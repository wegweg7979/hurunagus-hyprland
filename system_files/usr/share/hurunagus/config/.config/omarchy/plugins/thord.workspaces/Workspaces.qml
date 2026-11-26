import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// A clone of Omarchy's workspaces widget: each bar lists and highlights its own
// monitor's workspaces, followed by the workspace's layout, the state of its
// focused window, the windows open on it (Windows.qml) and the windows
// minimized from it (Minimized.qml).
// Settings are fields on this widget's entry in ~/.config/omarchy/shell.json.
// The shell passes the entry as-is, without the manifest defaults, so a missing
// flag counts as on:
//   perMonitor          false: every bar lists 1-5 plus every open workspace
//   showLayout          false: no layout label
//   layoutCycleCommand  run with the workspace id when the label is clicked;
//                       empty (the default) leaves the label display-only
//   showWindowState     false: no Max / Float / Group label
//   showWindows         false: no icons for the workspace's open windows
//   showMinimized       false: no minimized icons, restoreLast does nothing
BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  function flag(key) {
    return !root.settings || root.settings[key] !== false
  }

  readonly property bool perMonitor: flag("perMonitor")
  readonly property bool showLayout: flag("showLayout")
  readonly property bool showWindowState: flag("showWindowState")
  readonly property bool showWindows: flag("showWindows")
  readonly property bool showMinimized: flag("showMinimized")
  readonly property string layoutCycleCommand:
    root.settings && root.settings.layoutCycleCommand ? String(root.settings.layoutCycleCommand) : ""

  // One bar surface exists per monitor. Resolve the name of the monitor THIS
  // instance is drawn on, so it can highlight that monitor's active workspace
  // instead of the single globally focused one (which made both bars identical).
  readonly property string screenName:
    root.QsWindow && root.QsWindow.window && root.QsWindow.window.screen
      ? String(root.QsWindow.window.screen.name || "") : ""

  // The Hyprland monitor object matching this bar's screen.
  readonly property var thisMonitor: {
    var mons = Hyprland.monitors.values
    for (var i = 0; i < mons.length; i++) {
      if (String(mons[i].name) === root.screenName) return mons[i]
    }
    return null
  }

  // Workspace this bar's own monitor is displaying. Falls back to the globally
  // focused workspace if the screen can't be resolved yet.
  readonly property int activeWsId:
    thisMonitor && thisMonitor.activeWorkspace ? thisMonitor.activeWorkspace.id
      : (Hyprland.focusedWorkspace !== null ? Hyprland.focusedWorkspace.id : -1)

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  // Workspace id -> monitor selector ("desc:..." or a connector name), read from
  // the workspace rules hyprmoncfg writes. Empty when no rules exist.
  property var ruleMonitors: ({})

  function refreshRules() {
    if (root.perMonitor && !rulesProc.running) rulesProc.running = true
  }

  function parseRules(text) {
    var map = {}
    try {
      var rules = JSON.parse(text)
      for (var i = 0; i < rules.length; i++) {
        var id = parseInt(rules[i].workspaceString, 10)
        if (String(id) === rules[i].workspaceString && id > 0 && rules[i].monitor)
          map[id] = String(rules[i].monitor)
      }
    } catch (e) {
      map = {}
    }
    root.ruleMonitors = map
  }

  function selectorMatchesThisMonitor(selector) {
    if (!root.thisMonitor) return false
    if (selector.indexOf("desc:") === 0)
      return String(root.thisMonitor.description || "").indexOf(selector.slice(5)) === 0
    return selector === root.screenName
  }

  // Workspaces this bar shows: those currently on its monitor, plus those a rule
  // assigns to it that aren't currently open on another monitor. Without any
  // rules (single-screen profiles), or with perMonitor off, it falls back to 1-5
  // plus every open workspace.
  function workspaceIds() {
    var values = Hyprland.workspaces.values
    var ruled = Object.keys(root.ruleMonitors)
    var ids = []

    if (!root.perMonitor || ruled.length === 0 || !root.thisMonitor) {
      ids = [1, 2, 3, 4, 5]
      for (var i = 0; i < values.length; i++) {
        if (values[i].id > 0 && ids.indexOf(values[i].id) === -1) ids.push(values[i].id)
      }
    } else {
      for (var j = 0; j < values.length; j++) {
        var ws = values[j]
        if (ws.id > 0 && ws.monitor && String(ws.monitor.name) === root.screenName) ids.push(ws.id)
      }
      for (var k = 0; k < ruled.length; k++) {
        var id = parseInt(ruled[k], 10)
        if (ids.indexOf(id) !== -1 || root.workspaceById(id) !== null) continue
        if (root.selectorMatchesThisMonitor(root.ruleMonitors[id])) ids.push(id)
      }
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  Process {
    id: rulesProc
    command: ["hyprctl", "-j", "workspacerules"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseRules(text)
    }
  }

  // Layout of the workspace this bar's monitor is showing (hyprctl's tiledLayout),
  // shown as a small label after the workspace numbers.
  readonly property string layoutName: {
    var ws = root.thisMonitor ? root.thisMonitor.activeWorkspace : Hyprland.focusedWorkspace
    var raw = ws && ws.lastIpcObject ? String(ws.lastIpcObject.tiledLayout || "") : ""
    return raw ? raw.charAt(0).toUpperCase() + raw.slice(1) : ""
  }

  // State of the window last focused on this monitor's workspace, shown in the
  // accent colour after the layout: Max (Super+F), Tiled FS (Super+Ctrl+F),
  // Float, Pop out (float + pin), Group i/n, and Square while Omarchy's
  // single-window square aspect toggle is on and actually applies (one tiled
  // window). Plain tiled and real fullscreen (which covers the bar) show nothing.
  // One hyprctl snapshot feeds every bar; it's re-read on window events, and on
  // the custom event thord.window:changed that the Super+Ctrl+F binding sends
  // (a client-only fullscreen change emits no Hyprland event). Pseudo isn't
  // shown: Hyprland exposes it neither in hyprctl nor in its Lua window object.
  property var windowSnapshot: ({ workspaces: [], clients: [], square: false })

  readonly property string squareFlag:
    Quickshell.env("HOME") + "/.local/state/omarchy/toggles/hypr/single-window-aspect-ratio.lua"

  function refreshWindowState() {
    if (root.showWindowState) stateDebounce.restart()
  }

  function parseWindowSnapshot(text) {
    try {
      var data = JSON.parse(text)
      if (data && data.workspaces && data.clients) root.windowSnapshot = data
    } catch (e) {}
  }

  readonly property string windowState: {
    var snap = root.windowSnapshot
    var ws = null
    for (var i = 0; i < snap.workspaces.length; i++) {
      if (snap.workspaces[i].id === root.activeWsId) ws = snap.workspaces[i]
    }
    if (!ws || !ws.lastwindow) return ""

    var win = null
    var tiled = 0
    for (var j = 0; j < snap.clients.length; j++) {
      var c = snap.clients[j]
      if (!c.workspace || c.workspace.id !== root.activeWsId) continue
      if (!c.floating) tiled++
      if (c.address === ws.lastwindow) win = c
    }
    if (!win || win.fullscreen === 2) return ""

    var parts = []
    if (win.fullscreen === 1) parts.push("Max")
    else if (win.fullscreenClient === 2) parts.push("Tiled FS")
    if (win.floating) parts.push(win.pinned ? "Pop out" : "Float")
    var group = win.grouped || []
    if (group.length > 1) parts.push("Group " + (group.indexOf(win.address) + 1) + "/" + group.length)
    if (snap.square && !win.floating && win.fullscreen === 0 && tiled === 1) parts.push("Square")
    return parts.join(" · ")
  }

  Timer {
    id: stateDebounce
    interval: 60
    onTriggered: if (!stateProc.running) stateProc.running = true
  }

  Process {
    id: stateProc
    command: ["sh", "-c",
      'printf \'{"workspaces":\'; hyprctl -j workspaces; printf \',"clients":\'; hyprctl -j clients; ' +
      'if [ -f "$1" ]; then printf \',"square":true}\'; else printf \',"square":false}\'; fi',
      "sh", root.squareFlag]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseWindowSnapshot(text)
    }
  }

  function cycleLayout() {
    if (!root.bar || root.activeWsId < 1 || root.layoutCycleCommand === "") return
    root.bar.run(root.layoutCycleCommand + " " + root.activeWsId)
  }

  // hyprmoncfg applies a profile by rewriting its Lua file and reloading, so
  // re-read the rules on reloads and monitor changes. tiledLayout is only
  // re-read on request: on workspace/monitor switches, reloads, and the custom
  // event thord.layout:changed (a layout rule change emits no event, so a
  // layout command should send it, as workspace-layout-cycle does).
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name)
      if (name === "configreloaded" || name.indexOf("monitoradded") === 0 || name.indexOf("monitorremoved") === 0)
        root.refreshRules()
      if (name === "configreloaded" || name.indexOf("workspace") === 0 || name.indexOf("focusedmon") === 0
          || name.indexOf("moveworkspace") === 0 || (name === "custom" && String(event.data) === "thord.layout:changed"))
        Hyprland.refreshWorkspaces()
      if (name === "configreloaded" || name.indexOf("workspace") === 0 || name.indexOf("focusedmon") === 0
          || name.indexOf("activewindow") === 0 || name.indexOf("fullscreen") === 0 || name === "changefloatingmode"
          || name === "pin" || name.indexOf("openwindow") === 0 || name.indexOf("closewindow") === 0
          || name.indexOf("movewindow") === 0 || name === "togglegroup" || name.indexOf("moveintogroup") === 0
          || name.indexOf("moveoutofgroup") === 0 || (name === "custom" && String(event.data) === "thord.window:changed"))
        root.refreshWindowState()
    }
  }

  onPerMonitorChanged: refreshRules()
  onShowWindowStateChanged: refreshWindowState()

  Component.onCompleted: {
    refreshRules()
    refreshWindowState()
  }

  // `omarchy-shell thord.workspaces restoreLast`: restore the window most
  // recently minimized from the focused workspace (see Minimized.qml).
  IpcHandler {
    target: "thord.workspaces"
    enabled: root.showMinimized

    function restoreLast(): void { minimized.restoreLast() }
  }

  AppIcons {
    id: appIcons
    bar: root.bar
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    // Select THIS bar's monitor first, then switch it to the workspace. The
    // stock widget targets the globally focused monitor, so clicking a pill on
    // one screen could flip the other one instead.
    var ws = "hl.dsp.focus({ workspace = \"" + id + "\" })"
    var mon = root.screenName
    if (mon !== "") {
      root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ monitor = \"" + mon + "\" })")
        + " && hyprctl dispatch " + Util.shellQuote(ws))
    } else {
      root.bar.run("hyprctl dispatch " + Util.shellQuote(ws))
    }
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: row.implicitWidth + trailingGap
  implicitHeight: row.implicitHeight

  // Numbers, layout, window state, open windows and minimized icons in one row
  // (one column on a vertical bar, where only the numbers and icons show). The
  // layout skips hidden items, so turning a part off closes its gap.
  GridLayout {
    id: row
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : 6
    columnSpacing: 0
    rowSpacing: root.vertical ? Style.space(2) : 0

    GridLayout {
      id: grid
      columns: root.vertical ? 1 : root.workspaceIds().length
      columnSpacing: root.vertical ? 0 : Style.space(1)
      rowSpacing: root.vertical ? Style.space(2) : 0

      Repeater {
        model: root.workspaceIds()

        WidgetButton {
          required property int modelData

          readonly property var workspace: root.workspaceById(modelData)
          readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
          readonly property bool focused: root.activeWsId === modelData

          bar: root.bar
          text: focused ? "󱓻" : String(modelData)
          opacity: occupied || focused ? 1 : 0.5
          horizontalMargin: 6
          verticalPadding: 6
          fixedWidth: root.vertical ? root.barSize : Style.space(20)
          fixedHeight: root.barSize
          onPressed: function() { root.focusWorkspace(modelData) }
        }
      }
    }

    WidgetButton {
      id: layoutLabel
      visible: !root.vertical && root.showLayout && root.layoutName !== ""
      bar: root.bar
      text: root.layoutName
      fontSize: Style.font.bodySmall
      opacity: 0.7
      useActiveColor: false
      pressable: root.layoutCycleCommand !== ""
      horizontalMargin: 6
      verticalPadding: 6
      fixedHeight: root.barSize
      tooltipText: root.layoutCycleCommand !== "" ? "Workspace layout. Click to cycle" : "Workspace layout"
      onPressed: function() { root.cycleLayout() }
    }

    WidgetButton {
      id: stateLabel
      visible: !root.vertical && root.showWindowState && root.windowState !== ""
      bar: root.bar
      text: root.windowState
      foreground: Color.accent
      fontSize: Style.font.bodySmall
      useActiveColor: false
      pressable: false
      horizontalMargin: layoutLabel.visible ? 2 : 6
      verticalPadding: 6
      fixedHeight: root.barSize
      tooltipText: "State of this workspace's focused window"
    }

    Windows {
      id: openWindows
      Layout.leftMargin: root.vertical ? 0 : Style.spaceReal(1.5)
      bar: root.bar
      wsId: root.activeWsId
      vertical: root.vertical
      active: root.showWindows
      icons: appIcons
    }

    // Thin line between open and minimized windows, only when both show.
    Rectangle {
      visible: openWindows.visible && minimized.visible
      Layout.alignment: Qt.AlignCenter
      Layout.leftMargin: root.vertical ? 0 : Style.spaceReal(1)
      Layout.rightMargin: root.vertical ? 0 : Style.spaceReal(1)
      Layout.topMargin: root.vertical ? Style.spaceReal(1) : 0
      Layout.bottomMargin: root.vertical ? Style.spaceReal(1) : 0
      implicitWidth: root.vertical ? Math.round(root.barSize * 0.5) : 1
      implicitHeight: root.vertical ? 1 : Math.round(root.barSize * 0.5)
      color: Color.muted
    }

    Minimized {
      id: minimized
      Layout.leftMargin: root.vertical || openWindows.visible ? 0 : Style.spaceReal(1.5)
      bar: root.bar
      wsId: root.activeWsId
      vertical: root.vertical
      active: root.showMinimized
      icons: appIcons
    }
  }
}
