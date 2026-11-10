import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Power-profile picker for the Omarchy bar that does not care whether the
// machine has a battery.
//
// Omarchy's first-party omarchy.power widget owns the same picker, but gates
// its whole panel on `visible: batteryPresent` so it renders zero-width on a
// desktop (UPower reports no battery), and omarchy.battery only auto-switches
// profiles on AC/battery transitions. This widget carries just the profile
// half of that panel and stays put, so desktops get a CPU profile selector on
// the bar and laptops get one that is not entangled with battery state.
//
// Interactions: left = popup picker, right = cycle forward, middle = cycle
// backward, scroll/arrows/keyboard through the picker via the shared focus
// ring (PanelKeyCatcher + the bar navigator).
//
// Reads and writes go through the omarchy-powerprofiles-* helpers, so the
// chosen profile is persisted under the same ac/battery state key the
// first-party tooling uses.
Panel {
  id: root

  moduleName: "thord.powerprofile"
  ipcTarget: "thord.powerprofile"

  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false

  readonly property bool configured: profiles.length > 0
  readonly property bool showLabel: setting("showLabel", false) === true
  readonly property color fg: barForeground
  readonly property string fontFam: bar && bar.fontFamily ? bar.fontFamily : Style.font.family

  // ---------------------------------------------------------------- data flow

  function refresh() {
    if (!profilesProc.running) profilesProc.running = true
  }

  // omarchy-powerprofiles-list --active-state emits `<profile>\t<0|1>` per
  // line, most performant first. An empty payload means the daemon was
  // momentarily unavailable, so keep the last known list rather than blinking
  // the button out.
  function updateProfiles(raw) {
    var next = []
    var current = ""
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      if (parts.length < 1 || !parts[0]) continue
      next.push(parts[0])
      if (parts.length > 1 && String(parts[1]).trim() === "1") current = parts[0]
    }
    if (next.length === 0) return
    profiles = next
    activeProfile = current !== "" ? current : next[0]
    var idx = next.indexOf(activeProfile)
    profileIndex = idx >= 0 ? idx : 0
  }

  function profileIcon(name) {
    if (name === "performance") return "\uf0e7" // nf-fa-bolt
    if (name === "balanced") return "\uf24e" // nf-fa-balance_scale
    if (name === "power-saver") return "\uf06c" // nf-fa-leaf
    return "\uf0e7"
  }

  function profileLabel(name) {
    if (name === "performance") return "Performance"
    if (name === "balanced") return "Balanced"
    if (name === "power-saver") return "Power saver"
    return String(name)
  }

  function buttonText() {
    var glyph = profileIcon(activeProfile)
    return showLabel && activeProfile !== "" ? glyph + " " + profileLabel(activeProfile) : glyph
  }

  function setProfile(name) {
    if (!name || actionProc.running) return
    var target = String(name)
    if (target === activeProfile) return
    pendingProfile = target
    actionProc.command = ["omarchy-powerprofiles-set", "autodetect", target]
    actionProc.running = true
  }

  function cycle(step) {
    if (profiles.length === 0) return
    var i = profiles.indexOf(activeProfile)
    if (i < 0) i = 0
    setProfile(profiles[(i + step + profiles.length) % profiles.length])
  }

  function selectProfileByDelta(delta) {
    if (profiles.length === 0) return
    profileIndex = (profileIndex + delta + profiles.length) % profiles.length
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  // Set optimistically so the label turns over on click rather than a poll
  // later; the refresh on process exit confirms or corrects it.
  property string pendingProfile: ""

  onPendingProfileChanged: if (pendingProfile !== "") activeProfile = pendingProfile

  onOpenedChanged: {
    if (!opened) return
    refresh()
    var idx = profiles.indexOf(activeProfile)
    profileIndex = idx >= 0 ? idx : 0
    cursorActive = false
  }

  onProfilesChanged: if (pendingProfile !== "" && profiles.indexOf(pendingProfile) >= 0) pendingProfile = ""

  Component.onCompleted: refresh()

  // ---------------------------------------------------------------- bar button

  visible: configured
  implicitWidth: configured ? button.implicitWidth : 0
  implicitHeight: configured ? button.implicitHeight : 0

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.buttonText()
    slotSize: root.showLabel && !root.vertical ? Style.bar.iconSlot * 2 : Style.bar.iconSlot
    tooltipText: root.activeProfile === "" ? "CPU power profile" : "CPU power profile: " + root.profileLabel(root.activeProfile)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycle(1)
      else if (b === Qt.MiddleButton) root.cycle(-1)
      else root.toggle()
    }
  }

  // ------------------------------------------------------------------- popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.configured
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          return
        }
        if (dx !== 0) root.selectProfileByDelta(dx > 0 ? 1 : -1)
        else if (dy !== 0) root.selectProfileByDelta(dy > 0 ? 1 : -1)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: active profile glyph + name ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabel.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.profileIcon(root.activeProfile)
            color: root.fg
            font.family: root.fontFam
            font.pixelSize: Style.font.title
          }

          Text {
            id: heroLabel
            textFormat: Text.PlainText
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            text: root.activeProfile === "" ? "Unknown" : root.profileLabel(root.activeProfile)
            color: root.fg
            font.family: root.fontFam
            font.pixelSize: Style.font.title
          }
        }

        PanelSeparator {
          foreground: root.fg
        }

        // ---------- Profile picker ----------
        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "CPU POWER PROFILE"
            foreground: root.fg
            fontFamily: root.fontFam
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles

              Button {
                required property var modelData
                required property int index

                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: root.profileLabel(String(modelData))
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFam
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === String(modelData)
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(String(modelData))
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "The choice is remembered per power source by Omarchy."
            color: root.fg
            opacity: 0.6
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- processes

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateProfiles(text)
    }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  // Poll while the popup is open, and slowly in the background so the bar
  // glyph follows external changes (omarchy-powerprofiles-set, the battery
  // service, a profile changed from a terminal).
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
