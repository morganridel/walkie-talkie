"""Delivery and ambiguity behavior for the local reply helper."""
import errno
import importlib.machinery
import importlib.util
import json
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import shutil
import socket
import stat
import sys
import tempfile
import unittest
import urllib.error

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("walkie-reply")
loader = importlib.machinery.SourceFileLoader("walkie_reply", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
walkie_reply = importlib.util.module_from_spec(spec)
loader.exec_module(walkie_reply)


class FakeResponse:
    def __init__(self, value, status=200):
        self.status = status
        self.value = value
        self.closed = False

    def read(self):
        return self.value

    def close(self):
        self.closed = True


class BrokenResponse(FakeResponse):
    def read(self):
        raise OSError("read failed")


class WalkieReplyTests(unittest.TestCase):
    def make_token(self, folder):
        token = Path(folder) / "reply-token"
        token.write_text("test-secret-token\n", encoding="utf-8")
        return token

    def test_payload_preserves_codex_destination_images_and_text(self):
        with tempfile.TemporaryDirectory() as folder:
            token = self.make_token(folder)
            first = Path(folder) / "first.png"
            second = Path(folder) / "second image.jpg"
            first.write_bytes(b"png")
            second.write_bytes(b"jpg")
            payload = walkie_reply.make_payload(
                ["A concise", "answer", "--thread", "thread-123",
                 "--image", str(first), "-i", str(second)],
                token_path=token, env={}, project_root="/tmp/demo-project",
            )
            self.assertEqual(payload, {
                "token": "test-secret-token",
                "text": "A concise answer",
                "from": "demo-project",
                "tty": "codex:thread-123",
                "images": [str(first), str(second)],
            })

    def test_thread_environment_and_stdin_are_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            payload = walkie_reply.make_payload(
                [], token_path=self.make_token(folder), stdin_text="piped answer\n",
                env={"CODEX_THREAD_ID": "thread-from-env"}, tty="ttys006",
            )
            self.assertEqual(payload["text"], "piped answer")
            self.assertEqual(payload["tty"], "codex:thread-from-env")
            self.assertEqual(payload["images"], [])

    def test_refused_listener_falls_through_to_next_port(self):
        calls = []
        response = FakeResponse(b'{"ok":true,"shown":true}')

        def opener(request, timeout):
            calls.append((request.full_url, timeout))
            if len(calls) == 1:
                raise urllib.error.URLError(
                    ConnectionRefusedError(errno.ECONNREFUSED, "refused")
                )
            return response

        answer = walkie_reply.post_reply({"text": "answer"}, ports=(8917, 8918), opener=opener)
        self.assertEqual(answer, {"ok": True, "shown": True})
        self.assertEqual([call[0] for call in calls], [
            "http://127.0.0.1:8917/reply", "http://127.0.0.1:8918/reply",
        ])
        self.assertEqual([call[1] for call in calls], [8, 8])
        self.assertTrue(response.closed)

    def test_permission_denial_explains_escalation_without_retrying(self):
        for error in (PermissionError(errno.EPERM, "blocked"),
                      urllib.error.URLError(PermissionError(errno.EACCES, "blocked"))):
            calls = []
            def opener(request, timeout):
                calls.append(request.full_url)
                raise error
            with self.assertRaisesRegex(walkie_reply.ReplyError,
                                        "denied by the sandbox.*request permission.*before delivery"):
                walkie_reply.post_reply({}, ports=(8917, 8918), opener=opener)
            self.assertEqual(calls, ["http://127.0.0.1:8917/reply"])

    def test_timeout_is_unknown_and_never_retried(self):
        for timeout_error in (socket.timeout("timed out"),
                              urllib.error.URLError(socket.timeout("timed out"))):
            calls = []

            def opener(request, timeout):
                calls.append(request.full_url)
                raise timeout_error

            with self.assertRaisesRegex(walkie_reply.ReplyError, "request timed out.*check the reply bubble"):
                walkie_reply.post_reply({}, ports=(8917, 8918), opener=opener)
            self.assertEqual(calls, ["http://127.0.0.1:8917/reply"])

    def test_malformed_acknowledgement_is_unknown_and_never_retried(self):
        calls = []

        def opener(request, timeout):
            calls.append(request.full_url)
            return FakeResponse(b"not json")

        with self.assertRaisesRegex(walkie_reply.ReplyError, "response was malformed.*check the reply bubble"):
            walkie_reply.post_reply({}, ports=(8917, 8918), opener=opener)
        self.assertEqual(calls, ["http://127.0.0.1:8917/reply"])

    def test_response_is_closed_even_when_read_fails(self):
        response = BrokenResponse(b"")
        calls = []

        def opener(request, timeout):
            calls.append(request.full_url)
            return response

        with self.assertRaisesRegex(walkie_reply.ReplyError, "response could not be read"):
            walkie_reply.post_reply({}, ports=(8917, 8918), opener=opener)
        self.assertTrue(response.closed)
        self.assertEqual(len(calls), 1)

    def test_unconfirmed_success_is_unknown_and_never_retried(self):
        calls = []

        def opener(request, timeout):
            calls.append(request.full_url)
            return FakeResponse(b'{"shown":true}')

        with self.assertRaisesRegex(walkie_reply.ReplyError, "did not confirm delivery"):
            walkie_reply.post_reply({}, ports=(8917, 8918), opener=opener)
        self.assertEqual(len(calls), 1)

    def test_success_and_suppressed_success_are_distinguished(self):
        ok = walkie_reply.post_reply(
            {}, ports=(8917,), opener=lambda *_args, **_kwargs:
            FakeResponse(b'{"ok":true,"shown":true}')
        )
        suppressed = walkie_reply.post_reply(
            {}, ports=(8917,), opener=lambda *_args, **_kwargs:
            FakeResponse(b'{"ok":true,"shown":false}')
        )
        self.assertTrue(ok["shown"])
        self.assertFalse(suppressed["shown"])

    def test_images_are_staged_for_request_and_removed_after_ack(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            token = self.make_token(root)
            original = root / "source.png"
            original.write_bytes(b"original image bytes")
            cache = root / "cache"
            requests = []

            def opener(request, timeout):
                payload = json.loads(request.data)
                staged = Path(payload["images"][0])
                requests.append((payload, staged, timeout))
                self.assertNotEqual(staged, original)
                self.assertEqual(staged.read_bytes(), b"original image bytes")
                self.assertEqual(stat.S_IMODE(staged.parent.stat().st_mode), 0o700)
                return FakeResponse(b'{"ok":true,"shown":true}')

            with redirect_stdout(StringIO()):
                result = walkie_reply.main(
                    ["answer", "--image", str(original)], token_path=token,
                    env={}, project_root="project", tty="ttys1", opener=opener,
                    ports=(8917,), cache_dir=cache,
                )
            self.assertEqual(result, 0)
            self.assertEqual(len(requests), 1)
            self.assertEqual(requests[0][2], 8)
            self.assertFalse(requests[0][1].parent.exists())
            self.assertEqual(original.read_bytes(), b"original image bytes")

    def test_timeout_keeps_staged_image_and_never_retries(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            token = self.make_token(root)
            original = root / "source.jpg"
            original.write_bytes(b"image survives uncertain delivery")
            cache = root / "cache"
            requests = []

            def opener(request, timeout):
                payload = json.loads(request.data)
                staged = Path(payload["images"][0])
                requests.append(staged)
                raise socket.timeout("test timeout")

            old_out, old_err = sys.stdout, sys.stderr
            try:
                sys.stdout, sys.stderr = StringIO(), StringIO()
                result = walkie_reply.main(
                    ["answer", "--image", str(original)], token_path=token,
                    env={}, project_root="project", tty="ttys1", opener=opener,
                    ports=(8917, 8918), cache_dir=cache,
                )
                error_text = sys.stderr.getvalue()
            finally:
                sys.stdout, sys.stderr = old_out, old_err
            self.assertEqual(result, 1)
            self.assertEqual(len(requests), 1)
            staged = requests[0]
            self.assertTrue(staged.is_file())
            self.assertEqual(staged.read_bytes(), b"image survives uncertain delivery")
            self.assertIn(str(staged.parent), error_text)
            self.assertEqual(original.read_bytes(), b"image survives uncertain delivery")
            shutil.rmtree(staged.parent)

    def test_missing_token_fails_without_network_or_token_logging(self):
        with tempfile.TemporaryDirectory() as folder:
            out, err = [], []
            calls = []
            old_out, old_err = sys.stdout, sys.stderr
            try:
                from io import StringIO
                sys.stdout, sys.stderr = StringIO(), StringIO()
                result = walkie_reply.main(
                    ["answer"], token_path=Path(folder) / "missing-token",
                    env={}, project_root="project", tty="ttys1",
                    opener=lambda *args, **kwargs: calls.append(args),
                )
                out.append(sys.stdout.getvalue())
                err.append(sys.stderr.getvalue())
            finally:
                sys.stdout, sys.stderr = old_out, old_err
            self.assertEqual(result, 1)
            self.assertFalse(calls)
            self.assertIn("has not made", err[0])
            self.assertNotIn("test-secret-token", err[0])
            self.assertEqual(out[0], "")

    def test_malformed_arguments_are_reported_without_traceback(self):
        from io import StringIO
        old_out, old_err = sys.stdout, sys.stderr
        try:
            sys.stdout, sys.stderr = StringIO(), StringIO()
            result = walkie_reply.main(
                ["--thread"], token_path="unused", env={},
                opener=lambda *_args, **_kwargs: self.fail("must not send"),
            )
            error_text = sys.stderr.getvalue()
        finally:
            sys.stdout, sys.stderr = old_out, old_err
        self.assertEqual(result, 1)
        self.assertIn("--thread needs a Codex conversation ID", error_text)
        self.assertNotIn("Traceback", error_text)


if __name__ == "__main__":
    unittest.main()
