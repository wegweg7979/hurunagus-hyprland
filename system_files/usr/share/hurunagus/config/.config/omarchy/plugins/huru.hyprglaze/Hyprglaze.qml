import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Shader wallpaper (hyprglaze) on the Omarchy bar.
//
// A Panel, like the first-party audio and monitor widgets: the bar renders the
// glyph, and the same item owns the popup with the switches, the effect picker
// and the theme picker.
//
// Everything goes through `omarchy-hyprglaze`, exactly the command a user has in
// a terminal, so the panel is a view over it rather than a second implementation:
//
//   omarchy-hyprglaze status --json      state, and the JSON parsed here
//   omarchy-hyprglaze toggle [monitor]   per-monitor (and master) on/off
//   omarchy-hyprglaze set effect <name>  hot-reloaded, no restart
//   omarchy-hyprglaze set theme <name>
//   omarchy-hyprglaze set music on|off   the current effect's section
//
// hyprglaze hot-reloads its config file, so a change lands on every monitor's
// instance without restarting anything.
Panel {
  id: root

  moduleName: "huru.hyprglaze"
  ipcTarget: "huru.hyprglaze"

  readonly property string cmd: "omarchy-hyprglaze"
  readonly property string daemon: "hyprglaze"

  // ---------------------------------------------------------------- state
  //
  // The shape of `status --json` (see system_files/usr/bin/omarchy-hyprglaze):
  //   { installed, layer, monitors: [name], instances: [{monitor, unit, active}],
  //     effect, theme, music, music_sections: [section] }

  property var status: ({})
  property var effects: []
  property var themes: []
  property string pendingEffect: ""
  property string pendingTheme: ""
  property bool actionRunning: false

  readonly property bool installed: status.installed !== false
  readonly property bool anyRunning: (status.instances || []).length > 0
  readonly property bool layerUp: status.layer === true
  readonly property string effect: pendingEffect !== "" ? pendingEffect : (status.effect ? String(status.effect) : "")
  readonly property string theme: pendingTheme !== "" ? pendingTheme : (status.theme ? String(status.theme) : "")
  readonly property bool musicOn: status.music !== false
  readonly property var monitorRows: buildMonitorRows()
  readonly property bool configured: installed && (monitorRows.length > 0 || anyRunning)

  readonly property color fg: barForeground
  readonly property string fontFam: bar && bar.fontFamily ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical === true : false
  readonly property bool showLabel: setting("showLabel", false) === true

  function buildMonitorRows() {
    var rows = []
    var list = status.monitors || []
    var insts = status.instances || []
    for (var i = 0; i < list.length; i++) {
      var on = false
      for (var j = 0; j < insts.length; j++) {
        if (insts[j].monitor === list[i] && insts[j].active === true) on = true
      }
      rows.push({ monitor: String(list[i]), active: on })
    }
    // An instance whose monitor the compositor no longer reports (a screen that
    // is off) still needs a row, or it could never be switched off from here.
    for (var k = 0; k < insts.length; k++) {
      var known = false
      for (var m = 0; m < rows.length; m++) if (rows[m].monitor === insts[k].monitor) known = true
      if (!known) rows.push({ monitor: String(insts[k].monitor), active: insts[k].active === true })
    }
    return rows
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function loadLists() {
    if (!effectsProc.running && effects.length === 0) effectsProc.running = true
    if (!themesProc.running && themes.length === 0) themesProc.running = true
  }

  // Optimistic, like the power-profile widget: the switch turns over on click and
  // the refresh that follows an action confirms or corrects it.
  function run(args) {
    actionProc.command = [root.cmd].concat(args)
    actionProc.running = true
    actionRunning = true
  }

  function masterToggle() {
    if (anyRunning || layerUp) run(["off"])
    else run(["on"])
  }

  function toggleMonitor(name) {
    run(["toggle", name])
  }

  function setEffect(name) {
    if (name === "" || name === root.effect) return
    pendingEffect = name
    run(["set", "effect", name])
  }

  function setTheme(name) {
    if (name === "" || name === root.theme) return
    pendingTheme = name
    run(["set", "theme", name])
  }

  function setMusic(on) {
    run(["set", "music", on ? "on" : "off"])
  }

  function setMusicEverywhere() {
    run(["set", "music", musicOn ? "off" : "on", "--all"])
  }

  function statusLine() {
    if (!installed) return "not installed"
    if (!anyRunning && !layerUp) return "off"
    var n = 0
    var rows = monitorRows
    for (var i = 0; i < rows.length; i++) if (rows[i].active) n++
    return (n > 0 ? n + (n === 1 ? " monitor" : " monitors") : "starting") + (effect !== "" ? " · " + effect : "")
  }

  function buttonText() {
    var glyph = "\uf1fc" // nf-fa-paint_brush
    if (!installed) return glyph
    if (!anyRunning && !layerUp) return glyph
    return showLabel && !vertical && effect !== "" ? glyph + "  " + effect : glyph
  }

  // -------------------------------------------------------------- processes

  Process {
    id: statusProc
    command: [root.cmd, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = null
        try {
          parsed = JSON.parse(String(text || "{}"))
        } catch (e) {
          return
        }
        if (parsed && typeof parsed === "object") {
          root.status = parsed
          // The daemon's own answer wins once an action has settled.
          if (root.pendingEffect !== "" && parsed.effect === root.pendingEffect) root.pendingEffect = ""
          if (root.pendingTheme !== "" && parsed.theme === root.pendingTheme) root.pendingTheme = ""
        }
      }
    }
  }

  Process {
    id: effectsProc
    command: [root.daemon, "--list-effects"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var name = lines[i].trim()
          if (name !== "") next.push({ value: name, label: name })
        }
        root.effects = next
      }
    }
  }

  Process {
    id: themesProc
    command: [root.daemon, "--list-themes"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var name = lines[i].trim()
          if (name !== "") next.push({ value: name, label: name })
        }
        root.themes = next
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      root.actionRunning = false
      root.refresh()
    }
  }

  // While the popup is closed a slow poll keeps the glyph honest; while it is
  // open, a fast one so the switches track the real state.
  Timer {
    interval: root.opened ? 4000 : 20000
    running: root.installed
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    refresh()
    loadLists()
  }

  onOpenedChanged: {
    if (!opened) return
    refresh()
    loadLists()
  }

  // ------------------------------------------------------------- bar button

  visible: installed
  implicitWidth: installed ? button.implicitWidth : 0
  implicitHeight: installed ? button.implicitHeight : 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.buttonText()
    slotSize: root.showLabel && !root.vertical ? Style.bar.iconSlot * 2 : Style.bar.iconSlot
    tooltipText: "Shader wallpaper: " + root.statusLine()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.masterToggle() // the fastest way to switch it
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (root.effects.length < 2) return
      var names = []
      for (var i = 0; i < root.effects.length; i++) names.push(root.effects[i].value)
      var at = names.indexOf(root.effect)
      if (at < 0) at = 0
      var step = delta > 0 ? 1 : -1
      root.setEffect(names[(at + step + names.length) % names.length])
    }
  }

  // ------------------------------------------------------------------ popup

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
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        // `parent.width` here is the flickable's *content* width, which collapses
        // to the column's own implicit width. availableWidth is the viewport.
        Column {
          id: column
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: glyph, state, master switch ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroGlyph.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroGlyph
              textFormat: Text.PlainText
              text: "\uf1fc"
              color: root.anyRunning || root.layerUp ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.5)
              font.family: root.fontFam
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: masterSwitch
              checked: root.anyRunning || root.layerUp
              busy: root.actionRunning
              foreground: root.bar.foreground
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.masterToggle()

              PanelToolTip {
                visible: masterSwitch.containsMouse
                text: root.anyRunning || root.layerUp ? "Turn the wallpaper off" : "Turn the wallpaper on"
                fontFamily: root.fontFam
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroGlyph.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: masterSwitch.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "Shader wallpaper"
                color: root.bar.foreground
                font.family: root.fontFam
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                textFormat: Text.PlainText
                text: root.statusLine().toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.fontFam
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          PanelSeparator { foreground: root.bar.foreground }

          // ---------- Monitors ----------
          PanelSectionHeader {
            text: "MONITORS"
            foreground: root.bar.foreground
            fontFamily: root.fontFam
            visible: root.monitorRows.length > 0
          }

          Repeater {
            model: root.monitorRows

            // An Item, not a Row: a trailing switch needs to be anchored to the
            // right edge, which QML forbids inside a Row.
            Item {
              width: column.width
              implicitHeight: Math.max(rowLabel.implicitHeight, rowSwitch.implicitHeight)
              property var row: modelData

              Text {
                id: rowLabel
                textFormat: Text.PlainText
                text: row.monitor
                color: root.bar.foreground
                font.family: root.fontFam
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              ToggleSwitch {
                id: rowSwitch
                checked: row.active
                busy: root.actionRunning
                foreground: root.bar.foreground
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                onToggled: root.toggleMonitor(row.monitor)
              }
            }
          }

          PanelSeparator { foreground: root.bar.foreground }

          // ---------- Effect ----------
          PanelSectionHeader {
            text: "EFFECT"
            foreground: root.bar.foreground
            fontFamily: root.fontFam
          }

          SearchableDropdown {
            width: parent.width
            label: "Effect"
            fontFamily: root.fontFam
            foreground: root.bar.foreground
            background: root.bar.background
            placeholderText: "Search effects..."
            options: root.effects
            value: root.effect
            onChanged: function(v) { root.setEffect(v) }
          }

          // ---------- Theme ----------
          PanelSectionHeader {
            text: "THEME"
            foreground: root.bar.foreground
            fontFamily: root.fontFam
          }

          SearchableDropdown {
            width: parent.width
            label: "Theme"
            fontFamily: root.fontFam
            foreground: root.bar.foreground
            background: root.bar.background
            placeholderText: "Search " + root.themes.length + " Gogh schemes..."
            options: root.themes
            value: root.theme
            onChanged: function(v) { root.setTheme(v) }
          }

          PanelSeparator { foreground: root.bar.foreground }

          // ---------- Audio ----------
          PanelSectionHeader {
            text: "AUDIO"
            foreground: root.bar.foreground
            fontFamily: root.fontFam
          }

          Item {
            width: column.width
            implicitHeight: Math.max(musicLabel.implicitHeight, musicSwitch.implicitHeight)

            Text {
              id: musicLabel
              textFormat: Text.PlainText
              text: "Music reactivity"
              color: root.bar.foreground
              font.family: root.fontFam
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: musicSwitch
              checked: root.musicOn
              busy: root.actionRunning
              foreground: root.bar.foreground
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.setMusic(!root.musicOn)

              PanelToolTip {
                visible: musicSwitch.containsMouse
                text: "Reads the output monitor's audio; off skips capture entirely"
                fontFamily: root.fontFam
              }
            }
          }

          Item {
            width: column.width
            implicitHeight: Math.max(applyHint.implicitHeight, applyAll.implicitHeight)
            visible: root.effect !== ""

            Text {
              id: applyHint
              textFormat: Text.PlainText
              text: root.musicOn ? "Turn it off for every audio effect too" : "Turn it back on for every audio effect"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.fontFam
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              anchors.left: parent.left
              anchors.right: applyAll.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
            }

            PanelActionButton {
              id: applyAll
              iconText: "\uf021" // nf-fa-refresh, "apply"
              tooltipText: "Write every section that honours music"
              foreground: root.bar.foreground
              fontFamily: root.fontFam
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.setMusicEverywhere()
            }
          }

          // ---------- Footer: where the settings live ----------
          PanelSeparator { foreground: root.bar.foreground }

          Text {
            textFormat: Text.PlainText
            text: root.status.path ? String(root.status.path).replace(/^.*\/\.config/, "~/.config") : ""
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
            width: parent.width
          }
        }
      }
    }
  }
}
