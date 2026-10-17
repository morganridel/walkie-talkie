"""Private reusable terminal host. Only its own untouched, idle TUI may be replaced.

The host forwards a real terminal to a native Codex TUI on a private PTY. Both
PIDs, both TTYs, the parent relationship and exact resume ID are checked before
publishing a binding. Any human keyboard input retires the host from reuse and
removes that mapping (a manually entered /new can change the TUI's identity).
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import socket
import subprocess
import sys
import termios
import tty as tty_module
import time

from codex_bridge import (BridgeError, RpcClient, UUID_RE, make_input, process_rows,
                          sidecar_dir, verified_terminal_host)

MAX_REQUEST = 4 * 1024 * 1024
# Parse the byte stream, not individual read() packets. A terminal may split a
# single reply across reads, or combine focus/color/geometry reports in one read.
TERMINAL_TOKEN = re.compile(rb'(?:\x1b\[<[0-9]+;[0-9]+;[0-9]+[Mm]|\x1b\[M[\x20-\xff]{3}|\x1b\[[?>=]?[0-9;:]*[cRn]|\x1b\[[IO]|\x1b\[\?[0-9;]*[u]|\x1b\[\?[0-9;]*\$y|\x1b\[[4689];[0-9;]*t|\x1b\]([0-9]+);[^\x1b\x07]*(?:\x07|\x1b\\)|\x1bP[^\x1b]*\x1b\\)')
TERMINAL_REPLY = re.compile(b'(?:' + TERMINAL_TOKEN.pattern + b')+')


class TerminalInput:
    """Recognize automatic responses without retaining keyboard input."""
    def __init__(self):
        self.pending = b''
        self.deadline = 0
        self.dirty = False
        self.reason = None

    @staticmethod
    def incomplete(data):
        if data == b'\x1b':
            return True
        if data.startswith(b'\x1b[M'):
            return len(data) < 6 and all(byte >= 0x20 for byte in data[3:])
        if data.startswith(b'\x1b['):
            return all(0x20 <= byte <= 0x3f for byte in data[2:])
        if data.startswith((b'\x1b]', b'\x1bP')):
            # A final ESC may be the first half of the ST terminator.
            body = data[2:]
            return b'\x07' not in body and b'\x1b' not in body.rstrip(b'\x1b')
        return False

    def feed(self, data):
        if self.dirty:
            return
        data = self.pending + data
        self.pending = b''
        while data:
            match = TERMINAL_TOKEN.match(data)
            if match:
                data = data[match.end():]
            elif len(data) <= 4096 and self.incomplete(data):
                self.pending = data
                self.deadline = time.monotonic() + 0.2
                return
            else:
                self.dirty = True
                if data.startswith(b'\x1b[<'):
                    self.reason = 'unrecognized_control_input:mouse'
                elif data.startswith(b'\x1b['):
                    self.reason = 'unrecognized_control_input:csi'
                elif data.startswith(b'\x1b]'):
                    self.reason = 'unrecognized_control_input:osc'
                elif data.startswith(b'\x1bP'):
                    self.reason = 'unrecognized_control_input:dcs'
                elif data.startswith(b'\x1b'):
                    self.reason = 'unrecognized_control_input:other'
                else:
                    self.reason = 'keyboard_input'
                return

    def expire(self):
        if self.pending and time.monotonic() >= self.deadline:
            self.pending = b''
            self.dirty = True
            self.reason = 'incomplete_control_input'


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value) + '\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def read_message(connection):
    data = bytearray()
    while b'\n' not in data:
        block = connection.recv(65536)
        if not block:
            raise BridgeError('terminal connection closed; delivery outcome is unknown')
        data.extend(block)
        if len(data) > MAX_REQUEST:
            raise BridgeError('terminal request is too large')
    return json.loads(bytes(data).split(b'\n', 1)[0])


def try_reuse(request):
    """Unavailable is safe to fall back from; every other outcome is final."""
    rows = {row['pid']: row for row in process_rows()}
    reasons = []
    def result(value):
        # No prompt text or input bytes: retain why an idle terminal was skipped,
        # even if its window is closed before the issue is reported.
        folder = sidecar_dir()
        try:
            folder.mkdir(parents=True, exist_ok=True, mode=0o700)
            atomic_json(folder / 'last-reuse.json', {'at': time.time(),
                        'status': value['status'], 'candidates': reasons})
        except OSError:
            pass  # Diagnostics must never change a delivery outcome.
        return value
    for manifest in sorted(sidecar_dir().glob('host-tty*.json')):
        try:
            record = json.loads(manifest.read_text())
        except (OSError, ValueError):
            reasons.append({'host': manifest.stem, 'reason': 'invalid_manifest'})
            continue
        if not verified_terminal_host(record, rows):
            reasons.append({'host': manifest.stem, 'reason': 'owner_not_verified'})
            continue
        try:
            endpoint = manifest.with_suffix('.sock')
            connection = socket.socket(socket.AF_UNIX)
            connection.settimeout(100)
            try:
                connection.connect(str(endpoint))
            except (ConnectionRefusedError, FileNotFoundError):
                connection.close()
                reasons.append({'host': manifest.stem, 'reason': 'host_not_listening'})
                continue  # No bytes have been sent.
            with connection:
                connection.sendall((json.dumps(request) + '\n').encode())
                reply = read_message(connection)
            reasons.append({'host': manifest.stem, 'reason': reply.get('reason', reply.get('status'))})
            if reply.get('status') == 'unavailable':
                continue
            if reply.get('status') != 'reused':
                raise BridgeError(reply.get('error') or 'terminal delivery outcome is unknown')
            return result(reply)
        except (OSError, ValueError, KeyError) as error:
            raise BridgeError('terminal reuse failed; delivery outcome may be unknown') from error
    return result({'status': 'unavailable'})


def reusable_state(dirty, child_alive, thread):
    return (not dirty and child_alive and thread.get('status', {}).get('type') == 'idle')


class TerminalHost:
    def __init__(self, binary, thread_id, directory, terminal_tty, model=None):
        self.binary, self.thread_id = binary, thread_id
        self.directory, self.tty, self.model = str(directory), terminal_tty, model
        self.child = None
        self.master = None
        self.child_tty = None
        self.dirty = False
        self.input = TerminalInput()
        self.folder = sidecar_dir()
        self.record = self.folder / (Path(self.tty).name + '.json')
        self.manifest = self.folder / ('host-' + Path(self.tty).name + '.json')
        self.endpoint = self.manifest.with_suffix('.sock')

    def resize(self, *_):
        if self.master is not None:
            size = fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(8))
            fcntl.ioctl(self.master, termios.TIOCSWINSZ, size)

    def stop_child(self):
        if self.child is not None and self.child.poll() is None:
            # Closing our PTY releases the UI without blocking its shutdown on
            # output that this same event loop would otherwise have to drain.
            if self.master is not None:
                os.close(self.master)
                self.master = None
            # Popen owns this unreaped PID, so it cannot have been recycled.
            self.child.terminate()
            try:
                self.child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.child.kill()
                self.child.wait(timeout=5)
        if self.master is not None:
            os.close(self.master)
            self.master = None

    def start_child(self):
        self.master, slave = pty.openpty()
        self.child_tty = os.ttyname(slave)
        self.resize()
        command = [self.binary, '--remote', 'unix://', 'resume', self.thread_id]
        if self.model:
            command += ['--model', self.model]
        # Give Codex a controlling PTY while retaining the host's original TTY.
        def setup_child():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        try:
            self.child = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                                          cwd=self.directory, preexec_fn=setup_child)
        finally:
            os.close(slave)
        atomic_json(self.record, {'threadId': self.thread_id, 'tty': self.tty,
                    'pid': self.child.pid, 'childTTY': self.child_tty,
                    'hostPID': os.getpid()})

    def read_input(self):
        data = os.read(0, 65536)
        if not data:
            raise EOFError('terminal input closed')
        self.input.feed(data)
        self.update_input_state()
        os.write(self.master, data)

    def update_input_state(self):
        self.input.expire()
        if self.input.dirty and not self.dirty:
            self.dirty = True
            self.record.unlink(missing_ok=True)
            try:
                atomic_json(self.manifest, {'hostPID': os.getpid(), 'tty': self.tty,
                            'reuseBlocked': self.input.reason})
            except OSError:
                pass

    def drain_pending_input(self):
        # Queued focus/geometry replies are not drafts. Read and classify them
        # just as the regular forwarding loop does before deciding to reuse.
        while True:
            if self.dirty:
                return
            wait = max(0, self.input.deadline - time.monotonic()) if self.input.pending else 0
            if not select.select([0], [], [], wait)[0]:
                self.update_input_state()
                return
            self.read_input()

    def handle(self, request):
        if self.child.poll() is not None:
            return {'status': 'unavailable', 'reason': 'tui_exited'}
        self.drain_pending_input()
        if self.dirty or self.input.pending:
            return {'status': 'unavailable', 'reason': self.input.reason or ('pending_control_input' if self.input.pending else 'keyboard_input')}
        directory = Path(request['directory']).expanduser().resolve()
        prompt = request.get('prompt', '')
        resumed_id = request.get('resume')
        if resumed_id and (not isinstance(resumed_id, str) or not UUID_RE.fullmatch(resumed_id)
                           or prompt or request.get('images')):
            raise BridgeError('opening an existing chat requires its exact ID and no prompt')
        if not directory.is_dir() or not isinstance(prompt, str) or (not resumed_id and not prompt.strip()):
            raise BridgeError('new chat needs an available folder and a first prompt')
        with RpcClient(timeout=20) as client:
            current = client.request('thread/read', {'threadId': self.thread_id, 'includeTurns': False})['thread']
            if current.get('id') != self.thread_id or not reusable_state(self.dirty, self.child.poll() is None, current):
                return {'status': 'unavailable', 'reason': 'thread_' + current.get('status', {}).get('type', 'unknown')}
            # From this point failures are never retried or converted to fallback.
            if resumed_id:
                from codex_background import broker_request
                prepared = broker_request('prepare-open', {'threadId': resumed_id, 'destination': 'cli'})
                if not prepared or not prepared.get('safe'):
                    raise BridgeError('existing chat ownership could not be verified')
                new_id = resumed_id
            else:
                created = client.request('thread/start', {'cwd': str(directory)})['thread']
                new_id = created['id']
                client.request('turn/start', {'threadId': new_id,
                               'input': make_input(prompt, request.get('images', []))}, timeout=30)
        # Keyboard input or a new turn may have arrived while creating the
        # new chat. Preserve the old view in that case; the exact new ID still
        # receives the prompt and is bound independently of this terminal.
        with RpcClient(timeout=20) as client:
            current = client.request('thread/read', {'threadId': self.thread_id, 'includeTurns': False})['thread']
        self.drain_pending_input()
        if self.input.pending or not reusable_state(self.dirty, self.child.poll() is None, current):
            if resumed_id:
                # No prompt or model mutation occurred. A new window may safely
                # show the requested existing chat while preserving this draft.
                return {'status': 'unavailable', 'reason': 'host_changed_while_preparing'}
            return {'status': 'reused', 'threadId': new_id}
        self.record.unlink(missing_ok=True)
        self.stop_child()
        self.thread_id, self.directory = new_id, str(directory)
        self.start_child()
        return {'status': 'reused', 'tty': self.tty, 'threadId': new_id}

    def run(self):
        self.folder.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.folder.chmod(0o700)
        self.endpoint.unlink(missing_ok=True)
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(self.endpoint))
        self.endpoint.chmod(0o600)
        server.listen(4)
        atomic_json(self.manifest, {'hostPID': os.getpid(), 'tty': self.tty})
        old = termios.tcgetattr(0)
        def end(*_):
            raise KeyboardInterrupt()
        for sig in (signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, end)
        signal.signal(signal.SIGWINCH, self.resize)
        try:
            tty_module.setraw(0)
            self.start_child()
            while self.child.poll() is None:
                ready, _, _ = select.select([0, self.master, server], [], [], 0.2)
                if 0 in ready:
                    self.read_input()
                else:
                    self.update_input_state()
                if self.master in ready:
                    try:
                        data = os.read(self.master, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    os.write(1, data)
                if server in ready:
                    connection, _ = server.accept()
                    with connection:
                        connection.settimeout(5)
                        try:
                            reply = self.handle(read_message(connection))
                        except Exception as error:
                            reply = {'status': 'error', 'error': str(error)}
                        try:
                            connection.sendall((json.dumps(reply) + '\n').encode())
                        except OSError:
                            pass  # Outcome is unknown to the caller: no retry.
        except (KeyboardInterrupt, EOFError):
            pass
        finally:
            self.record.unlink(missing_ok=True)
            self.manifest.unlink(missing_ok=True)
            self.endpoint.unlink(missing_ok=True)
            self.stop_child()
            server.close()
            termios.tcsetattr(0, termios.TCSADRAIN, old)
