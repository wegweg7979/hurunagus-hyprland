// Detail layer for dan.weather. Sits beside the clone's frozen copy of
// upstream Model.js (which still owns location parsing, provider
// normalisation and the bar icon) and carries everything the retro-dense
// views read that upstream's model does not: one Open-Meteo request holding
// hourly + daily series, condition text, compass/UV labels, sunrise/sunset
// arithmetic and the block-character ramps used for sparklines and shade rows.
//
// Self-contained on purpose: the popup and the full-screen board each keep a
// verbatim copy, the same way an omarchy plugin clone is a frozen copy.

function encoded(value) {
  if (typeof encodeURIComponent === "function") return encodeURIComponent(String(value))
  return String(value)
}

// One request for everything both views show. Replaces the bare 4-day daily
// call: hourly series drive the sparklines, the current block supplies
// pressure/visibility/gusts, and the daily block carries sunrise/sunset/UV
// and precipitation alongside hi/lo.
function requestUrl(latitude, longitude, days) {
  var span = Math.max(1, Math.min(16, parseInt(days, 10) || 7))
  return "https://api.open-meteo.com/v1/forecast"
    + "?latitude=" + encoded(latitude)
    + "&longitude=" + encoded(longitude)
    + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,wind_direction_10m,wind_gusts_10m,weather_code,is_day,surface_pressure,precipitation,visibility"
    + "&hourly=temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,is_day,wind_speed_10m,wind_direction_10m,relative_humidity_2m,uv_index"
    + "&daily=weather_code,temperature_2m_max,temperature_2m_min,apparent_temperature_max,apparent_temperature_min,sunrise,sunset,uv_index_max,precipitation_sum,precipitation_probability_max,wind_speed_10m_max,wind_direction_10m_dominant"
    + "&forecast_days=" + span
    + "&timezone=auto"
}

// A series slot as a number, or null when the column is missing/blank. Call
// with one argument to read a scalar (the `current` object).
function seriesNumber(series, index) {
  // Explicit null checks, not a falsy test: a real reading of 0 (clear-sky UV,
  // 0.0 mm of rain) is a value, and `!0` would throw it away.
  if (series === undefined || series === null) return null
  var raw = index === undefined ? series : series[index]
  if (raw === undefined || raw === null || raw === "") return null
  var n = Number(raw)
  return isFinite(n) ? n : null
}

function toFahrenheitNumber(celsius) {
  return celsius === null || celsius === undefined ? null : (celsius * 9 / 5) + 32
}

function roundedOrNull(value) {
  var n = seriesNumber(value)
  return n === null ? null : Math.round(n)
}

function oneDecimalOrNull(value) {
  var n = seriesNumber(value)
  return n === null ? null : Math.round(n * 10) / 10
}

// Hourly rows from the hour containing `startIso` forward. `startIso` is an
// ISO minute ("2026-11-26T19:15"); only its date+hour part is compared, and a
// blank marker starts at the first row.
function hourly(report, startIso, count) {
  var source = report && report.hourly ? report.hourly : null
  if (!source || !source.time || !source.time.length) return []

  var marker = String(startIso || "").slice(0, 13)
  var start = 0
  if (marker !== "") {
    for (var i = 0; i < source.time.length; i++) {
      if (String(source.time[i]).slice(0, 13) >= marker) { start = i; break }
      start = i + 1
    }
  }

  var limit = Math.max(1, parseInt(count, 10) || 24)
  var out = []
  for (var j = start; j < source.time.length && out.length < limit; j++) {
    var tempC = seriesNumber(source.temperature_2m, j)
    var feelsC = seriesNumber(source.apparent_temperature, j)
    out.push({
      time: String(source.time[j]),
      date: String(source.time[j]).slice(0, 10),
      hour: String(source.time[j]).slice(11, 16),
      hourNumber: parseInt(String(source.time[j]).slice(11, 13), 10),
      tempC: tempC,
      tempF: toFahrenheitNumber(tempC),
      feelsC: feelsC,
      feelsF: toFahrenheitNumber(feelsC),
      code: seriesNumber(source.weather_code, j),
      isDay: seriesNumber(source.is_day, j) === 1,
      precipProb: seriesNumber(source.precipitation_probability, j),
      precipMm: seriesNumber(source.precipitation, j),
      windKmph: seriesNumber(source.wind_speed_10m, j),
      windDeg: seriesNumber(source.wind_direction_10m, j),
      humidity: seriesNumber(source.relative_humidity_2m, j),
      uv: seriesNumber(source.uv_index, j)
    })
  }
  return out
}

// Daily rows from today forward -- index 0 is today, unlike
// upstream's openMeteoForecastDays() which skips today and stops at three.
function days(report, count) {
  var source = report && report.daily ? report.daily : null
  if (!source || !source.time || !source.time.length) return []

  var limit = Math.max(1, parseInt(count, 10) || 7)
  var out = []
  for (var i = 0; i < source.time.length && out.length < limit; i++) {
    var maxC = seriesNumber(source.temperature_2m_max, i)
    var minC = seriesNumber(source.temperature_2m_min, i)
    var feelsMaxC = seriesNumber(source.apparent_temperature_max, i)
    var feelsMinC = seriesNumber(source.apparent_temperature_min, i)
    out.push({
      date: String(source.time[i]),
      code: seriesNumber(source.weather_code, i),
      maxC: maxC,
      minC: minC,
      maxF: toFahrenheitNumber(maxC),
      minF: toFahrenheitNumber(minC),
      feelsMaxC: feelsMaxC,
      feelsMaxF: toFahrenheitNumber(feelsMaxC),
      feelsMinC: feelsMinC,
      feelsMinF: toFahrenheitNumber(feelsMinC),
      sunrise: source.sunrise ? String(source.sunrise[i] || "") : "",
      sunset: source.sunset ? String(source.sunset[i] || "") : "",
      uvMax: seriesNumber(source.uv_index_max, i),
      precipMm: seriesNumber(source.precipitation_sum, i),
      precipProb: seriesNumber(source.precipitation_probability_max, i),
      windMaxKmph: seriesNumber(source.wind_speed_10m_max, i),
      windDeg: seriesNumber(source.wind_direction_10m_dominant, i)
    })
  }
  return out
}

// The `current` block as display fields, keyed the way wttr names them so the
// views can read either provider through one set of getters.
function currentDetail(report) {
  var current = report && report.current ? report.current : null
  if (!current || seriesNumber(current.temperature_2m) === null) return null
  var tempC = seriesNumber(current.temperature_2m)
  var feelsC = seriesNumber(current.apparent_temperature)
  var windKmph = seriesNumber(current.wind_speed_10m)
  var gustKmph = seriesNumber(current.wind_gusts_10m)
  var humidity = seriesNumber(current.relative_humidity_2m)
  var pressure = seriesNumber(current.surface_pressure)
  var visibilityM = seriesNumber(current.visibility)
  return {
    observedAt: String(current.time || ""),
    tempC: tempC,
    tempF: toFahrenheitNumber(tempC),
    feelsC: feelsC,
    feelsF: toFahrenheitNumber(feelsC),
    humidity: roundedOrNull(humidity),
    windKmph: windKmph,
    windMph: windKmph === null ? null : windKmph * 0.621371,
    gustKmph: gustKmph,
    gustMph: gustKmph === null ? null : gustKmph * 0.621371,
    windDeg: seriesNumber(current.wind_direction_10m),
    code: seriesNumber(current.weather_code),
    isDay: seriesNumber(current.is_day) === 1,
    pressure: oneDecimalOrNull(pressure),
    pressureInHg: pressure === null ? null : pressure * 0.02953,
    precipMm: seriesNumber(current.precipitation),
    visibilityKm: visibilityM === null ? null : Math.round(visibilityM / 100) / 10
  }
}

// WMO weather code (Open-Meteo) as words, for the retro read-out lines.
function codeLabel(code) {
  var c = seriesNumber(code)
  if (c === null) return ""
  if (c === 0) return "Clear sky"
  if (c === 1) return "Mainly clear"
  if (c === 2) return "Partly cloudy"
  if (c === 3) return "Overcast"
  if (c === 45 || c === 48) return "Fog"
  if (c === 51 || c === 53 || c === 55) return "Drizzle"
  if (c === 56 || c === 57) return "Freezing drizzle"
  if (c === 61 || c === 63 || c === 65) return "Rain"
  if (c === 66 || c === 67) return "Freezing rain"
  if (c === 71 || c === 73 || c === 75) return "Snow"
  if (c === 77) return "Snow grains"
  if (c === 80 || c === 81 || c === 82) return "Rain showers"
  if (c === 85 || c === 86) return "Snow showers"
  if (c === 95) return "Thunderstorm"
  if (c === 96 || c === 99) return "Thunderstorm, hail"
  return ""
}

// Nerd Font weather glyphs, mirroring omarchy-weather-icon's wttr.in code map
// (the same table upstream's Model.js carries), so this file alone is enough
// for a view. Written as escapes: the private-use codepoints survive every
// editor and copy that way, and a dropped glyph cannot hide as whitespace.
function iconForCode(code, night) {
  var c = parseInt(String(code === undefined || code === null ? "0" : code), 10)
  switch (c) {
    case 113: return night ? "\ue32b" : "\ue30d"
    case 116: return night ? "\ue32e" : "\ue302"
    case 119: case 122: return "\ue33d"
    case 143: case 248: case 260: return night ? "\ue346" : "\ue313"
    case 176: case 263: case 353: return night ? "\ue333" : "\ue308"
    case 179: case 227: case 230: case 323: case 326: case 368: return night ? "\ue327" : "\ue30a"
    case 182: case 185: case 281: case 284: case 311: case 314:
    case 317: case 320: case 350: case 362: case 365: case 374: case 377: return "\ue3ad"
    case 200: case 386: case 389: case 392: case 395: return "\ue31d"
    case 266: case 293: case 296: case 299: case 302: case 305: case 308: case 356: case 359: return "\ue318"
    case 329: case 332: case 335: case 338: case 371: return "\ue31a"
    default: return "\ue33d"
  }
}

// WMO code (Open-Meteo) through the same table.
function iconForOpenMeteoCode(code, night) {
  var c = parseInt(String(code === undefined || code === null ? "0" : code), 10)
  if (c === 0) return iconForCode(113, night)
  if (c === 1 || c === 2) return iconForCode(116, night)
  if (c === 3) return iconForCode(119, night)
  if (c === 45 || c === 48) return iconForCode(143, night)
  if (c === 51 || c === 53 || c === 55 || c === 56 || c === 57 || c === 61) return iconForCode(266, night)
  if (c === 63 || c === 65 || c === 66 || c === 67 || c === 80 || c === 81 || c === 82) return iconForCode(308, night)
  if (c === 71 || c === 73 || c === 75 || c === 77 || c === 85 || c === 86) return iconForCode(338, night)
  if (c === 95 || c === 96 || c === 99) return iconForCode(389, night)
  return iconForCode(119, night)
}

var compassPoints = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                     "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

// 16-point name for the direction the wind blows FROM, wttr's own convention.
function windDirectionLabel(degrees) {
  var d = seriesNumber(degrees)
  if (d === null) return ""
  var index = Math.round((((d % 360) + 360) % 360) / 22.5) % 16
  return compassPoints[index]
}

function uvRiskLabel(value) {
  var v = seriesNumber(value)
  if (v === null) return ""
  if (v < 3) return "Low"
  if (v < 6) return "Moderate"
  if (v < 8) return "High"
  if (v < 11) return "Very high"
  return "Extreme"
}

// Minutes past local midnight from an ISO minute string.
function minutesOfDay(iso) {
  var text = String(iso || "")
  var hh = parseInt(text.slice(11, 13), 10)
  var mm = parseInt(text.slice(14, 16), 10)
  if (!isFinite(hh) || !isFinite(mm)) return null
  return hh * 60 + mm
}

// Where the sun sits between sunrise and sunset: 0 at sunrise, 1 at sunset,
// null when the day's times are missing; below 0 / above 1 means night.
function sunProgress(nowIso, sunriseIso, sunsetIso) {
  var now = minutesOfDay(nowIso)
  var rise = minutesOfDay(sunriseIso)
  var set = minutesOfDay(sunsetIso)
  if (now === null || rise === null || set === null || set <= rise) return null
  return (now - rise) / (set - rise)
}

function daylightMinutes(sunriseIso, sunsetIso) {
  var rise = minutesOfDay(sunriseIso)
  var set = minutesOfDay(sunsetIso)
  if (rise === null || set === null || set <= rise) return null
  return set - rise
}

function durationLabel(minutes) {
  var n = seriesNumber(minutes)
  if (n === null) return ""
  var total = Math.max(0, Math.round(n))
  var h = Math.floor(total / 60)
  var m = total % 60
  return (h < 10 ? "0" : "") + h + "h " + (m < 10 ? "0" : "") + m + "m"
}

function clockLabel(iso) {
  return String(iso || "").slice(11, 16)
}

function dateLabel(iso) {
  return String(iso || "").slice(0, 10)
}

// Scale a list of numbers to 0..1 across its own min/max. Nulls stay null so
// gaps in a series are drawn as gaps rather than zeros.
function normalizeSeries(values) {
  var nums = []
  for (var i = 0; i < (values || []).length; i++) {
    var v = seriesNumber(values[i])
    if (v !== null) nums.push(v)
  }
  if (!nums.length) return []
  var lo = Math.min.apply(null, nums)
  var hi = Math.max.apply(null, nums)
  var span = hi - lo
  var out = []
  for (var j = 0; j < values.length; j++) {
    var n = seriesNumber(values[j])
    if (n === null) { out.push(null); continue }
    out.push(span < 0.0001 ? 0.5 : (n - lo) / span)
  }
  return out
}

function minOf(values) {
  var nums = []
  for (var i = 0; i < (values || []).length; i++) {
    var v = seriesNumber(values[i])
    if (v !== null) nums.push(v)
  }
  return nums.length ? Math.min.apply(null, nums) : null
}

function maxOf(values) {
  var nums = []
  for (var i = 0; i < (values || []).length; i++) {
    var v = seriesNumber(values[i])
    if (v !== null) nums.push(v)
  }
  return nums.length ? Math.max.apply(null, nums) : null
}

// Eight-level ramp: one character per value, heights from ▁ to █.
var BLOCK_RAMP = ["\u2581", "\u2582", "\u2583", "\u2584", "\u2585", "\u2586", "\u2587", "\u2588"]
// Four-level shading for probabilities and sums: ░ ▒ ▓ █.
var SHADE_RAMP = ["\u2591", "\u2592", "\u2593", "\u2588"]

// Fractional values (0..1, nulls allowed) as one ramp character each, so a
// list of 24 reads as a solid sparkline row in a monospace font.
function rampRow(values, ramp) {
  var chars = ramp || BLOCK_RAMP
  var out = ""
  for (var i = 0; i < (values || []).length; i++) {
    var v = values[i]
    if (v === null || v === undefined || !isFinite(Number(v))) { out += " "; continue }
    var k = Math.max(0, Math.min(chars.length - 1, Math.round(Number(v) * (chars.length - 1))))
    out += chars[k]
  }
  return out
}

function sparkRow(values, ramp) {
  return rampRow(normalizeSeries(values), ramp || BLOCK_RAMP)
}

// One ramp character per cell as an array -- the views place each cell
// themselves so a row spans its full width whatever the font metrics are.
function sparkCells(values, ramp) {
  var chars = ramp || BLOCK_RAMP
  var normalized = normalizeSeries(values)
  var out = []
  for (var i = 0; i < normalized.length; i++) {
    var v = normalized[i]
    if (v === null || v === undefined) { out.push(" "); continue }
    var k = Math.max(0, Math.min(chars.length - 1, Math.round(v * (chars.length - 1))))
    out.push(chars[k])
  }
  return out
}

// Percentages (0..100) as a four-level shade row; a zero reads as a gap, not
// as ░, so "no rain" does not paint a bar.
function shadePercentCells(values) {
  var out = []
  for (var i = 0; i < (values || []).length; i++) {
    var v = seriesNumber(values[i])
    if (v === null || v <= 0) { out.push(" "); continue }
    var clamped = Math.max(0, Math.min(100, v)) / 100
    out.push(SHADE_RAMP[Math.max(0, Math.min(SHADE_RAMP.length - 1, Math.round(clamped * (SHADE_RAMP.length - 1))))])
  }
  return out
}

// Fraction (0..1) of the way along a lo..hi span, clamped -- how the daily
// range bars are placed inside the week's own minimum and maximum.
function spanFraction(value, lo, hi) {
  var v = seriesNumber(value)
  var a = seriesNumber(lo)
  var b = seriesNumber(hi)
  if (v === null || a === null || b === null) return 0
  var span = b - a
  if (span < 0.0001) return 0
  return Math.max(0, Math.min(1, (v - a) / span))
}

if (typeof module !== "undefined") {
  module.exports = {
    requestUrl: requestUrl,
    seriesNumber: seriesNumber,
    toFahrenheitNumber: toFahrenheitNumber,
    roundedOrNull: roundedOrNull,
    oneDecimalOrNull: oneDecimalOrNull,
    hourly: hourly,
    days: days,
    currentDetail: currentDetail,
    codeLabel: codeLabel,
    iconForCode: iconForCode,
    iconForOpenMeteoCode: iconForOpenMeteoCode,
    windDirectionLabel: windDirectionLabel,
    uvRiskLabel: uvRiskLabel,
    minutesOfDay: minutesOfDay,
    sunProgress: sunProgress,
    daylightMinutes: daylightMinutes,
    durationLabel: durationLabel,
    clockLabel: clockLabel,
    dateLabel: dateLabel,
    normalizeSeries: normalizeSeries,
    minOf: minOf,
    maxOf: maxOf,
    rampRow: rampRow,
    sparkRow: sparkRow,
    sparkCells: sparkCells,
    shadePercentCells: shadePercentCells,
    spanFraction: spanFraction,
    BLOCK_RAMP: BLOCK_RAMP,
    SHADE_RAMP: SHADE_RAMP
  }
}
