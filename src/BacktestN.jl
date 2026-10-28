# BacktestN.jl — @backtestN: N accounts × N strategies, one shared bar loop.
#
# Included by Advanced_Backtester.jl (inside `module Advanced_Backtester`,
# so every `__collect_refs!` / `__max_lag` / `__auto_warmup` / ... helper and
# `BacktestResult` / `backtest_stats` is directly visible).
#
# Usage — one leg per `deposit => strategy`, no brackets needed for
# single-expression strategies (`begin...end` works too):
#
#   res = @backtestN(dts, closes,
#       10_000.0 => begin
#           fast[i-1] > slow[i-1] && long!()
#           fast[i-1] < slow[i-1] && flat!()
#       end,
#       25_000.0 => rsi[i-1] < 30 ? long!() : (rsi[i-1] > 70 ? flat!() : nothing),
#       10_000.0 => begin
#           ... third strategy ...
#       end => (notional=2_000.0,);
#       fee_pct=0.001, slippage_bps=10.0)
#
#   # res::Vector{BacktestResult} — one per leg, in leg order
#   backtest_stats.(res)          # stats per account
#   plot(res[1].eq_t, res[1].eq_v)
#
# Rules:
#   - Shared kwargs are defaults for EVERY leg: one fee_pct / slippage_bps /
#     funding / symbol / notional / fill / opens / drawdown setup covers all
#     N accounts (that is the point: same fees, one loop).
#   - The trailing `=> (kw=...)` tuple overrides ONE leg only. Allowed keys:
#     funding, symbol, notional, quantity, allow_reverse, allow_add, warmup,
#     guard, track. (fee_pct / slippage_bps / fill / opens / drawdown knobs
#     are shared-only — the error tells you if you try.)
#   - DSL names work exactly like @backtest, resolved PER LEG: acc/inst/usd,
#     WARMUP, long!/short!/flat! (+ raw open_position!/close_position! with
#     mark_first=false — the shared loop already marked every account).
#     i/dt/price are shared (same bar for all legs).
#   - Each leg gets its own guard chain (bounds + isfinite + guard=), its own
#     :auto warmup (slowest-n-plus-2 over the arrays THAT leg reads), its own
#     equity/position/signal/drawdown vectors and its own final flatten.
#   - A leg whose strategy repeats an entry needs allow_add=true (shared or
#     per-leg) to pyramid — same silent no-pyramid default as @backtest.
#   - Opposite-direction flips need allow_reverse=true (or flat!() first).

# Leg-level knobs a per-leg trailing tuple may override. Shared kwargs are
# the defaults for every leg; the override tuple wins per leg.
const __N_LEG_KEYS__ = (:funding, :symbol, :notional, :quantity,
    :allow_reverse, :allow_add, :warmup, :guard, :track)

"""Split `deposit => strategy` or `deposit => strategy => (kw=…)` into
`(deposit_expr, strategy_expr, override_dict)`. `=>` is left-assoc so the
triple parses as `((deposit => strategy) => overrides)`."""
function __split_leg(ex)
    if ex isa Expr && ex.head === :call && length(ex.args) == 3 &&
            ex.args[1] === Symbol("=>")
        lhs, rhs = ex.args[2], ex.args[3]
        # triple form: (deposit => strategy) => (override tuple / single assign)
        if lhs isa Expr && lhs.head === :call && length(lhs.args) == 3 &&
                lhs.args[1] === Symbol("=>")
            dep, strat = lhs.args[2], lhs.args[3]
            ov = Dict{Symbol,Any}()
            items = (rhs isa Expr && rhs.head === :tuple) ? rhs.args : Any[rhs]
            for it in items
                k, v = nothing, nothing
                if it isa Expr && it.head === :(=) &&
                        length(it.args) == 2 && it.args[1] isa Symbol
                    k, v = it.args[1], it.args[2]
                elseif it isa Expr && it.head === :call && length(it.args) == 3 &&
                        it.args[1] === Symbol("=>") && it.args[2] isa Symbol
                    k, v = it.args[2], it.args[3]   # (notional => 2000) friendly form
                else
                    error("@backtestN: per-leg overrides must look like " *
                        "(name=value, …); got `$it`")
                end
                k in __N_LEG_KEYS__ ||
                    error("@backtestN: cannot override `$k` per leg (allowed: " *
                        "$(join(__N_LEG_KEYS__, ", "))). " *
                        "Put it in the shared kwargs instead.")
                ov[k] = v
            end
            return (dep, strat, ov)
        end
        # plain form: deposit => strategy (strategy may be ANY expression —
        # single line, ternary, begin block — no brackets required)
        return (lhs, rhs, Dict{Symbol,Any}())
    end
    error("@backtestN: each leg must look like `deposit => strategy` or " *
        "`deposit => strategy => (kw=…)`; got `$ex`")
end

"""Unwrap `guard=(a, b)` / `guard=a` into a vector of raw exprs."""
function __guard_list(g)
    if g isa Expr && (g.head === :tuple || g.head === :vect)
        return Any[a for a in g.args]
    end
    return Any[g]
end

"""Names the DSL owns per leg — excluded from warmup-base detection."""
__n_reserved() = (:i, :dt, :price, :acc, :inst, :usd, :WARMUP,
    :long!, :short!, :flat!, :open_position!, :close_position!)

macro backtestN(args...)
    pos = Any[]
    kws = Dict{Symbol,Any}()
    for a in args
        if a isa Expr && a.head === :parameters
            for p in a.args
                p isa Expr && p.head === :kw ||
                    error("@backtestN kwargs must look like name=value; got `$p`")
                kws[p.args[1]] = p.args[2]
            end
        else
            push!(pos, a)
        end
    end
    length(pos) >= 3 || error(
        "usage: @backtestN(dts, closes, deposit => strategy, " *
        "[deposit => strategy …]; kwargs...) — " *
        "got $(length(pos)) positional args. " *
        "NOTE: kwargs need a `;`: @backtestN(dts, closes, 10_000 => begin … end; fee_pct=0.001)")
    dts_ex, closes_ex = pos[1], pos[2]
    leg_exprs = pos[3:end]

    for k in keys(kws)
        k in (:funding, :fee_pct, :symbol, :notional, :quantity,
              :slippage_bps, :allow_reverse, :allow_add, :warmup, :guard,
              :track, :fill, :opens, :precompute, :drawdown_mode,
              :drawdown_period) ||
            error("@backtestN: unknown kwarg `$k`")
    end

    getkw(name, default) = haskey(kws, name) ? kws[name] : QuoteNode(default)

    fill_sym = haskey(kws, :fill) ? kws[:fill] : :close
    fill_sym isa QuoteNode && (fill_sym = fill_sym.value)
    fill_sym in (:close, :next_open) ||
        error("@backtestN: fill must be :close or :next_open, got `$fill_sym`")
    if fill_sym === :next_open && !haskey(kws, :opens)
        error("@backtestN: fill=:next_open requires opens=... (BACKTEST_SYTHESIS.md §4E)")
    end
    shared_opens = haskey(kws, :opens) ? kws[:opens] : nothing
    precompute_inner = haskey(kws, :precompute) ? kws[:precompute] : nothing
    shared_guard = haskey(kws, :guard) ? __guard_list(kws[:guard]) : Any[]
    shared_track = haskey(kws, :track) ? kws[:track] : nothing
    shared_warmup = haskey(kws, :warmup) ? kws[:warmup] : nothing
    dd_mode_ex = getkw(:drawdown_mode, :percentage)
    dd_period_ex = haskey(kws, :drawdown_period) ?
        kws[:drawdown_period] : :(Advanced_Backtester.__zero_period())

    # --- per-leg analysis (guards + lag + warmup bases, like @backtest) ---
    legs = Any[]   # (dep, strat, ov, guards, track, refs, warmup_or_nothing, lag)
    for leg in leg_exprs
        dep, strat, ov = __split_leg(leg)
        gextra = copy(shared_guard)
        haskey(ov, :guard) && append!(gextra, __guard_list(ov[:guard]))
        refs = __collect_refs!(strat, Any[], Set{String}())
        lag = __max_lag(strat)
        for g in gextra
            lag = max(lag, __max_lag(g))
        end
        trk = haskey(ov, :track) ? ov[:track] : shared_track
        trk !== nothing && (lag = max(lag, __max_lag(trk)))
        if isempty(refs)
            @warn("@backtestN: a leg has no `ARR[i-k]` reads — no finiteness " *
                "guard emitted for it. Index precomputed vectors at `i-1` " *
                "(BACKTEST_SYTHESIS.md §3) or pass guard=(...) explicitly.")
        else
            lag = max(lag, 1)   # any lagged read needs i ≥ 2
        end
        for r in refs
            r isa Expr && r.head === :ref && __has_bare_i(r) &&
                !(r.args[1] === :opens && fill_sym === :next_open) &&
                @warn("@backtestN: same-bar read `$(r)` detected — trading " *
                    "index-`i` values at closes[i] is lookahead " *
                    "(BACKTEST_SYTHESIS.md §7.1). Use `i-1`. " *
                    "(`opens[i]` with fill=:next_open is exempt.)")
        end
        push!(legs, (dep, strat, ov, gextra, trk, refs,
            haskey(ov, :warmup) ? ov[:warmup] : shared_warmup, lag))
    end

    # --- per-leg shared-kwarg resolution (override tuple wins) ---
    nlegs = length(legs)
    leg_fund = Any[]; leg_sym = Any[]
    leg_not = Any[]; leg_qty = Any[]   # notional/quantity exprs (open_position! ignores qty when notional finite)
    leg_rev = Any[]; leg_add = Any[]
    for (_dep, _strat, ov, _g, _t, _r, _w, _l) in legs
        push!(leg_fund, haskey(ov, :funding) ? ov[:funding] : getkw(:funding, :fullyfunded))
        push!(leg_sym, haskey(ov, :symbol) ? ov[:symbol] : getkw(:symbol, :ABC))
        if haskey(ov, :notional)
            push!(leg_not, :(Float64($(ov[:notional])))); push!(leg_qty, :(1.0))
        elseif haskey(ov, :quantity)
            push!(leg_not, :(NaN)); push!(leg_qty, :(Float64($(ov[:quantity]))))
        elseif haskey(kws, :quantity) && !haskey(kws, :notional)
            push!(leg_not, :(NaN)); push!(leg_qty, :(Float64($(kws[:quantity]))))
        else
            push!(leg_not, :(Float64($(haskey(kws, :notional) ? kws[:notional] : 1_000.0))))
            push!(leg_qty, :(1.0))
        end
        push!(leg_rev, haskey(ov, :allow_reverse) ? ov[:allow_reverse] : getkw(:allow_reverse, false))
        push!(leg_add, haskey(ov, :allow_add) ? ov[:allow_add] : getkw(:allow_add, false))
    end

    px_inner = fill_sym === :close ? :price : :(Float64(__bt_opens__[i]))

    # --- codegen: suffix every macro-owned name per leg; user exprs stay raw ---
    setup_stmts = Any[]    # accounts + vectors + warmups, one block per leg
    loop_stmts = Any[]     # per-bar: mark, helpers, guard, strategy, record
    tail_stmts = Any[]     # flatten + BacktestResult per leg
    for (j, (dep, strat, _ov, gextra, trk, refs, warmup_opt, lag)) in enumerate(legs)
        S = string("__btn", j, "__")
        q = (n) -> Symbol(S * n)
        acc, inst, usd = q("acc"), q("inst"), q("usd")
        depv, symv = q("dep"), q("sym")
        rev, add = q("rev"), q("add")
        eq_t, eq_v, pos_v, sig_v = q("eq_t"), q("eq_v"), q("pos_v"), q("sig_v")
        ddcall, ddv = q("collect_dd"), q("dd")
        ddmode, ddper = q("dd_mode"), q("dd_period")
        warm, lagv = q("WARMUP"), q("lag")
        ok, px = q("ok"), q("px")
        not_ex, qty_ex = leg_not[j], leg_qty[j]

        cond = :(i > max($warm, $lagv))
        for r in refs
            term = (r isa Expr && r.head === :ref && __has_colon(r)) ?
                :(all(isfinite, $r)) : :(isfinite($r))
            cond = Expr(:&&, cond, term)
        end
        for g in gextra
            cond = Expr(:&&, cond, g)
        end

        base_syms = Symbol[]
        seen_b = Set{Symbol}()
        reserved = __n_reserved()
        for r in refs
            r isa Expr && r.head === :ref && r.args[1] isa Symbol || continue
            b = r.args[1]::Symbol
            b in reserved && continue
            b ∉ seen_b && (push!(seen_b, b); push!(base_syms, b))
        end
        bases_tuple = Expr(:tuple, base_syms...)
        warmup_inner = warmup_opt === nothing ?
            :(Advanced_Backtester.__auto_warmup($bases_tuple)) : warmup_opt
        track_inner = trk !== nothing ? trk :
            isempty(refs) ? :(NaN) : refs[1]

        # The SAME dsl names (acc/inst/usd, WARMUP, long!/short!/flat!) resolve
        # to THIS leg's suffixed locals via `let` — no expression rewriting,
        # so arbitrary user code (ifs, ternaries, locals) stays intact.
        strat_local = quote
            let acc = $acc, inst = $inst, usd = $usd, WARMUP = $warm,
                long! = (() -> open_position!($acc, $inst, dt, $px;
                    side=:long, notional=$not_ex, quantity=$qty_ex,
                    fill_price=$px * __bt_up__, allow_add=$add,
                    allow_reverse=$rev, mark_first=false)),
                short! = (() -> open_position!($acc, $inst, dt, $px;
                    side=:short, notional=$not_ex, quantity=$qty_ex,
                    fill_price=$px * __bt_dn__, allow_add=$add,
                    allow_reverse=$rev, mark_first=false)),
                flat! = (() -> close_position!($acc, $inst, dt, $px;
                    fill_price=$px * __bt_dn__, mark_first=false))
                $strat
            end
        end

        push!(setup_stmts, quote
            $depv = Float64($dep)
            $rev = Bool($(leg_rev[j]))
            $add = Bool($(leg_add[j]))
            $symv = Symbol($(leg_sym[j]))
            $acc = Account(; funding=Advanced_Backtester.__funding($(leg_fund[j])),
                base_currency=CashSpec(:USD),
                broker=FlatFeeBroker(pct=__bt_fee__))
            $usd = cash_asset($acc, :USD)
            deposit!($acc, $usd, $depv)
            $inst = register_instrument!($acc, spot_instrument($symv, $symv, :USD))
            $ddmode = Advanced_Backtester.__drawdown_mode($dd_mode_ex)
            $ddper = Advanced_Backtester.__drawdown_period($dd_period_ex)
            $ddcall, $ddv = drawdown_collector($ddmode, $ddper)
            $warm = Int($warmup_inner)
            $warm >= 1 || throw(ArgumentError("@backtestN leg $j: warmup must be ≥ 1, got $($warm)"))
            $warm >= length(__bt_dts__) &&
                throw(ArgumentError("@backtestN leg $j: warmup ($($warm)) ≥ bar count " *
                    "($(length(__bt_dts__))) — nothing left to trade on"))
            $lagv = $lag
            $eq_t = DateTime[]; $eq_v = Float64[]
            $pos_v = Float64[]; $sig_v = Float64[]
        end)
        push!(loop_stmts, quote
            update_marks!($acc, $inst, dt, price, price, price)
            $px = $px_inner
            $ok = $cond
            if $ok
                $strat_local
            end
            push!($sig_v, $ok ?
                Advanced_Backtester.__tofloat($track_inner) : NaN)
            push!($eq_t, dt); push!($eq_v, equity($acc, $usd))
            $ddcall(dt, $eq_v[end])
            push!($pos_v, get_position($acc, $inst).quantity)
        end)
        push!(tail_stmts, quote
            close_position!($acc, $inst, __bt_dts__[end], __bt_closes__[end]; mark_first=false)
            push!($eq_t, __bt_dts__[end]); push!($eq_v, equity($acc, $usd))
            $ddcall(__bt_dts__[end], $eq_v[end])
            push!(__bt_results__,
                Advanced_Backtester.BacktestResult($eq_t, $eq_v, $pos_v, $sig_v,
                    copy($ddv.dates), copy(Base.values($ddv)),
                    Advanced_Backtester.__drawdown_mode_sym($ddmode),
                    $ddper,
                    $acc, $inst, $usd, collect($acc.trades), $warm, $lagv, $depv))
        end)
    end

    # Whole-body esc: scope-sharing DSL like @backtest — i/dt/price and user
    # exprs resolve to the loop/caller, macro-owned names use the __btnN__
    # prefix (plus shared __bt_ fee/slip/inputs). NO inner esc() anywhere
    # above: built raw, escaped once here.
    body = quote
        let __bt_dts__ = $dts_ex, __bt_closes__ = $closes_ex,
            __bt_opens__ = $(shared_opens === nothing ? nothing : shared_opens)
            Advanced_Backtester.__validate_inputs(__bt_dts__, __bt_closes__, __bt_opens__)
            $(precompute_inner === nothing ? nothing : precompute_inner)
            __bt_fee__ = Float64($(getkw(:fee_pct, 0.001)))
            __bt_bps__ = Float64($(getkw(:slippage_bps, 10.0)))
            __bt_up__ = 1.0 + __bt_bps__ / 10_000.0
            __bt_dn__ = 1.0 - __bt_bps__ / 10_000.0
            $(setup_stmts...)
            __bt_results__ = Advanced_Backtester.BacktestResult[]
            for i in eachindex(__bt_dts__)
                dt = __bt_dts__[i]
                price = __bt_closes__[i]
                $(loop_stmts...)
            end
            $(tail_stmts...)
            __bt_results__
        end
    end
    return esc(body)
end
