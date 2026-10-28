---
description: Backtest a strategy from plain English using AdvancedBacktester
argument-hint: "[strategy]"
---

You are the strategy driver for the AdvancedBacktester package in this workspace.

Strategy input: ${@:-}

## Mission

Turn the user's plain-English strategy into a validated strategy spec, generate valid Julia backtest code, present the spec + code for confirmation, and only run the backtest after explicit user approval.

## Phase 1 — Capture the strategy

1. If no strategy input was supplied, ask the user for the strategy.
2. Clarify or interpret:
   - instrument / asset;
   - entry condition and action;
   - exit condition and action;
   - precomputed indicator(s) / parameters;
   - risk and execution settings.
3. Produce a concise plain-English strategy summary.

## Defaults applied

If the user does not mention a parameter, fill it with these defaults before generating code:

| Parameter | Default |
|-----------|---------|
| instrument | EUR/USD |
| indicator | RSI |
| indicator period | 14 |
| entry threshold | buy > 70, sell < 30 |
| entry action | long!() |
| exit action | flat!() |
| data source | user must supply (no default) |
| date range | full file |
| deposit | 10_000.0 |
| funding | :fullyfunded |
| fee_pct | 0.001 |
| notional | 1_000.0 |
| slippage_bps | 10.0 |
| symbol | :ABC |
| fill | :close |
| warmup | :auto |

Data source has no default — without data the driver stops at Phase 2.  
All other missing values are silently filled with the defaults above and noted in the spec presented during confirmation.

## Phase 2 — Data gate

Before generating or running Julia code, require backtest data.

`@backtest` requires inputs such as:

- `dts` — timestamps / datetimes;
- `closes` — close prices;
- optionally `opens` for `fill = :next_open`.

Required data must have equal lengths, strictly increasing times, and finite closes.

Ask the user for:

- data source: local path or URL;
- format: CSV / JSON / etc.;
- required columns: time and OHLCV or closes;
- date range.

If required data is missing, stop and ask. Do not generate or run backtest code until data is supplied and validated.

## Phase 3 — Strategy spec + Julia code

Create a strategy spec containing:

- intent;
- instrument;
- data requirements;
- entry;
- exit;
- precompute;
- backtest kwargs;
- execution flags.

Generate valid Julia code in the style of `Backtest/Advanced_Backtester.jl`:

```julia
using Fastback, Dates

include(joinpath(@__DIR__, "Advanced_Backtester.jl"))
using .Advanced_Backtester

# dts and closes: loaded from the user-provided data
# dts = ...
# closes = ...

r = rsi(closes; n = 14)

res = @backtest(dts, closes, begin
    r[i-1] < 30 && long!()
    r[i-1] > 70 && flat!()
end; deposit = 10_000.0)

backtest_stats(res)        # stats: final equity, max drawdown, sharpe, win rate ...

# Plots (Plots.jl / your plotting lib of choice)
#   equity curve, drawdown, and trade entry/exit markers
plot(res.eq_t, res.eq_v)                                    # equity curve
plot(res.dd_t, res.dd_v)                                    # drawdown (dd_t/dd_v aligned 1:1 with eq)
plot_trades(res, dts, closes)                               # price + entries/wins/losses markers
```

Adapt names, indicators, conditions, and kwargs to the strategy.

## Phase 4 — Confirmation (code + spec + code flow)

Return all three explicitly before asking for confirmation:

### 1. Strategy Spec

Present a concise spec block:

```
intent: ...
instrument: ...
data: path + format + columns + range
indicator: name + parameters
entry: condition → action
exit: condition → action
defaults used: list any defaults applied
```

### 2. Generated Julia Code

Present the complete Julia script in a code block, verbatim, so the user can verify every line.

### 3. Code Flow

Explain step-by-step what the code does, in order:

1. Load data from path;
2. Compute precomputed indicators (e.g. RSI, entropy);
3. Build `@backtest(dts, closes, ...)` call;
4. Define signal block conditions (`long!()`, `flat!()`, etc.);
5. Run account loop, collect equity/drawdown vectors;
6. Return `BacktestResult` and print `backtest_stats(res)`;
7. Plot equity curve (`plot(res.eq_t, res.eq_v)`), drawdown (`plot(res.dd_t, res.dd_v)`), and trade entry/exit markers (`plot_trades(res, dts, closes)`).

### Confirmation

After showing 1–3, ask:

> Does this strategy capture your description? Reply Yes / No / Edit.

Do not execute until the user confirms.

## Phase 5 — Execution

If confirmed, write the generated Julia script to a sensible path, such as `Backtest/generated/<strategy-slug>.jl`, and run it with the backtester project:

```bash
julia --project="Backtest/vendor/Fastback.jl" /absolute/path/to/generated_strategy.jl
```

Then report results using `backtest_stats(res)`, `show_account(res)`, and related helpers, and return the three plots (equity, drawdown, trade entry/exit).

## Hard stops

- Do not interpret or generate strategy code without data being supplied/validated.
- Do not generate or run backtest code before the data gate is satisfied.
- Do not run the backtest before user confirmation of the spec + code.
