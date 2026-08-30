# Chand — Iran free-market rates on the Omarchy bar

A first-party-quality Omarchy Quattro bar widget that shows Iran's free-market
rates in **Toman**, like the iOS app [Chand](https://apps.apple.com/us/app/chand/id1524200188).

- **Bar pill** — `USD  206,200 T  ▲2.33%` (compact mode: `206.2k T ▲2.33%`).
  Colors follow the spec exactly: up `#22c55e`, down `#ef4444`, flat = bar
  foreground. Fetch errors use `Color.urgent`; stale/offline dims to 0.5 with a
  `↺`. Left-click toggles the panel, middle refreshes, right-click toggles
  compact. Click the Detail price to copy it.
  The bar pill always shows **USD only** (the default currency; nothing else
  can be set on the bar). Add gold/crypto/currencies to the panel watchlist.
- **Watchlist** — scrollable list of assets you added; tap a row for Detail
  (and set it as the bar primary), `✕` removes just that row.
- **Detail** — big Toman price, colored Δ% + Δ T, buy/sell (only when both
  exist and differ), range chips (`1D 1W 1Y 5Y All`), an area chart, a Jalali
  from→to summary (high / low / range Δ), and a converter on this screen only.
- **Catalog** — searchable, grouped add screen (Currencies / Gold & coins /
  Crypto). Already-added rows show a checkmark; tap adds and stays open for
  multi-add.

## Data

- **Hybrid, real-time sources** (mirrors the Chand iOS app):
  - **Wallex** `https://api.wallex.ir/v1/markets` — real-time USD (`USDTTMN`),
    crypto (`BTCUSDT`…), gold tokens (`XAUTUSDT`/`PAXGUSDT`), and **all chart
    history** via its klines endpoint (`/v1/udf/history`, 1D–5Y+ daily closes).
    This is the fast, live, accurate path the iPhone Chand app uses.
  - **TGJU** `https://call5.tgju.org/ajax.json` — breadth only: fiat currencies
    (EUR, GBP, AED…) and physical coins (Azadi, Emami, geram18…) that Wallex
    does not list. Daily snapshot, so its change is often 0.
- No ECB / Yahoo / NIMA / SANA. No third-party TGJU proxy.
- USD / crypto / gold tokens: Toman straight from Wallex. TGJU fiat & coins:
  Toman = rial ÷ 10; TGJU crypto (not on Wallex): Toman = `usd × USDTTMN ÷ 1`.
- Polls every 90s; the full watchlist + open detail are fetched each tick and
  merged into the snapshot so rows never blink or reset.
- History cache at `~/.cache/omarchy-chand/history/<key>.jsonl` (append-only,
  capped at 8000 points, Tehran day boundary). Wallex klines backfill real
  ups/downs; TGJU-only assets fall back to the local cache. Offline uses the
  last cached snapshot.
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
omarchy bar move io.github.HACK3RRABBIT.chand --section right
```

Or clone the repo and add it from disk:

```bash
git clone https://github.com/HACK3RRABBIT/omarchy-chand
omarchy plugin add ./omarchy-chand --enable
omarchy bar move io.github.HACK3RRABBIT.chand --section right
```

## IPC

```bash
omarchy-shell io.github.HACK3RRABBIT.chand toggle   # open / close
omarchy-shell io.github.HACK3RRABBIT.chand open
omarchy-shell io.github.HACK3RRABBIT.chand close
omarchy-shell io.github.HACK3RRABBIT.chand refresh
```

## Settings

Persisted to the widget's inline `shell.json` entry (via `updateEntryInline`),
which also mirrors `~/.config/omarchy/chand.json`-style fields:

```json
{ "primary": "price_dollar_rl", "symbols": ["price_dollar_rl", "price_eur", "price_aed", "geram18", "sekee", "gerami", "crypto-tether", "crypto-bitcoin"], "range": "1m", "compact": false }
```

## Repo layout

```
manifest.json        plugin contract (id io.github.HACK3RRABBIT.chand)
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
