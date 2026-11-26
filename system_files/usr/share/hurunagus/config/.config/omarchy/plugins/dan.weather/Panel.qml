import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model
import "WeatherModel.js" as Wx

// The weather pill's detail popup, dressed as a retro console read-out.
// Upstream's popup showed a hero and a three-day strip; this one keeps every
// bit of the plumbing (both providers, location editing, retries) and spends
// the extra width on a 24-hour block sparkline with a rainfall shade row, a
// seven-day range-bar table and a details grid. All colour comes from the
// active theme: accent is the cold end of the temperature ramp, urgent the
// warm end, so the whole thing re-tints on a theme switch.
Panel {
  id: root
  moduleName: "omarchy.weather"
  ipcTarget: "omarchy.weather"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    locationFile.reload()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    locationFile.reload()
    root.refresh()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingLocation) root.cancelEditingLocation()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // Parsed wttr.in j1 response. Kept on failure so stale data stays visible.
  property var report: null
  property var dailyForecastReport: null

  // Configured location, read from the weather.json state file (owned by
  // omarchy-weather-location). The watch makes hand edits take effect live.
  property var configuredLocationState: ({ name: "", latitude: null, longitude: null })
  readonly property string configuredLocation: configuredLocationState.name

  // With nothing configured, where geo.omarchy.org places this network, in the
  // same shape. Kept when a later lookup fails.
  property var detectedLocationState: ({ name: "", latitude: null, longitude: null })
  property bool detectingLocation: false
  readonly property bool autoLocation: Model.isAutoLocation(configuredLocationState)
  onAutoLocationChanged: if (autoLocation) detectLocation()

  // The query is the wttr.in path segment (coordinates when known, else the
  // encoded name); empty means wttr.in's own IP auto-detect, used only when
  // geo.omarchy.org could not answer.
  readonly property var locationState: Model.effectiveLocation(configuredLocationState, detectedLocationState)
  readonly property string locationQuery: Model.wttrLocationQuery(locationState.name, locationState.latitude, locationState.longitude)

  // Keep the previous report visible while the new location loads. The
  // editor remains open with a spinner, so stale data is never presented
  // under the newly configured location label.
  onLocationQueryChanged: {
    if (savingLocation) savingLocationQueryStarted = true
    forecastRetries = 0
    dailyForecastRetries = 0
    forecastProc.running = false
    dailyForecastProc.running = false
    Qt.callLater(refresh)
  }

  property FileView locationFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.configuredLocationState = Model.parseLocationFile(text())
    onLoadFailed: root.configuredLocationState = Model.parseLocationFile("")
  }

  // The first read can race shell startup (observed sporadically), leaving a
  // stored location unhonored until the next file write. One delayed reload
  // self-corrects; if the first read was fine it's a no-op, since identical
  // state doesn't change locationQuery and so triggers no refetch.
  Timer {
    interval: 1500
    running: true
    onTriggered: locationFile.reload()
  }

  property int forecastRetries: 0
  property int dailyForecastRetries: 0

  // Click-to-edit state for the location label.
  property bool editingLocation: false
  property bool savingLocation: false
  property bool savingLocationQueryStarted: false
  property var locationSuggestions: []
  property int suggestionIndex: 0
  property string geocodePendingQuery: ""
  property string geocodeActiveQuery: ""

  // Shared hero/bar icon state, updated with each successful weather response.
  property string label: ""

  // wttr's current conditions when available; open-meteo's (bundled with the
  // much faster daily forecast fetch) fill the hero while wttr is in flight.
  readonly property bool hasConfiguredCoordinates: !isNaN(parseFloat(String(configuredLocationState.latitude))) && !isNaN(parseFloat(String(configuredLocationState.longitude)))
  readonly property bool hasCoordinates: !isNaN(parseFloat(String(locationState.latitude))) && !isNaN(parseFloat(String(locationState.longitude)))
  readonly property var openMeteoCurrent: Model.openMeteoCurrentCondition(dailyForecastReport)
  readonly property var current: (hasCoordinates && openMeteoCurrent) ? openMeteoCurrent : ((report && report.current_condition && report.current_condition[0]) ? report.current_condition[0] : openMeteoCurrent)
  readonly property var areaInfo: report && report.nearest_area && report.nearest_area[0] ? report.nearest_area[0] : null
  readonly property var forecastDays: buildForecastDays()
  readonly property string reportCountry: areaInfo && areaInfo.country && areaInfo.country[0] ? areaInfo.country[0].value : ""

  readonly property bool useImperial: Model.shouldUseImperial(setting("unit", ""), Qt.locale().name, reportCountry)

  // Auto-refresh interval in minutes; clamped to a sane minimum.
  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 15), 10) || 15)

  readonly property string reportLocation:  configuredLocation || (autoLocation ? detectedLocationState.name : "") || (areaInfo && areaInfo.areaName && areaInfo.areaName[0] ? areaInfo.areaName[0].value : "")
  readonly property string reportTempNum:   current ? displayNumber(useImperial ? current.temp_F : current.temp_C) : ""
  readonly property string tempUnit:        "°" + (useImperial ? "F" : "C")
  readonly property string reportFeels:     current ? formatTemp(useImperial ? current.FeelsLikeF : current.FeelsLikeC) : ""
  readonly property string reportWind:      current ? (useImperial ? (displayNumber(current.windspeedMiles) + " mph") : (displayNumber(current.windspeedKmph) + " km/h")) : ""
  readonly property string reportHumidity:  current ? (displayNumber(current.humidity) + "%") : ""

  // The report's numbers arrive as strings ("13"), and blank when missing.
  function displayNumber(value) {
    if (value === undefined || value === null || value === "") return ""
    return Commons.I18n.formatNumber(value)
  }

  function refresh() {
    // Each full refresh cycle gets a fresh retry budget, so an earlier
    // exhausted round (e.g. waking with the network still down) doesn't
    // starve retries for the rest of the session.
    forecastRetries = 0
    dailyForecastRetries = 0
    // Until geo.omarchy.org answers there is nothing to ask for: wait for it
    // rather than have wttr.in look this machine up. Its answer, or its
    // failure, refreshes again.
    if (detectingLocation && locationQuery === "") return
    if (!forecastProc.running) forecastProc.running = true
    // With coordinates this fetches open-meteo right away — no need to wait
    // for the slow wttr response. Without them it's a no-op until wttr
    // reports the area.
    refreshDailyForecast(null)
  }

  function detectLocation() {
    if (locationProc.running) return
    detectingLocation = true
    locationProc.running = true
  }

  function refreshDailyForecast(sourceReport) {
    if (dailyForecastProc.running) return

    var lat = parseFloat(String(root.locationState.latitude))
    var lon = parseFloat(String(root.locationState.longitude))
    if (isNaN(lat) || isNaN(lon)) {
      var area = sourceReport && sourceReport.nearest_area && sourceReport.nearest_area[0] ? sourceReport.nearest_area[0] : root.areaInfo
      if (!area) return
      lat = parseFloat(String(area.latitude || ""))
      lon = parseFloat(String(area.longitude || ""))
    }
    if (isNaN(lat) || isNaN(lon)) return

    // One request carries the hourly and daily series both the popup and the
    // board read (see WeatherModel.js).
    var url = Wx.requestUrl(lat, lon, 7)
    // Open-Meteo's edge answers 403 to curl's own User-Agent on a request
    // carrying timezone=auto; the clone carries the same identifying UA as the
    // packaged panel until upstream sends one of its own.
    dailyForecastProc.command = ["curl", "-fsS", "--max-time", "5", "-A", "omarchy-weather/1.0", url]
    dailyForecastProc.running = true
  }

  // ---- Location editing. Clicking the location label swaps it for a search
  //      field; picking a geocoded suggestion persists name + coordinates to
  //      the module's shell.json entry. An empty commit returns to auto.
  // The search field lives in the panel's lazily built content.
  function locationInput() {
    return panel.loadedContent ? panel.loadedContent.locationField : null
  }

  function startEditingLocation() {
    editingLocation = true
    savingLocation = false
    savingLocationQueryStarted = false
    locationSuggestions = []
    suggestionIndex = 0
    Qt.callLater(function() {
      var locationField = root.locationInput()
      if (!locationField) return
      locationField.text = root.configuredLocation
      locationField.selectAll()
      locationField.forceActiveFocus()
    })
  }

  function cancelEditingLocation() {
    editingLocation = false
    savingLocation = false
    savingLocationQueryStarted = false
    locationSuggestions = []
    geocodeDebounce.stop()
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  function commitLocation() {
    var locationField = root.locationInput()
    if (!locationField) return
    var location = Model.locationCommit(locationField.text, locationSuggestions, suggestionIndex)
    if (location.name === "") {
      clearLocation()
      return
    }
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = {
      name: location.name,
      latitude: location.latitude,
      longitude: location.longitude
    }
    persistLocation(location.name, location.latitude, location.longitude)
  }

  function clearLocation() {
    persistLocation("", null, null)
    cancelEditingLocation()
  }

  function pickSuggestion(suggestion) {
    if (!suggestion) return
    savingLocation = true
    savingLocationQueryStarted = false
    configuredLocationState = {
      name: suggestion.name,
      latitude: suggestion.latitude,
      longitude: suggestion.longitude
    }
    persistLocation(suggestion.name, suggestion.latitude, suggestion.longitude)
  }

  function finishSavingLocation() {
    if (savingLocation && savingLocationQueryStarted) cancelEditingLocation()
  }

  function persistLocation(name, latitude, longitude) {
    if (name && latitude !== null && longitude !== null)
      locationSaveProc.command = ["omarchy-weather-location", "--set", name, latitude + "," + longitude]
    else if (name)
      locationSaveProc.command = ["omarchy-weather-location", "--set", name]
    else
      locationSaveProc.command = ["omarchy-weather-location", "--clear"]
    locationSaveProc.running = true
  }

  // Debounced geocoding. Only one curl runs at a time; if the query moved on
  // while a fetch was in flight, the latest query is fetched right after.
  function requestGeocode() {
    var locationField = root.locationInput()
    var query = locationField ? locationField.text.trim() : ""
    if (query.length < 2) {
      locationSuggestions = []
      return
    }
    geocodePendingQuery = query
    if (!geocodeProc.running) startGeocode()
  }

  function startGeocode() {
    geocodeActiveQuery = geocodePendingQuery
    // Same client identification as the forecast fetch above.
    geocodeProc.command = ["curl", "-fsS", "--max-time", "5", "-A", "omarchy-weather/1.0",
      "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(geocodeActiveQuery) + "&count=5&language=en&format=json"]
    geocodeProc.running = true
  }

  function buildForecastDays() {
    return Model.buildForecastDays(report, dailyForecastReport, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  }

  function openMeteoForecastDays() {
    return Model.openMeteoForecastDays(dailyForecastReport, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  }

  function wttrNextForecastDays() {
    return Model.wttrNextForecastDays(report, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  }

  function isFutureForecastDate(dateString) {
    return Model.isFutureForecastDate(dateString, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  }

  function roundedTemp(value) {
    return Model.roundedTemp(value)
  }

  function celsiusToFahrenheit(value) {
    return Model.celsiusToFahrenheit(value)
  }

  function formatTemp(value) {
    return Model.formatTemp(value, useImperial, Commons.I18n.formatNumber)
  }

  function dayName(dateString) {
    var locale = Qt.locale(Commons.I18n.formatLocale)
    return Model.dayName(dateString, function(date) { return locale.standaloneDayName(date.getDay(), Locale.LongFormat) })
  }

  // Bare degree value (no unit letter), used in the forecast row.
  function bareTempForDay(day, kind) {
    return Model.bareTempForDay(day, kind, useImperial, Commons.I18n.formatNumber)
  }

  // Representative icon for a forecast day: the hourly entry nearest noon.
  function dayIcon(day) {
    return Model.dayIcon(day)
  }

  function iconForOpenMeteoCode(code) {
    return Model.iconForOpenMeteoCode(code)
  }

  // Mirrors omarchy-weather-icon's wttr.in code → nerd-font glyph mapping.
  function iconForCode(code, night) {
    return Model.iconForCode(code, night)
  }

  // ==========================================================================
  // Detail layer. Whatever the views below show comes from here, so the bar
  // pill and the full-screen board stay in step.
  // ==========================================================================

  // A report field as a number, or null when it is missing or blank.
  function valueOf(value) {
    if (value === undefined || value === null || value === "") return null
    var n = Number(value)
    return isFinite(n) ? n : null
  }

  // Open-Meteo's current block; falls back to wttr's own condition row when
  // only wttr answered, so the details grid is never empty on the wttr path.
  readonly property var wx: {
    var detail = Wx.currentDetail(root.dailyForecastReport)
    if (detail) return detail
    var w = root.current
    if (!w) return null
    var windKmph = root.valueOf(w.windspeedKmph)
    var gustKmph = root.valueOf(w.gustsKmph)
    var pressure = root.valueOf(w.pressure)
    var visibility = root.valueOf(w.visibility)
    return {
      observedAt: "",
      tempC: root.valueOf(w.temp_C),
      tempF: root.valueOf(w.temp_F),
      feelsC: root.valueOf(w.FeelsLikeC),
      feelsF: root.valueOf(w.FeelsLikeF),
      humidity: root.valueOf(w.humidity),
      windKmph: windKmph,
      windMph: root.valueOf(w.windspeedMiles),
      gustKmph: gustKmph,
      gustMph: gustKmph === null ? null : gustKmph * 0.621371,
      windDeg: root.valueOf(w.winddirDegree),
      code: root.valueOf(w.weatherCode),
      isDay: true,
      pressure: pressure,
      pressureInHg: pressure === null ? null : pressure * 0.02953,
      precipMm: root.valueOf(w.precipMM),
      visibilityKm: visibility,
      uvIndex: root.valueOf(w.uvIndex)
    }
  }

  // The hour the latest report was taken in the reported location's own time,
  // which is what the hourly series is indexed by.
  readonly property string nowIsoHour: {
    var at = root.dailyForecastReport && root.dailyForecastReport.current ? String(root.dailyForecastReport.current.time || "") : ""
    if (at !== "") return at.slice(0, 13)
    return root.wx && root.wx.observedAt ? String(root.wx.observedAt).slice(0, 13) : ""
  }

  readonly property var hourRows: Wx.hourly(root.dailyForecastReport, root.nowIsoHour, 24)

  readonly property var hourTemps: {
    var out = []
    for (var i = 0; i < root.hourRows.length; i++)
      out.push(root.useImperial ? root.hourRows[i].tempF : root.hourRows[i].tempC)
    return out
  }

  readonly property var hourRain: {
    var out = []
    for (var i = 0; i < root.hourRows.length; i++)
      out.push(root.hourRows[i].precipProb)
    return out
  }

  // One block character per hour, and one shade character per hour's chance
  // of rain -- the two rows under the 24-hour rule.
  readonly property var tempCells: Wx.sparkCells(root.hourTemps)
  readonly property var rainCells: Wx.shadePercentCells(root.hourRain)

  // Eight hour marks, evenly stepped through the same cells as the sparkline.
  readonly property var tickCells: {
    var out = []
    for (var i = 0; i < root.hourRows.length; i += 3) {
      var row = root.hourRows[i]
      out.push({ index: i, label: String(row.hour).slice(0, 2), isDay: row.isDay })
    }
    return out
  }

  // Seven days from today. With no open-meteo answer, whatever the wttr path
  // resolved still fills the table rather than leaving it blank.
  readonly property var weekDays: {
    var rows = Wx.days(root.dailyForecastReport, 7)
    if (rows.length) return rows
    var fallback = root.buildForecastDays()
    var out = []
    for (var i = 0; i < fallback.length; i++) {
      var d = fallback[i]
      out.push({
        date: d.date, code: null,
        maxC: root.valueOf(d.maxtempC), minC: root.valueOf(d.mintempC),
        maxF: root.valueOf(d.maxtempF), minF: root.valueOf(d.mintempF),
        sunrise: "", sunset: "", uvMax: null, precipMm: null, precipProb: null,
        windMaxKmph: null, windDeg: null
      })
    }
    return out
  }

  readonly property var todayRow: root.weekDays.length > 0 ? root.weekDays[0] : null

  // The span the day range-bars are drawn inside, in whatever unit is shown.
  readonly property var weekExtremes: {
    var lo = null
    var hi = null
    for (var i = 0; i < root.weekDays.length; i++) {
      var row = root.weekDays[i]
      var min = root.valueOf(root.useImperial ? row.minF : row.minC)
      var max = root.valueOf(root.useImperial ? row.maxF : row.maxC)
      if (min !== null) lo = lo === null ? min : Math.min(lo, min)
      if (max !== null) hi = hi === null ? max : Math.max(hi, max)
    }
    return { lo: lo, hi: hi }
  }

  // Temperature in the displayed unit.
  function tempDisplay(celsius, fahrenheit) {
    var value = root.useImperial ? fahrenheit : celsius
    return root.valueOf(value)
  }

  function tempText(celsius, fahrenheit) {
    var value = root.tempDisplay(celsius, fahrenheit)
    return value === null ? "" : Math.round(value) + "°"
  }

  function speedText(kmph, mph) {
    var value = root.valueOf(root.useImperial ? mph : kmph)
    if (value === null) return ""
    return Math.round(value) + (root.useImperial ? " mph" : " km/h")
  }

  function distanceText(km) {
    var value = root.valueOf(km)
    if (value === null) return ""
    return root.useImperial ? Math.round(value * 0.621371) + " mi" : Math.round(value) + " km"
  }

  // Cold-to-warm ramp across the week's own span: theme accent at the cold
  // end, theme urgent at the warm end, so it belongs to whatever theme is on.
  function tempColor(value) {
    var lo = root.weekExtremes.lo
    var hi = root.weekExtremes.hi
    var v = root.valueOf(value)
    if (v === null || lo === null || hi === null || hi - lo < 0.001) return Commons.Color.accent
    var k = Math.max(0, Math.min(1, (v - lo) / (hi - lo)))
    var cold = Commons.Color.accent
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

  function dayOrdinal(dateString) {
    return String(dateString || "").slice(8, 10)
  }

  // Hero strip: six read-outs across the width.
  readonly property var statCells: {
    var w = root.wx
    if (!w) return []
    var today = root.todayRow
    return [
      { label: "FEELS", value: root.tempText(w.feelsC, w.feelsF) },
      { label: "HIGH", value: today ? root.tempText(today.maxC, today.maxF) : "" },
      { label: "LOW", value: today ? root.tempText(today.minC, today.minF) : "" },
      { label: "HUMID", value: w.humidity === null ? "" : Math.round(w.humidity) + "%" },
      { label: "WIND", value: root.speedText(w.windKmph, w.windMph) },
      { label: "GUST", value: root.speedText(w.gustKmph, w.gustMph) }
    ]
  }

  // Details grid: four columns, three rows -- the numbers a glance at the
  // hero leaves out.
  readonly property var detailCells: {
    var w = root.wx
    var today = root.todayRow
    var uv = today ? root.valueOf(today.uvMax) : null
    return [
      { label: "SUNRISE", value: today ? Wx.clockLabel(today.sunrise) : "" },
      { label: "SUNSET", value: today ? Wx.clockLabel(today.sunset) : "" },
      { label: "DAYLIGHT", value: today ? Wx.durationLabel(Wx.daylightMinutes(today.sunrise, today.sunset)) : "" },
      { label: "UV INDEX", value: uv === null ? "" : (Math.round(uv * 10) / 10) + " " + Wx.uvRiskLabel(uv).toUpperCase() },
      { label: "RAIN TODAY", value: (today && today.precipMm !== null) ? (Math.round(today.precipMm * 10) / 10) + " mm" : "" },
      { label: "RAIN CHANCE", value: (today && today.precipProb !== null) ? Math.round(today.precipProb) + "%" : "" },
      { label: "PRESSURE", value: w && w.pressure !== null ? Math.round(root.useImperial ? w.pressureInHg : w.pressure) + (root.useImperial ? " inHg" : " hPa") : "" },
      { label: "VISIBILITY", value: w ? root.distanceText(w.visibilityKm) : "" },
      { label: "WIND DIR", value: w && w.windDeg !== null ? Wx.windDirectionLabel(w.windDeg) + " · " + Math.round(w.windDeg) + "°" : "" },
      { label: "PEAK WIND", value: (today && today.windMaxKmph !== null) ? root.distanceSpeed(today.windMaxKmph) : "" },
      { label: "FEELS MAX", value: root.tempText(today ? today.feelsMaxC : null, today ? today.feelsMaxF : null) },
      { label: "FEELS MIN", value: root.tempText(today ? today.feelsMinC : null, today ? today.feelsMinF : null) }
    ]
  }

  function distanceSpeed(kmph) {
    var value = root.valueOf(kmph)
    if (value === null) return ""
    return root.useImperial ? Math.round(value * 0.621371) + " mph" : Math.round(value) + " km/h"
  }

  // The UV marker's position on the 0..11 scale painted under the grid.
  readonly property real uvToday: {
    var today = root.todayRow
    var uv = today ? root.valueOf(today.uvMax) : null
    return uv === null ? 0 : uv
  }

  readonly property string conditionText: {
    var w = root.wx
    if (w && w.code !== null) return Wx.codeLabel(w.code)
    var condition = root.report && root.report.current_condition && root.report.current_condition[0]
      ? root.report.current_condition[0].weatherDesc : null
    if (condition && condition[0] && condition[0].value) return String(condition[0].value)
    return ""
  }

  readonly property string observedText: {
    var at = root.wx && root.wx.observedAt ? Wx.clockLabel(root.wx.observedAt) : ""
    if (at !== "") return at
    return Qt.formatTime(new Date(), "HH:mm")
  }

  readonly property string headerDate: {
    var w = root.wx && root.wx.observedAt ? Wx.dateLabel(root.wx.observedAt) : Qt.formatDate(new Date(), "yyyy-MM-dd")
    var d = new Date(String(w) + "T12:00:00")
    if (isNaN(d.getTime())) return ""
    var locale = Qt.locale(Commons.I18n.formatLocale)
    var day = String(locale.standaloneDayName(d.getDay(), Locale.ShortFormat)).toUpperCase()
    var month = String(locale.standaloneMonthName(d.getMonth(), Locale.ShortFormat)).toUpperCase()
    return day + " " + Wx.dateLabel(w).slice(8, 10) + " " + month
  }

  readonly property string coordinateText: {
    var lat = root.valueOf(root.locationState.latitude)
    var lon = root.valueOf(root.locationState.longitude)
    if (lat === null || lon === null) return ""
    var latText = Math.abs(lat).toFixed(2) + "°" + (lat >= 0 ? "N" : "S")
    var lonText = Math.abs(lon).toFixed(2) + "°" + (lon >= 0 ? "E" : "W")
    return latText + " " + lonText
  }

  readonly property bool hasDetail: !!root.wx
  readonly property string sourceText: "OPEN-METEO · REFRESH " + root.refreshMinutes + "M"

  Process {
    id: forecastProc
    command: ["curl", "-fsS", "--max-time", "10", "https://wttr.in/" + root.locationQuery + "?format=j1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleForecastRetry()
          return
        }
        try {
          var parsed = JSON.parse(raw)
          root.report = parsed
          root.label = Model.barIconAfterResponse("wttr", parsed.current_condition && parsed.current_condition[0], root.label)
          root.forecastRetries = 0
          if (Model.weatherResponseCompletesSave(root.hasConfiguredCoordinates, "wttr"))
            root.finishSavingLocation()
          // Known coordinates already drove the fast open-meteo fetch from
          // refresh(); only a name, or wttr's own IP lookup, needs the area
          // wttr reported.
          if (!root.hasCoordinates)
            root.refreshDailyForecast(parsed)
        } catch (e) {
          // Keep last-good report visible, but try again shortly.
          root.scheduleForecastRetry()
        }
      }
    }
  }

  // wttr.in can be slow or flaky, especially for a location it hasn't
  // cached yet. Retry a few times before leaving it to the refresh timer.
  function scheduleForecastRetry() {
    if (forecastRetries >= 3) return
    forecastRetries++
    forecastRetryTimer.restart()
  }

  Timer {
    id: forecastRetryTimer
    interval: 2500
    onTriggered: if (!forecastProc.running) forecastProc.running = true
  }

  // With configured coordinates this fetch is the only thing that updates the
  // bar icon, so a dropped response (e.g. waking before the network is back)
  // must retry rather than wait out the refresh timer with a stale icon.
  function scheduleDailyForecastRetry() {
    if (dailyForecastRetries >= 3) return
    dailyForecastRetries++
    dailyForecastRetryTimer.restart()
  }

  Timer {
    id: dailyForecastRetryTimer
    interval: 2500
    onTriggered: root.refreshDailyForecast(null)
  }

  Process {
    id: dailyForecastProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleDailyForecastRetry()
          return
        }
        try {
          var parsed = JSON.parse(raw)
          var parsedCurrent = Model.openMeteoCurrentCondition(parsed)
          root.dailyForecastReport = parsed
          root.label = Model.barIconAfterResponse("open-meteo", parsedCurrent, root.label)
          root.dailyForecastRetries = 0
          if (Model.weatherResponseCompletesSave(root.hasConfiguredCoordinates, "open-meteo"))
            root.finishSavingLocation()
        } catch (e) {
          // Keep last-good daily forecast visible, but try again shortly.
          root.scheduleDailyForecastRetry()
        }
      }
    }
  }

  Process {
    id: geocodeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.locationSuggestions = root.editingLocation ? Model.parseGeocodingResults(text) : []
        root.suggestionIndex = 0
        if (root.geocodePendingQuery !== root.geocodeActiveQuery) Qt.callLater(root.startGeocode)
      }
    }
  }

  Timer {
    id: geocodeDebounce
    interval: 300
    onTriggered: root.requestGeocode()
  }

  Process {
    id: locationSaveProc
    onExited: function(exitCode) {
      if (exitCode !== 0 || !root.savingLocation) return

      // FileView handles changed locations. Explicitly refresh here too so
      // saving the already-active location cannot strand the spinner.
      locationFile.reload()
      if (!root.savingLocationQueryStarted) {
        root.savingLocationQueryStarted = true
        root.forecastRetries = 0
        root.dailyForecastRetries = 0
        forecastProc.running = false
        dailyForecastProc.running = false
        Qt.callLater(root.refresh)
      }
    }
  }

  // Omarchy's own lookup: city and coordinates from Cloudflare's view of
  // this network, in weather.json's shape.
  Process {
    id: locationProc
    command: ["curl", "-fsS", "--max-time", "4", "https://geo.omarchy.org/"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.detectingLocation = false
        var detected = Model.parseLocationFile(text)
        var query = Model.wttrLocationQuery(detected.name, detected.latitude, detected.longitude)
        // A new place changes locationQuery, which refreshes. An unchanged
        // one was already fetched; a failure keeps the last place, or with
        // none falls back to wttr.in's own lookup.
        if (query !== "" && query !== root.locationQuery)
          root.detectedLocationState = detected
        else if (root.locationQuery === "")
          root.refresh()
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (root.autoLocation) root.detectLocation()
      root.refresh()
    }
  }

  ShellIpc {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function edit(): void { root.openFromHotkey(); root.startEditingLocation() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // Anchor under the widget rather than the middle of the bar, so the
    // popup follows wherever the widget is placed.
    centerOnBar: false
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias locationField: locationField
      implicitHeight: wxColumn.implicitHeight
      anchors.fill: parent
      blocked: root.editingLocation
      onReturnRequested: root.startEditingLocation()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: wxScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: wxColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: wxColumn
          width: wxScroll.width
          spacing: Style.space(10)

          // ---- Console header: location (tap to edit), coordinates, date.
          Item {
            width: parent.width
            implicitHeight: headerRow.implicitHeight + Style.space(14) * 2

            Row {
              id: headerRow
              visible: !root.editingLocation
              anchors.left: parent.left
              anchors.leftMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              TapHandler { onTapped: root.startEditingLocation() }
              HoverHandler { cursorShape: Qt.PointingHandCursor }

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "\u258C"
                color: Commons.Color.accent
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.heading
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: (root.reportLocation || "").toUpperCase()
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                font.letterSpacing: 2
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                visible: text !== ""
                text: root.coordinateText
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              visible: root.editingLocation
              anchors.left: parent.left
              anchors.leftMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              TextField {
                id: locationField
                width: Style.space(220)
                enabled: !root.savingLocation
                placeholderText: Commons.I18n.t("weather.searchCity")
                foreground: root.bar.foreground
                font.family: root.bar.fontFamily

                onTextChanged: if (root.editingLocation && !root.savingLocation) geocodeDebounce.restart()

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.cancelEditingLocation()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Down) {
                    if (root.suggestionIndex < root.locationSuggestions.length - 1) root.suggestionIndex++
                    event.accepted = true
                  } else if (event.key === Qt.Key_Up) {
                    if (root.suggestionIndex > 0) root.suggestionIndex--
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.commitLocation()
                    event.accepted = true
                  }
                }
              }

              // Clear back to IP auto-detect. While a committed location is
              // loading, this same compact affordance becomes a spinner.
              Item {
                width: Style.space(20)
                height: Style.space(20)
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                  anchors.centerIn: parent
                  width: Style.space(18)
                  height: Style.space(18)
                  radius: Math.min(4, Style.cornerRadius)
                  color: !root.savingLocation && clearLocationArea.containsMouse ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent) : "transparent"
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: root.savingLocation ? "\u25CC" : "\u2715"
                  font.family: root.bar.fontFamily
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.pixelSize: Style.font.bodySmall

                  RotationAnimator on rotation {
                    running: root.savingLocation && !Style.reduceMotion
                    from: 0; to: 360
                    duration: Style.duration(800)
                    loops: Animation.Infinite
                  }
                }

                MouseArea {
                  id: clearLocationArea
                  anchors.fill: parent
                  enabled: !root.savingLocation
                  hoverEnabled: true
                  cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.clearLocation()
                }
              }
            }

            // Right-hand block: the date, and when the reading was taken.
            Column {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(96)
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: root.headerDate
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: root.observedText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                font.letterSpacing: 1
              }
            }
          }

          // ---- The scanline ribbon: accent fading out to the right.
          Rectangle {
            width: parent.width
            height: Math.max(1, Style.space(2))
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0.0; color: Commons.Color.accent }
              GradientStop { position: 0.45; color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.35) }
              GradientStop { position: 1.0; color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.0) }
            }
          }

          // ---- Hero: condition glyph, oversized reading, condition text,
          //      and today's range at the right edge.
          Item {
            width: parent.width
            implicitHeight: Math.max(heroGlyph.implicitHeight, heroBody.implicitHeight, heroRange.implicitHeight) + Style.space(10)

            Text {
              id: heroGlyph
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              text: root.label || "\u2014"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              // Decorative condition glyph, deliberately off the type scale.
              font.pixelSize: Math.round(Style.font.displayLarge * 1.8)
            }

            Item {
              id: heroBody
              anchors.left: heroGlyph.right
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              LayoutMirroring.enabled: false
              width: Math.max(heroTemp.width, heroCondition.implicitWidth)
              implicitHeight: heroTemp.height + heroCondition.implicitHeight + Style.space(4)

              Item {
                id: heroTemp
                width: bigTemp.width + Style.space(6) + bigUnit.width
                height: bigTemp.implicitHeight

                Text {
                  id: bigTemp
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.top: parent.top
                  text: root.reportTempNum || "\u2014"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Math.round(Style.font.displayLarge * 1.5)
                  font.bold: true
                }
                Text {
                  id: bigUnit
                  textFormat: Text.PlainText
                  anchors.left: bigTemp.right
                  anchors.leftMargin: Style.space(4)
                  anchors.top: parent.top
                  anchors.topMargin: Style.space(8)
                  text: root.current ? root.tempUnit : ""
                  color: root.tempColor(root.tempDisplay(root.wx ? root.wx.tempC : null, root.wx ? root.wx.tempF : null))
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
              }

              Text {
                id: heroCondition
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.top: heroTemp.bottom
                anchors.topMargin: Style.space(4)
                text: root.conditionText.toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.25)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 3
              }
            }

            Column {
              id: heroRange
              anchors.right: parent.right
              anchors.rightMargin: Style.space(14)
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(70)
              spacing: Style.space(1)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: "TODAY"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 2
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignRight
                visible: !!root.todayRow
                text: root.todayRow ? ("\u2191" + root.tempText(root.todayRow.maxC, root.todayRow.maxF)) : ""
                color: root.tempColor(root.todayRow ? root.tempDisplay(root.todayRow.maxC, root.todayRow.maxF) : null)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignRight
                visible: !!root.todayRow
                text: root.todayRow ? ("\u2193" + root.tempText(root.todayRow.minC, root.todayRow.minF)) : ""
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }
          }

          // ---- Six read-outs in a hairline frame.
          Item {
            id: statsBlock
            width: parent.width
            implicitHeight: statsFrame.height

            Rectangle {
              id: statsFrame
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              height: statsRow.implicitHeight + Style.space(9) * 2
              color: "transparent"
              border.width: 1
              border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.22)
              radius: Style.cornerRadius

              Row {
                id: statsRow
                anchors.left: parent.left
                anchors.leftMargin: Style.space(9)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Repeater {
                  model: root.statCells

                  Item {
                    id: statCell
                    required property var modelData
                    width: Math.max(Style.space(50), (statsFrame.width - Style.space(18)) / Math.max(1, root.statCells.length))
                    height: statColumn.implicitHeight

                    Column {
                      id: statColumn
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(4)
                      spacing: Style.space(2)

                      Text {
                        textFormat: Text.PlainText
                        text: statCell.modelData.label
                        color: Qt.darker(root.bar.foreground, 1.5)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 2
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: statCell.modelData.value
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                      }
                    }
                  }
                }
              }
            }
          }

          // ---- Geocoding suggestions while the location is being edited.
          Column {
            visible: root.editingLocation && !root.savingLocation && root.locationSuggestions.length > 0
            width: parent.width
            spacing: 0

            Repeater {
              model: root.locationSuggestions

              Rectangle {
                id: suggestionRowItem
                required property var modelData
                required property int index
                width: parent.width
                height: suggestionRow.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: index === root.suggestionIndex ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent) : "transparent"

                Row {
                  id: suggestionRow
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name
                    color: index === root.suggestionIndex ? Style.hoverStateColor(root.bar.foreground, Commons.Color.accent) : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: text !== ""
                    text: modelData.description
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: root.suggestionIndex = index
                  onClicked: root.pickSuggestion(modelData)
                }
              }
            }
          }

          Text {
            visible: !root.hasDetail
            text: Commons.I18n.t("weather.fetching")
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.leftMargin: Style.space(14)
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- NEXT 24 HOURS: one block character per hour, with the chance
          //      of rain shaded underneath and eight hour marks below.
          SectionRule { title: "NEXT 24 HOURS"; visible: root.tempCells.length > 0 }

          Item {
            id: sparkBlock
            visible: root.tempCells.length > 0
            width: parent.width
            implicitHeight: sparkColumn.implicitHeight + Style.space(4)

            Column {
              id: sparkColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              spacing: 0

              // The temperature ribbon.
              Item {
                id: tempSpark
                width: parent.width
                readonly property real cellWidth: width / Math.max(1, root.tempCells.length)
                // Sized so one block character fills its cell exactly: the
                // ramp then reads as a solid chart, not a dotted line.
                readonly property real fontSize: Math.max(Style.font.body, Math.min(Style.font.displayLarge * 1.5, cellWidth / Math.max(0.2, root.blockAdvanceRatio)))
                height: tempSparkMeasure.implicitHeight

                Text {
                  id: tempSparkMeasure
                  visible: false
                  text: "\u2588"
                  font.family: root.bar.fontFamily
                  font.pixelSize: tempSpark.fontSize
                }

                Repeater {
                  model: root.tempCells.length

                  Text {
                    required property int index
                    x: Math.round(index * tempSpark.cellWidth)
                    width: Math.ceil(tempSpark.cellWidth)
                    height: tempSpark.height
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignBottom
                    text: root.tempCells[index]
                    color: root.tempColor(root.hourTemps[index])
                    font.family: root.bar.fontFamily
                    font.pixelSize: tempSpark.fontSize
                  }
                }
              }

              // The chance-of-rain shade row, same columns.
              Item {
                id: rainSpark
                width: parent.width
                visible: root.rainCells.length > 0
                readonly property real cellWidth: width / Math.max(1, root.rainCells.length)
                readonly property real fontSize: Math.max(Style.font.caption, Math.min(Style.font.display, cellWidth / Math.max(0.2, root.blockAdvanceRatio)))
                height: rainSparkMeasure.implicitHeight

                Text {
                  id: rainSparkMeasure
                  visible: false
                  text: "\u2588"
                  font.family: root.bar.fontFamily
                  font.pixelSize: rainSpark.fontSize
                }

                Repeater {
                  model: root.rainCells.length

                  Text {
                    required property int index
                    x: Math.round(index * rainSpark.cellWidth)
                    width: Math.ceil(rainSpark.cellWidth)
                    height: rainSpark.height
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignBottom
                    text: root.rainCells[index]
                    color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.85)
                    font.family: root.bar.fontFamily
                    font.pixelSize: rainSpark.fontSize
                  }
                }
              }

              // Hour marks, on the same cell grid.
              Item {
                id: tickRow
                width: parent.width
                height: tickMeasure.implicitHeight + Style.space(3)

                Text {
                  id: tickMeasure
                  visible: false
                  text: "00"
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: root.tickCells

                  Text {
                    required property var modelData
                    x: Math.round(modelData.index * tempSpark.cellWidth)
                    width: Math.ceil(tempSpark.cellWidth * 2)
                    text: modelData.label
                    color: Qt.darker(root.bar.foreground, modelData.isDay ? 1.35 : 1.7)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Text {
                  anchors.right: parent.right
                  text: "HR"
                  color: Qt.darker(root.bar.foreground, 1.9)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ---- SEVEN DAYS: one row per day, its range drawn inside the
          //      week's own cold-to-warm span.
          SectionRule { title: "7 DAY OUTLOOK"; visible: root.weekDays.length > 0 }

          Repeater {
            model: root.weekDays

            Item {
              id: dayRow
              required property var modelData
              required property int index
              width: wxColumn.width
              height: Style.space(30)

              readonly property real gutter: Style.space(14)
              readonly property var minValue: root.tempDisplay(dayRow.modelData.minC, dayRow.modelData.minF)
              readonly property var maxValue: root.tempDisplay(dayRow.modelData.maxC, dayRow.modelData.maxF)

              Text {
                id: dayLabel
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.leftMargin: dayRow.gutter
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(66)
                text: index === 0 ? "TODAY" : (root.dayShort(dayRow.modelData.date).slice(0, 3) + " " + root.dayOrdinal(dayRow.modelData.date))
                color: index === 0 ? Commons.Color.accent : Qt.darker(root.bar.foreground, 1.35)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }

              Text {
                id: dayGlyph
                textFormat: Text.PlainText
                anchors.left: dayLabel.right
                anchors.leftMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(30)
                horizontalAlignment: Text.AlignLeft
                text: dayRow.modelData.code !== null && dayRow.modelData.code !== undefined
                  ? Model.iconForOpenMeteoCode(dayRow.modelData.code)
                  : root.dayIcon(dayRow.modelData)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }

              Text {
                id: rainText
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.rightMargin: dayRow.gutter
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(46)
                horizontalAlignment: Text.AlignRight
                text: dayRow.modelData.precipProb === null || dayRow.modelData.precipProb === undefined
                  ? "" : Math.round(dayRow.modelData.precipProb) + "%"
                color: Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.8)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: lowText
                textFormat: Text.PlainText
                anchors.right: rainText.left
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
                horizontalAlignment: Text.AlignRight
                text: root.tempText(dayRow.modelData.minC, dayRow.modelData.minF)
                color: Qt.darker(root.bar.foreground, 1.35)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }

              Text {
                id: highText
                textFormat: Text.PlainText
                anchors.right: lowText.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
                horizontalAlignment: Text.AlignRight
                text: root.tempText(dayRow.modelData.maxC, dayRow.modelData.maxF)
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              // The trough is the week's span; the fill is this day's.
              Rectangle {
                id: trough
                anchors.left: dayGlyph.right
                anchors.leftMargin: Style.space(6)
                anchors.right: highText.left
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(7)
                color: "transparent"
                border.width: 1
                border.color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.18)
                radius: 0

                readonly property real inner: Math.max(0, width - 2)
                readonly property real startFraction: Wx.spanFraction(dayRow.minValue, root.weekExtremes.lo, root.weekExtremes.hi)
                readonly property real endFraction: Wx.spanFraction(dayRow.maxValue, root.weekExtremes.lo, root.weekExtremes.hi)

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  x: 1 + trough.startFraction * trough.inner
                  width: Math.max(2, (trough.endFraction - trough.startFraction) * trough.inner)
                  height: Math.max(2, trough.height - 2)
                  radius: 0
                  color: dayRow.minValue === null || dayRow.maxValue === null
                    ? Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.25)
                    : root.tempColor((dayRow.minValue + dayRow.maxValue) / 2)
                  opacity: 0.9
                }

                // Today's reading, marked on its own bar.
                Rectangle {
                  visible: index === 0
                  anchors.verticalCenter: parent.verticalCenter
                  x: 1 + Wx.spanFraction(root.tempDisplay(root.wx ? root.wx.tempC : null, root.wx ? root.wx.tempF : null), root.weekExtremes.lo, root.weekExtremes.hi) * trough.inner - width / 2
                  width: Math.max(1, Style.spacing.hairline)
                  height: trough.height + Style.space(5)
                  color: root.bar.foreground
                }
              }
            }
          }

          // ---- DETAILS: the UV scale, then two rows of four read-outs.
          SectionRule { title: "DETAILS"; visible: root.hasDetail }

          Item {
            id: uvBlock
            visible: root.hasDetail
            width: parent.width
            implicitHeight: uvRow.implicitHeight

            Item {
              id: uvRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              implicitHeight: uvLabel.implicitHeight

              Text {
                id: uvLabel
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "UV"
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 2
              }

              Text {
                id: uvEndLabel
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "11+"
                color: Qt.darker(root.bar.foreground, 1.9)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              // 0..11 scale with marks at 3, 6, 8, 11 and today's peak on it.
              Rectangle {
                id: uvTrack
                anchors.left: uvLabel.right
                anchors.leftMargin: Style.space(10)
                anchors.right: uvEndLabel.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                height: Math.max(1, Style.spacing.hairline)
                color: root.bar.foreground
                opacity: 0.3
              }

              Repeater {
                model: [3, 6, 8]

                Rectangle {
                  required property var modelData
                  anchors.verticalCenter: uvTrack.verticalCenter
                  x: uvTrack.x + uvTrack.width * (modelData / 11) - width / 2
                  width: Math.max(1, Style.spacing.hairline)
                  height: Style.space(6)
                  color: root.bar.foreground
                  opacity: 0.45
                }
              }

              Rectangle {
                id: uvMarker
                anchors.verticalCenter: uvTrack.verticalCenter
                x: uvTrack.x + uvTrack.width * Math.max(0, Math.min(1, root.uvToday / 11)) - width / 2
                width: Style.space(4)
                height: Style.space(10)
                color: Commons.Color.accent
              }
            }
          }

          Item {
            id: detailsBlock
            visible: root.hasDetail
            width: parent.width
            implicitHeight: detailsGrid.implicitHeight

            Grid {
              id: detailsGrid
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              columns: 4
              rowSpacing: Style.space(9)
              columnSpacing: 0

              Repeater {
                model: root.detailCells

                Item {
                  id: detailCell
                  required property var modelData
                  width: detailsGrid.width / 4
                  height: detailColumn.implicitHeight

                  Column {
                    id: detailColumn
                    anchors.left: parent.left
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      text: detailCell.modelData.label
                      color: Qt.darker(root.bar.foreground, 1.5)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 2
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: detailCell.modelData.value
                      color: root.bar.foreground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                    }
                  }
                }
              }
            }
          }

          // ---- Console footer: where the numbers came from.
          Item {
            width: parent.width
            implicitHeight: footerText.implicitHeight + Style.space(10)

            Text {
              id: footerText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(14)
              anchors.top: parent.top
              anchors.topMargin: Style.space(4)
              text: root.sourceText
              color: Qt.darker(root.bar.foreground, 1.9)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }
          }
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // Retro console pieces. All of them read the active theme (Style.* and
  // Commons.Color.*), so nothing here is hard-coded to one palette.

  // One monospace advance width at 100px, so a block-character row can size
  // itself to fill its cells exactly whatever font the theme resolves to.
  TextMetrics {
    id: blockMetrics
    font.family: root.bar.fontFamily
    font.pixelSize: 100
    text: "\u2588"
  }

  readonly property real blockAdvanceRatio: {
    var ratio = blockMetrics.advanceWidth / 100
    return (isFinite(ratio) && ratio > 0.2 && ratio < 1.5) ? ratio : 0.6
  }

  // A full-width rule with a centred, letter-spaced label: "-— LABEL —-".
  component SectionRule: Item {
    id: rule
    property string title: ""
    width: parent.width
    implicitHeight: ruleTitle.implicitHeight + Style.space(4)

    Text {
      id: ruleTitle
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: rule.title
      color: Qt.darker(root.bar.foreground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 3
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: ruleTitle.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: ruleTitle.verticalCenter
      height: Math.max(1, Style.spacing.hairline)
      color: root.bar.foreground
      opacity: 0.18
    }

    Rectangle {
      anchors.left: ruleTitle.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.verticalCenter: ruleTitle.verticalCenter
      height: Math.max(1, Style.spacing.hairline)
      color: root.bar.foreground
      opacity: 0.18
    }
  }
}
