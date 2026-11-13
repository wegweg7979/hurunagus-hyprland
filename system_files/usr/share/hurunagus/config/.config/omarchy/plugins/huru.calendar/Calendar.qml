import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Huru Calendar agenda widget.
//
// The data comes from the hcal daemon over IPC (`hcal ipc events.list …`, JSON
// on a unix socket). That daemon is pure Go: it syncs iCloud (CalDAV) with no
// Qt, no shell process and no tray of its own, so this widget is the calendar's
// only UI. Left click opens the agenda, right click forces a sync, middle click
// just re-reads.
Panel {
  id: root

  moduleName: "huru.calendar"
  ipcTarget: "huru.calendar"

  // ---------------------------------------------------------------- settings

  readonly property int dayCount: {
    var d = Math.round(Number(setting("days", 7)))
    if (!isFinite(d) || d < 1) d = 7
    return Math.min(31, d)
  }
  readonly property bool showLabel: setting("showLabel", false) === true
  readonly property bool showCancelled: setting("showCancelled", false) === true

  // ------------------------------------------------------------------- state

  // rows: flat list of {kind: "day"|"event", label|ev, h, y}. Heights are fixed,
  // so the offsets the keyboard scrolls to are exact without measuring the
  // delegates.
  property var rows: []
  property var colors: ({})           // calendarId -> colour, from calendars.list
  property var upcoming: []           // sorted events, same order as the rows
  property bool daemonOk: false       // false = no socket; the panel offers to start it
  property bool loaded: false         // at least one successful read
  property date loadedAt: new Date()
  property int selected: 0            // index into `upcoming`
  property bool cursorActive: false
  property bool syncing: false
  property bool starting: false
  property bool showDetails: true

  readonly property color fg: barForeground
  readonly property string fontFam: bar && bar.fontFamily ? bar.fontFamily : Style.font.family
  readonly property real headerH: Style.space(30)
  readonly property real rowH: Style.space(36)

  readonly property var selectedEvent: (selected >= 0 && selected < upcoming.length) ? upcoming[selected] : null
  readonly property var nextEvent: upcoming.length > 0 ? upcoming[0] : null

  // ------------------------------------------------------------------ helpers

  function iso(date) {
    // RFC3339 without the milliseconds, which is what the IPC params expect.
    return date.toISOString().replace(/\.\d{3}Z$/, "Z")
  }

  function startOfToday() {
    var d = new Date()
    return new Date(d.getFullYear(), d.getMonth(), d.getDate())
  }

  function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
  }

  function dayTitle(date) {
    var today = startOfToday()
    if (sameDay(date, today)) return "TODAY"
    var tomorrow = new Date(today.getTime() + 86400000)
    if (sameDay(date, tomorrow)) return "TOMORROW"
    return Qt.formatDateTime(date, "dddd d MMMM").toUpperCase()
  }

  function timeLabel(ev) {
    return ev.allDay ? "all day" : Qt.formatTime(ev.start, "HH:mm")
  }

  function rangeLabel(ev) {
    if (ev.allDay) {
      var last = new Date(ev.end.getTime() - 86400000)
      if (sameDay(ev.start, last)) return Qt.formatDateTime(ev.start, "ddd d MMM") + " · all day"
      return Qt.formatDateTime(ev.start, "ddd d MMM") + " – " + Qt.formatDateTime(last, "ddd d MMM") + " · all day"
    }
    return Qt.formatDateTime(ev.start, "ddd d MMM HH:mm") + " – " + Qt.formatTime(ev.end, "HH:mm")
  }

  function calendarColor(id) {
    var c = colors[String(id)]
    return c ? String(c) : ""
  }

  function countdown(ev) {
    var mins = Math.round((ev.start.getTime() - Date.now()) / 60000)
    if (mins <= 0) return "now"
    if (mins < 60) return "in " + mins + " min"
    var hours = Math.round(mins / 60)
    if (hours < 24) return "in " + hours + " h"
    return "in " + Math.round(hours / 24) + " d"
  }

  // ------------------------------------------------------------------- reads

  function refresh() {
    if (eventsProc.running) return
    var from = new Date()
    var to = new Date(from.getTime() + dayCount * 86400000)
    eventsProc.command = ["hcal", "ipc", "events.list",
                          "from=" + iso(from), "to=" + iso(to), "limit=250"]
    eventsProc.running = true
  }

  function refreshColors() {
    if (colorsProc.running) return
    colorsProc.running = true
  }

  function syncNow() {
    if (syncProc.running) return
    syncing = true
    syncProc.running = true
  }

  function startDaemon() {
    if (startProc.running) return
    starting = true
    startProc.running = true
    startRetry.start()
  }

  // The daemon answers JSON ({"events":[…]}) or prints an error and exits
  // non-zero when its socket is missing. Parsing is the success test, so the
  // widget never has to reason about exit-code ordering between stdout and
  // exited.
  function applyEvents(raw) {
    var parsed = null
    try {
      parsed = JSON.parse(String(raw || ""))
    } catch (err) {
      parsed = null
    }
    daemonOk = !!(parsed && parsed.events)
    if (!daemonOk) {
      rows = []
      upcoming = []
      loaded = false
      return
    }
    var list = parsed.events
    var events = []
    for (var i = 0; i < list.length; i++) {
      var e = list[i]
      var start = new Date(String(e.start))
      if (isNaN(start.getTime())) continue
      var end = new Date(String(e.end))
      if (isNaN(end.getTime())) end = start
      if (String(e.status) === "cancelled" && !showCancelled) continue
      events.push({
        id: String(e.id || ""),
        uid: String(e.uid || ""),
        summary: String(e.summary || "(no title)"),
        location: String(e.location || ""),
        description: String(e.description || ""),
        meetingUrl: String(e.meetingUrl || ""),
        calendarId: String(e.calendarId || ""),
        status: String(e.status || ""),
        allDay: e.allDay === true,
        start: start,
        end: end
      })
    }
    events.sort(function(a, b) {
      var d = a.start.getTime() - b.start.getTime()
      if (d !== 0) return d
      if (a.allDay === b.allDay) return 0
      return a.allDay ? -1 : 1
    })

    var out = []
    var y = 0
    var dayKey = ""
    for (var j = 0; j < events.length; j++) {
      var ev = events[j]
      var k = ev.start.getFullYear() + "-" + ev.start.getMonth() + "-" + ev.start.getDate()
      if (k !== dayKey) {
        dayKey = k
        out.push({ kind: "day", label: dayTitle(ev.start), h: headerH, y: y })
        y += headerH
      }
      out.push({ kind: "event", ev: ev, index: j, h: rowH, y: y })
      y += rowH
    }
    rows = out
    upcoming = events
    loaded = true
    loadedAt = new Date()
    if (selected >= events.length) selected = events.length > 0 ? events.length - 1 : 0
    if (selected < 0) selected = 0
    keepVisible()
  }

  function applyColors(raw) {
    var parsed
    try {
      parsed = JSON.parse(String(raw || "[]"))
    } catch (err) {
      return
    }
    var map = {}
    var list = parsed instanceof Array ? parsed : []
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].id) map[String(list[i].id)] = String(list[i].color || "")
    }
    colors = map
  }

  // -------------------------------------------------------------- navigation

  function rowForEvent(index) {
    for (var i = 0; i < rows.length; i++)
      if (rows[i].kind === "event" && rows[i].index === index) return i
    return -1
  }

  function move(delta) {
    if (upcoming.length === 0) return
    // The first arrow key only arms the cursor, like the other panels.
    if (!cursorActive) {
      cursorActive = true
      return
    }
    var next = selected + delta
    if (next < 0) next = 0
    if (next > upcoming.length - 1) next = upcoming.length - 1
    selected = next
    keepVisible()
  }

  function keepVisible() {
    if (!flick || flick.height <= 0) return
    var rowIndex = rowForEvent(selected)
    if (rowIndex < 0) return
    var top = rows[rowIndex].y
    var bottom = top + rows[rowIndex].h
    var margin = Style.space(8)
    if (top - margin < flick.contentY)
      flick.contentY = Math.max(0, top - margin)
    else if (bottom + margin > flick.contentY + flick.height)
      flick.contentY = Math.min(Math.max(0, listColumn.implicitHeight - flick.height),
                                bottom + margin - flick.height)
  }

  function scrollBy(amount) {
    if (!flick) return
    flick.contentY = Math.max(0, Math.min(Math.max(0, listColumn.implicitHeight - flick.height),
                                          flick.contentY + amount))
  }

  // ------------------------------------------------------------------- bar UI

  readonly property string glyph: "\uf073" // nf-fa-calendar

  function buttonLabel() {
    if (!showLabel || !nextEvent) return ""
    return nextEvent.allDay ? "" : Qt.formatTime(nextEvent.start, "HH:mm")
  }

  function tooltip() {
    if (!daemonOk) return "Huru Calendar: the hcal daemon is not running"
    if (!loaded) return "Huru Calendar"
    if (upcoming.length === 0) return "Huru Calendar: nothing in the next " + dayCount + " days"
    var lines = []
    var max = Math.min(3, upcoming.length)
    for (var i = 0; i < max; i++) {
      var ev = upcoming[i]
      lines.push(timeLabel(ev) + "  " + ev.summary)
    }
    if (upcoming.length > max) lines.push("+" + (upcoming.length - max) + " more")
    return lines.join("\n")
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened) return
    cursorActive = false
    refresh()
    refreshColors()
    Qt.callLater(keepVisible)
  }

  Component.onCompleted: {
    refresh()
    refreshColors()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    labelText: root.buttonLabel()
    tooltipText: root.tooltip()
    // Nothing upcoming (or no daemon) should not shout: dim the glyph instead.
    dimmed: root.loaded ? root.upcoming.length === 0 : true
    slotSize: root.showLabel && root.buttonLabel() !== "" && !root.vertical
      ? Style.bar.iconSlot * 2
      : Style.bar.iconSlot
    onPressed: function(b) {
      if (b === Qt.RightButton) root.syncNow()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (root.opened) root.move(delta > 0 ? 1 : -1)
    }
  }

  // -------------------------------------------------------------------- popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.move(dy > 0 ? 1 : -1)
        else if (dx !== 0) root.move(dx > 0 ? 1 : -1)
      }
      onActivateRequested: root.showDetails = !root.showDetails
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero: what is next ----------
        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            id: heroGlyph
            textFormat: Text.PlainText
            text: root.glyph
            color: root.fg
            font.family: root.fontFam
            font.pixelSize: Style.font.title
          }

          Column {
            width: parent.width - heroGlyph.width - Style.space(12)
            spacing: Style.space(2)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: root.nextEvent ? root.nextEvent.summary : (root.daemonOk ? "Nothing upcoming" : "Daemon not running")
              color: root.fg
              font.family: root.fontFam
              font.pixelSize: Style.font.title
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: root.nextEvent
                ? root.rangeLabel(root.nextEvent) + "  ·  " + root.countdown(root.nextEvent)
                : (root.daemonOk ? "The next " + root.dayCount + " days are clear, or nothing is synced yet."
                                 : "hcal has no running daemon, so there is nothing to read.")
              color: root.fg
              opacity: 0.7
              font.family: root.fontFam
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        PanelSeparator { foreground: root.fg }

        // ---------- Daemon down: offer the one useful action ----------
        Row {
          width: parent.width
          spacing: Style.space(10)
          visible: !root.daemonOk

          Button {
            id: startButton
            text: root.starting ? "Starting…" : "Start the hcal daemon"
            foreground: root.fg
            fontFamily: root.fontFam
            bordered: true
            onClicked: root.startDaemon()
          }

          Text {
            width: parent.width - startButton.width - Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "systemctl --user start hcal — needs the huru-calendar package."
            color: root.fg
            opacity: 0.6
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Agenda ----------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.daemonOk

          PanelSectionHeader {
            text: "UPCOMING"
            foreground: root.fg
            fontFamily: root.fontFam
          }

          Flickable {
            id: flick
            width: parent.width
            height: Math.min(listColumn.implicitHeight, Style.space(380))
            contentWidth: width
            contentHeight: listColumn.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            clip: true
            interactive: contentHeight > height

            Column {
              id: listColumn
              width: flick.width
              spacing: 0

              Repeater {
                model: root.rows

                delegate: Item {
                  required property var modelData
                  width: listColumn.width
                  height: modelData.h

                  // ---------- day header ----------
                  Text {
                    visible: modelData.kind === "day"
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: visible ? modelData.label : ""
                    color: root.fg
                    opacity: 0.55
                    font.family: root.fontFam
                    font.pixelSize: Style.font.bodySmall
                  }

                  // ---------- event row ----------
                  Item {
                    id: eventRow
                    visible: modelData.kind === "event"
                    anchors.fill: parent
                    anchors.topMargin: Style.space(2)
                    anchors.bottomMargin: Style.space(2)

                    readonly property bool isSelected: visible && root.selectedEvent && modelData.ev
                      && root.selectedEvent.id === modelData.ev.id
                    readonly property color tint: {
                      if (!visible) return Qt.rgba(0, 0, 0, 0)
                      var col = root.calendarColor(modelData.ev.calendarId)
                      if (col !== "") return col
                      return root.fg
                    }

                    Rectangle {
                      anchors.fill: parent
                      radius: Style.cornerRadius
                      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b,
                                     (eventRow.isSelected && root.cursorActive) ? 0.18
                                       : (hover.hovered ? 0.10 : 0.04))
                    }

                    Rectangle {
                      // calendar colour stripe
                      width: Style.space(3)
                      height: parent.height - Style.space(10)
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(4)
                      anchors.verticalCenter: parent.verticalCenter
                      radius: width / 2
                      color: eventRow.tint
                    }

                    Text {
                      id: rowTime
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(16)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(58)
                      textFormat: Text.PlainText
                      text: visible ? (modelData.ev.allDay ? "all day" : Qt.formatTime(modelData.ev.start, "HH:mm")) : ""
                      color: root.fg
                      opacity: 0.75
                      font.family: root.fontFam
                      font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                      id: rowTitle
                      anchors.left: rowTime.right
                      anchors.leftMargin: Style.space(8)
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      text: visible ? modelData.ev.summary : ""
                      color: root.fg
                      font.family: root.fontFam
                      font.pixelSize: Style.font.body
                    }

                    MouseArea {
                      id: hover
                      anchors.fill: parent
                      hoverEnabled: true
                      acceptedButtons: Qt.LeftButton
                      cursorShape: Qt.PointingHandCursor
                      onContainsMouseChanged: if (containsMouse) {
                        root.cursorActive = true
                        root.selected = modelData.index
                      }
                      onClicked: root.selected = modelData.index
                    }
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.daemonOk && root.rows.length === 0
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "Nothing in the next " + root.dayCount + " days."
            color: root.fg
            opacity: 0.6
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Selected event detail ----------
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.daemonOk && root.selectedEvent !== null && root.showDetails

          PanelSeparator { foreground: root.fg }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.selectedEvent ? root.rangeLabel(root.selectedEvent) : ""
            color: root.fg
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            visible: root.selectedEvent ? root.selectedEvent.location !== "" : false
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.selectedEvent ? root.selectedEvent.location : ""
            color: root.fg
            opacity: 0.75
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            visible: root.selectedEvent ? root.selectedEvent.description !== "" : false
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            maximumLineCount: 4
            elide: Text.ElideRight
            text: root.selectedEvent ? root.selectedEvent.description : ""
            color: root.fg
            opacity: 0.6
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Footer ----------
        Text {
          width: parent.width
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: {
            var stamp = Qt.formatTime(root.loadedAt, "HH:mm")
            if (!root.daemonOk) return "hcal: no daemon · " + stamp
            if (root.syncing) return "syncing iCloud… · read " + stamp
            return root.upcoming.length + " event" + (root.upcoming.length === 1 ? "" : "s")
              + " · read " + stamp + " · right click the icon to sync"
          }
          color: root.fg
          opacity: 0.5
          font.family: root.fontFam
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  // --------------------------------------------------------------- processes

  Process {
    id: eventsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyEvents(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("huru.calendar", text.trim())
    }
  }

  Process {
    id: colorsProc
    command: ["hcal", "ipc", "calendars.list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyColors(text)
    }
  }

  Process {
    id: syncProc
    command: ["hcal", "sync"]
    onExited: function() {
      root.syncing = false
      root.refresh()
    }
  }

  Process {
    id: startProc
    command: ["systemctl", "--user", "start", "hcal"]
    onExited: function() { root.starting = false }
  }

  // The daemon needs a moment to bind its socket after systemd returns.
  Timer {
    id: startRetry
    interval: 1500
    repeat: false
    onTriggered: root.refresh()
  }

  // Live while the popup is open, slow in the background so the bar label and
  // the tooltip follow iCloud (the daemon syncs on its own schedule).
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: {
      root.refresh()
      if (root.colors === undefined || Object.keys(root.colors).length === 0) root.refreshColors()
    }
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: false
    onTriggered: root.refresh()
  }

  Timer {
    interval: 600000
    running: true
    repeat: true
    onTriggered: root.refreshColors()
  }
}
