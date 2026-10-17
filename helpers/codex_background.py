"""Persistent, same-user background client for Codex's shared app-server.

The detached broker owns a subscription, not a private copy of a conversation.
It remains alive when the menu app exits so server approval/question callbacks
stay pending. The private socket is scoped to the exact Codex home; callers never
retry a mutation after sending it, including when its response is lost.
"""
from __future__ import annotations

import argparse
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import queue
import secrets
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
import uuid

sys.dont_write_bytecode = True

from codex_bridge import (BridgeError, RpcClient, UUID_RE, active_turn_id,
                          codex_home, error_object, find_codex, one_thread,
                          stored_turn_status, thread_row)

PROTOCOL = 1
FEATURES = ["idle-release-v1"]
MAX_MESSAGE = 8 * 1024 * 1024
WAITING = {"active", "waitingOnApproval", "waitingOnUserInput"}


def home_key():
    return hashlib.sha256(str(codex_home().expanduser().resolve()).encode()).hexdigest()[:12]


def runtime_dir():
    base = Path(os.environ.get("WALKIE_BACKGROUND_HOME") or
                (Path.home() / ".walkie-talkie" / "codex-background"))
    return base / home_key()


def secure_directory(path):
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o077):
        raise BridgeError("background runtime directory is not private",
                          code="background_security")


def private_file(path):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o077):
        raise BridgeError("background credential is not private", code="background_security")
    return path.read_text().strip()


def atomic_json(path, value):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(value, stream, ensure_ascii=False)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def read_message(stream):
    line = stream.readline(MAX_MESSAGE + 1)
    if not line or len(line) > MAX_MESSAGE or not line.endswith(b"\n"):
        raise BridgeError("invalid background request size", code="background_protocol")
    value = json.loads(line)
    if not isinstance(value, dict):
        raise BridgeError("invalid background request", code="background_protocol")
    return value


def check_peer(sock):
    if hasattr(sock, "getpeereid"):
        uid, _ = sock.getpeereid()
    elif hasattr(socket, "SO_PEERCRED"):
        _, uid, _ = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    else:
        # macOS Python exposes LOCAL_PEERCRED through getpeereid on supported
        # builds. File ownership + a private random token is still required.
        return
    if uid != os.getuid():
        raise BridgeError("background socket belongs to another user", code="background_security")


def _connect(command, params=None, *, timeout=40):
    directory = runtime_dir()
    secure_directory(directory)
    path = directory / "broker.sock"
    info = path.lstat()
    if (not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o077):
        raise BridgeError("background socket is not private", code="background_security")
    token = private_file(directory / "token")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(str(path))
        check_peer(sock)
        request = {"protocol": PROTOCOL, "token": token, "home": home_key(),
                   "command": command, "params": params or {}}
        serialized = json.dumps(request, ensure_ascii=False).encode() + b"\n"
        if len(serialized) > MAX_MESSAGE:
            raise BridgeError("background prompt is too large", code="background_protocol")
        # From this point onward an error has an unknown outcome; never retry.
        try:
            sock.sendall(serialized)
            result = read_message(sock.makefile("rb"))
        except (OSError, ValueError, BridgeError) as error:
            raise BridgeError("background request outcome is unknown; do not resend automatically",
                              code="background_outcome_unknown") from error
    if "error" in result:
        raise BridgeError(result["error"], code=result.get("code", "background_error"),
                          details=result.get("details"))
    return result


def broker_request(command, params=None, *, start=False, timeout=40):
    """Only read-only availability probes may repeat; mutations are sent once."""
    directory = runtime_dir()
    if not start and not (directory / "broker.sock").exists():
        return None
    try:
        _connect("ping", timeout=1)
    except (FileNotFoundError, ConnectionRefusedError):
        if not start:
            return None
        secure_directory(directory)
        # The child acquires an exclusive lifetime lock. Concurrent callers may
        # launch children, but only one may create or unlink the socket/token.
        with (directory / "broker.log").open("ab") as output:
            os.chmod(directory / "broker.log", 0o600)
            subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--serve"],
                             stdin=subprocess.DEVNULL, stdout=output, stderr=output,
                             start_new_session=True, close_fds=True,
                             cwd=str(Path.home()), env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})
        deadline = time.monotonic() + 20
        while True:
            try:
                _connect("ping", timeout=1)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.monotonic() >= deadline:
                    raise BridgeError("background Codex worker did not start", code="background_unavailable")
                time.sleep(0.05)
    return _connect(command, params, timeout=timeout)


def offline_status():
    """A dead worker must never turn submitted work into a false idle badge."""
    path = runtime_dir() / "state.json"
    empty = {"ok": True, "threads": [], "requests": [], "completions": []}
    if not path.exists():
        return empty
    try:
        value = json.loads(private_file(path))
    except (OSError, ValueError):
        return {**empty, "problem": {"code": "background_unavailable", "message": "Background status is unavailable."}}
    rows = [row for row in value.get("threads", []) if row.get("busy") is not False]
    if not rows and not value.get("requests"):
        return empty
    problem = {"code": "background_unavailable", "message": "The background worker stopped; submitted work has an unknown state."}
    for row in rows:
        row.update(state="error", busy=None, live=False, subscribed=False, error=problem)
    return {**empty, "threads": rows, "problem": problem}


class AsyncRPC:
    """One reader keeps native callbacks alive while local requests run."""
    def __init__(self, callback):
        self.client = RpcClient(timeout=20)
        self.callback = callback
        self.lock = threading.RLock()
        self.waiters = {}
        self.next_id = 1000000
        self.failure = None
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        try:
            while True:
                try:
                    message = self.client.receive(deadline=time.monotonic() + 3600)
                except BridgeError as error:
                    if error.code == "protocol_timeout":
                        continue
                    raise
                with self.lock:
                    waiter = self.waiters.get(message.get("id")) if "method" not in message else None
                    if waiter:
                        waiter[1].append(message)
                        waiter[0].set()
                if not waiter:
                    self.callback(message)
        except Exception as error:
            with self.lock:
                self.failure = error
                for event, _ in self.waiters.values():
                    event.set()
            self.callback({"method": "walkie/connectionLost", "params": {"reason": str(error)}})

    def send(self, message):
        with self.lock:
            if self.failure:
                raise BridgeError("background Codex connection was lost", code="background_connection_lost")
            self.client.send(message)

    def request(self, method, params, timeout=30):
        event, reply = threading.Event(), []
        with self.lock:
            request_id = self.next_id
            self.next_id += 1
            self.waiters[request_id] = (event, reply)
        try:
            try:
                self.send({"id": request_id, "method": method, "params": params})
            except OSError as error:
                raise BridgeError("Codex request outcome is unknown; do not resend automatically",
                                  code="background_outcome_unknown", details={"method": method}) from error
            if not event.wait(timeout) or not reply:
                raise BridgeError("Codex request outcome is unknown; do not resend automatically",
                                  code="background_outcome_unknown",
                                  details={"method": method})
            return RpcClient._result(reply[0])
        finally:
            with self.lock:
                self.waiters.pop(request_id, None)


def approval_detail(method, params, item=None):
    """Review the actual action without exposing transport metadata as UI."""
    lines = []
    if params.get("reason"):
        lines.append(str(params["reason"]))
    command = params.get("command") or (item or {}).get("command")
    if isinstance(command, list):
        import shlex
        command = shlex.join(str(part) for part in command)
    if command:
        lines.append(("Input to running command:\n" if params.get("kind") == "writeStdin" else "Command:\n") + str(command))
    if params.get("cwd"):
        lines.append("Folder: " + str(params["cwd"]))
    if params.get("grantRoot"):
        lines.append("Allow writes under: " + str(params["grantRoot"]) + " for the remainder of this session.")
    changes = (item or {}).get("changes") or params.get("fileChanges") or []
    if isinstance(changes, dict):
        changes = [{"path": path, **(value if isinstance(value, dict) else {})} for path, value in changes.items()]
    for change in changes:
        if not isinstance(change, dict):
            continue
        lines.append("File: " + str(change.get("path") or "Unknown path"))
        kind = change.get("type") or change.get("kind")
        if kind:
            lines.append("Change: " + str(kind))
        for key in ("diff", "unified_diff", "content"):
            if change.get(key):
                lines.append(str(change[key]))
        if change.get("move_path"):
            lines.append("Move to: " + str(change["move_path"]))
    permissions = params.get("permissions") or {}
    filesystem = permissions.get("fileSystem") or {}
    for key, label in (("read", "Read"), ("write", "Write")):
        for path in filesystem.get(key) or []:
            lines.append(label + ": " + str(path))
    for entry in filesystem.get("entries") or []:
        path = entry.get("path") or {}
        target = path.get("path") or path.get("pattern")
        if not target:
            special = path.get("value") or {}
            target = str(special.get("kind", "special location")) + (": " + str(special["path"]) if special.get("path") else "")
        lines.append(str(entry.get("access", "Access")).capitalize() + ": " + str(target))
    if (permissions.get("network") or {}).get("enabled"):
        lines.append("Allow network access for this turn.")
    network = params.get("networkApprovalContext") or {}
    if network:
        lines.append("Network destination: " + str(network.get("host") or network.get("hostname") or "See command"))
    if method in {"item/fileChange/requestApproval", "applyPatchApproval"} and not changes:
        lines.append("The proposed file diff is not available yet. Approval is disabled until it can be reviewed.")
    return "\n\n".join(lines) or "This request is not supported by this version of Walkie Talkie. It remains pending; no action has been approved."


def request_view(message, item=None):
    params, method = message.get("params") or {}, message["method"]
    result = {"id": str(uuid.uuid4()), "threadId": params.get("threadId", params.get("conversationId")),
              "method": method, "params": params, "kind": "unsupported", "choices": [],
              "title": "Codex needs a response", "detail": approval_detail(method, params, item),
              "timestamp": time.time()}
    if method in {"item/commandExecution/requestApproval", "item/fileChange/requestApproval"}:
        result.update(kind="approval", title="Approve command" if "commandExecution" in method else "Approve file changes")
        result["choices"] = [
            {"id": decision, "label": label, "response": {"decision": decision}}
            for decision, label in (("accept", "Approve once"), ("decline", "Decline"), ("cancel", "Stop turn"))]
        available = params.get("availableDecisions")
        if isinstance(available, list):
            result["choices"] = [choice for choice in result["choices"] if choice["id"] in available]
        if method == "item/fileChange/requestApproval" and not ((item or {}).get("changes") or params.get("fileChanges")):
            result["choices"] = [choice for choice in result["choices"] if choice["id"] != "accept"]
        if method == "item/commandExecution/requestApproval" and not (params.get("command") or (item or {}).get("command")):
            result["detail"] += "\n\nThe command is unavailable for review. Approval is disabled."
            result["choices"] = [choice for choice in result["choices"] if choice["id"] != "accept"]
    elif method == "item/permissions/requestApproval":
        result.update(kind="approval", title="Approve additional permissions")
        result["choices"] = [
            {"id": "approve", "label": "Approve for this turn", "response": {
                "permissions": params.get("permissions") or {}, "scope": "turn"}},
            {"id": "decline", "label": "Decline", "response": {"permissions": {}, "scope": "turn"}}]
    elif method == "item/tool/requestUserInput":
        result.update(kind="questions", title="Codex has questions", questions=params.get("questions") or [])
    # Older native approval variants use different decision spelling.
    elif method in {"execCommandApproval", "applyPatchApproval"}:
        result.update(kind="approval", title="Approve command" if method == "execCommandApproval" else "Approve file changes")
        result["choices"] = [
            {"id": decision, "label": label, "response": {"decision": decision}}
            for decision, label in (("approved", "Approve once"), ("denied", "Decline"), ("abort", "Stop turn"))]
        if method == "applyPatchApproval" and not params.get("fileChanges"):
            result["choices"] = [choice for choice in result["choices"] if choice["id"] != "approved"]
    return result


def validate_response(request, response):
    if not isinstance(response, dict):
        raise BridgeError("response must be an object", code="invalid_response")
    if request["kind"] == "approval":
        if response not in [choice["response"] for choice in request["choices"]]:
            raise BridgeError("approval response is not one of the offered choices", code="invalid_response")
    elif request["kind"] == "questions":
        answers = response.get("answers")
        expected = {item["id"] for item in request.get("questions", [])}
        if not isinstance(answers, dict) or set(answers) != expected:
            raise BridgeError("answer every Codex question", code="invalid_response")
        for answer in answers.values():
            if (not isinstance(answer, dict) or not isinstance(answer.get("answers"), list)
                    or not answer["answers"] or not all(isinstance(x, str) and x.strip() for x in answer["answers"])):
                raise BridgeError("question answer is empty", code="invalid_response")
    else:
        raise BridgeError("this Codex callback is unsupported; it remains pending",
                          code="unsupported_callback")


def verified_shared_cli_owner(thread_id, owner):
    """A known remote TUI may rejoin our same shared writer, never a private one."""
    from codex_bridge import (DesktopIpcClient, process_rows, sidecar_tty_map,
                              verified_codex_resume_process)
    import shlex
    record = sidecar_tty_map().get(thread_id)
    if not record or record.get("pid") != owner.get("pid"):
        return False
    process = next((row for row in process_rows() if row["pid"] == record["pid"]), None)
    if not process or not verified_codex_resume_process(
            process, tty=record.get("childTTY") or record["tty"], thread_id=thread_id):
        return False
    try:
        argv = shlex.split(process["command"])
    except ValueError:
        return False
    remote = any(arg == "--remote=unix://" or (arg == "--remote" and index + 1 < len(argv)
                 and argv[index + 1] == "unix://") for index, arg in enumerate(argv))
    if not remote:
        return False
    # Even a verified shared TUI cannot authorize resuming a Desktop writer.
    try:
        with DesktopIpcClient(timeout=12) as desktop:
            desktop.find_owner(thread_id)
    except BridgeError as error:
        return error.code == "desktop_thread_not_owned"
    return False


class Broker:
    def __init__(self, directory, rpc_factory=AsyncRPC, *, start_release_worker=True):
        self.directory = directory
        self.lock = threading.RLock()
        self.mutation = threading.Lock()
        self.threads = {}
        self.requests = {}
        self.native_requests = {}
        self.completions = []
        self.items = {}
        self.problem = None
        self.release_queue = queue.Queue()
        self.release_worker = None
        state_path = directory / "state.json"
        if state_path.exists():
            try:
                previous = json.loads(private_file(state_path))
                interrupted = [value for value in previous.get("threads", [])
                               if value.get("background") and value.get("busy") is not False]
                if interrupted or previous.get("requests"):
                    self.problem = {"code": "background_previous_connection_lost", "message":
                                    "The previous background worker stopped. Its pending native requests cannot be replayed automatically."}
                    for value in interrupted:
                        value.update(state="error", status="unknown", busy=None, live=False,
                                     subscribed=False, error=self.problem)
                        self.threads[value["id"]] = value
                    # Callback IDs are connection-scoped. Show an explanation,
                    # never attach old approval choices to a new connection.
                    for value in previous.get("requests", []):
                        value.update(kind="unsupported", choices=[], responding=False,
                                     title="Previous Codex connection stopped",
                                     detail="This request belonged to a disconnected worker. It has not been approved. Open Codex to recover the chat; Walkie will not replay it.")
                        self.requests[value["id"]] = value
            except (OSError, ValueError):
                self.problem = {"code": "background_previous_state_unreadable", "message": "Previous background status could not be read."}
        self.rpc = rpc_factory(self.on_message)
        if start_release_worker:
            self.release_worker = threading.Thread(target=self._release_loop,
                                                   name="walkie-idle-release", daemon=True)
            self.release_worker.start()

    def snapshot(self):
        with self.lock:
            return copy.deepcopy({"ok": True, "threads": list(self.threads.values()),
                                  "requests": list(self.requests.values()),
                                  "completions": self.completions, "problem": self.problem,
                                  "pid": os.getpid(), "protocol": PROTOCOL, "features": FEATURES})

    def persist(self):
        # Never used as authority after a process restart. Native request IDs
        # belong to this live RPC connection and cannot safely be replayed.
        atomic_json(self.directory / "state.json", self.snapshot())

    def on_message(self, message):
        method, params = message.get("method"), message.get("params") or {}
        if not method:
            return
        with self.lock:
            if "id" in message:
                item = self.items.get((params.get("threadId"), params.get("itemId")))
                view = request_view(message, item)
                if view["threadId"] not in self.threads:
                    # Account-level/incompatible callbacks are surfaced, but
                    # guardian/subagent requests never become explorer chats.
                    view["title"] = "Codex background connection needs attention" if not view["threadId"] else view["title"]
                self.requests[view["id"]] = view
                self.native_requests[view["id"]] = message["id"]
                row = self.threads.get(view["threadId"])
                if row:
                    row.update(state="waitingOnUserInput" if view["kind"] == "questions" else "waitingOnApproval", busy=True)
            elif method in {"item/started", "item/completed"}:
                item = params.get("item") or {}
                if item.get("type") in {"fileChange", "commandExecution"}:
                    self.items[(params.get("threadId"), item.get("id"))] = item
                    for key, request in list(self.requests.items()):
                        if request["threadId"] == params.get("threadId") and request["params"].get("itemId") == item.get("id"):
                            refreshed = request_view({"method": request["method"], "params": request["params"]}, item)
                            request.update(detail=refreshed["detail"], choices=refreshed["choices"])
            elif method == "thread/status/changed":
                row = self.threads.get(params.get("threadId"))
                if row:
                    status = params.get("status") or {}
                    state = status.get("type", "unknown")
                    flags = status.get("activeFlags") or []
                    if "waitingOnUserInput" in flags:
                        state = "waitingOnUserInput"
                    elif "waitingOnApproval" in flags:
                        state = "waitingOnApproval"
                    row.update(state=state, status=status.get("type", "unknown"), busy=state in WAITING)
                    if state == "idle":
                        self._schedule_release(row)
            elif method in {"turn/started", "turn/completed"}:
                row = self.threads.get(params.get("threadId"))
                turn = params.get("turn") or {}
                if row:
                    row.update(turnId=turn.get("id") or row.get("turnId"))
                    if method == "turn/started":
                        row.update(state="active", status="active", busy=True)
                    else:
                        self.complete(row, turn.get("status", "unknown"))
            elif method == "serverRequest/resolved":
                native_id = params.get("requestId")
                resolved_threads = set()
                for key in list(self.requests):
                    if self.native_requests.get(key) == native_id:
                        resolved_threads.add(self.requests[key].get("threadId"))
                        self.requests.pop(key, None)
                        self.native_requests.pop(key, None)
                for thread_id in resolved_threads:
                    row = self.threads.get(thread_id)
                    if row:
                        self._schedule_release(row)
            elif method == "walkie/connectionLost":
                self.problem = {"code": "background_connection_lost", "message": params.get("reason")}
                for row in self.threads.values():
                    if row.get("background"):
                        row.update(state="error", busy=None, error=self.problem)
            else:
                return
        self.persist()

    def complete(self, row, status):
        row.update(state="idle" if status == "completed" else "error", status="idle", busy=False,
                   turnStatus=status)
        if status == "completed":
            key = row["id"] + ":" + str(row.get("turnId"))
            if not any(value["id"] == key for value in self.completions):
                self.completions.append({"id": key, "threadId": row["id"], "turnId": row.get("turnId"),
                                         "timestamp": time.time(), "status": "completed"})
                del self.completions[:-200]
        if status != "completed":
            for key, request in list(self.requests.items()):
                if request["threadId"] == row["id"] and request.get("params", {}).get("turnId") == row.get("turnId"):
                    self.requests.pop(key, None)
                    self.native_requests.pop(key, None)
        self._schedule_release(row)

    def _schedule_release(self, row):
        if (row.get("turnStatus") == "completed" and row.get("background") and row.get("subscribed")
                and row.get("state") == "idle" and row.get("busy") is False
                and not any(value.get("threadId") == row["id"] for value in self.requests.values())
                and row.get("releaseScheduledTurn") != row.get("turnId")):
            row["releaseScheduledTurn"] = row.get("turnId")
            # Native responses are read on this callback's thread. Waiting for
            # an RPC response here would deadlock that reader. A separate queue
            # serializes release with later sends/opening without waiting for
            # the daemon's roughly one-minute idle writer-retention interval.
            self.release_queue.put((row["id"], row.get("turnId")))

    def _release_loop(self):
        while True:
            item = self.release_queue.get()
            try:
                if item is None:
                    return
                released = self.release_idle(*item)
                if not released:
                    with self.lock:
                        row = self.threads.get(item[0])
                        if row and row.get("releaseScheduledTurn") == item[1]:
                            row.pop("releaseScheduledTurn", None)
            except Exception as error:
                # An optional idle release must not terminate the subscriber or
                # retry a request whose outcome may be unknown.
                with self.lock:
                    row = self.threads.get(item[0]) if item else None
                    if row:
                        row["releaseError"] = {"code": getattr(error, "code", "idle_release_failed"),
                                               "message": str(error)}
                try:
                    self.persist()
                except OSError:
                    pass
            finally:
                self.release_queue.task_done()

    def _release_candidate(self, thread_id, turn_id):
        row = self.threads.get(thread_id)
        if (not row or row.get("id") != thread_id or row.get("turnId") != turn_id
                or not row.get("background") or not row.get("subscribed")
                or row.get("state") != "idle" or row.get("busy") is not False
                or row.get("turnStatus") != "completed"
                or any(value.get("threadId") == thread_id for value in self.requests.values())):
            return None
        return row

    def _mark_unsubscribed(self, thread_id, result):
        status = result.get("status") if isinstance(result, dict) else None
        if status not in {"unsubscribed", "notSubscribed", "notLoaded"}:
            raise BridgeError("Codex returned an incompatible unsubscribe result", code="protocol_error")
        with self.lock:
            row = self.threads.get(thread_id)
            if row:
                row.update(subscribed=False, live=False, ownerState="unknown",
                           releaseState="released" if status == "notLoaded" else "waiting",
                           releaseStartedAt=time.time())
                row.pop("releaseError", None)
        self.persist()

    def release_idle(self, thread_id, turn_id):
        """Release only this subscriber after its exact successful idle turn."""
        with self.mutation:
            with self.lock:
                if self._release_candidate(thread_id, turn_id) is None:
                    return False
            thread = (self.rpc.request("thread/read", {
                "threadId": thread_id, "includeTurns": False})).get("thread") or {}
            if thread.get("id") != thread_id or (thread.get("status") or {}).get("type") != "idle":
                return False
            with self.lock:
                # A CLI/native notification can report another turn or request
                # while the metadata RPC was in flight. Recheck before acting.
                if self._release_candidate(thread_id, turn_id) is None:
                    return False
            result = self.rpc.request("thread/unsubscribe", {"threadId": thread_id})
            self._mark_unsubscribed(thread_id, result)
            return True

    def _shared_thread_loaded(self, thread_id):
        cursor = None
        while True:
            params = {"limit": 100}
            if cursor:
                params["cursor"] = cursor
            result = self.rpc.request("thread/loaded/list", params)
            if thread_id in result.get("data", []):
                return True
            cursor = result.get("nextCursor")
            if not cursor:
                return False

    def track(self, thread, *, background, turn_id=None):
        from codex_catalog import guardian_review
        if guardian_review(thread):
            raise BridgeError("guardian review chats are hidden", code="thread_hidden")
        row = thread_row(thread, live=background)
        row.update(background=background, state=row["status"], turnId=turn_id,
                   threadId=row["id"], subscribed=background)
        if background:
            row.update(live=True, tty="codex:" + row["id"], ttyOwner=False, ownerState="live")
        with self.lock:
            old = self.threads.get(row["id"])
            if old and old.get("background") and not background:
                if turn_id:
                    old.update(turnId=turn_id)
                return old
            if old and old.get("turnId") == turn_id:
                return old
            self.threads[row["id"]] = row
        return row

    def create(self, params):
        cwd = Path(params["cwd"]).expanduser().resolve()
        if cwd == Path.home() / "workspace":
            cwd.mkdir(parents=True, exist_ok=True)
        if not cwd.is_dir():
            raise BridgeError("new chat folder is unavailable", code="invalid_cwd")
        inputs = params["input"]
        if not any(value.get("type") == "text" and value.get("text", "").strip() for value in inputs):
            raise BridgeError("message is empty", code="empty_message")
        options = {"cwd": str(cwd)}
        if params.get("model"):
            options["model"] = params["model"]
        # Inherit native approval policy, reviewer, sandbox, model and settings.
        result = self.rpc.request("thread/start", options)
        thread = result.get("thread") or {}
        if not isinstance(thread.get("id"), str) or not UUID_RE.fullmatch(thread["id"]):
            raise BridgeError("Codex returned no valid thread ID", code="protocol_error")
        row = self.track(thread, background=True)
        try:
            return self.start_turn(row, inputs, model=params.get("model"))
        except BridgeError as error:
            details = {**(error.details or {}), "threadId": thread["id"]}
            raise BridgeError(str(error), code=error.code, details=details) from error

    def start_turn(self, row, inputs, model=None, expected_turn=None):
        if row.get("state") in {"waitingOnApproval", "waitingOnUserInput"}:
            raise BridgeError("answer the pending Codex request before sending another prompt", code="thread_waiting")
        thread_id = row["id"]
        read = self.rpc.request("thread/read", {"threadId": thread_id, "includeTurns": False})
        status = ((read.get("thread") or {}).get("status") or {}).get("type")
        if status == "active":
            if model:
                raise BridgeError("cannot change model while steering an active turn", code="active_model_override")
            turn_id = expected_turn or row.get("turnId") or active_turn_id(thread_id)
            if not turn_id:
                raise BridgeError("active turn could not be resolved", code="active_turn_unresolved")
            result = self.rpc.request("turn/steer", {"threadId": thread_id, "expectedTurnId": turn_id,
                                      "clientUserMessageId": str(uuid.uuid4()), "input": inputs})
            row.update(turnId=result.get("turnId") or turn_id, state="active", status="active", busy=True)
            action = "steered"
        elif status == "idle":
            options = {"threadId": thread_id, "input": inputs, "clientUserMessageId": str(uuid.uuid4()),
                       "turnTrigger": "walkie-talkie"}
            if model:
                options["model"] = model
            result = self.rpc.request("turn/start", options)
            turn = result.get("turn") or {}
            # Do not overwrite a very fast completion notification with active.
            with self.lock:
                if row.get("turnId") != turn.get("id"):
                    row.update(turnId=turn.get("id"), state="active", status="active", busy=True)
                    row.pop("turnStatus", None)
            action = "started"
        else:
            raise BridgeError("background chat is no longer safely loaded", code="thread_not_owned")
        self.persist()
        return {"ok": True, "threadId": thread_id, "thread": copy.deepcopy(row), "turnId": row.get("turnId"),
                "action": action, "transport": "background-app-server"}

    def send_existing(self, params):
        thread_id = params["threadId"]
        with self.lock:
            row = self.threads.get(thread_id)
        if row and row.get("state") == "error" and row.get("busy") is None:
            raise BridgeError("the previous Codex connection was lost; recover this chat in Codex before sending again",
                              code="background_connection_lost")
        if not row or not row.get("background") or not row.get("subscribed"):
            # Full owner check immediately before resuming through the SAME
            # shared daemon. Never launch a private app-server for stored chats.
            owner = one_thread(thread_id, require_owner_state=True)
            same_shared_cli = bool(row and row.get("background") and owner.get("live")
                                   and verified_shared_cli_owner(thread_id, owner))
            if owner.get("ownerState") != "closed" and not same_shared_cli:
                raise BridgeError("another Codex client owns this chat", code="thread_not_owned")
            result = self.rpc.request("thread/resume", {"threadId": thread_id})
            row = self.track(result.get("thread") or {}, background=True)
        return self.start_turn(row, params["input"], params.get("model"), params.get("expectedTurnId"))

    def observe(self, params):
        thread_id = params["threadId"]
        result = self.rpc.request("thread/read", {"threadId": thread_id, "includeTurns": False})
        row = self.track(result.get("thread") or {}, background=False, turn_id=params.get("turnId"))
        row.update(state="active", busy=True)
        self.persist()
        return {"ok": True}

    def status(self, params):
        # Stored turn state works for owner-routed Desktop and CLI sends without
        # subscribing, resuming or navigating those clients.
        with self.lock:
            observed = [row.copy() for row in self.threads.values() if not row.get("background") and row.get("busy")]
        for value in observed:
            status = stored_turn_status(value["id"], value.get("turnId"))
            if status and status != "inProgress":
                with self.lock:
                    self.complete(self.threads[value["id"]], status)
        result = self.snapshot()
        if params.get("since") is not None:
            result["completions"] = [value for value in result["completions"] if value["timestamp"] >= params["since"]]
        return result

    def respond(self, params):
        key, response = params["requestId"], params["response"]
        with self.lock:
            request = self.requests.get(key)
            if request is None:
                raise BridgeError("Codex request is no longer pending", code="request_not_pending")
            validate_response(request, response)
            native_id = self.native_requests.get(key)
            if native_id is None:
                raise BridgeError("this request belonged to a disconnected Codex worker", code="request_not_pending")
            # Mark outcome before sending; a failed socket write is not safe to
            # repeat. A later native resolved event also removes the request.
            request["responding"] = True
            if request.get("responseSent"):
                raise BridgeError("response outcome is unknown; do not submit again", code="background_outcome_unknown")
            request["responseSent"] = True
            self.rpc.send({"id": native_id, "result": response})
            self.requests.pop(key, None)
            self.native_requests.pop(key, None)
            row = self.threads.get(request["threadId"])
            if row:
                row.update(state="active", busy=True)
        self.persist()
        return {"ok": True, "requestId": key}

    def prepare_open(self, params):
        thread_id, destination = params["threadId"], params["destination"]
        result = self.rpc.request("thread/read", {"threadId": thread_id, "includeTurns": False})
        thread = result.get("thread") or {}
        from codex_catalog import guardian_review
        if guardian_review(thread):
            raise BridgeError("guardian review chats are hidden", code="thread_hidden")
        status = (thread.get("status") or {}).get("type")
        with self.lock:
            row = self.threads.get(thread_id)
            pending = any(value["threadId"] == thread_id for value in self.requests.values())
        background_owned = bool(row and row.get("background") and row.get("subscribed"))
        if not background_owned:
            owner = one_thread(thread_id, require_owner_state=True)
            if owner.get("live") and str(owner.get("tty") or "").startswith("codex:"):
                if destination == "cli":
                    raise BridgeError("Codex Desktop owns this chat; open it in Desktop", code="desktop_thread_owned")
                # Showing its existing Desktop owner does not change writers.
                return {"ok": True, "safe": True, "threadId": thread_id, "destination": destination, "thread": owner}
        active = status == "active" or active_turn_id(thread_id)
        # Native PTY verification confirms remote CLI attaches to this same
        # daemon writer without interrupting its active turn. Desktop has a
        # separate writer and requires actual unload before opening.
        if pending or (active and not (destination == "cli" and background_owned)):
            raise BridgeError("this chat is working; opening it could interrupt the turn", code="thread_busy")
        if status == "systemError" or (row and row.get("state") == "error" and row.get("busy") is None):
            raise BridgeError("cannot verify that opening this chat is safe", code="thread_ownership_unknown")
        if row and row.get("background") and row.get("subscribed") and destination == "desktop":
            self._mark_unsubscribed(thread_id, self.rpc.request("thread/unsubscribe", {"threadId": thread_id}))
        if destination == "desktop" and status != "notLoaded":
            if self._shared_thread_loaded(thread_id):
                raise BridgeError(
                    "Codex is releasing this chat for Desktop. This normally takes about a minute after its answer; an open CLI view can keep it loaded.",
                    code="thread_release_pending",
                    details={"threadId": thread_id, "releaseStartedAt": (row or {}).get("releaseStartedAt")})
            thread = {**thread, "status": {"type": "notLoaded"}}
            with self.lock:
                if row:
                    row["releaseState"] = "released"
        return {"ok": True, "safe": True, "threadId": thread_id, "destination": destination,
                "thread": thread_row(thread, live=False)}

    def dispatch(self, command, params):
        if command == "ping":
            return {"ok": True, "protocol": PROTOCOL, "home": home_key(), "pid": os.getpid(), "features": FEATURES}
        if command == "status":
            return self.status(params)
        if command == "owns":
            with self.lock:
                row = self.threads.get(params["threadId"])
                # Even after a Desktop preflight unsubscribes, route later
                # sends here so a verified shared resume restores callbacks.
                return {"owned": bool(row and row.get("background")),
                        "subscribed": bool(row and row.get("subscribed"))}
        if command not in {"create", "send", "observe", "respond", "prepare-open"}:
            raise BridgeError("unknown background command", code="background_protocol")
        with self.mutation:
            return {"create": self.create, "send": self.send_existing, "observe": self.observe,
                    "respond": self.respond, "prepare-open": self.prepare_open}[command](params)


def serve():
    directory = runtime_dir()
    secure_directory(directory)
    lock_path = directory / "broker.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_NOFOLLOW | os.O_RDWR, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        return
    subprocess.run([str(find_codex()), "app-server", "daemon", "start"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=20)
    token = secrets.token_urlsafe(48)
    atomic_json(directory / "owner.json", {"pid": os.getpid(), "home": home_key(), "protocol": PROTOCOL})
    token_path = directory / "token"
    token_path.unlink(missing_ok=True)
    fd = os.open(token_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(token)
    broker = Broker(directory)
    path = directory / "broker.sock"
    path.unlink(missing_ok=True)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    os.chmod(path, 0o600)
    server.listen(8)

    def handle(connection):
        with connection:
            connection.settimeout(60)
            try:
                check_peer(connection)
                request = read_message(connection.makefile("rb"))
                if (request.get("protocol") != PROTOCOL or request.get("home") != home_key()
                        or not secrets.compare_digest(str(request.get("token", "")), token)):
                    raise BridgeError("background client authentication/version failed", code="background_security")
                result = broker.dispatch(request.get("command"), request.get("params") or {})
            except Exception as error:
                result = error_object(error)
            try:
                connection.sendall(json.dumps(result, ensure_ascii=False).encode() + b"\n")
            except OSError:
                pass  # Caller disappeared; accepted work continues unchanged.

    try:
        while True:
            connection, _ = server.accept()
            threading.Thread(target=handle, args=(connection,), daemon=True).start()
    finally:
        server.close()
        path.unlink(missing_ok=True)
        os.close(descriptor)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true", required=True)
    parser.parse_args()
    try:
        serve()
    except Exception as error:
        print(json.dumps(error_object(error)), file=sys.stderr)
        raise SystemExit(2)
