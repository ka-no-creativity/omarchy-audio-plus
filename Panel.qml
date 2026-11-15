import QtQuick
import QtQuick.Controls
import QtQml.Models
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.audio"
  ipcTarget: "omarchy.audio"

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var mediaService: bar?.shell?.firstPartyServiceFor("omarchy.media")
  readonly property var activeMediaPlayer: mediaService ? mediaService.activePlayer : null

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  readonly property string helperPath: Qt.resolvedUrl("helpers/audio_plus.py").toString().replace(/^file:\/\//, "")
  property var deviceStatus: ({endpoints: [], hidden: [], microphones: {count: 0, muted: false, mixed: false}})
  property var contextEndpoint: null
  property bool hiddenView: false
  property string actionError: ""
  property string actionErrorKind: ""
  readonly property bool deviceBusy: deviceActionProc.running
  readonly property var connectedHidden: deviceStatus.hidden.filter(function(e) { return e.connected })
  readonly property var allMicrophones: deviceStatus.microphones

  function refreshStatus() {
    if (!statusProc.running && !deviceBusy) statusProc.running = true
  }
  function endpointFor(name) {
    for (var i = 0; i < deviceStatus.endpoints.length; i++)
      if (deviceStatus.endpoints[i].name === name) return deviceStatus.endpoints[i]
    return null
  }
  function selectedEndpoint(e) {
    return !!e && ((sink && String(sink.name) === e.name)
      || (volumeSink && String(volumeSink.name) === e.name)
      || (source && String(source.name) === e.name))
  }
  function showDeviceAction(node) {
    if (!node) return
    contextEndpoint = endpointFor(String(node.name)) || {name: String(node.name), label: nodeLabel(node), supported: false}
    hiddenView = false
    focusSection = "deviceAction"
    selectedIndex = 0
    cursorActive = true
    refreshStatus()
    Qt.callLater(resetScroll)
  }
  function deviceAction(action, name) {
    if (deviceBusy) return
    if (action === "hide" && selectedEndpoint(contextEndpoint)) return
    actionError = ""
    actionErrorKind = ""
    deviceActionProc.command = ["python3", helperPath, action, name]
    deviceActionProc.running = true
  }
  function testOutput() {
    if (!sink || testProc.running || deviceBusy) return
    actionError = ""
    testProc.command = ["python3", helperPath, "test", String(sink.name)]
    testProc.running = true
  }
  function readResult(raw, kind) {
    try {
      var result = JSON.parse(raw)
      if (result.error) { actionError = String(result.error); actionErrorKind = kind }
      return result
    } catch (e) {
      actionError = strings.t("error.invalidResponse")
      actionErrorKind = kind
      return null
    }
  }

  // Nodes of a platform's audio processing, which are neither devices nor apps,
  // stay out of every list (AudioNodes.platformHides). Most machines have none.
  readonly property var nodeNames: {
    var names = []
    for (var i = 0; i < nodes.length; i++)
      if (nodes[i] && nodes[i].name) names.push(String(nodes[i].name))
    return names
  }

  function platformHides(node) {
    return !!node && AudioNodes.platformHides(node.name, nodeNames)
  }

  readonly property var candidateSinks: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isSink || n.isStream || platformHides(n)) continue
      list.push(n)
    }
    return list
  }

  readonly property var candidateSources: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || n.isSink || n.isStream) continue
      if (!isAudioSource(n) && !Model.isUntypedSource(n, sourceAvailability)) continue
      var name = n.name || ""
      if (name === "quickshell" || platformHides(n)) continue
      list.push(n)
    }
    return list
  }

  readonly property var candidateStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream || !isPlaybackStream(n)) continue
      // A tuning's output is a playback stream too, but it is the processing
      // itself rather than an application, so it does not belong in the list.
      if (String(n.name || "").indexOf("omarchy_speaker_tuning") === 0) continue
      if (platformHides(n)) continue
      list.push(n)
    }
    return list
  }

  property var sinkAvailability: ({})
  property bool sinkAvailabilityLoaded: false
  property var sourceAvailability: ({})

  // Identify true playback streams without reading node.properties here:
  // PwNode.properties is invalid until the node is bound, and reading it while
  // capture streams are appearing (for example, when Voxtype starts recording)
  // can destabilize Quickshell's Pipewire service. Quickshell versions differ
  // in how `type` is exposed (media.class, enum name, or numeric enum), but
  // playback streams consistently accept audio input from clients and publish
  // `isSink: true`; capture streams publish as stream sources.
  function isPlaybackStream(node) {
    return Model.isPlaybackStream(node)
  }

  function isAudioSource(node) {
    return Model.isAudioSource(node)
  }


  readonly property var rawAudioSinks: {
    var list = []
    for (var i = 0; i < candidateSinks.length; i++)
      if (sinkAvailable(candidateSinks[i])) list.push(candidateSinks[i])
    if (sink && list.indexOf(sink) < 0) list.unshift(sink)
    return list
  }

  readonly property var rawAudioSources: {
    var list = candidateSources.slice()
    if (source && list.indexOf(source) < 0) list.unshift(source)
    return list
  }

  readonly property var audioSinks: rawAudioSinks
  readonly property var audioSources: rawAudioSources

  readonly property var audioStreams: {
    var list = []
    for (var i = 0; i < candidateStreams.length; i++)
      if (candidateStreams[i].audio) list.push(candidateStreams[i])
    return list
  }

  // Feed Repeaters with panel-local snapshots of primitives instead of the live
  // PipeWire model. PipeWire can remove nodes while Quickshell is dispatching
  // the removal signal, and a row still holding the PwNode is a QObject Qt
  // dereferences without a null check, which segfaults the shell. Rows carry id
  // and name only; every delegate resolves its own node through nodeFor(). The
  // snapshot timer lets the mutation settle first, and closed panels keep their
  // repeaters detached entirely.
  property var displayAudioSinks: []
  property var displayAudioSources: []
  property var displayAudioStreams: []
  property var outputMeterRows: []
  property var outputPeaks: ({})
  readonly property real outputActivity: {
    if (!opened) return 0
    var peak = 0
    for (var key in outputPeaks) peak = Math.max(peak, outputPeaks[key])
    return peak
  }
  function updateOutputPeak(name, peak) {
    var next = Object.assign({}, outputPeaks)
    if (peak < 0) delete next["n:" + name]
    else next["n:" + name] = peak
    outputPeaks = next
  }

  // A DSP sink -- a speaker tuning, or EasyEffects -- can be the selected output
  // without being where loudness lives: changing its volume alters the level going
  // *into* the processing, so the slider would move while the speakers did not,
  // and on a chain with a limiter it would change the tone as well.
  //
  // omarchy-audio-output-sink resolves the *current* default output through any
  // such sink to the physical one, which is the same definition the volume keys
  // and the output switcher use. Resolving the default (rather than "whatever a
  // tuning fronts") is what keeps this correct when headphones or HDMI are
  // selected while a tuning still exists.
  property string volumeSinkName: ""

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  readonly property var volumeSink: {
    if (volumeSinkName === "" || !sink) return sink
    if (volumeSinkName === String(sink.name)) return sink
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === volumeSinkName && n.audio)
        return n
    }
    return sink
  }

  // Re-resolve whenever the selected output changes, and when nodes or links
  // come and go: a tuning being applied or removed underneath us, or a DSP sink
  // rerouted to another output, shows up as exactly that.
  onSinkChanged: { resolveVolumeSink(); scheduleDisplayAudioModelRefresh() }
  onNodesChanged: volumeSinkResolveTimer.restart()

  Connections {
    target: Pipewire.linkGroups
    function onValuesChanged() { volumeSinkResolveTimer.restart(); root.scheduleDisplayAudioModelRefresh() }
  }

  property bool volumeSinkStale: false
  // Bumped by every resolve, so a script read still running from before cannot
  // overwrite a newer answer, the hardware fast path's included.
  property int volumeSinkGeneration: 0
  property int volumeSinkRequest: -1

  function resolveVolumeSink() {
    volumeSinkGeneration++
    // A hardware output is its own volume sink, as omarchy-audio-output-sink
    // reports without looking further, so only a DSP sink needs the script.
    if (sink && String(sink.name).indexOf("alsa_output.") === 0) {
      volumeSinkName = String(sink.name)
      return
    }
    if (volumeSinkProc.running) {
      volumeSinkStale = true
      return
    }
    volumeSinkRequest = volumeSinkGeneration
    volumeSinkProc.running = true
  }

  // An idle EasyEffects is resolved through its configured output device, which
  // changes without touching the Pipewire graph.
  FileView {
    path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/easyeffects/db/easyeffectsrc"
    watchChanges: true
    printErrors: false
    onFileChanged: volumeSinkResolveTimer.restart()
  }

  readonly property real outputVolume: volumeSink && volumeSink.audio ? volumeSink.audio.volume : 0
  readonly property bool outputMuted: volumeSink && volumeSink.audio ? volumeSink.audio.muted : false
  // A virtual source is untyped in Quickshell (see Model.isUntypedSource), so
  // its volume and mute go through wpctl (UntypedInput), and the panel shows no
  // level meter for it: Quickshell's peak monitor takes typed nodes only.
  readonly property bool inputViaWpctl: UntypedInput.active
  readonly property bool inputLevelKnown: !inputViaWpctl || UntypedInput.known
  readonly property real inputVolume: inputViaWpctl ? UntypedInput.volume : (source && source.audio ? source.audio.volume : 0)
  readonly property bool inputMuted: inputViaWpctl ? UntypedInput.muted : (source && source.audio ? source.audio.muted : false)
  readonly property var inputPeakNode: inputViaWpctl ? null : source
  readonly property bool inputLevelShown: !!inputPeakNode


  // Single cursor model shared by keyboard and mouse. Sections:
  //   "output"  — output slider + sink device list
  //   "input"   — input slider + source device list
  //   "streams" — per-app playback streams
  // selectedIndex semantics within a section:
  //   -1            → on the slider row (h/l adjusts volume, m/Enter mute)
  //   0..N-1        → on the Nth device/stream row
  // Visuals derive from hasCursor/current via CursorSurface, never
  // from containsMouse — that's what keeps the highlight unique across
  // keyboard + mouse like wifi does.
  property string focusSection: "output"
  property int selectedIndex: -1
  property bool cursorActive: false

  // The header holds independent speaker/microphone buttons; Left/Right
  // chooses one before Enter activates it.
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  readonly property bool hasOutput: !!(volumeSink && volumeSink.audio)
  readonly property bool hasInput: allMicrophones.count > 0

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Commons.Color.accent)
    : "transparent"
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Commons.Color.accent)
    : "transparent"

  function sectionCount(section) {
    if (section === "output") return displayAudioSinks.length
    if (section === "input") return displayAudioSources.length
    if (section === "hiddenDevices") return connectedHidden.length
    if (section === "streams") return displayAudioStreams.length
    return 0
  }

  function sectionVisible(section) {
    if (section === "test" || section === "hidden") return true
    if (section === "deviceAction") return !!contextEndpoint
    if (section === "hiddenDevices") return hiddenView && connectedHidden.length > 0
    if (section === "output") return true
    if (section === "input") return displayAudioSources.length > 0 || !!source
    if (section === "streams") return displayAudioStreams.length > 0
    return false
  }

  function sectionHasSlider(section) {
    if (section === "output") return true
    if (section === "input") return !!source
    return false  // stream rows carry their own sliders inline; not a section-level slider
  }

  // Order of visible sections, recomputed reactively so dropping a section
  // (e.g. no input devices) doesn't leave the cursor pointing at it.
  readonly property var visibleSections: {
    var list = []
    if (sectionVisible("output")) list.push("output")
    if (sectionVisible("input")) list.push("input")
    if (sectionVisible("streams")) list.push("streams")
    list.push("test", "hidden")
    if (sectionVisible("deviceAction")) list.push("deviceAction")
    if (sectionVisible("hiddenDevices")) list.push("hiddenDevices")
    return list
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (sections.length === 0) return
    if (focusSection === "header") {
      if (delta > 0) { focusSection = sections[0]; selectedIndex = sectionHasSlider(sections[0]) ? -1 : 0 }
      return
    }
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; selectedIndex = sectionHasSlider(focusSection) ? -1 : 0; return }

    var idx = selectedIndex
    var max = sectionCount(focusSection) - 1  // last device index
    var hasSlider = sectionHasSlider(focusSection)
    var floor = hasSlider ? -1 : 0  // -1 = slider row

    if (delta > 0) {
      if (idx < max) { selectedIndex = idx + 1; return }
      // Fall through to next section.
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionHasSlider(focusSection) ? -1 : 0
      }
    } else {
      if (idx > floor) { selectedIndex = idx - 1; return }
      // Escape upward.
      if (sIdx > 0) {
        focusSection = sections[sIdx - 1]
        var prevMax = sectionCount(focusSection) - 1
        selectedIndex = prevMax >= 0 ? prevMax : (sectionHasSlider(focusSection) ? -1 : 0)
      } else {
        focusSection = "header"
      }
    }
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    selectedIndex = -1
  }

  function moveSection(delta) {
    var sections = visibleSections
    if (sections.length === 0) return
    var current = sections.indexOf(focusSection)
    if (current < 0) current = delta > 0 ? -1 : 0
    var next = (current + delta + sections.length) % sections.length
    focusSection = sections[next]
    selectedIndex = sectionHasSlider(focusSection) ? -1 : 0
    cursorActive = true
  }

  // Adjust the slider associated with the focused section. Output and
  // input sliders are real volume controls; on stream rows h/l adjusts
  // that stream's volume (so keyboard parity with the inline slider).
  // For device rows (selectedIndex >= 0 in output/input) h/l is a no-op
  // — the cursor is on a discrete row, not on the slider, and silently
  // moving the global slider would surprise the user.
  function adjustVolume(delta) {
    if (focusSection === "header") {
      selectedIndex = delta > 0 ? 1 : 0
      return
    }
    if (focusSection === "output" && selectedIndex === -1) {
      setOutputVolume(outputVolume + delta)
      return
    }
    if (focusSection === "input" && selectedIndex === -1) {
      setInputVolume(inputVolume + delta)
      return
    }
    if (focusSection === "streams" && selectedIndex >= 0 && selectedIndex < displayAudioStreams.length) {
      var s = nodeFor(displayAudioStreams[selectedIndex])
      if (s && s.audio) s.audio.volume = Math.max(0, Math.min(1.5, s.audio.volume + delta))
    }
  }

  // Enter/Space: activate whatever the cursor is on.
  function activateCursor() {
    if (focusSection === "header") { selectedIndex === 1 ? toggleInputMute() : toggleOutputMute(); return }
    if (focusSection === "test") { testOutput(); return }
    if (focusSection === "hidden") { hiddenView = !hiddenView; contextEndpoint = null; refreshStatus(); return }
    if (focusSection === "deviceAction") {
      if (contextEndpoint && contextEndpoint.supported && !selectedEndpoint(contextEndpoint)) deviceAction("hide", contextEndpoint.name)
      return
    }
    if (focusSection === "hiddenDevices") {
      if (connectedHidden[selectedIndex]) deviceAction("unhide", connectedHidden[selectedIndex].name)
      return
    }
    if (focusSection === "output") {
      if (selectedIndex === -1) { toggleOutputMute(); return }
      var sink = nodeFor(displayAudioSinks[selectedIndex])
      if (sink) setDefaultSink(sink)
      return
    }
    if (focusSection === "input") {
      if (selectedIndex === -1) { toggleInputMute(); return }
      var src = nodeFor(displayAudioSources[selectedIndex])
      if (src) setDefaultSource(src)
      return
    }
    if (focusSection === "streams" && selectedIndex >= 0) {
      var st = nodeFor(displayAudioStreams[selectedIndex])
      if (st && st.audio) st.audio.muted = !st.audio.muted
    }
  }

  onOpenedChanged: {
    if (opened) {
      refreshStatus()
      refreshDisplayAudioModels()
      focusSection = "output"
      selectedIndex = -1  // first keyboard cursor reveal starts on the output slider
      cursorActive = false
      Qt.callLater(resetScroll)
    } else {
      clearDisplayAudioModels()
    }
  }

  // Clamp / repair the cursor whenever any list refreshes underneath us.
  onAudioSinksChanged: scheduleDisplayAudioModelRefresh()
  onAudioSourcesChanged: scheduleDisplayAudioModelRefresh()
  onAudioStreamsChanged: scheduleDisplayAudioModelRefresh()

  function rowSnapshot(list) {
    return Model.rowSnapshot(list)
  }

  // A row that outlives its node resolves to null, or to a node PipeWire recreated
  // under the same id and name; every binding below guards for null, and a row
  // that never held the node cannot dangle.
  function nodeFor(row) {
    if (!row) return null
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.id === row.id && String(n.name || "") === row.name) return n
    }
    return null
  }

  function refreshDisplayAudioModels() {
    if (!opened) return
    displayAudioSinks = rowSnapshot(audioSinks)
    displayAudioSources = rowSnapshot(audioSources)
    displayAudioStreams = rowSnapshot(audioStreams)
    var meterRows = Model.outputMeterRows(nodes, Pipewire.linkGroups.values, sink)
    if (JSON.stringify(meterRows) !== JSON.stringify(outputMeterRows)) outputMeterRows = meterRows
    clampCursor()
  }

  function scheduleDisplayAudioModelRefresh() {
    if (!opened) return
    audioModelRefreshTimer.restart()
  }

  function clearDisplayAudioModels() {
    audioModelRefreshTimer.stop()
    displayAudioSinks = []
    displayAudioSources = []
    displayAudioStreams = []
    outputMeterRows = []
    outputPeaks = ({})
  }

  // Keep the keyboard-focused row inside the visible viewport of the
  // ScrollView. Each cursor target (slider rows, SinkRow, SourceRow,
  // StreamRow) calls this when it gains hasCursor. Without it, j/k can
  // walk the selection off-screen — wifi uses ListView.positionViewAtIndex
  // for this; we don't have that affordance with a multi-section Column.
  function resetScroll() {
    var scrollArea = panel.loadedContent ? panel.loadedContent.scrollArea : null
    if (!scrollArea) return
    var flick = scrollArea.contentItem
    if (flick && flick.contentY !== undefined) flick.contentY = 0
  }

  function ensureCursorVisible(item) {
    var scrollArea = panel.loadedContent ? panel.loadedContent.scrollArea : null
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var margin = 6
    var maxY = Math.max(0, (flick.contentHeight || 0) - flick.height)
    if (maxY <= Style.space(24) || (root.focusSection === "output" && root.selectedIndex === -1)) {
      flick.contentY = 0
      return
    }
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    if (top < viewTop + margin) flick.contentY = Math.max(0, Math.min(maxY, top - margin))
    else if (bottom > viewBottom - margin)
      flick.contentY = Math.max(0, Math.min(maxY, bottom + margin - flick.height))
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    // "header" is virtual and never appears in visibleSections, so it has to
    // be let through: muting republishes the PipeWire snapshot, and clamping
    // would knock the cursor off the hero switch on every toggle.
    if (focusSection === "header") return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = visibleSections[0]
      selectedIndex = sectionHasSlider(focusSection) ? -1 : 0
      return
    }
    var count = sectionCount(focusSection)
    var hasSlider = sectionHasSlider(focusSection)
    var floor = hasSlider ? -1 : 0
    if (selectedIndex > count - 1) selectedIndex = Math.max(floor, count - 1)
    if (selectedIndex < floor) selectedIndex = floor
  }

  function outputIcon(volume) {
    // Match the old Waybar pulseaudio glyph set. The Material Design speaker
    // icons render visually smaller in JetBrainsMono Nerd Font.
    if (!sink || !sink.audio) return ""
    if (isHeadphones(sink)) return "󰋋"
    if (outputMuted) return ""
    var v = volume === undefined ? outputVolume : volume
    if (v >= 0.67) return ""
    if (v >= 0.34) return ""
    if (v > 0) return ""
    return ""
  }

  function inputIcon() {
    if (!hasInput) return "󰍭"
    return inputMuted ? "󰍭" : "󰍬"
  }

  // Playful mood-name for a given output volume. Mirrors the brightness
  // panel's brightnessName ladder; bands are wide enough that small
  // tweaks don't rename the room you're in.
  function outputVolumeName(volume, muted) {
    return Model.outputVolumeName(volume, muted, function(key) { return strings.t(key) })
  }

  function setOutputVolume(v) {
    if (!volumeSink || !volumeSink.audio) return outputVolume
    var volume = Math.max(0, Math.min(1, v))
    volumeSink.audio.volume = volume
    return volume
  }

  function showVolumeOsd(volume) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: outputIcon(volume),
      value: Math.round(volume * 100)
    }))
  }

  function setInputVolume(v) {
    if (inputViaWpctl) {
      UntypedInput.setVolume(v)
      return
    }
    if (!source || !source.audio) return
    source.audio.volume = Math.max(0, Math.min(1, v))
  }

  function toggleOutputMute() {
    if (volumeSink && volumeSink.audio) volumeSink.audio.muted = !volumeSink.audio.muted
  }

  function toggleInputMute() {
    if (!micActionProc.running) {
      actionError = ""
      micActionProc.running = true
    }
  }

  function setDefaultSink(node) {
    if (!node || deviceBusy) return
    Pipewire.preferredDefaultAudioSink = node
    if (node.id !== undefined && node.name) {
      Quickshell.execDetached([
        "omarchy-audio-output-set-default",
        String(node.id),
        String(node.name)
      ])
    }
  }

  function setDefaultSource(node) {
    if (!node || deviceBusy) return
    // Quickshell refuses an untyped node; the command below still selects it.
    if (node.audio) Pipewire.preferredDefaultAudioSource = node
    if (node.id !== undefined && node.name) {
      Quickshell.execDetached([
        "omarchy-audio-input-set-default",
        String(node.id),
        String(node.name)
      ])
    }
  }

  function sinkAvailable(node) {
    if (!node || !node.name || !sinkAvailabilityLoaded) return true
    var name = String(node.name)
    return sinkAvailability[name] !== false
  }

  function updateSinkAvailability(raw) {
    sinkAvailability = Model.parseSinkAvailability(raw)
    sinkAvailabilityLoaded = true
  }

  function friendlyDeviceLabel(text) {
    return Model.friendlyDeviceLabel(text)
  }

  function nodeLabel(node) {
    return Model.nodeLabel(node, function(key) { return strings.t(key) })
  }

  function nodeProps(node) {
    return Model.nodeProps(node)
  }

  function isHeadphones(node) {
    return Model.isHeadphones(node)
  }

  function sinkGlyph(node) {
    return Model.sinkGlyph(node)
  }

  function sourceGlyph(node) {
    return Model.sourceGlyph(node)
  }

  function friendlyStreamLabel(label) {
    return Model.friendlyStreamLabel(label)
  }

  function streamLabelKey(label) {
    return Model.streamLabelKey(label)
  }

  function streamLabelIsGeneric(label) {
    return Model.streamLabelIsGeneric(label)
  }

  function rawStreamLabel(node) {
    return Model.rawStreamLabel(node)
  }

  function mprisPlayerLabel(player) {
    return Model.mprisPlayerLabel(player)
  }

  function mprisPlayerIsProxy(player) {
    return Model.mprisPlayerIsProxy(player)
  }

  function streamRepresentsMprisPlayer(streamLabel, playerLabel) {
    return Model.streamRepresentsMprisPlayer(streamLabel, playerLabel)
  }

  function mprisLabelsFor(predicate) {
    return Model.mprisLabelsFor(mprisPlayers, predicate)
  }

  function matchingMprisStreamLabel(label) {
    return Model.matchingMprisStreamLabel(label, mprisPlayers)
  }

  function unmatchedMprisStreamLabel(label) {
    // Spotify exposes its PipeWire stream as "audio-src". For generic stream
    // names, use the one MPRIS player not already represented by another audio
    // stream (e.g. Chromium, or ALSA apps like cliamp).
    return Model.unmatchedMprisStreamLabel(label, mprisPlayers, audioStreams)
  }

  // These read the other streams' node properties, so they take the live list --
  // displayAudioStreams carries primitives now, and resolving each row back
  // would only rebuild what audioStreams already is.
  function streamLabel(node) {
    return Model.streamLabel(node, mprisPlayers, audioStreams, function(key) { return strings.t(key) })
  }

  function streamRepresentsPlayer(node, player) {
    return Model.streamRepresentsPlayer(node, player, mprisPlayers, audioStreams)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  PwObjectTracker { objects: root.candidateSinks }
  PwObjectTracker { objects: root.candidateSources }
  PwObjectTracker { objects: root.audioStreams }

  PwNodePeakMonitor {
    id: inputPeakMonitor
    node: root.inputPeakNode
    enabled: root.opened && !!root.inputPeakNode
  }

  Instantiator {
    model: root.opened ? root.outputMeterRows : []
    delegate: PwNodePeakMonitor {
      required property var modelData
      node: root.nodeFor(modelData)
      enabled: root.opened && !!node
      onPeakChanged: root.updateOutputPeak(modelData.name, peak)
      Component.onDestruction: root.updateOutputPeak(modelData.name, -1)
    }
  }

  Process {
    id: statusProc
    command: ["python3", root.helperPath, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        var result = root.readResult(text, "status")
        if (result && !result.error) root.deviceStatus = result
      }
    }
  }
  Process {
    id: deviceActionProc
    stdout: StdioCollector {
      onStreamFinished: root.readResult(text, "device")
    }
    onExited: function(code, status) {
      if (code !== 0 && root.actionError === "") root.actionError = strings.t("error.actionFailed")
      if (code === 0) { root.contextEndpoint = null; root.focusSection = root.hiddenView ? "hidden" : "output"; root.selectedIndex = -1 }
      Qt.callLater(root.refreshStatus)
    }
  }
  Process {
    id: micActionProc
    command: ["python3", root.helperPath, "mic-toggle"]
    stdout: StdioCollector {
      onStreamFinished: {
        var result = root.readResult(text, "microphones")
        if (result && !result.error) root.deviceStatus = Object.assign({}, root.deviceStatus, {microphones: result})
      }
    }
    onExited: function(code, status) {
      if (code !== 0 && root.actionError === "") root.actionError = strings.t("error.actionFailed")
      Qt.callLater(root.refreshStatus)
    }
  }
  Process {
    id: testProc
    stdout: StdioCollector { onStreamFinished: root.readResult(text, "test") }
    onExited: function(code, status) {
      if (code !== 0 && root.actionError === "") root.actionError = strings.t("error.actionFailed")
    }
  }
  Timer {
    interval: root.opened ? 1000 : 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  Process {
    id: sinkAvailabilityProc
    command: ["omarchy-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateSinkAvailability(text)
    }
  }

  Process {
    id: sourceAvailabilityProc
    command: ["omarchy-audio-sink-availability", "sources"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.sourceAvailability = Model.parseSinkAvailability(text)
    }
  }

  Process {
    id: volumeSinkProc
    command: ["omarchy-audio-output-sink"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.volumeSinkRequest === root.volumeSinkGeneration) root.volumeSinkName = String(text).trim()
      }
    }
    onExited: {
      if (!root.volumeSinkStale) return
      root.volumeSinkStale = false
      // Deferred: the process still reports running while it signals exit.
      Qt.callLater(root.resolveVolumeSink)
    }
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!sinkAvailabilityProc.running) sinkAvailabilityProc.running = true
      if (!sourceAvailabilityProc.running) sourceAvailabilityProc.running = true
    }
  }

  // Runs whether or not the panel is open: the bar shows and scrolls the output
  // volume too, so an unresolved sink there would read and change the virtual
  // tuning sink instead of the speakers. Streams starting and stopping also
  // change the graph, so a burst of changes resolves once.
  Timer {
    id: volumeSinkResolveTimer
    interval: 500
    onTriggered: root.resolveVolumeSink()
  }

  Component.onCompleted: root.resolveVolumeSink()

  Timer {
    id: audioModelRefreshTimer
    interval: 75
    repeat: false
    onTriggered: root.refreshDisplayAudioModels()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.outputIcon()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleOutputMute()
      else root.toggle()
    }

    onWheelMoved: function(delta) {
      if (!root.hasOutput) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      var volume = root.setOutputVolume(root.outputVolume + wheel.steps * 0.05)
      root.showVolumeOsd(volume)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(560))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias scrollArea: scrollArea
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustVolume(dx * 0.05)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "t" || t === "T") { root.testOutput(); return }
        if (t === "v" || t === "V") { root.hiddenView = !root.hiddenView; root.contextEndpoint = null; root.refreshStatus(); return }
        if (t === "d" || t === "D") {
          var rows = root.focusSection === "output" ? root.displayAudioSinks : (root.focusSection === "input" ? root.displayAudioSources : [])
          if (root.selectedIndex >= 0 && rows[root.selectedIndex]) root.showDeviceAction(root.nodeFor(rows[root.selectedIndex]))
          return
        }
        // 'm' mutes whatever the cursor is on: focused section's slider
        // for output/input, the focused stream for streams.
        if (t === "m" || t === "M") {
          if (!root.cursorActive) return
          if (root.focusSection === "streams" && root.selectedIndex >= 0
              && root.selectedIndex < root.displayAudioStreams.length) {
            var s = root.nodeFor(root.displayAudioStreams[root.selectedIndex])
            if (s && s.audio) s.audio.muted = !s.audio.muted
          } else if (root.focusSection === "input") {
            root.toggleInputMute()
          } else {
            root.toggleOutputMute()
          }
        }
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: speaker icon · title/status ----------
          Item {
            id: heroItem
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, muteButtons.implicitHeight)

            // Status glyph; the independent buttons own muting.
            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.outputIcon()
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              opacity: root.outputMuted ? 0.5 : 1.0
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Row {
              id: muteButtons
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)
              Ui.Button {
                iconText: root.outputMuted ? "󰝟" : "󰕾"
                tooltipText: strings.t("speaker.toggle")
                foreground: root.bar.foreground
                enabled: root.hasOutput
                hasCursor: root.headerHasCursor && root.selectedIndex !== 1
                selected: root.outputMuted
                onHovered: function(on) { if (on) { root.setHeaderCursor(); root.selectedIndex = 0 } }
                onClicked: root.toggleOutputMute()
              }
              Ui.Button {
                iconText: root.allMicrophones.muted ? "󰍭" : "󰍬"
                text: root.allMicrophones.mixed ? strings.t("microphones.mixedShort") : ""
                tooltipText: root.allMicrophones.mixed ? strings.t("microphones.mixed") : strings.t("microphones.toggle")
                foreground: root.bar.foreground
                enabled: root.hasInput && !micActionProc.running && !root.deviceBusy
                hasCursor: root.headerHasCursor && root.selectedIndex === 1
                selected: root.allMicrophones.muted
                onHovered: function(on) { if (on) { root.setHeaderCursor(); root.selectedIndex = 1 } }
                onClicked: root.toggleInputMute()
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: muteButtons.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: strings.t("audio.title")
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: root.outputVolumeName(
                  outputSlider.dragging ? outputSlider.liveValue : root.outputVolume,
                  root.outputMuted
                ).toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            Ui.Button {
              text: strings.t("test")
              foreground: root.bar.foreground
              enabled: !!root.sink && !testProc.running && !root.deviceBusy
              hasCursor: root.cursorActive && root.focusSection === "test"
              onHovered: function(on) { if (on) { root.focusSection = "test"; root.selectedIndex = 0; root.cursorActive = true } }
              onClicked: root.testOutput()
            }
            Ui.Button {
              text: strings.t("hidden.title")
              foreground: root.bar.foreground
              selected: root.hiddenView
              hasCursor: root.cursorActive && root.focusSection === "hidden"
              onHovered: function(on) { if (on) { root.focusSection = "hidden"; root.selectedIndex = 0; root.cursorActive = true } }
              onClicked: { root.hiddenView = !root.hiddenView; root.contextEndpoint = null; root.refreshStatus() }
            }
          }
          Text {
            width: parent.width
            visible: root.deviceBusy || root.actionError !== ""
            textFormat: Text.PlainText
            text: root.deviceBusy ? strings.t("devices.applying") : root.actionError
            wrapMode: Text.Wrap
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: !!root.contextEndpoint
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.contextEndpoint ? root.contextEndpoint.label : ""
              wrapMode: Text.Wrap
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: !root.contextEndpoint || !root.contextEndpoint.supported ? strings.t("devices.unsupported")
                : root.selectedEndpoint(root.contextEndpoint) ? strings.t("devices.switchFirst") : strings.t("devices.interruption")
              wrapMode: Text.Wrap
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Row {
              spacing: Style.space(8)
              Ui.Button {
                text: strings.t("devices.hide")
                foreground: root.bar.foreground
                enabled: !!root.contextEndpoint && root.contextEndpoint.supported && !root.selectedEndpoint(root.contextEndpoint) && !root.deviceBusy
                hasCursor: root.cursorActive && root.focusSection === "deviceAction"
                onClicked: root.deviceAction("hide", root.contextEndpoint.name)
              }
              Ui.Button {
                text: strings.t("cancel")
                foreground: root.bar.foreground
                enabled: !root.deviceBusy
                onClicked: { root.contextEndpoint = null; root.focusSection = "output"; root.selectedIndex = -1 }
              }
            }
          }
          Column {
            width: parent.width
            visible: root.hiddenView
            spacing: Style.space(6)
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.connectedHidden.length ? strings.t("devices.interruption") : strings.t("hidden.empty")
              wrapMode: Text.Wrap
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            Repeater {
              model: root.connectedHidden
              Column {
                required property var modelData
                required property int index
                width: panelColumn.width
                spacing: Style.space(4)
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: strings.t(modelData.direction === "output" ? "hidden.output" : "hidden.input").arg(modelData.label)
                  wrapMode: Text.Wrap
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
                Ui.Button {
                  text: strings.t("devices.unhide")
                  foreground: root.bar.foreground
                  enabled: !root.deviceBusy
                  hasCursor: root.cursorActive && root.focusSection === "hiddenDevices" && root.selectedIndex === index
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(this)
                  onHovered: function(on) { if (on) { root.focusSection = "hiddenDevices"; root.selectedIndex = index; root.cursorActive = true } }
                  onClicked: root.deviceAction("unhide", modelData.name)
                }
              }
            }
          }

          // ---- Output devices ----
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(outputHeader.implicitHeight, outputPercent.implicitHeight)

              PanelSectionHeader {
                id: outputHeader
                text: strings.t("audio.output")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: outputPercent
                textFormat: Text.PlainText
                text: Commons.I18n.formatNumber(Math.round((outputSlider.dragging ? outputSlider.liveValue : root.outputVolume) * 100)) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.outputMuted ? 0.5 : 1.0
              }
            }

            CursorSurface {
              id: outputSliderRow
              width: parent.width
              height: outputSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "output" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(outputSliderRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: outputSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: 1
                step: 0.05
                value: root.outputVolume
                opacity: root.outputMuted ? 0.5 : 1.0
                enabled: !!root.sink

                onMoved: function(v) { root.setOutputVolume(v) }
                onRightClicked: root.toggleOutputMute()
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "output"
                  root.selectedIndex = -1
                }
              }
            }

            Rectangle {
              width: parent.width - Style.space(12)
              x: Style.space(6)
              height: Math.max(Style.space(5), Style.spacing.xs)
              color: Util.alpha(root.bar.foreground, 0.18)
              Rectangle {
                height: parent.height
                width: parent.width * Math.max(0, Math.min(1, root.outputActivity))
                color: root.bar.foreground
                Behavior on width { NumberAnimation { duration: Style.duration(70) } }
              }
            }

            Repeater {
              model: root.displayAudioSinks

              SinkRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                node: root.nodeFor(modelData)
                rowIndex: index
              }
            }
          }

          // ---- Input ----
          PanelSeparator {
            visible: root.displayAudioSources.length > 0 || !!root.source
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.displayAudioSources.length > 0 || !!root.source

            Item {
              width: parent.width
              implicitHeight: Math.max(microphoneHeader.implicitHeight, microphonePercent.implicitHeight)

              PanelSectionHeader {
                id: microphoneHeader
                text: strings.t("audio.input")
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: microphonePercent
                textFormat: Text.PlainText
                text: root.inputLevelKnown ? Commons.I18n.formatNumber(Math.round((inputSlider.dragging ? inputSlider.liveValue : root.inputVolume) * 100)) + "%" : "–"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.inputMuted ? 0.5 : 1.0
              }
            }

            CursorSurface {
              id: inputSliderRow
              visible: !!root.source
              width: parent.width
              height: inputControls.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "input" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(inputSliderRow)
              foreground: root.bar.foreground
              outline: true

              Column {
                id: inputControls
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                // Alone, the slider centres in the row the way the output slider does.
                anchors.topMargin: root.inputLevelShown ? 0 : Style.spacing.controlGap / 2
                spacing: Style.space(5)

                PanelSlider {
                  id: inputSlider
                  bar: root.bar
                  width: parent.width
                  minimum: 0
                  maximum: 1
                  step: 0.05
                  value: root.inputVolume
                  opacity: root.inputMuted ? 0.5 : 1.0
                  enabled: !!root.source

                  onMoved: function(v) { root.setInputVolume(v) }
                  onRightClicked: root.toggleInputMute()
                }

                Rectangle {
                  visible: root.inputLevelShown
                  width: parent.width
                  height: Math.max(Style.space(5), Style.spacing.xs)
                  color: Util.alpha(root.bar.foreground, 0.18)
                  opacity: root.inputMuted ? 0.35 : 1.0

                  Rectangle {
                    height: parent.height
                    width: parent.width * Math.max(0, Math.min(1, inputPeakMonitor.peak))
                    color: root.bar.foreground
                    Behavior on width { NumberAnimation { duration: Style.duration(70) } }
                  }
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "input"
                  root.selectedIndex = -1
                }
              }
            }

            Repeater {
              model: root.displayAudioSources

              SourceRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                node: root.nodeFor(modelData)
                rowIndex: index
              }
            }
          }

          // ---- Per-app streams ----
          PanelSeparator {
            visible: root.displayAudioStreams.length > 0
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displayAudioStreams.length > 0

            PanelSectionHeader {
              text: strings.t("audio.sources")
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.displayAudioStreams

              StreamRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                node: root.nodeFor(modelData)
                rowIndex: index
              }
            }
          }
        }
      }
    }
  }

  // ---- Reusable inline components ----

  // Output device row — cursor target inside the "output" section. Mouse
  // hover updates the panel cursor at the root; visuals come entirely
  // from hasCursor/current via CursorSurface, never from containsMouse.
  component SinkRow: CursorSurface {
    id: sinkRow
    required property var node
    required property int rowIndex

    readonly property bool isActive: root.sink && node && root.sink.id === node.id
    hasCursor: root.cursorActive && root.focusSection === "output" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sinkRow)
    current: isActive
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: sinkInner.implicitHeight + Style.spacing.xl

    Row {
      id: sinkInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: root.sinkGlyph(sinkRow.node)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: root.nodeLabel(sinkRow.node)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: sinkRow.isActive
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "output"
        root.selectedIndex = sinkRow.rowIndex
      }
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.showDeviceAction(sinkRow.node)
        else if (!root.deviceBusy) root.setDefaultSink(sinkRow.node)
      }
    }
  }

  // Input device row — sibling of SinkRow for the "input" section.
  component SourceRow: CursorSurface {
    id: sourceRow
    required property var node
    required property int rowIndex

    readonly property bool isActive: root.source && node && root.source.id === node.id
    hasCursor: root.cursorActive && root.focusSection === "input" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sourceRow)
    current: isActive
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: sourceInner.implicitHeight + Style.spacing.xl

    Row {
      id: sourceInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: root.sourceGlyph(sourceRow.node)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: root.nodeLabel(sourceRow.node)
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: sourceRow.isActive
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "input"
        root.selectedIndex = sourceRow.rowIndex
      }
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) root.showDeviceAction(sourceRow.node)
        else if (!root.deviceBusy) root.setDefaultSource(sourceRow.node)
      }
    }
  }

  // Per-app stream row — cursor target inside the "streams" section.
  // The stream has its own slider inline, so h/l from the keyboard
  // adjusts THIS stream's volume (not the global output) when the cursor
  // sits on this row. Enter/Space mutes the stream.
  component StreamRow: CursorSurface {
    id: streamRow
    required property var node
    required property int rowIndex

    readonly property real streamVolume: node && node.audio ? node.audio.volume : 0
    readonly property bool streamMuted: node && node.audio ? node.audio.muted : false
    readonly property bool isActive: root.streamRepresentsPlayer(node, root.activeMediaPlayer)

    hasCursor: root.cursorActive && root.focusSection === "streams" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(streamRow)
    current: isActive
    foreground: root.bar.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: streamColumn.implicitHeight + Style.spacing.xl

    Column {
      id: streamColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(2)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          id: streamMuteIcon
          textFormat: Text.PlainText
          text: streamRow.streamMuted ? "󰝟" : "󰕾"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.title
          width: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          anchors.verticalCenter: parent.verticalCenter
          opacity: streamRow.streamMuted ? 0.5 : 1.0

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (streamRow.node && streamRow.node.audio)
                streamRow.node.audio.muted = !streamRow.node.audio.muted
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          text: root.streamLabel(streamRow.node)
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          font.bold: streamRow.isActive
          elide: Text.ElideRight
          width: parent.width - streamMuteIcon.width - streamPct.width - Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: streamPct
          textFormat: Text.PlainText
          text: Commons.I18n.formatNumber(Math.round(streamRow.streamVolume * 100)) + "%"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: Style.space(36)
          horizontalAlignment: Text.AlignRight
          anchors.verticalCenter: parent.verticalCenter
          opacity: streamRow.streamMuted ? 0.5 : 1.0
        }
      }

      PanelSlider {
        bar: root.bar
        width: parent.width
        minimum: 0
        maximum: 1.5
        step: 0.05
        value: streamRow.streamVolume
        opacity: streamRow.streamMuted ? 0.5 : 1.0

        onMoved: function(v) {
          if (streamRow.node && streamRow.node.audio) streamRow.node.audio.volume = v
        }
        onRightClicked: {
          if (streamRow.node && streamRow.node.audio)
            streamRow.node.audio.muted = !streamRow.node.audio.muted
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      propagateComposedEvents: true
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.focusSection = "streams"
        root.selectedIndex = streamRow.rowIndex
      }
    }
  }
}
