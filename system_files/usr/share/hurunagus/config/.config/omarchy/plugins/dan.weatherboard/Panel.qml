import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "WeatherModel.js" as Wx

// The full-screen retro weather board -- the pill popup's bigger sibling.
// Summoned as a standalone panel plugin, so `omarchy-shell shell summon
// dan.weatherboard` (or the keybinding in bindings.lua) maps it over the
// focused monitor. One Open-Meteo request feeds everything: current
// conditions, a sun arc, a wind compass, a 24-hour block chart and the hourly
// and seven-day tables. Esc (or the header's close box) dismisses it.
//
// Colours come from the active theme only: Commons.Color.foreground is the
// ink, accent the cold end of the temperature ramp, urgent the warm end, so it
// re-tints with the theme like the rest of the shell.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  // ---- theme ink + the retro type helpers shared by every panel below.
  readonly property color ink: Commons.Color.foreground
  readonly property color dimInk: Qt.darker(root.ink, 1.45)
  readonly property color faintInk: Qt.darker(root.ink, 1.75)
  readonly property color accentInk: Commons.Color.accent
  readonly property color surface: Qt.darker(Commons.Color.background, 1.12)

  // The user's own HuruPixel face for the HURU-WX wordmark. Checked rather than
  // assumed: on a machine without it installed the wordmark falls back to the
  // shell font instead of quietly rendering in whatever Qt picks.
  readonly property string wordmarkFamily: {
    var families = Qt.fontFamilies()
    for (var i = 0; i < families.length; i++)
      if (String(families[i]).toLowerCase() === "hurupixel") return "HuruPixel"
    return Style.font.family
  }

  // Band proportions of the fluid area. The tables get whatever is left.
  // Sized against the measured content: the hero band has to hold a glyph row
  // plus three read-out rows in every panel, and the chart needs enough height
  // for the block ribbon to reach its full cell width.
  readonly property real heroWeight: 0.33
  readonly property real chartWeight: 0.32

  property int refreshMinutes: 15

  // ---- data ------------------------------------------------------------------
  property var report: null
  property string loadError: ""

  property var locationState: ({ name: "", latitude: null, longitude: null })
  property var detectedState: ({ name: "", latitude: null, longitude: null })

  readonly property bool hasCoordinates: !isNaN(parseFloat(String(locationState.latitude))) && !isNaN(parseFloat(String(locationState.longitude)))
  readonly property string reportLocation: locationState.name !== "" ? String(locationState.name) : String(detectedState.name || "")

  readonly property var current: Wx.currentDetail(root.report)
  readonly property var hours: Wx.hourly(root.report, root.nowIsoHour, 24)
  readonly property var days: Wx.days(root.report, 7)
  readonly property var today: root.days.length > 0 ? root.days[0] : null
  readonly property bool hasData: !!root.current && root.days.length > 0

  readonly property string nowIsoHour: {
    var at = root.report && root.report.current ? String(root.report.current.time || "") : ""
    return at.slice(0, 13)
  }

  // ---- functions the shell calls ---------------------------------------------
  function open(payloadJson) {
    opened = true
    root.loadError = ""
    locationFile.reload()
    root.refresh()
  }

  function close() {
    opened = false
  }

  function dismiss() {
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "dan.weatherboard")
    else close()
  }

  // ---- fetch -----------------------------------------------------------------
  function refresh() {
    if (forecastProc.running) return
    var lat = parseFloat(String(root.locationState.latitude))
    var lon = parseFloat(String(root.locationState.longitude))
    if (isNaN(lat) || isNaN(lon)) {
      var alt = parseFloat(String(root.detectedState.latitude))
      var altLon = parseFloat(String(root.detectedState.longitude))
      if (isNaN(alt) || isNaN(altLon)) {
        root.detectLocation()
        return
      }
      lat = alt
      lon = altLon
    }
    forecastProc.command = ["curl", "-fsS", "--max-time", "8", "-A", "omarchy-weather/1.0", Wx.requestUrl(lat, lon, 7)]
    forecastProc.running = true
  }

  function detectLocation() {
    if (locationProc.running) return
    locationProc.running = true
  }

  Process {
    id: forecastProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) { root.loadError = "NO RESPONSE FROM OPEN-METEO"; return }
        try {
          root.report = JSON.parse(raw)
          root.loadError = ""
        } catch (e) {
          root.loadError = "UNREADABLE FORECAST RESPONSE"
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (root.report === null) root.loadError = "OPEN-METEO UNREACHABLE"
    }
  }

  // Coordinates are only looked up when the pill has none configured, so the
  // board remains usable on a machine that never picked a place.
  Process {
    id: locationProc
    command: ["curl", "-fsS", "--max-time", "5", "https://geo.omarchy.org/"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var text0 = String(text || "")
        if (text0.trim() === "") return
        try {
          var parsed = JSON.parse(text0)
          root.detectedState = {
            name: typeof parsed.name === "string" ? parsed.name : "",
            latitude: parsed.latitude,
            longitude: parsed.longitude
          }
          root.refresh()
        } catch (e) {}
      }
    }
  }

  property FileView locationFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var text0 = text()
      try {
        var data = JSON.parse(String(text0 || ""))
        root.locationState = {
          name: typeof data.name === "string" ? data.name : "",
          latitude: data.latitude,
          longitude: data.longitude
        }
      } catch (e) {
        root.locationState = { name: "", latitude: null, longitude: null }
      }
    }
    onLoadFailed: root.locationState = { name: "", latitude: null, longitude: null }
  }

  // Refresh while open; the board is a snapshot, so a slow cadence is enough.
  Timer {
    interval: Math.max(1, root.refreshMinutes) * 60 * 1000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // ---- derived presentation --------------------------------------------------
  readonly property bool useImperial: {
    var locale = String(Qt.locale().name || "").replace(".", "_")
    return /^en[_-]US($|[_.-])/.test(locale) || /^en[_-]LR($|[_.-])/.test(locale)
  }

  function valueOf(value) {
    if (value === undefined || value === null || value === "") return null
    var n = Number(value)
    return isFinite(n) ? n : null
  }

  function tempDisplay(celsius, fahrenheit) {
    return root.valueOf(root.useImperial ? fahrenheit : celsius)
  }

  function tempText(celsius, fahrenheit) {
    var value = root.tempDisplay(celsius, fahrenheit)
    return value === null ? "" : Math.round(value) + "°"
  }

  function speedText(kmph) {
    var value = root.valueOf(kmph)
    if (value === null) return ""
    return root.useImperial ? Math.round(value * 0.621371) + " mph" : Math.round(value) + " km/h"
  }

  function distanceText(km) {
    var value = root.valueOf(km)
    if (value === null) return ""
    return root.useImperial ? Math.round(value * 0.621371) + " mi" : Math.round(value) + " km"
  }

  function oneDecimal(value) {
    var v = root.valueOf(value)
    return v === null ? "" : String(Math.round(v * 10) / 10)
  }

  // Cold-to-warm across the week's own span: theme accent at the cold end,
  // theme urgent at the warm end.
  readonly property var weekExtremes: {
    var lo = null
    var hi = null
    for (var i = 0; i < root.days.length; i++) {
      var min = root.tempDisplay(root.days[i].minC, root.days[i].minF)
      var max = root.tempDisplay(root.days[i].maxC, root.days[i].maxF)
      if (min !== null) lo = lo === null ? min : Math.min(lo, min)
      if (max !== null) hi = hi === null ? max : Math.max(hi, max)
    }
    return { lo: lo, hi: hi }
  }

  function tempColor(value) {
    var lo = root.weekExtremes.lo
    var hi = root.weekExtremes.hi
    var v = root.valueOf(value)
    if (v === null || lo === null || hi === null || hi - lo < 0.001) return root.accentInk
    var k = Math.max(0, Math.min(1, (v - lo) / (hi - lo)))
    var cold = root.accentInk
    var warm = Commons.Color.urgent
    return Qt.rgba(cold.r + (warm.r - cold.r) * k,
                   cold.g + (warm.g - cold.g) * k,
                   cold.b + (warm.b - cold.b) * k,
                   1)
  }

  function dayShort(dateString) {
    var d = new Date(String(dateString) + "T12:00:00")
    if (isNaN(d.getTime())) return ""
    var locale = Qt.locale(Commons.I18n.formatLocale)
    return String(locale.standaloneDayName(d.getDay(), Locale.ShortFormat)).toUpperCase()
  }

  function headerDate() {
    var at = root.current && root.current.observedAt !== "" ? Wx.dateLabel(root.current.observedAt) : Qt.formatDate(new Date(), "yyyy-MM-dd")
    var d = new Date(String(at) + "T12:00:00")
    if (isNaN(d.getTime())) return ""
    var locale = Qt.locale(Commons.I18n.formatLocale)
    return String(locale.standaloneDayName(d.getDay(), Locale.ShortFormat)).toUpperCase()
      + " " + String(at).slice(8, 10) + " "
      + String(locale.standaloneMonthName(d.getMonth(), Locale.ShortFormat)).toUpperCase()
  }

  readonly property string observedText: root.current && root.current.observedAt !== "" ? Wx.clockLabel(root.current.observedAt) : Qt.formatTime(new Date(), "HH:mm")

  readonly property string coordinateText: {
    var lat = root.valueOf(root.locationState.latitude)
    var lon = root.valueOf(root.locationState.longitude)
    if (lat === null || lon === null) return ""
    return Math.abs(lat).toFixed(2) + "°" + (lat >= 0 ? "N" : "S")
      + " " + Math.abs(lon).toFixed(2) + "°" + (lon >= 0 ? "E" : "W")
  }

  readonly property string conditionText: root.current && root.current.code !== null ? Wx.codeLabel(root.current.code) : ""

  // ---- 24-hour chart ---------------------------------------------------------
  readonly property var hourTemps: {
    var out = []
    for (var i = 0; i < root.hours.length; i++)
      out.push(root.useImperial ? root.hours[i].tempF : root.hours[i].tempC)
    return out
  }
  readonly property var hourRain: {
    var out = []
    for (var i = 0; i < root.hours.length; i++) out.push(root.hours[i].precipProb)
    return out
  }
  readonly property var tempCells: Wx.sparkCells(root.hourTemps)
  readonly property var rainCells: Wx.shadePercentCells(root.hourRain)
  readonly property var tickCells: {
    var out = []
    for (var i = 0; i < root.hours.length; i += 3)
      out.push({ index: i, label: String(root.hours[i].hour).slice(0, 2), isDay: root.hours[i].isDay })
    return out
  }

  readonly property string chartSummary: {
    if (!root.hasData) return ""
    var lo = Wx.minOf(root.hourTemps)
    var hi = Wx.maxOf(root.hourTemps)
    var rain = 0
    var chance = 0
    for (var i = 0; i < root.hours.length; i++) {
      var mm = root.valueOf(root.hours[i].precipMm)
      if (mm !== null) rain += mm
      var p = root.valueOf(root.hours[i].precipProb)
      if (p !== null) chance = Math.max(chance, p)
    }
    return "RANGE " + Math.round(lo) + "°…" + Math.round(hi) + "°   RAIN " + (Math.round(rain * 10) / 10) + " mm   PEAK CHANCE " + Math.round(chance) + "%"
  }

  // ---- stat lines ------------------------------------------------------------
  readonly property var nowStats: {
    var w = root.current
    if (!w) return []
    return [
      { label: "FEELS LIKE", value: root.tempText(w.feelsC, w.feelsF) },
      { label: "HUMIDITY", value: w.humidity === null ? "" : Math.round(w.humidity) + "%" },
      { label: "RAIN NOW", value: w.precipMm === null ? "" : root.oneDecimal(w.precipMm) + " mm" },
      { label: "PRESSURE", value: w.pressure === null ? "" : Math.round(root.useImperial ? w.pressureInHg : w.pressure) + (root.useImperial ? " inHg" : " hPa") },
      { label: "VISIBILITY", value: root.distanceText(w.visibilityKm) },
      { label: "RAIN TODAY", value: root.today && root.today.precipMm !== null ? root.oneDecimal(root.today.precipMm) + " mm" : "" }
    ]
  }

  readonly property var windStats: {
    var w = root.current
    if (!w) return []
    return [
      { label: "SPEED", value: root.speedText(w.windKmph) },
      { label: "GUST", value: root.speedText(w.gustKmph) },
      { label: "FROM", value: w.windDeg === null ? "" : Wx.windDirectionLabel(w.windDeg) + " · " + Math.round(w.windDeg) + "°" },
      { label: "PEAK TODAY", value: root.today ? root.speedText(root.today.windMaxKmph) : "" },
      { label: "DOMINANT", value: root.today && root.today.windDeg !== null ? Wx.windDirectionLabel(root.today.windDeg) : "" }
    ]
  }

  readonly property var skyStats: {
    var t = root.today
    if (!t) return []
    return [
      { label: "SUNRISE", value: Wx.clockLabel(t.sunrise) },
      { label: "SUNSET", value: Wx.clockLabel(t.sunset) },
      { label: "DAYLIGHT", value: Wx.durationLabel(Wx.daylightMinutes(t.sunrise, t.sunset)) },
      { label: "UV PEAK", value: t.uvMax === null ? "" : root.oneDecimal(t.uvMax) + " " + Wx.uvRiskLabel(t.uvMax).toUpperCase() }
    ]
  }

  readonly property real uvToday: root.today && root.today.uvMax !== null ? root.valueOf(root.today.uvMax) : 0

  // Sun position between sunrise and sunset, 0..1; anything outside is night.
  readonly property real sunProgress: {
    var t = root.today
    if (!t || !root.current) return 0
    var p = Wx.sunProgress(root.current.observedAt, t.sunrise, t.sunset)
    return p === null ? 0 : Math.max(0, Math.min(1, p))
  }
  readonly property bool sunUp: {
    var t = root.today
    if (!t || !root.current) return false
    var p = Wx.sunProgress(root.current.observedAt, t.sunrise, t.sunset)
    return p !== null && p >= 0 && p <= 1
  }

  // ---- tables ----------------------------------------------------------------
  readonly property var hourlyHeading: [
    { w: 0.10, text: "TIME" },
    { w: 0.06, text: "" },
    { w: 0.10, text: "TEMP", align: "right" },
    { w: 0.10, text: "FEELS", align: "right" },
    { w: 0.09, text: "RAIN", align: "right" },
    { w: 0.09, text: "MM", align: "right" },
    { w: 0.16, text: "WIND", align: "right" },
    { w: 0.10, text: "DIR", align: "right" },
    { w: 0.09, text: "HUM", align: "right" },
    { w: 0.11, text: "UV", align: "right" }
  ]

  readonly property var hourlyTable: {
    var out = []
    for (var i = 0; i < 10 && i < root.hours.length; i++) {
      var h = root.hours[i]
      out.push([
        { w: 0.10, text: h.hour, bold: true, color: i === 0 ? root.accentInk : root.ink },
        { w: 0.06, text: Wx.iconForOpenMeteoCode(h.code, !h.isDay), color: i === 0 ? root.accentInk : root.dimInk },
        { w: 0.10, text: root.tempText(h.tempC, h.tempF), align: "right", bold: true, color: root.tempColor(root.tempDisplay(h.tempC, h.tempF)) },
        { w: 0.10, text: root.tempText(h.feelsC, h.feelsF), align: "right", color: root.faintInk },
        { w: 0.09, text: h.precipProb === null ? "" : Math.round(h.precipProb) + "%", align: "right", color: (root.valueOf(h.precipProb) || 0) > 0 ? root.accentInk : root.faintInk },
        { w: 0.09, text: root.oneDecimal(h.precipMm), align: "right", color: root.faintInk },
        { w: 0.16, text: root.speedText(h.windKmph), align: "right" },
        { w: 0.10, text: Wx.windDirectionLabel(h.windDeg), align: "right", color: root.faintInk },
        { w: 0.09, text: h.humidity === null ? "" : Math.round(h.humidity) + "%", align: "right" },
        { w: 0.11, text: root.oneDecimal(h.uv), align: "right", color: root.faintInk }
      ])
    }
    return out
  }

  readonly property var dayHeading: [
    { w: 0.14, text: "DAY" },
    { w: 0.06, text: "" },
    { w: 0.22, text: "CONDITION" },
    { w: 0.20, text: "RANGE" },
    { w: 0.09, text: "HIGH", align: "right" },
    { w: 0.09, text: "LOW", align: "right" },
    { w: 0.10, text: "RAIN", align: "right" },
    { w: 0.10, text: "MM", align: "right" }
  ]

  readonly property var dayTable: {
    var out = []
    for (var i = 0; i < root.days.length; i++) {
      var d = root.days[i]
      var lo = root.tempDisplay(d.minC, d.minF)
      var hi = root.tempDisplay(d.maxC, d.maxF)
      out.push([
        { w: 0.14, text: i === 0 ? "TODAY" : (root.dayShort(d.date) + " " + String(d.date).slice(8, 10)), bold: true, color: i === 0 ? root.accentInk : root.ink },
        { w: 0.06, text: Wx.iconForOpenMeteoCode(d.code, false), color: root.dimInk },
        { w: 0.22, text: String(Wx.codeLabel(d.code)).toUpperCase(), color: root.dimInk },
        {
          w: 0.20,
          bar: {
            start: Wx.spanFraction(lo, root.weekExtremes.lo, root.weekExtremes.hi),
            end: Wx.spanFraction(hi, root.weekExtremes.lo, root.weekExtremes.hi),
            color: lo === null || hi === null ? root.faintInk : root.tempColor((lo + hi) / 2),
            trough: true
          }
        },
        { w: 0.09, text: root.tempText(d.maxC, d.maxF), align: "right", bold: true, color: root.tempColor(hi) },
        { w: 0.09, text: root.tempText(d.minC, d.minF), align: "right", color: root.faintInk },
        { w: 0.10, text: d.precipProb === null ? "" : Math.round(d.precipProb) + "%", align: "right", color: (root.valueOf(d.precipProb) || 0) > 0 ? root.accentInk : root.faintInk },
        { w: 0.10, text: root.oneDecimal(d.precipMm), align: "right", color: root.faintInk }
      ])
    }
    return out
  }

  // Cumulative left offsets for a row's cells, from their width fractions.
  function columnOffsets(cells) {
    var out = []
    var acc = 0
    for (var i = 0; i < cells.length; i++) {
      out.push(acc)
      acc += Number(cells[i].w || 0)
    }
    return out
  }

  // Read-out lines chunked into rows of two: a panel's stats take half the
  // height they would in a single column, which is what keeps them inside the
  // frame instead of spilling past its border.
  function pairsOf(entries) {
    var out = []
    for (var i = 0; i < entries.length; i += 2) out.push(entries.slice(i, i + 2))
    return out
  }

  // Advance width of one block character at 100px, so the chart can size its
  // own type to fill the width whatever family the theme resolves to.
  TextMetrics {
    id: blockMetrics
    font.family: Style.font.family
    font.pixelSize: 100
    text: "\u2588"
  }
  readonly property real blockAdvanceRatio: {
    var ratio = blockMetrics.advanceWidth / 100
    return (isFinite(ratio) && ratio > 0.2 && ratio < 1.5) ? ratio : 0.6
  }

  // ==========================================================================
  // The surface
  // ==========================================================================
  OverlayWindow {
    id: overlay
    shown: root.opened
    WlrLayershell.namespace: "dan-weather-board"

    Rectangle {
      anchors.fill: parent
      color: root.surface
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.dismiss()

      Item {
        id: board
        anchors.fill: parent
        anchors.margins: Style.space(11)

        // The console frame.
        Rectangle {
          anchors.fill: parent
          color: "transparent"
          border.width: 1
          border.color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.28)
          radius: 0
        }

        Column {
          id: boardColumn
          anchors.fill: parent
          anchors.margins: Style.space(11)
          spacing: Style.space(9)

          readonly property real fluid: Math.max(0, height - headerRow.height - ribbon.height - Style.space(9) * 4)

          // ---- header strip
          Item {
            id: headerRow
            width: parent.width
            height: Style.space(26)

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(9)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "\u258C"
                color: root.accentInk
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
              }
              // The wordmark, set in the user's own HuruPixel face. The dash
              // between the halves is drawn rather than set: the font does
              // carry a hyphen, but at header sizes it is a hairline next to
              // these chunky caps, and a rectangle can be put on the same pixel
              // grid the letters sit on.
              //
              // Size snapped to a multiple of 8: the face's stems are eighths of
              // an em, so 24px draws 3px stems where 21 or 22 draws blurry
              // halves. (Panel titles stay in the shell font for the same
              // reason: caption is 15px on this font scale.)
              Row {
                id: wordmark
                anchors.verticalCenter: parent.verticalCenter
                spacing: Math.round(wordmark.glyphSize * 0.2)

                readonly property int glyphSize: Math.max(8, Math.round(Style.font.heading / 8) * 8)

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "HURU"
                  color: root.ink
                  font.family: root.wordmarkFamily
                  font.pixelSize: wordmark.glyphSize
                  font.letterSpacing: Math.round(wordmark.glyphSize * 0.16)
                }

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.round(wordmark.glyphSize * 0.5)
                  height: Math.max(2, Math.round(wordmark.glyphSize / 8))
                  color: root.ink
                  radius: 0
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "WX"
                  color: root.ink
                  font.family: root.wordmarkFamily
                  font.pixelSize: wordmark.glyphSize
                  font.letterSpacing: Math.round(wordmark.glyphSize * 0.16)
                }
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "\u2502"
                color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.3)
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: (root.reportLocation || "LOCATING").toUpperCase()
                color: root.ink
                font.family: Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
                font.letterSpacing: 2
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                visible: root.coordinateText !== ""
                text: root.coordinateText
                color: root.faintInk
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(12)

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.headerDate()
                color: root.dimInk
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 2
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.observedText
                color: root.ink
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "ESC"
                color: root.faintInk
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1

                TapHandler { onTapped: root.dismiss() }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
              }
            }
          }

          // ---- accent ribbon
          Rectangle {
            id: ribbon
            width: parent.width
            height: Math.max(1, Style.space(2))
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0.0; color: root.accentInk }
              GradientStop { position: 0.5; color: Qt.rgba(root.accentInk.r, root.accentInk.g, root.accentInk.b, 0.3) }
              GradientStop { position: 1.0; color: Qt.rgba(root.accentInk.r, root.accentInk.g, root.accentInk.b, 0.0) }
            }
          }

          // ---- band 1: NOW | SKY | WIND
          Item {
            id: heroBand
            width: parent.width
            height: Math.round(boardColumn.fluid * root.heroWeight)

            Row {
              anchors.fill: parent
              spacing: Style.space(9)

              PanelFrame {
                id: nowPanel
                width: Math.round((heroBand.width - Style.space(18)) * 0.34)
                height: heroBand.height
                title: "NOW"

                Column {
                  id: nowColumn
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  anchors.topMargin: Style.space(26)
                  spacing: Style.space(5)

                  Row {
                    width: parent.width
                    spacing: Style.space(14)

                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.current && root.current.code !== null && !root.current.isDay
                        ? Wx.iconForOpenMeteoCode(root.current.code, true)
                        : Wx.iconForOpenMeteoCode(root.current ? root.current.code : 3, false)
                      color: root.ink
                      font.family: Style.font.family
                      font.pixelSize: Math.round(Style.font.displayLarge * 1.9)
                    }

                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 0

                      Item {
                        width: bigTemp.width + Style.space(6) + bigUnit.width
                        height: bigTemp.implicitHeight

                        Text {
                          id: bigTemp
                          textFormat: Text.PlainText
                          anchors.left: parent.left
                          anchors.top: parent.top
                          text: root.current ? String(Math.round(root.tempDisplay(root.current.tempC, root.current.tempF))) : "—"
                          color: root.ink
                          font.family: Style.font.family
                          font.pixelSize: Math.round(Style.font.displayLarge * 1.55)
                          font.bold: true
                        }
                        Text {
                          id: bigUnit
                          textFormat: Text.PlainText
                          anchors.left: bigTemp.right
                          anchors.leftMargin: Style.space(4)
                          anchors.top: parent.top
                          anchors.topMargin: Style.space(10)
                          text: root.useImperial ? "°F" : "°C"
                          color: root.tempColor(root.current ? root.tempDisplay(root.current.tempC, root.current.tempF) : null)
                          font.family: Style.font.family
                          font.pixelSize: Style.font.heading
                          font.bold: true
                        }
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: root.conditionText.toUpperCase()
                        color: root.accentInk
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.letterSpacing: 3
                      }
                    }
                  }

                  Rectangle {
                    width: parent.width
                    height: Math.max(1, Style.spacing.hairline)
                    color: root.ink
                    opacity: 0.18
                  }

                  Column {
                    width: parent.width
                    spacing: Style.space(3)

                    Repeater {
                      model: root.pairsOf(root.nowStats)

                      StatPair {
                        required property var modelData
                        width: parent.width
                        items: modelData
                      }
                    }
                  }
                }
              }

              PanelFrame {
                id: skyPanel
                width: Math.round((heroBand.width - Style.space(18)) * 0.36)
                height: heroBand.height
                title: "SKY"

                Column {
                  id: skyColumn
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  anchors.topMargin: Style.space(26)
                  spacing: Style.space(6)

                  // Sun arc: ticks along a half circle with the sun on it. The
                  // arc takes whatever height the read-outs below leave, so
                  // this panel cannot overflow its frame either.
                  Item {
                    id: arcArea
                    width: parent.width
                    height: Math.max(Style.space(56),
                      parent.height - skyStats.height - skyUv.height - Style.space(12))

                    readonly property real band: Style.space(13)
                    readonly property real pad: Style.space(9)
                    readonly property real radius: Math.max(0, Math.min(arcArea.width / 2, arcArea.height - arcArea.band) - arcArea.pad)
                    readonly property real tickHeight: Style.space(7)

                    // Ground line across the whole panel, not just the arc.
                    Rectangle {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: arcArea.band
                      height: Math.max(1, Style.spacing.hairline)
                      color: root.ink
                      opacity: 0.3
                    }

                    Item {
                      id: arcDial
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.bottom: parent.bottom
                      anchors.bottomMargin: arcArea.band
                      width: arcArea.radius * 2
                      height: arcArea.radius

                      // Ticks across the sky, sunrise (left) to sunset (right).
                      Repeater {
                        model: 25

                        Item {
                          required property int index
                          anchors.fill: parent
                          // Rotate about the horizon (bottom-centre), not the
                          // box centre: otherwise the arc collapses to a
                          // fraction of its radius and floats above the line.
                          transformOrigin: Item.Bottom
                          rotation: -90 + (index / 24) * 180

                          Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 0
                            width: Math.max(1, Style.spacing.hairline)
                            height: index % 6 === 0 ? arcArea.tickHeight : arcArea.tickHeight * 0.5
                            color: root.ink
                            opacity: index % 6 === 0 ? 0.5 : 0.22
                          }
                        }
                      }

                      // The sun (or its dimmed night position at either end).
                      Item {
                        anchors.fill: parent
                        transformOrigin: Item.Bottom
                        rotation: -90 + root.sunProgress * 180
                        opacity: root.sunUp ? 1 : 0.35

                        Rectangle {
                          anchors.horizontalCenter: parent.horizontalCenter
                          y: 0
                          width: Style.space(9)
                          height: Style.space(9)
                          radius: width / 2
                          color: root.accentInk
                        }
                      }

                    }

                    // The arc's ends, labelled with the times they mark.
                    Text {
                      textFormat: Text.PlainText
                      anchors.horizontalCenter: arcDial.left
                      anchors.top: arcDial.bottom
                      anchors.topMargin: Style.space(3)
                      text: root.today ? Wx.clockLabel(root.today.sunrise) : ""
                      color: root.faintInk
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      textFormat: Text.PlainText
                      anchors.horizontalCenter: arcDial.right
                      anchors.top: arcDial.bottom
                      anchors.topMargin: Style.space(3)
                      text: root.today ? Wx.clockLabel(root.today.sunset) : ""
                      color: root.faintInk
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }

                  TickScale {
                    id: skyUv
                    width: parent.width
                    label: "UV"
                    value: root.uvToday
                    maxValue: 11
                    stops: [3, 6, 8]
                  }

                  Column {
                    id: skyStats
                    width: parent.width
                    spacing: Style.space(3)

                    Repeater {
                      model: root.pairsOf(root.skyStats)

                      StatPair {
                        required property var modelData
                        width: parent.width
                        items: modelData
                      }
                    }
                  }
                }
              }

              PanelFrame {
                id: windPanel
                width: heroBand.width - nowPanel.width - skyPanel.width - Style.space(18)
                height: heroBand.height
                title: "WIND"

                Column {
                  id: windColumn
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  anchors.topMargin: Style.space(26)
                  spacing: Style.space(6)

                  Item {
                    id: compassBox
                    width: parent.width
                    height: Math.max(Style.space(70), parent.height - windStats.height - Style.space(9))

                    Item {
                      id: compass
                      anchors.centerIn: parent
                      width: Math.min(compassBox.width, compassBox.height)
                      height: width

                      Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: 1
                        border.color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.25)
                        radius: width / 2
                      }

                      // Compass points, every 45 degrees, N at the top.
                      Repeater {
                        model: ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

                        Item {
                          required property var modelData
                          required property int index
                          anchors.fill: parent
                          rotation: index * 45

                          Text {
                            textFormat: Text.PlainText
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: Style.space(4)
                            text: modelData
                            color: modelData === "N" ? root.accentInk : root.faintInk
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: modelData === "N"
                          }
                        }
                      }

                      // The needle points where the wind is going -- the
                      // reading itself is the direction it comes FROM.
                      Item {
                        anchors.fill: parent
                        rotation: (root.current && root.current.windDeg !== null ? root.current.windDeg : 0) + 180

                        Rectangle {
                          anchors.horizontalCenter: parent.horizontalCenter
                          anchors.bottom: parent.verticalCenter
                          anchors.bottomMargin: Style.space(4)
                          width: Math.max(2, Style.space(3))
                          height: Math.round(parent.height * 0.32)
                          radius: width / 2
                          color: root.accentInk
                        }
                      }

                      // ...with a tick on the side it is coming from.
                      Item {
                        anchors.fill: parent
                        rotation: root.current && root.current.windDeg !== null ? root.current.windDeg : 0

                        Rectangle {
                          anchors.horizontalCenter: parent.horizontalCenter
                          y: Style.space(4)
                          width: Math.max(1, Style.spacing.hairline)
                          height: Style.space(6)
                          color: root.ink
                          opacity: 0.55
                        }
                      }

                      Rectangle {
                        anchors.centerIn: parent
                        width: Style.space(5)
                        height: Style.space(5)
                        radius: width / 2
                        color: root.ink
                      }
                    }
                  }

                  Column {
                    id: windStats
                    width: parent.width
                    spacing: Style.space(3)

                    Repeater {
                      model: root.pairsOf(root.windStats)

                      StatPair {
                        required property var modelData
                        width: parent.width
                        items: modelData
                      }
                    }
                  }
                }
              }
            }
          }

          // ---- band 2: the 24-hour block chart
          Item {
            id: chartBand
            width: parent.width
            height: Math.round(boardColumn.fluid * root.chartWeight)

            PanelFrame {
              anchors.fill: parent
              title: "NEXT 24 HOURS"
              summary: root.chartSummary

              Column {
                id: chartColumn
                anchors.fill: parent
                anchors.margins: Style.space(10)
                anchors.topMargin: Style.space(26)
                spacing: 0

                // Temperature ribbon: one block character per hour, sized so
                // the row spans the full width.
                Item {
                  id: tempRamp
                  width: parent.width
                  // Whatever the rain band and the hour marks leave. On this
                  // font scale that is what lets the glyphs size to the full
                  // cell width, so the columns abut instead of reading dotted.
                  height: Math.max(Style.space(40),
                    chartColumn.height - rainRamp.height - tickRow.height)

                  readonly property real cellWidth: width / Math.max(1, root.tempCells.length)
                  readonly property real fontSize: Math.max(Style.font.body,
                    Math.min(tempRamp.cellWidth / Math.max(0.2, root.blockAdvanceRatio), tempRamp.height / 1.32))

                  Repeater {
                    model: root.tempCells.length

                    Text {
                      required property int index
                      x: Math.round(index * tempRamp.cellWidth)
                      width: Math.ceil(tempRamp.cellWidth)
                      height: tempRamp.height
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignBottom
                      text: root.tempCells[index]
                      color: root.tempColor(root.hourTemps[index])
                      font.family: Style.font.family
                      font.pixelSize: tempRamp.fontSize
                    }
                  }
                }

                // Chance of rain, same columns, shaded rather than filled.
                Item {
                  id: rainRamp
                  width: parent.width
                  height: Math.round(chartColumn.height * 0.22)

                  readonly property real cellWidth: width / Math.max(1, root.rainCells.length)
                  readonly property real fontSize: Math.max(Style.font.caption,
                    Math.min(rainRamp.cellWidth / Math.max(0.2, root.blockAdvanceRatio), rainRamp.height / 1.32))
                  // Too short a band for one glyph to reach the cell width, so
                  // each cell repeats its shade character to fill the slot: a
                  // textured band rather than a dotted line.
                  readonly property int glyphRepeats: Math.max(1,
                    Math.round(rainRamp.cellWidth / (rainRamp.fontSize * Math.max(0.2, root.blockAdvanceRatio))))

                  Repeater {
                    model: root.rainCells.length

                    Text {
                      required property int index
                      x: Math.round(index * rainRamp.cellWidth)
                      width: Math.ceil(rainRamp.cellWidth)
                      height: rainRamp.height
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignBottom
                      text: root.rainCells[index] === " " ? "" : root.rainCells[index].repeat(rainRamp.glyphRepeats)
                      color: Qt.rgba(root.accentInk.r, root.accentInk.g, root.accentInk.b, 0.85)
                      font.family: Style.font.family
                      font.pixelSize: rainRamp.fontSize
                    }
                  }
                }

                // Hour marks on the same grid.
                Item {
                  id: tickRow
                  width: parent.width
                  height: Style.space(20)

                  readonly property real cellWidth: tempRamp.cellWidth

                  Repeater {
                    model: root.tickCells

                    Text {
                      required property var modelData
                      x: Math.round(modelData.index * tickRow.cellWidth)
                      width: Math.ceil(tickRow.cellWidth * 2)
                      height: tickRow.height
                      verticalAlignment: Text.AlignVCenter
                      text: modelData.label
                      color: Qt.darker(root.ink, modelData.isDay ? 1.35 : 1.75)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }
          }

          // ---- band 3: the tables
          Item {
            id: tablesBand
            width: parent.width
            height: Math.max(0, boardColumn.fluid - heroBand.height - chartBand.height)

            Row {
              anchors.fill: parent
              spacing: Style.space(9)

              PanelFrame {
                id: hourlyPanel
                width: Math.round((tablesBand.width - Style.space(9)) * 0.58)
                height: tablesBand.height
                title: "HOURLY \u2014 NEXT 10 HOURS"

                Column {
                  id: hourlyTable
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  anchors.topMargin: Style.space(26)
                  spacing: 0

                  readonly property real rowHeight: height / 11

                  TableRow {
                    width: parent.width
                    height: hourlyTable.rowHeight
                    cells: root.hourlyHeading
                    heading: true
                  }

                  Repeater {
                    model: root.hourlyTable

                    TableRow {
                      required property var modelData
                      width: parent.width
                      height: hourlyTable.rowHeight
                      cells: modelData
                    }
                  }
                }
              }

              PanelFrame {
                id: dailyPanel
                width: tablesBand.width - hourlyPanel.width - Style.space(9)
                height: tablesBand.height
                title: "7 DAY OUTLOOK"

                Column {
                  id: dailyTable
                  anchors.fill: parent
                  anchors.margins: Style.space(10)
                  anchors.topMargin: Style.space(26)
                  spacing: 0

                  readonly property real rowHeight: height / 8

                  TableRow {
                    width: parent.width
                    height: dailyTable.rowHeight
                    cells: root.dayHeading
                    heading: true
                  }

                  Repeater {
                    model: root.dayTable

                    TableRow {
                      required property var modelData
                      width: parent.width
                      height: dailyTable.rowHeight
                      cells: modelData
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    // ---- nothing to show yet
    Text {
      textFormat: Text.PlainText
      visible: !root.hasData
      anchors.centerIn: parent
      text: root.loadError !== "" ? root.loadError : "ACQUIRING FORECAST\u2026"
      color: root.dimInk
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.letterSpacing: 3
    }
  }

  // ==========================================================================
  // Retro console pieces. Theme colours only, so a theme switch re-tints the
  // whole board.

  // A hairline-framed panel with a letter-spaced title and an optional
  // right-aligned summary on the same line.
  component PanelFrame: Rectangle {
    id: frame
    property string title: ""
    property string summary: ""

    color: "transparent"
    border.width: 1
    border.color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.22)
    radius: 0

    Text {
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.margins: Style.space(9)
      text: frame.title
      color: root.dimInk
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 3
    }

    Text {
      textFormat: Text.PlainText
      visible: frame.summary !== ""
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(9)
      text: frame.summary
      color: root.faintInk
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 1
    }
  }

  // Two read-outs side by side, each half the row.
  component StatPair: Row {
    id: pair
    property var items: []

    width: parent.width
    spacing: Style.space(6)

    Repeater {
      model: pair.items

      StatLine {
        required property var modelData
        // Half the row each, less the gap: without it the first column's
        // right-aligned value touches the second column's label.
        width: (pair.width - pair.spacing) / 2
        label: modelData.label
        value: modelData.value
      }
    }
  }

  // LABEL .............................. VALUE
  component StatLine: Item {
    id: line
    property string label: ""
    property string value: ""
    property color valueColor: root.ink

    width: parent.width
    height: Math.max(labelText.implicitHeight, valueText.implicitHeight) + Style.space(2)

    Text {
      id: labelText
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: line.label
      color: root.faintInk
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 2
    }

    Text {
      id: valueText
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: line.value
      color: line.valueColor
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
    }
  }

  // A 0..maxValue scale with tick stops and a marker at `value`.
  component TickScale: Item {
    // NOT `scale`: Item already has a `scale` property, and inside a nested
    // delegate that property shadows an id of the same name.
    id: gauge
    property string label: ""
    property real value: 0
    property real maxValue: 11
    property var stops: []
    property string tailLabel: ""

    width: parent.width
    height: Math.max(labelText.implicitHeight, tailText.implicitHeight, track.height) + Style.space(2)

    Text {
      id: labelText
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: gauge.label
      color: root.faintInk
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.letterSpacing: 2
    }

    Text {
      id: tailText
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: gauge.tailLabel
      color: root.faintInk
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Rectangle {
      id: track
      anchors.left: labelText.right
      anchors.leftMargin: Style.space(10)
      anchors.right: tailText.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(1, Style.spacing.hairline)
      color: root.ink
      opacity: 0.3
    }

    Repeater {
      model: gauge.stops

      Rectangle {
        required property var modelData
        anchors.verticalCenter: track.verticalCenter
        x: track.x + track.width * (modelData / Math.max(0.001, gauge.maxValue)) - width / 2
        width: Math.max(1, Style.spacing.hairline)
        height: Style.space(6)
        color: root.ink
        opacity: 0.45
      }
    }

    Rectangle {
      anchors.verticalCenter: track.verticalCenter
      x: track.x + track.width * Math.max(0, Math.min(1, gauge.value / Math.max(0.001, gauge.maxValue))) - width / 2
      width: Style.space(4)
      height: Style.space(10)
      color: root.accentInk
    }
  }

  // One table line: text cells, or a range/probability bar cell. Column
  // geometry comes from each cell's own width fraction.
  component TableRow: Item {
    id: row
    property var cells: []
    property bool heading: false
    property real cellGap: Style.space(5)

    width: parent.width
    height: Style.space(16)

    readonly property var offsets: root.columnOffsets(row.cells)

    Rectangle {
      visible: row.heading
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Math.max(1, Style.spacing.hairline)
      color: root.ink
      opacity: 0.22
    }

    Repeater {
      model: row.cells

      Item {
        id: cellItem
        required property var modelData
        required property int index

        readonly property var cell: modelData

        x: Math.round(row.offsets[index] * row.width)
        width: Math.round((cell.w === undefined ? 0 : cell.w) * row.width)
        height: row.height

        Text {
          visible: cellItem.cell.bar === undefined
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.rightMargin: row.cellGap
          anchors.verticalCenter: parent.verticalCenter
          text: cellItem.cell.text === undefined ? "" : String(cellItem.cell.text)
          elide: Text.ElideRight
          horizontalAlignment: cellItem.cell.align === "right" ? Text.AlignRight : Text.AlignLeft
          color: cellItem.cell.color !== undefined
            ? cellItem.cell.color
            : (row.heading ? root.faintInk : root.ink)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: cellItem.cell.bold === true || row.heading
          font.letterSpacing: row.heading ? 2 : 0
        }

        Rectangle {
          id: cellBar
          visible: cellItem.cell.bar !== undefined
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.rightMargin: row.cellGap
          anchors.verticalCenter: parent.verticalCenter
          height: Math.max(2, Math.round(row.height * 0.44))
          color: "transparent"
          border.width: cellItem.cell.bar !== undefined && cellItem.cell.bar.trough ? 1 : 0
          border.color: Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.18)
          radius: 0

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            x: 1 + (cellItem.cell.bar === undefined ? 0 : cellItem.cell.bar.start) * Math.max(0, cellBar.width - 2)
            width: Math.max(2, ((cellItem.cell.bar === undefined ? 0 : cellItem.cell.bar.end) - (cellItem.cell.bar === undefined ? 0 : cellItem.cell.bar.start)) * Math.max(0, cellBar.width - 2))
            height: Math.max(2, cellBar.height - 2)
            radius: 0
            color: cellItem.cell.bar === undefined ? root.ink : cellItem.cell.bar.color
            opacity: 0.92
          }
        }
      }
    }
  }
}
