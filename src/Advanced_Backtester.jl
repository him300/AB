# Advanced_Backtester.jl
#
# One-macro backtest pipeline for the batch (`Indicators.jl`) playbook.
# Implements BACKTEST_SYTHESIS.md §2 (setup) + §3 (loop, flatten, vectors) as code,
# so a strategy file only contains: precompute line(s) + signal block.
#
# Usage:
#   using Fastback, Dates, Indicators
#   include(joinpath(@__DIR__, "Advanced_Backtester.jl"))
#   using .Advanced_Backtester
#
#   # 1. precompute (ordinary code, runs before the macro call)
#   r = rsi(closes; n=14)
#
#   # 2. one macro call = account + loop + flatten + vectors
#   res = @backtest(dts, closes, begin
#       r[i-1] < 30 && long!()
#       r[i-1] > 70 && flat!()
#   end; deposit=10_000.0)
#
#   # 3. analyze
#   backtest_stats(res)          # NamedTuple: final_equity, max_drawdown, sharpe, ...
#   show_account(res)            # same as Fastback show(acc): cash/equity/positions/trades
#   wins = winning_trades(res)   # realizing fills with realized return > 0
#   losses = losing_trades(res)  # realizing fills with realized return < 0
#   plot(res.eq_t, res.eq_v)     # your plotting lib of choice
#
# What the macro automates (BACKTEST_SYTHESIS.md §2–§3, §5 vectors):
#   - Account creation: funding (FullyFunded/Margined), FlatFeeBroker, deposit,
#     spot instrument registration. Fresh account per call (service.jl rule).
#   - The bar loop: update_marks! every bar (even no-trade bars), trade at
#     closes[i] on signal reads at i-1 (your block), equity/pos/signal vectors.
#   - Final flatten: close_position! at last bar + post-flatten equity point.
#   - WARMUP: :auto (default) scans every i-lagged array your signal reads and
#     sets WARMUP = longest leading-NaN/Inf run + 2 (slowest-n-plus-2 rule).
#   - NaN guard: every `ARR[i-k]` read your signal touches becomes an
#     `isfinite` conjunct (matrix rows with `:` use `all(isfinite, ...)`), plus
#     an `i > max(WARMUP, LAG)` bounds guard where LAG is the deepest `i-k`
#     lag found in your block (so `i-2` reads can never BoundsError on bar 1).
#   - sig_v overlay: records your first lagged read per bar (override: track=...).
#   - Drawdown vector: feeds every bar's equity through Fastback's
#     drawdown_collector into res.dd_t/dd_v. Default period Millisecond(0)
#     ⇒ one point per bar + one post-flatten point, aligned 1:1 with eq_t/eq_v.
#     A larger drawdown_period (e.g. Day(1)) downsamples: dd_t/dd_v get
#     shorter than eq_t/eq_v, and the post-flatten point only appears if the
#     last gap >= period. Mode via drawdown_mode kwarg (:percentage | :pnl).
#
# Names visible inside your signal block (do not predefine these):
#   i, dt, price        loop counter / bar timestamp / execution reference price
#   acc, inst, usd      account, instrument, base-cash handle
#   WARMUP              warmup actually used (useful for your own extra logic)
#   long!()             open long  at default size + adverse slippage
#   short!()            open short at default size + adverse slippage
#                       (needs funding=:margined; honors allow_reverse kwarg)
#   flat!()             close_position! (full) at adverse slippage
#   open_position! / close_position!   raw helpers (trading_utils.jl), for
#                       custom sizing — remember mark_first=false (loop already
#                       marked) and fill_price=price*1.001 / *0.999 slippage.
#
# Keyword knobs (all optional):
#   deposit=10_000.0  funding=:fullyfunded | :margined   fee_pct=0.001
#   symbol=:ABC       notional=1_000.0 | quantity=10.0   slippage_bps=10.0
#                       (multiplicative ± per BACKTEST_SYTHESIS.md §2:
#                        buys price*(1+bps), sells price*(1-bps))
#   allow_reverse=false  allow_add=false                 warmup=:auto | Int
#   drawdown_mode=:percentage | :pnl   Fastback drawdown_collector mode feeding
#                       res.dd_v (:percentage → fractions in [-1, 0],
#                        :pnl → currency amounts ≤ 0; default :percentage)
#   drawdown_period=Millisecond(0)  throttle for the drawdown collector.
#                       Default Millisecond(0) ⇒ emits every bar (1:1 with eq).
#                       E.g. Day(1) ⇒ downsampled, dd_t/dd_v shorter than eq.
#   guard=(...)       extra raw finiteness/truth exprs ANDed with the auto guards
#                     (e.g. guard=(isfinite(myfilter[i-1]),); NOT isfinite-wrapped)
#   track=EXPR        sig_v overlay source (default: first auto-derived read)
#   fill=:close | :next_open   opens=VEC (required iff :next_open; §4E — signal
#                       on closes[i-1], fill at opens[i] with adverse slip)
#   precompute=quote ... end   optional block spliced before account setup
#                       (vars stay macro-local; prefer precomputing outside)
#
# N accounts × N strategies, one shared bar loop — @backtestN:
#   res = @backtestN(dts, closes,
#       10_000.0 => rsi[i-1] < 30 ? long!() : rsi[i-1] > 70 ? flat!() : nothing,
#       20_000.0 => begin
#           fast[i-1] > slow[i-1] && long!()
#           fast[i-1] < slow[i-1] && flat!()
#       end => (notional=2_000.0,);
#       fee_pct=0.001, slippage_bps=10.0)
#   # res::Vector{BacktestResult} — backtest_stats.(res), res[2].eq_v, ...
# Every leg is `deposit => strategy [=> (overrides...)]` — no brackets needed
# for single-expression strategies. One loop steps all N accounts together
# (same dt/price); each leg gets its own account, deposit, guard chain,
# warmup, vectors and drawdown collector. Shared kwargs are defaults for
# every leg (so one fee_pct/slippage_bps covers all N accounts); the trailing
# per-leg tuple overrides funding/symbol/notional/quantity/allow_reverse/
# allow_add/warmup/guard/track for that leg only. Same DSL names as @backtest
# resolve per-leg inside every strategy: acc/inst/usd, i/dt/price, WARMUP,
# long!/short!/flat! (+ raw open_position!/close_position! with
# mark_first=false — the shared loop already marked every account).
module Advanced_Backtester

using Fastback
using Dates
using Statistics

include(joinpath(@__DIR__, "trading_utils.jl"))
include(joinpath(@__DIR__, "BacktestN.jl"))

export open_position!, close_position!
export @backtest, @backtestN, BacktestResult, backtest_stats, show_account
export realizing_trades, winning_trades, losing_trades
export plot_trades, mplot_trades

# ---------------------------------------------------------------------------
# Result + stats
# ---------------------------------------------------------------------------

"""Vectors + handles returned by `@backtest`. Plot/analyze freely.

`dd_t`/`dd_v` come from Fastback's `drawdown_collector` (default period
`Millisecond(0)`: one point per bar + one post-flatten point, aligned 1:1
with `eq_t`/`eq_v`; a larger `drawdown_period` downsamples so `dd_t`/`dd_v`
are shorter — always plot `dd_v` against `dd_t`, never `eq_t`). `dd_v`
semantics follow `drawdown_mode`: `:percentage` → fractions in `[-1, 0]`
(e.g. `-0.05` = −5%), `:pnl` → currency amounts `≤ 0`."""
struct BacktestResult
    eq_t::Vector{DateTime}
    eq_v::Vector{Float64}
    pos_v::Vector{Float64}
    sig_v::Vector{Float64}
    dd_t::Vector{DateTime}
    dd_v::Vector{Float64}
    drawdown_mode::Symbol
    drawdown_period::Dates.Period
    acc
    inst
    usd
    trades::Vector
    warmup::Int
    lag::Int
    initial_cash::Float64
end

"""Backwards-compatible constructor: old 11-field positional order
(pre-drawdown) still works — fills empty `:percentage`/`Millisecond(0)`
drawdown vectors."""
function BacktestResult(eq_t, eq_v, pos_v, sig_v, acc, inst, usd,
        trades, warmup, lag, initial_cash)
    BacktestResult(eq_t, eq_v, pos_v, sig_v,
        DateTime[], Float64[], :percentage, Millisecond(0),
        acc, inst, usd, trades, warmup, lag, initial_cash)
end

function Base.show(io::IO, r::BacktestResult)
    print(io, "BacktestResult(bars=$(length(r.eq_t)), warmup=$(r.warmup), ",
        "trades=$(length(r.trades)), final_equity=$(round(r.eq_v[end]; digits=2)))")
end

"""
    backtest_stats(res; periods_per_year=252) -> NamedTuple

BACKTEST_SYTHESIS.md §5 math: total return, max drawdown (+bar index),
annualized Sharpe on log-returns, trade count, sign-aware win rate.
`NaN` Sharpe when fewer than 2 finite returns or zero variance.
"""
function backtest_stats(res::BacktestResult; periods_per_year::Real=252)
    eq = res.eq_v
    final_equity = eq[end]
    total_return = final_equity / eq[1] - 1.0
    peak = eq[1]; mdd = 0.0; mdd_idx = 1
    for (k, v) in enumerate(eq)
        v > peak && (peak = v)
        dd = (peak - v) / peak
        dd > mdd && (mdd = dd; mdd_idx = k)
    end
    f = filter(isfinite, eq)
    rets = length(f) > 1 ? diff(log.(f)) : Float64[]
    sharpe = (length(rets) > 1 && std(rets) > 0) ?
        sqrt(Float64(periods_per_year)) * mean(rets) / std(rets) : NaN
    tr = res.trades
    wins = count(tr) do t
        r = sign(Float64(t.pos_qty)) *
            (Float64(t.fill_price) - Float64(t.pos_price)) / abs(Float64(t.pos_price))
        r > 0
    end
    return (;
        final_equity, total_return, max_drawdown=mdd, max_drawdown_idx=mdd_idx,
        sharpe, n_trades=length(tr),
        win_rate=isempty(tr) ? NaN : wins / length(tr), warmup=res.warmup)
end

"""
    realizing_trades(res) -> Vector

Every fill in `res.trades` that closed (part of) a position
(`Fastback.is_realizing`, i.e. `realized_qty != 0`). Entry fills only open
exposure and realize nothing, so they are excluded — a fill can only be a
win or a loss on the closing leg. Returns a fresh `Vector` (safe to
sort/filter in place) in chronological fill order.
"""
realizing_trades(res::BacktestResult) = filter(Fastback.is_realizing, res.trades)

function __trade_ret(t, by::Symbol)
    by === :gross && return Fastback.realized_return_gross(t)
    by === :net && return Fastback.realized_return_net(t)
    throw(ArgumentError("by must be :gross or :net, got $(repr(by))"))
end

"""
    winning_trades(res; by=:gross) -> Vector
    losing_trades(res; by=:gross) -> Vector

Realizing fills (see `realizing_trades`) split by sign of per-unit realized
return: `> 0` wins, `< 0` losses. Exact-zero (breakeven) fills and fills
with undefined return (`NaN`) appear in neither — use `realizing_trades`
for the full closing-fill set.

`by` selects the return basis (both Fastback price-only per-unit returns):
- `:gross` (default) — `realized_return_gross`: `sign(pos_qty) *
  (fill_price - pos_price) / abs(pos_price)`, before costs. Same formula
  `backtest_stats` uses for `win_rate` (which additionally counts entry
  fills as non-wins).
- `:net` — `realized_return_net`: gross minus round-trip commission
  attribution for the realized leg.

Each element is the raw Fastback `Trade` — analyse freely, e.g.
`getproperty.(wins, :fill_pnl_settle)` (gross P&L per fill, settlement ccy),
`getproperty.(wins, :fill_price)`, `getproperty.(wins, :date)`.
Works per leg on `@backtestN` output via broadcast: `winning_trades.(res)`.
"""
function winning_trades(res::BacktestResult; by::Symbol=:gross)
    return filter(t -> Fastback.is_realizing(t) && __trade_ret(t, by) > 0, res.trades)
end
function losing_trades(res::BacktestResult; by::Symbol=:gross)
    return filter(t -> Fastback.is_realizing(t) && __trade_ret(t, by) < 0, res.trades)
end

"""Fill `(date, fill_price)` points for a trade vector."""
__trade_points(ts) =
    (getproperty.(ts, :date), Float64.(getproperty.(ts, :fill_price)))

function __plots_mod()
    isdefined(Main, :Plots) && return getproperty(Main, :Plots)
    return Base.require(Main, :Plots)
end

function __makie_mod()
    isdefined(Main, :CairoMakie) && return getproperty(Main, :CairoMakie)
    return Base.require(Main, :CairoMakie)
end

"""
    plot_trades(res, dts, closes; kwargs...) -> Plots.Plot  (Plots.jl)

Price line + scatter markers at each fill's `(date, fill_price)`.
Deliberately unopinionated: no title / xlabel / ylabel is ever set —
style everything yourself via the kwargs below.

Flags (all `true` by default, set `false` to hide a layer):
- `entries` — non-realizing (open) fills, blue circles
- `wins` / `losses` — realizing fills split by `by` (`:gross` | `:net`,
  same basis as `winning_trades`/`losing_trades`)

Styling — every layer merges your tuple OVER the defaults, so any Plots
attribute just works, e.g. `win_kwargs=(; color=:lime, markersize=8,
label="my wins")`:
- `price_kwargs=(;)` — forwarded to `plot(dts, closes; ...)`
- `win_kwargs` — defaults `(marker=:utriangle, color=:green, label="wins", markersize=6, markerstrokewidth=0)`
- `loss_kwargs` — defaults `(marker=:dtriangle, color=:red, label="losses", markersize=6, markerstrokewidth=0)`
- `entry_kwargs` — defaults `(marker=:circle, color=:blue, label="entries", markersize=5, markerstrokewidth=0)`
- trailing `kwargs...` — extra Plots attributes for the price line
  (e.g. `title="SMA cross", xlabel="time", linewidth=2`).

Requires Plots.jl in your environment (`using Plots` first, or it is
lazy-loaded). Returns the plot — keep calling `plot!`/`scatter!` on it.
"""
function plot_trades(res::BacktestResult, dts, closes;
        by::Symbol=:gross,
        entries::Bool=true, wins::Bool=true, losses::Bool=true,
        price_kwargs::NamedTuple=(;),
        win_kwargs::NamedTuple=(;),
        loss_kwargs::NamedTuple=(;),
        entry_kwargs::NamedTuple=(;),
        kwargs...)
    P = __plots_mod()
    plt = P.plot(dts, closes; label="", price_kwargs..., kwargs...)
    if entries
        ents = filter(!Fastback.is_realizing, res.trades)
        if !isempty(ents)
            ed, ep = __trade_points(ents)
            P.scatter!(plt, ed, ep; marker=:circle, color=:blue,
                label="entries", markersize=5, markerstrokewidth=0, entry_kwargs...)
        end
    end
    if wins
        w = winning_trades(res; by)
        if !isempty(w)
            wd, wp = __trade_points(w)
            P.scatter!(plt, wd, wp; marker=:utriangle, color=:green,
                label="wins", markersize=6, markerstrokewidth=0, win_kwargs...)
        end
    end
    if losses
        l = losing_trades(res; by)
        if !isempty(l)
            ld, lp = __trade_points(l)
            P.scatter!(plt, ld, lp; marker=:dtriangle, color=:red,
                label="losses", markersize=6, markerstrokewidth=0, loss_kwargs...)
        end
    end
    return plt
end

"""
    mplot_trades(res, dts, closes; kwargs...) -> (fig, ax)  (CairoMakie.jl)

Same data as `plot_trades`, Makie flavour. Equally unopinionated: no
title / xlabel / ylabel is ever set. Returns `(fig, ax)` so you keep
customizing (`ax.title = ...`, `lines!`, `save("t.png", fig)`, ...).

- `fig=nothing, ax=nothing` — pass your own to draw into an existing
  figure/axis instead of creating one.
- `figure=(;)` / `axis=(;)` — forwarded to `Figure(; ...)` / `Axis(; ...)`
  when creating (e.g. `figure=(; size=(900, 500))`).
- `entries/wins/losses::Bool=true`, `by=:gross` — same as `plot_trades`.
- `price_kwargs` → `lines!`, `win/loss/entry_kwargs` → `scatter!`, merged
over defaults: wins `(marker=:utriangle, color=:green, label="wins",
  markersize=12)`, losses `(marker=:dtriangle, color=:red,
  label="losses", markersize=12)`, entries `(marker=:circle,
  color=:blue, label="entries", markersize=9)`.
- No legend is drawn for you — call `axislegend(ax)` if you want one.

Requires CairoMakie in your environment (`using CairoMakie` first, or it
is lazy-loaded).
"""
function mplot_trades(res::BacktestResult, dts, closes;
        by::Symbol=:gross,
        entries::Bool=true, wins::Bool=true, losses::Bool=true,
        fig=nothing, ax=nothing,
        figure::NamedTuple=(;),
        axis::NamedTuple=(;),
        price_kwargs::NamedTuple=(;),
        win_kwargs::NamedTuple=(;),
        loss_kwargs::NamedTuple=(;),
        entry_kwargs::NamedTuple=(;))
    M = __makie_mod()
    if fig === nothing
        fig = M.Figure(; figure...)
    end
    if ax === nothing
        ax = M.Axis(fig[1, 1]; axis...)
    end
    M.lines!(ax, dts, closes; price_kwargs...)
    if entries
        ents = filter(!Fastback.is_realizing, res.trades)
        if !isempty(ents)
            ed, ep = __trade_points(ents)
            M.scatter!(ax, ed, ep; marker=:circle, color=:blue,
                label="entries", markersize=9, entry_kwargs...)
        end
    end
    if wins
        w = winning_trades(res; by)
        if !isempty(w)
            wd, wp = __trade_points(w)
            M.scatter!(ax, wd, wp; marker=:utriangle, color=:green,
                label="wins", markersize=12, win_kwargs...)
        end
    end
    if losses
        l = losing_trades(res; by)
        if !isempty(l)
            ld, lp = __trade_points(l)
            M.scatter!(ax, ld, lp; marker=:dtriangle, color=:red,
                label="losses", markersize=12, loss_kwargs...)
        end
    end
    return (fig, ax)
end

"""
    show_account(res; kwargs...)
    show_account(res, io; kwargs...)

Pretty-print the Fastback account behind a `@backtest` result — same output
as `show(acc)` in the REPL (cash balances, equity, positions, trades).

`kwargs` pass through to `Base.show(::Account)` (e.g. `max_trades=50`).
"""
show_account(res::BacktestResult; kwargs...) = show_account(stdout, res; kwargs...)
show_account(io::IO, res::BacktestResult; kwargs...) = show(io, res.acc; kwargs...)

# ---------------------------------------------------------------------------
# Expansion-time analysis of the user's signal block
# ---------------------------------------------------------------------------

"""Does `ex` mention the loop counter `i` anywhere?"""
__mentions_i(ex) = ex === :i ? true :
    (ex isa Expr ? any(__mentions_i, ex.args) : false)

"""Collect every `ARR[<idx mentioning i>]` ref in `ex` (deduped, in order)."""
function __collect_refs!(ex, acc::Vector{Any}, seen::Set{String})
    if ex isa Expr
        if ex.head === :ref && length(ex.args) >= 2 &&
                any(a -> a isa Expr || a === :i, ex.args[2:end]) &&
                any(__mentions_i, ex.args[2:end])
            key = string(ex)
            if key ∉ seen
                push!(seen, key); push!(acc, ex)
            end
        end
        for a in ex.args
            __collect_refs!(a, acc, seen)
        end
    end
    return acc
end

"""Deepest literal `i - k` lag in `ex` (0 if none; plain `i` contributes 0)."""
function __max_lag(ex)
    best = 0
    if ex isa Expr
        if ex.head === :call && length(ex.args) == 3 && ex.args[1] === :(-) &&
                ex.args[2] === :i && ex.args[3] isa Integer
            best = max(best, Int(ex.args[3]))
        end
        for a in ex.args
            best = max(best, __max_lag(a))
        end
    end
    return best
end

"""Index arg exactly `:i` (same-bar read — likely lookahead, warn)?"""
__has_bare_i(ref::Expr) = any(a -> a === :i, ref.args[2:end])

"""Does this ref index span a whole row/col (`:`)? → needs all(isfinite,...)."""
__has_colon(ref::Expr) = any(a -> a === :(:) ||
    (a isa Expr && a.head === :quote && length(a.args) == 1 && a.args[1] === :(:)), ref.args[2:end])

# ---------------------------------------------------------------------------
# Runtime helpers (always module-qualified in generated code)
# ---------------------------------------------------------------------------

function __funding(x)
    if x === :fullyfunded || x === "fullyfunded" || x === AccountFunding.FullyFunded
        return AccountFunding.FullyFunded
    elseif x === :margined || x === "margined" || x === AccountFunding.Margined
        return AccountFunding.Margined
    end
    throw(ArgumentError("funding must be :fullyfunded or :margined, got $(repr(x))"))
end

function __drawdown_mode(x)
    if x === :percentage || x === "percentage" || x == DrawdownMode.Percentage
        return DrawdownMode.Percentage
    elseif x === :pnl || x === "pnl" || x == DrawdownMode.PnL
        return DrawdownMode.PnL
    end
    throw(ArgumentError("drawdown_mode must be :percentage or :pnl, got $(repr(x))"))
end

__drawdown_mode_sym(m) = m == DrawdownMode.PnL ? :pnl : :percentage

"""Zero period so the drawdown collector emits one point per call (per bar)."""
__zero_period() = Millisecond(0)

function __drawdown_period(x)
    x isa Dates.Period ||
        throw(ArgumentError("drawdown_period must be a Dates.Period " *
            "(e.g. Millisecond(0), Day(1)), got $(repr(x))"))
    return x
end

function __validate_inputs(dts, closes, opens)
    length(dts) == length(closes) ||
        throw(ArgumentError("dts ($(length(dts))) and closes ($(length(closes))) differ in length"))
    N = length(dts)
    N >= 1 || throw(ArgumentError("need ≥ 1 bar, got empty inputs"))
    for k in 2:N
        dts[k] > dts[k-1] || throw(ArgumentError("dts not strictly increasing at bar $k"))
    end
    all(x -> x isa Number && isfinite(x), closes) ||
        throw(ArgumentError("closes must be all finite (got NaN/Inf/missing)"))
    if opens !== nothing
        length(opens) == N || throw(ArgumentError("opens length must match dts"))
        all(x -> x isa Number && isfinite(x), opens) ||
            throw(ArgumentError("opens must be all finite"))
    end
    return N
end

__leading_bad(::Any) = 0
function __leading_bad(v::AbstractVector)
    n = 0
    for x in v
        (x isa Number && isfinite(x)) && break
        n += 1
    end
    return n
end
function __leading_bad(m::AbstractMatrix)
    n = 0
    for k in axes(m, 1)
        all(x -> x isa Number && isfinite(x), @view(m[k, :])) && break
        n += 1
    end
    return n
end

"""slowest-leading-NaN-run + 2 (BACKTEST_SYTHESIS.md §3 rule). Empty → 2."""
__auto_warmup(bases::Tuple{}) = 2
__auto_warmup(bases::Tuple) = maximum(map(__leading_bad, bases); init=0) + 2

__tofloat(x::Number) = Float64(x)
__tofloat(::Any) = NaN

# ---------------------------------------------------------------------------
# The macro
# ---------------------------------------------------------------------------
macro backtest(args...)
    pos = Any[]
    kws = Dict{Symbol,Any}()
    for a in args
        if a isa Expr && a.head === :parameters
            for p in a.args
                p isa Expr && p.head === :kw ||
                    error("@backtest kwargs must look like name=value; got `$p`")
                kws[p.args[1]] = p.args[2]
            end
        else
            push!(pos, a)
        end
    end
    length(pos) == 3 || error(
        "usage: @backtest(dts, closes, signal_block; kwargs...) — " *
        "got $(length(pos)) positional args. " *
        "NOTE: kwargs need a `;`: @backtest(dts, closes, begin ... end; deposit=10_000.0)")
    dts_ex, closes_ex, signal_ex = pos[1], pos[2], pos[3]

    getkw(name, default) = haskey(kws, name) ? kws[name] : QuoteNode(default)
    for k in keys(kws)
        k in (:deposit, :funding, :fee_pct, :symbol, :notional, :quantity,
              :slippage_bps, :allow_reverse, :allow_add, :warmup, :guard,
              :track, :fill, :opens, :precompute, :drawdown_mode,
              :drawdown_period) ||
            error("@backtest: unknown kwarg `$k`")
    end

    # --- user guard exprs: raw, ANDed (never isfinite-wrapped) ---
    extra_guard = Any[]
    if haskey(kws, :guard)
        g = kws[:guard]
        if g isa Expr && (g.head === :tuple || g.head === :vect)
            append!(extra_guard, g.args)
        else
            push!(extra_guard, g)
        end
    end

    # --- derive auto guards + lag from the signal block ---
    auto_refs = __collect_refs!(signal_ex, Any[], Set{String}())
    lag = __max_lag(signal_ex)
    for g in extra_guard
        lag = max(lag, __max_lag(g))
    end
    if haskey(kws, :track)
        lag = max(lag, __max_lag(kws[:track]))
    end
    if isempty(auto_refs)
        @warn("@backtest: no `ARR[i-k]` reads detected in signal block — " *
            "no finiteness guard emitted. If your signal uses precomputed vectors, " *
            "index them at `i-1` (BACKTEST_SYTHESIS.md §3) or pass guard=(...) explicitly.")
    else
        for r in auto_refs
            r isa Expr && r.head === :ref && __has_bare_i(r) &&
                r.args[1] !== :opens &&
                @warn("@backtest: same-bar read `$(r)` detected — trading index-`i` " *
                    "values at closes[i] is lookahead (BACKTEST_SYTHESIS.md §7.1). " *
                    "Use `i-1`. (`opens[i]` with fill=:next_open is exempt.)")
        end
        isempty(auto_refs) || (lag = max(lag, 1))  # any lagged read needs i ≥ 2
    end

    # single && chain: bounds guard + auto isfinite guards + raw user guards
    cond = :(i > max(WARMUP, __bt_lag__))
    for r in auto_refs
        term = (r isa Expr && r.head === :ref && __has_colon(r)) ?
            :(all(isfinite, $r)) : :(isfinite($r))
        cond = Expr(:&&, cond, term)
    end
    for g in extra_guard
        cond = Expr(:&&, cond, g)
    end

    # warmup bases: Symbol heads of auto-derived refs only
    base_syms = Symbol[]
    seen_b = Set{Symbol}()
    for r in auto_refs
        r isa Expr && r.head === :ref && r.args[1] isa Symbol || continue
        b = r.args[1]::Symbol
        b in (:i, :dt, :price, :acc, :inst, :usd, :WARMUP) && continue
        b ∉ seen_b && (push!(seen_b, b); push!(base_syms, b))
    end
    bases_tuple = Expr(:tuple, base_syms...)
    track_inner = haskey(kws, :track) ? kws[:track] :
        isempty(auto_refs) ? :(NaN) : auto_refs[1]

    __warmup_opt = haskey(kws, :warmup) ? kws[:warmup] : QuoteNode(:auto)
    __warmup_opt isa QuoteNode && (__warmup_opt = __warmup_opt.value)
    warmup_inner = if __warmup_opt === :auto
        :(Advanced_Backtester.__auto_warmup($bases_tuple))
    else
        kws[:warmup]  # caller-supplied Int/expr: spliced raw, evaluated at call site
    end
    precompute_inner = haskey(kws, :precompute) ? kws[:precompute] : nothing

    fill_sym = haskey(kws, :fill) ? kws[:fill] : :close
    fill_sym isa QuoteNode && (fill_sym = fill_sym.value)
    fill_sym in (:close, :next_open) ||
        error("@backtest: fill must be :close or :next_open, got `$fill_sym`")
    if fill_sym === :next_open && !haskey(kws, :opens)
        error("@backtest: fill=:next_open requires opens=... (BACKTEST_SYTHESIS.md §4E)")
    end
    px_inner = fill_sym === :close ? :price : :(Float64(__bt_opens__[i]))
    size_kw = haskey(kws, :quantity) ? :(quantity=__bt_size__) : :(notional=__bt_size__)

    # Whole-body esc: this is a scope-sharing DSL — i/dt/price/acc/long! … must
    # resolve to the loop's locals, and user exprs (dts, signal, kwargs) to the
    # caller. So NO inner esc() anywhere below: build the body raw, call esc
    # once on the whole thing. (Hygiene note: because user signal code shares
    # scope with the loop, caller vars named eq_t/WARMUP/... would collide —
    # macro-owned names use the __bt_ prefix; eq_t/eq_v/pos_v/sig_v and
    # acc/inst/usd/dt/price/i/WARMUP/long!/short!/flat! intentionally match the
    # BACKTEST_SYTHESIS.md §3 skeleton and DSL spec. Do not predefine them.)
    # Runtime helpers stay Advanced_Backtester.__qualified so they resolve
    # regardless (caller still needs `using Fastback, Dates`).
    body = quote
        let __bt_dts__ = $dts_ex, __bt_closes__ = $closes_ex,
            __bt_opens__ = $(haskey(kws, :opens) ? kws[:opens] : nothing)

            Advanced_Backtester.__validate_inputs(__bt_dts__, __bt_closes__, __bt_opens__)
            $(precompute_inner === nothing ? nothing : precompute_inner)

            __bt_funding__ = Advanced_Backtester.__funding($(getkw(:funding, :fullyfunded)))
            __bt_fee__ = Float64($(getkw(:fee_pct, 0.001)))
            __bt_dep__ = Float64($(getkw(:deposit, 10_000.0)))
            __bt_sym__ = Symbol($(getkw(:symbol, :ABC)))
            __bt_bps__ = Float64($(getkw(:slippage_bps, 10.0)))
            __bt_up__ = 1.0 + __bt_bps__ / 10_000.0   # buys:  price*1.001 (BACKTEST_SYTHESIS.md §2)
            __bt_dn__ = 1.0 - __bt_bps__ / 10_000.0   # sells: price*0.999 (same)
            __bt_rev__ = Bool($(getkw(:allow_reverse, false)))
            __bt_add__ = Bool($(getkw(:allow_add, false)))
            __bt_size__ = Float64($(haskey(kws, :quantity) ?
                getkw(:quantity, 1.0) : getkw(:notional, 1_000.0)))

            acc = Account(; funding=__bt_funding__,
                base_currency=CashSpec(:USD), broker=FlatFeeBroker(pct=__bt_fee__))
            usd = cash_asset(acc, :USD)
            deposit!(acc, usd, __bt_dep__)
            inst = register_instrument!(acc, spot_instrument(__bt_sym__, __bt_sym__, :USD))
            __bt_dd_mode__ = Advanced_Backtester.__drawdown_mode($(getkw(:drawdown_mode, :percentage)))
            __bt_dd_period__ = Advanced_Backtester.__drawdown_period($(haskey(kws, :drawdown_period) ? kws[:drawdown_period] : :(Advanced_Backtester.__zero_period())))
            __bt_collect_dd__, __bt_dd__ = drawdown_collector(
                __bt_dd_mode__, __bt_dd_period__)

            WARMUP = Int($warmup_inner)
            WARMUP >= 1 || throw(ArgumentError("@backtest: warmup must be ≥ 1, got $WARMUP"))
            WARMUP >= length(__bt_dts__) &&
                throw(ArgumentError("@backtest: warmup ($WARMUP) ≥ bar count " *
                    "($(length(__bt_dts__))) — nothing left to trade on"))
            __bt_lag__ = $lag

            eq_t = DateTime[]; eq_v = Float64[]
            pos_v = Float64[]; sig_v = Float64[]
            for i in eachindex(__bt_dts__)
                dt = __bt_dts__[i]
                price = __bt_closes__[i]
                update_marks!(acc, inst, dt, price, price, price)
                __bt_px__ = $px_inner
                long! = () -> open_position!(acc, inst, dt, __bt_px__;
                    side=:long, $size_kw,
                    fill_price=__bt_px__ * __bt_up__, allow_add=__bt_add__,
                    allow_reverse=__bt_rev__, mark_first=false)
                short! = () -> open_position!(acc, inst, dt, __bt_px__;
                    side=:short, $size_kw,
                    fill_price=__bt_px__ * __bt_dn__, allow_add=__bt_add__,
                    allow_reverse=__bt_rev__, mark_first=false)
                flat! = () -> close_position!(acc, inst, dt, __bt_px__;
                    fill_price=__bt_px__ * __bt_dn__, mark_first=false)

                __bt_ok__ = $cond
                if __bt_ok__
                    $signal_ex
                end

                push!(sig_v, __bt_ok__ ?
                    Advanced_Backtester.__tofloat($track_inner) : NaN)
                push!(eq_t, dt); push!(eq_v, equity(acc, usd))
                __bt_collect_dd__(dt, eq_v[end])
                push!(pos_v, get_position(acc, inst).quantity)
            end
            close_position!(acc, inst, __bt_dts__[end], __bt_closes__[end]; mark_first=false)
            push!(eq_t, __bt_dts__[end]); push!(eq_v, equity(acc, usd))
            __bt_collect_dd__(__bt_dts__[end], eq_v[end])
            Advanced_Backtester.BacktestResult(eq_t, eq_v, pos_v, sig_v,
                copy(__bt_dd__.dates), copy(Base.values(__bt_dd__)),
                Advanced_Backtester.__drawdown_mode_sym(__bt_dd_mode__),
                __bt_dd_period__,
                acc, inst, usd, collect(acc.trades), WARMUP, __bt_lag__, __bt_dep__)
        end
    end
    return esc(body)
end

end # module
