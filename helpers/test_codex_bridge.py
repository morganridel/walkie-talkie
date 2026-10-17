import base64
import hashlib
import json
import os
from types import SimpleNamespace
from pathlib import Path
import socket
import sqlite3
import subprocess
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

from helpers import codex_bridge


HERE = Path(__file__).resolve().parent
BRIDGE = HERE / "codex_bridge.py"


FAKE_CODEX = r'''#!/usr/bin/python3
import json, os, sys

if "--version" in sys.argv:
    print("codex-cli 0.test")
    raise SystemExit

log = os.environ.get("FAKE_CODEX_LOG")
status = os.environ.get("FAKE_THREAD_STATUS", "idle")

def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)

for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    params = message.get("params") or {}
    mid = message.get("id")
    if log and method:
        with open(log, "a") as handle:
            handle.write(json.dumps({"method": method, "params": params}) + "\n")
    if mid is None:
        continue
    if method == "initialize":
        emit({"id": mid, "result": {"serverInfo": {"name": "fake"}}})
    elif method == "thread/list":
        emit({"id": mid, "result": {"data": [{
            "id": "11111111-1111-4111-8111-111111111111", "name": "Live chat",
            "cwd": "/tmp/project", "status": {"type": status}, "source": "cli",
            "projectId": "p1", "createdAt": 10, "updatedAt": 20, "model": "fake",
        }], "nextCursor": None}})
    elif method == "thread/read":
        emit({"id": mid, "result": {"thread": {
            "id": params["threadId"], "name": "Live chat", "cwd": "/tmp/project",
            "status": {"type": status}, "source": "cli", "createdAt": 10,
            "updatedAt": 20, "model": "fake", "projectId": "p1",
        }}})
    elif method == "thread/turns/list":
        emit({"id": mid, "result": {"data": [{
            "id": "22222222-2222-4222-8222-222222222222",
            "status": "inProgress", "items": [],
        }]}})
    elif method == "thread/resume":
        emit({"id": mid, "result": {"thread": {"id": params["threadId"]}}})
    elif method == "thread/start":
        emit({"id": mid, "result": {
            "thread": {"id": "33333333-3333-4333-8333-333333333333", "model": "fake"},
            "model": params.get("model") or "fake-model",
        }})
    elif method == "turn/start" and params.get("threadId") == "33333333-3333-4333-8333-333333333333":
        turn = "44444444-4444-4444-8444-444444444444"
        if os.environ.get("FAKE_QUICK_TOOL"):
            emit({"id": mid, "result": {"turn": {"id": turn, "status": "inProgress", "items": []}}})
            emit({"method": "item/started", "params": {
                "threadId": params["threadId"], "turnId": turn,
                "item": {"id": "tool1", "type": "commandExecution", "command": "cat secret"},
            }})
            continue
        emit({"method": "item/agentMessage/delta", "params": {
            "threadId": params["threadId"], "turnId": turn, "itemId": "i1", "delta": "Hi",
        }})
        emit({"id": mid, "result": {"turn": {"id": turn, "status": "inProgress", "items": []}}})
        emit({"method": "item/agentMessage/delta", "params": {
            "threadId": params["threadId"], "turnId": turn, "itemId": "i1", "delta": " there",
        }})
        emit({"method": "turn/completed", "params": {
            "threadId": params["threadId"], "turn": {"id": turn, "status": "completed", "items": []},
        }})
    elif method == "turn/start":
        emit({"id": mid, "result": {"turn": {
            "id": "55555555-5555-4555-8555-555555555555", "status": "inProgress", "items": [],
        }}})
    elif method == "turn/steer":
        emit({"id": mid, "result": {"turnId": params["expectedTurnId"]}})
    elif method == "turn/interrupt":
        emit({"id": mid, "result": {}})
    else:
        emit({"id": mid, "error": {"code": -32601, "message": "no " + str(method)}})
'''


class CodexBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / "codex-home"
        self.home.mkdir()
        self.fake = self.root / "codex"
        self.fake.write_text(FAKE_CODEX)
        self.fake.chmod(0o755)
        self.log = self.root / "rpc.jsonl"
        self.env = os.environ.copy()
        self.env.update({
            "CODEX_BIN": str(self.fake),
            "CODEX_HOME": str(self.home),
            "FAKE_CODEX_LOG": str(self.log),
            "WALKIE_CODEX_TTY_DIR": str(self.root / "tty-map"),
            "WALKIE_BACKGROUND_HOME": str(self.root / "background"),
            "WALKIE_BACKGROUND_MONITOR": "0",
        })
        self.make_state()
        self.make_history()
        self.sock = None
        self.ipc_server = None
        self.ipc_methods = []
        self.ipc_requests = []
        self.ipc_errors = {}

    def tearDown(self):
        if self.sock:
            self.sock.close()
        if self.ipc_server:
            self.ipc_server.close()
        self.temp.cleanup()

    def make_socket(self):
        path = self.root / "control.sock"
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(str(path))
        self.sock.listen(1)
        self.env["CODEX_APP_SERVER_SOCKET"] = str(path)

        def exact(connection, size):
            data = b""
            while len(data) < size:
                chunk = connection.recv(size - len(data))
                if not chunk:
                    return None
                data += chunk
            return data

        def receive(connection):
            head = exact(connection, 2)
            if not head:
                return None
            length = head[1] & 0x7f
            if length == 126:
                length = struct.unpack(">H", exact(connection, 2))[0]
            elif length == 127:
                length = struct.unpack(">Q", exact(connection, 8))[0]
            mask = exact(connection, 4) if head[1] & 0x80 else None
            data = exact(connection, length)
            if data is None:
                return None
            if mask:
                data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
            if head[0] & 0x0f == 8:
                return None
            return json.loads(data)

        def send(connection, value):
            data = json.dumps(value, separators=(",", ":")).encode()
            if len(data) < 126:
                header = bytes((0x81, len(data)))
            else:
                header = bytes((0x81, 126)) + struct.pack(">H", len(data))
            connection.sendall(header + data)

        def serve():
            connection, _ = self.sock.accept()
            with connection:
                request = b""
                while b"\r\n\r\n" not in request:
                    request += connection.recv(4096)
                key_line = next(line for line in request.split(b"\r\n")
                                if line.lower().startswith(b"sec-websocket-key:"))
                key = key_line.split(b":", 1)[1].strip()
                accept = base64.b64encode(hashlib.sha1(
                    key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
                connection.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                                   b"Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
                while True:
                    message = receive(connection)
                    if message is None:
                        return
                    method = message.get("method")
                    params = message.get("params") or {}
                    mid = message.get("id")
                    if method:
                        with open(self.log, "a") as handle:
                            handle.write(json.dumps({"method": method, "params": params}) + "\n")
                    if mid is None:
                        continue
                    status = self.env.get("FAKE_THREAD_STATUS", "idle")
                    if method == "initialize": result = {"serverInfo": {"name": "fake"}}
                    elif method == "thread/list": result = {"data": [{
                        "id": "11111111-1111-4111-8111-111111111111", "name": "Live chat",
                        "cwd": "/tmp/project", "status": {"type": status}, "source": "cli",
                        "projectId": "p1", "createdAt": 10, "updatedAt": 20, "model": "fake",
                    }], "nextCursor": None}
                    elif method == "thread/read": result = {"thread": {
                        "id": params["threadId"], "name": "Live chat", "cwd": "/tmp/project",
                        "status": {"type": status}, "source": "cli", "createdAt": 10,
                        "updatedAt": 20, "model": "fake", "projectId": "p1",
                    }}
                    elif method == "thread/turns/list": result = {"data": [{
                        "id": "22222222-2222-4222-8222-222222222222",
                        "status": "inProgress", "items": [],
                    }]}
                    elif method == "turn/start": result = {"turn": {
                        "id": "55555555-5555-4555-8555-555555555555",
                        "status": "inProgress", "items": [],
                    }}
                    elif method == "turn/steer": result = {"turnId": params["expectedTurnId"]}
                    else:
                        send(connection, {"id": mid, "error": {"code": -32601,
                                                               "message": "no " + str(method)}})
                        continue
                    send(connection, {"id": mid, "result": result})

        threading.Thread(target=serve, daemon=True).start()

    def test_control_socket_accepts_owned_symlink_to_private_socket(self):
        source_directory = self.root / "control"
        target_directory = self.root / "daemon"
        source_directory.mkdir(mode=0o700)
        target_directory.mkdir(mode=0o700)
        target = target_directory / "server.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(str(target))
            link = source_directory / "control.sock"
            link.symlink_to(target)
            with mock.patch.dict(os.environ, {"CODEX_APP_SERVER_SOCKET": str(link)}):
                self.assertEqual(codex_bridge.control_socket(), target.resolve())
        finally:
            server.close()

    def test_control_socket_rejects_symlink_into_unsafe_directory(self):
        source_directory = self.root / "control"
        target_directory = self.root / "daemon"
        source_directory.mkdir(mode=0o700)
        target_directory.mkdir(mode=0o700)
        target = target_directory / "server.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(str(target))
            target_directory.chmod(0o777)
            link = source_directory / "control.sock"
            link.symlink_to(target)
            with mock.patch.dict(os.environ, {"CODEX_APP_SERVER_SOCKET": str(link)}):
                self.assertIsNone(codex_bridge.control_socket())
        finally:
            target_directory.chmod(0o700)
            server.close()

    def test_control_socket_rejects_symlink_to_regular_file(self):
        source_directory = self.root / "control"
        target_directory = self.root / "daemon"
        source_directory.mkdir(mode=0o700)
        target_directory.mkdir(mode=0o700)
        target = target_directory / "not-a-socket"
        target.write_text("not a socket")
        link = source_directory / "control.sock"
        link.symlink_to(target)
        with mock.patch.dict(os.environ, {"CODEX_APP_SERVER_SOCKET": str(link)}):
            self.assertIsNone(codex_bridge.control_socket())

    def make_desktop_ipc(self):
        directory = self.root / "ipc"
        directory.mkdir(mode=0o700)
        path = directory / "ipc.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(path))
        server.listen(1)
        self.ipc_server = server
        self.env["CODEX_DESKTOP_IPC_SOCKET"] = str(path)

        def receive(connection):
            header = connection.recv(4)
            if not header:
                return None
            length = struct.unpack("<I", header)[0]
            data = b""
            while len(data) < length:
                data += connection.recv(length - len(data))
            return json.loads(data)

        def send(connection, value):
            data = json.dumps(value, separators=(",", ":")).encode()
            connection.sendall(struct.pack("<I", len(data)) + data)

        def serve():
            connection, _ = server.accept()
            with connection:
                while True:
                    request = receive(connection)
                    if request is None:
                        return
                    method = request["method"]
                    self.ipc_methods.append(method)
                    self.ipc_requests.append(request)
                    if method in self.ipc_errors:
                        send(connection, {
                            "type": "response", "requestId": request["requestId"],
                            "resultType": "error", "error": self.ipc_errors[method],
                        })
                        continue
                    if method == "thread-follower-steer-turn":
                        params = request.get("params") or {}
                        restore = params.get("restoreMessage") or {}
                        context = restore.get("context") or {}
                        required_arrays = (
                            context.get("workspaceRoots"), context.get("addedFiles"),
                            context.get("fileAttachments"),
                            context.get("commentAttachments"),
                            context.get("imageAttachments"),
                        )
                        text_items = [value for value in params.get("input", [])
                                      if value.get("type") == "text"]
                        if (any(not isinstance(value, list) for value in required_arrays)
                                or any(not isinstance(value.get("text_elements"), list)
                                       for value in text_items)):
                            send(connection, {
                                "type": "response", "requestId": request["requestId"],
                                "resultType": "error",
                                "error": "invalid native composer message",
                            })
                            continue
                    if method == "initialize":
                        result = {"clientId": "walkie-client"}
                    elif method == "thread-owner-discovery":
                        result = {"supportsUntrustedAppInput": True}
                    elif method == "thread-follower-start-turn":
                        result = {"result": {"turn": {"id": "desktop-turn"}}}
                    elif method == "thread-follower-steer-turn":
                        result = {"result": {"turnId": "desktop-active-turn"}}
                    else:
                        result = {"ok": True}
                    send(connection, {"type": "response", "requestId": request["requestId"],
                                      "resultType": "success", "method": method,
                                      "handledByClientId": "owner-window", "result": result})

        threading.Thread(target=serve, daemon=True).start()

    def make_state(self):
        db = sqlite3.connect(self.home / "state_5.sqlite")
        db.executescript("""
            CREATE TABLE threads (
                id TEXT PRIMARY KEY, rollout_path TEXT, created_at INTEGER,
                updated_at INTEGER, created_at_ms INTEGER, updated_at_ms INTEGER,
                source TEXT, cwd TEXT, title TEXT, name TEXT, preview TEXT,
                first_user_message TEXT, project_id TEXT, model TEXT, git_branch TEXT,
                archived INTEGER, recency_at_ms INTEGER, tokens_used INTEGER,
                has_user_event INTEGER
            );
            CREATE TABLE projects (
                id TEXT PRIMARY KEY, name TEXT, metadata TEXT, position INTEGER,
                created_at_ms INTEGER, updated_at_ms INTEGER
            );
            CREATE TABLE project_roots (
                project_id TEXT, position INTEGER, path TEXT
            );
        """)
        now = int(time.time() * 1000)
        db.execute("""
            INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, ("11111111-1111-4111-8111-111111111111", "/tmp/rollout.jsonl",
              now // 1000, now // 1000, now, now, "cli", "/tmp/project/sub",
              "Stored chat", "Named chat", "preview", "hello", "p1", "fake",
              "main", 0, now, 1234, 1))
        db.execute("INSERT INTO projects VALUES (?,?,?,?,?,?)",
                   ("p1", "Project", "{}", 0, now, now))
        db.execute("INSERT INTO project_roots VALUES (?,?,?)", ("p1", 0, "/tmp/project"))
        db.commit()
        db.close()

    def make_history(self):
        db = sqlite3.connect(self.home / "thread_history_1.sqlite")
        db.executescript("""
            CREATE TABLE thread_turns (
                thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT,
                error_json TEXT, started_at INTEGER, completed_at INTEGER, duration_ms INTEGER
            );
            CREATE TABLE thread_items (
                thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER,
                created_at_ms INTEGER, item_json TEXT, item_type TEXT
            );
        """)
        thread = "11111111-1111-4111-8111-111111111111"
        turn = "22222222-2222-4222-8222-222222222222"
        now = int(time.time() * 1000)
        db.execute("INSERT INTO thread_turns VALUES (?,?,?,?,?,?,?,?)",
                   (thread, turn, 1, "completed", None, now // 1000, now // 1000, 10))
        items = [
            ("u", 1, {"type": "userMessage", "content": [{"type": "text", "text": "my blue bicycle"}]}, "userMessage"),
            ("a", 2, {"type": "agentMessage", "text": "The blue bicycle is ready"}, "agentMessage"),
            ("r", 3, {"type": "reasoning", "content": ["blue bicycle secret"]}, "reasoning"),
        ]
        for item_id, ordinal, payload, item_type in items:
            db.execute("INSERT INTO thread_items VALUES (?,?,?,?,?,?,?)",
                       (thread, turn, item_id, ordinal, now, json.dumps(payload), item_type))
        db.commit()
        db.close()

    def run_bridge(self, *arguments, input_text=None, env=None):
        return subprocess.run(
            [sys.executable, str(BRIDGE), *arguments],
            input=input_text, capture_output=True, text=True, timeout=10,
            env=env or self.env,
        )

    def json_output(self, result):
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return json.loads(result.stdout.strip().splitlines()[-1])

    def rpc_methods(self):
        return [json.loads(line)["method"] for line in self.log.read_text().splitlines()]

    @staticmethod
    def rpc_client_for_thread(status="idle"):
        class FakeRpcClient:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def request(self, method, params):
                if method != "thread/read":
                    raise AssertionError(method)
                return {"thread": {
                    "id": params["threadId"], "name": "CLI chat",
                    "cwd": "/tmp/project", "status": {"type": status},
                    "source": "cli", "createdAt": 10, "updatedAt": 20,
                    "model": "fake", "projectId": "p1",
                }}

        return FakeRpcClient

    def test_list_falls_back_to_read_only_database(self):
        result = self.json_output(self.run_bridge("list", "--limit", "5"))
        self.assertFalse(result["live"])
        self.assertEqual(result["threads"][0]["title"], "Named chat")
        self.assertIsNone(result["threads"][0]["busy"])

    def test_unknown_server_status_never_implies_live_ownership(self):
        row = codex_bridge.thread_row({
            "id": "11111111-1111-4111-8111-111111111111",
            "status": {"type": "unknown"}, "source": "cli",
        }, live=True)
        self.assertFalse(row["live"])
        self.assertIsNone(row["busy"])

    def test_list_live_only_uses_verified_desktop_owner(self):
        self.make_desktop_ipc()
        result = self.json_output(self.run_bridge("list", "--limit", "5", "--live-only"))
        self.assertTrue(result["live"])
        self.assertEqual(len(result["threads"]), 1)
        self.assertTrue(result["threads"][0]["live"])
        self.assertTrue(result["threads"][0]["ttyOwner"])
        self.assertEqual(result["threads"][0]["tty"],
                         "codex:11111111-1111-4111-8111-111111111111")

    def test_list_uses_shared_proxy_when_available(self):
        self.make_socket()
        result = self.json_output(self.run_bridge("list", "--limit", "5"))
        self.assertFalse(result["live"])
        self.assertEqual(result["threads"][0]["title"], "Live chat")
        self.assertFalse(result["threads"][0]["live"])
        self.assertIn("thread/list", self.rpc_methods())

    def test_archive_inclusive_native_list_merges_pages_filters_guardian_and_deduplicates(self):
        calls = []

        class FakeRpcClient:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def request(self, method, params):
                calls.append((method, dict(params)))
                if method != "thread/list":
                    raise AssertionError(method)
                archived, cursor = params["archived"], params.get("cursor")
                if not archived and cursor is None:
                    return {"data": [
                        {"id": "new-active", "name": "Active", "cwd": "/work",
                         "updatedAt": 30, "source": "cli"},
                        {"id": "new-active", "name": "Duplicate row", "cwd": "/work",
                         "updatedAt": 29, "source": "cli"},
                        {"id": "guardian", "threadSource": "guardian_review",
                         "source": "appServer", "cwd": "/work"},
                    ], "nextCursor": "active-page-2"}
                if archived and cursor is None:
                    return {"data": [
                        {"id": "old-archived", "name": "Archived", "cwd": "/work",
                         "updatedAt": 10, "source": "cli", "archived": True},
                    ], "nextCursor": "archived-page-2"}
                if not archived and cursor == "active-page-2":
                    return {"data": [
                        {"id": "middle-active", "name": "Middle", "cwd": "/work",
                         "updatedAt": 20, "source": "cli"},
                    ], "nextCursor": None}
                if archived and cursor == "archived-page-2":
                    return {"data": [
                        {"id": "oldest-archived", "name": "Older archive", "cwd": "/work",
                         "updatedAt": 5, "source": "cli", "archived": True},
                    ], "nextCursor": None}
                raise AssertionError((archived, cursor))

        noop = lambda rows: rows
        with mock.patch.object(codex_bridge, "RpcClient", FakeRpcClient), \
             mock.patch.object(codex_bridge, "add_ttys", noop), \
             mock.patch.object(codex_bridge, "enrich_background_owners", noop), \
             mock.patch.object(codex_bridge, "enrich_desktop_owners", noop):
            first = codex_bridge.list_threads(SimpleNamespace(
                limit=1, cursor=None, cwd=None, project=None, query=None,
                live_only=False, include_archived=True))
            second = codex_bridge.list_threads(SimpleNamespace(
                limit=1, cursor=first["nextCursor"], cwd=None, project=None,
                query=None, live_only=False, include_archived=True))
            third = codex_bridge.list_threads(SimpleNamespace(
                limit=1, cursor=second["nextCursor"], cwd=None, project=None,
                query=None, live_only=False, include_archived=True))
            fourth = codex_bridge.list_threads(SimpleNamespace(
                limit=1, cursor=third["nextCursor"], cwd=None, project=None,
                query=None, live_only=False, include_archived=True))

        self.assertEqual([row["id"] for result in (first, second, third, fourth)
                          for row in result["threads"]],
                         ["new-active", "middle-active", "old-archived", "oldest-archived"])
        self.assertTrue(third["threads"][0]["archived"])
        self.assertTrue(fourth["threads"][0]["archived"])
        self.assertEqual(len({row["id"] for result in (first, second, third, fourth)
                              for row in result["threads"]}), 4)
        self.assertIsNone(fourth["nextCursor"])
        self.assertTrue(all(params["sourceKinds"] == codex_bridge.ALL_SOURCE_KINDS
                            for method, params in calls if method == "thread/list"))
        self.assertEqual({params["archived"] for method, params in calls
                          if method == "thread/list"}, {False, True})
        cursor_state = json.loads(base64.urlsafe_b64decode(
            first["nextCursor"].split(":", 1)[1] + "==="))
        self.assertEqual(cursor_state, {"phase": "active", "cursor": "active-page-2"})
        # Cursor goes over argv to the Swift host, so keep it bounded and free
        # of titles/previews or other row metadata.
        self.assertLess(len(first["nextCursor"]), 256)
        for private_value in ("Active", "Duplicate row", "preview", "new-active"):
            self.assertNotIn(private_value, first["nextCursor"])

    def test_catalog_search_command_uses_selected_folder_and_all_history(self):
        old_thread = "old-alpha"
        beta_thread = "new-beta"
        now = int(time.time() * 1000)
        db = sqlite3.connect(self.home / "state_5.sqlite")
        for thread_id, cwd, updated in ((old_thread, "/tmp/project", 1),
                                        (beta_thread, "/tmp/other", now)):
            db.execute("""INSERT INTO threads VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                       (thread_id, f"/rollout/{thread_id}", updated // 1000,
                        updated // 1000, updated, updated, "cli", cwd, thread_id,
                        thread_id, "", "", "p1", "fake", "main", 0, updated, 0, 0))
        db.commit()
        db.close()
        history = sqlite3.connect(self.home / "thread_history_1.sqlite")
        for thread_id, ordinal, role, text in (
                (old_thread, 1, "userMessage", "a rare old-folder marker"),
                (old_thread, 2, "agentMessage", "the rare marker answer"),
                (beta_thread, 1, "userMessage", "a rare old-folder marker")):
            item = ({"type": "userMessage", "content": [{"type": "text", "text": text}]}
                    if role == "userMessage" else {"type": "agentMessage", "text": text})
            history.execute("INSERT INTO thread_items VALUES (?, ?, ?, ?, ?, ?, ?)",
                            (thread_id, "turn", f"item-{ordinal}", ordinal, ordinal,
                             json.dumps(item), role))
        history.commit()
        history.close()
        with mock.patch.object(codex_bridge, "codex_home", return_value=self.home):
            parsed = codex_bridge.build_parser().parse_args([
                "catalog-search", "--cwd", "/tmp/project", "--query", "rare marker",
                "--limit", "10"])
            result = codex_bridge.catalog_search(parsed)
        self.assertEqual([row["session"] for row in result["threads"]], [old_thread])
        self.assertEqual(result["threads"][0]["hits"], 2)
        self.assertIsNone(result["nextCursor"])

    def test_recent_picker_uses_sqlite_without_daemon_or_owner_probes(self):
        args = codex_bridge.build_parser().parse_args(["recent", "--limit", "10"])
        with mock.patch.object(codex_bridge, "db_path", side_effect=lambda name: self.home / name), \
             mock.patch.object(codex_bridge, "RpcClient", side_effect=AssertionError("RPC used")), \
             mock.patch.object(codex_bridge, "add_ttys", side_effect=AssertionError("TTY scan used")), \
             mock.patch.object(codex_bridge, "enrich_background_owners", side_effect=AssertionError("owner scan used")), \
             mock.patch.object(codex_bridge, "enrich_desktop_owners", side_effect=AssertionError("desktop scan used")):
            result = codex_bridge.recent_threads(args)
        self.assertEqual([row["id"] for row in result["threads"]],
                         ["11111111-1111-4111-8111-111111111111"])
        row = result["threads"][0]
        self.assertEqual(row["source"], "cli")
        self.assertIsNone(row["busy"])
        self.assertFalse(row["live"])
        self.assertIsNone(result["nextCursor"])

    def test_latest_preview_is_sqlite_only_and_rejects_guardian(self):
        thread_id = "11111111-1111-4111-8111-111111111111"
        args = SimpleNamespace(thread=thread_id)
        with mock.patch.object(codex_bridge, "db_path", side_effect=lambda name: self.home / name), \
             mock.patch.object(codex_bridge, "RpcClient", side_effect=AssertionError("RPC used")):
            result = codex_bridge.latest_thread_preview(args)
        self.assertEqual(result["threadId"], thread_id)
        self.assertEqual(result["turns"][0]["items"][0]["type"], "userMessage")
        self.assertEqual(result["turns"][0]["items"][1]["type"], "agentMessage")

        state = sqlite3.connect(self.home / "state_5.sqlite")
        state.execute("ALTER TABLE threads ADD COLUMN thread_source TEXT")
        state.execute("UPDATE threads SET thread_source = 'guardian_review' WHERE id = ?",
                      (thread_id,))
        state.commit()
        state.close()
        with mock.patch.object(codex_bridge, "db_path", side_effect=lambda name: self.home / name), \
             mock.patch.object(codex_bridge, "RpcClient", side_effect=AssertionError("RPC used")), \
             mock.patch.object(codex_bridge.codex_catalog, "sqlite_latest_visible_turn",
                               side_effect=AssertionError("guardian history read")):
            with self.assertRaises(codex_bridge.BridgeError) as raised:
                codex_bridge.latest_thread_preview(args)
        self.assertEqual(raised.exception.code, "thread_hidden")

    def test_history_page_refuses_guardian_before_requesting_turn_items(self):
        thread = "guardian-thread"

        class FakeRpcClient:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def request(self, method, params):
                if method == "thread/read":
                    return {"thread": {"id": thread,
                                       "threadSource": "guardian_review",
                                       "source": "appServer"}}
                raise AssertionError("guardian preview must be refused before history read")

        with mock.patch.object(codex_bridge, "RpcClient", FakeRpcClient):
            with self.assertRaises(codex_bridge.BridgeError) as raised:
                codex_bridge.history_page(SimpleNamespace(
                    thread=thread, limit=10, cursor=None, direction="desc"))
        self.assertEqual(raised.exception.code, "thread_hidden")

    def test_offline_exact_thread_lookup_includes_archived_and_hides_guardian(self):
        thread = "11111111-1111-4111-8111-111111111111"
        db = sqlite3.connect(self.home / "state_5.sqlite")
        db.execute("ALTER TABLE threads ADD COLUMN thread_source TEXT")
        db.execute("UPDATE threads SET archived = 1 WHERE id = ?", (thread,))
        db.commit()
        db.close()

        class OfflineRpcClient:
            def __enter__(self):
                raise codex_bridge.BridgeError(
                    "shared daemon unavailable", code="shared_daemon_unavailable")

            def __exit__(self, *_):
                pass

        noop = lambda rows: rows
        with mock.patch.object(codex_bridge, "codex_home", return_value=self.home), \
             mock.patch.object(codex_bridge, "RpcClient", OfflineRpcClient), \
             mock.patch.object(codex_bridge, "add_ttys", noop), \
             mock.patch.object(codex_bridge, "enrich_background_owners", noop), \
             mock.patch.object(codex_bridge, "enrich_desktop_owners", noop):
            archived = codex_bridge.one_thread(thread)
        self.assertTrue(archived["archived"])

        db = sqlite3.connect(self.home / "state_5.sqlite")
        db.execute("UPDATE threads SET source = ? WHERE id = ?", (
            json.dumps({"subAgent": {"other": "guardian"}}), thread))
        db.commit()
        db.close()
        with mock.patch.object(codex_bridge, "codex_home", return_value=self.home), \
             mock.patch.object(codex_bridge, "RpcClient", OfflineRpcClient):
            with self.assertRaises(codex_bridge.BridgeError) as raised:
                codex_bridge.one_thread(thread)
        self.assertEqual(raised.exception.code, "thread_hidden")

    def test_offline_archived_catalog_offset_cursor_stays_on_sqlite_when_rpc_returns(self):
        db = sqlite3.connect(self.home / "state_5.sqlite")
        db.execute("UPDATE threads SET archived = 1")
        now = int(time.time() * 1000)
        for index in range(105):
            thread_id = f"offline-archived-{index:03d}"
            db.execute("""INSERT INTO threads VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                       (thread_id, f"/rollout/{thread_id}", now // 1000,
                        now // 1000, now, now, "cli", "/tmp/project", thread_id,
                        thread_id, "private preview", "", "p1", "fake", "main",
                        1, now - index, 0, 0))
        db.commit()
        db.close()

        class OfflineRpcClient:
            def __enter__(self):
                raise codex_bridge.BridgeError(
                    "shared daemon unavailable", code="shared_daemon_unavailable")

            def __exit__(self, *_):
                pass

        class NewlyAvailableRpcClient:
            def __init__(self):
                raise AssertionError("SQLite offset cursor must not switch sources")

        noop = lambda rows: rows
        args = SimpleNamespace(limit=100, cursor=None, cwd=None, project=None,
                               query=None, live_only=False, include_archived=True)
        with mock.patch.object(codex_bridge, "codex_home", return_value=self.home), \
             mock.patch.object(codex_bridge, "RpcClient", OfflineRpcClient), \
             mock.patch.object(codex_bridge, "add_ttys", noop), \
             mock.patch.object(codex_bridge, "enrich_background_owners", noop), \
             mock.patch.object(codex_bridge, "enrich_desktop_owners", noop):
            first = codex_bridge.list_threads(args)

        self.assertEqual(len(first["threads"]), 100)
        self.assertEqual(first["nextCursor"], "offset:100")
        args.cursor = first["nextCursor"]
        with mock.patch.object(codex_bridge, "codex_home", return_value=self.home), \
             mock.patch.object(codex_bridge, "RpcClient", NewlyAvailableRpcClient), \
             mock.patch.object(codex_bridge, "add_ttys", noop), \
             mock.patch.object(codex_bridge, "enrich_background_owners", noop), \
             mock.patch.object(codex_bridge, "enrich_desktop_owners", noop):
            second = codex_bridge.list_threads(args)

        self.assertEqual(len(second["threads"]), 6)
        self.assertTrue(all(row["archived"] for row in second["threads"]))
        self.assertIsNone(second["nextCursor"])

    def test_one_thread_shared_read_keeps_verified_cli_tty(self):
        thread = "11111111-1111-4111-8111-111111111111"
        record = {"tty": "/dev/ttys007", "pid": 42,
                  "sourceResolution": "sidecar"}
        with mock.patch.object(codex_bridge, "RpcClient", self.rpc_client_for_thread()), \
             mock.patch.object(codex_bridge, "sidecar_tty_map",
                               return_value={thread: record}), \
             mock.patch.object(codex_bridge, "codex_home", return_value=self.home):
            row = codex_bridge.one_thread(thread)
        self.assertTrue(row["live"])
        self.assertTrue(row["ttyOwner"])
        self.assertEqual(row["tty"], "/dev/ttys007")
        self.assertEqual(row["source"], "cli")
        self.assertEqual(row["sourceResolution"], "sidecar")
        self.assertEqual(row["status"], "idle")
        self.assertFalse(row["busy"])

    def test_one_thread_unproven_cli_mapping_is_saved_not_live(self):
        thread = "11111111-1111-4111-8111-111111111111"
        with mock.patch.object(codex_bridge, "RpcClient", self.rpc_client_for_thread()), \
             mock.patch.object(codex_bridge, "sidecar_tty_map", return_value={}), \
             mock.patch.object(codex_bridge, "enrich_desktop_owners",
                               side_effect=lambda rows: rows):
            row = codex_bridge.one_thread(thread)
        self.assertFalse(row["live"])
        self.assertFalse(row["ttyOwner"])
        self.assertIsNone(row["tty"])
        self.assertIsNone(row["busy"])

    def test_exact_thread_activation_confirms_desktop_owner(self):
        self.make_desktop_ipc()
        result = self.json_output(self.run_bridge(
            "thread", "--id", "11111111-1111-4111-8111-111111111111",
            "--require-owner-state"))
        self.assertEqual(result["ownerState"], "live")
        self.assertTrue(result["live"])
        self.assertTrue(result["ttyOwner"])
        self.assertEqual(result["tty"],
                         "codex:11111111-1111-4111-8111-111111111111")

    def test_exact_thread_activation_confirms_absent_desktop_owner(self):
        self.ipc_errors["thread-owner-discovery"] = "no-client-found"
        self.make_desktop_ipc()
        result = self.json_output(self.run_bridge(
            "thread", "--id", "11111111-1111-4111-8111-111111111111",
            "--require-owner-state"))
        self.assertEqual(result["ownerState"], "closed")
        self.assertFalse(result["live"])

    def test_exact_thread_activation_fails_when_ownership_is_unknown(self):
        result = self.run_bridge(
            "thread", "--id", "11111111-1111-4111-8111-111111111111",
            "--require-owner-state")
        self.assertEqual(result.returncode, 2)
        error = json.loads(result.stdout)
        self.assertEqual(error["code"], "thread_ownership_unknown")
        self.assertEqual(error["details"]["cause"], "desktop_ipc_unavailable")

    def test_exact_owner_state_uses_longer_read_only_discovery_timeout(self):
        thread = "11111111-1111-4111-8111-111111111111"
        timeouts = []

        class RecordingDesktopClient:
            def __init__(self, timeout=5.0):
                timeouts.append(timeout)

            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def find_owner(self, _thread_id):
                raise codex_bridge.BridgeError(
                    "no owner", code="desktop_thread_not_owned",
                    details={"reason": "no-client-found"})

        common = (
            mock.patch.object(codex_bridge, "RpcClient", self.rpc_client_for_thread()),
            mock.patch.object(codex_bridge, "sidecar_tty_map", return_value={}),
            mock.patch.object(codex_bridge, "DesktopIpcClient", RecordingDesktopClient),
        )
        with common[0], common[1], common[2]:
            strict = codex_bridge.one_thread(thread, require_owner_state=True)
            ordinary = codex_bridge.one_thread(thread)

        self.assertEqual(timeouts, [12.0, 5.0])
        self.assertEqual(strict["ownerState"], "closed")
        self.assertNotIn("ownerState", ordinary)

    def test_exact_owner_timeout_remains_unknown_not_closed(self):
        thread = "11111111-1111-4111-8111-111111111111"

        class TimedOutDesktopClient:
            def __init__(self, timeout=5.0):
                self.timeout = timeout

            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

            def find_owner(self, _thread_id):
                raise codex_bridge.BridgeError(
                    "desktop discovery timed out",
                    code="desktop_ipc_outcome_unknown")

        with mock.patch.object(codex_bridge, "RpcClient", self.rpc_client_for_thread()), \
             mock.patch.object(codex_bridge, "sidecar_tty_map", return_value={}), \
             mock.patch.object(codex_bridge, "DesktopIpcClient", TimedOutDesktopClient):
            with self.assertRaises(codex_bridge.BridgeError) as caught:
                codex_bridge.one_thread(thread, require_owner_state=True)

        self.assertEqual(caught.exception.code, "thread_ownership_unknown")
        self.assertEqual(caught.exception.details["cause"],
                         "desktop_ipc_outcome_unknown")

    def test_resolve_tty_returns_consistent_verified_cli_owner(self):
        thread = "11111111-1111-4111-8111-111111111111"
        db = sqlite3.connect(self.home / "thread_history_1.sqlite")
        db.execute("UPDATE thread_turns SET status = 'inProgress'")
        db.commit()
        db.close()
        record = {"tty": "/dev/ttys007", "pid": 42,
                  "sourceResolution": "sidecar"}
        with mock.patch.object(codex_bridge, "sidecar_tty_map",
                               return_value={thread: record}), \
             mock.patch.object(codex_bridge, "codex_home", return_value=self.home):
            row = codex_bridge.resolve_tty("/dev/ttys007")
        self.assertEqual(row["source"], "cli")
        self.assertEqual(row["sourceResolution"], "sidecar")
        self.assertEqual(row["pid"], 42)
        self.assertTrue(row["live"])
        self.assertTrue(row["ttyOwner"])
        self.assertEqual(row["status"], "active")
        self.assertTrue(row["busy"])

    def test_active_send_steers_exact_turn(self):
        self.make_socket()
        self.env["FAKE_THREAD_STATUS"] = "active"
        text = self.root / "message.txt"
        text.write_text("continue")
        result = self.json_output(self.run_bridge(
            "send", "--thread", "11111111-1111-4111-8111-111111111111",
            "--text-file", str(text)))
        self.assertEqual(result["action"], "steered")
        self.assertIn("turn/steer", self.rpc_methods())
        self.assertNotIn("turn/start", self.rpc_methods())

    def test_active_send_can_use_caller_confirmed_expected_turn(self):
        self.make_socket()
        self.env["FAKE_THREAD_STATUS"] = "active"
        text = self.root / "message.txt"
        text.write_text("continue")
        turn = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        result = self.json_output(self.run_bridge(
            "send", "--thread", "11111111-1111-4111-8111-111111111111",
            "--text-file", str(text), "--expected-turn", turn))
        self.assertEqual(result["action"], "steered")
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        steer = next(call for call in calls if call["method"] == "turn/steer")
        self.assertEqual(steer["params"]["expectedTurnId"], turn)
        self.assertNotIn("thread/turns/list", [call["method"] for call in calls])

    def test_unloaded_send_requires_explicit_verified_owner(self):
        self.make_socket()
        self.env["FAKE_THREAD_STATUS"] = "notLoaded"
        text = self.root / "message.txt"
        text.write_text("continue")
        result = self.run_bridge(
            "send", "--thread", "11111111-1111-4111-8111-111111111111",
            "--text-file", str(text))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["code"], "thread_ownership_unknown")
        methods = self.rpc_methods()
        self.assertNotIn("thread/resume", methods)
        self.assertNotIn("turn/start", methods)

    def test_send_never_starts_private_fallback(self):
        text = self.root / "message.txt"
        text.write_text("continue")
        result = self.run_bridge(
            "send", "--thread", "11111111-1111-4111-8111-111111111111",
            "--text-file", str(text))
        self.assertEqual(result.returncode, 2)
        error = json.loads(result.stdout)
        self.assertEqual(error["code"], "desktop_ipc_unavailable")
        self.assertFalse(self.log.exists())

    def test_send_routes_to_exact_desktop_owner_without_private_server(self):
        self.make_desktop_ipc()
        text = self.root / "message.txt"
        text.write_text("continue")
        result = self.json_output(self.run_bridge(
            "send", "--thread", "11111111-1111-4111-8111-111111111111",
            "--text-file", str(text)))
        self.assertEqual(result["transport"], "desktop-ipc")
        self.assertEqual(result["turnId"], "desktop-turn")
        self.assertEqual(result["action"], "started")
        self.assertFalse(self.log.exists())

    def test_active_desktop_send_steers_owner(self):
        db = sqlite3.connect(self.home / "thread_history_1.sqlite")
        db.execute("UPDATE thread_turns SET status = 'inProgress'")
        db.commit()
        db.close()
        self.make_desktop_ipc()
        text = self.root / "message.txt"
        text.write_text("continue")
        result = self.json_output(self.run_bridge(
            "send", "--thread", "11111111-1111-4111-8111-111111111111",
            "--text-file", str(text)))
        self.assertEqual(result["action"], "steered")
        self.assertEqual(result["turnId"], "desktop-active-turn")
        self.assertEqual(self.ipc_methods.count("thread-follower-steer-turn"), 1)
        self.assertNotIn("thread-follower-start-turn", self.ipc_methods)
        request = next(value for value in self.ipc_requests
                       if value["method"] == "thread-follower-steer-turn")
        params = request["params"]
        restore = params["restoreMessage"]
        self.assertEqual(restore["id"], params["clientUserMessageId"])
        self.assertEqual(restore["text"], "continue")
        self.assertEqual(restore["cwd"], "/tmp/project/sub")
        self.assertIsInstance(restore["createdAt"], int)
        self.assertEqual(restore["context"], {
            "prompt": "continue",
            "messageThreadId": None,
            "turnTrigger": "walkie-talkie",
            "addedFiles": [],
            "fileAttachments": [],
            "commentAttachments": [],
            "ideContext": None,
            "imageAttachments": [],
            "workspaceRoots": ["/tmp/project/sub"],
        })

    def test_active_desktop_steer_preserves_input_images(self):
        db = sqlite3.connect(self.home / "thread_history_1.sqlite")
        db.execute("UPDATE thread_turns SET status = 'inProgress'")
        db.commit()
        db.close()
        self.make_desktop_ipc()
        text = self.root / "message.txt"
        text.write_text("describe")
        image = self.root / "image.png"
        image.write_bytes(b"synthetic image")
        self.json_output(self.run_bridge(
            "send", "--thread", "11111111-1111-4111-8111-111111111111",
            "--text-file", str(text), "--image", str(image)))
        request = next(value for value in self.ipc_requests
                       if value["method"] == "thread-follower-steer-turn")
        self.assertEqual(request["params"]["input"], [
            {"type": "text", "text": "describe", "text_elements": []},
            {"type": "localImage", "path": str(image.resolve())},
        ])

    def test_active_desktop_owner_rejection_is_not_masked_as_unowned(self):
        db = sqlite3.connect(self.home / "thread_history_1.sqlite")
        db.execute("UPDATE thread_turns SET status = 'inProgress'")
        db.commit()
        db.close()
        self.make_socket()
        self.env["FAKE_THREAD_STATUS"] = "notLoaded"
        self.ipc_errors["thread-follower-steer-turn"] = "native steer rejected"
        self.make_desktop_ipc()
        text = self.root / "message.txt"
        text.write_text("continue")
        result = self.run_bridge(
            "send", "--thread", "11111111-1111-4111-8111-111111111111",
            "--text-file", str(text))
        self.assertEqual(result.returncode, 2)
        error = json.loads(result.stdout)
        self.assertEqual(error["code"], "desktop_thread_unavailable")
        self.assertEqual(error["details"]["reason"], "native steer rejected")
        request = next(value for value in self.ipc_requests
                       if value["method"] == "thread-follower-steer-turn")
        self.assertEqual(request["params"]["restoreMessage"]["cwd"], "/tmp/project")

    def test_desktop_owner_discovery_miss_has_distinct_error(self):
        self.ipc_errors["thread-owner-discovery"] = "no-client-found"
        self.make_desktop_ipc()
        with mock.patch.dict(os.environ, self.env, clear=True):
            with codex_bridge.DesktopIpcClient() as client:
                with self.assertRaises(codex_bridge.BridgeError) as caught:
                    client.find_owner("11111111-1111-4111-8111-111111111111")
        self.assertEqual(caught.exception.code, "desktop_thread_not_owned")
        self.assertEqual(caught.exception.details["reason"], "no-client-found")

    def test_projects_include_swift_compatible_rank_fields(self):
        result = self.json_output(self.run_bridge("projects"))
        project = result["projects"][0]
        self.assertEqual(project["path"], "/tmp/project")
        self.assertEqual(project["score"], 1234)

    def test_watch_until_idle_observes_exact_stored_turn(self):
        result = self.json_output(self.run_bridge(
            "watch-until-idle",
            "--thread", "11111111-1111-4111-8111-111111111111",
            "--turn", "22222222-2222-4222-8222-222222222222",
            "--timeout", "1"))
        self.assertTrue(result["idle"])
        self.assertEqual(result["status"], "completed")

    def test_search_only_returns_visible_messages(self):
        lines = self.run_bridge("search", "--query", "blue bicycle").stdout.splitlines()
        row = json.loads(lines[0])
        done = json.loads(lines[-1])
        self.assertEqual(row["hits"], 2)
        self.assertEqual(row["session"], "11111111-1111-4111-8111-111111111111")
        self.assertEqual(row["role"], "codex")
        self.assertIn("The blue bicycle is ready", row["snippet"])
        self.assertTrue(done["done"])

    def test_search_reports_user_role_for_latest_user_match(self):
        lines = self.run_bridge("search", "--query", "my blue").stdout.splitlines()
        row = json.loads(lines[0])
        self.assertEqual(row["hits"], 1)
        self.assertEqual(row["role"], "me")
        self.assertIn("my blue bicycle", row["snippet"])

    def test_visible_message_roles_use_codex_vocabulary(self):
        self.assertEqual(codex_bridge.extract_visible(
            "agentMessage", json.dumps({"text": "answer"})), ("codex", "answer"))
        self.assertEqual(codex_bridge.extract_visible(
            "plan", json.dumps({"text": "plan"})), ("codex", "plan"))
        self.assertEqual(codex_bridge.extract_visible(
            "userMessage", json.dumps({"content": [
                {"type": "text", "text": "question"},
            ]})), ("me", "question"))

    def test_search_marks_verified_desktop_owner(self):
        self.make_desktop_ipc()
        lines = self.run_bridge("search", "--query", "blue bicycle").stdout.splitlines()
        row = json.loads(lines[0])
        self.assertTrue(row["ttyOwner"])
        self.assertEqual(row["tty"],
                         "codex:11111111-1111-4111-8111-111111111111")

    def test_tty_sidecar_requires_matching_process_identity(self):
        folder = self.root / "tty-map"
        folder.mkdir()
        thread = "11111111-1111-4111-8111-111111111111"
        (folder / "ttys007.json").write_text(json.dumps({
            "pid": 42, "tty": "/dev/ttys007", "threadId": thread,
        }))
        with mock.patch.object(codex_bridge, "sidecar_dir", return_value=folder), \
             mock.patch.object(codex_bridge, "process_rows", return_value=[{
                 "pid": 42, "ppid": 1, "tty": "ttys007",
                 "command": "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex --remote unix:// resume " + thread,
             }]):
            self.assertEqual(codex_bridge.sidecar_tty_map()[thread]["pid"], 42)
        with mock.patch.object(codex_bridge, "sidecar_dir", return_value=folder), \
             mock.patch.object(codex_bridge, "process_rows", return_value=[{
                 "pid": 42, "ppid": 1, "tty": "ttys007",
                 "command": "/usr/bin/python3 unrelated.py",
             }]):
            self.assertEqual(codex_bridge.sidecar_tty_map(), {})

    def test_native_process_resolution_rejects_ambiguous_owners(self):
        thread = "11111111-1111-4111-8111-111111111111"
        command = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex resume " + thread
        rows = [
            {"pid": 41, "ppid": 1, "tty": "ttys007", "command": command},
            {"pid": 42, "ppid": 1, "tty": "ttys007", "command": command},
        ]
        with mock.patch.object(codex_bridge, "process_rows", return_value=rows):
            self.assertIsNone(codex_bridge.process_thread_for_tty("/dev/ttys007"))

    def test_quick_worker_accepts_request_before_ready_and_streams_cumulative_text(self):
        request = {"id": "q1", "text": "hello", "model": "fake-model", "effort": "low"}
        result = self.run_bridge("quick-worker", input_text=json.dumps(request) + "\n")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(events[0]["type"], "ready")
        deltas = [event["text"] for event in events if event["type"] == "delta"]
        self.assertEqual(deltas, ["Hi", "Hi there"])
        self.assertEqual(events[-1]["type"], "completed")
        self.assertEqual(events[-1]["text"], "Hi there")
        self.assertEqual(events[-1]["model"], "fake-model")
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        start = next(call["params"] for call in calls if call["method"] == "thread/start")
        self.assertTrue(start["ephemeral"])
        self.assertEqual(start["dynamicTools"], [])
        self.assertNotEqual(start["cwd"], str(self.root))
        self.assertIn("walkie-quick-", start["cwd"])

    def test_quick_worker_fails_closed_when_a_tool_item_appears(self):
        environment = self.env.copy()
        environment["FAKE_QUICK_TOOL"] = "1"
        request = {"id": "q-tool", "text": "read a private file"}
        result = self.run_bridge("quick-worker", input_text=json.dumps(request) + "\n",
                                 env=environment)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(events[-1]["type"], "error")
        self.assertEqual(events[-1]["code"], "quick_tool_denied")
        self.assertIn("turn/interrupt", self.rpc_methods())


class ReleasePreflightTests(unittest.TestCase):
    @staticmethod
    def _rpc(thread, status="notLoaded"):
        rpc = mock.MagicMock()
        rpc.__enter__.return_value = rpc
        rpc.request.return_value = {"thread": {"id": thread, "status": {"type": status}}}
        return rpc

    @staticmethod
    def _snapshot(*, threads=None, requests=None, problem=None):
        return {"ok": True, "threads": threads or [], "requests": requests or [],
                "problem": problem}

    def test_pending_release_checks_all_native_pages_without_mutating_broker(self):
        thread = "11111111-2222-4333-8444-555555555555"
        broker = mock.Mock(return_value={"threads": [{"id": thread, "background": True,
                                                       "subscribed": False, "state": "idle"}]})
        rpc = self._rpc(thread, "idle")
        rpc.request.side_effect = [
            {"thread": {"id": thread, "status": {"type": "idle"}}},
            {"data": [], "nextCursor": "page2"}, {"data": [thread]},
        ]
        with mock.patch.dict(sys.modules, {"codex_background": SimpleNamespace(broker_request=broker)}), \
                mock.patch.object(codex_bridge, "RpcClient", return_value=rpc), \
                mock.patch.object(codex_bridge, "active_turn_id", return_value=None):
            with self.assertRaises(codex_bridge.BridgeError) as caught:
                codex_bridge.prepare_open(SimpleNamespace(id=thread, destination="desktop"))
        self.assertEqual(caught.exception.code, "thread_release_pending")
        self.assertEqual([call.args[0] for call in broker.call_args_list], ["status"])
        self.assertEqual(rpc.request.call_args.args[1]["cursor"], "page2")

    def test_pending_approval_prevents_even_release_polling(self):
        thread = "11111111-2222-4333-8444-555555555555"
        broker = mock.Mock(return_value=self._snapshot(
            threads=[{"id": thread, "background": True, "subscribed": False,
                      "state": "idle", "busy": False}],
            requests=[{"threadId": thread}],
        ))
        rpc = self._rpc(thread)
        with mock.patch.dict(sys.modules, {"codex_background": SimpleNamespace(broker_request=broker)}), \
                mock.patch.object(codex_bridge, "RpcClient", return_value=rpc), \
                mock.patch.object(codex_bridge, "active_turn_id", return_value=None):
            with self.assertRaises(codex_bridge.BridgeError) as caught:
                codex_bridge.prepare_open(SimpleNamespace(id=thread, destination="desktop"))
        self.assertEqual(caught.exception.code, "thread_busy")
        self.assertEqual(rpc.request.call_args.args[0], "thread/read")
        self.assertNotIn("thread/loaded/list", [call.args[0] for call in rpc.request.call_args_list])

    def test_closed_stored_chat_opens_without_desktop_owner_or_broker_prepare_probe(self):
        thread = "11111111-2222-4333-8444-555555555555"
        broker = mock.Mock(return_value=self._snapshot())
        rpc = self._rpc(thread)
        with mock.patch.dict(sys.modules, {"codex_background": SimpleNamespace(broker_request=broker)}), \
                mock.patch.object(codex_bridge, "RpcClient", return_value=rpc), \
                mock.patch.object(codex_bridge, "active_turn_id", return_value=None), \
                mock.patch.object(codex_bridge, "DesktopIpcClient",
                                  side_effect=AssertionError("Desktop owner probe used")):
            result = codex_bridge.prepare_open(SimpleNamespace(id=thread, destination="desktop"))
        self.assertTrue(result["safe"])
        self.assertEqual(result["thread"]["id"], thread)
        self.assertEqual([call.args[0] for call in broker.call_args_list], ["status"])
        self.assertEqual([call.args[0] for call in rpc.request.call_args_list], ["thread/read"])

    def test_native_unloaded_clears_stale_unsubscribed_owner_unknown(self):
        thread = "11111111-2222-4333-8444-555555555555"
        snapshot = self._snapshot(threads=[{
            "id": thread, "background": True, "subscribed": False,
            "state": "idle", "busy": False, "ownerState": "unknown",
            "releaseState": "waiting",
        }])
        broker = mock.Mock(return_value=snapshot)
        rpc = self._rpc(thread, "notLoaded")
        with mock.patch.dict(sys.modules, {
                "codex_background": SimpleNamespace(broker_request=broker)}), \
                mock.patch.object(codex_bridge, "RpcClient", return_value=rpc), \
                mock.patch.object(codex_bridge, "active_turn_id", return_value=None), \
                mock.patch.object(codex_bridge, "DesktopIpcClient",
                                  side_effect=AssertionError("Desktop owner probe used")):
            result = codex_bridge.prepare_open(SimpleNamespace(id=thread, destination="desktop"))
        self.assertTrue(result["safe"])
        self.assertEqual([call.args[0] for call in broker.call_args_list], ["status"])
        self.assertEqual([call.args[0] for call in rpc.request.call_args_list], ["thread/read"])

    def test_not_loaded_fastpath_is_vetoed_by_active_turn(self):
        thread = "11111111-2222-4333-8444-555555555555"
        snapshot = self._snapshot()
        broker = mock.Mock(side_effect=[snapshot, {"ok": True, "safe": True}])
        rpc = self._rpc(thread)
        with mock.patch.dict(sys.modules, {"codex_background": SimpleNamespace(broker_request=broker)}), \
                mock.patch.object(codex_bridge, "RpcClient", return_value=rpc), \
                mock.patch.object(codex_bridge, "active_turn_id", return_value="turn-active"):
            result = codex_bridge.prepare_open(SimpleNamespace(id=thread, destination="desktop"))
        self.assertIn("safe", result)
        self.assertTrue(result["safe"])
        self.assertEqual([call.args[0] for call in broker.call_args_list],
                         ["status", "prepare-open"])

    def test_not_loaded_fastpath_is_vetoed_by_subscribed_or_unknown_writer(self):
        thread = "11111111-2222-4333-8444-555555555555"
        cases = [
            {"id": thread, "background": True, "subscribed": True,
             "state": "idle", "busy": False},
            {"id": thread, "background": True, "subscribed": False,
             "state": "unknown", "busy": None},
        ]
        for tracked in cases:
            with self.subTest(tracked=tracked):
                snapshot = self._snapshot(threads=[tracked])
                broker = mock.Mock(side_effect=[snapshot, {"ok": True, "safe": True}])
                rpc = self._rpc(thread)
                # An unsubscribed unknown row takes the normal loaded check;
                # a subscribed row goes straight to broker handoff.
                rpc.request.side_effect = [
                    {"thread": {"id": thread, "status": {"type": "notLoaded"}}},
                    {"data": []},
                ]
                with mock.patch.dict(sys.modules, {
                        "codex_background": SimpleNamespace(broker_request=broker)}), \
                        mock.patch.object(codex_bridge, "RpcClient", return_value=rpc), \
                        mock.patch.object(codex_bridge, "active_turn_id", return_value=None):
                    result = codex_bridge.prepare_open(SimpleNamespace(id=thread, destination="desktop"))
                self.assertTrue(result["safe"])
                self.assertEqual(broker.call_args_list[-1].args[0], "prepare-open")

    def test_not_loaded_fastpath_rejects_identity_mismatch_and_guardian(self):
        thread = "11111111-2222-4333-8444-555555555555"
        for native, code in [
                ({"id": "22222222-2222-4222-8222-222222222222",
                  "status": {"type": "notLoaded"}}, "thread_identity_mismatch"),
                ({"id": thread, "threadSource": "guardian_review",
                  "status": {"type": "notLoaded"}}, "thread_hidden")]:
            with self.subTest(code=code):
                rpc = mock.MagicMock()
                rpc.__enter__.return_value = rpc
                rpc.request.return_value = {"thread": native}
                with mock.patch.dict(sys.modules, {
                        "codex_background": SimpleNamespace(broker_request=mock.Mock())}), \
                        mock.patch.object(codex_bridge, "RpcClient", return_value=rpc):
                    with self.assertRaises(codex_bridge.BridgeError) as caught:
                        codex_bridge.prepare_open(SimpleNamespace(id=thread, destination="desktop"))
                self.assertEqual(caught.exception.code, code)

    def test_active_background_writer_is_refused_without_desktop_owner_probe(self):
        thread = "11111111-2222-4333-8444-555555555555"
        snapshot = self._snapshot(threads=[{
            "id": thread, "background": True, "subscribed": True,
            "state": "active", "busy": True,
        }])
        broker = mock.Mock(return_value=snapshot)
        rpc = self._rpc(thread, "active")
        with mock.patch.dict(sys.modules, {
                "codex_background": SimpleNamespace(broker_request=broker)}), \
                mock.patch.object(codex_bridge, "RpcClient", return_value=rpc), \
                mock.patch.object(codex_bridge, "DesktopIpcClient",
                                  side_effect=AssertionError("Desktop owner probe used")):
            with self.assertRaises(codex_bridge.BridgeError) as caught:
                codex_bridge.prepare_open(SimpleNamespace(id=thread, destination="desktop"))
        self.assertEqual(caught.exception.code, "thread_busy")
        self.assertEqual([call.args[0] for call in broker.call_args_list], ["status"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
