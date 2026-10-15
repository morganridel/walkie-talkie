import base64
import hashlib
import json
import os
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
        })
        self.make_state()
        self.make_history()
        self.sock = None
        self.ipc_server = None
        self.ipc_methods = []

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
            ("u", 1, {"type": "userMessage", "content": [{"type": "text", "text": "blue bicycle"}]}, "userMessage"),
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
        self.assertEqual(json.loads(result.stdout)["code"], "thread_not_owned")
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
        self.assertTrue(done["done"])

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
