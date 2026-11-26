import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Windows minimized from a workspace live on the hidden Hyprland workspace
// "special:min-<id>" (the Super+M binding puts them there). This part of the
// widget shows the ones belonging to the workspace its own monitor is
// displaying; clicking an icon moves that window back and focuses it. Hyprland
// holds all the state, so a shell restart or plugin reload loses nothing.
// Workspaces.qml supplies bar, wsId, vertical and icons (the shared AppIcons
// lookup), and turns it off with active. Icons are dimmed to read as hidden.
Item {
  id: root

  property QtObject bar: null
  property int wsId: -1
  property bool vertical: false
  property bool active: true
  property QtObject icons: null

  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property string prefix: "special:min-"

  readonly property var minimizedWorkspace: {
    if (!root.active) return null
    var name = root.prefix + root.wsId
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].name) === name) return values[i]
    }
    return null
  }

  readonly property var windows: minimizedWorkspace ? minimizedWorkspace.toplevels.values : []

  // class/initialClass come from lastIpcObject, which is only filled in after a
  // refresh, so refresh whenever a window lands on or leaves a min workspace.
  Connections {
    target: Hyprland
    enabled: root.active
    function onRawEvent(event) {
      var name = String(event.name)
      if (name.indexOf("movewindow") === 0 || name.indexOf("openwindow") === 0 || name.indexOf("windowtitle") === 0)
        Hyprland.refreshToplevels()
    }
  }

  function restore(top) {
    if (!root.bar || !top || root.wsId < 1) return
    var addr = String(top.address || "")
    if (addr.indexOf("0x") !== 0) addr = "0x" + addr
    var move = "hl.dsp.window.move({ window = \"address:" + addr + "\", workspace = \"" + root.wsId + "\" })"
    var focus = "hl.dsp.focus({ window = \"address:" + addr + "\" })"
    root.bar.run("hyprctl dispatch " + Util.shellQuote(move) + " && hyprctl dispatch " + Util.shellQuote(focus))
  }

  // Keyboard restore: `omarchy-shell thord.workspaces restoreLast` brings back the
  // window most recently minimized from the focused workspace. Hidden windows
  // can't take focus, so the lowest focusHistoryID on special:min-<id> is the
  // newest one. Uses hyprctl's fresh client list rather than lastIpcObject,
  // which may lag. The IPC call reaches one bar instance, so it acts on the
  // focused workspace, not on this instance's monitor.
  readonly property string restoreLastScript:
    'addr=$(hyprctl -j clients | jq -r --arg ws "' + prefix + '$1" ' +
    '\'[.[] | select(.workspace.name == $ws)] | min_by(.focusHistoryID) | .address // empty\')\n' +
    '[ -n "$addr" ] || exit 0\n' +
    'hyprctl dispatch "hl.dsp.window.move({ window = \\"address:$addr\\", workspace = \\"$1\\" })" &&\n' +
    'hyprctl dispatch "hl.dsp.focus({ window = \\"address:$addr\\" })"\n'

  function restoreLast() {
    var ws = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
    if (!root.active || ws < 1 || restoreLastProc.running) return
    restoreLastProc.command = ["sh", "-c", root.restoreLastScript, "sh", String(ws)]
    restoreLastProc.running = true
  }

  Process { id: restoreLastProc }

  visible: root.active && root.windows.length > 0
  implicitWidth: visible ? grid.implicitWidth : 0
  implicitHeight: visible ? grid.implicitHeight : 0

  GridLayout {
    id: grid
    anchors.fill: parent
    columns: root.vertical ? 1 : Math.max(1, root.windows.length)
    columnSpacing: 0
    rowSpacing: 0

    Repeater {
      model: root.windows

      BarIconButton {
        id: button
        required property var modelData

        bar: root.bar
        fixedWidth: root.vertical ? root.barSize : Style.bar.iconSlot
        fixedHeight: root.barSize
        tooltipText: String(button.modelData.title || "") + "\nClick to restore"
        useActiveColor: false
        opacity: tooltipHovered ? 1 : 0.55
        iconComponent: Component {
          Image {
            source: root.icons ? root.icons.iconFor(button.modelData) : ""
            fillMode: Image.PreserveAspectFit
            sourceSize.width: Math.round(Style.bar.iconCanvas * Screen.devicePixelRatio)
            sourceSize.height: Math.round(Style.bar.iconCanvas * Screen.devicePixelRatio)
            asynchronous: true
          }
        }
        onPressed: function() { root.restore(button.modelData) }
      }
    }
  }
}
