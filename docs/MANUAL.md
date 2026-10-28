# Advanced_Backtester.jl — Complete User Manual

**File:** `Backtest/Advanced_Backtester.jl` (module `Advanced_Backtester`)
**Engine:** vendored Fastback v0.14.0 (`Backtest/vendor/Fastback.jl`)
**Helpers:** `Backtest/trading_utils.jl` (`open_position!`, `close_position!`)
**Companions:** `MANUAL.md` (helper reference), `BACKTEST_SYTHESIS.md` (design spec),
`INDICATOR_LIST.md` (every closes-only signature), `SETUP_MANUAL.md` (workspace setup)

One macro — `@backtest` — turns *precompute line(s) + signal block* into a full,
rigorous backtest: account, bar loop, flatten, equity/position/signal/drawdown vectors,
stats. No TradingView-style hand-waving: closed-bar signals, warmup, NaN guards,
every-bar marks, adverse slippage, fees, final flatten.

---

## Table of contents

1. [Mental model](#1-mental-model)
2. [Prerequisites & loading](#2-prerequisites--loading)
3. [Minimal example (3 steps)](#3-minimal-example-3-steps)
4. [What the macro automates](#4-what-the-macro-automates)
5. [Names inside the signal block](#5-names-inside-the-signal-block)
6. [Keyword reference (all optional)](#6-keyword-reference-all-optional)
7. [The result object (`BacktestResult`)](#7-the-result-object-backtestresult)
8. [`backtest_stats` reference](#8-backtest_stats-reference)
9. [Signal cookbook (copy-paste patterns)](#9-signal-cookbook-copy-paste-patterns)
10. [Warmup, guards & lag — how they actually work](#10-warmup-guards--lag--how-they-actually-work)
11. [Drawdown vector (`dd_t`/`dd_v`)](#11-drawdown-vector-dd_tdd_v)
12. [Execution models: `fill=:close` vs `:next_open`](#12-execution-models-fillclose-vs-next_open)
13. [Shorts, pyramiding & brackets](#13-shorts-pyramiding--brackets)
14. [Data loading & validation](#14-data-loading--validation)
15. [Multi-run workflows (sweeps, compare, long/short legs)](#15-multi-run-workflows-sweeps-compare-longshort-legs)
16. [Plotting & persisting](#16-plotting--persisting)
17. [Demystifying warnings & errors](#17-demystifying-warnings--errors)
18. [Pitfall checklist](#18-pitfall-checklist)
19. [FAQ](#19-faq)
20. [File map](#20-file-map)

---

## 1. Mental model

```
┌──────────────┐   ┌───────────────────┐   ┌────────────────────┐
│  PRECOMPUTE  │──▶│     @backtest     │──▶│  ANALYZE           │
│ ordinary     │   │  account + loop   │   │  backtest_stats /  │
│ Julia code   │   │  + flatten +      │   │  plot / CSV / JSON │
│ (runs first) │   │  vectors          │   │                    │
└──────────────┘   └───────────────────┘   └────────────────────┘
```

* **Precompute** runs *before* the macro call, in your scope: `r = rsi(closes; n=14)`.
  Whole-vector math is fine — no trading happens yet.
* **`@backtest(dts, closes, begin ... end; kwargs...)`** builds a fresh account,
  loops every bar (`signal[i-1]` → fill at bar `i`), flattens at the end, returns
  a `BacktestResult`.
* **Analyze** with `backtest_stats(res)`, `res.eq_t/res.eq_v`, `res.dd_t/res.dd_v`, plots.

The golden rule: **decide on closed bar `i-1`, get filled on bar `i`.**
`rsi[i]` already contains bar `i`'s close — reading it while executing at
`closes[i]` is peeking. The macro's guard/lag machinery exists to make `i-1`
the path of least resistance.

---

## 2. Prerequisites & loading

```julia
using Fastback, Dates          # required in YOUR scope (macro emits qualified
                               # Advanced_Backtester.* calls, but Account,
                               # update_marks!, equity, DateTime resolve via caller)
using Indicators               # only if your precompute uses it
using Statistics               # only for your own analysis (mean/std/median)

include(joinpath(@__DIR__, "Advanced_Backtester.jl"))
using .Advanced_Backtester     # brings @backtest, BacktestResult, backtest_stats,
                               # open_position!, close_position! into scope
```

Run with the vendored engine project:

```bash
julia --project="Backtest/vendor/Fastback.jl" path/to/your_script.jl
```

First run needs network once (`Pkg.instantiate()` pulls EnumX/Format/RiskPerf/Tables);
after that the checked-in `Manifest.toml` makes runs offline.

> `using .Advanced_Backtester` also re-exports the raw helpers `open_position!` /
> `close_position!` (they live in `trading_utils.jl`, included by the module).
> See `MANUAL.md` for their standalone reference.

---

## 3. Minimal example (3 steps)

```julia
using Fastback, Dates
include(joinpath(@__DIR__, "Advanced_Backtester.jl"))
using .Advanced_Backtester

# --- inputs: same-length vectors, dts strictly increasing, closes all finite ---
# dts::Vector{DateTime}, closes::Vector{Float64}

# 1. precompute (ordinary code)
sma(v, n) = [i < n ? NaN : sum(v[i-n+1:i]) / n for i in eachindex(v)]
fast = sma(closes, 5)
slow = sma(closes, 20)

# 2. one macro call = account + loop + flatten + vectors
res = @backtest(dts, closes, begin
    if fast[i-2] <= slow[i-2] && fast[i-1] > slow[i-1]
        long!()    # open long at default size + adverse slippage
    elseif fast[i-2] >= slow[i-2] && fast[i-1] < slow[i-1]
        flat!()    # close everything at adverse slippage
    end
end; deposit=10_000.0, notional=1_000.0)

# 3. analyze
println(res)              # BacktestResult(bars=201, warmup=22, trades=14, final_equity=9901.97)
st = backtest_stats(res)
println(st)               # final_equity / total_return / max_drawdown(+idx) /
                          # sharpe / n_trades / win_rate / warmup
```

Working end-to-end scripts in this folder:

| Script | What it shows |
|---|---|
| `demo_advanced.jl` | SMA(5/20) on `sample_candles.csv` + stats + equity CSV |
| `demo_side_by_side.jl` | Same signal, `fill=:close` vs `:next_open` — the lookahead-bias overlay |
| `demo_extended_ohlc_entropy_obi.jl` | OHLC + ATR + entropy + OBI signal, `guard=`, `track=`, next-open fills |
| `example_sma_cross.jl` | Bare-engine version without the macro (teaches the loop the macro hides) |

---

## 4. What the macro automates

Given `@backtest(dts, closes, SIGNAL; kwargs...)`, the expansion:

1. **Validates inputs** — equal lengths, ≥ 1 bar, strictly increasing `dts`,
   all-finite `closes` (and `opens` if given). Fail-fast `ArgumentError`.
2. **Runs `precompute=quote ... end`** if given (spliced before account setup,
   macro-local vars — prefer precomputing outside; §6).
3. **Creates one fresh account** — `Account(; funding, base_currency=CashSpec(:USD),
   broker=FlatFeeBroker(pct=fee_pct))`, `deposit!(acc, usd, deposit)`,
   `register_instrument!(acc, spot_instrument(symbol, symbol, :USD))`.
   Fresh per call — a poisoned account never leaks into the next run.
4. **Computes `WARMUP`** — `:auto` (default) scans every `i`-lagged array your
   block reads and takes longest leading-NaN/Inf run + 2 (slowest-n-plus-2 rule);
   explicit `warmup=N` overrides. Validates `1 ≤ WARMUP < bar count`.
5. **Derives the guard chain** — `i > max(WARMUP, LAG)` plus one `isfinite`
   conjunct per `ARR[i-k]` read (`all(isfinite, ...)` for `:` rows) plus your raw
   `guard=` exprs. Your block runs only when `__bt_ok__` is true. (§10)
6. **Loops every bar** — `update_marks!` unconditionally (even no-trade bars),
   computes fill reference (`price` = `closes[i]`, or `opens[i]` for `:next_open`),
   defines `long!/short!/flat!` closures, runs your block, records
   `sig_v/eq_t/eq_v/pos_v` + feeds the drawdown collector.
7. **Flattens** — `close_position!` at the last bar + one post-flatten equity
   point (so `eq_t/eq_v` have `N+1` points for `N` bars; `pos_v/sig_v` have `N`).
8. **Returns `BacktestResult`** with vectors + handles + `warmup/lag/initial_cash`.

What it does **not** do: multi-account portfolios (one account per call — run the
macro N times and compare), order-book simulation, intrabar fills, live trading.

---

## 5. Names inside the signal block

Do **not** predefine these — the loop owns them:

| Name | Meaning |
|---|---|
| `i` | Loop counter over `eachindex(dts)`. Read signals at `i-1` (or `i-2` for crosses). |
| `dt` | Bar timestamp `dts[i]`. |
| `price` | Execution reference `closes[i]` (or `opens[i]` under `fill=:next_open`, §12). |
| `acc, inst, usd` | Account, instrument, base-cash handle (for raw helper calls). |
| `WARMUP` | Warmup actually used (handy for your own extra logic, e.g. regime median over `WARMUP:end`). |
| `long!()` | `open_position!(...; side=:long, notional/quantity, fill_price=px*(1+bps), allow_add, allow_reverse, mark_first=false)`. No-op if already long (unless `allow_add=true`). |
| `short!()` | Mirror with `px*(1-bps)`. Needs `funding=:margined`; no-op if long unless `allow_reverse=true`. |
| `flat!()` | `close_position!(...; fill_price=px*(1-bps), mark_first=false)`. No-op if flat. |
| `open_position!` / `close_position!` | Raw helpers for custom sizing, partial exits (`fraction=`), brackets (`take_profit/stop_loss`). Remember `mark_first=false` (loop already marked) and adverse `fill_price`. |

⚠️ **Collision warning.** This is a scope-sharing DSL (whole-body `esc`): your
signal code shares scope with the loop. Don't name your own variables `eq_t`,
`eq_v`, `pos_v`, `sig_v`, `acc`, `inst`, `usd`, `dt`, `price`, `i`, `WARMUP`,
`long!`/`short!`/`flat!` — macro-owned names use the `__bt_` prefix precisely to
leave the documented names for you, but yours must not pre-exist either.

---

## 6. Keyword reference (all optional)

| Kwarg | Default | Meaning & notes |
|---|---|---|
| `deposit` | `10_000.0` | Starting cash (Float64). Recorded as `res.initial_cash`. |
| `funding` | `:fullyfunded` | `:fullyfunded` (long-only) or `:margined` (enables `short!`). Accepts symbols, strings, or `AccountFunding` values. |
| `fee_pct` | `0.001` | Broker fee per fill (0.001 = 10 bps). Set once on the account — never per trade. `is_maker` tier only matters for raw helper calls. |
| `symbol` | `:ABC` | Instrument symbol (`spot_instrument(symbol, symbol, :USD)`). Cosmetic for single-asset runs. |
| `notional` | `1_000.0` | Dollar size per `long!/short!` (buys `notional/fill_price` units). Ignored when `quantity` is given. |
| `quantity` | — | Share count per `long!/short!`. Takes precedence over `notional` when present. |
| `slippage_bps` | `10.0` | Adverse slip, multiplicative: buys `px*(1+bps/1e4)`, sells `px*(1-bps/1e4)`. So `10.0` ≈ `price*1.001 / *0.999`. |
| `allow_reverse` | `false` | `true`: `short!()` while long (or `long!()` while short) flips in one call. `false`: opposite-direction call no-ops — `flat!()` first. |
| `allow_add` | `false` | `true`: repeated same-direction `long!()` pyramids. `false`: re-entry while exposed no-ops (loop-safety). |
| `warmup` | `:auto` | `:auto` = slowest-leading-NaN-run + 2 over every array your block reads (§10). Integer overrides (e.g. `warmup=40`). Must satisfy `1 ≤ WARMUP < N`. |
| `drawdown_mode` | `:percentage` | `:percentage` → `dd_v` fractions in `[-1, 0]`; `:pnl` → currency amounts `≤ 0`. Accepts symbols, strings, or `DrawdownMode` values. (§11) |
| `drawdown_period` | `Millisecond(0)` | Collector throttle. `Millisecond(0)` ⇒ every bar (1:1 with `eq`). Larger (e.g. `Day(1)`) downsamples `dd_t/dd_v`. Must be a `Dates.Period`. (§11) |
| `guard` | — | Extra raw exprs ANDed with the auto guards, e.g. `guard=(atr[i-1] > 0.0,)`. **Not** `isfinite`-wrapped — write the full condition. A `Tuple`/`Vector` spreads; a single expr works too. Contributes to lag detection. |
| `track` | — | `sig_v` overlay source. Default: first auto-derived `ARR[i-k]` read. Override e.g. `track=obi[i-1]` to plot imbalance instead. Non-`Number` results become `NaN`. Contributes to lag detection. |
| `fill` | `:close` | `:close` → signal `i-1`, fill at `closes[i]`. `:next_open` → fill at `opens[i]` (requires `opens=`). (§12) |
| `opens` | — | Opens vector (same length, all finite). Required iff `fill=:next_open`. `opens[i]` reads are exempt from the same-bar lookahead warning. |
| `precompute` | — | `precompute=quote ... end` spliced before account setup (macro-local). Prefer precomputing outside for readability/debugging. |

Unknown kwargs throw at macro-expansion time (`@backtest: unknown kwarg`), so
typos like `drawdow_mode` fail loudly instead of silently using defaults.

**Sizing rule of thumb:** `notional` (default) auto-scales with price — `$1,000`
buys 10 shares at $100, 20 at $50. `quantity` is for fixed-share experiments.

---

## 7. The result object (`BacktestResult`)

```julia
struct BacktestResult
    eq_t::Vector{DateTime}      # N+1 : every bar + post-flatten point
    eq_v::Vector{Float64}       # N+1 : equity(acc, usd) per bar + post-flatten
    pos_v::Vector{Float64}      # N   : get_position(acc, inst).quantity per bar
    sig_v::Vector{Float64}      # N   : track expr (or first lagged read), NaN when guard fails
    dd_t::Vector{DateTime}      # N+1 by default; shorter if drawdown_period > 0
    dd_v::Vector{Float64}       # drawdown per collector semantics (§11)
    drawdown_mode::Symbol       # :percentage | :pnl (what dd_v means)
    drawdown_period::Dates.Period
    acc                        # live account handle (trades, positions, cash)
    inst                       # instrument handle
    usd                        # base-cash handle
    trades::Vector             # collect(acc.trades) — Trade objects
    warmup::Int                # WARMUP actually used
    lag::Int                   # deepest i-k lag found in block+guard+track
    initial_cash::Float64      # deposit
end
```

* `show` prints `BacktestResult(bars=201, warmup=22, trades=14, final_equity=9901.97)`
  (`bars` = `length(eq_t)` = N+1).
* **Lengths:** `eq_t/eq_v` N+1; `pos_v/sig_v` N; `dd_t/dd_v` N+1 at default period,
  shorter when downsampled — always plot `dd_v` vs `dd_t`, never vs `eq_t`.
* `sig_v` records `__tofloat(track)` when the guard passes, else `NaN` — it's a
  coverage map: leading `NaN`s show warmup/guard inaction.
* Old 11-field positional construction (pre-drawdown) still works via a
  backwards-compatible outer constructor (fills empty `:percentage`/`Millisecond(0)` vectors).
* `acc.trades` fields per trade: `pos_qty`, `fill_price`, `pos_price`,
  `fill_qty`, `realized_qty`. Win logic in `backtest_stats`:
  `sign(pos_qty) * (fill_price - pos_price) / abs(pos_price) > 0`.
  Note: Fastback may split one logical round-trip into multiple `Trade` rows —
  `n_trades` counts fills, not round-trips.

---

## 8. `backtest_stats` reference

```julia
st = backtest_stats(res; periods_per_year=252)
```

| Field | Math | Notes |
|---|---|---|
| `final_equity` | `eq_v[end]` | Post-flatten. Compare vs `initial_cash`/`eq_v[1]`. |
| `total_return` | `eq[end]/eq[1] - 1` | On marked equity incl. fees/slippage. |
| `max_drawdown` | `max((peak-v)/peak)` | Positive fraction (0.05 = −5%). |
| `max_drawdown_idx` | argmax | Index into `eq_t/eq_v` (N+1-based). Under default period, same index hits `dd_t/dd_v`. |
| `sharpe` | `√ppy · mean/std` of log-returns | Annualized; `NaN` if < 2 finite returns or zero variance. Set `periods_per_year` to bar frequency (252 daily, 8760 hourly, …). |
| `n_trades` | `length(trades)` | Fill count, not round-trips. |
| `win_rate` | wins / n | Sign-aware per-trade return (§7); `NaN` if no trades. |
| `warmup` | `res.warmup` | Echo for sweep tables. |

`backtest_stats` derives maxDD from full-resolution `eq_v` — always authoritative,
even when `drawdown_period` downsampled `dd_v` for display.

---

## 9. Signal cookbook (copy-paste patterns)

Every body below is the **inside** of the macro's `begin ... end` — guards are
automatic (but read §10 to know what they do). Precompute lines run **before**
the macro call. All bodies trade at bar `i` on reads at `i-1`.

### Pattern A — Threshold (RSI, ROC, momentum)

```julia
r = rsi(closes; n=14)   # or momentum(closes; n=12), roc(...), kst(...)
res = @backtest(dts, closes, begin
    r[i-1] < 30 && long!()
    r[i-1] > 70 && flat!()
end; deposit=10_000.0)
```

### Pattern B — Crossover (needs `i-2` + `i-1`)

```julia
ef = ema(closes; n=9); es = ema(closes; n=21)
res = @backtest(dts, closes, begin
    if ef[i-2] <= es[i-2] && ef[i-1] > es[i-1]
        long!()
    elseif ef[i-2] >= es[i-2] && ef[i-1] < es[i-1]
        flat!()
    end
end; deposit=10_000.0)
```

MACD is the same shape on a matrix (`mac[i-2,1]` vs `mac[i-2,2]` →
`mac[i-1,1]` vs `mac[i-1,2]`; `mac = macd(closes)` gives `[MACD Signal Hist]`):

```julia
m = macd(closes; nfast=12, nslow=26, nsig=9)
res = @backtest(dts, closes, begin
    m[i-1,1] > m[i-1,2] && m[i-2,1] <= m[i-2,2] && long!()
    m[i-1,1] < m[i-1,2] && m[i-2,1] >= m[i-2,2] && flat!()
end; deposit=10_000.0)
```

Matrix rows with `:` get `all(isfinite, ...)` guards automatically.

### Pattern C — Bands (Bollinger / MLR / Donchian-style)

```julia
b = bbands(closes; n=20, sigma=2.0)   # [lower mid upper]
res = @backtest(dts, closes, begin
    closes[i-1] > b[i-1,3] && long!()    # breakout: buy above upper
    closes[i-1] < b[i-1,2] && flat!()    # exit below mid
end; deposit=10_000.0)
# mean-reversion flip: buy closes[i-1] < b[i-1,1], exit closes[i-1] > b[i-1,3]
```

### Pattern D — Gate (regime filter + entry)

```julia
sl = mlr_slope(closes; n=20)
r  = rsi(closes; n=14)
res = @backtest(dts, closes, begin
    sl[i-1] > 0 && r[i-1] < 30 && long!()   # both guarded automatically
    r[i-1] > 70 && flat!()
end; deposit=10_000.0)
```

### Pattern E — OHLC-exogenous signals + raw guard + custom overlay

Any same-length vector can drive the signal (ATR, entropy, OBI, sentiment,
ML scores) — the macro guards every `ARR[i-k]` it finds, `closes` stays the
execution series:

```julia
# atr, entropy, obi precomputed as in demo_extended_ohlc_entropy_obi.jl
res = @backtest(dts, closes, begin
    breakout = closes[i-1] > highs[i-2] - 0.2*atr[i-1]
    trending = entropy[i-1] < 0.85
    bid_bias = obi[i-1] > 0.15
    if breakout && trending && bid_bias
        long!()
    elseif entropy[i-1] > 0.95 || obi[i-1] < -0.25
        flat!()
    end
end; deposit=10_000.0, notional=1_000.0,
     opens=opens, fill=:next_open,
     guard=(atr[i-1] > 0.0,),   # raw extra condition, ANDed, lag-aware
     track=obi[i-1])            # sig_v shows imbalance, not the first read
```

### Two canonical retail strategies (Indicators.jl-native)

**Connors RSI(2) mean-reversion (long-only, daily):** buy the washout in an
uptrend, sell the bounce (~3-bar holds):

```julia
r2 = rsi(closes; n=2); sma5 = sma(closes; n=5); sma200 = sma(closes; n=200)
res = @backtest(dts, closes, begin
    r2[i-1] < 10 && closes[i-1] > sma200[i-1] && closes[i-1] < sma5[i-1] && long!()
    closes[i-1] > sma5[i-1] && flat!()
end; deposit=10_000.0)
# selective variant: r2[i-1] < 5. Short mirror needs funding=:margined.
```

**MACD(12,26,9) crossover + SMA(50) trend filter:**

```julia
m = macd(closes; nfast=12, nslow=26, nsig=9); f50 = sma(closes; n=50)
res = @backtest(dts, closes, begin
    m[i-1,1] > m[i-1,2] && m[i-2,1] <= m[i-2,2] && closes[i-1] > f50[i-1] && long!()
    m[i-1,1] < m[i-1,2] && m[i-2,1] >= m[i-2,2] && flat!()
end; deposit=10_000.0)
```

---

## 10. Warmup, guards & lag — how they actually work

Three cooperating mechanisms, all derived at macro-expansion time from your
block (+ `guard=` + `track=`):

**LAG** — deepest literal `i-k` in block/guard/track (`__max_lag`; any lagged
read forces `lag ≥ 1` so `i ≥ 2`). Available after the run as `res.lag`.
`i-2` reads can never `BoundsError` on bars 1–2 because the guard
`i > max(WARMUP, LAG)` blocks them.

**WARMUP** — `:auto` (default): for every `Symbol`-headed array your block reads
(`__leading_bad` counts leading non-finite entries), `WARMUP = max + 2`
(slowest-n-plus-2). Empty (no reads found) → 2. Explicit `warmup=N` overrides.
Validated: `≥ 1`, and `< bar count` (else "nothing left to trade on").
Available in-block as `WARMUP` and after as `res.warmup` / `st.warmup`.

**Guard chain** — single `&&` chain evaluated as `__bt_ok__` before your block:

```
i > max(WARMUP, LAG) && isfinite(READ₁) && … && all(isfinite, MATRIXROW) && GUARD₁ && …
```

* Scalar reads → `isfinite(...)`; whole-row `:` reads → `all(isfinite, ...)`.
* `guard=` exprs are spliced **raw** (never wrapped) — write complete conditions.
* When `__bt_ok__` is false your block is skipped and `sig_v` gets `NaN`.

**Why both WARMUP and isfinite?** Different failures: `i > WARMUP` catches
*unstable-but-finite* startup values (an EMA seeded on 3 bars returns a finite
number that means nothing); `isfinite` catches `NaN` (incomplete window —
`rsi(14)[1:14]` are `NaN`) and `Inf` (divide-by-zero). Use `isfinite`, never
`!isnan` (`!isnan(Inf) == true`).

**Warmup bases are auto-derived refs only** — `guard=`/`track=` arrays don't
extend the auto-warmup scan (they do extend lag). If your filter needs a longer
run-up than your signal (e.g. `hurst(n=100)` gate on an `rsi(14)` entry), either
reference it in the block body (not just `guard=`) or set `warmup=` explicitly.

---

## 11. Drawdown vector (`dd_t`/`dd_v`)

Every bar's `equity(acc, usd)` is fed through Fastback's `drawdown_collector`
(`Backtest/vendor/Fastback.jl/src/collectors/drawdown.jl`) into `res.dd_t/dd_v`.
It tracks running `max_equity`; each point is `min(0, equity - peak)` scaled by mode.

| `drawdown_mode` | `dd_v` semantics | Example |
|---|---|---|
| `:percentage` (default) | Fractions in `[-1, 0]` | `-0.05` = −5% underwater |
| `:pnl` | Currency amounts `≤ 0` | `-250.0` = $250 below peak |

```julia
res = @backtest(dts, closes, begin ... end)                              # % mode
res = @backtest(dts, closes, begin ... end; drawdown_mode=:pnl)          # cash mode
plot(res.dd_t, res.dd_v)   # ALWAYS dd_t as x — see period note below
```

**`drawdown_period` (default `Millisecond(0)`):** the collector's throttle
(`emit iff dt - last_emit ≥ period`). `Millisecond(0)` emits every call → one
point per bar + one post-flatten point, 1:1 with `eq_t/eq_v`. Any larger period
(e.g. `Day(1)`) **downsamples**: `dd_t/dd_v` get shorter than `eq_t/eq_v`, the
post-flatten point appears only if the last gap ≥ period, and intra-period
troughs vanish from the vector. Keep `Millisecond(0)` for every data frequency
(minutes, hours, days — it's frequency-agnostic); use larger periods only to
slim charts on 100k+ bar runs, and then take maxDD stats from
`backtest_stats(res)` (full-resolution `eq_v`), never from the downsampled vector.
Non-`Dates.Period` values throw `ArgumentError`.

---

## 12. Execution models: `fill=:close` vs `:next_open`

| | `fill=:close` (default) | `fill=:next_open` |
|---|---|---|
| Signal | `closes[i-1]` (your block) | same |
| Fill price | `closes[i]` (`price`) | `opens[i]` |
| Requires | nothing | `opens=` vector (same length, all finite) |
| Best for | Screening, research, indicator comparison | Trust-live validation ("can I actually get this price?") |

```julia
# quick research
res = @backtest(dts, closes, begin ... end; deposit=10_000.0)
# publishable check — signal on close i-1, fill at open i + adverse slip
res = @backtest(dts, closes, begin ... end; opens=opens, fill=:next_open)
```

The `close − next_open` equity gap visualizes lookahead bias: same signals,
different fill prices. Without `opens`, `:close` fills at the wished price;
with `opens + :next_open`, the fill models reality. `fill=:next_open` without
`opens=` fails loudly at expansion time. `opens[i]` reads are exempt from the
same-bar lookahead warning. See `demo_side_by_side.jl`.

---

## 13. Shorts, pyramiding & brackets

```julia
# long/short flip — needs margined funding + allow_reverse
res = @backtest(dts, closes, begin
    m[i-1,1] > m[i-1,2] && m[i-2,1] <= m[i-2,2] && short!()   # or long!()
    m[i-1,1] < m[i-1,2] && m[i-2,1] >= m[i-2,2] && flat!()
end; funding=:margined, allow_reverse=true)

# pyramiding — scale in on repeated signals
res = @backtest(dts, closes, begin
    breakout[i-1] && long!()
    stop[i-1] && flat!()
end; allow_add=true)

# custom sizing / partials / brackets — raw helpers (mark_first=false!
# inside the block; adverse fill_price explicit)
res = @backtest(dts, closes, begin
    if r[i-1] < 30
        open_position!(acc, inst, dt, price; side=:long, notional=2_000.0,
            fill_price=price*1.001, mark_first=false)
    elseif r[i-1] > 70
        close_position!(acc, inst, dt, price; fraction=0.5,
            fill_price=price*0.999, mark_first=false)   # take half
    end
    # brackets: open_position!(...; take_profit=price*1.05, stop_loss=price*0.97, ...)
end; deposit=10_000.0)
```

Shorts on the default `:fullyfunded` account throw `ShortNotAllowed` — that's
Fastback telling you to opt into margin, not a macro bug.

---

## 14. Data loading & validation

CSV shape (see `sample_candles.csv`: 200 hourly bars + header): `t,o,h,l,c`
(`v` allowed, ignored). Accepted timestamp formats: `yyyy-mm-ddTHH:MM:SS`,
`yyyy-mm-dd HH:MM:SS`, `yyyy-mm-dd`.

```julia
function load_candles(path)
    dts = DateTime[]; opens = Float64[]; closes = Float64[]
    fmts = (dateformat"yyyy-mm-ddTHH:MM:SS", dateformat"yyyy-mm-dd HH:MM:SS",
            dateformat"yyyy-mm-dd")
    open(path) do io
        header = split(strip(readline(io)), ',')
        idx = Dict(Symbol(strip(h)) => i for (i, h) in enumerate(header))
        for line in eachline(io)
            isempty(strip(line)) && continue
            f = split(strip(line), ',')
            dt = nothing
            for fmt in fmts
                try; dt = DateTime(strip(f[idx[:t]]), fmt); break; catch; end
            end
            dt === nothing && error("unparseable timestamp")
            push!(dts, dt); push!(opens, parse(Float64, f[idx[:o]]))
            push!(closes, parse(Float64, f[idx[:c]]))
        end
    end
    return dts, opens, closes
end
```

The macro validates at runtime: equal lengths, non-empty, strictly increasing
`dts` ("not strictly increasing at bar k"), all-finite `closes`/`opens`.
A poisoned feed throws `ArgumentError` before any account is touched.

---

## 15. Multi-run workflows (sweeps, compare, long/short legs)

One `@backtest` = one account. Portfolios are N sequential calls:

```julia
# parameter sweep
for n in (5, 10, 20)
    rsi_n = rsi(closes; n=n)
    res = @backtest(dts, closes, begin
        rsi_n[i-1] < 30 && long!()
        rsi_n[i-1] > 70 && flat!()
    end; deposit=10_000.0)
    st = backtest_stats(res)
    println("n=$n sharpe=$(round(st.sharpe; digits=3)) dd=$(round(100*st.max_drawdown; digits=2))% trades=$(st.n_trades)")
end

# research vs trust-live on the same signal
res_close = @backtest(dts, closes, begin ... end; deposit=10_000.0)
res_open  = @backtest(dts, closes, begin ... end; opens=opens, fill=:next_open)

# long leg + short leg, compared
res_long  = @backtest(dts, closes, begin ... end; deposit=10_000.0)
res_short = @backtest(dts, closes, begin ... end; funding=:margined, allow_reverse=true)
```

For true multi-asset / multi-account simulation in one loop, drop to the bare
engine (`trading_utils.jl` + `example_sma_cross.jl` skeleton, `MANUAL.md` §2):
create N `Account`s yourself and call `open_position!(acc_k, ...)` per leg.

---

## 16. Plotting & persisting

```julia
# base choice: no extra deps — dump vectors, plot elsewhere
open("equity.csv", "w") do io
    for v in res.eq_v; println(io, v); end
end
open("drawdown.csv", "w") do io
    for (t, v) in zip(res.dd_t, res.dd_v); println(io, "$t,$v"); end
end

# in-Julia (needs Plots.jl in your env — NOT vendored)
using Plots
plot(res.eq_t, res.eq_v, label="equity")
plot(res.dd_t, res.dd_v, label="drawdown", fillrange=0)  # underwater chart
plot(res.eq_t[1:end-1], res.pos_v, label="exposure")
plot(res.eq_t[1:end-1], res.sig_v, label="signal")
```

`run_sma_job.jl` shows the minimal no-dependency JSON writer pattern if you need
`results.json` for a web UI. `demo_*.jl` scripts write `*_equity.csv` /
`demo_fill_*.csv` the same way.

---

## 17. Demystifying warnings & errors

| Message | Meaning | Fix |
|---|---|---|
| `no ARR[i-k] reads detected — no finiteness guard emitted` | Block has no index-`i` array reads (constants? closed-over scalar?) | Index precomputed vectors at `i-1`, or pass `guard=(isfinite(x[i-1]),)` |
| `same-bar read X detected — trading index-i values at closes[i] is lookahead` | You read `ARR[i]` while filling at `closes[i]` | Use `i-1` (`opens[i]` with `:next_open` is exempt) |
| `unknown kwarg` | Typo (`drawdow_mode`) or unsupported knob | Check §6 spelling; kwargs need `;` before them |
| `fill must be :close or :next_open` | Bad `fill=` | One of the two symbols |
| `fill=:next_open requires opens=...` | Missing opens leg | Pass `opens=opens` |
| `funding/drawdown_mode must be …` | Bad enum kwarg | See §6 accepted forms (symbol/string/engine value) |
| `drawdown_period must be a Dates.Period` | e.g. `drawdown_period=7` | `Day(1)`, `Hour(4)`, `Millisecond(0)` |
| `warmup must be ≥ 1` / `warmup ≥ bar count` | Explicit `warmup=` out of range | Lower it (or drop to `:auto`) |
| `dts (...) and closes (...) differ` / `not strictly increasing at bar k` / `must be all finite` | Feed problem | Fix CSV/loader (§14) |
| `ShortNotAllowed` (Fastback) | `short!()` on `:fullyfunded` | `funding=:margined` |
| `UndefVarError` inside block | You referenced a name that exists neither in your scope nor the loop's (§5) | Check spelling; precompute before the call |
| Zero trades | Guard never passes (warmup too long? thresholds never crossed? wrong vector in `isfinite`?) | Print `findfirst(isfinite, r)` vs `res.warmup`; print `res.sig_v` coverage |

---

## 18. Pitfall checklist (read before trusting any result)

1. **Same-bar signal+fill** — `v[i]` → `closes[i]` is lookahead. Always `i-1 → i` (§12 for the stronger `:next_open` variant).
2. **`run*` with `cumulative=true`** — expanding window leaks regime; backtests want `cumulative=false` (see `INDICATOR_LIST.md` legend).
3. **Under-warmup** — over-warmup discards bars (cheap); under-warmup fabricates trades. When in doubt, explicit `warmup=` higher or trust `:auto`.
4. **No friction** — always keep `fee_pct` + `slippage_bps` on. Frictionless Sharpe 3.0s die live.
5. **Unflattened tail** — the macro flattens for you; bare-engine loops must `close_position!` after the loop (`MANUAL.md` §2).
6. **Marking** — the macro marks every bar; if you go bare-engine, `update_marks!` every bar (even no-trade bars) and use `mark_first=false` in helpers.
7. **Opposite-direction trap** — default `allow_reverse=false` silently no-ops the flip; `flat!()` first or opt in.
8. **Silent no-pyramid** — default `allow_add=false` ignores repeat entries; opt in only to scale in.
9. **Downsampled drawdown** — `drawdown_period > 0` shortens `dd_v`; stats stay exact via `eq_v`, plots must use `dd_t`.
10. **`sig_v` ≠ position** — `sig_v` is the raw overlay value (early `NaN`s = guard), `pos_v` is exposure. Don't confuse a flat overlay with a flat book.
11. **200-bar sample ≠ significance** — `sample_candles.csv` is a smoke test. Any Sharpe/win-rate on it is a pipeline check, not a strategy verdict.

---

## 19. FAQ

**Q: Multiple accounts / portfolio in one call?**
A: Yes — `@backtestN` (see §21, `BacktestN.jl`): N `deposit => strategy`
legs, one shared bar loop, one `fee_pct`/`slippage_bps` for all N accounts.
Single `@backtest` stays one-account; run it N times only when the legs need
different bars/feeds.

**Q: Do I need `opens`?**
A: Only for `fill=:next_open`. For `:close` research runs, `dts + closes` suffice.

**Q: Which period for `drawdown_period`?**
A: `Millisecond(0)` (default) for everything — it's frequency-agnostic. Larger
periods only slim charts on huge runs.

**Q: Why are my `dd_v` values negative / zero?**
A: By design (Fastback convention): `0.0` = at peak, negative = underwater.
`:percentage` gives fractions (`-0.05` = −5%), `:pnl` gives cash.

**Q: `pos_v`/`sig_v` are shorter than `eq_v` — bug?**
A: No: `N` vs `N+1`. The extra equity point is the post-flatten mark.

**Q: Can I use non-Indicators signals (sentiment, ML, order-book)?**
A: Yes — any same-length vector works (§9 Pattern E). The macro guards every
`ARR[i-k]` regardless of provenance.

**Q: OHLC-matrix Indicators (`adx`, `atr`, `stoch`, …)?**
A: They need `[h l c]` matrices (`INDICATOR_LIST.md` "Excluded"). Compute with
whatever lib you like, then feed resulting vectors as exogenous signals —
`closes` stays the execution series.

**Q: Live trading?**
A: No. This is a batch backtester. `service.jl`'s `SequencedDriver` is the
closest thing to a live guard (closed-bar signals, monotonic `dt`), but serving
it is outside this macro's scope.

---

## 20. File map

| File | Role |
|---|---|
| `Advanced_Backtester.jl` | The macro + `BacktestResult` + `backtest_stats` (this manual) |
| `trading_utils.jl` | `open_position!` / `close_position!` loop-safe helpers (`MANUAL.md`) |
| `BACKTEST_SYTHESIS.md` | Design spec the macro implements (§2 setup, §3 loop, §5 vectors, §7 pitfalls) |
| `INDICATOR_LIST.md` | Every closes-only `Indicators.jl` signature + excluded matrix-input list |
| `MANUAL.md` | Helper reference + bare-engine skeleton + strategy sketches |
| `SETUP_MANUAL.md` | Workspace setup, CSV format, guard rails, troubleshooting |
| `demo_advanced.jl` | Runnable SMA demo + stats + equity CSV |
| `demo_side_by_side.jl` | `:close` vs `:next_open` comparison |
| `demo_extended_ohlc_entropy_obi.jl` | Exogenous-signal demo (`guard=`, `track=`, next-open) |
| `example_sma_cross.jl` | Bare-engine loop (no macro) — teaches the hidden machinery |
| `run_sma_job.jl` / `service.jl` | Guarded SaaS-style pipeline (fresh account per job, JSON output) |
| `sample_candles.csv` | 200 hourly bars for smoke tests |
| `vendor/Fastback.jl/` | Vendored engine v0.14.0 (collectors, account, analytics) |
| `BacktestN.jl` | `@backtestN` — N accounts × N strategies, one shared loop (§21) |
| `demo_backtestN.jl` | Runnable 3-leg N-way demo + stats + per-leg equity CSV |

---

## 21. N-way backtests (`@backtestN`)

One call, N accounts, N strategies, one shared bar loop. Returns
`Vector{BacktestResult}` — one per leg, in leg order.

```julia
res = @backtestN(dts, closes,
    10_000.0 => begin
        if fast[i-2] <= slow[i-2] && fast[i-1] > slow[i-1]
            long!()
        elseif fast[i-2] >= slow[i-2] && fast[i-1] < slow[i-1]
            flat!()
        end
    end,
    25_000.0 => fast[i-1] > slow[i-1] ? long!() : (fast[i-1] < slow[i-1] ? flat!() : nothing),
    50_000.0 => begin
        if med[i-2] <= slow[i-2] && med[i-1] > slow[i-1]
            long!()
        elseif med[i-2] >= slow[i-2] && med[i-1] < slow[i-1]
            flat!()
        end
    end => (notional=2_000.0,);
    fee_pct=0.001, slippage_bps=10.0)

backtest_stats.(res)   # stats per account
plot(res[1].eq_t, res[1].eq_v)
```

**Leg shape:** `deposit => strategy` or `deposit => strategy => (kw=…)`.
Strategies are raw expressions — single line, ternary, `begin…end`, `if`
chains — no brackets required. The per-leg tuple overrides that leg only:
`funding, symbol, notional, quantity, allow_reverse, allow_add, warmup,
guard, track`. Everything else (`fee_pct`, `slippage_bps`, `fill`, `opens`,
drawdown knobs) is shared — one fee schedule for all N accounts, by design.

**DSL per leg:** `acc/inst/usd`, `WARMUP`, `long!/short!/flat!` resolve to
that leg's account (via `let` localization — no rewriting, so arbitrary user
code stays intact). `i/dt/price` are shared: same bar, all legs. Each leg
gets its own guard chain, `:auto` warmup (over the arrays THAT leg reads),
own vectors and its own final flatten.

**Gotchas:** same silent defaults as `@backtest` per leg —
`allow_add=false` (repeat entries no-op unless you opt in), opposite flips
need `allow_reverse=true` or `flat!()` first, shorts need
`funding=:margined`. Overriding a shared-only knob (e.g. `fee_pct`) per leg
throws with the allowed-key list. See `BacktestN.jl` header + `demo_backtestN.jl`.
