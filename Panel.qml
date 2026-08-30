import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Chand popup panel.
//
// One column, padding on every side, nothing painted outside the card. The
// KeyboardPanel (Ui/KeyboardPanel.qml) owns the layer-shell; this content
// lives inside its contentHolder. Flickable + contentWidth ~ Style.space(340)
// so it scrolls only when taller than the capped height (~560).
//
// Surfaces (state machine):
//   "watchlist" (default) -> list of symbols
//   "detail"              -> big price + chart + converter for one symbol
//   "catalog"             -> searchable add screen
//
// Keyboard:
//   Esc on catalog/detail -> watchlist; Esc on watchlist -> close
//   + or / -> catalog; Backspace or h -> back
//   j/k move rows; Enter opens detail or adds from catalog
//   r refresh; Flickable must not eat these (PanelKeyCatcher runs BeforeItem)

Panel {
  id: root
  moduleName: "io.github.HACK3RRABBIT.chand"
  ipcTarget: "io.github.HACK3RRABBIT.chand"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Absolute path to the bundled fetch script. Quickshell's Process does not
  // resolve relative paths against the plugin dir, so we derive it from this
  // file's location.
  readonly property string fetchChand: Qt.resolvedUrl("scripts/fetch-chand").toString().replace(/^file:\/\//, "")

  // ---- settings mirror (kept honest with the bar-widget entry) ----
  readonly property var cfg: Model.loadSettings(settings ? JSON.stringify(settings) : "{}")

  // ---- surface state ----
  property string surface: "watchlist"
  property string selectedKey: ""
  property int cursor: 0
  property string range: (cfg.range || "1y")

  // detail fetch state (one-shot; history file is appended by the poller too)
  property var detailState: null

  // ---- colors (product spec) ----
  readonly property color upColor:   "#22c55e"
  readonly property color downColor: "#ef4444"
  readonly property color flatColor: root.bar ? root.bar.barForeground : Color.foreground
  function dirColor(dir) {
    if (dir === "up") return root.upColor
    if (dir === "down") return root.downColor
    return root.flatColor
  }

  // ---- settings helpers (persist via updateEntryInline, like clock/weather) ----
  function buildEntry(extra) {
    var e = { id: root.moduleName, primary: cfg.primary, compact: cfg.compact, range: root.range }
    if (Array.isArray(cfg.symbols)) e.symbols = cfg.symbols.slice()
    if (extra) for (var k in extra) e[k] = extra[k]
    return e
  }
  function persist(entry) {
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }
  // Range is in-memory only. Previously this called persist()/updateEntryInline
  // on every chip tap, which reloaded the whole plugin (the panel shook and the
  // pill flickered to "Chand" while settings reinitialized). Range does NOT need
  // to be persisted, so we just switch it and refetch the chart for this key.
  function setRange(r) {
    if (root.range === r) return
    root.range = r
    if (root.selectedKey) root.fetchDetail(root.selectedKey, r)
  }
  function setPrimary(key) {
    // Bar primary is locked to USD (product spec: only USD on the bar, nothing
    // else can be set). Still persist the rest and open Detail for this key.
    var e = buildEntry({})
    e.primary = "price_dollar_rl"
    persist(e)
    if (root.hostWidget && typeof root.hostWidget.setPrimary === "function") root.hostWidget.setPrimary("price_dollar_rl")
  }
  function setSymbols(syms) {
    var e = buildEntry({})
    e.symbols = syms.slice()
    persist(e)
  }

  // ---- panel open/close (mirrors weather Panel) ----
  function open() {
    root.controller.show()
    root.refresh()
  }
  function openFromHotkey() {
    root.controller.show()
    root.refresh()
    Qt.callLater(function () {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }
  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }
  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function goDetail(key) {
    root.selectedKey = key
    root.surface = "detail"
    root.cursor = 0
    root.detailState = null
    fetchDetail(key, root.range)
  }
  function goWatchlist() {
    root.surface = "watchlist"
    root.cursor = 0
    root.selectedKey = ""
    root.detailState = null
  }
  function goCatalog() {
    root.surface = "catalog"
    root.cursor = 0
    root.catalogQuery = ""
    Qt.callLater(function () { if (catalogField) catalogField.forceActiveFocus() })
  }
  function back() {
    if (root.surface === "watchlist") root.close()
    else root.goWatchlist()
  }

  // Remove a symbol from the watchlist (✕), without opening detail.
  function removeSymbol(key) {
    var syms = (Array.isArray(cfg.symbols) ? cfg.symbols : []).filter(function (k) { return k !== key })
    setSymbols(syms)
    if (root.cursor >= syms.length) root.cursor = Math.max(0, syms.length - 1)
  }
  function addSymbol(key) {
    var syms = Array.isArray(cfg.symbols) ? cfg.symbols.slice() : []
    if (syms.indexOf(key) === -1) syms.push(key)
    setSymbols(syms)
  }

  // ---- keyboard ----
  function moveCursor(d) {
    var len = root.surface === "catalog" ? root.catalogItems.length : (root.surface === "detail" ? 0 : (Array.isArray(cfg.symbols) ? cfg.symbols.length : 0))
    if (len <= 0) return
    root.cursor = Math.max(0, Math.min(len - 1, root.cursor + d))
  }
  function activateCursor() {
    if (root.surface === "watchlist") {
      var syms = Array.isArray(cfg.symbols) ? cfg.symbols : []
      if (root.cursor >= 0 && root.cursor < syms.length) {
        root.goDetail(syms[root.cursor])
      }
    } else if (root.surface === "catalog") {
      var item = root.catalogItems[root.cursor]
      if (item) root.addSymbol(item.key)
    }
  }

  // ================= POLLING =================
  // Every tick we fetch the primary + every watchlist symbol + the open
  // detail key, and MERGE the result into the snapshot (never replace it) so
  // rows never blink or reset to 0 between polls. A separate detail process
  // appends to the history cache and (on first open) backfills the snapshot
  // for the detail key.
  property var snapshot: ({})        // key -> latest current item

  function refresh() {
    var keys = []
    if (cfg.primary) keys.push(cfg.primary)
    var syms = Array.isArray(cfg.symbols) ? cfg.symbols : []
    for (var i = 0; i < syms.length; i++) if (syms[i] !== cfg.primary) keys.push(syms[i])
    if (root.surface === "detail" && root.selectedKey && keys.indexOf(root.selectedKey) === -1)
      keys.push(root.selectedKey)
    if (keys.length === 0) return
    poller.command = [root.fetchChand, "current"].concat(keys)
    poller.running = true
  }

  function fetchDetail(key, range) {
    detailProc.command = [root.fetchChand, "history", key, range]
    detailProc.running = true
  }

  Process {
    id: poller
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var parsed = JSON.parse(raw)
          if (parsed && parsed.items) {
            // Merge into the existing snapshot so unwatched/unchanged rows
            // (and rows not in this poll's key set) keep their last value.
            var snap = {}
            var old = root.snapshot || {}
            for (var k in old) snap[k] = old[k]
            for (var i = 0; i < parsed.items.length; i++) {
              var it = parsed.items[i]
              if (it && it.key) snap[it.key] = it
            }
            root.snapshot = snap
            // Mirror the primary into the bar pill.
            if (snap[cfg.primary] && root.hostWidget && typeof root.hostWidget.setPrimaryState === "function")
              root.hostWidget.setPrimaryState(snap[cfg.primary])
            // Refresh the open detail's current values (live Δ etc.).
            if (root.surface === "detail" && snap[root.selectedKey])
              root.detailState = snap[root.selectedKey]
          }
        } catch (e) {}
      }
    }
  }

  Process {
    id: detailProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        try {
          var parsed = JSON.parse(raw)
          root.detailHistory = parsed
          // Cold cache (first open of a brand-new key): kick a background
          // warm; when it lands it re-reads this chart from cache.
          if (parsed && parsed.summary && parsed.summary.points === 0)
            root.warmCharts()
        } catch (e) {}
      }
    }
  }

  property var detailHistory: null

  // Background chart warmer. Every 5 minutes it rebuilds every chart range
  // for every watchlist key into ~/.cache/omarchy-chand/charts, so opening a
  // detail chart is an instant cache read (fetch-chand history) — never a
  // blocking network fetch. Runs detached from the visible poller.
  Process {
    id: warmer
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // A warm pass just landed; re-read the open chart from the
        // now-fresh cache (covers the cold-miss kick below too).
        if (root.surface === "detail" && root.selectedKey)
          root.fetchDetail(root.selectedKey, root.range)
      }
    }
  }
  function warmCharts() {
    var keys = []
    var syms = Array.isArray(cfg.symbols) ? cfg.symbols : []
    for (var i = 0; i < syms.length; i++) keys.push(syms[i])
    if (cfg.primary && keys.indexOf(cfg.primary) === -1) keys.push(cfg.primary)
    if (root.surface === "detail" && root.selectedKey && keys.indexOf(root.selectedKey) === -1)
      keys.push(root.selectedKey)
    if (keys.length === 0 || warmer.running) return
    warmer.command = [root.fetchChand, "warm"].concat(keys)
    warmer.running = true
  }

  Timer {
    id: refreshTimer
    interval: 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.refresh()
      root.warmCharts()
    }
  }

  // ================= UI =================
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(chandColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.surface === "catalog" && catalogField && catalogField.activeFocus
      onMoveRequested: function(dx, dy) { root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: {
        if (root.surface === "watchlist") root.close()
        else root.goWatchlist()
      }
      onDeleteRequested: {
        if (root.surface === "watchlist" && Array.isArray(cfg.symbols)) {
          var syms = cfg.symbols
          if (root.cursor >= 0 && root.cursor < syms.length) root.removeSymbol(syms[root.cursor])
        }
      }
      onTabRequested: function(direction) { if (direction > 0) root.goCatalog() }
      onTextKey: function(t) {
        if (t === "r") root.refresh()
        else if (t === "+" || t === "/") root.goCatalog()
        else if (t === "h") root.back()
      }
      onReturnRequested: root.activateCursor()

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: chandColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: chandColumn
          width: scroll.width
          spacing: Style.space(12)

          // ---- HEADER ----
          Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
              id: titleText
              anchors.verticalCenter: parent.verticalCenter
              text: root.surface === "catalog" ? "Add asset" : "Chand"
              color: root.bar.barForeground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Item { width: parent.width - backBtn.width - headerAction.width - titleText.width - Style.space(32); height: 1 }
            // Back (detail/catalog)
            Rectangle {
              id: backBtn
              visible: root.surface !== "watchlist"
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22); height: Style.space(22)
              radius: Style.cornerRadius
              color: root.cursor >= 0 && false ? "transparent" : "transparent"
              Text {
                anchors.centerIn: parent
                text: "‹"
                color: root.bar.barForeground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.back()
              }
            }
            // Header action: + (watchlist) or Done (catalog)
            Rectangle {
              id: headerAction
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22); height: Style.space(22)
              radius: Style.cornerRadius
              color: "transparent"
              visible: root.surface === "watchlist" || root.surface === "catalog"
              Text {
                anchors.centerIn: parent
                text: root.surface === "catalog" ? "✓" : "+"
                color: root.bar.barForeground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (root.surface === "watchlist") root.goCatalog()
                  else root.goWatchlist()
                }
              }
            }
            // Manual refresh button (↻): update prices right now, on demand.
            Rectangle {
              id: refreshBtn
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(22); height: Style.space(22)
              radius: Style.cornerRadius
              color: "transparent"
              visible: root.surface === "watchlist" || root.surface === "detail"
              Text {
                anchors.centerIn: parent
                text: "↻"
                color: root.bar.barForeground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.refresh()
              }
            }
          }

          // ================= WATCHLIST =================
          Column {
            visible: root.surface === "watchlist"
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: Array.isArray(cfg.symbols) ? cfg.symbols : []
              delegate: Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: rowInner.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: index === root.cursor ? Style.hoverFillFor(root.bar.barForeground, Color.accent) : "transparent"
                property var entry: Model.catalogEntry(modelData)
                property var st: root.snapshot[modelData] || null

                Row {
                  id: rowInner
                  // Stack above the row-level MouseArea (a later-declared
                  // sibling that covers the whole row): without this, the ✕
                  // click never reaches removeBtn and opens Detail instead.
                  z: 1
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(20)
                  spacing: Style.space(8)

                  Column {
                    width: parent.width - removeBtn.width - changeCol.width - Style.space(16)
                    Text {
                      text: (entry ? entry.code : modelData) + (entry && entry.name !== entry.code ? "  " + entry.name : "")
                      color: root.bar.barForeground
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                      width: parent.width
                    }
                    Text {
                      visible: !!st && st.ok
                      text: st && st.ok ? Model.formatToman(st.toman) + " T" : ""
                      color: Qt.darker(root.bar.barForeground, 1.4)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }

                  Column {
                    id: changeCol
                    width: Style.space(70)
                    Text {
                      property string dir: st && st.ok ? Model.direction(st.change_pct) : "flat"
                      text: st && st.ok ? Model.formatPercent(st.change_pct) + "%" : "—"
                      color: st && st.ok ? root.dirColor(dir) : Qt.darker(root.bar.barForeground, 1.5)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      horizontalAlignment: Text.AlignRight
                      width: parent.width
                    }
                  }

                  Rectangle {
                    id: removeBtn
                    width: Style.space(20); height: Style.space(20)
                    radius: Style.cornerRadius
                    z: 2
                    color: "transparent"
                    Text {
                      anchors.centerIn: parent
                      text: "✕"
                      color: Qt.darker(root.bar.barForeground, 1.5)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.removeSymbol(modelData)
                    }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.cursor = index
                  onClicked: { root.goDetail(modelData) }
                }
              }
            }

            // Empty state.
            Column {
              visible: !Array.isArray(cfg.symbols) || cfg.symbols.length === 0
              width: parent.width
              spacing: Style.space(8)
              Text {
                text: "Add currencies, gold, or crypto"
                color: Qt.darker(root.bar.barForeground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                width: parent.width
              }
              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(60); height: Style.space(26)
                radius: Style.cornerRadius
                color: Style.hoverFillFor(root.bar.barForeground, Color.accent)
                Text {
                  anchors.centerIn: parent
                  text: "Add"
                  color: root.bar.barForeground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.goCatalog()
                }
              }
            }
          }

          // ================= DETAIL =================
          Column {
            visible: root.surface === "detail"
            width: parent.width
            spacing: Style.space(12)

            readonly property var dEntry: Model.catalogEntry(root.selectedKey)
            readonly property var dSt: root.detailState || (root.snapshot[root.selectedKey]) || null
            readonly property string dDir: (dSt && dSt.ok) ? Model.direction(dSt.change_pct) : "flat"

            Text {
              text: (parent.dEntry ? parent.dEntry.name : root.selectedKey)
              color: root.bar.barForeground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              width: parent.width
              elide: Text.ElideRight
            }
            Text {
              readonly property var s: parent.dSt
              text: s && s.ok ? Model.formatToman(s.toman) + " Toman" : (s && s.ok === false ? "unavailable" : "…")
              color: root.bar.barForeground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              font.bold: true
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  var code = root.selectedKey ? (Model.catalogEntry(root.selectedKey) || {}).code : ""
                  if (parent.s && parent.s.ok) {
                    var txt = code + " " + Model.formatToman(parent.s.toman) + " Toman"
                    root.bar.run("printf '%s' " + JSON.stringify(txt) + " | wl-copy")
                  }
                }
              }
            }
            // Δ% for the selected range: first price -> current price from
            // the (cache-warmed) chart summary. Falls back to the live 24h
            // change only while no series exists yet.
            // NOTE: reference dSt directly here — inside a property binding
            // of this Column, `parent` is the Column's VISUAL parent, which
            // has no dSt (that made Δ% show 0 for every asset/range).
            readonly property real dPct: {
              var h = root.detailHistory
              if (h && h.summary && h.summary.points >= 2 && h.summary.first_price)
                return h.summary.range_delta / h.summary.first_price * 100
              var s = dSt
              return (s && s.ok) ? (Number(s.change_pct) || 0) : 0
            }
            // "The price range was this at first, now it's that."
            readonly property string dRangeText: {
              var h = root.detailHistory
              if (h && h.summary && h.summary.points >= 2)
                return Model.formatToman(h.summary.first_price) + " → " + Model.formatToman(h.summary.last_price) + " T"
              var s = dSt
              return (s && s.ok) ? Model.formatSignedToman(Number(s.change_toman) || 0) + " T" : ""
            }
            Row {
              spacing: Style.space(10)
              readonly property string dDir: Model.direction(parent.dPct)
              readonly property string rangeText: parent.dRangeText
              Text {
                text: Model.directionGlyph(parent.dDir) + " " + Model.formatPercent(parent.parent.dPct) + "%"
                color: root.dirColor(parent.dDir)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
              Text {
                text: parent.rangeText
                color: root.dirColor(parent.dDir)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
              }
            }
            // Buy / sell line (only if both exist and differ).
            Row {
              readonly property var s: parent.dSt
              visible: !!s && s.ok && s.buy_toman != null && s.sell_toman != null && s.buy_toman !== s.sell_toman
              spacing: Style.space(16)
              Text {
                visible: parent.visible
                text: "Buy " + Model.formatToman(parent.s ? parent.s.buy_toman : 0) + " T"
                color: Qt.darker(root.bar.barForeground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                visible: parent.visible
                text: "Sell " + Model.formatToman(parent.s ? parent.s.sell_toman : 0) + " T"
                color: Qt.darker(root.bar.barForeground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            // Range chips (Flow, wraps 3+3).
            Flow {
              width: parent.width
              spacing: Style.space(6)
              property var ranges: ["1D", "1W", "1Y", "5Y", "All"]
              Repeater {
                model: parent.ranges
                Rectangle {
                  required property var modelData
                  width: Style.space(46); height: Style.space(26)
                  radius: Style.cornerRadius
                  color: (root.range.toLowerCase() === modelData.toLowerCase())
                    ? Style.hoverFillFor(root.bar.barForeground, Color.accent)
                    : "transparent"
                  border.width: 1
                  border.color: Qt.darker(root.bar.barForeground, 1.8)
                  Text {
                    anchors.centerIn: parent
                    text: modelData
                    color: root.bar.barForeground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      var map = { "1D": "1d", "1W": "1w", "1Y": "1y", "5Y": "5y", "All": "all" }
                      root.setRange(map[modelData])
                    }
                  }
                }
              }
            }

            // Chart (or collecting-history placeholder).
            Rectangle {
              width: parent.width
              height: Style.space(120)
              radius: Style.cornerRadius
              color: Qt.darker(root.bar.background, 1.0)
              border.width: 1
              border.color: Util.alpha(root.bar.barForeground, 0.08)
              clip: true

              readonly property var hist: root.detailHistory
              readonly property var series: (hist && hist.series) ? hist.series : []
              readonly property string rangeDir: (hist && hist.summary && hist.summary.points >= 2)
                ? Model.direction(hist.summary.range_delta)
                : ((root.detailState && root.detailState.ok) ? Model.direction(root.detailState.change_pct) : "flat")
              ChartCanvas {
                anchors.fill: parent
                anchors.margins: Style.space(4)
                points: parent.series
                color: root.dirColor(parent.rangeDir)
                fill: Util.alpha(parent.color, 0.18)
                visible: parent.series.length >= 2
              }
              Text {
                visible: parent.series.length < 2
                anchors.centerIn: parent
                text: "Collecting history…"
                color: Qt.darker(root.bar.barForeground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.italic: true
              }
            }

            // Summary: Jalali from->to, high, low, range Δ.
            Column {
              width: parent.width
              spacing: Style.space(4)
              readonly property var sum: (root.detailHistory && root.detailHistory.summary && root.detailHistory.summary.points > 0) ? root.detailHistory.summary : null
              Text {
                visible: parent.sum
                text: parent.sum ? Model.jalaliRange(parent.sum.from, parent.sum.to) : ""
                color: Qt.darker(root.bar.barForeground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              Row {
                visible: parent.sum
                spacing: Style.space(14)
                Text { text: parent.sum ? ("High " + Model.formatToman(parent.sum.high) + " T") : ""; color: Qt.darker(root.bar.barForeground, 1.3); font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
                Text { text: parent.sum ? ("Low " + Model.formatToman(parent.sum.low) + " T") : ""; color: Qt.darker(root.bar.barForeground, 1.3); font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
              }
            }

            // Converter (this screen only): amount × this asset ↔ Toman.
            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "Converter"
                color: Qt.darker(root.bar.barForeground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }
              Row {
                width: parent.width
                spacing: Style.space(6)
                Rectangle {
                  id: convBox
                  width: parent.width - tomanOut.width - Style.space(6)
                  height: Style.space(26)
                  radius: Style.cornerRadius
                  color: "transparent"
                  border.width: 1
                  border.color: Util.alpha(root.bar.barForeground, 0.2)
                  TextInput {
                    id: convInput
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(6)
                    verticalAlignment: Text.AlignVCenter
                    color: root.bar.barForeground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    text: "1"
                    validator: DoubleValidator { bottom: 0; decimals: 8 }
                    onTextChanged: Qt.callLater(root.recompute)
                  }
                }
                Text {
                  id: tomanOut
                  width: Style.space(120)
                  text: root.convertedToman
                  color: root.bar.barForeground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  horizontalAlignment: Text.AlignRight
                  elide: Text.ElideRight
                }
              }
              Text {
                text: (parent.parent.dEntry ? parent.parent.dEntry.code : "") + " × " + (root.convAmount) + "  =  " + root.convertedToman + " Toman"
                color: Qt.darker(root.bar.barForeground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
                width: parent.width
                elide: Text.ElideRight
              }
            }
          }

          // ================= CATALOG =================
          Column {
            visible: root.surface === "catalog"
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: catalogField
              width: parent.width
              placeholderText: "Search assets"
              foreground: root.bar.barForeground
              font.family: root.bar.fontFamily
              onTextChanged: { root.catalogQuery = text; root.cursor = 0 }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { root.goWatchlist(); event.accepted = true }
                else if (event.key === Qt.Key_Backspace && text === "") { root.goWatchlist(); event.accepted = true }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(10)
              Repeater {
                model: root.catalogGroupsFiltered
                delegate: Column {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(2)
                  Text {
                    text: modelData.title
                    color: Qt.darker(root.bar.barForeground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.letterSpacing: 1
                  }
                  Repeater {
                    model: modelData.items
                    delegate: Rectangle {
                      required property var modelData
                      readonly property var item: modelData
                      width: parent.width
                      height: catRow.implicitHeight + Style.space(8)
                      radius: Style.cornerRadius
                      color: item.__idx === root.cursor ? Style.hoverFillFor(root.bar.barForeground, Color.accent) : "transparent"
                      readonly property bool added: Array.isArray(cfg.symbols) && cfg.symbols.indexOf(item.key) !== -1

                      Row {
                        id: catRow
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - Style.space(16)
                        spacing: Style.space(8)
                        Text {
                          text: item.code + "  " + item.name
                          color: root.bar.barForeground
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.body
                          width: parent.width - checkCol.width - Style.space(8)
                          elide: Text.ElideRight
                        }
                        Text {
                          id: checkCol
                          text: added ? "✓" : ""
                          color: root.upColor
                          font.family: root.bar.fontFamily
                          font.pixelSize: Style.font.body
                          horizontalAlignment: Text.AlignRight
                        }
                      }
                      MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.cursor = item.__idx
                        onClicked: { if (!added) root.addSymbol(item.key) }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // ---- catalog derived state ----
  property string catalogQuery: ""
  // Filtered, grouped catalog by query (code/name match). Reactive: recomputes
  // whenever catalogQuery changes. Re-indexes __idx across the visible set so
  // cursor navigation spans groups.
  readonly property var catalogGroupsFiltered: {
    var q = (root.catalogQuery || "").trim().toLowerCase()
    var groups = Model.catalogGroups()
    var out = []
    for (var g = 0; g < groups.length; g++) {
      var items = groups[g].items
      if (q) items = items.filter(function (a) {
        return a.code.toLowerCase().indexOf(q) !== -1 || a.name.toLowerCase().indexOf(q) !== -1
      })
      if (items.length) out.push({ title: groups[g].title, items: items })
    }
    var idx = 0
    for (var gg = 0; gg < out.length; gg++)
      for (var ii = 0; ii < out[gg].items.length; ii++) out[gg].items[ii].__idx = idx++
    return out
  }
  // Flattened visible list (for cursor navigation).
  readonly property var catalogItems: {
    var out = []
    var groups = root.catalogGroupsFiltered
    for (var g = 0; g < groups.length; g++)
      for (var i = 0; i < groups[g].items.length; i++) out.push(groups[g].items[i])
    return out
  }

  // ---- converter derived state ----
  readonly property real convAmount: parseFloat(convInput && convInput.text ? convInput.text : "0") || 0
  readonly property real convertedToman: {
    var s = root.detailState || (root.snapshot[root.selectedKey])
    if (!s || !s.ok) return 0
    return root.convAmount * s.toman
  }
  function recompute() {}

  // Reset transient state when surface/selection changes.
  onSurfaceChanged: root.cursor = 0
  onSelectedKeyChanged: root.cursor = 0
}
