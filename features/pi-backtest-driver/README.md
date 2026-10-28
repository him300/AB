# Pi Backtest Driver — Agent Feature

A Pi prompt template (`/backtest`) that turns plain-English strategy descriptions into valid Julia backtest code using the `AdvancedBacktester` package, then runs it and returns stats.

## What it does

- Captures a strategy from natural language (e.g. "buy when RSI crosses above 30").
- Requires backtest data before generating any code (data gate).
- Generates a strategy spec + Julia script using `@backtest()`.
- Presents spec + code for user confirmation before execution.
- Runs the backtest and returns `backtest_stats(res)` results.

## Files

| File | Purpose |
|------|---------|
| `prompts/backtest.md` | Pi prompt template — install to `~/.pi/agent/prompts/` or `.pi/prompts/` |
| `README.md` | This file |

## Install

```bash
# User-level (available in all sessions)
cp features/pi-backtest-driver/prompts/backtest.md ~/.pi/agent/prompts/backtest.md

# Or project-level
cp features/pi-backtest-driver/prompts/backtest.md .pi/prompts/backtest.md
```

Then in Pi:

```text
/reload
/backtest Buy when RSI crosses above 30, sell when RSI crosses below 70.
```

## Data requirements

The driver stops at Phase 2 (data gate) unless you supply:
- Data source (local path or URL)
- Format (CSV, JSON, etc.)
- Required columns (time + OHLCV or closes)
- Date range

All other parameters use sensible defaults (see the defaults table in the prompt).

## Example output

The driver returns three things before execution:
1. **Strategy spec** — intent, instrument, data, indicator, entry/exit, defaults.
2. **Generated Julia code** — full `@backtest(...)` script.
3. **Code flow** — step-by-step explanation of what the code does.

After confirmation, it runs the script and reports `backtest_stats(res)`.
