#!/usr/bin/env python3
"""User-session audio controls. No shell interpolation or third-party Python modules."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

OWNER = 'omarchy-audio-plus-v1'
STATE_KEY = 'omarchy.audio-plus'
FRAGMENT = '90-omarchy-audio-plus.conf'
PARENT_KEYS = ('device.name', 'device.serial', 'device.bus-path')


def run(*args, timeout=12):
    try:
        return subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout).stdout.strip()
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or str(exc)).strip()[:2000]
        raise RuntimeError(f'{args[0]} failed: {detail}') from exc


def props(obj):
    return obj.get('info', {}).get('props', {})


def graph():
    return json.loads(run('pw-dump'))


def parents(objects):
    return {str(o['id']): props(o) for o in objects
            if o.get('type') == 'PipeWire:Interface:Device' and props(o).get('device.api') == 'alsa'}


def parent_identity(p):
    return {k: str(p[k]) for k in PARENT_KEYS if p.get(k)}


def parent_matches(identity, p):
    if not identity.get('device.name') or str(p.get('device.name', '')) != identity['device.name']:
        return False
    # A serial-bearing USB device can reconnect on another port. Keep the
    # observed bus path as metadata, but prefer serial + stable device.name.
    key = 'device.serial' if identity.get('device.serial') else 'device.bus-path'
    return not identity.get(key) or str(p.get(key, '')) == identity[key]


def parent_connected(identity, objects):
    return any(parent_matches(identity, p) for p in parents(objects).values())


def active_parent_profile(identity, objects):
    for obj in objects:
        if obj.get('type') != 'PipeWire:Interface:Device':
            continue
        p = props(obj)
        if parent_matches(identity, p):
            profiles = obj.get('info', {}).get('params', {}).get('Profile', [])
            return str(profiles[0].get('name', '')) if profiles else ''
    return ''


def endpoint(obj, objects):
    p = props(obj)
    name, cls = p.get('node.name', ''), p.get('media.class', '')
    if obj.get('type') != 'PipeWire:Interface:Node' or cls not in ('Audio/Sink', 'Audio/Source'):
        return None
    parent = parents(objects).get(str(p.get('device.id')), {})
    direction = 'output' if cls == 'Audio/Sink' else 'input'
    supported = (p.get('device.api') == 'alsa' and parent.get('device.api') == 'alsa'
                 and name.startswith('alsa_output.' if direction == 'output' else 'alsa_input.')
                 and bool(parent.get('device.name')))
    return dict(name=name, label=str(p.get('node.description') or name), direction=direction,
                parent=parent_identity(parent), supported=bool(supported), id=obj['id'])


def microphones(sources):
    # Pulse exposes physical and virtual sources, including classes Quickshell
    # cannot type. A sink monitor is never a microphone, even with a custom name.
    return [s for s in sources if s.get('name')
            and not str(s['name']).endswith('.monitor')
            and s.get('monitor_of_sink') in (None, '', 4294967295, -1)
            and s.get('monitor_of_sink_name') in (None, '')
            and s.get('properties', {}).get('device.class') != 'monitor'
            and s.get('properties', {}).get('media.class') != 'Audio/Sink'
            and str(s.get('properties', {}).get('node.disabled', 'false')).lower() != 'true']


def mic_status(sources):
    mics = microphones(sources)
    muted = sum(bool(s.get('mute')) for s in mics)
    return dict(count=len(mics), muted=bool(mics) and muted == len(mics), mixed=0 < muted < len(mics))


def toggle_microphones():
    mics = microphones(json.loads(run('pactl', '-f', 'json', 'list', 'sources')))
    target = any(not s.get('mute') for s in mics)
    changed = []
    try:
        for s in mics:
            run('pactl', 'set-source-mute', s['name'], '1' if target else '0')
            changed.append(s)
    except Exception:
        for s in changed:
            with contextlib.suppress(Exception):
                run('pactl', 'set-source-mute', s['name'], '1' if s.get('mute') else '0')
        raise
    if mics:
        with contextlib.suppress(Exception):
            run('omarchy-brightness-keyboard-mute', 'on' if target else 'off')
    return dict(count=len(mics), muted=target if mics else False, mixed=False)


def config_path():
    return Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'wireplumber/wireplumber.conf.d' / FRAGMENT


def validate_hidden(hidden):
    if not isinstance(hidden, list) or len(hidden) > 256:
        raise ValueError('Invalid hidden endpoint list')
    seen = set()
    for e in hidden:
        if not isinstance(e, dict) or e.get('direction') not in ('input', 'output'):
            raise ValueError('Invalid endpoint direction')
        prefix = 'alsa_input.' if e['direction'] == 'input' else 'alsa_output.'
        name = e.get('name')
        if not isinstance(name, str) or not name.startswith(prefix) or len(name) > 1024 or name in seen:
            raise ValueError('Invalid or duplicate endpoint identity')
        seen.add(name)
        if not isinstance(e.get('label'), str) or len(e['label']) > 2048:
            raise ValueError('Invalid endpoint label')
        if 'parent_profile' in e and (not isinstance(e['parent_profile'], str) or len(e['parent_profile']) > 1024):
            raise ValueError('Invalid saved parent profile')
        parent = e.get('parent')
        if not isinstance(parent, dict) or not parent.get('device.name') or not set(parent) <= set(PARENT_KEYS):
            raise ValueError('Invalid parent identity')
        if any(not isinstance(v, str) or not v or len(v) > 1024 for v in parent.values()):
            raise ValueError('Invalid parent identity value')
    return hidden


def rules(hidden):
    validate_hidden(hidden)
    # node.name is globally unique and encodes its ALSA parent. Do not match
    # transient device.id/card indexes or disable the entire parent device.
    return [{'matches': [{'node.name': e['name'], 'media.class':
                          'Audio/Sink' if e['direction'] == 'output' else 'Audio/Source'}],
             'actions': {'update-props': {'node.disabled': True}}}
            for e in sorted(hidden, key=lambda e: e['name'])]


def encode(hidden):
    return (json.dumps({STATE_KEY: {'owner': OWNER, 'hidden': hidden},
                        'monitor.alsa.rules': rules(hidden)}, indent=2, ensure_ascii=True) + '\n').encode()


def load_hidden(path):
    if not path.exists():
        return []
    data = json.loads(path.read_bytes())
    state = data.get(STATE_KEY, {})
    if state.get('owner') != OWNER:
        raise ValueError(f'Refusing to overwrite unmanaged configuration: {path}')
    hidden = validate_hidden(state.get('hidden'))
    if data.get('monitor.alsa.rules') != rules(hidden):
        raise ValueError('Managed rules were edited externally; back up the fragment and use restore-all')
    return hidden


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            os.fchmod(f.fileno(), 0o600)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def restart():
    # Serialized actions can still arrive faster than systemd's start limiter.
    # Space successful and recovery restarts across processes (runtime-only).
    with lock('restart'):
        marker = Path(os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')) / 'omarchy-audio-plus-last-restart'
        try:
            delay = min(2.5, max(0, 2.5 - (time.monotonic() - float(marker.read_text()))))
        except (FileNotFoundError, ValueError):
            delay = 0
        if delay:
            time.sleep(delay)
        if run('systemctl', '--user', 'show', 'wireplumber.service', '--property=Result', '--value') == 'start-limit-hit':
            run('systemctl', '--user', 'reset-failed', 'wireplumber.service')
        try:
            run('systemctl', '--user', 'restart', 'wireplumber.service', timeout=20)
        finally:
            atomic_write(marker, str(time.monotonic()).encode())
        if run('systemctl', '--user', 'is-active', 'wireplumber.service') != 'active':
            raise RuntimeError('WirePlumber did not become active')


def selected_names():
    names = {run('pactl', 'get-default-sink'), run('pactl', 'get-default-source')}
    # Protect a physical output behind a selected DSP sink as well.
    with contextlib.suppress(Exception):
        names.add(run('omarchy-audio-output-sink'))
    return names


def verify_applied(hidden, previous_graph, removed=None):
    deadline = time.monotonic() + 8
    old_endpoints = [endpoint(o, previous_graph) for o in previous_graph]
    hidden_names = {e['name'] for e in hidden}
    expected_parents = [parent_identity(p) for p in parents(previous_graph).values()]
    # Sibling nodes which existed before the restart must remain available.
    siblings = {e['name'] for e in old_endpoints if e and e['supported'] and e['name'] not in hidden_names}
    while True:
        current = graph()
        current_names = {props(o).get('node.name') for o in current if o.get('type') == 'PipeWire:Interface:Node'}
        connected_siblings = {e['name'] for e in old_endpoints if e and e['name'] in siblings
                              and parent_connected(e['parent'], current)}
        pulse_names = {s['name'] for s in json.loads(run('pactl', '-f', 'json', 'list', 'sinks'))}
        pulse_names.update(s['name'] for s in json.loads(run('pactl', '-f', 'json', 'list', 'sources')))
        parents_ready = all(parent_connected(identity, current) for identity in expected_parents)
        if parents_ready and not hidden_names & (current_names | pulse_names) and connected_siblings <= current_names:
            # An unhidden endpoint can belong to a profile no longer active.
            # Its rule is removed regardless; give active profiles time to return.
            same_profile = removed and removed.get('parent_profile') and active_parent_profile(removed['parent'], current) == removed['parent_profile']
            if not removed or removed['name'] in current_names or not same_profile:
                return
        if time.monotonic() >= deadline:
            raise RuntimeError('Audio graph did not reach the expected state after restart')
        time.sleep(0.2)


@contextlib.contextmanager
def lock(name):
    directory = Path(os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}'))
    with (directory / ('omarchy-audio-plus-' + name + '.lock')).open('a') as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another audio action is in progress') from None
        yield


def restore_previous(path, previous):
    if previous is None:
        path.unlink(missing_ok=True)
    else:
        atomic_write(path, previous)


def apply(action, name=None):
    path = config_path()
    with lock('devices'):
        journal = path.with_suffix('.pending')
        if journal.exists():
            recover_pending(path, journal)
        previous = path.read_bytes() if path.exists() else None
        # Restore-all also works if a user accidentally damaged this fragment.
        hidden = [] if action == 'restore-all' else load_hidden(path)
        objects = graph()
        removed = None
        if action == 'hide':
            matches = [endpoint(o, objects) for o in objects if props(o).get('node.name') == name]
            e = next((e for e in matches if e and e['supported']), None)
            if not e:
                raise ValueError('Only connected ALSA endpoints can be hidden; Bluetooth and virtual devices are unsupported')
            if name in selected_names():
                raise ValueError('Switch away from this endpoint before hiding it')
            if any(h['name'] == name for h in hidden):
                raise ValueError('Endpoint is already hidden')
            saved = {k: e[k] for k in ('name', 'label', 'direction', 'parent')}
            profile = active_parent_profile(e['parent'], objects)
            if profile:
                saved['parent_profile'] = profile
            hidden = hidden + [saved]
        elif action == 'unhide':
            removed = next((e for e in hidden if e['name'] == name), None)
            if not removed:
                raise ValueError('Endpoint is not hidden')
            hidden = [e for e in hidden if e['name'] != name]
        # One atomic file contains both durable identities and corresponding
        # rules. Journal permits recovery after process termination or power loss.
        atomic_write(journal, json.dumps({'previous': previous.decode() if previous is not None else None}).encode())
        try:
            # Recheck immediately before committing, after all preparation.
            if action == 'hide' and name in selected_names():
                raise ValueError('Endpoint became selected; switch away before hiding it')
            if action == 'restore-all':
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, encode(hidden))
            restart()
            verify_applied(hidden, objects, removed)
        except BaseException as error:
            recovery = []
            try:
                restore_previous(path, previous)
            except Exception as exc:
                recovery.append('configuration restore failed: ' + str(exc))
            try:
                restart()
            except Exception as exc:
                recovery.append('recovery restart failed: ' + str(exc))
            if not recovery:
                journal.unlink(missing_ok=True)
            raise RuntimeError(f'{error}; previous configuration restored and recovery attempted'
                               + ('; ' + '; '.join(recovery) if recovery else '')) from error
        journal.unlink(missing_ok=True)
    return {'ok': True}


def recover_pending(path, journal):
    previous = json.loads(journal.read_bytes())['previous']
    restore_previous(path, previous.encode() if previous is not None else None)
    restart()
    journal.unlink()


def status():
    objects = graph()
    hidden = load_hidden(config_path())
    return dict(endpoints=[e for o in objects if (e := endpoint(o, objects))],
                hidden=[dict(e, connected=parent_connected(e['parent'], objects)) for e in hidden],
                microphones=mic_status(json.loads(run('pactl', '-f', 'json', 'list', 'sources'))),
                pending=config_path().with_suffix('.pending').exists())


def play_test(name):
    with lock('test'):
        outputs = json.loads(run('pactl', '-f', 'json', 'list', 'sinks'))
        if not any(s['name'] == name for s in outputs):
            raise ValueError('The selected output is no longer available')
        # Pulse routes the stream through the selected sink's volume and mute.
        # No fallback to another output if the target disappears.
        run('paplay', '--device=' + name, '--client-name=Omarchy Audio Plus',
            '--stream-name=Audio output test', str(Path(__file__).resolve().parent.parent / 'assets/test-tone.wav'))
    return {'ok': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('status', 'hide', 'unhide', 'restore-all', 'recover', 'mic-toggle', 'test'))
    parser.add_argument('name', nargs='?')
    args = parser.parse_args()
    try:
        if args.action in ('hide', 'unhide', 'test') and not args.name:
            parser.error('endpoint name is required')
        if args.action == 'status':
            result = status()
        elif args.action == 'mic-toggle':
            with lock('microphones'):
                result = toggle_microphones()
        elif args.action == 'test':
            result = play_test(args.name)
        elif args.action == 'recover':
            with lock('devices'):
                journal = config_path().with_suffix('.pending')
                if journal.exists():
                    recover_pending(config_path(), journal)
            result = {'ok': True}
        else:
            result = apply(args.action, args.name)
        print(json.dumps(result))
    except Exception as exc:
        print(json.dumps({'error': str(exc)}))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
