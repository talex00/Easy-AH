module 'EasyAH.core.post'
local EasyAH = require 'EasyAH'
local info = require 'EasyAH.util.info'
local stack = require 'EasyAH.core.stack'
local history = require 'EasyAH.core.history'
local disenchant = require 'EasyAH.core.disenchant'
local safety = require 'EasyAH.core.safety'
local state

M.AUTOPRICE_DEFAULTS = {
	value_buyout = 0.95,
	daily_buyout = 0.50,
	daily_start = 0.80,
	merchant_buy_start = 1.1,
	merchant_buy_buyout = 1.15,
	vendor_base = 1.35,
	vendor_amp = 3.65,
	vendor_decay = 4000,
	vendor_flat = 1.35,
	disenchant_start = 0.85,
	bid_vs_buyout = 0.91,
	de_reco_factor = 0.95,
	de_reco_flat = 30,
	vendor_reco = 1.35,
	review_multiple = 5,
	min_market_sample = 3,
}


function cfg(key)
    local v = tonumber((EasyAH.account_data.autoprice or {})[key])
    if not safety.finite(v) or v < 0 then return AUTOPRICE_DEFAULTS[key] end
    if (key == 'value_buyout' or key == 'merchant_buy_buyout' or key == 'vendor_base' or key == 'vendor_decay' or key == 'bid_vs_buyout') and v <= 0 then return AUTOPRICE_DEFAULTS[key] end
    if key == 'bid_vs_buyout' then return min(1, v) end
    return v
end
function M.valid_duration(d) return d == 120 or d == 480 or d == 1440 end
function M.busy() return state ~= nil end
function M.cut() return history.context() == 'neutral' and .15 or .05 end
function M.undercut(unit_price, quantity, own)
    local total = ceil(unit_price * quantity)
    if not own then
        local mode = EasyAH.account_data.undercut_mode or 'fixed'
        local amount = tonumber(EasyAH.account_data.undercut) or 1
        if not safety.finite(amount) then amount = 1 end
        amount = max(0, amount)
        if mode == 'percent' then total = total - ceil(total * min(100, amount) / 100)
        elseif mode ~= 'match' then total = total - floor(amount) end
    end
    return max(1, total) / quantity
end
local function round_price(c)
    if c >= 1000 then return max(1, floor(c / 100 + .5) * 100) end
    return c
end
function M.auto_price(key, item_id, slot, quality, level, typed_buyout, quantity)
    quantity = quantity or 1
    local snap, reason = history.market_status(key)
    local market = snap and snap.value
    local historical = history.value(key)
    local de = disenchant.value(slot, quality, level, item_id)
    local vendor = info.vendor_sell_price(item_id)
    local _, vendor_buy = info.merchant_info(item_id)
    local bp, source
    if typed_buyout and typed_buyout > 0 then bp, source = typed_buyout, 'manual_buyout'
    elseif not snap then return 0, 0, 'scan_required'
    elseif market then
        if snap.count < cfg('min_market_sample') then return 0, 0, 'review_thin_market' end
        bp, source = undercut(market, quantity), 'market'
    elseif historical and historical > 0 then bp, source = historical * cfg('value_buyout'), 'history'
    elseif vendor_buy and vendor_buy > 0 then bp, source = vendor_buy * cfg('merchant_buy_buyout'), 'vendor_buy'
    elseif vendor and vendor > 0 then
        bp = vendor * (cfg('vendor_base') + cfg('vendor_amp') * math.exp(-vendor / cfg('vendor_decay')))
        source = 'vendor_estimate'
    else return 0, 0, 'insufficient' end
    local sp = bp * cfg('bid_vs_buyout')
    if not safety.finite(bp) or bp <= 0 or not safety.finite(sp) or sp <= 0 then return 0, 0, 'invalid_price' end
    if de and bp < cfg('de_reco_factor') * de - cfg('de_reco_flat') then return sp, bp, 'disenchant' end
    if cfg('review_multiple') > 0 and historical and historical > 0 and bp > cfg('review_multiple') * historical then return sp, bp, 'review' end
    if EasyAH.account_data.round_prices then sp, bp = round_price(sp), round_price(bp) end
    return sp, max(sp, bp), nil, source
end

-- Same quote object drives preview and StartAuction. Prices are rounded once
-- per lot. Vendor/charge quantities are normalized by util.info.
function M.quote(key, ii, qty, duration, sp, bp)
    if not ii or not safety.finite(qty) or qty < 1 or qty ~= floor(qty) or not valid_duration(duration) then return nil, 'invalid_parameters' end
    if not safety.finite(sp) or not safety.finite(bp) or sp < 0 or bp < 0 then return nil, 'invalid_price' end
    local source, status = 'manual', nil
    local automatic = sp == 0
    if automatic then sp, bp, status, source = auto_price(key, ii.item_id, ii.slot, ii.quality, ii.level, bp, qty) end
    if status then return nil, status end
    local bid, buyout = max(1, EasyAH.round(sp * qty)), EasyAH.round(bp * qty)
    if not safety.money(bid) or bid < 1 or not safety.money(buyout) or (buyout > 0 and bid > buyout) or (automatic and buyout < 1) then return nil, 'invalid_price' end
    local vendor = info.vendor_sell_price(ii.item_id)
    if vendor == nil then return nil, 'vendor_unknown' end
    local vendor_total = vendor * qty
    local margin = max(0, tonumber(EasyAH.account_data.min_profit_margin) or 5)
    local minimum = ceil(vendor_total * (1 + margin / 100))
    local bid_net, buyout_net = floor(bid * (1 - cut())), buyout > 0 and floor(buyout * (1 - cut())) or nil
    local low = bid_net < minimum or (buyout_net and buyout_net < minimum)
    return {bid=bid, buyout=buyout, unit_bid=bid/qty, unit_buyout=buyout/qty, source=source,
        vendor=vendor_total, bid_net=bid_net, buyout_net=buyout_net, low_profit=low,
        created=GetTime(), context=history.context(), automatic=automatic}
end
function M.reason_text(reason)
    local labels = {scan_required='Refresh this item: market missing or stale', review_thin_market='Too few competing auctions',
        insufficient='Not enough price data', vendor_unknown='Vendor price unknown; select the item first',
        low_profit='Starting bid or buyout below the vendor safety floor', invalid_price='Invalid bid/buyout',
        invalid_parameters='Invalid quantity/duration', disenchant='Disenchanting may be better',
        review='Price far above history: review manually', insufficient_money='Not enough money for deposit'}
    return labels[reason] or tostring(reason or '')
end
local function finish(result, detail)
    if not state then return end
    local s = state
    state = nil
    EasyAH.kill_thread(s.thread_id)
    stack.stop('cancelled')
    if result ~= 'success' then safety.log('post', result, detail or s.item_key) end
    if s.callback then EasyAH.thread(s.callback, s.posted, result, detail) end
end
function M.stop(reason)
    if not state then return end
    finish('cancelled', reason or 'Stopped')
    safety.cancel(reason or 'Posting stopped')
end
function EasyAH.handle.CLOSE() stop('Auction closed') end
local process, post_lot
post_lot = function(s, slot)
    if state ~= s then return end
    local ii = info.container_item(unpack(slot))
    if not ii or ii.locked or ii.item_key ~= s.item_key or ii.aux_quantity ~= s.stack_size or not info.auctionable(ii.tooltip, nil, true) then return finish('failed', 'Inventory changed') end
    if CursorHasItem() then return finish('failed', 'Cursor is occupied') end
    -- Populate sell slot, then verify it before sending any monetary action.
    ClickAuctionSellItemButton(); ClearCursor()
    PickupContainerItem(unpack(slot)); ClickAuctionSellItemButton(); ClearCursor()
    local sell = info.auction_sell_item()
    if not sell or sell.name ~= ii.name or sell.count ~= ii.count then return finish('failed', 'Sell slot mismatch') end
    -- API sell value is full-charge value, so normalize explicitly here too.
    EasyAH.account_data.merchant_sell[ii.item_id] = sell.vendor_price / (ii.max_charges or sell.count)
    local q, reason = quote(s.item_key, ii, s.stack_size, s.duration, s.unit_start_price, s.unit_buyout_price)
    if not q then return finish('failed', reason_text(reason)) end
    if q.low_profit and not s.options.allow_low_profit then return finish('failed', reason_text('low_profit')) end
    if s.options.expected and (q.bid ~= s.options.expected.bid or q.buyout ~= s.options.expected.buyout or q.context ~= s.options.expected.context) then return finish('failed', 'Price changed since confirmation') end
    if not CalculateAuctionDeposit then return finish('failed', 'CalculateAuctionDeposit unavailable on this client') end
    local deposit = CalculateAuctionDeposit(s.duration)
    if not safety.money(deposit) or GetMoney() < deposit then return finish('failed', reason_text('insufficient_money')) end
    local id, error = safety.begin('post', ERR_AUCTION_STARTED, function() StartAuction(q.bid, q.buyout, s.duration) end,
        function(result, detail)
            if state ~= s then return end
            if result ~= 'success' then return finish(result, detail) end
            s.posted = s.posted + 1
            s.thread_id = EasyAH.thread(process)
        end, ii.name .. ' x' .. s.stack_size, q.buyout)
    if not id then return finish('failed', error) end
end
process = function()
    local s = state
    if not s then return end
    if s.options.expected and GetTime() - s.options.expected.created > 300 then return finish('failed', 'Confirmed price expired; build a fresh plan') end
    if not safety.is_open() then return finish('cancelled', 'Auction closed') end
    if s.posted >= s.count then return finish('success') end
    stack.start(s.item_key, s.stack_size, function(slot, result)
        if state ~= s then return end
        if not slot then return finish(result or 'failed', 'Could not assemble stack') end
        s.thread_id = EasyAH.thread(post_lot, s, slot)
    end)
end
function M.start(key, size, duration, sp, bp, count, callback, options)
    if state or safety.busy() or safety.blocked() or not safety.is_open() then
        if callback then EasyAH.thread(callback, 0, 'failed', 'Busy, closed, or uncertain operation') end
        return false
    end
    if not safety.finite(size) or size < 1 or size ~= floor(size) or not safety.finite(count) or count < 1 or count ~= floor(count) or not valid_duration(duration) then
        if callback then EasyAH.thread(callback, 0, 'failed', 'Invalid quantity/duration') end
        return false
    end
    state = {item_key=key, stack_size=size, duration=duration, unit_start_price=sp, unit_buyout_price=bp,
        count=count, posted=0, callback=callback, options=options or {}}
    state.thread_id = EasyAH.thread(process)
    return true
end
