#!/usr/bin/env python3
"""Validate, back up, clone using Omarchy's workflow, and install Audio Plus."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
FILES = ('Panel.qml', 'Model.js', 'manifest.json', 'i18n', 'helpers', 'assets', 'LICENSE', 'NOTICE')
MARK_BEGIN = '-- omarchy-audio-plus: begin'
MARK_END = '-- omarchy-audio-plus: end'


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def replace_id(config, old, new):
    for section in config.get('bar', {}).get('layout', {}).values():
        for entry in section:
            if entry.get('id') == old:
                entry['id'] = new


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--uninstall', action='store_true')
    args = parser.parse_args()
    config_home = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config'))
    shell = config_home / 'omarchy/shell.json'
    bindings = config_home / 'hypr/bindings.lua'
    target = config_home / 'omarchy/plugins/franz.audio'
    backup = ROOT / 'backups' / datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    if not args.uninstall:
        subprocess.run(['python3', '-m', 'unittest', 'discover', '-s', str(ROOT / 'tests')], check=True)
        subprocess.run(['node', str(ROOT / 'tests/model.test.js')], check=True)
        subprocess.run(['/usr/lib/qt6/bin/qmllint', '--unqualified', 'disable', str(ROOT / 'Panel.qml')], check=True)
        subprocess.run(['omarchy', 'plugin', 'validate', str(ROOT)], check=True)
        for command in ('omarchy', 'omarchy-shell', 'pw-dump', 'pactl', 'paplay', 'systemctl', 'python3'):
            if not shutil.which(command):
                raise RuntimeError('Missing dependency: ' + command)
    backup.mkdir(parents=True, mode=0o700)
    for source in (shell, bindings):
        if source.exists():
            shutil.copy2(source, backup / source.name)
    if target.exists():
        shutil.copytree(target, backup / 'franz.audio', ignore=shutil.ignore_patterns('__pycache__'))
    old_config = shell.read_bytes()
    old_bindings = bindings.read_bytes()
    installed_before = target.exists()
    try:
        if args.uninstall:
            run('python3', str(target / 'helpers/audio_plus.py'), 'restore-all')
            config = json.loads(shell.read_bytes())
            replace_id(config, 'franz.audio', 'omarchy.audio')
            shell.write_text(json.dumps(config, indent=2) + '\n')
            text = bindings.read_text()
            if MARK_BEGIN in text:
                start = text.index(MARK_BEGIN)
                end = text.index(MARK_END, start) + len(MARK_END)
                text = text[:start] + text[end:].lstrip('\n')
                bindings.write_text(text)
            if target.exists():
                shutil.rmtree(target)
        else:
            if not target.exists():
                # The official command retains stable built-in IPC targets and
                # records clonedFrom. The validated payload replaces its copy.
                if os.environ.get('USER') != 'franz':
                    raise RuntimeError('This approved clone uses franz.audio; run the official clone manually and rename its manifest on other accounts')
                print(run('omarchy', 'plugin', 'clone', 'omarchy.audio'))
            stage = Path(tempfile.mkdtemp(prefix='.audio-plus-', dir=target.parent))
            try:
                for name in FILES:
                    source = ROOT / name
                    if source.is_dir():
                        shutil.copytree(source, stage / name, ignore=shutil.ignore_patterns('__pycache__'))
                    else:
                        shutil.copy2(source, stage / name)
                # Complete staging before removing the old plugin. Omarchy
                # watches this directory and rescans after the rename.
                shutil.rmtree(target)
                stage.rename(target)
            finally:
                if stage.exists():
                    shutil.rmtree(stage)
            config = json.loads(shell.read_bytes())
            replace_id(config, 'omarchy.audio', 'franz.audio')
            shell.write_text(json.dumps(config, indent=2) + '\n')
            text = bindings.read_text()
            if MARK_BEGIN in text:
                start = text.index(MARK_BEGIN)
                end = text.index(MARK_END, start) + len(MARK_END)
                text = text[:start] + text[end:].lstrip('\n')
            # Override the existing shortcut without changing packaged commands.
            command = 'python3 ' + str(target / 'helpers/audio_plus.py') + ' mic-toggle'
            text += '\n' + MARK_BEGIN + '\n' + 'o.rebind("XF86AudioMicMute", "Mute all microphones", ' + json.dumps(command) + ', { locked = true })\n' + MARK_END + '\n'
            bindings.write_text(text)
        run('hyprctl', 'reload')
        errors = run('hyprctl', 'configerrors')
        if errors and errors != 'ok':
            raise RuntimeError('Hyprland configuration errors: ' + errors)
        run('omarchy-shell', 'shell', 'rescanPlugins')
        # Qt may retain the baseline clone component at the same URL.
        # A shell restart ensures the validated replacement is instantiated.
        run('omarchy', 'restart', 'shell')
        time.sleep(1)
        if not args.uninstall:
            plugins = json.loads(run('omarchy', 'plugin', 'list', '--json'))
            if not any(p.get('id') == 'franz.audio' for p in plugins):
                raise RuntimeError('Installed plugin was not discovered')
            run('omarchy-shell', 'shell', 'ping')
        print(('Uninstalled' if args.uninstall else 'Installed') + f'. Backups: {backup}')
    except BaseException:
        shell.write_bytes(old_config)
        bindings.write_bytes(old_bindings)
        if target.exists():
            shutil.rmtree(target)
        if installed_before:
            shutil.copytree(backup / 'franz.audio', target)
        subprocess.run(['hyprctl', 'reload'], capture_output=True)
        subprocess.run(['omarchy-shell', 'shell', 'rescanPlugins'], capture_output=True)
        subprocess.run(['omarchy', 'restart', 'shell'], capture_output=True)
        raise


if __name__ == '__main__':
    main()
