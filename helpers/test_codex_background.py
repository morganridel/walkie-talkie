import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest.mock import patch

import codex_background as background
from codex_bridge import BridgeError


THREAD = "11111111-2222-4333-8444-555555555555"


class FakeRPC:
    def __init__(self, callback):
        self.callback = callback
        self.calls = []
        self.sent = []
        self.status = "idle"

    def request(self, method, params, **kwargs):
        self.calls.append((method, params))
        if method in {"thread/start", "thread/read", "thread/resume"}:
            return {"thread": {"id": THREAD, "cwd": "/tmp", "status": {"type": self.status}}}
        if method == "turn/start":
            self.status = "active"
            return {"turn": {"id": "turn-1", "status": "inProgress"}}
        if method == "turn/steer":
            return {"turnId": "turn-1"}
        if method == "thread/unsubscribe":
            self.status = "notLoaded"
            return {"status": "unsubscribed"}
        if method == "thread/loaded/list":
            return {"data": [] if self.status == "notLoaded" else [THREAD]}
        raise AssertionError(method)

    def send(self, message):
        self.sent.append(message)


class BackgroundTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.broker = background.Broker(self.directory, rpc_factory=FakeRPC, start_release_worker=False)

    def tearDown(self):
        self.temp.cleanup()

    def create(self):
        return self.broker.create({"cwd": self.temp.name, "input": [{"type": "text", "text": "hello"}]})

    def test_worker_advertises_idle_release_without_protocol_break(self):
        self.assertEqual(self.broker.snapshot()["protocol"], background.PROTOCOL)
        self.assertIn("idle-release-v1", self.broker.snapshot()["features"])
        self.assertIn("idle-release-v1", self.broker.dispatch("ping", {})["features"])

    def finish(self):
        self.broker.rpc.status = "idle"
        self.broker.on_message({"method": "turn/completed", "params": {"threadId": THREAD,
                               "turn": {"id": "turn-1", "status": "completed"}}})

    def test_completed_background_turn_releases_only_its_subscriber_and_keeps_identity(self):
        self.create()
        self.finish()
        self.assertFalse(any(method == "thread/unsubscribe" for method, _ in self.broker.rpc.calls))
        self.assertTrue(self.broker.release_idle(THREAD, "turn-1"))
        self.assertEqual(self.broker.rpc.calls[-2:], [
            ("thread/read", {"threadId": THREAD, "includeTurns": False}),
            ("thread/unsubscribe", {"threadId": THREAD})])
        row = self.broker.snapshot()["threads"][0]
        self.assertFalse(row["subscribed"])
        self.assertFalse(row["live"])
        self.assertTrue(self.broker.dispatch("owns", {"threadId": THREAD})["owned"])
        self.assertFalse(any("archive" in method for method, _ in self.broker.rpc.calls))

    def test_new_turn_before_queued_release_preserves_subscription(self):
        self.create()
        self.finish()
        self.broker.on_message({"method": "turn/started", "params": {"threadId": THREAD,
                               "turn": {"id": "turn-2", "status": "inProgress"}}})
        before = len(self.broker.rpc.calls)
        self.assertFalse(self.broker.release_idle(THREAD, "turn-1"))
        self.assertEqual(len(self.broker.rpc.calls), before)
        self.assertTrue(self.broker.threads[THREAD]["subscribed"])

    def test_pending_approval_blocks_release_until_native_resolution(self):
        self.create()
        self.broker.on_message({"id": 9, "method": "item/commandExecution/requestApproval", "params": {
            "threadId": THREAD, "turnId": "turn-1", "command": "echo hello"}})
        self.finish()
        self.assertEqual(len(self.broker.snapshot()["requests"]), 1)
        self.assertTrue(self.broker.release_queue.empty())
        self.assertFalse(self.broker.release_idle(THREAD, "turn-1"))
        self.broker.on_message({"method": "serverRequest/resolved", "params": {"requestId": 9}})
        self.assertFalse(self.broker.release_queue.empty())
        self.assertTrue(self.broker.release_idle(THREAD, "turn-1"))

    def test_fresh_native_active_status_blocks_release_of_locally_idle_row(self):
        self.create()
        self.finish()
        self.broker.rpc.status = "active"
        self.assertFalse(self.broker.release_idle(THREAD, "turn-1"))
        self.assertTrue(self.broker.threads[THREAD]["subscribed"])
        self.assertFalse(any(method == "thread/unsubscribe" for method, _ in self.broker.rpc.calls))

    def test_new_turn_notification_during_metadata_read_blocks_release(self):
        self.create()
        self.finish()
        original = self.broker.rpc.request
        def raced(method, params, **kwargs):
            result = original(method, params, **kwargs)
            if method == "thread/read":
                self.broker.on_message({"method": "turn/started", "params": {"threadId": THREAD,
                                       "turn": {"id": "turn-2", "status": "inProgress"}}})
            return result
        self.broker.rpc.request = raced
        self.assertFalse(self.broker.release_idle(THREAD, "turn-1"))
        self.assertTrue(self.broker.threads[THREAD]["subscribed"])
        self.assertFalse(any(method == "thread/unsubscribe" for method, _ in self.broker.rpc.calls))

    def test_release_rpc_runs_off_callback_reader_and_does_not_block_notifications(self):
        reached, resume = threading.Event(), threading.Event()
        class BlockingRPC(FakeRPC):
            block_release = False
            def request(self, method, params, **kwargs):
                if method == "thread/read" and self.block_release:
                    reached.set()
                    if not resume.wait(3):
                        raise AssertionError("test did not resume release RPC")
                return super().request(method, params, **kwargs)
        with tempfile.TemporaryDirectory() as directory:
            broker = background.Broker(Path(directory), rpc_factory=BlockingRPC)
            broker.create({"cwd": directory, "input": [{"type": "text", "text": "hello"}]})
            broker.rpc.status = "idle"
            broker.rpc.block_release = True
            callback = threading.Thread(target=broker.on_message, args=({"method": "turn/completed", "params": {
                "threadId": THREAD, "turn": {"id": "turn-1", "status": "completed"}}},))
            try:
                callback.start()
                callback.join(1)
                self.assertFalse(callback.is_alive(), "completion callback blocked on its own RPC reader")
                self.assertTrue(reached.wait(1), "release worker did not perform its metadata check")
                broker.on_message({"method": "turn/started", "params": {"threadId": THREAD,
                                   "turn": {"id": "turn-2", "status": "inProgress"}}})
                self.assertEqual(broker.threads[THREAD]["state"], "active")
            finally:
                resume.set()
                broker.release_queue.put(None)
                broker.release_worker.join(2)
                callback.join(2)
            self.assertFalse(broker.release_worker.is_alive())
            self.assertFalse(any(method == "thread/unsubscribe" for method, _ in broker.rpc.calls))

    def test_desktop_release_pending_returns_without_retention_wait(self):
        self.create()
        self.broker.rpc.status = "idle"
        self.broker.threads[THREAD].update(state="idle", busy=False)
        original = self.broker.rpc.request
        def retaining(method, params, **kwargs):
            if method == "thread/unsubscribe":
                self.broker.rpc.calls.append((method, params))
                return {"status": "unsubscribed"}
            return original(method, params, **kwargs)
        self.broker.rpc.request = retaining
        with patch.object(background, "active_turn_id", return_value=None), patch.object(background.time, "sleep") as sleep:
            with self.assertRaises(BridgeError) as error:
                self.broker.dispatch("prepare-open", {"threadId": THREAD, "destination": "desktop"})
        self.assertEqual(error.exception.code, "thread_release_pending")
        self.assertIn("minute", str(error.exception))
        sleep.assert_not_called()
        self.assertTrue(self.broker.mutation.acquire(blocking=False))
        self.broker.mutation.release()
        methods = [method for method, _ in self.broker.rpc.calls]
        self.assertEqual(methods.count("thread/read"), 2)  # Initial start plus exact open preflight.
        self.assertEqual(methods.count("thread/loaded/list"), 1)

    def test_loaded_thread_check_follows_native_pagination(self):
        calls = []
        def pages(method, params, **kwargs):
            calls.append((method, params))
            if not params.get("cursor"):
                return {"data": ["some-other-thread"], "nextCursor": "next"}
            return {"data": [THREAD]}
        self.broker.rpc.request = pages
        self.assertTrue(self.broker._shared_thread_loaded(THREAD))
        self.assertEqual(calls[-1][1]["cursor"], "next")

    def test_first_prompt_submitted_once_and_native_policy_inherited(self):
        result = self.create()
        self.assertEqual(result["threadId"], THREAD)
        self.assertTrue(result["thread"]["background"])
        calls = self.broker.rpc.calls
        self.assertEqual([method for method, _ in calls].count("turn/start"), 1)
        options = next(params for method, params in calls if method == "thread/start")
        self.assertEqual(options, {"cwd": str(Path(self.temp.name).resolve())})
        self.assertFalse(any("archive" in method for method, _ in calls))

    def test_empty_prompt_creates_nothing(self):
        with self.assertRaises(BridgeError):
            self.broker.create({"cwd": self.temp.name, "input": [{"type": "text", "text": " "}]})
        self.assertEqual(self.broker.rpc.calls, [])

    def test_approval_stays_pending_until_explicit_response(self):
        self.create()
        self.broker.on_message({"id": 8, "method": "item/commandExecution/requestApproval", "params": {
            "threadId": THREAD, "turnId": "turn-1", "command": "touch /tmp/example"}})
        status = self.broker.snapshot()
        self.assertEqual(status["threads"][0]["state"], "waitingOnApproval")
        self.assertEqual(self.broker.rpc.sent, [])
        request = status["requests"][0]
        with self.assertRaises(BridgeError):
            self.broker.respond({"requestId": request["id"], "response": {"decision": "acceptForSession"}})
        self.assertEqual(self.broker.rpc.sent, [])
        self.broker.respond({"requestId": request["id"], "response": {"decision": "accept"}})
        self.assertEqual(self.broker.rpc.sent, [{"id": 8, "result": {"decision": "accept"}}])
        with self.assertRaises(BridgeError):
            self.broker.respond({"requestId": request["id"], "response": {"decision": "accept"}})

    def test_questions_require_all_answers_and_never_auto_answer(self):
        self.create()
        self.broker.on_message({"id": "question-1", "method": "item/tool/requestUserInput", "params": {
            "threadId": THREAD, "turnId": "turn-1", "questions": [
                {"id": "which", "header": "Choice", "question": "Which one?"}]}})
        request = self.broker.snapshot()["requests"][0]
        self.assertEqual(request["kind"], "questions")
        with self.assertRaises(BridgeError):
            self.broker.respond({"requestId": request["id"], "response": {"answers": {}}})
        response = {"answers": {"which": {"answers": ["A"]}}}
        self.broker.respond({"requestId": request["id"], "response": response})
        self.assertEqual(self.broker.rpc.sent[0]["result"], response)

    def test_unsupported_callback_visible_and_not_fabricated(self):
        self.create()
        self.broker.on_message({"id": 9, "method": "item/tool/call", "params": {"threadId": THREAD}})
        request = self.broker.snapshot()["requests"][0]
        self.assertEqual(request["kind"], "unsupported")
        with self.assertRaises(BridgeError):
            self.broker.respond({"requestId": request["id"], "response": {}})
        self.assertEqual(self.broker.rpc.sent, [])

    def test_completed_success_once_errors_no_completion_checkmark(self):
        self.create()
        completed = {"method": "turn/completed", "params": {"threadId": THREAD,
                     "turn": {"id": "turn-1", "status": "completed"}}}
        self.broker.on_message(completed)
        self.broker.on_message(completed)
        self.assertEqual(len(self.broker.snapshot()["completions"]), 1)
        self.broker.on_message({"method": "turn/completed", "params": {"threadId": THREAD,
                               "turn": {"id": "turn-2", "status": "failed"}}})
        self.assertEqual(len(self.broker.snapshot()["completions"]), 1)
        self.assertEqual(self.broker.snapshot()["threads"][0]["state"], "error")

    def test_active_open_refused_without_unsubscribe_or_archive(self):
        self.create()
        with patch.object(background, "active_turn_id", return_value="turn-1"):
            with self.assertRaises(BridgeError) as error:
                self.broker.prepare_open({"threadId": THREAD, "destination": "desktop"})
        self.assertEqual(error.exception.code, "thread_busy")
        self.assertFalse(any(method in {"thread/unsubscribe", "thread/archive"} for method, _ in self.broker.rpc.calls))

    def test_active_cli_attaches_same_shared_writer_without_unsubscribe(self):
        self.create()
        with patch.object(background, "active_turn_id", return_value="turn-1"):
            result = self.broker.prepare_open({"threadId": THREAD, "destination": "cli"})
        self.assertTrue(result["safe"])
        self.assertFalse(any(method in {"thread/unsubscribe", "thread/archive"} for method, _ in self.broker.rpc.calls))

    def test_active_desktop_owner_may_open_its_own_view_but_cli_refused(self):
        owner = {"id": THREAD, "live": True, "tty": "codex:" + THREAD, "busy": True}
        with patch.object(background, "one_thread", return_value=owner):
            result = self.broker.prepare_open({"threadId": THREAD, "destination": "desktop"})
            self.assertTrue(result["safe"])
            with self.assertRaises(BridgeError) as error:
                self.broker.prepare_open({"threadId": THREAD, "destination": "cli"})
            self.assertEqual(error.exception.code, "desktop_thread_owned")

    def test_idle_desktop_open_unsubscribes_and_checks_release_never_archives(self):
        self.create()
        self.broker.rpc.status = "idle"
        self.broker.threads[THREAD].update(state="idle", busy=False)
        with patch.object(background, "active_turn_id", return_value=None):
            result = self.broker.prepare_open({"threadId": THREAD, "destination": "desktop"})
        self.assertTrue(result["safe"])
        self.assertFalse(self.broker.threads[THREAD]["subscribed"])
        self.assertFalse(any("archive" in method for method, _ in self.broker.rpc.calls))

    def test_closed_resume_requires_conclusive_owner_check(self):
        with patch.object(background, "one_thread", return_value={"ownerState": "unknown"}):
            with self.assertRaises(BridgeError):
                self.broker.send_existing({"threadId": THREAD, "input": [{"type": "text", "text": "hello"}]})
        self.assertFalse(any(method == "thread/resume" for method, _ in self.broker.rpc.calls))

    def test_released_background_chat_keeps_broker_routing_and_rejoins_safely(self):
        self.create()
        self.broker.rpc.status = "idle"
        self.broker.threads[THREAD].update(subscribed=False, busy=False, state="idle")
        self.assertTrue(self.broker.dispatch("owns", {"threadId": THREAD})["owned"])
        with patch.object(background, "one_thread", return_value={"ownerState": "closed"}):
            result = self.broker.send_existing({"threadId": THREAD, "input": [{"type": "text", "text": "again"}]})
        self.assertTrue(result["thread"]["subscribed"])
        self.assertEqual([method for method, _ in self.broker.rpc.calls].count("thread/resume"), 1)

    def test_observing_existing_cli_never_demotes_background_owner(self):
        self.create()
        self.broker.observe({"threadId": THREAD, "turnId": "turn-2"})
        row = self.broker.snapshot()["threads"][0]
        self.assertTrue(row["background"])
        self.assertTrue(row["subscribed"])

    def test_released_chat_rejoins_verified_remote_cli_but_never_private_owner(self):
        self.create()
        row = self.broker.threads[THREAD]
        row.update(subscribed=False, busy=False, state="idle")
        self.broker.rpc.status = "idle"
        owner = {"ownerState": "live", "live": True, "pid": 123, "tty": "/dev/ttys007"}
        with patch.object(background, "one_thread", return_value=owner), patch.object(background, "verified_shared_cli_owner", return_value=False):
            with self.assertRaises(BridgeError):
                self.broker.send_existing({"threadId": THREAD, "input": [{"type": "text", "text": "again"}]})
        self.assertFalse(any(method == "thread/resume" for method, _ in self.broker.rpc.calls))
        with patch.object(background, "one_thread", return_value=owner), patch.object(background, "verified_shared_cli_owner", return_value=True):
            result = self.broker.send_existing({"threadId": THREAD, "input": [{"type": "text", "text": "again"}]})
        self.assertTrue(result["thread"]["subscribed"])

    def test_approval_detail_displays_action_and_respects_available_decisions(self):
        view = background.request_view({"method": "item/commandExecution/requestApproval", "params": {
            "threadId": THREAD, "command": "echo hello", "cwd": "/tmp", "reason": "Needs access",
            "availableDecisions": ["decline", "cancel"]}})
        self.assertIn("Command:\necho hello", view["detail"])
        self.assertIn("Folder: /tmp", view["detail"])
        self.assertNotIn('"threadId"', view["detail"])
        self.assertEqual([value["id"] for value in view["choices"]], ["decline", "cancel"])

    def test_file_approval_needs_full_diff_before_approve_is_offered(self):
        message = {"method": "item/fileChange/requestApproval", "params": {"threadId": THREAD, "itemId": "file1"}}
        without = background.request_view(message)
        self.assertNotIn("accept", [choice["id"] for choice in without["choices"]])
        with_diff = background.request_view(message, {"changes": [{"path": "/tmp/a", "diff": "+content"}]})
        self.assertIn("accept", [choice["id"] for choice in with_diff["choices"]])
        self.assertIn("+content", with_diff["detail"])

    def test_connection_loss_is_unknown_not_idle(self):
        self.create()
        self.broker.on_message({"method": "walkie/connectionLost", "params": {"reason": "lost"}})
        row = self.broker.snapshot()["threads"][0]
        self.assertEqual(row["state"], "error")
        self.assertIsNone(row["busy"])

    def test_crashed_worker_state_never_replays_connection_scoped_approvals(self):
        self.create()
        self.broker.on_message({"id": 8, "method": "item/commandExecution/requestApproval", "params": {
            "threadId": THREAD, "turnId": "turn-1", "command": "echo hello"}})
        recovered = background.Broker(self.directory, rpc_factory=FakeRPC, start_release_worker=False)
        status = recovered.snapshot()
        self.assertEqual(status["problem"]["code"], "background_previous_connection_lost")
        self.assertIsNone(status["threads"][0]["busy"])
        request = status["requests"][0]
        self.assertEqual(request["choices"], [])
        with self.assertRaises(BridgeError):
            recovered.respond({"requestId": request["id"], "response": {"decision": "accept"}})
        self.assertEqual(recovered.rpc.sent, [])

    def test_offline_status_never_claims_unfinished_work_is_idle(self):
        self.create()
        with patch.object(background, "runtime_dir", return_value=self.directory):
            status = background.offline_status()
        self.assertEqual(status["problem"]["code"], "background_unavailable")
        self.assertIsNone(status["threads"][0]["busy"])
        self.assertEqual(status["requests"], [])

    def test_mutation_unknown_outcome_is_not_retried(self):
        with patch.object(background, "runtime_dir", return_value=self.directory), patch.object(
                background, "_connect", side_effect=[{"ok": True}, BridgeError("unknown", code="background_outcome_unknown")]) as connect:
            with self.assertRaises(BridgeError):
                background.broker_request("create", {}, start=True)
        self.assertEqual([call.args[0] for call in connect.call_args_list], ["ping", "create"])

    def test_runtime_refuses_symlink_and_world_readable_credentials(self):
        target = self.directory / "target"
        target.mkdir(mode=0o700)
        linked = self.directory / "link"
        linked.symlink_to(target)
        with self.assertRaises(BridgeError):
            background.secure_directory(linked)
        credential = target / "token"
        credential.write_text("secret")
        credential.chmod(0o644)
        with self.assertRaises(BridgeError):
            background.private_file(credential)


if __name__ == "__main__":
    unittest.main()
