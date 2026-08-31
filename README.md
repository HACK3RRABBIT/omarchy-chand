# Chand — Iran free-market rates on the Omarchy bar

A first-party-quality Omarchy Quattro bar widget that shows Iran's free-market
rates in **Toman**, like the iOS app [Chand](https://apps.apple.com/us/app/chand/id1524200188).

- **Bar pill** — just the **live USD price in Toman**, colored by the **5-minute
  tick**: green when the price is **up vs the last poll (~5 min ago)**, red when
  **down vs the last poll** (up `#22c55e`, down `#ef4444`), flat = bar foreground.
  This is the at-a-glance up/down, *independent of any chart range*. The chart's
  1D/1W/1M/… Δ is computed separately from the range's own first→current price.
  No currency code, no %. Stale/offline dims to 0.5 with a `↺`; fetch error
  shows `✕`. Left-click toggles the panel, middle (or the panel's ↻ button)
  refreshes, right-click toggles compact (full vs. `205.1k` style). The bar
  always shows **USD only** (the default currency; nothing else can be set). Add
  gold/crypto/currencies to the panel watchlist.
- **Watchlist** — scrollable list of assets you added; tap a row for Detail,
  `✕` removes just that row. Reopening the panel always lands on the watchlist.
  (USD stays on the bar regardless — it is the locked primary.)
- **Detail** — big Toman price that **counts up** from its previous value when
  it changes (animated, like it is loading), a colored Δ% for the selected
  range (computed as first-price → current-price from the chart, so it is never
  0), the "first → current" price pair in Toman, buy/sell (only when both exist
  and differ), range chips (`1D 1W 1M 1Y 5Y All` — default **1D**), an area chart
  (real movement from cached history), a Jalali from→to summary (high / low),
  and a converter on this screen only. **Tap the chart** to pin the price at that
  moment — a crosshair + dot mark it and a bubble shows the price and Jalali date;
  tap again to clear. Switching range only refetches the chart — it does not
  reload the plugin. Closing the panel resets every chart back to **1D** and
  reopening always lands on the watchlist.
- **Catalog** — searchable, grouped add screen (Currencies / Gold & coins /
  Crypto). Already-added rows show a checkmark; tap adds and stays open for
  multi-add.

## Data

- **Hybrid, real-time sources** (mirrors the Chand iOS app):
  - **Wallex** `https://api.wallex.ir/v1/markets` — real-time prices for USD and
    crypto in **Toman**, via Wallex's TMN-quoted markets (`USDTTMN`, `BTCTMN`,
    `ETHTMN`, `XRPTMN`, `LTCTMN`, `BNBTMN`, `XAUTTMN`). These are the fast,
    live, accurate Toman prices. Chart history comes from Wallex's UDF klines
    (`/v1/udf/history`): hourly for 1D/1W/1M, daily for 1Y/5Y/All.
  - **TGJU** `https://call5.tgju.org/ajax.json` — breadth for fiat currencies
    (EUR, GBP, AED…) and physical coins (Azadi, Emami, geram18…) that Wallex
    does not list. TGJU quotes **rial** (`toman = rial ÷ 10`); crypto rows are
    USD (`toman = usd × USDTTMN`). Daily snapshot, so its live change is often 0.
  - **api.tgju.org** (TGJU first-party) — daily OHLC history back to 2012 for
    every TGJU asset, used for fiat/coin chart ranges.
- No ECB / Yahoo / NIMA / SANA. No third-party TGJU proxy.
- **State restore.** The last price snapshot is saved to
  `~/.cache/omarchy-chand/panel.json` and restored on load, so the bar pill and
  watchlist repaint instantly after a shell or plugin reload — no blank
  prices while the network poll lands. Closing the panel resets the UI:
  reopening lands on the watchlist with every chart at **1D**. A brand-new
  key's chart shows a small
  animated spinner ("Collecting history…") while its first background warm
  builds the cache.
- **Background caching (no on-demand chart fetching).** Every 5 minutes the
  panel runs `fetch-chand warm` in the background, rebuilding every chart range
  for every watchlist key into `~/.cache/omarchy-chand/charts/<key>_<range>.json`.
  Opening a chart is an **instant cache read** (`history` serves the file
  directly, 3 ms) — it never blocks on the network. The first open of a brand-new
  key triggers one background warm and re-reads when it lands.
- The 5-minute poller fetches live current prices via `fetch-chand current`,
  appending the 5-minute points to `~/.cache/omarchy-chand/history/<key>.jsonl`
  (capped at 8000 points). Short TGJU ranges (1D/1W) splice these intraday
  points in for real hour-to-hour movement. Offline uses the last snapshot.
- Auto-refreshes every **5 minutes**; tap the panel's **↻** button (or
  middle-click the pill) for an on-demand update. The full watchlist + open
  detail are fetched each tick and merged into the snapshot so rows never blink
  or reset.
- All fetching runs off the UI thread via `Process` + `StdioCollector` (one
  `curl` + `jq` call per refresh), exactly like the first-party weather widget.

## Keyboard

| Key | Action |
|-----|--------|
| `Esc` | Catalog/Detail → Watchlist; Watchlist → close |
| `+` or `/` | Open Catalog |
| `Backspace` or `h` | Back |
| `j` / `k` | Move row cursor |
| `Enter` | Open Detail (watchlist) / add (catalog) |
| `r` | Refresh |
| `✕` (click) | Remove watchlist row |

The `Flickable` never eats these — `PanelKeyCatcher` runs `Keys.BeforeItem`.

## Install

From a git URL (recommended):

```bash
omarchy plugin add https://github.com/HACK3RRABBIT/omarchy-chand --enable
omarchy bar move io.github.hack3rrabbit.chand --section right
```

Or clone the repo and add it from disk:

```bash
git clone https://github.com/HACK3RRABBIT/omarchy-chand
omarchy plugin add ./omarchy-chand --enable
omarchy bar move io.github.hack3rrabbit.chand --section right
```

## Remove

```bash
omarchy plugin remove io.github.hack3rrabbit.chand
```

Then, if you had moved it on the bar, nothing else is needed — removing the
plugin cleans up its bar entry.

## Requirements

External commands used at runtime: `curl` and `jq` (both preinstalled on
Omarchy). No other dependencies; the plugin installs nothing system-wide.

## IPC

```bash
omarchy-shell io.github.hack3rrabbit.chand toggle   # open / close
omarchy-shell io.github.hack3rrabbit.chand open
omarchy-shell io.github.hack3rrabbit.chand close
omarchy-shell io.github.hack3rrabbit.chand refresh
```

## Settings

Persisted to the widget's inline `shell.json` entry (via `updateEntryInline`),
which also mirrors `~/.config/omarchy/chand.json`-style fields:

```json
{ "primary": "price_dollar_rl", "symbols": ["price_dollar_rl", "price_eur", "price_aed", "geram18", "sekee", "gerami", "crypto-tether", "crypto-bitcoin"], "range": "1m", "compact": false }
```

## Repo layout

```
manifest.json        plugin contract (id io.github.hack3rrabbit.chand)
BarWidget.qml        bar pill + IPC entry point (loads Panel.qml)
Panel.qml            watchlist / detail / catalog surfaces
ChartCanvas.qml      Canvas area chart (paints inside its bounds)
Model.js             catalog, settings, formatting, Jalali dates
scripts/fetch-chand  curl + jq fetcher (current / history)
LICENSE              MIT
```

## Notes on the catalog

Every key was verified present on a live `ajax.json` payload. The spec's
suggested Emami-coin key `sekkeh` does **not** exist in the live data; the real
Emami (Imami) coin is `sekee`, and `sekeb` is the Bahar Azadi coin. This plugin
maps honestly to avoid a mislabeled, duplicated row:

| Label | Asset | TGJU key |
|-------|-------|----------|
| EMAMI | Emami coin | `sekee` |
| AZADI | Azadi coin | `sekeb` |
| ½AZ | Half Azadi | `nim` |
| ¼AZ | Quarter Azadi | `rob` |
| 1G | Gold 1g coin | `gerami` |

## License

MIT © HACK3RRABBIT
