import argparse
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from helpers import codex_bridge as bridge


class DesktopCreationTests(unittest.TestCase):
    thread_id = "33333333-3333-4333-8333-333333333333"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.args = argparse.Namespace(cwd=self.temp.name)
        self.events = []
        self.rpc = mock.MagicMock()
        self.rpc.__enter__.return_value = self.rpc
        self.rpc.request.side_effect = self.rpc_request
        self.desktop = mock.MagicMock()
        self.desktop.__enter__.return_value = self.desktop
        self.desktop.find_owner.side_effect = lambda thread: self.events.append(("owner", thread))
        for name, value in [
            ("RpcClient", mock.Mock(return_value=self.rpc)),
            ("DesktopIpcClient", mock.Mock(return_value=self.desktop)),
            ("desktop_ipc_socket", mock.Mock(return_value=Path("/tmp/fake.sock"))),
            ("find_codex", mock.Mock(return_value=Path("/fake/codex"))),
            ("wait_for_desktop_history", mock.Mock(side_effect=lambda thread: self.events.append(("history", thread["id"])))),
        ]:
            patch = mock.patch.object(bridge, name, value)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(bridge.subprocess, "run", side_effect=self.run_process)
        self.run_mock = patch.start()
        self.addCleanup(patch.stop)

    def rpc_request(self, method, params, **kwargs):
        self.events.append((method, params))
        if method == "thread/start":
            return {"thread": {"id": self.thread_id, "cwd": self.temp.name}}
        if method == "thread/name/set":
            return {}
        if method == "thread/archive":
            return {}
        if method == "thread/unarchive":
            return {"thread": {"id": self.thread_id, "cwd": self.temp.name, "status": {"type": "notLoaded"}}}
        self.fail("unexpected request " + method)

    def run_process(self, command, **kwargs):
        self.events.append(("process", command))

    def testReleaseBeforeOpeningAndVerifyExactIDWithoutSending(self):
        result = bridge.create_desktop(self.args)
        self.assertEqual(result["thread"]["id"], self.thread_id)
        self.assertTrue(result["thread"]["live"])
        self.assertEqual(self.events[1], ("thread/start", {
            "cwd": str(Path(self.temp.name).resolve())}))
        self.assertEqual(self.events[2], ("thread/name/set", {"threadId": self.thread_id, "name": "New chat"}))
        self.assertEqual(self.events[3], ("thread/archive", {"threadId": self.thread_id}))
        self.assertEqual(self.events[4], ("thread/unarchive", {"threadId": self.thread_id}))
        self.assertEqual(self.events[5], ("history", self.thread_id))
        self.assertEqual(self.events[6][1][:4], ["/usr/bin/open", "-g", "-b", "com.openai.codex"])
        self.assertEqual(self.events[6][1][-1], "codex://threads/" + self.thread_id + "?hostId=local")
        self.assertEqual(self.events[7], ("owner", self.thread_id))
        self.assertEqual(self.rpc.request.call_count, 4)

    def testUnknownOwnerOutcomeDoesNotRetryOrSend(self):
        self.desktop.find_owner.side_effect = bridge.BridgeError("timeout", code="desktop_ipc_outcome_unknown")
        with self.assertRaises(bridge.BridgeError) as raised:
            bridge.create_desktop(self.args)
        self.assertEqual(raised.exception.code, "desktop_handoff_failed")
        self.assertEqual(raised.exception.details["threadId"], self.thread_id)
        self.assertEqual(self.desktop.find_owner.call_count, 1)
        self.assertEqual(self.rpc.request.call_count, 4)

    def testFailedReleaseNeverOpensDesktopOrSends(self):
        self.rpc.request.side_effect = [
            {"thread": {"id": self.thread_id}}, {}, {}, {"thread": {"id": self.thread_id, "status": {"type": "idle"}}}]
        with self.assertRaises(bridge.BridgeError):
            bridge.create_desktop(self.args)
        self.assertEqual(self.run_mock.call_count, 1)  # daemon startup only
        self.desktop.find_owner.assert_not_called()

    def testDesktopUnavailableDoesNotCreateAnything(self):
        with mock.patch.object(bridge, "desktop_ipc_socket", return_value=None):
            with self.assertRaises(bridge.BridgeError):
                bridge.create_desktop(self.args)
        self.rpc.request.assert_not_called()
        self.run_mock.assert_not_called()

    def testHistoryFailureNeverOpensDesktopOrSends(self):
        with mock.patch.object(bridge, "wait_for_desktop_history", side_effect=bridge.BridgeError("not ready")):
            with self.assertRaises(bridge.BridgeError) as raised:
                bridge.create_desktop(self.args)
        self.assertEqual(raised.exception.details["threadId"], self.thread_id)
        self.assertEqual(self.run_mock.call_count, 1)
        self.desktop.find_owner.assert_not_called()


class DesktopHistoryBarrierTests(unittest.TestCase):
    def testRequiresMatchingSessionMetadataBeforeDesktopOpens(self):
        import json
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            path = home / "sessions" / ("rollout-" + DesktopCreationTests.thread_id + ".jsonl")
            path.parent.mkdir()
            thread = {"id": DesktopCreationTests.thread_id, "path": str(path)}
            with mock.patch.object(bridge, "codex_home", return_value=home):
                with self.assertRaises(bridge.BridgeError):
                    bridge.wait_for_desktop_history(thread, timeout=0)
                path.write_text('{"type":')
                with self.assertRaises(bridge.BridgeError):
                    bridge.wait_for_desktop_history(thread, timeout=0)
                path.write_text(json.dumps({"type": "session_meta", "payload": {"id": "different"}}) + "\n")
                with self.assertRaises(bridge.BridgeError):
                    bridge.wait_for_desktop_history(thread, timeout=0)
                path.write_text(json.dumps({"type": "session_meta", "payload": {"id": thread["id"]}}) + "\n")
                bridge.wait_for_desktop_history(thread, timeout=0)

    def testRejectsUnexpectedHistoryLocation(self):
        with mock.patch.object(bridge, "codex_home", return_value=Path("/tmp/fake-codex-home")):
            with self.assertRaises(bridge.BridgeError):
                bridge.wait_for_desktop_history({"id": DesktopCreationTests.thread_id, "path": "/tmp/unrelated"}, timeout=0)
