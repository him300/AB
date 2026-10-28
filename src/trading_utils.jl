# trading_utils.jl
# Reusable open/close helpers for Fastback.jl (https://github.com/rbeeli/Fastback.jl.git)
# Two functions only:
# - `open_position!`  — enter long/short, loop-safe
# - `close_position!` — exit (full or partial), loop-safe
# Design: call inside any `for (dt, price)` loop. Strategy logic stays OUTSIDE.
using Fastback
using Dates

"""
    open_position!(acc, inst, dt, price; kwargs...) -> Union{Trade, Nothing}

Open (or add to) a position. Safe to call every bar inside a backtest loop.

# Args
- `acc`, `inst` : Fastback account + instrument
- `dt` : bar timestamp (must be >= account clock & last mark)
- `price` : reference price (used for mark + default fill)

# Kwargs
- `side::Symbol = :long` — `:long` or `:short`
- `quantity::Real = 1.0` — base-asset qty. Ignored if `notional` given.
- `notional::Real = NaN` — quote-currency size, e.g. `notional=1_000` buys `1000/price` units.
  Overrides `quantity` when finite.
- `fill_price::Real = price` — actual execution price (models slippage by passing worse price)
- `bid::Real = fill_price, ask::Real = fill_price, last::Real = fill_price` — quote legs
- `allow_add::Bool = false` — if `false` (default) and a position in the SAME direction
  already exists, do nothing and return `nothing`. If `true`, pyramids.
- `allow_reverse::Bool = false` — if `false` and position is OPPOSITE direction,
  do nothing (call `close_position!` first). If `true`, flips exposure.
- `take_profit, stop_loss` — passed through to `create_order!`
- `is_maker::Bool = false`, `trade_reason = Fastback.TradeReason.Normal`
- `mark_first::Bool = true` — call `update_marks!` before ordering (recommended)

Returns the `Trade`, or `nothing` if skipped.
"""
function open_position!(
    acc,
    inst,
    dt,
    price::Real;
    side::Symbol=:long,
    quantity::Real=1.0,
    notional::Real=NaN,
    fill_price::Real=price,
    bid::Real=fill_price,
    ask::Real=fill_price,
    last::Real=fill_price,
    allow_add::Bool=false,
    allow_reverse::Bool=false,
    take_profit::Real=NaN,
    stop_loss::Real=NaN,
    is_maker::Bool=false,
    trade_reason=Fastback.TradeReason.Normal,
    mark_first::Bool=true,
)
    @assert side === :long || side === :short "side must be :long or :short, got $side"

    # Resolve size → signed quantity
    qty = isfinite(notional) ? notional / fill_price : quantity
    qty = side === :long ? abs(qty) : -abs(qty)
    (isfinite(qty) && qty != 0) || return nothing

    pos = Fastback.get_position(acc, inst)
    cur = pos.quantity

    if cur != 0
        same_dir = sign(cur) == sign(qty)
        if same_dir && !allow_add
            return nothing # already in — skip (loop-safe)
        elseif !same_dir && !allow_reverse
            return nothing # opposite exposure — caller must close first
        end
    end

    if mark_first
        Fastback.update_marks!(acc, inst, dt, bid, ask, last)
    end
    order = Fastback.create_order!(acc, inst, dt, price, qty;
        take_profit=take_profit, stop_loss=stop_loss)
    return Fastback.fill_order!(acc, order;
        dt=dt, fill_price=fill_price, bid=bid, ask=ask, last=last,
        is_maker=is_maker, trade_reason=trade_reason)
end

"""
    close_position!(acc, inst, dt, price; kwargs...) -> Union{Trade, Nothing}

Close (full or partial) the current position. Safe to call every bar.

# Kwargs
- `fraction::Real = 1.0` — `1.0` = flat, `0.5` = halve, etc. Clamped to (0, 1].
- `fill_price::Real = price`, `bid, ask, last` — execution + quote legs
- `is_maker, trade_reason, mark_first` — as in `open_position!`

Returns the closing `Trade`, or `nothing` if already flat.
"""
function close_position!(
    acc,
    inst,
    dt,
    price::Real;
    fraction::Real=1.0,
    fill_price::Real=price,
    bid::Real=fill_price,
    ask::Real=fill_price,
    last::Real=fill_price,
    is_maker::Bool=false,
    trade_reason=Fastback.TradeReason.Normal,
    mark_first::Bool=true,
)
    pos = Fastback.get_position(acc, inst)
    cur = pos.quantity
    cur == 0 && return nothing # flat — nothing to do (loop-safe)

    frac = clamp(fraction, eps(), 1.0)
    qty = -cur * frac # opposite sign → reduces exposure
    qty == 0 && return nothing

    if mark_first
        Fastback.update_marks!(acc, inst, dt, bid, ask, last)
    end
    order = Fastback.create_order!(acc, inst, dt, price, qty)
    return Fastback.fill_order!(acc, order;
        dt=dt, fill_price=fill_price, bid=bid, ask=ask, last=last,
        is_maker=is_maker, trade_reason=trade_reason)
end


using Dates

function datetime_range(x::DateTime, y::DateTime, unit::Symbol)
    step = Dict(
        :second => Second(1),
        :minute => Minute(1),
        :hour   => Hour(1),
        :day    => Day(1),
        :week   => Week(1),
        :month  => Month(1),
        :year   => Year(1),
    )[unit]
    return collect(x:step:y)
end   
