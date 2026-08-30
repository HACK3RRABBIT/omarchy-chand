// Model.js — Chand data layer.
//
// Pure JS (no QML imports) so it can be unit-reasoned about and reused by
// BarWidget.qml and Panel.qml via `import "Model.js" as Model`.
//
// Responsibilities:
//   - the asset catalog (verified live against TGJU before shipping)
//   - settings load/save to ~/.config/omarchy/chand.json
//   - number / percent / change formatting (Toman, no Persian, compact mode)
//   - Jalali date helpers (Latin digits, Tehran date arithmetic)
//   - history cache file path + cap logic shared with scripts/fetch-chand

var HOME = (function () {
  try { if (typeof Quickshell !== "undefined" && Quickshell.env) return Quickshell.env("HOME") } catch (e) {}
  try { if (typeof process !== "undefined" && process.env && process.env.HOME) return process.env.HOME } catch (e) {}
  return "~"
})()
var CONFIG_FILE = HOME + "/.config/omarchy/chand.json"
var CACHE_DIR = HOME + "/.cache/omarchy-chand"
var HISTORY_DIR = CACHE_DIR + "/history"
var MAX_DAYS = 90

// --- Asset catalog -----------------------------------------------------------
//
// Every key below was verified present on a live https://call5.tgju.org/ajax.json
// payload (2026-08-30). NOTE the Emami/Imami coin: the spec suggested `sekkeh`,
// but that key does NOT exist in the live payload. The real Emami coin is
// `sekee`; `sekeb` is the Bahar Azadi coin. We map honestly to avoid a
// mislabeled and duplicated row.
//
// kind: "currency" | "gold" | "crypto"
//   currency/gold: Toman = rial(p) / 10
//   crypto:        Toman = usd(p) * price_dollar_rl / 10  (USD on TGJU)
// code: short bar label (USD, EUR, BTC, AZADI, EMAMI, ...). Used on the pill
//       and as the compact overflow-safe label.
// name: friendly English name shown in the panel / catalog.

var CATALOG = [
  // ---- Currencies ----
  { key: "price_dollar_rl", code: "USD",  name: "US Dollar",        kind: "currency" },
  { key: "price_eur",       code: "EUR",  name: "Euro",             kind: "currency" },
  { key: "price_gbp",       code: "GBP",  name: "British Pound",    kind: "currency" },
  { key: "price_aed",       code: "AED",  name: "UAE Dirham",       kind: "currency" },
  { key: "price_try",       code: "TRY",  name: "Turkish Lira",     kind: "currency" },
  { key: "price_chf",       code: "CHF",  name: "Swiss Franc",      kind: "currency" },
  { key: "price_sek",       code: "SEK",  name: "Swedish Krona",    kind: "currency" },
  { key: "price_nok",       code: "NOK",  name: "Norwegian Krone",  kind: "currency" },
  { key: "price_dkk",       code: "DKK",  name: "Danish Krone",     kind: "currency" },
  { key: "price_sgd",       code: "SGD",  name: "Singapore Dollar", kind: "currency" },
  { key: "price_cad",       code: "CAD",  name: "Canadian Dollar",  kind: "currency" },
  { key: "price_aud",       code: "AUD",  name: "Australian Dollar",kind: "currency" },
  { key: "price_cny",       code: "CNY",  name: "Chinese Yuan",     kind: "currency" },
  { key: "price_jpy",       code: "JPY",  name: "Japanese Yen",     kind: "currency" },
  { key: "price_hkd",       code: "HKD",  name: "Hong Kong Dollar", kind: "currency" },
  { key: "price_inr",       code: "INR",  name: "Indian Rupee",     kind: "currency" },
  { key: "price_myr",       code: "MYR",  name: "Malaysian Ringgit",kind: "currency" },
  { key: "price_thb",       code: "THB",  name: "Thai Baht",        kind: "currency" },
  { key: "price_rub",       code: "RUB",  name: "Russian Ruble",    kind: "currency" },
  { key: "price_qar",       code: "QAR",  name: "Qatari Riyal",     kind: "currency" },
  { key: "price_omr",       code: "OMR",  name: "Omani Rial",       kind: "currency" },
  { key: "price_kwd",       code: "KWD",  name: "Kuwaiti Dinar",    kind: "currency" },
  { key: "price_sar",       code: "SAR",  name: "KSA Riyal",        kind: "currency" },
  { key: "price_iqd",       code: "IQD",  name: "Iraqi Dinar",      kind: "currency" },
  { key: "price_bhd",       code: "BHD",  name: "Bahraini Dinar",   kind: "currency" },
  { key: "price_azn",       code: "AZN",  name: "Azerbaijani Manat",kind: "currency" },
  { key: "price_amd",       code: "AMD",  name: "Armenian Dram",    kind: "currency" },
  { key: "price_afn",       code: "AFN",  name: "Afghan Afghani",   kind: "currency" },

  // ---- Gold & coins ----
  { key: "geram18", code: "18K",  name: "Gold 18k (per gram)", kind: "gold" },
  { key: "geram24", code: "24K",  name: "Gold 24k (per gram)", kind: "gold" },
  { key: "mesghal", code: "MSG",  name: "Gold Mesghal",        kind: "gold" },
  { key: "sekee",   code: "EMAMI",name: "Emami coin",          kind: "gold" },
  { key: "sekeb",   code: "AZADI",name: "Azadi coin",          kind: "gold" },
  { key: "nim",     code: "½AZ",  name: "Half Azadi coin",     kind: "gold" },
  { key: "rob",     code: "¼AZ",  name: "Quarter Azadi coin",  kind: "gold" },
  { key: "gerami",  code: "1G",   name: "Gold 1g coin",        kind: "gold" },

  // ---- Crypto (USD on TGJU) ----
  { key: "crypto-bitcoin",      code: "BTC",  name: "Bitcoin",       kind: "crypto" },
  { key: "crypto-ethereum",     code: "ETH",  name: "Ethereum",      kind: "crypto" },
  { key: "crypto-tether",       code: "USDT", name: "Tether",        kind: "crypto" },
  { key: "crypto-ripple",       code: "XRP",  name: "Ripple",        kind: "crypto" },
  { key: "crypto-litecoin",     code: "LTC",  name: "Litecoin",      kind: "crypto" },
  { key: "crypto-eos",          code: "EOS",  name: "EOS",           kind: "crypto" },
  { key: "crypto-binance-coin", code: "BNB",  name: "BNB",           kind: "crypto" }
]

// Fast key -> catalog entry lookup.
var CATALOG_BY_KEY = (function () {
  var m = {}
  for (var i = 0; i < CATALOG.length; i++) m[CATALOG[i].key] = CATALOG[i]
  return m
})()

function catalogEntry(key) {
  return CATALOG_BY_KEY[key] || null
}

// Grouped catalog (for the catalog screen), in display order.
function catalogGroups() {
  return [
    { title: "Currencies",   kind: "currency", items: CATALOG.filter(function (a) { return a.kind === "currency" }) },
    { title: "Gold & coins", kind: "gold",     items: CATALOG.filter(function (a) { return a.kind === "gold" }) },
    { title: "Crypto",       kind: "crypto",   items: CATALOG.filter(function (a) { return a.kind === "crypto" }) }
  ]
}

// --- Settings ----------------------------------------------------------------

function defaultSettings() {
  return {
    // Bar primary asset key.
    primary: "price_dollar_rl",
    // Watchlist (panel) asset keys, in order.
    symbols: [
      "price_dollar_rl"
    ],
    // Selected chart range for Detail.
    range: "1y",
    // Compact bar pill (right-click toggles too). Defaults ON so the
    // closed bar widget stays short: "USD 205.1k ▲1.48%".
    compact: true
  }
}

function loadSettings(raw) {
  var def = defaultSettings()
  var data
  try { data = JSON.parse(String(raw || "")) } catch (e) { data = {} }
  if (!data || typeof data !== "object") data = {}
  return {
    primary: typeof data.primary === "string" ? data.primary : def.primary,
    symbols: Array.isArray(data.symbols) && data.symbols.length
      ? data.symbols.slice() : def.symbols.slice(),
    range: typeof data.range === "string" ? data.range : def.range,
    compact: !!data.compact
  }
}

// --- Number / change formatting ---------------------------------------------

// Persian/Arabic digit guard: TGJU sometimes returns localized digits. This
// keeps the plugin free of any Persian text in the UI and ensures parsing is
// safe. Returns a JS number or NaN.
function parseNum(v) {
  if (typeof v === "number") return v
  if (v === null || v === undefined) return NaN
  var s = String(v).replace(/,/g, "").trim()
  // Normalize any non-ASCII digits (e.g. Arabic-Indic) to ASCII.
  s = s.replace(/[٠-٩۰-۹]/g, function (d) {
    var map = "٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹"
    var i = map.indexOf(d)
    return i >= 0 ? String(i % 10) : d
  })
  return parseFloat(s)
}

// Toman formatted with thousands separators and no decimals when large.
//   formatToman(206010)      -> "206,010"
//   formatToman(16071190317) -> "16,071,190,317"
function formatToman(value) {
  var n = parseNum(value)
  if (isNaN(n)) return "—"
  var neg = n < 0
  n = Math.abs(Math.round(n))
  var s = String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return (neg ? "-" : "") + s
}

// Compact Toman for the right-click / overflow pill:
//   < 1000      -> "123"
//   < 1M        -> "12.3k"   (thousand)
//   < 1B        -> "1.23M"   (million)
//   >= 1B       -> "16.1B"
function formatCompactToman(value) {
  var n = parseNum(value)
  if (isNaN(n)) return "—"
  var neg = n < 0
  n = Math.abs(n)
  var out
  if (n < 1000) out = String(Math.round(n))
  else if (n < 1e6) out = trimZeros(n / 1e3) + "k"
  else if (n < 1e9) out = trimZeros(n / 1e6) + "M"
  else out = trimZeros(n / 1e9) + "B"
  return (neg ? "-" : "") + out
}

function trimZeros(n) {
  // Up to 2 decimals, trailing zeros stripped.
  var s = n.toFixed(2)
  return s.replace(/\.?0+$/, "")
}

// Signed percent with 2 decimals, e.g. "+2.33" / "-1.05" / "0.00".
// Normalizes -0.00 to 0.00 so a flat asset never shows a stray minus.
function formatPercent(pct) {
  var n = parseNum(pct)
  if (isNaN(n)) return "0.00"
  // round to 2 decimals, then drop a -0.00
  n = Math.round(n * 100) / 100
  if (n === 0) n = 0
  var sign = n > 0 ? "+" : ""
  return sign + n.toFixed(2)
}

// Signed Toman change with thousands separators, e.g. "+4,810".
function formatSignedToman(value) {
  var n = parseNum(value)
  if (isNaN(n)) return "0"
  var neg = n < 0
  n = Math.abs(Math.round(n))
  var s = String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return (neg ? "-" : "+") + s
}

// Direction from a percent: "up" | "down" | "flat".
function direction(pct) {
  var n = parseNum(pct)
  if (isNaN(n) || n === 0) return "flat"
  return n > 0 ? "up" : "down"
}

// Glyph for a direction (never Color.accent / Color.urgent — those are applied
// by the QML layer via explicit colors per the product spec).
function directionGlyph(dir) {
  if (dir === "up") return "▲"
  if (dir === "down") return "▼"
  return "▬"
}

// --- Jalali (Persian calendar) -------------------------------------------------
//
// Latin digits only. We render the *Tehran* date for the summary "from -> to"
// and convert a Gregorian date to Jalali for display. Algorithm: the standard
// Gregorian<->Jalali conversion (via Julian Day Number).

function gregorianToJalali(gy, gm, gd) {
  var g_d_m = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
  var gy2 = (gm > 2) ? (gy + 1) : gy
  var days = 355666 + (365 * gy) + Math.floor((gy2 + 3) / 4)
    - Math.floor((gy2 + 99) / 100)
    + Math.floor((gy2 + 399) / 400)
    + gd + g_d_m[gm - 1]
  var jy = -1595 + (33 * Math.floor(days / 12053))
  days %= 12053
  jy += 4 * Math.floor(days / 1461)
  days %= 1461
  if (days > 365) {
    jy += Math.floor((days - 1) / 365)
    days = (days - 1) % 365
  }
  var jm, jd
  if (days < 186) jm = 1 + Math.floor(days / 31)
  else jm = 7 + Math.floor((days - 186) / 30)
  jd = 1 + (days < 186 ? (days % 31) : ((days - 186) % 30))
  return { y: jy, m: jm, d: jd }
}

var PERSIAN_MONTHS = ["Far", "Ord", "Kho", "Tir", "Mor", "Sha", "Meh", "Aba", "Aza", "Dei", "Bah", "Esf"]

function jalaliLabel(dateOrEpoch) {
  var d = (typeof dateOrEpoch === "number") ? new Date(dateOrEpoch * 1000) : new Date(dateOrEpoch)
  if (isNaN(d.getTime())) return ""
  var j = gregorianToJalali(d.getFullYear(), d.getMonth() + 1, d.getDate())
  var mon = PERSIAN_MONTHS[(j.m - 1 + 12) % 12] || ("M" + j.m)
  return j.y + " " + mon + " " + (j.d < 10 ? "0" + j.d : j.d)
}

function jalaliRange(fromEpoch, toEpoch) {
  return jalaliLabel(fromEpoch) + " → " + jalaliLabel(toEpoch)
}

// --- History cache ------------------------------------------------------------

function historyFile(key) {
  return HISTORY_DIR + "/" + key + ".jsonl"
}

// Tehran date string (YYYY-MM-DD).
function tehranDateString(date) {
  var d = date || new Date()
  // Build a Tehran-local date string without relying on TZ libs in QML.
  var t = new Date(d.getTime() + (d.getTimezoneOffset() + 210) * 60000)
  var y = t.getUTCFullYear(), m = t.getUTCMonth() + 1, day = t.getUTCDate()
  return y + "-" + (m < 10 ? "0" + m : m) + "-" + (day < 10 ? "0" + day : day)
}

function updateEntryInlineSupported() { return true }
