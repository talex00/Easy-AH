module 'EasyAH.core.history'

local T = require 'T'
local EasyAH = require 'EasyAH'

local persistence = require 'EasyAH.util.persistence'

local history_schema = {'tuple', '#', {next_push='number'}, {daily_min_buyout='number'}, {data_points={'list', ';', {'tuple', '@', {value='number'}, {time='number'}}}}}

local value_cache = {}
local samples = {}

-- session_market holds the CURRENT market floor per item, taken from this
-- session's scans and kept ONLY in memory (never saved to disk). This is what
-- auto-price undercuts. Before an item is scanned this session there is no
-- value (nil), so the algorithm falls back to the historical value instead of
-- a stale cached number. Each scan bumps scan_generation; the first sighting
-- of an item in a scan resets its floor, later sightings keep the minimum.
local session_market = {}
-- Number of distinct competing auctions (excluding our own) that the current
-- market floor is based on. A floor built from only 1-2 asking lots is not a
-- reliable price signal (those sellers may just be guessing) -- auto-price
-- uses this to require a minimum sample before trusting the market floor.
local session_market_count = {}
local scan_generation = 0
local item_generation = {}

function M.begin_scan()
	scan_generation = scan_generation + 1
end

function EasyAH.handle.LOAD2()
	data = EasyAH.faction_data.history
end

do
	local next_push = 0
	function get_next_push()
		if time() > next_push then
			local date = date('*t')
			date.hour, date.min, date.sec = 24, 0, 0
			next_push = time(date)
		end
		return next_push
	end
end

function new_record()
	return T.temp-T.map('next_push', get_next_push(), 'data_points', T.acquire())
end

function read_record(item_key)
	local record = data[item_key] and persistence.read(history_schema, data[item_key]) or new_record()
	if record.next_push <= time() then
		push_record(record)
		write_record(item_key, record)
	end
	return record
end

function write_record(item_key, record)
	data[item_key] = persistence.write(history_schema, record)
	if value_cache[item_key] then
		T.release(value_cache[item_key])
		value_cache[item_key] = nil
	end
end

function M.process_auction(auction_record)
	local unit_buyout_price = ceil(auction_record.buyout_price / auction_record.aux_quantity)
	if unit_buyout_price <= 0 then return end
	local key = auction_record.item_key

	-- 1) Live market floor for pricing (in-memory, rebuilt fresh each scan).
	local fresh = item_generation[key] ~= scan_generation
	item_generation[key] = scan_generation
	local pct = EasyAH.account_data.market_percentile
	if pct and pct > 0 then
		if fresh and samples[key] then
			T.release(samples[key])
			samples[key] = nil
		end
		samples[key] = samples[key] or T.acquire()
		tinsert(samples[key], T.map('value', unit_buyout_price, 'weight', auction_record.aux_quantity or 1))
		local robust = weighted_percentile(samples[key], pct / 100)
		if robust then session_market[key] = robust end
	elseif fresh or unit_buyout_price < (session_market[key] or EasyAH.huge) then
		session_market[key] = unit_buyout_price
	end

	-- 2) Persisted daily low, used ONLY to build the long-term historical value
	--    (data_points) at day rollover. Never used directly for live pricing.
	local item_record = read_record(key)
	if unit_buyout_price < (item_record.daily_min_buyout or EasyAH.huge) then
		item_record.daily_min_buyout = unit_buyout_price
		write_record(key, item_record)
	end
end

function M.data_points(item_key)
	return read_record(item_key).data_points
end

function M.value(item_key)
	if not value_cache[item_key] or value_cache[item_key].next_push <= time() then
		local item_record, value
		item_record = read_record(item_key)
		if getn(item_record.data_points) > 0 then
			local total_weight, weighted_values = 0, T.temp-T.acquire()
			for _, data_point in item_record.data_points do
				local weight = .99 ^ EasyAH.round((item_record.data_points[1].time - data_point.time) / (60 * 60 * 24))
				total_weight = total_weight + weight
				tinsert(weighted_values, T.map('value', data_point.value, 'weight', weight))
			end
			for _, weighted_value in weighted_values do
				weighted_value.weight = weighted_value.weight / total_weight
			end
			value = weighted_median(weighted_values)
		else
			value = item_record.daily_min_buyout
		end
		value_cache[item_key] = T.map('value', value, 'next_push', item_record.next_push)
	end
	return value_cache[item_key].value
end

-- The live market floor from this session's scans (in-memory only). Returns
-- nil if the item has not been scanned yet this session.
function M.market_value(item_key)
	return session_market[item_key]
end

-- How many competing auctions (excluding our own) the current market floor is
-- based on. Returns 0 if the item has not been scanned yet this session.
function M.market_count(item_key)
	return session_market_count[item_key] or 0
end

-- Set the live market floor directly (from a completed scan's visible lots,
-- excluding our own auctions), along with how many competing auctions were
-- seen. In-memory only, never persisted.
function M.set_market_value(item_key, value, count)
	if value and value > 0 then
		session_market[item_key] = value
		session_market_count[item_key] = count or 0
	end
end

function weighted_median(list)
	sort(list, function(a,b) return a.value < b.value end)
	local weight = 0
	for _, v in ipairs(list) do
		weight = weight + v.weight
		if weight >= .5 then
			return v.value
		end
	end
end

function weighted_percentile(list, p)
	sort(list, function(a, b) return a.value < b.value end)
	local total = 0
	for _, v in list do total = total + v.weight end
	if total == 0 then return end
	local threshold = total * p
	local cum = 0
	for _, v in list do
		cum = cum + v.weight
		if cum >= threshold then return v.value end
	end
end

function push_record(item_record)
	if item_record.daily_min_buyout then
		tinsert(item_record.data_points, 1, T.map('value', item_record.daily_min_buyout, 'time', item_record.next_push))
		while getn(item_record.data_points) > 11 do
			T.release(item_record.data_points[getn(item_record.data_points)])
			tremove(item_record.data_points)
		end
	end
	item_record.next_push, item_record.daily_min_buyout = get_next_push(), nil
end