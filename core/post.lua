module 'EasyAH.core.post'

local EasyAH = require 'EasyAH'
local info = require 'EasyAH.util.info'
local stack = require 'EasyAH.core.stack'
local history = require 'EasyAH.core.history'
local disenchant = require 'EasyAH.core.disenchant'

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
	local t = EasyAH.account_data.autoprice
	local v = t and t[key]
	if v == nil then return AUTOPRICE_DEFAULTS[key] end
	return v
end

function EasyAH.handle.CLOSE()
	stop()
end

function process()
	if state.posted < state.count then

		local stacking_complete

		local send_signal, signal_received = EasyAH.signal()
		EasyAH.when(signal_received, function()
			local slot = signal_received()[1]
			if slot then
				return post_auction(slot, process)
			else
				return stop()
			end
		end)

		return stack.start(state.item_key, state.stack_size, send_signal)
	end

	return stop()
end

function post_auction(slot, k)
	local item_info = info.container_item(unpack(slot))
	if item_info.item_key == state.item_key and info.auctionable(item_info.tooltip, nil, true) and item_info.aux_quantity == state.stack_size then

		ClearCursor()
		ClickAuctionSellItemButton()
		ClearCursor()
		PickupContainerItem(unpack(slot))
		ClickAuctionSellItemButton()
		ClearCursor()
		
		local start_price = state.unit_start_price
		local buyout_price = state.unit_buyout_price
		
		-- use autoprice heuristic if start bid 0 is set
		if start_price == 0 then
			local status
			start_price, buyout_price, status = auto_price(state.item_key, item_info.item_id, item_info.slot, item_info.quality, item_info.level, buyout_price)
			if status == 'disenchant' then
				print("EasyAH: autopricing recommends disenchanting!")
				return stop()
			elseif status == 'vendor' then
				print("EasyAH: autopricing recommends vendoring!")
				return stop()
			elseif status == 'insufficient' then
				print("EasyAH: insufficient data for autopricing!")
				return stop()
			elseif status == 'review' then
				print("EasyAH: price looks off (far above historical value) - review and post manually!")
				return stop()
			elseif status == 'review_thin_market' then
				print("EasyAH: too few competing listings to trust the market price - review and post manually!")
				return stop()
			end
			local gold = floor(start_price / COPPER_PER_GOLD)
			local silver = floor(mod(start_price, COPPER_PER_GOLD) / COPPER_PER_SILVER)
			local copper = EasyAH.round(mod(start_price, COPPER_PER_SILVER))
			print("bid_price: "..gold.."g "..silver.."s "..copper.."c")
			gold = floor(buyout_price / COPPER_PER_GOLD)
			silver = floor(mod(buyout_price, COPPER_PER_GOLD) / COPPER_PER_SILVER)
			copper = EasyAH.round(mod(buyout_price, COPPER_PER_SILVER))
			print("buyout_price: "..gold.."g "..silver.."s "..copper.."c")
		end
		StartAuction(max(1, EasyAH.round(start_price * item_info.aux_quantity)), EasyAH.round(buyout_price * item_info.aux_quantity), state.duration)

		local send_signal, signal_received = EasyAH.signal()
		EasyAH.when(signal_received, function()
			state.posted = state.posted + 1
			return k()
		end)

		local posted
		EasyAH.event_listener('CHAT_MSG_SYSTEM', function(kill)
			if arg1 == ERR_AUCTION_STARTED then
				send_signal()
				kill()
			end
		end)
	else
		return stop()
	end
end

function M.stop()
	if state then
		EasyAH.kill_thread(state.thread_id)

		local callback = state.callback
		local posted = state.posted

		state = nil

		if callback then
			callback(posted)
		end
	end
end

function M.start(item_key, stack_size, duration, unit_start_price, unit_buyout_price, count, callback)
	stop()
	state = {
		thread_id = EasyAH.thread(process),
		item_key = item_key,
		stack_size = stack_size,
		duration = duration,
		unit_start_price = unit_start_price,
		unit_buyout_price = unit_buyout_price,
		count = count,
		posted = 0,
		callback = callback,
	}
end

function round_price(c)
	if c >= 10 * COPPER_PER_SILVER then
		return max(1, floor(c / COPPER_PER_SILVER + 0.5) * COPPER_PER_SILVER)
	end
	return c
end

function M.auto_price(item_key, item_id, slot, quality, level, unit_buyout_price)
	-- Data sources (read once).
	local market = history.market_value(item_key)      -- live market floor from this session's scan (or nil)
	local historical = history.value(item_key)          -- long-term weighted value (or nil)
	local disench = disenchant.value(slot, quality, level, item_id)

	-- Vendor buy price (item purchasable from a vendor), if known.
	local vendor_buy
	if EasyAH.account_data.merchant_buy[item_id] ~= nil then
		vendor_buy = tonumber(strsub(tostring(EasyAH.account_data.merchant_buy[item_id]), 1, -3))
	end
	-- Vendor sell price (what a vendor pays you for it), if known.
	local vendor_price = 0
	if EasyAH.account_data.merchant_sell[item_id] ~= nil then
		vendor_price = tonumber(EasyAH.account_data.merchant_sell[item_id])
	elseif ShaguTweaks and ShaguTweaks.SellValueDB[item_id] ~= nil then
		local charges = 1
		if info.max_item_charges(item_id) ~= nil then
			charges = info.max_item_charges(item_id)
		end
		vendor_price = ShaguTweaks.SellValueDB[item_id] / charges
	end

	-- 1) BASE BUYOUT PRICE from a single source, by priority (waterfall):
	--    user-typed buyout > live market (undercut) > historical value >
	--    vendor buy price > rough vendor estimate. No source -> insufficient.
	local buyout_price
	local used_market_source = false
	if unit_buyout_price and unit_buyout_price > 0 then
		buyout_price = unit_buyout_price
	elseif market ~= nil then
		buyout_price = max(1, tonumber(market) - 1)
		used_market_source = true
	elseif historical ~= nil then
		buyout_price = cfg('value_buyout') * tonumber(historical)
	elseif vendor_buy then
		buyout_price = vendor_buy * cfg('merchant_buy_buyout')
	elseif vendor_price > 0 then
		buyout_price = vendor_price * (cfg('vendor_base') + cfg('vendor_amp') * math.exp(-(1/cfg('vendor_decay')) * vendor_price))
	else
		return 0, 0, 'insufficient'
	end

	-- 2) Bid is a fixed fraction of the buyout.
	local start_price = cfg('bid_vs_buyout') * buyout_price

	-- 3) GATES: decide whether this should be auto-posted at all. Each returns a
	--    status so the caller (Post / Post All) skips it and lets the user decide.
	-- Better to disenchant than to sell.
	if disench ~= nil and buyout_price < cfg('de_reco_factor') * tonumber(disench) - cfg('de_reco_flat') then
		return start_price, buyout_price, 'disenchant'
	end
	-- Worth so little that selling to a vendor beats auctioning.
	if vendor_price > 0 then
		local ref = market or historical
		if ref and tonumber(ref) < cfg('vendor_reco') * vendor_price then
			return start_price, buyout_price, 'vendor'
		end
	end
	-- Market looks manipulated / very thin (price far above historical value).
	if cfg('review_multiple') > 0 and historical ~= nil then
		local hv = tonumber(historical)
		if hv > 0 and buyout_price > cfg('review_multiple') * hv then
			return start_price, buyout_price, 'review'
		end
	end
	-- Live market floor built from very few competing auctions (e.g. only 1-2
	-- asking prices) is not a reliable price signal - flag for manual review
	-- instead of auto-posting with false confidence.
	if used_market_source and cfg('min_market_sample') > 0 and history.market_count(item_key) < cfg('min_market_sample') then
		return start_price, buyout_price, 'review_thin_market'
	end

	if EasyAH.account_data.round_prices then
		start_price = round_price(start_price)
		buyout_price = max(start_price, round_price(buyout_price))
	end
	return start_price, buyout_price
end
