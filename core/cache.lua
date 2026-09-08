module 'EasyAH.util.info'

local T = require 'T'
local EasyAH = require 'EasyAH'
local persistence = require 'EasyAH.util.persistence'

local MIN_ITEM_ID = 1
local MAX_ITEM_ID = 30000

local items_schema = {'tuple', '#', {name='string'}, {quality='number'}, {level='number'}, {class='string'}, {subclass='string'}, {slot='string'}, {max_stack='number'}, {texture='string'}}
local merchant_buy_schema = {'tuple', '#', {unit_price='number'}, {limited='boolean'}}

function EasyAH.handle.LOAD()
	scan_wdb()

	EasyAH.event_listener('MERCHANT_SHOW', on_merchant_show)
	EasyAH.event_listener('MERCHANT_CLOSED', on_merchant_closed)
	EasyAH.event_listener('MERCHANT_UPDATE', on_merchant_update)
	EasyAH.event_listener('BAG_UPDATE', on_bag_update)

	CreateFrame('Frame', nil, MerchantFrame):SetScript('OnUpdate', merchant_on_update)

	EasyAH.event_listener('NEW_AUCTION_UPDATE', function()
		local data = auction_sell_item()
		if data then
			local item_id = item_id(data.name)
			if item_id then
				EasyAH.account_data.merchant_sell[item_id] = data.vendor_price / (max_item_charges(item_id) or data.count)
			end
		end
	end)
end

do
	local characters = {}
	function M.is_player(name)
		return not not characters[name]
	end
	function EasyAH.handle.LOAD()
		characters = EasyAH.realm_data.characters
		for k, v in characters do
			if type(v) ~= 'number' or time() > v + 60 * 60 * 24 * 30 then
				characters[k] = nil
			end
		end
		characters[UnitName'player'] = time()
	end
end

do
	local sell_scan_queued, incomplete_buy_data
	function on_merchant_show()
		merchant_sell_scan()
		incomplete_buy_data = not merchant_buy_scan()
	end
	function on_merchant_closed()
		sell_scan_queued = nil
		incomplete_buy_data = false
	end
	function on_merchant_update()
		if incomplete_buy_data then
			incomplete_buy_data = not merchant_buy_scan()
		end
	end
	function on_bag_update()
		if MerchantFrame:IsVisible() then
			sell_scan_queued = true
		end
	end
	function merchant_on_update()
		if sell_scan_queued then
			sell_scan_queued = nil
			merchant_sell_scan()
		end
	end
end

function merchant_loaded()
	for i = 1, GetMerchantNumItems() do
		if not GetMerchantItemLink(i) then
			return false
		end
	end
	return true
end

function M.merchant_info(item_id)
	local buy_info
	if EasyAH.account_data.merchant_buy[item_id] then
		buy_info = persistence.read(merchant_buy_schema, EasyAH.account_data.merchant_buy[item_id])
	end
	return EasyAH.account_data.merchant_sell[item_id], buy_info and buy_info.unit_price, buy_info and buy_info.limited
end

-- Vendor sell price used by the tooltip, anywhere in the world.
--
-- The 1.12.1 client never exposes an item's vendor price to addons, so the only
-- prices EasyAH can know are the ones it recorded itself: bag items scanned
-- while a merchant window was open, and items placed into the auction sell
-- slot. EasyAH also ships a built-in vanilla price database
-- (data/vendor_prices.lua) as a fallback, so that even items the player never
-- carried are priced out of the box; the ShaguTweaks database is consulted too
-- when that addon is installed.
--
-- Returns the unit price plus a flag telling whether it came from such an
-- external database instead of our own observations.
local external_price_databases = {
	function() return ShaguTweaks and ShaguTweaks.SellValueDB end,
	function() return EasyAH_VendorPriceDB end,
}

function M.vendor_sell_price(item_id)
	if not item_id or item_id == 0 then return end

	local own_price = EasyAH.account_data.merchant_sell[item_id]
	if type(own_price) == 'number' and own_price >= 0 then return own_price, false end

	-- Charge items (oils, gadgets) are listed at the price for all charges in
	-- external databases, matching how the game itself reports them.
	local charges = max_item_charges(item_id) or 1
	for _, get_database in ipairs(external_price_databases) do
		local database = get_database()
		if type(database) == 'table' then
			local price = tonumber(database[item_id])
			if price and price > 0 then
				return price / charges, true
			end
		end
	end
end

-- How many items we currently hold a vendor sell / buy price for.
local function table_size(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

function M.vendor_price_count()
	local db_count = type(EasyAH_VendorPriceDB) == 'table' and table_size(EasyAH_VendorPriceDB) or 0
	return table_size(EasyAH.account_data.merchant_sell), table_size(EasyAH.account_data.merchant_buy), db_count
end

function M.item_info(item_id)
	local data_string = EasyAH.account_data.items[item_id]
	if data_string then
		local cached_data = persistence.read(items_schema, data_string)
		return T.map(
			'name', cached_data.name,
			'itemstring', 'item:' .. item_id .. ':0:0:0',
			'quality', cached_data.quality,
			'level', cached_data.level,
			'class', cached_data.class,
			'subclass', cached_data.subclass,
			'slot', cached_data.slot,
			'max_stack', cached_data.max_stack,
			'texture', cached_data.texture
		)
	end
end

function M.item_id(item_name)
	return EasyAH.account_data.item_ids[strlower(item_name)]
end

function merchant_buy_scan()
	local incomplete_data
	for i = 1, GetMerchantNumItems() do
		local _, _, price, count, stock = GetMerchantItemInfo(i)
		local link = GetMerchantItemLink(i)
		if link then
			local item_id = parse_link(link)
			local new_unit_price, new_limited = price / count, stock >= 0
			if EasyAH.account_data.merchant_buy[item_id] then
				local buy_info = persistence.read(merchant_buy_schema, EasyAH.account_data.merchant_buy[item_id])

				local unit_price
				if buy_info.limited and not new_limited then
					unit_price = new_unit_price
				elseif new_limited and not buy_info.limited then
					unit_price = buy_info.unit_price
				else
					unit_price = min(buy_info.unit_price, new_unit_price)
				end

                EasyAH.account_data.merchant_buy[item_id] = persistence.write(merchant_buy_schema, T.temp-T.map(
					'unit_price', unit_price,
					'limited', buy_info.limited and new_limited
				))
			else
				EasyAH.account_data.merchant_buy[item_id] = persistence.write(merchant_buy_schema, T.temp-T.map(
					'unit_price', new_unit_price,
					'limited', new_limited
				))
			end
		else
			incomplete_data = true
		end
	end

	return not incomplete_data
end

function merchant_sell_scan()
	for slot in inventory() do
		T.temp(slot)
		local item_info = T.temp-container_item(unpack(slot))
		if item_info then
			EasyAH.account_data.merchant_sell[item_info.item_id] = item_info.tooltip_money / item_info.aux_quantity
		end
	end
end

function scan_wdb(item_id)
	item_id = item_id or MIN_ITEM_ID

	local processed = 0
	while processed < 100 and item_id <= MAX_ITEM_ID do
		local itemstring = 'item:' .. item_id
		local name, _, quality, level, class, subclass, max_stack, slot, texture = GetItemInfo(itemstring)
		if name and not EasyAH.account_data.item_ids[strlower(name)] then
            EasyAH.account_data.item_ids[strlower(name)] = item_id
			EasyAH.account_data.items[item_id] = persistence.write(items_schema, T.temp-T.map(
				'name', name,
				'quality', quality,
				'level', level,
				'class', class,
				'subclass', subclass,
				'slot', slot,
				'max_stack', max_stack,
				'texture', texture
			))
			local tooltip = tooltip('link', itemstring)
			if auctionable(tooltip, quality) then
				tinsert(EasyAH.account_data.auctionable_items, strlower(name))
			end
		end
		processed = processed + 1
		item_id = item_id + 1
	end

	if item_id <= MAX_ITEM_ID then
		EasyAH.thread(EasyAH.when, EasyAH.later(.5), scan_wdb, item_id)
	else
		sort(EasyAH.account_data.auctionable_items, function(a, b) return strlen(a) < strlen(b) or (strlen(a) == strlen(b) and a < b) end)
	end
end

function M.populate_wdb(item_id)
	item_id = item_id or MIN_ITEM_ID
	if item_id > MAX_ITEM_ID then
		EasyAH.print('Cache populated.')
		return
	end
	if not GetItemInfo('item:' .. item_id) then
		EasyAH.print('Fetching item ' .. item_id .. '.')
		EasyAHTooltip:SetHyperlink('item:' .. item_id)
	end
	EasyAH.thread(populate_wdb, item_id + 1)
end
function M.rebuild_cache()
    EasyAH.account_data.items = {}
    EasyAH.account_data.item_ids = {}
    EasyAH.account_data.auctionable_items = {}
    scan_wdb()
end
