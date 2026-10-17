import importlib.machinery
import importlib.util
import json
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import codex_terminal as terminal
from helpers import codex_bridge as bridge

THREAD = '11111111-1111-4111-8111-111111111111'
NEW = '22222222-2222-4222-8222-222222222222'


class ReusableTerminalTests(unittest.TestCase):
    def test_open_existing_chat_reuses_host_without_creating_or_sending_prompt(self):
        host = terminal.TerminalHost('/fake/codex', THREAD, '/tmp', '/dev/ttys007')
        host.child = mock.Mock()
        host.child.poll.return_value = None
        rpc = mock.MagicMock()
        rpc.__enter__.return_value = rpc
        rpc.request.return_value = {'thread': {'id': THREAD, 'status': {'type': 'idle'}}}
        with tempfile.TemporaryDirectory() as directory:
            host.record = Path(directory) / 'record'
            with mock.patch.object(terminal, 'RpcClient', return_value=rpc), mock.patch.object(host, 'drain_pending_input'), mock.patch.object(host, 'stop_child') as stop, mock.patch.object(host, 'start_child') as start, mock.patch('codex_background.broker_request', return_value={'safe': True}) as prepare:
                result = host.handle({'directory': '/tmp', 'prompt': '', 'resume': NEW, 'images': []})
        self.assertEqual(result['threadId'], NEW)
        self.assertEqual([call.args[0] for call in rpc.request.call_args_list], ['thread/read', 'thread/read'])
        prepare.assert_called_once_with('prepare-open', {'threadId': NEW, 'destination': 'cli'})
        stop.assert_called_once()
        start.assert_called_once()

    def test_only_idle_untouched_live_child_is_reusable(self):
        for state in ['active', 'notLoaded', 'systemError', 'unknown']:
            self.assertFalse(terminal.reusable_state(False, True, {'status': {'type': state}}))
        self.assertFalse(terminal.reusable_state(True, True, {'status': {'type': 'idle'}}))
        self.assertFalse(terminal.reusable_state(False, False, {'status': {'type': 'idle'}}))
        self.assertTrue(terminal.reusable_state(False, True, {'status': {'type': 'idle'}}))

    def test_keyboard_input_and_drafts_are_not_terminal_replies(self):
        for data in [b'hello', b'/new\r', b'\x1b[A', b'\x03', b'\r', b'\x1b[']:
            self.assertIsNone(terminal.TERMINAL_REPLY.fullmatch(data))
        for data in [b'\x1b[I', b'\x1b[O', b'\x1b[?2026;2$y', b'\x1b[8;40;120t', b'\x1b[1;1R', b'\x1b[?1;2c', b'\x1b]11;rgb:0000/0000/0000\x1b\\']:
            self.assertIsNotNone(terminal.TERMINAL_REPLY.fullmatch(data))

    def test_mapping_requires_both_ttys_parent_and_exact_resume_id(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'ttys007.json'
            record = {'threadId': THREAD, 'tty': '/dev/ttys007', 'pid': 43,
                      'hostPID': 42, 'childTTY': '/dev/ttys008'}
            path.write_text(json.dumps(record))
            rows = [
                {'pid': 42, 'ppid': 1, 'tty': 'ttys007', 'command': '/usr/bin/python3 ' + str(Path(bridge.__file__).parent / 'walkie-codex') + ' --managed --cd /tmp'},
                {'pid': 43, 'ppid': 42, 'tty': 'ttys008', 'command': '/fake/codex --remote unix:// resume ' + THREAD}]
            with mock.patch.object(bridge, 'sidecar_dir', return_value=Path(directory)), mock.patch.object(bridge, 'process_rows', return_value=rows):
                self.assertEqual(bridge.sidecar_tty_map()[THREAD]['tty'], '/dev/ttys007')
                for key, value in [('tty', 'ttys009'), ('ppid', 99), ('command', '/fake/codex resume ' + NEW)]:
                    old = rows[1][key]
                    rows[1][key] = value
                    self.assertEqual(bridge.sidecar_tty_map(), {})
                    rows[1][key] = old
                rows[0]['command'] = '/usr/bin/python3 unrelated.py --managed'
                self.assertEqual(bridge.sidecar_tty_map(), {})

    def test_busy_or_manual_input_never_creates_or_stops_a_chat(self):
        for dirty, state in [(True, 'idle'), (False, 'active')]:
            host = terminal.TerminalHost('/fake/codex', THREAD, '/tmp', '/dev/ttys007')
            host.dirty = dirty
            host.child = mock.Mock()
            host.child.poll.return_value = None
            rpc = mock.MagicMock()
            rpc.__enter__.return_value = rpc
            rpc.request.return_value = {'thread': {'id': THREAD, 'status': {'type': state}}}
            with mock.patch.object(terminal, 'RpcClient', return_value=rpc), mock.patch.object(host, 'drain_pending_input'), mock.patch.object(host, 'stop_child') as stop:
                self.assertEqual(host.handle({'directory': '/tmp', 'prompt': 'hello'})['status'], 'unavailable')
                self.assertNotIn('thread/start', [call.args[0] for call in rpc.request.call_args_list])
                stop.assert_not_called()

    def test_unknown_send_outcome_is_not_retried_or_replaced(self):
        host = terminal.TerminalHost('/fake/codex', THREAD, '/tmp', '/dev/ttys007')
        host.child = mock.Mock()
        host.child.poll.return_value = None
        rpc = mock.MagicMock()
        rpc.__enter__.return_value = rpc
        rpc.request.side_effect = [{'thread': {'id': THREAD, 'status': {'type': 'idle'}}}, {'thread': {'id': NEW}}, terminal.BridgeError('unknown')]
        with mock.patch.object(terminal, 'RpcClient', return_value=rpc), mock.patch.object(host, 'drain_pending_input'), mock.patch.object(host, 'stop_child') as stop:
            with self.assertRaises(terminal.BridgeError):
                host.handle({'directory': '/tmp', 'prompt': 'hello'})
            self.assertEqual([call.args[0] for call in rpc.request.call_args_list], ['thread/read', 'thread/start', 'turn/start'])
            stop.assert_not_called()

    def test_switch_creates_and_submits_once_before_replacing_view(self):
        host = terminal.TerminalHost('/fake/codex', THREAD, '/tmp', '/dev/ttys007')
        host.child = mock.Mock()
        host.child.poll.return_value = None
        host.record = mock.Mock()
        rpc = mock.MagicMock()
        rpc.__enter__.return_value = rpc
        rpc.request.side_effect = [{'thread': {'id': THREAD, 'status': {'type': 'idle'}}}, {'thread': {'id': NEW}}, {}, {'thread': {'id': THREAD, 'status': {'type': 'idle'}}}]
        with mock.patch.object(terminal, 'RpcClient', return_value=rpc), mock.patch.object(host, 'drain_pending_input'), mock.patch.object(host, 'stop_child') as stop, mock.patch.object(host, 'start_child') as start:
            reply = host.handle({'directory': '/tmp', 'prompt': 'first words'})
            self.assertEqual(reply, {'status': 'reused', 'tty': '/dev/ttys007', 'threadId': NEW})
            self.assertEqual(host.thread_id, NEW)
            self.assertEqual([call.args[0] for call in rpc.request.call_args_list].count('turn/start'), 1)
            stop.assert_called_once()
            start.assert_called_once()

    def test_input_arriving_during_rpc_keeps_old_view_and_returns_exact_new_id(self):
        host = terminal.TerminalHost('/fake/codex', THREAD, '/tmp', '/dev/ttys007')
        host.child = mock.Mock()
        host.child.poll.return_value = None
        rpc = mock.MagicMock()
        rpc.__enter__.return_value = rpc
        rpc.request.side_effect = [{'thread': {'id': THREAD, 'status': {'type': 'idle'}}}, {'thread': {'id': NEW}}, {}, {'thread': {'id': THREAD, 'status': {'type': 'idle'}}}]
        drains = []
        def arriving_input():
            drains.append(True)
            if len(drains) == 2:
                host.dirty = True
        with mock.patch.object(terminal, 'RpcClient', return_value=rpc), mock.patch.object(host, 'drain_pending_input', side_effect=arriving_input), mock.patch.object(host, 'stop_child') as stop:
            self.assertEqual(host.handle({'directory': '/tmp', 'prompt': 'first words'}), {'status': 'reused', 'threadId': NEW})
            self.assertEqual(host.thread_id, THREAD)
            stop.assert_not_called()

    def test_transport_failure_never_tries_another_terminal(self):
        with tempfile.TemporaryDirectory() as directory:
            for name in ['host-ttys001.json', 'host-ttys002.json']:
                (Path(directory) / name).write_text('{}')
            connection = mock.MagicMock()
            connection.__enter__.return_value = connection
            with mock.patch.object(terminal, 'sidecar_dir', return_value=Path(directory)), mock.patch.object(terminal, 'process_rows', return_value=[]), mock.patch.object(terminal, 'verified_terminal_host', return_value=True), mock.patch.object(terminal.socket, 'socket', return_value=connection) as connect, mock.patch.object(terminal, 'read_message', side_effect=terminal.BridgeError('unknown')):
                with self.assertRaises(terminal.BridgeError):
                    terminal.try_reuse({'directory': '/tmp', 'prompt': 'only once'})
                self.assertEqual(connect.call_count, 1)
                self.assertEqual(connection.sendall.call_count, 1)

    def test_expired_and_malformed_manifests_are_skipped_without_sending(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'host-ttys001.json').write_text('{')
            (Path(directory) / 'host-ttys002.json').write_text('{}')
            with mock.patch.object(terminal, 'sidecar_dir', return_value=Path(directory)), mock.patch.object(terminal, 'process_rows', return_value=[]), mock.patch.object(terminal.socket, 'socket') as connect:
                self.assertEqual(terminal.try_reuse({'directory': '/tmp', 'prompt': 'hello'}), {'status': 'unavailable'})
                connect.assert_not_called()

    def test_installed_host_path_with_spaces_requires_exact_immediate_managed_flag(self):
        script = '/Applications/Walkie Talkie.app/Contents/Resources/walkie-codex'
        record = {'hostPID': 42, 'tty': '/dev/ttys007'}
        row = {'pid': 42, 'tty': 'ttys007', 'command': '/usr/bin/python3 ' + script + ' --managed --cd /tmp'}
        with mock.patch.object(bridge, '__file__', '/Applications/Walkie Talkie.app/Contents/Resources/codex_bridge.py'):
            self.assertTrue(bridge.verified_terminal_host(record, {42: row}))
            for command in ['/usr/bin/python3 ' + script + ' --cd /tmp -- fake --managed', '/usr/bin/python3 ' + script + '-other --managed', '/usr/bin/python3 unrelated.py --managed']:
                row['command'] = command
                self.assertFalse(bridge.verified_terminal_host(record, {42: row}))

    def test_automatic_terminal_replies_survive_every_packet_boundary(self):
        replies = [b'\x1b[<0;23;19M', b'\x1b[<0;23;19m', b'\x1b[<64;23;19M', b'\x1b[M !~', b'\x1b[1;1R', b'\x1b[?1;2c', b'\x1b[I\x1b[O',
                   b'\x1b[4;800;1200t', b'\x1b[6;16;8t', b'\x1b[8;40;120t',
                   b'\x1b[?0u', b'\x1b[?2026;2$y',
                   b'\x1b]11;rgb:0000/0000/0000\x1b\\',
                   b'\x1bP>|Terminal(1.0)\x1b\\']
        for reply in replies:
            for split in range(len(reply) + 1):
                tracker = terminal.TerminalInput()
                tracker.feed(reply[:split])
                tracker.feed(reply[split:])
                self.assertFalse(tracker.dirty, (reply, split, tracker.reason))
                self.assertEqual(tracker.pending, b'')
        tracker = terminal.TerminalInput()
        for byte in b''.join(replies):
            tracker.feed(bytes([byte]))
        self.assertFalse(tracker.dirty)
        self.assertEqual(tracker.pending, b'')

    def test_real_keyboard_and_incomplete_escape_still_preserve_drafts(self):
        for data in [b'new draft', b'/new\r', b'\x1b[A', b'\x1b[97;5u', b'\r', b'\x03']:
            tracker = terminal.TerminalInput()
            tracker.feed(data)
            self.assertTrue(tracker.dirty, data)
            self.assertEqual(tracker.pending, b'')
        tracker = terminal.TerminalInput()
        tracker.feed(b'\x1b')
        tracker.deadline = 0
        tracker.expire()
        self.assertTrue(tracker.dirty)
        self.assertEqual(tracker.reason, 'incomplete_control_input')

    def test_queued_automatic_reply_is_forwarded_and_does_not_block_reuse(self):
        host = terminal.TerminalHost('/fake/codex', THREAD, '/tmp', '/dev/ttys007')
        host.master = 55
        host.record = mock.Mock()
        report = b'\x1b[4;800;1200t'
        with mock.patch.object(terminal.select, 'select', side_effect=[([0], [], []), ([], [], [])]), mock.patch.object(terminal.os, 'read', return_value=report), mock.patch.object(terminal.os, 'write') as write:
            host.drain_pending_input()
        self.assertFalse(host.dirty)
        write.assert_called_once_with(55, report)
        host.record.unlink.assert_not_called()

    def test_queued_human_draft_is_forwarded_and_retires_view(self):
        host = terminal.TerminalHost('/fake/codex', THREAD, '/tmp', '/dev/ttys007')
        host.master = 55
        host.record = mock.Mock()
        with mock.patch.object(terminal.select, 'select', return_value=([0], [], [])), mock.patch.object(terminal.os, 'read', return_value=b'my draft'), mock.patch.object(terminal.os, 'write') as write, mock.patch.object(terminal, 'atomic_json') as save:
            host.drain_pending_input()
        self.assertTrue(host.dirty)
        write.assert_called_once_with(55, b'my draft')
        host.record.unlink.assert_called_once()
        diagnostic = save.call_args.args[1]
        self.assertEqual(diagnostic['reuseBlocked'], 'keyboard_input')
        self.assertNotIn('my draft', json.dumps(diagnostic))

    def test_unavailable_selection_records_reason_without_prompt_content(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'host-ttys001.json').write_text('{}')
            with mock.patch.object(terminal, 'sidecar_dir', return_value=Path(directory)), mock.patch.object(terminal, 'process_rows', return_value=[]):
                terminal.try_reuse({'directory': '/tmp', 'prompt': 'PRIVATE_PROMPT_MUST_NOT_BE_LOGGED'})
            data = (Path(directory) / 'last-reuse.json').read_text()
            self.assertNotIn('PRIVATE_PROMPT', data)
            self.assertEqual(json.loads(data)['candidates'][0]['reason'], 'owner_not_verified')

    def test_delayed_loop_drains_completed_reply_before_expiring_partial_prefix(self):
        host = terminal.TerminalHost('/fake/codex', THREAD, '/tmp', '/dev/ttys007')
        host.master = 55
        host.input.feed(b'\x1b[')
        host.input.deadline = 0
        with mock.patch.object(terminal.select, 'select', side_effect=[([0], [], []), ([], [], [])]), mock.patch.object(terminal.os, 'read', return_value=b'4;800;1200t'), mock.patch.object(terminal.os, 'write'):
            host.drain_pending_input()
        self.assertFalse(host.dirty)
        self.assertFalse(host.input.pending)

    def test_mouse_navigation_without_typing_does_not_create_a_draft(self):
        tracker = terminal.TerminalInput()
        for event in [b'\x1b[<0;8;12M', b'\x1b[<0;8;12m', b'\x1b[<64;8;12M', b'\x1b[<65;8;12M']:
            tracker.feed(event)
            self.assertFalse(tracker.dirty)
        tracker.feed(b'actual typed draft')
        tracker.feed(b'\x1b[<64;8;12M')
        self.assertTrue(tracker.dirty)
