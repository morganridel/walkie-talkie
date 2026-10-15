#!/usr/bin/env python3
"""Small, dependency-free bridge between Walkie Talkie and Codex.

The bridge has deliberately separate transports:

* Existing shared-daemon chats use its local Unix-socket WebSocket endpoint.
* Existing desktop chats use the app's owner/follower IPC router, which first
  resolves the exact window that owns the requested thread.
* Quick questions use a private app-server and ephemeral threads.  They cannot
  alter or appear in the user's stored chat list.

There is no private-server fallback for an existing chat: that could race the
desktop client or create a second live copy. Read-only commands fall back to
Codex's SQLite stores and explicitly probe desktop ownership where needed.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shlex
import signal
import socket
import sqlite3
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.dont_write_bytecode = True


APP_CODEX = Path("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
CODEX_APP = Path("/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex")
ALL_SOURCE_KINDS = [
    "cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview",
    "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown",
]
DEFAULT_QUICK_SYSTEM = (
    "Answer the question directly and briefly, in the language of the question. "
    "Treat likely speech-recognition mistakes as mistakes and answer what the "
    "speaker most likely meant. Do not use tools unless the request explicitly "
    "asks for web checking."
)
UUID_RE = re.compile(
    r"(?<![0-9A-Fa-f])(?:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})(?![0-9A-Fa-f])"
)


class BridgeError(RuntimeError):
    def __init__(self, message, *, code="bridge_error", details=None):
        super().__init__(message)
        self.code = code
        self.details = details


def codex_home():
    return Path(os.environ.get("CODEX_HOME") or (Path.home() / ".codex"))


def find_codex():
    """Resolve the native CLI without trusting the commonly broken npm shim."""
    candidates = []
    override = os.environ.get("CODEX_BIN", "").strip()
    if override:
        candidates.append(Path(override).expanduser())
    here = Path(__file__).resolve()
    for parent in (here.parent, *here.parents):
        candidates.extend((
            parent / "codex-cli/bin/codex",
            parent / "Resources/codex-cli/bin/codex",
        ))
    candidates.extend((APP_CODEX, CODEX_APP))
    seen = set()
    for candidate in candidates:
        try:
            candidate = candidate.resolve()
        except OSError:
            continue
        if candidate in seen:
            continue
        seen.add(candidate)
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise BridgeError(
        "Codex CLI not found; set CODEX_BIN to the native Codex executable",
        code="codex_not_found",
    )


def control_socket():
    override = os.environ.get("CODEX_APP_SERVER_SOCKET", "").strip()
    path = Path(override).expanduser() if override else (
        codex_home() / "app-server-control/app-server-control.sock"
    )
    uid = os.getuid() if hasattr(os, "getuid") else None
    try:
        source_stat = path.lstat()
        source_directory_stat = path.parent.lstat()
        resolved = path.resolve(strict=True)
        socket_stat = resolved.lstat()
        target_directory_stat = resolved.parent.lstat()
    except (OSError, RuntimeError):
        return None
    if not (stat.S_ISSOCK(source_stat.st_mode) or stat.S_ISLNK(source_stat.st_mode)):
        return None
    if not stat.S_ISSOCK(socket_stat.st_mode):
        return None
    if not (stat.S_ISDIR(source_directory_stat.st_mode)
            and stat.S_ISDIR(target_directory_stat.st_mode)):
        return None
    if uid is not None and any(info.st_uid != uid for info in (
            source_stat, source_directory_stat, socket_stat, target_directory_stat)):
        return None
    if source_directory_stat.st_mode & 0o022:
        return None
    if target_directory_stat.st_mode & 0o022:
        return None
    if socket_stat.st_mode & 0o022:
        return None
    return resolved


def desktop_ipc_socket():
    """Return Codex Desktop's same-user IPC router only when permissions are safe."""
    override = os.environ.get("CODEX_DESKTOP_IPC_SOCKET", "").strip()
    path = Path(override).expanduser() if override else codex_home() / "ipc/ipc.sock"
    try:
        socket_stat = path.lstat()
        directory_stat = path.parent.lstat()
    except OSError:
        return None
    uid = os.getuid() if hasattr(os, "getuid") else None
    if not stat.S_ISSOCK(socket_stat.st_mode) or not stat.S_ISDIR(directory_stat.st_mode):
        return None
    if uid is not None and (socket_stat.st_uid != uid or directory_stat.st_uid != uid):
        return None
    if directory_stat.st_mode & 0o022:
        return None
    return path


IPC_VERSIONS = {
    "thread-owner-discovery": 1,
    "thread-follower-start-turn": 2,
    "thread-follower-steer-turn": 1,
}


class DesktopIpcClient:
    """Short-lived, distinctly identified client of Codex Desktop's IPC router.

    The router chooses the window that owns a thread.  We do not claim thread
    ownership, identify as a desktop window, or supply another caller's IDs.
    """

    def __init__(self, timeout=5.0):
        path = desktop_ipc_socket()
        if path is None:
            raise BridgeError("Codex Desktop IPC is unavailable", code="desktop_ipc_unavailable")
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(timeout)
        try:
            self.socket.connect(str(path))
            response = self.request("initialize", {"clientType": "walkie-talkie"}, version=0)
        except (OSError, ValueError) as error:
            self.close()
            raise BridgeError("could not connect to Codex Desktop IPC",
                              code="desktop_ipc_unavailable") from error
        self.client_id = response.get("result", {}).get("clientId")
        if not self.client_id:
            self.close()
            raise BridgeError("Codex Desktop rejected IPC initialization",
                              code="desktop_ipc_protocol_error")

    def _write(self, value):
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()
        self.socket.sendall(struct.pack("<I", len(payload)) + payload)

    def _read_exact(self, size):
        parts = []
        remaining = size
        while remaining:
            chunk = self.socket.recv(remaining)
            if not chunk:
                raise BridgeError("Codex Desktop IPC closed", code="desktop_ipc_closed")
            parts.append(chunk)
            remaining -= len(chunk)
        return b"".join(parts)

    def _read(self):
        try:
            length = struct.unpack("<I", self._read_exact(4))[0]
            if length <= 0 or length > 256 * 1024 * 1024:
                raise BridgeError("invalid Codex Desktop IPC frame",
                                  code="desktop_ipc_protocol_error")
            value = json.loads(self._read_exact(length))
        except socket.timeout as error:
            raise BridgeError(
                "Codex Desktop did not confirm the request; it will not be retried",
                code="desktop_ipc_outcome_unknown",
            ) from error
        except (ValueError, struct.error) as error:
            raise BridgeError("invalid Codex Desktop IPC response",
                              code="desktop_ipc_protocol_error") from error
        if not isinstance(value, dict):
            raise BridgeError("invalid Codex Desktop IPC response",
                              code="desktop_ipc_protocol_error")
        return value

    def request(self, method, params, *, version=None, target=None, host_id=None):
        request_id = str(uuid.uuid4())
        message = {
            "type": "request", "requestId": request_id,
            "sourceClientId": getattr(self, "client_id", "initializing-client"),
            "version": IPC_VERSIONS.get(method, 0) if version is None else version,
            "method": method, "params": params,
        }
        if target:
            message["targetClientId"] = target
        if host_id and host_id != "local":
            message["hostId"] = host_id
        self._write(message)
        while True:
            response = self._read()
            if response.get("type") == "client-discovery-request":
                self._write({"type": "client-discovery-response",
                             "requestId": response.get("requestId"),
                             "response": {"canHandle": False}})
                continue
            if response.get("type") != "response" or response.get("requestId") != request_id:
                continue
            if response.get("resultType") != "success":
                raise BridgeError(
                    "Codex Desktop could not route the request to the thread owner",
                    code="desktop_thread_unavailable",
                    details={"reason": response.get("error")},
                )
            return response

    def find_owner(self, thread_id, host_id="local"):
        try:
            response = self.request("thread-owner-discovery", {
                "hostId": host_id, "conversationId": thread_id,
            })
        except BridgeError as error:
            details = error.details or {}
            if (error.code == "desktop_thread_unavailable"
                    and details.get("reason") == "no-client-found"):
                raise BridgeError(
                    "no Codex Desktop window owns this thread",
                    code="desktop_thread_not_owned",
                    details=details,
                ) from error
            raise
        owner = response.get("handledByClientId")
        if not owner:
            raise BridgeError("no Codex Desktop window owns this thread",
                              code="desktop_thread_not_owned")
        return owner, response.get("result") or {}

    def follower_request(self, thread_id, method, params, host_id="local"):
        owner, capabilities = self.find_owner(thread_id, host_id)
        response = self.request(method, params, target=owner, host_id=host_id)
        return response.get("result") or {}, capabilities

    def close(self):
        sock = getattr(self, "socket", None)
        if sock is not None:
            try:
                sock.close()
            finally:
                self.socket = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class RpcClient:
    """One app-server connection: private JSONL stdio or shared Unix WebSocket."""

    def __init__(self, *, private=False, timeout=8.0):
        binary = find_codex()
        self.private = private
        self.process = None
        self.ws_socket = None
        self.stderr = []
        self.pending = []
        self.next_id = 1
        self.timeout = timeout
        self._private_home = None
        self.private_workspace = None
        if private:
            # Quick Ask gets a clean runtime rather than inheriting user/project
            # settings, instructions, skills, MCP servers, plugins, or hooks.
            # The auth file is referenced read-only; it is never copied or
            # changed. Shell and every other optional built-in tool are disabled
            # at process startup. Hosted web search is selected per thread.
            self._private_home = tempfile.TemporaryDirectory(prefix="walkie-quick-")
            private_home = Path(self._private_home.name)
            self.private_workspace = private_home / "workspace"
            self.private_workspace.mkdir(mode=0o700)
            auth = codex_home() / "auth.json"
            if auth.is_file():
                (private_home / "auth.json").symlink_to(auth)
            disabled_features = (
                "shell_tool", "view_image", "sleep_tool", "multi_agent",
                "apps", "plugins", "hooks", "skill_search",
                "workspace_dependencies", "computer_use", "image_generation",
                "goals", "request_permissions_tool", "token_budget",
            )
            command = [str(binary), "app-server", "-c", "mcp_servers={}"]
            for feature in disabled_features:
                command.extend(("--disable", feature))
            command.extend(("--listen", "stdio://"))
            environment = os.environ.copy()
            environment["CODEX_HOME"] = str(private_home)
            environment.pop("CODEX_APP_TOOLS_PIPE_PATH", None)
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                cwd=self.private_workspace,
                env=environment,
            )
            self.incoming = queue.Queue()
            self._stdout_thread = threading.Thread(target=self._drain_stdout, daemon=True)
            self._stdout_thread.start()
            self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
            self._stderr_thread.start()
        else:
            socket_path = control_socket()
            if socket_path is None:
                raise BridgeError(
                    "shared Codex app-server is unavailable",
                    code="shared_daemon_unavailable",
                    details={"expectedSocket": str(
                        Path(os.environ.get("CODEX_APP_SERVER_SOCKET", "")).expanduser()
                        if os.environ.get("CODEX_APP_SERVER_SOCKET")
                        else codex_home() / "app-server-control/app-server-control.sock"
                    )},
                )
            self.ws_socket = self._open_websocket(socket_path, timeout)
        response = self.request("initialize", {
            "clientInfo": {
                "name": "walkie_talkie",
                "title": "Walkie Talkie",
                "version": "1.0",
            },
            "capabilities": {"experimentalApi": True},
        })
        if not isinstance(response, dict):
            self.close()
            raise BridgeError("Codex app-server rejected initialization", code="protocol_error")
        self.notify("initialized", {})

    @staticmethod
    def _recv_exact(sock, size):
        parts = []
        while size:
            chunk = sock.recv(size)
            if not chunk:
                raise BridgeError("Codex app-server connection closed", code="connection_closed")
            parts.append(chunk)
            size -= len(chunk)
        return b"".join(parts)

    @classmethod
    def _open_websocket(cls, path, timeout):
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        try:
            sock.connect(str(path))
            key = base64.b64encode(os.urandom(16)).decode()
            request = (
                "GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                f"Sec-WebSocket-Key: {key}\r\n\r\n"
            ).encode()
            sock.sendall(request)
            response = b""
            while b"\r\n\r\n" not in response and len(response) < 65536:
                response += sock.recv(4096)
            head, separator, extra = response.partition(b"\r\n\r\n")
            if not separator or not head.startswith(b"HTTP/1.1 101") or extra:
                raise BridgeError("Codex app-server rejected WebSocket upgrade",
                                  code="protocol_error")
            headers = {}
            for line in head.split(b"\r\n")[1:]:
                name, _, value = line.partition(b":")
                headers[name.strip().lower()] = value.strip()
            expected = base64.b64encode(hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
            ).digest())
            if headers.get(b"sec-websocket-accept") != expected:
                raise BridgeError("invalid Codex app-server WebSocket handshake",
                                  code="protocol_error")
            return sock
        except Exception:
            sock.close()
            raise

    def _ws_send(self, payload, opcode=1):
        data = payload.encode() if isinstance(payload, str) else payload
        mask = os.urandom(4)
        length = len(data)
        if length < 126:
            header = bytes((0x80 | opcode, 0x80 | length))
        elif length < 65536:
            header = bytes((0x80 | opcode, 0xFE)) + struct.pack(">H", length)
        else:
            header = bytes((0x80 | opcode, 0xFF)) + struct.pack(">Q", length)
        masked = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
        self.ws_socket.sendall(header + mask + masked)

    def _ws_read(self, deadline):
        fragments = []
        message_opcode = None
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise socket.timeout()
            self.ws_socket.settimeout(remaining)
            first, second = self._recv_exact(self.ws_socket, 2)
            final, opcode, masked = bool(first & 0x80), first & 0x0F, bool(second & 0x80)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._recv_exact(self.ws_socket, 2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._recv_exact(self.ws_socket, 8))[0]
            mask = self._recv_exact(self.ws_socket, 4) if masked else None
            data = self._recv_exact(self.ws_socket, length)
            if mask:
                data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
            if opcode == 8:
                raise BridgeError("Codex app-server connection closed", code="connection_closed")
            if opcode == 9:
                self._ws_send(data, opcode=10)
                continue
            if opcode in (1, 2):
                message_opcode, fragments = opcode, [data]
            elif opcode == 0 and message_opcode is not None:
                fragments.append(data)
            else:
                continue
            if final:
                if message_opcode != 1:
                    raise BridgeError("unexpected binary app-server message", code="protocol_error")
                return b"".join(fragments).decode("utf-8")

    def _drain_stderr(self):
        try:
            for line in self.process.stderr:
                self.stderr.append(line.rstrip())
                if len(self.stderr) > 30:
                    del self.stderr[:10]
        except (OSError, ValueError):
            pass

    def _drain_stdout(self):
        try:
            for line in self.process.stdout:
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if isinstance(message, dict):
                    self.incoming.put(message)
        except (OSError, ValueError):
            pass
        finally:
            self.incoming.put(None)

    def send(self, message):
        serialized = json.dumps(message, ensure_ascii=False, separators=(",", ":"))
        if self.ws_socket is not None:
            self._ws_send(serialized)
            return
        if self.process is None or self.process.poll() is not None:
            raise BridgeError(
                "Codex app-server connection closed",
                code="connection_closed",
                details={"stderr": "\n".join(self.stderr[-5:])},
            )
        self.process.stdin.write(serialized + "\n")
        self.process.stdin.flush()

    def notify(self, method, params):
        self.send({"method": method, "params": params})

    def request(self, method, params, timeout=None):
        request_id = self.next_id
        self.next_id += 1
        self.send({"method": method, "id": request_id, "params": params})
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        while True:
            for index, message in enumerate(self.pending):
                if message.get("id") == request_id:
                    self.pending.pop(index)
                    return self._result(message)
            message = self.read(deadline=deadline)
            if message.get("id") == request_id:
                return self._result(message)
            self.pending.append(message)

    @staticmethod
    def _result(message):
        if "error" in message:
            error = message.get("error") or {}
            raise BridgeError(
                error.get("message") or "Codex app-server request failed",
                code="rpc_error",
                details={"rpcCode": error.get("code"), "data": error.get("data")},
            )
        return message.get("result")

    def read(self, *, deadline):
        if self.ws_socket is not None:
            try:
                message = json.loads(self._ws_read(deadline))
            except socket.timeout as error:
                raise BridgeError("Codex app-server did not respond in time",
                                  code="protocol_timeout") from error
            except ValueError as error:
                raise BridgeError("invalid Codex app-server response",
                                  code="protocol_error") from error
            if isinstance(message, dict):
                return message
            raise BridgeError("invalid Codex app-server response", code="protocol_error")
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BridgeError(
                    "Codex app-server did not respond in time",
                    code="protocol_timeout",
                    details={"stderr": "\n".join(self.stderr[-5:])},
                )
            try:
                message = self.incoming.get(timeout=remaining)
            except queue.Empty:
                continue
            if message is None:
                raise BridgeError(
                    "Codex app-server connection closed",
                    code="connection_closed",
                    details={"stderr": "\n".join(self.stderr[-5:])},
                )
            return message

    def receive(self, *, deadline):
        """Read the next notification, including ones received before an RPC reply."""
        if self.pending:
            return self.pending.pop(0)
        return self.read(deadline=deadline)

    def close(self):
        sock = getattr(self, "ws_socket", None)
        if sock is not None:
            try:
                self._ws_send(b"", opcode=8)
            except (OSError, BridgeError):
                pass
            sock.close()
            self.ws_socket = None
        else:
            process = getattr(self, "process", None)
            if process is not None:
                try:
                    if process.stdin:
                        process.stdin.close()
                except OSError:
                    pass
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=2)
        if self._private_home is not None:
            self._private_home.cleanup()
            self._private_home = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def db_path(name):
    home = codex_home()
    candidates = [home / name, home / "sqlite" / name]
    return next((p for p in candidates if p.is_file()), None)


def connect_readonly(path):
    if path is None:
        raise BridgeError("Codex state database is unavailable", code="state_unavailable")
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA query_only=ON")
    return connection


def source_name(value):
    if value in ("cli", "vscode", "exec", "appServer"):
        return value
    if isinstance(value, dict):
        return "subAgent" if "subagent" in value else "unknown"
    if isinstance(value, str) and value.startswith("{"):
        try:
            return source_name(json.loads(value))
        except ValueError:
            pass
    return value if isinstance(value, str) and value else "unknown"


def thread_row(raw, *, live):
    status_value = raw.get("status") if isinstance(raw, dict) else None
    status = status_value.get("type") if isinstance(status_value, dict) else status_value
    if not status:
        status = "unknown"
    live = bool(live and status in {"idle", "active", "systemError"})
    name = raw.get("name") or raw.get("title") or raw.get("preview") or raw.get("first_user_message") or ""
    branch = raw.get("git_branch") or ((raw.get("gitInfo") or {}).get("branch") if isinstance(raw.get("gitInfo"), dict) else "")
    row = {
        "id": raw.get("id"),
        "title": name,
        "cwd": raw.get("cwd") or "",
        "status": status,
        "busy": status == "active" if live else None,
        "live": live,
        "source": source_name(raw.get("source")),
        "projectId": raw.get("projectId") if "projectId" in raw else raw.get("project_id"),
        "createdAt": raw.get("createdAt") if "createdAt" in raw else raw.get("created_at"),
        "updatedAt": raw.get("updatedAt") if "updatedAt" in raw else raw.get("updated_at"),
        "model": raw.get("model"),
        "branch": branch or "",
        "tty": None,
        "ttyOwner": False,
    }
    if row["createdAt"] is None and raw.get("created_at_ms") is not None:
        row["createdAt"] = raw["created_at_ms"] / 1000
    if row["updatedAt"] is None and raw.get("updated_at_ms") is not None:
        row["updatedAt"] = raw["updated_at_ms"] / 1000
    return row


def db_threads(limit=100, cwd=None, project=None, query=None, thread_id=None):
    connection = connect_readonly(db_path("state_5.sqlite"))
    try:
        sql = """
            SELECT id, created_at, updated_at, created_at_ms, updated_at_ms,
                   source, cwd, title, name, preview, first_user_message,
                   project_id, model, git_branch
              FROM threads
             WHERE archived = 0
        """
        values = []
        if thread_id:
            sql += " AND id = ?"
            values.append(thread_id)
        if cwd:
            sql += " AND cwd = ?"
            values.append(str(Path(cwd).expanduser().resolve()))
        if project:
            sql += " AND project_id = ?"
            values.append(project)
        if query:
            sql += " AND (name LIKE ? OR title LIKE ? OR preview LIKE ? OR first_user_message LIKE ?)"
            needle = "%" + query + "%"
            values.extend([needle] * 4)
        sql += " ORDER BY COALESCE(NULLIF(recency_at_ms, 0), updated_at_ms, updated_at * 1000) DESC LIMIT ?"
        values.append(max(1, min(limit, 1000)))
        return [thread_row(dict(row), live=False) for row in connection.execute(sql, values)]
    finally:
        connection.close()


def validated_tty(value):
    name = Path(value).name
    if not re.fullmatch(r"tty(?:s\d+|[A-Za-z0-9._-]+)", name):
        raise BridgeError("invalid tty", code="invalid_tty")
    return "/dev/" + name


def sidecar_dir():
    override = os.environ.get("WALKIE_CODEX_TTY_DIR", "").strip()
    return Path(override).expanduser() if override else Path.home() / ".walkie-talkie/codex-tty"


def sidecar_tty_map():
    result = {}
    folder = sidecar_dir()
    if not folder.is_dir():
        return result
    processes = {row["pid"]: row for row in process_rows()}
    for path in folder.glob("tty*.json"):
        try:
            record = json.loads(path.read_text(encoding="utf-8"))
            tty = validated_tty(record.get("tty") or path.stem)
            thread_id = str(record["threadId"])
            pid = int(record["pid"])
        except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError, BridgeError):
            continue
        process = processes.get(pid)
        if process is None or not UUID_RE.fullmatch(thread_id):
            continue
        if not verified_codex_resume_process(process, tty=tty, thread_id=thread_id):
            continue
        result[thread_id] = {
            "tty": tty, "pid": pid, "sourceResolution": "sidecar",
        }
    return result


def process_rows():
    try:
        result = subprocess.run(
            ["/bin/ps", "-axo", "pid=,ppid=,tty=,command="],
            capture_output=True, text=True, timeout=3, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    rows = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) != 4:
            continue
        try:
            rows.append({"pid": int(parts[0]), "ppid": int(parts[1]),
                         "tty": parts[2], "command": parts[3]})
        except ValueError:
            continue
    return rows


def verified_codex_resume_process(process, *, tty, thread_id):
    """Require the exact native resume argv, PID row, tty, and thread token."""
    try:
        argv = shlex.split(process["command"])
    except (KeyError, TypeError, ValueError):
        return False
    return bool(
        Path(process.get("tty") or "").name == Path(tty).name
        and argv
        and Path(argv[0]).name == "codex"
        and "resume" in argv
        and thread_id.lower() in {arg.lower() for arg in argv}
    )


def process_thread_for_tty(tty):
    short = Path(tty).name
    rows = process_rows()
    matches = []
    for row in rows:
        if Path(row["tty"]).name != short:
            continue
        try:
            argv = shlex.split(row["command"])
        except ValueError:
            continue
        if not argv or Path(argv[0]).name != "codex" or "resume" not in argv:
            continue
        ids = [arg.lower() for arg in argv if UUID_RE.fullmatch(arg)]
        matches.extend((value, row["pid"]) for value in ids)
    return matches[0] if len(matches) == 1 else None


def resolve_tty(tty):
    tty = validated_tty(tty)
    for thread_id, record in sidecar_tty_map().items():
        if record["tty"] == tty:
            rows = db_threads(thread_id=thread_id, limit=1)
            if rows:
                return apply_cli_owner(rows[0], record)
    process_match = process_thread_for_tty(tty)
    if process_match:
        thread_id, pid = process_match
        rows = db_threads(thread_id=thread_id, limit=1)
        if rows:
            return apply_cli_owner(rows[0], {
                "tty": tty, "pid": pid, "sourceResolution": "process",
            })
    raise BridgeError(
        "no uniquely verified Codex thread owns this tty",
        code="tty_unresolved",
        details={"tty": tty},
    )


def add_ttys(rows):
    mapping = sidecar_tty_map()
    for row in rows:
        record = mapping.get(row.get("id"))
        if record:
            apply_cli_owner(row, record)
    return rows


def apply_cli_owner(row, record):
    """Apply metadata only after sidecar/process validation proved ownership."""
    active = active_turn_id(row["id"])
    row.update({
        "tty": record["tty"],
        "pid": record["pid"],
        "sourceResolution": record["sourceResolution"],
        "ttyOwner": True,
        "live": True,
        "status": "active" if active else "idle",
        "busy": bool(active),
    })
    return row


def desktop_owned_ids(thread_ids, *, budget=1.5):
    """Return exact desktop-owned IDs within one small total time budget."""
    if not thread_ids or desktop_ipc_socket() is None:
        return set()
    deadline = time.monotonic() + budget
    owned = set()
    try:
        client = DesktopIpcClient(timeout=min(0.5, budget))
    except BridgeError:
        return owned
    with client:
        for thread_id in thread_ids:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            client.socket.settimeout(max(0.05, min(0.25, remaining)))
            try:
                owner, _ = client.find_owner(thread_id)
            except BridgeError as error:
                if error.code == "desktop_ipc_outcome_unknown":
                    break
                continue
            if owner:
                owned.add(thread_id)
    return owned


def enrich_desktop_owners(rows, *, budget=1.5):
    """Annotate exact desktop-owned rows within one small total time budget."""
    owned = desktop_owned_ids([row["id"] for row in rows], budget=budget)
    for row in rows:
        if row["id"] in owned:
            active = active_turn_id(row["id"])
            row.update({"live": True, "status": "active" if active else "idle",
                        "busy": bool(active), "ttyOwner": True})
            if row.get("tty") is None:
                row["tty"] = "codex:" + row["id"]
    return rows


def list_threads(args):
    try:
        with RpcClient() as client:
            params = {
                "limit": args.limit,
                "sortKey": "recency_at",
                "sortDirection": "desc",
                "sourceKinds": ALL_SOURCE_KINDS,
                "useStateDbOnly": True,
            }
            if args.cursor:
                params["cursor"] = args.cursor
            if args.cwd:
                params["cwd"] = str(Path(args.cwd).expanduser().resolve())
            if args.query:
                params["searchTerm"] = args.query
            result = client.request("thread/list", params)
            # A daemon record alone is saved metadata. A row becomes live only
            # after an exact CLI process/TTY or desktop-window owner is proven.
            rows = [thread_row(raw, live=False) for raw in result.get("data", [])]
            if args.project:
                rows = [row for row in rows if row.get("projectId") == args.project]
            rows = add_ttys(rows)
            enrich_desktop_owners([row for row in rows if not row["live"]])
            if args.live_only:
                rows = [row for row in rows if row["live"]]
            return {"threads": rows, "nextCursor": result.get("nextCursor"),
                    "backwardsCursor": result.get("backwardsCursor"),
                    "live": any(row["live"] for row in rows)}
    except BridgeError as error:
        if error.code != "shared_daemon_unavailable":
            raise
    rows = enrich_desktop_owners(add_ttys(db_threads(
        limit=args.limit, cwd=args.cwd, project=args.project, query=args.query)))
    if args.live_only:
        rows = [row for row in rows if row["live"]]
    return {"threads": rows, "nextCursor": None,
            "backwardsCursor": None, "live": any(row["live"] for row in rows)}


def one_thread(thread_id):
    try:
        with RpcClient() as client:
            result = client.request("thread/read", {"threadId": thread_id, "includeTurns": False})
            row = add_ttys([thread_row(result["thread"], live=False)])[0]
            return row if row["live"] else enrich_desktop_owners([row])[0]
    except BridgeError as error:
        if error.code != "shared_daemon_unavailable":
            raise
    rows = db_threads(thread_id=thread_id, limit=1)
    if not rows:
        raise BridgeError("Codex thread not found", code="thread_not_found")
    row = add_ttys(rows)[0]
    try:
        with DesktopIpcClient() as client:
            owner, _ = client.find_owner(thread_id)
        if owner:
            row.update({"live": True,
                        "status": "active" if active_turn_id(thread_id) else "idle",
                        "ttyOwner": True})
            row["busy"] = row["status"] == "active"
            if row.get("tty") is None:
                row["tty"] = "codex:" + thread_id
    except BridgeError:
        pass
    return row


def make_input(text, images):
    value = [{"type": "text", "text": text}]
    for image in images:
        path = Path(image).expanduser().resolve()
        if not path.is_file():
            raise BridgeError(f"image does not exist: {path}", code="image_not_found")
        value.append({"type": "localImage", "path": str(path)})
    return value


def read_text_file(path):
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as error:
        raise BridgeError(f"could not read text file: {error}", code="text_unavailable") from error
    if not text.strip():
        raise BridgeError("message is empty", code="empty_message")
    return text


def active_turn_id(thread_id):
    path = db_path("thread_history_1.sqlite")
    if path is None:
        return None
    connection = connect_readonly(path)
    try:
        row = connection.execute("""
            SELECT turn_id FROM thread_turns
             WHERE thread_id = ? AND status = 'inProgress'
             ORDER BY rollout_ordinal DESC LIMIT 1
        """, (thread_id,)).fetchone()
        return row["turn_id"] if row else None
    finally:
        connection.close()


def stored_turn_status(thread_id, turn_id):
    path = db_path("thread_history_1.sqlite")
    if path is None:
        return None
    connection = connect_readonly(path)
    try:
        row = connection.execute("""
            SELECT status FROM thread_turns
             WHERE thread_id = ? AND turn_id = ? LIMIT 1
        """, (thread_id, turn_id)).fetchone()
        return row["status"] if row else None
    finally:
        connection.close()


def watch_until_idle(args):
    """Wait for one accepted turn (or the current turn) without owning it."""
    deadline = time.monotonic() + args.timeout
    seen_active = False
    client = None
    try:
        try:
            client = RpcClient(timeout=min(8, args.timeout))
        except BridgeError as error:
            if error.code != "shared_daemon_unavailable":
                raise
        while time.monotonic() < deadline:
            if args.turn:
                stored = stored_turn_status(args.thread, args.turn)
                if stored:
                    seen_active = True
                    if stored != "inProgress":
                        return {"ok": True, "threadId": args.thread, "turnId": args.turn,
                                "status": stored, "idle": True}
            if client is not None:
                result = client.request("thread/read", {
                    "threadId": args.thread, "includeTurns": False,
                })
                status = ((result.get("thread") or {}).get("status") or {}).get("type")
                if status == "active":
                    seen_active = True
                elif not args.turn or seen_active:
                    return {"ok": True, "threadId": args.thread,
                            "turnId": args.turn, "status": status or "idle", "idle": True}
            else:
                active = active_turn_id(args.thread)
                if active and (not args.turn or active == args.turn):
                    seen_active = True
                elif not args.turn or seen_active:
                    return {"ok": True, "threadId": args.thread,
                            "turnId": args.turn, "status": "idle", "idle": True}
            time.sleep(0.25)
    finally:
        if client is not None:
            client.close()
    raise BridgeError("timed out waiting for Codex turn to finish",
                      code="watch_timeout",
                      details={"threadId": args.thread, "turnId": args.turn})


def nested_turn_id(value):
    """Extract only a confirmed turn ID from the small native response tree."""
    if not isinstance(value, dict):
        return None
    turn = value.get("turn")
    if isinstance(turn, dict) and isinstance(turn.get("id"), str):
        return turn["id"]
    if isinstance(value.get("turnId"), str):
        return value["turnId"]
    for key in ("result", "response"):
        found = nested_turn_id(value.get(key))
        if found:
            return found
    return None


def desktop_restore_message(thread_id, inputs, message_id, cwd=None):
    """Build the local composer record required by Desktop's steer handler."""
    if not isinstance(cwd, str) or not cwd:
        rows = db_threads(thread_id=thread_id, limit=1)
        cwd = rows[0].get("cwd") if rows else None
    if not isinstance(cwd, str) or not cwd:
        raise BridgeError(
            "Codex Desktop thread working directory is unavailable",
            code="desktop_thread_metadata_unavailable",
            details={"threadId": thread_id},
        )
    text = "\n".join(
        value["text"] for value in inputs
        if value.get("type") == "text" and isinstance(value.get("text"), str)
    )
    return {
        "id": message_id,
        "text": text,
        "context": {
            "prompt": text,
            "messageThreadId": None,
            "turnTrigger": "walkie-talkie",
            "addedFiles": [],
            "fileAttachments": [],
            "commentAttachments": [],
            "ideContext": None,
            "imageAttachments": [],
            "workspaceRoots": [cwd],
        },
        "cwd": cwd,
        "createdAt": int(time.time() * 1000),
    }


def send_desktop(args, inputs, cwd=None):
    """Route through the app's owner/follower IPC; never resume a second copy."""
    message_id = str(uuid.uuid4())
    desktop_inputs = [
        {**value, "text_elements": value.get("text_elements") or []}
        if value.get("type") == "text" else value
        for value in inputs
    ]
    active = active_turn_id(args.thread)
    if active:
        if args.model:
            raise BridgeError("cannot change model while steering an active turn",
                              code="active_model_override")
        method = "thread-follower-steer-turn"
        params = {"conversationId": args.thread, "input": desktop_inputs,
                  "clientUserMessageId": message_id,
                  "restoreMessage": desktop_restore_message(
                      args.thread, desktop_inputs, message_id, cwd=cwd)}
        action = "steered"
    else:
        method = "thread-follower-start-turn"
        request = {"threadId": args.thread, "clientUserMessageId": message_id,
                   "input": desktop_inputs, "turnTrigger": "walkie-talkie"}
        if args.model:
            request["model"] = args.model
        params = {"conversationId": args.thread,
                  "turnStart": {"request": request, "context": {}}}
        action = "started"
    with DesktopIpcClient() as client:
        result, _ = client.follower_request(args.thread, method, params)
    return {"ok": True, "threadId": args.thread,
            "turnId": nested_turn_id(result), "action": action,
            "transport": "desktop-ipc"}


def send_existing(args):
    text = read_text_file(args.text_file)
    inputs = make_input(text, args.image)
    try:
        client = RpcClient()
    except BridgeError as error:
        if error.code != "shared_daemon_unavailable":
            raise
        return send_desktop(args, inputs)
    with client:
        read = client.request("thread/read", {"threadId": args.thread, "includeTurns": False})
        thread = read.get("thread") or {}
        status = (thread.get("status") or {}).get("type")
        if status == "systemError":
            raise BridgeError("thread is in system-error state", code="thread_unavailable")
        if status == "active":
            if args.model:
                raise BridgeError("cannot change model while steering an active turn",
                                  code="active_model_override")
            expected_turn = getattr(args, "expected_turn", None)
            active = {"id": expected_turn} if expected_turn else None
            if active is None:
                turns = client.request("thread/turns/list", {
                    "threadId": args.thread, "limit": 5,
                    "sortDirection": "desc", "itemsView": "notLoaded",
                })
                active = next((turn for turn in turns.get("data", [])
                               if turn.get("status") == "inProgress"), None)
            if active is None:
                raise BridgeError(
                    "thread is active but its active turn id is unavailable",
                    code="active_turn_unresolved",
                )
            result = client.request("turn/steer", {
                "threadId": args.thread,
                "expectedTurnId": active["id"],
                "clientUserMessageId": str(uuid.uuid4()),
                "input": inputs,
            })
            return {"ok": True, "threadId": args.thread,
                    "turnId": result.get("turnId"), "action": "steered",
                    "transport": "app-server-websocket"}
        if status == "notLoaded":
            # A desktop window may own this same stored thread while the shared
            # daemon reports it as unloaded. Prefer the app's owner-routed IPC;
            # if no owner exists, require an explicit launcher resume instead
            # of creating a second live copy behind the user's back.
            try:
                return send_desktop(args, inputs, cwd=thread.get("cwd"))
            except BridgeError as error:
                if error.code not in ("desktop_ipc_unavailable", "desktop_thread_not_owned"):
                    raise
            raise BridgeError(
                "thread is not owned by the shared daemon or a desktop window; resume it explicitly",
                code="thread_not_owned",
            )
        params = {
            "threadId": args.thread,
            "clientUserMessageId": str(uuid.uuid4()),
            "input": inputs,
            "turnTrigger": "walkie-talkie",
        }
        if args.model:
            params["model"] = args.model
        result = client.request("turn/start", params)
        return {"ok": True, "threadId": args.thread,
                "turnId": (result.get("turn") or {}).get("id"), "action": "started",
                "transport": "app-server-websocket"}


def project_rows():
    connection = connect_readonly(db_path("state_5.sqlite"))
    try:
        rows = connection.execute("""
            SELECT p.id, p.name, p.metadata, p.position, p.created_at_ms,
                   p.updated_at_ms, r.position AS root_position, r.path
              FROM projects p
              LEFT JOIN project_roots r ON r.project_id = p.id
             ORDER BY p.position, r.position
        """).fetchall()
        activity = [dict(row) for row in connection.execute("""
            SELECT cwd, tokens_used, has_user_event,
                   COALESCE(NULLIF(recency_at_ms, 0), updated_at_ms, updated_at * 1000) AS used_at_ms
              FROM threads WHERE archived = 0
        """)]
        projects = []
        by_id = {}
        for raw in rows:
            project = by_id.get(raw["id"])
            if project is None:
                try:
                    metadata = json.loads(raw["metadata"] or "{}")
                except ValueError:
                    metadata = {}
                project = {
                    "id": raw["id"], "name": raw["name"], "paths": [], "path": "",
                    "position": raw["position"],
                    "createdAt": (raw["created_at_ms"] or 0) / 1000,
                    "updatedAt": (raw["updated_at_ms"] or 0) / 1000,
                    "metadata": metadata, "score": 0, "prompts": 0, "lastUsed": 0,
                }
                projects.append(project)
                by_id[raw["id"]] = project
            if raw["path"]:
                project["paths"].append(raw["path"])
                if not project["path"]:
                    project["path"] = raw["path"]
        cutoff_ms = int((time.time() - 14 * 86400) * 1000)
        for project in projects:
            for thread in activity:
                cwd = thread["cwd"] or ""
                if not any(cwd == root or cwd.startswith(root.rstrip("/") + "/")
                           for root in project["paths"]):
                    continue
                used_at = thread["used_at_ms"] or 0
                project["lastUsed"] = max(project["lastUsed"], used_at / 1000)
                if used_at >= cutoff_ms:
                    project["score"] += int(thread["tokens_used"] or 0)
                    project["prompts"] += int(bool(thread["has_user_event"]))
        projects.sort(key=lambda row: (-row["score"], -row["lastUsed"], row["position"]))
        return projects
    finally:
        connection.close()


def extract_visible(item_type, item_json):
    try:
        item = json.loads(item_json)
    except ValueError:
        return None
    if item_type in ("agentMessage", "plan"):
        text = item.get("text")
        return ("codex", text) if isinstance(text, str) and text.strip() else None
    if item_type != "userMessage":
        return None
    parts = []
    for block in item.get("content") or []:
        if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
            parts.append(block["text"])
    text = "\n".join(parts).strip()
    return ("me", text) if text else None


def snippet(text, terms, before=60, after=140):
    lower = text.lower()
    positions = [lower.find(term) for term in terms]
    positions = [position for position in positions if position >= 0]
    at = min(positions) if positions else 0
    start, end = max(0, at - before), min(len(text), at + after)
    value = " ".join(text[start:end].split())
    return ("…" if start else "") + value + ("…" if end < len(text) else "")


def search_threads(args):
    terms = [term for term in args.query.lower().split() if term]
    started = time.time()
    if not terms:
        print_json({"done": True, "found": 0, "scanned": 0, "elapsed": 0})
        return
    state = connect_readonly(db_path("state_5.sqlite"))
    history = connect_readonly(db_path("thread_history_1.sqlite"))
    cutoff_ms = int((time.time() - args.days * 86400) * 1000)
    try:
        metadata = {row["id"]: dict(row) for row in state.execute("""
            SELECT id, rollout_path, cwd, title, name, preview, git_branch,
                   updated_at, updated_at_ms
              FROM threads
             WHERE archived = 0 AND COALESCE(updated_at_ms, updated_at * 1000) >= ?
        """, (cutoff_ms,))}
        if not metadata:
            print_json({"done": True, "found": 0, "scanned": 0,
                        "elapsed": round(time.time() - started, 3)})
            return
        placeholders = ",".join("?" for _ in metadata)
        items = history.execute(f"""
            SELECT thread_id, item_type, item_json, created_at_ms
              FROM thread_items
             WHERE thread_id IN ({placeholders})
               AND item_type IN ('userMessage', 'agentMessage', 'plan')
             ORDER BY created_at_ms DESC, rollout_ordinal DESC
        """, tuple(metadata))
        found = {}
        ttys = sidecar_tty_map()
        for raw in items:
            visible = extract_visible(raw["item_type"], raw["item_json"])
            if not visible:
                continue
            role, text = visible
            lower = text.lower()
            if not all(term in lower for term in terms):
                continue
            thread_id = raw["thread_id"]
            row = found.get(thread_id)
            if row is None:
                meta = metadata[thread_id]
                cwd = meta["cwd"] or ""
                tty = ttys.get(thread_id)
                row = {
                    "session": thread_id, "path": meta["rollout_path"] or "",
                    "mtime": (meta["updated_at_ms"] / 1000 if meta["updated_at_ms"]
                              else meta["updated_at"]),
                    "cwd": cwd, "folder": Path(cwd).name or cwd,
                    "branch": meta["git_branch"] or "",
                    "title": meta["name"] or meta["title"] or meta["preview"] or "",
                    "hits": 0, "role": role, "snippet": snippet(text, terms),
                    "tty": tty["tty"] if tty else None, "ttyOwner": bool(tty),
                }
                found[thread_id] = row
            row["hits"] += 1
        rows = sorted(found.values(), key=lambda value: value["mtime"], reverse=True)[:args.limit]
        owned = desktop_owned_ids([row["session"] for row in rows])
        for row in rows:
            if row["session"] in owned and row["tty"] is None:
                row["tty"] = "codex:" + row["session"]
                row["ttyOwner"] = True
            print_json(row)
        print_json({"done": True, "found": len(rows), "scanned": len(metadata),
                    "elapsed": round(time.time() - started, 3)})
    finally:
        history.close()
        state.close()


def history_page(args):
    try:
        with RpcClient() as client:
            params = {"threadId": args.thread, "limit": args.limit,
                      "sortDirection": args.direction, "itemsView": "full"}
            if args.cursor:
                params["cursor"] = args.cursor
            result = client.request("thread/turns/list", params)
            return {"threadId": args.thread, "turns": result.get("data", []),
                    "nextCursor": result.get("nextCursor"),
                    "backwardsCursor": result.get("backwardsCursor"), "live": True}
    except BridgeError as error:
        if error.code != "shared_daemon_unavailable":
            raise
    history = connect_readonly(db_path("thread_history_1.sqlite"))
    try:
        direction = "ASC" if args.direction == "asc" else "DESC"
        turns = []
        for turn in history.execute(f"""
            SELECT turn_id, status, error_json, started_at, completed_at, duration_ms
              FROM thread_turns WHERE thread_id = ?
             ORDER BY rollout_ordinal {direction} LIMIT ?
        """, (args.thread, args.limit)):
            items = []
            for item in history.execute("""
                SELECT item_json FROM thread_items
                 WHERE thread_id = ? AND turn_id = ? ORDER BY rollout_ordinal
            """, (args.thread, turn["turn_id"])):
                try:
                    items.append(json.loads(item["item_json"]))
                except ValueError:
                    continue
            turns.append({"id": turn["turn_id"], "status": turn["status"],
                          "error": json.loads(turn["error_json"]) if turn["error_json"] else None,
                          "startedAt": turn["started_at"], "completedAt": turn["completed_at"],
                          "durationMs": turn["duration_ms"], "items": items})
        return {"threadId": args.thread, "turns": turns, "nextCursor": None,
                "backwardsCursor": None, "live": False}
    finally:
        history.close()


def quick_answer(client, request):
    request_id = str(request.get("id") or uuid.uuid4())
    text = request.get("text")
    if not isinstance(text, str) or not text.strip():
        raise BridgeError("quick question is empty", code="empty_message")
    system_prompt = request.get("system") or DEFAULT_QUICK_SYSTEM
    # The caller's cwd is deliberately not used. Project-local instructions and
    # settings are part of a full Codex session, not a context-free Quick Ask.
    cwd = client.private_workspace
    if cwd is None:
        raise BridgeError("quick worker is not isolated", code="quick_isolation_error")
    start_params = {
        "cwd": str(Path(cwd).expanduser().resolve()),
        "ephemeral": True,
        "approvalPolicy": "never",
        "sandbox": "read-only",
        "serviceName": "walkie-talkie-quick",
        "baseInstructions": system_prompt,
        "developerInstructions": "",
        "dynamicTools": [],
        "environments": [],
        "selectedCapabilityRoots": [],
        "config": {
            "web_search": "live" if request.get("web") else "disabled",
            "tools": {
                "experimental_request_user_input": {"enabled": False},
                "update_plan": {"enabled": False},
            },
        },
    }
    if request.get("model"):
        start_params["model"] = request["model"]
    started = client.request("thread/start", start_params, timeout=30)
    thread = started.get("thread") or {}
    thread_id = thread.get("id")
    if not thread_id:
        raise BridgeError("quick thread did not start", code="protocol_error")
    turn_params = {"threadId": thread_id, "input": [{"type": "text", "text": text}]}
    if request.get("model"):
        turn_params["model"] = request["model"]
    if request.get("effort"):
        turn_params["effort"] = request["effort"]
    turn_result = client.request("turn/start", turn_params, timeout=30)
    turn_id = (turn_result.get("turn") or {}).get("id")
    cumulative = ""
    deadline = time.monotonic() + 180
    while True:
        message = client.receive(deadline=deadline)
        if message.get("id") is not None:
            # Any server callback means a tool or approval path escaped the
            # startup restrictions. Reject it and fail the request.
            if message.get("method"):
                client.send({"id": message["id"], "error": {
                    "code": -32601, "message": "quick worker does not service tools"}})
                raise BridgeError("quick worker denied a tool request",
                                  code="quick_tool_denied")
            continue
        method, params = message.get("method"), message.get("params") or {}
        if params.get("threadId") != thread_id:
            continue
        if method == "item/started":
            item_type = (params.get("item") or {}).get("type")
            allowed = {"userMessage", "agentMessage", "reasoning"}
            if request.get("web"):
                allowed.add("webSearch")
            if item_type not in allowed:
                try:
                    client.request("turn/interrupt", {
                        "threadId": thread_id, "turnId": turn_id,
                    }, timeout=5)
                except BridgeError:
                    pass
                raise BridgeError(
                    f"quick worker denied tool item: {item_type or 'unknown'}",
                    code="quick_tool_denied",
                )
        if method == "item/agentMessage/delta" and params.get("turnId") == turn_id:
            cumulative += params.get("delta") or ""
            print_json({"type": "delta", "id": request_id, "text": cumulative})
        elif method == "turn/completed" and (params.get("turn") or {}).get("id") == turn_id:
            turn = params.get("turn") or {}
            if turn.get("status") != "completed":
                error = turn.get("error") or {}
                raise BridgeError(error.get("message") or f"quick turn {turn.get('status')}",
                                  code="quick_turn_failed")
            model = started.get("model") or request.get("model") or thread.get("model")
            print_json({"type": "completed", "id": request_id, "text": cumulative,
                        "model": model, "threadId": thread_id, "turnId": turn_id})
            return


def quick_worker():
    client = None
    old_term = signal.getsignal(signal.SIGTERM)
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(0)))
    try:
        client = RpcClient(private=True, timeout=20)
        print_json({"type": "ready", "model": None})
        for line in sys.stdin:
            request = None
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise BridgeError("quick request must be an object", code="invalid_request")
                quick_answer(client, request)
            except (ValueError, BridgeError) as error:
                print_json(error_object(error, event=True,
                                        request_id=request.get("id") if isinstance(request, dict) else None))
    finally:
        signal.signal(signal.SIGTERM, old_term)
        if client:
            client.close()


def print_json(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def error_object(error, *, event=False, request_id=None):
    if isinstance(error, BridgeError):
        payload = {"error": str(error), "code": error.code}
        if error.details:
            payload["details"] = error.details
    else:
        payload = {"error": str(error), "code": "internal_error"}
    if event:
        payload["type"] = "error"
        if request_id is not None:
            payload["id"] = str(request_id)
    return payload


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    listed = commands.add_parser("list")
    listed.add_argument("--limit", type=int, default=100)
    listed.add_argument("--cursor")
    listed.add_argument("--cwd")
    listed.add_argument("--project")
    listed.add_argument("--query")
    listed.add_argument("--live-only", action="store_true")

    thread = commands.add_parser("thread")
    thread.add_argument("--id", required=True)

    send = commands.add_parser("send")
    send.add_argument("--thread", required=True)
    send.add_argument("--text-file", required=True)
    send.add_argument("--image", action="append", default=[])
    send.add_argument("--model")
    send.add_argument("--expected-turn")

    resolve = commands.add_parser("resolve")
    resolve.add_argument("--tty", required=True)

    projects = commands.add_parser("projects")

    search = commands.add_parser("search")
    search.add_argument("--query", required=True)
    search.add_argument("--days", type=float, default=21)
    search.add_argument("--limit", type=int, default=25)

    history = commands.add_parser("history")
    history.add_argument("--thread", required=True)
    history.add_argument("--limit", type=int, default=50)
    history.add_argument("--cursor")
    history.add_argument("--direction", choices=("asc", "desc"), default="desc")

    watch = commands.add_parser("watch-until-idle")
    watch.add_argument("--thread", required=True)
    watch.add_argument("--turn")
    watch.add_argument("--timeout", type=float, default=600)

    quick = commands.add_parser("quick")
    quick.add_argument("--text-file", required=True)
    quick.add_argument("--cwd")
    quick.add_argument("--model")
    quick.add_argument("--effort")
    quick.add_argument("--system")
    quick.add_argument("--web", action="store_true")

    commands.add_parser("quick-worker")
    commands.add_parser("doctor")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == "list":
        print_json(list_threads(args))
    elif args.command == "thread":
        print_json(one_thread(args.id))
    elif args.command == "send":
        print_json(send_existing(args))
    elif args.command == "resolve":
        print_json(resolve_tty(args.tty))
    elif args.command == "projects":
        print_json({"projects": project_rows()})
    elif args.command == "search":
        search_threads(args)
    elif args.command == "history":
        print_json(history_page(args))
    elif args.command == "watch-until-idle":
        print_json(watch_until_idle(args))
    elif args.command == "quick-worker":
        quick_worker()
    elif args.command == "quick":
        request = {"id": str(uuid.uuid4()), "text": read_text_file(args.text_file),
                   "cwd": args.cwd, "model": args.model, "effort": args.effort,
                   "system": args.system, "web": args.web}
        with RpcClient(private=True, timeout=20) as client:
            print_json({"type": "ready", "model": args.model})
            quick_answer(client, request)
    elif args.command == "doctor":
        binary = find_codex()
        version = subprocess.run([str(binary), "--version"], capture_output=True,
                                 text=True, timeout=5, check=False).stdout.strip()
        print_json({"ok": True, "binary": str(binary), "version": version,
                    "sharedSocket": str(control_socket()) if control_socket() else None,
                    "stateDatabase": str(db_path("state_5.sqlite")) if db_path("state_5.sqlite") else None,
                    "historyDatabase": str(db_path("thread_history_1.sqlite")) if db_path("thread_history_1.sqlite") else None})


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        os._exit(0)
    except BridgeError as error:
        print_json(error_object(error))
        raise SystemExit(2)
    except KeyboardInterrupt:
        raise SystemExit(130)
