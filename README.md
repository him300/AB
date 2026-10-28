### AdvancedBacktester

Advanced Julia backtesting pipeline. Macro-based (`@backtest`), vendored Fastback engine.

## The One-Macro Backtesting Engine for Julia

**A complete, battle-tested backtesting framework that automates the entire backtesting workflow - from account setup to final statistics - with a single macro call.**

### Key Features
- **One-click backtesting**: Precompute your signal logic, then call `@backtest()` with your data
- **Automated workflow**: Handles account creation, bar-by-bar execution, position management, and final flattening
- **Production-grade safeguards**: Warmup periods, NaN guards, boundary checks, and slippage modeling
- **Comprehensive statistics**: Final equity, max drawdown, Sharpe ratio, wins/losses metrics
- **Plotting-ready**: Built-in support for equity curves, drawdown charts, and trade visualizations
- **Zero configuration**: No boilerplate setup required - just write your signal logic

### How It Works
1. **Precompute**: Calculate indicators or signals outside the macro (ordinary code, runs before the macro call)
2. **One macro call**: Use `@backtest(dts, closes, begin ... end)` to execute your strategy
3. **Analyze**: Use the returned `BacktestResult` for statistics, plots, or trade analysis

### Usage Example
```julia
using Fastback, Dates
include("Advanced_Backtester.jl")
using .Advanced_Backtester

# 1. Precompute (ordinary code, runs before macro call)
r = rsi(closes; n=14)

# 2. One macro call = account + loop + flatten + vectors
res = @backtest(dts, closes, begin
    r[i-1] < 30 && long!()
    r[i-1] > 70 && flat!()
end; deposit=10_000.0)

# 3. Analyze
backtest_stats(res)          # NamedTuple: final_equity, max_drawdown, sharpe, ...
show_account(res)            # Cash/equity/positions/trades view
wins = winning_trades(res)    # Realizing fills with return > 0
plot(res.eq_t, res.eq_v)      # Your plotting lib of choice
```

### Why Use This?
- Eliminates manual backtesting setup errors
- Enforces consistent execution patterns
- Reduces false positives through rigorous vector processing
- Integrates with existing Julia packages (Fastback, Indicators, Plots)
- Maintains full transparency through detailed result objects

For full documentation, see the [Advanced_Backtester_MANUAL.md](docs/ADVANCED_BACKTESTER_MANUAL.md) or the [BACKTEST_SYTHESIS.md](specs/BACKTEST_SYTHESIS.md) design document.
