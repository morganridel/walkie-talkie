import contextlib
import importlib.util
import io
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest import mock
from importlib.machinery import SourceFileLoader


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_loader(
    "walkie_finish", SourceFileLoader("walkie_finish", str(HERE / "walkie-finish")))
walkie_finish = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(walkie_finish)


THREAD = "11111111-1111-4111-8111-111111111111"
TURN = "22222222-2222-4222-8222-222222222222"
RECORD = {"pid": 4242, "tty": "/dev/ttys007", "source": "sidecar"}
PROCESS = [{"pid": 4242, "ppid": 1, "tty": "ttys007",
            "command": "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex "
                       "--remote unix:// resume " + THREAD}]
WINDOW = {"matches": 1, "windowID": 42, "windowTabCount": 1}


class WalkieFinishTests(unittest.TestCase):
    def run_main(self, args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = walkie_finish.main(args)
        import json
        return code, json.loads(output.getvalue())

    def test_stale_sidecar_is_rejected_without_touching_terminal(self):
        with mock.patch.object(walkie_finish.codex_bridge, "sidecar_tty_map", return_value={}), \
             mock.patch.object(walkie_finish, "terminal_tab_count") as tabs, \
             mock.patch.object(walkie_finish.os, "kill") as kill:
            code, result = self.run_main(["--thread", THREAD])
        self.assertEqual(code, 3)
        self.assertEqual(result["reason"], "no_verified_cli_terminal_sidecar")
        tabs.assert_not_called()
        kill.assert_not_called()

    def test_mismatched_sidecar_thread_is_rejected(self):
        other = "33333333-3333-4333-8333-333333333333"
        with mock.patch.object(walkie_finish.codex_bridge, "sidecar_tty_map",
                               return_value={other: RECORD}), \
             mock.patch.object(walkie_finish, "terminal_tab_count") as tabs:
            result = walkie_finish.verified_record(THREAD)
        self.assertIsNone(result)
        tabs.assert_not_called()

    def test_wrong_or_reused_pid_command_is_rejected(self):
        wrong = [{"pid": 4242, "ppid": 1, "tty": "ttys007",
                  "command": "/usr/bin/python3 unrelated.py " + THREAD}]
        with mock.patch.object(walkie_finish.codex_bridge, "sidecar_tty_map",
                               return_value={THREAD: RECORD}), \
             mock.patch.object(walkie_finish.codex_bridge, "process_rows", return_value=wrong):
            self.assertIsNone(walkie_finish.verified_record(THREAD))

    def test_dry_run_reports_only_the_verified_target(self):
        with mock.patch.object(walkie_finish.codex_bridge, "sidecar_tty_map",
                               return_value={THREAD: RECORD}), \
             mock.patch.object(walkie_finish.codex_bridge, "process_rows", return_value=PROCESS), \
             mock.patch.object(walkie_finish, "terminal_tab_count", return_value=1), \
             mock.patch.object(walkie_finish, "terminal_window_snapshot", return_value=WINDOW), \
             mock.patch.object(walkie_finish, "tty_owner_identity", return_value=(88, 1000)), \
             mock.patch.object(walkie_finish.os, "kill") as kill, \
             mock.patch.object(walkie_finish.subprocess, "Popen") as popen:
            code, result = self.run_main(["--thread", THREAD, "--turn", TURN, "--dry-run"])
        self.assertEqual(code, 0)
        self.assertEqual(result["action"], "would_wait_and_close_tab")
        self.assertEqual(result["tty"], RECORD["tty"])
        kill.assert_not_called()
        popen.assert_not_called()

    def test_exact_turn_watcher_is_detached_and_returns_promptly(self):
        with mock.patch.object(walkie_finish.codex_bridge, "sidecar_tty_map",
                               return_value={THREAD: RECORD}), \
             mock.patch.object(walkie_finish.codex_bridge, "process_rows", return_value=PROCESS), \
             mock.patch.object(walkie_finish, "terminal_tab_count", return_value=1), \
             mock.patch.object(walkie_finish, "terminal_window_snapshot", return_value=WINDOW), \
             mock.patch.object(walkie_finish.subprocess, "Popen") as popen:
            code, result = self.run_main(["--thread", THREAD, "--turn", TURN])
        self.assertEqual(code, 0)
        self.assertEqual(result["action"], "watching_exact_turn")
        command = popen.call_args.args[0]
        self.assertIn("--_after-turn", command)
        self.assertIn(TURN, command)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertIs(popen.call_args.kwargs["stdin"], subprocess.DEVNULL)

    def test_tty_owner_identity_uses_root_login_pid_and_lstart(self):
        output = (
            "501 1 Tue Oct 14 11:22:33 2025 /usr/bin/login\n"
            "502 501 Tue Oct 14 11:22:34 2025 /Applications/Codex.app/codex "
            "resume " + THREAD + "\n")
        with mock.patch.object(walkie_finish.subprocess, "run",
                               return_value=mock.Mock(returncode=0, stdout=output)) as run:
            owner = walkie_finish.tty_owner_identity("/dev/ttys007")
        self.assertIsNotNone(owner)
        self.assertEqual(owner[0], 501)
        self.assertGreater(owner[1], 0)
        self.assertEqual(run.call_args.args[0],
                         ["/bin/ps", "-t", "ttys007", "-o", "pid=,ppid=,lstart=,comm="])

    def test_reused_tty_with_new_root_owner_never_closes_replacement_tab(self):
        ps_output = [
            mock.Mock(returncode=0, stdout=(
                "501 1 Tue Oct 14 11:22:33 2025 /usr/bin/login\n"
                "502 501 Tue Oct 14 11:22:34 2025 /Applications/Codex.app/codex "
                "resume " + THREAD + "\n")),
            mock.Mock(returncode=0, stdout=(
                "601 1 Tue Oct 14 11:24:13 2025 /usr/bin/login\n"
                "602 601 Tue Oct 14 11:24:14 2025 /bin/zsh\n")),
        ]
        process_calls = [PROCESS[0], PROCESS[0], None, None]

        def rows():
            row = process_calls.pop(0)
            return [row] if row else []

        with mock.patch.object(walkie_finish.codex_bridge, "sidecar_tty_map",
                               return_value={THREAD: RECORD}), \
             mock.patch.object(walkie_finish.codex_bridge, "process_rows", side_effect=rows), \
             mock.patch.object(walkie_finish, "terminal_tab_count", return_value=1), \
             mock.patch.object(walkie_finish, "terminal_window_snapshot", return_value=WINDOW), \
             mock.patch.object(walkie_finish.subprocess, "run", side_effect=ps_output), \
             mock.patch.object(walkie_finish.os, "kill") as kill, \
             mock.patch.object(walkie_finish, "close_terminal_window") as close, \
             mock.patch.object(walkie_finish.time, "sleep"):
            result = walkie_finish.finish_verified(THREAD)

        self.assertFalse(result["ok"])
        self.assertEqual(result["reason"], "terminal_owner_changed")
        kill.assert_called_once_with(4242, signal.SIGTERM)
        close.assert_not_called()

    def test_bare_invocation_with_active_turn_schedules_watcher_without_closing(self):
        with mock.patch.object(walkie_finish.codex_bridge, "sidecar_tty_map",
                               return_value={THREAD: RECORD}), \
             mock.patch.object(walkie_finish.codex_bridge, "process_rows", return_value=PROCESS), \
             mock.patch.object(walkie_finish.codex_bridge, "active_turn_id",
                               return_value=TURN) as active, \
             mock.patch.object(walkie_finish, "terminal_tab_count", return_value=1), \
             mock.patch.object(walkie_finish, "terminal_window_snapshot", return_value=WINDOW), \
             mock.patch.object(walkie_finish, "finish_verified") as finish, \
             mock.patch.object(walkie_finish.os, "kill") as kill, \
             mock.patch.object(walkie_finish.subprocess, "Popen") as popen:
            code, result = self.run_main(["--thread", THREAD])
        self.assertEqual(code, 0)
        self.assertEqual(result["action"], "watching_exact_turn")
        active.assert_called_once_with(THREAD)
        self.assertIn(TURN, popen.call_args.args[0])
        finish.assert_not_called()
        kill.assert_not_called()

    def test_bare_invocation_without_active_turn_finishes_verified_target(self):
        expected = {"ok": True, "action": "closed_tab"}
        with mock.patch.object(walkie_finish.codex_bridge, "sidecar_tty_map",
                               return_value={THREAD: RECORD}), \
             mock.patch.object(walkie_finish.codex_bridge, "process_rows", return_value=PROCESS), \
             mock.patch.object(walkie_finish.codex_bridge, "active_turn_id", return_value=None), \
             mock.patch.object(walkie_finish, "terminal_tab_count", return_value=1), \
             mock.patch.object(walkie_finish, "terminal_window_snapshot", return_value=WINDOW), \
             mock.patch.object(walkie_finish, "finish_verified", return_value=expected) as finish, \
             mock.patch.object(walkie_finish.subprocess, "Popen") as popen, \
             mock.patch.dict("os.environ", {"CODEX_TURN_ID": TURN}):
            code, result = self.run_main(["--thread", THREAD])
        self.assertEqual(code, 0)
        self.assertEqual(result["action"], "closed_tab")
        finish.assert_called_once_with(THREAD)
        popen.assert_not_called()

    def test_detached_watcher_waits_for_the_exact_thread_and_turn(self):
        with mock.patch.object(walkie_finish.codex_bridge, "watch_until_idle",
                               return_value={"idle": True, "turnId": TURN}) as watch, \
             mock.patch.object(walkie_finish, "finish_verified",
                               return_value={"ok": True, "action": "closed_tab"}) as finish:
            result = walkie_finish.watch_then_finish(THREAD, TURN, 12)
        self.assertTrue(result["ok"])
        self.assertEqual(watch.call_args.args[0].thread, THREAD)
        self.assertEqual(watch.call_args.args[0].turn, TURN)
        self.assertEqual(watch.call_args.args[0].timeout, 12)
        finish.assert_called_once_with(THREAD)

    def test_close_signals_only_verified_cli_pid_and_closes_single_tab_window(self):
        process_calls = [PROCESS[0], PROCESS[0], None, None]

        def rows():
            row = process_calls.pop(0)
            return [row] if row else []

        with mock.patch.object(walkie_finish.codex_bridge, "sidecar_tty_map",
                               return_value={THREAD: RECORD}), \
             mock.patch.object(walkie_finish.codex_bridge, "process_rows", side_effect=rows), \
             mock.patch.object(walkie_finish, "terminal_tab_count", return_value=1), \
             mock.patch.object(walkie_finish, "terminal_window_snapshot", return_value=WINDOW), \
             mock.patch.object(walkie_finish.subprocess, "run",
                               return_value=mock.Mock(returncode=0, stdout="closed")) as run, \
             mock.patch.object(walkie_finish, "tty_owner_identity", return_value=(88, 1000)), \
             mock.patch.object(walkie_finish.os, "kill") as kill, \
             mock.patch.object(walkie_finish.time, "sleep"):
            result = walkie_finish.finish_verified(THREAD)

        self.assertEqual(result["action"], "closed_tab")
        kill.assert_called_once_with(4242, signal.SIGTERM)
        close_script = run.call_args_list[-1].args[0][-1]
        self.assertIn("close finalWindow", close_script)
        self.assertIn("/dev/ttys007", close_script)
        self.assertIn('id of finalWindow as text) is not "42"', close_script)
        self.assertNotIn("close item 1 of foundTabs", close_script)
        self.assertNotIn('quit', close_script)

    def test_close_script_compiles_without_sending_apple_events(self):
        script = walkie_finish.close_terminal_window_script(RECORD["tty"], 42)
        self.assertIn('tell application id "com.apple.Terminal"', script)
        self.assertIn('close finalWindow', script)
        self.assertIn('if finalTabCount is not 1 then return "multi_tab"', script)
        with mock.patch.object(walkie_finish.subprocess, "run",
                               return_value=mock.Mock(returncode=0, stdout="1\n42\n1\n")) as run:
            snapshot = walkie_finish.terminal_window_snapshot(RECORD["tty"])
        self.assertEqual(snapshot, WINDOW)
        snapshot_script = run.call_args.args[0][-1]
        with tempfile.TemporaryDirectory(prefix="walkie-finish-applescript-") as temp:
            for name, source_text in (("close", script), ("snapshot", snapshot_script)):
                source = Path(temp) / f"{name}.applescript"
                compiled = Path(temp) / f"{name}.scpt"
                source.write_text(source_text, encoding="utf-8")
                result = subprocess.run(
                    ["/usr/bin/osacompile", "-l", "AppleScript", "-o", str(compiled), str(source)],
                    capture_output=True, text=True, timeout=10, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(compiled.exists())

    def test_multitab_window_is_rejected_before_signaling_codex(self):
        with mock.patch.object(walkie_finish.codex_bridge, "sidecar_tty_map",
                               return_value={THREAD: RECORD}), \
             mock.patch.object(walkie_finish.codex_bridge, "process_rows", return_value=PROCESS), \
             mock.patch.object(walkie_finish, "terminal_tab_count", return_value=1), \
             mock.patch.object(walkie_finish, "terminal_window_snapshot",
                               return_value={"matches": 1, "windowID": 42,
                                             "windowTabCount": 2}), \
             mock.patch.object(walkie_finish.os, "kill") as kill, \
             mock.patch.object(walkie_finish, "close_terminal_window") as close:
            result = walkie_finish.finish_verified(THREAD)
        self.assertEqual(result["reason"], "terminal_multitab_close_unsupported")
        kill.assert_not_called()
        close.assert_not_called()

    def test_changed_window_identity_refuses_close_after_codex_exits(self):
        process_calls = [PROCESS[0], PROCESS[0], None, None]

        def rows():
            row = process_calls.pop(0)
            return [row] if row else []

        snapshots = [WINDOW, {"matches": 1, "windowID": 43, "windowTabCount": 1}]
        with mock.patch.object(walkie_finish.codex_bridge, "sidecar_tty_map",
                               return_value={THREAD: RECORD}), \
             mock.patch.object(walkie_finish.codex_bridge, "process_rows", side_effect=rows), \
             mock.patch.object(walkie_finish, "terminal_tab_count", return_value=1), \
             mock.patch.object(walkie_finish, "terminal_window_snapshot",
                               side_effect=snapshots), \
             mock.patch.object(walkie_finish, "tty_owner_identity", return_value=(88, 1000)), \
             mock.patch.object(walkie_finish.os, "kill") as kill, \
             mock.patch.object(walkie_finish, "close_terminal_window") as close, \
             mock.patch.object(walkie_finish.time, "sleep"):
            result = walkie_finish.finish_verified(THREAD)
        self.assertEqual(result["reason"], "terminal_window_changed")
        kill.assert_called_once_with(4242, signal.SIGTERM)
        close.assert_not_called()

    def test_close_failure_returns_bounded_osascript_diagnostic(self):
        long_error = "Terminal said no. " + ("x" * 500)
        with mock.patch.object(walkie_finish.subprocess, "run",
                               return_value=mock.Mock(returncode=1, stdout="",
                                                      stderr=long_error)) as run:
            result = walkie_finish.close_terminal_window(RECORD["tty"], 42)
        self.assertFalse(result["ok"])
        self.assertTrue(result["detail"].startswith("osascript exit 1: Terminal said no."))
        self.assertLessEqual(len(result["detail"]), len("osascript exit 1: ") + 200)
        self.assertEqual(run.call_args.kwargs["timeout"], 8)

    def test_close_failure_reports_timeout_and_launch_errors(self):
        with mock.patch.object(walkie_finish.subprocess, "run",
                               side_effect=subprocess.TimeoutExpired("osascript", 8)):
            timed_out = walkie_finish.close_terminal_window(RECORD["tty"], 42)
        self.assertEqual(timed_out["detail"],
                         "Terminal close AppleScript timed out after 8 seconds")

        with mock.patch.object(walkie_finish.subprocess, "run",
                               side_effect=OSError("permission denied\nextra")):
            launch_failed = walkie_finish.close_terminal_window(RECORD["tty"], 42)
        self.assertEqual(launch_failed["detail"], "could not start osascript: permission denied extra")

    def test_thread_must_be_uuid_and_desktop_without_cli_sidecar_is_unsupported(self):
        code, result = self.run_main(["--thread", "not-a-uuid"])
        self.assertEqual(code, 2)
        self.assertEqual(result["reason"], "missing_or_invalid_thread_id")

        with mock.patch.object(walkie_finish.codex_bridge, "sidecar_tty_map", return_value={}):
            code, result = self.run_main(["--thread", THREAD])
        self.assertEqual(code, 3)
        self.assertEqual(result["action"], "unsupported")


if __name__ == "__main__":
    unittest.main()
