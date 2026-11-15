# Omarchy Audio Plus

An enhanced clone of Omarchy's audio panel: output activity, a quiet output test,
separate speaker and microphone mute, and system-wide ALSA endpoint hiding.
The plugin ID is `franz.audio`; `omarchy.clonedFrom: omarchy.audio` retains the
upstream IPC routing used to open the audio panel.

## Controls

- The thin output meter shows activity in playback streams feeding the selected
  output, before that output's volume and mute. It is a software activity meter,
  not a measurement of sound pressure or a calibrated sum of streams. Both
  meters capture only while the panel is open.
- **Test** plays a 400 ms, 440 Hz stereo tone at -24 dBFS with 60 ms raised-cosine
  fades. It targets the selected output and respects its volume and mute.
  Tests cannot overlap, including across plugin instances.
- The speaker button and the bar icon's right-click mute the selected output
  (the physical volume endpoint when a DSP output fronts it).
- The microphone button and the installed `XF86AudioMicMute` shortcut toggle all
  connected, enabled physical and virtual PulseAudio sources. If any is live,
  mute all; otherwise unmute all. Speaker monitors are excluded. **Mixed**
  means some microphones are muted and some are live. Connecting a microphone
  does not change its mute state. Input volume and level remain selected-input
  controls. The stock optional separate microphone bar widget is not replaced.
- Right-click an endpoint to reveal **Hide device**. First select another output
  or input. The UI and helper both protect selected endpoints, with a final
  selection check immediately before writing. Bluetooth and virtual devices
  have an explanation instead of an enabled Hide action.
- **Hidden devices** is always accessible. It lists disabled endpoints whose
  parent ALSA hardware is connected, even though the endpoint itself has
  disappeared. **Unhide** restores availability without selecting it explicitly.
- Keyboard: arrows or j/k navigate, h/l adjust volume; Enter/Space activate;
  left/right on the top mute buttons selects speaker or microphones; `m` mutes
  the focused channel, `t` tests, `v` opens Hidden devices, and `d` opens the
  focused device's Hide action. Escape closes the panel. Tab switches panels.

## Endpoint hiding and recovery

Hide/Unhide apply immediately with one WirePlumber restart, which briefly
interrupts audio. Actions are serialized across processes, with a brief delay between rapid
restarts to avoid systemd start limits. Exact `node.name`
and `media.class` rules set `node.disabled`, leaving the other direction on the
same card intact. This controls PipeWire/PulseAudio availability; direct ALSA
access is outside its scope.

Only this fragment is managed:

```text
~/.config/wireplumber/wireplumber.conf.d/90-omarchy-audio-plus.conf
```

It contains both the rules and their saved endpoint name, label, direction, and
parent identity (`device.name`, plus serial and bus path when available), and
the active parent profile for restoration checks.
Hardware presence is determined from parent `Device` objects, never from the
missing disabled node. Disconnected entries stay in the fragment so the rules
continue to apply on reconnect, session restart and reboot. Endpoint names are
profile-specific: changing an ALSA card profile can introduce different
endpoints. Unhide still removes the rule if the saved profile is no longer active;
that endpoint becomes available when its profile is activated again. A USB device without a unique serial may be identified by its USB
port; moving it to another port can produce a new identity.

Writes use atomic replacement and a recovery journal. If application or graph
verification fails, the previous fragment is restored and a recovery restart
is attempted. Errors appear in the panel. Other WirePlumber fragments are never
modified. After a process or power interruption during application, run:

```bash
python3 ~/.config/omarchy/plugins/franz.audio/helpers/audio_plus.py recover
```

Restore every endpoint managed by this plugin:

```bash
python3 ~/.config/omarchy/plugins/franz.audio/helpers/audio_plus.py restore-all
```

If the helper itself cannot run, move the managed fragment and its pending
journal out of `wireplumber.conf.d`, then run
`systemctl --user restart wireplumber.service`. Preserve other files. A failed
recovery leaves the pending journal available for another recovery attempt.

## Installation

Requires Omarchy with its plugin clone workflow, Quickshell 0.3.2+, WirePlumber
0.5+, PipeWire with PulseAudio compatibility, Python 3.9+, `pactl`, `paplay`,
`pw-dump`, `wpctl`, Qt 6 `qmllint`, and Node.js for the JavaScript tests.
Baseline source: Omarchy 4.5.0-3. This approved installation retains the account
prefix `franz.audio` rather than selecting a new prefix on each machine.

```bash
git clone https://github.com/ka-no-creativity/omarchy-audio-plus.git
cd omarchy-audio-plus
python3 install.py
```

The installer validates before changing configuration, backs up `shell.json`,
Hyprland bindings, and any prior clone under ignored `backups/`, uses
`omarchy plugin clone omarchy.audio` for the first installation, and replaces
that baseline with the validated plugin. It installs into the user plugin
folder, switches the bar entry, and adds a marked microphone-key override in
`~/.config/hypr/bindings.lua`. It restarts the shell to clear cached QML components, validates Hyprland and plugin discovery, and
restores the previous widget and bindings on installation failure. Existing
packaged commands are preserved. To update, pull and rerun the installer.

```bash
python3 -m unittest discover -s tests -v
node tests/model.test.js
/usr/lib/qt6/bin/qmllint --unqualified disable Panel.qml
```

The unqualified-access diagnostic is suppressed because this clone follows the
upstream QML context pattern; other QML diagnostics remain enabled. Live tests
and any remaining manual checks are recorded in `VALIDATION.md`.

## Uninstall

From this checkout:

```bash
python3 install.py --uninstall
```

This backs up the current plugin/configuration, restores all managed endpoints,
returns the bar to `omarchy.audio`, removes only the marked microphone shortcut
override, reloads and validates Hyprland, then removes `franz.audio`.
Backups and the source checkout remain available. To restore an exact former
layout instead, copy the appropriate backed-up `shell.json` and `bindings.lua`
back to their original locations and reload Hyprland/rescan shell plugins.

## Upstream updates

This is a maintained clone, not an automatic patch of packaged Omarchy files.
After updating Omarchy, compare `/usr/share/omarchy/shell/plugins/panels/audio/`
against the baseline hashes in `upstream.json`. Manually merge changes into
`Panel.qml` and `Model.js`, retain `franz.audio`, `clonedFrom`, and the built-in
IPC target, and rerun the tests and live validation before installing. The
installer does not overwrite any packaged Omarchy source.

MIT; upstream attribution is in `NOTICE` and `LICENSE`.
