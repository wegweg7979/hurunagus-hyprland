import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Icons for the windows open on the workspace this bar's monitor is showing,
// ordered the way they sit on screen (left to right, then top to bottom). The
// focused window gets an accent underline. Clicking a window focuses it;
// clicking the focused one minimizes it, the same move as Super+M, so it
// shows up again among the minimized icons. Workspaces.qml supplies bar,
// wsId, vertical and icons, and turns it off with active.
Item {
  id: root

  property QtObject bar: null
  property int wsId: -1
  property bool vertical: false
  property bool active: true
  property QtObject icons: null

  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  // Bumped after a debounced toplevel refresh: positions come from
  // lastIpcObject, which changes without a property signal. Focus does too
  // until the shell has seen a focus change (activeToplevel is null after a
  // restart); then focusHistoryID 0 marks the focused window.
  property int revision: 0

  readonly property var windows: {
    root.revision
    if (!root.active || root.wsId < 1) return []
    var ws = null
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === root.wsId) ws = values[i]
    }
    if (!ws) return []

    var activeTop = Hyprland.activeToplevel
    var list = []
    var tops = ws.toplevels.values
    for (var j = 0; j < tops.length; j++) {
      var ipc = tops[j].lastIpcObject || {}
      list.push({
        top: tops[j],
        focused: activeTop ? tops[j] === activeTop : ipc.focusHistoryID === 0,
        at: ipc.at && ipc.at.length === 2 ? ipc.at : null,
        index: j
      })
    }
    list.sort(function(l, r) {
      if (l.at && r.at) {
        if (l.at[0] !== r.at[0]) return l.at[0] - r.at[0]
        if (l.at[1] !== r.at[1]) return l.at[1] - r.at[1]
      } else if (l.at || r.at) {
        return l.at ? -1 : 1
      }
      return l.index - r.index
    })
    return list
  }

  Connections {
    target: Hyprland
    enabled: root.active
    function onRawEvent(event) {
      var name = String(event.name)
      if (name.indexOf("openwindow") === 0 || name.indexOf("closewindow") === 0 || name.indexOf("movewindow") === 0
          || name.indexOf("activewindow") === 0 || name.indexOf("windowtitle") === 0 || name === "changefloatingmode"
          || name.indexOf("workspace") === 0 || name.indexOf("focusedmon") === 0)
        refreshDebounce.restart()
    }
  }

  Timer {
    id: refreshDebounce
    interval: 120
    onTriggered: {
      Hyprland.refreshToplevels()
      revisionBump.restart()
    }
  }

  Timer {
    id: revisionBump
    interval: 80
    onTriggered: root.revision++
  }

  Component.onCompleted: refreshDebounce.restart()

  function addressOf(top) {
    var addr = String(top && top.address || "")
    return addr.indexOf("0x") === 0 ? addr : "0x" + addr
  }

  function activate(item) {
    if (!root.bar || !item || root.wsId < 1) return
    var target = "address:" + root.addressOf(item.top)
    var command = item.focused
      ? "hl.dsp.window.move({ window = \"" + target + "\", workspace = \"special:min-" + root.wsId + "\", follow = false })"
      : "hl.dsp.focus({ window = \"" + target + "\" })"
    root.bar.run("hyprctl dispatch " + Util.shellQuote(command))
  }

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
        tooltipText: String(button.modelData.top.title || "")
          + (button.modelData.focused ? "\nClick to minimize" : "\nClick to focus")
        useActiveColor: false
        iconComponent: Component {
          Image {
            source: root.icons ? root.icons.iconFor(button.modelData.top) : ""
            fillMode: Image.PreserveAspectFit
            sourceSize.width: Math.round(Style.bar.iconCanvas * Screen.devicePixelRatio)
            sourceSize.height: Math.round(Style.bar.iconCanvas * Screen.devicePixelRatio)
            asynchronous: true
          }
        }
        onPressed: function() { root.activate(button.modelData) }

        Rectangle {
          visible: button.modelData.focused
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Math.round(root.barSize * 0.1)
          width: Math.round(Style.bar.iconCanvas * 0.7)
          height: 2
          radius: 1
          color: Color.accent
        }
      }
    }
  }
}
