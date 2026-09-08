module 'EasyAH.core.history'

local T = require 'T'
local EasyAH = require 'EasyAH'

local persistence = require 'EasyAH.util.persistence'

local history_schema = {'tuple', '#', {next_push='number'}, {daily_min_buyout='number'}, {data_points={'list', ';', {'tuple', '@', {value='number'}, {time='number'}}}}}

local value_cache = {}
local markets = {faction={}, neutral={}}
local context = 'faction'
local serial = 0

function M.select_market(neutral)
    context = neutral and 'neutral' or 'faction'
    if EasyAH.faction_data then
        data = neutral and EasyAH.faction_data.history_neutral or EasyAH.faction_data.history
    end
    value_cache = {}
end
function M.context() return context end
function EasyAH.handle.LOAD2() select_market(false) end

-- A snapshot is private to ONE complete exact-item scan. Empty is a valid
-- completed result; incomplete/aborted scans are never published.
function M.new_snapshot(keys)
    serial = serial + 1
    local s = {id=serial, context=context, items={}, started=GetTime()}
    for _, key in ipairs(keys or {}) do
        s.items[key] = {samples={}, count=0, sellers={}, owner_complete=true}
    end
    return s
end
function M.observe(s, ar)
    local v = s.items[ar.item_key]
    if not v or ar.buyout_price <= 0 then return end
    if not ar.owner then v.owner_complete = false; return end
    if require('EasyAH.util.info').is_player(ar.owner) then return end
    v.count = v.count + 1
    v.sellers[ar.owner] = true
    tinsert(v.samples, {value=ar.unit_buyout_price, weight=ar.aux_quantity})
end
function M.commit(s)
    if s.context ~= context then return false end
    for _, v in s.items do if not v.owner_complete then return false end end
    for key, v in s.items do
        local pct = tonumber(EasyAH.account_data.market_percentile) or 0
        pct = max(0, min(100, pct))
        v.value = weighted_percentile(v.samples, pct / 100)
        v.time, v.id, v.complete = GetTime(), s.id, true
        v.seller_count = EasyAH.size(v.sellers)
        v.samples = nil
        markets[context][key] = v
    end
    return true
end
function M.invalidate(item_key)
    markets[context][item_key] = nil
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
	local record
    if data[item_key] then
        local ok, result = pcall(persistence.read, history_schema, data[item_key])
        if ok and type(result) == 'table' and type(result.next_push) == 'number' and type(result.data_points) == 'table' then record = result end
    end
    record = record or new_record()
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

function M.process_auction(ar)
    if not ar.aux_quantity or ar.aux_quantity <= 0 or not ar.buyout_price or ar.buyout_price <= 0 then return end
    local price = ar.buyout_price / ar.aux_quantity
    local record = read_record(ar.item_key)
    if price < (record.daily_min_buyout or EasyAH.huge) then
        record.daily_min_buyout = price
        write_record(ar.item_key, record)
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

function M.market_status(item_key)
    local v = markets[context][item_key]
    if not v then return nil, 'not_scanned' end
    if GetTime() - v.time > (EasyAH.account_data.market_ttl or 300) then return nil, 'stale' end
    return v
end
function M.market_value(item_key)
    local v = market_status(item_key)
    return v and v.value
end
function M.market_count(item_key)
    local v = market_status(item_key)
    return v and v.count or 0
end
function M.daily_value(item_key) return read_record(item_key).daily_min_buyout end

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
	for _, v in ipairs(list) do
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