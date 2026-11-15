# Validation

Validated on 2026-11-15 with Omarchy 4.5.0-3, Quickshell 0.3.2 and
WirePlumber 0.5.18. Changes were loaded in an isolated Quickshell instance before
installation, then verified in the installed bar panel.

## Automated checks

- 19 Python tests: parent identity across transient ID changes, exact rules,
  sibling separation, unsupported endpoints, persistence encoding, external-edit
  protection, parent-device readiness following a restart, inactive-profile
  restoration, physical/virtual microphone filtering, aggregate and mixed mute,
  rollback after partial microphone failure, restart spacing/rate-limit recovery,
  failed writes/restarts, selection recheck, crash journal, restore-all, preserving
  other fragments, tone properties, and plain-text rendering of untrusted labels.
- JavaScript tests: selected-output stream routing, exclusion of unrelated
  playback streams, traversal through intermediates and cycles, and primitive
  node snapshots that cannot hold dangling QObjects.
- Qt 6 QML lint passes with upstream-style unqualified-access diagnostics
  suppressed; all other diagnostics are enabled.
- Omarchy manifest validation passes.

## Live checks passed

- The final output activity meter measured the same peak (approximately 0.401)
  at normal volume, zero volume and mute on a temporary silent software output.
  The system's existing DSP routing was active during this test. All meter
  capture nodes disappeared after the isolated panel closed.
- Disabled a nonselected built-in output, a USB microphone and an HDMI output.
  Each disappeared from both PipeWire and PulseAudio lists; the same card's
  sibling endpoint remained present. Disabled endpoints still appeared as
  connected in the helper's hidden-device list using their parent hardware.
- Unhide restored each endpoint immediately, without changing the default
  selection in those tests. Restore-all restored a deliberately hidden endpoint.
- A disabled endpoint remained disabled after a separate WirePlumber restart.
- Selected-output hiding was rejected. The final recheck race is covered by an
  automated test.
- Physical and virtual microphone mute: live/mixed -> mute all -> unmute all.
  Connecting a new unmuted virtual microphone preserved its state and changed
  aggregate status to mixed. Output mute states remained unchanged.
- Installed-panel keyboard navigation independently toggled/restored speaker
  mute and toggled aggregate microphone mute. The `v` shortcut opened Hidden
  devices; Escape dismissed the panel. Original mute states were restored.
- Test-tone generation checks: 48 kHz, 16-bit stereo, identical channels,
  19,200 frames (400 ms), approximately 440 Hz, -24 dBFS maximum, and gentle
  60 ms fades ending at zero.
- Selected-output tone playback preserved mute; concurrent tests were rejected.
  The short faded tone played successfully through the selected output.
- Installation used `omarchy plugin clone omarchy.audio`; the bar references
  `franz.audio`, its manifest retains `clonedFrom: omarchy.audio`, and upstream
  `shell summon omarchy.audio` opens the enhanced panel.
- Rendered panel inspected with the real theme. Hyprland reported no config
  errors. Shell logs contain the shell's existing multi-monitor duplicate IPC
  warnings and plugin-path scanner warnings; no Audio Plus binding or helper
  errors were observed in the final installed panel.

## Issues found and corrected during validation

- Sink-level peak monitoring went silent at zero volume/mute. The final meter
  monitors playback streams feeding the selected output before its gain/mute.
- WirePlumber's service can become active before its graph repopulates. The
  helper now waits for parent devices and sibling nodes before accepting success.
- Rapid test restarts hit systemd's start limiter. The service was recovered,
  all test endpoints restored, and cross-process restart spacing plus targeted
  start-limit recovery were added and tested.
- Qt initially retained the official clone's baseline component at the same
  URL. Restarting the shell loaded the replacement; the installer now performs
  that restart to ensure the new code is used.

## Manual hardware checks still required

Physical unplug/replug and a full machine reboot were not performed. Durable
rules were inspected, restart persistence was tested, and parent-connectivity
logic was tested with disconnected/replaced fixtures. To complete hardware
acceptance, hide a nonselected endpoint, unplug/replug its parent, then reboot
and confirm that it stays unavailable while its sibling remains usable. Unhide
or use the documented restore-all command afterwards.

Listening quality of the tone is subjective; its generated envelope and signal
properties are verified numerically. The hardware's direct ALSA interface is
outside the scope of this plugin.
