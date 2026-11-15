import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('audio_plus', ROOT / 'helpers/audio_plus.py')
audio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio)


def parent(id=1, name='alsa_card.usb-test'):
    return {'id': id, 'type': 'PipeWire:Interface:Device', 'info': {'props': {
        'device.api': 'alsa', 'device.name': name, 'device.serial': 'stable-serial'}}}


def node(id=2, name='alsa_output.usb-test.analog-stereo', cls='Audio/Sink'):
    return {'id': id, 'type': 'PipeWire:Interface:Node', 'info': {'props': {
        'device.api': 'alsa', 'device.id': 1, 'node.name': name, 'media.class': cls,
        'node.description': '<img src="https://example.invalid/tracker">'}}}


def entry():
    e = audio.endpoint(node(), [parent(), node()])
    return {k: e[k] for k in ('name', 'label', 'direction', 'parent')}


class IdentityTests(unittest.TestCase):
    def test_parent_identity_survives_id_change_but_not_replacement(self):
        identity = entry()['parent']
        self.assertTrue(audio.parent_connected(identity, [parent(99)]))
        self.assertFalse(audio.parent_connected(identity, []))
        moved = parent(100)
        moved['info']['props']['device.bus-path'] = 'another-usb-port'
        self.assertTrue(audio.parent_connected(dict(identity, **{'device.bus-path': 'original-port'}), [moved]))
        other = parent()
        other['info']['props']['device.serial'] = 'replacement'
        self.assertFalse(audio.parent_connected(identity, [other]))

    def test_exact_node_rule_does_not_disable_parent_or_sibling(self):
        e = entry()
        r = audio.rules([e])[0]
        self.assertEqual(r['matches'], [{'node.name': e['name'], 'media.class': 'Audio/Sink'}])
        self.assertEqual(r['actions']['update-props'], {'node.disabled': True})
        self.assertNotIn('device.disabled', json.dumps(r))
        self.assertFalse(r['matches'][0]['node.name'].startswith('~'))
        self.assertNotEqual(r['matches'][0]['node.name'], 'alsa_input.usb-test.analog-stereo')

    def test_unsupported_and_missing_parent(self):
        for name in ('bluez_output.headset', 'virtual_sink'):
            self.assertFalse(audio.endpoint(node(name=name), [parent()])['supported'])
        self.assertFalse(audio.endpoint(node(), [])['supported'])

    def test_state_roundtrip_and_external_edit_protection(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'managed.conf'
            audio.atomic_write(path, audio.encode([entry()]))
            self.assertEqual(audio.load_hidden(path), [entry()])
            data = json.loads(path.read_bytes())
            data['monitor.alsa.rules'][0]['matches'][0]['node.name'] = '~.*'
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                audio.load_hidden(path)

    def test_verification_waits_for_parent_devices_after_restart(self):
        with patch.object(audio, 'graph', side_effect=[[], [parent()]]), patch.object(audio, 'run', return_value='[]'), patch.object(audio.time, 'sleep') as sleep:
            audio.verify_applied([entry()], [parent(), node()])
        sleep.assert_called_once()

    def test_unhide_from_inactive_profile_removes_rule_without_selecting(self):
        p = parent()
        p['info']['params'] = {'Profile': [{'name': 'different-profile'}]}
        removed = dict(entry(), parent_profile='old-profile')
        with patch.object(audio, 'graph', return_value=[p]), patch.object(audio, 'run', return_value='[]'):
            audio.verify_applied([], [p], removed)

    def test_rejects_injection_and_duplicate_identity(self):
        e = entry()
        e['name'] = '~.*'
        with self.assertRaises(ValueError):
            audio.rules([e])
        with self.assertRaises(ValueError):
            audio.rules([entry(), entry()])


class MicrophoneTests(unittest.TestCase):
    def test_includes_virtual_excludes_all_monitor_variants(self):
        sources = [{'name': 'hardware', 'mute': False}, {'name': 'virtual', 'mute': True},
                   {'name': 'custom', 'monitor_of_sink': 7}, {'name': 'sink.monitor'},
                   {'name': 'another', 'properties': {'media.class': 'Audio/Sink'}},
                   {'name': 'disabled', 'properties': {'node.disabled': True}}]
        self.assertEqual([s['name'] for s in audio.microphones(sources)], ['hardware', 'virtual'])
        self.assertEqual(audio.mic_status(sources), dict(count=2, muted=False, mixed=True))
        self.assertEqual(audio.mic_status([]), dict(count=0, muted=False, mixed=False))

    def test_aggregate_toggle_and_new_connections(self):
        for muted in ((False, True), (True, True), (False, False)):
            sources = [{'name': 'physical', 'mute': muted[0]}, {'name': 'virtual', 'mute': muted[1]}]
            calls = []
            def run(*args, **kwargs):
                calls.append(args)
                return json.dumps(sources) if args[:2] == ('pactl', '-f') else ''
            with patch.object(audio, 'run', run):
                result = audio.toggle_microphones()
            desired = '1' if any(not m for m in muted) else '0'
            self.assertEqual([c for c in calls if c[:2] == ('pactl', 'set-source-mute')],
                             [('pactl', 'set-source-mute', name, desired) for name in ('physical', 'virtual')])
            self.assertEqual(result['muted'], desired == '1')
        # Status only observes; newly connected microphones keep their state.
        with patch.object(audio, 'run') as run:
            audio.mic_status([{'name': 'new', 'mute': False}])
            run.assert_not_called()

    def test_partial_failure_restores_changed_microphones(self):
        calls = []
        def run(*args, **kwargs):
            calls.append(args)
            if args[:2] == ('pactl', '-f'):
                return json.dumps([{'name': 'one', 'mute': False}, {'name': 'two', 'mute': True}])
            if args[:3] == ('pactl', 'set-source-mute', 'two'):
                raise RuntimeError('disconnected')
            return ''
        with patch.object(audio, 'run', run), self.assertRaises(RuntimeError):
            audio.toggle_microphones()
        self.assertEqual(calls[-1], ('pactl', 'set-source-mute', 'one', '0'))


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'wireplumber/wireplumber.conf.d/test.conf'
        self.patches = [patch.object(audio, 'config_path', return_value=self.path),
                        patch.dict(os.environ, XDG_RUNTIME_DIR=self.tmp.name),
                        patch.object(audio, 'graph', return_value=[parent(), node()]),
                        patch.object(audio, 'selected_names', return_value=set()),
                        patch.object(audio, 'verify_applied')]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)

    def test_selected_protection_rechecked_before_commit(self):
        with patch.object(audio, 'selected_names', side_effect=[set(), {entry()['name']}]), patch.object(audio, 'restart'):
            with self.assertRaisesRegex(RuntimeError, 'became selected'):
                audio.apply('hide', entry()['name'])
        self.assertFalse(self.path.exists())

    def test_restart_failure_rolls_back_previous_and_recovers(self):
        previous = audio.encode([])
        audio.atomic_write(self.path, previous)
        with patch.object(audio, 'restart', side_effect=[RuntimeError('restart failed'), None]) as restart:
            with self.assertRaisesRegex(RuntimeError, 'previous configuration restored'):
                audio.apply('hide', entry()['name'])
        self.assertEqual(self.path.read_bytes(), previous)
        self.assertEqual(restart.call_count, 2)
        self.assertFalse(self.path.with_suffix('.pending').exists())

    def test_write_failure_restores_previous(self):
        previous = audio.encode([])
        audio.atomic_write(self.path, previous)
        real = audio.atomic_write
        writes = []
        def write(path, data):
            writes.append(path)
            if path == self.path and len(writes) == 2:
                raise PermissionError('read-only')
            return real(path, data)
        with patch.object(audio, 'atomic_write', write), patch.object(audio, 'restart'):
            with self.assertRaisesRegex(RuntimeError, 'read-only'):
                audio.apply('hide', entry()['name'])
        self.assertEqual(self.path.read_bytes(), previous)

    def test_hide_unhide_restore_all_each_restart_once(self):
        with patch.object(audio, 'restart') as restart:
            audio.apply('hide', entry()['name'])
            self.assertEqual(audio.load_hidden(self.path), [entry()])
            audio.apply('unhide', entry()['name'])
            self.assertEqual(audio.load_hidden(self.path), [])
            audio.apply('restore-all')
            self.assertFalse(self.path.exists())
        self.assertEqual(restart.call_count, 3)

    def test_crash_journal_recovery(self):
        self.path.parent.mkdir(parents=True)
        journal = self.path.with_suffix('.pending')
        journal.write_text(json.dumps({'previous': None}))
        self.path.write_bytes(audio.encode([entry()]))
        with patch.object(audio, 'restart') as restart:
            audio.recover_pending(self.path, journal)
        self.assertFalse(self.path.exists())
        self.assertFalse(journal.exists())
        restart.assert_called_once()

    def test_preserves_other_config_fragments(self):
        self.path.parent.mkdir(parents=True)
        other = self.path.parent / '10-user.conf'
        other.write_text('user configuration')
        with patch.object(audio, 'restart'):
            audio.apply('restore-all')
        self.assertEqual(other.read_text(), 'user configuration')


class RestartTests(unittest.TestCase):
    def test_rate_limit_recovery_and_spacing(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, XDG_RUNTIME_DIR=directory), patch.object(audio.time, 'monotonic', return_value=100), patch.object(audio.time, 'sleep') as sleep:
            (Path(directory) / 'omarchy-audio-plus-last-restart').write_text('99')
            calls = []
            def run(*args, **kwargs):
                calls.append(args)
                if '--property=Result' in args:
                    return 'start-limit-hit'
                return 'active'
            with patch.object(audio, 'run', run):
                audio.restart()
            sleep.assert_called_once_with(1.5)
            self.assertIn(('systemctl', '--user', 'reset-failed', 'wireplumber.service'), calls)
            self.assertEqual(sum('restart' in c for c in calls), 1)


class AssetAndUiTests(unittest.TestCase):
    def test_tone_duration_channels_fades_and_level(self):
        import math, struct, wave
        with wave.open(str(ROOT / 'assets/test-tone.wav')) as wav:
            self.assertEqual((wav.getnchannels(), wav.getframerate(), wav.getnframes()), (2, 48000, 19200))
            samples = struct.unpack('<' + 'h' * 38400, wav.readframes(19200))
        left, right = samples[::2], samples[1::2]
        self.assertEqual(left, right)
        self.assertEqual((left[0], left[-1]), (0, 0))
        self.assertLessEqual(max(map(abs, left)), 2070)
        self.assertLess(max(map(abs, left[:480])), 145)
        crossings = sum(left[i] <= 0 < left[i+1] for i in range(3000, 16000))
        self.assertAlmostEqual(crossings * 48000 / 13000, 440, delta=4)

    def test_untrusted_labels_and_errors_are_plain_text(self):
        qml = (ROOT / 'Panel.qml').read_text()
        for block in __import__('re').findall(r'\bText\s*\{(.*?)\n\s*\}', qml, __import__('re').S):
            self.assertIn('textFormat: Text.PlainText', block)
        self.assertNotIn('tooltipText: modelData', qml)
        self.assertIn('text: root.contextEndpoint ? root.contextEndpoint.label', qml)
        self.assertIn('text: root.deviceBusy ? strings.t("devices.applying") : root.actionError', qml)
        self.assertIn('enabled: root.opened && !!node', qml)
        self.assertIn('model: root.opened ? root.outputMeterRows : []', qml)


if __name__ == '__main__':
    unittest.main()
