module 'EasyAH.tabs.post'

local T = require 'T'
local EasyAH = require 'EasyAH'
local info = require 'EasyAH.util.info'
local sort_util = require 'EasyAH.util.sort'
local persistence = require 'EasyAH.util.persistence'
local money = require 'EasyAH.util.money'
local scan_util = require 'EasyAH.util.scan'
local post = require 'EasyAH.core.post'
local scan = require 'EasyAH.core.scan'
local history = require 'EasyAH.core.history'
local search = require 'EasyAH.tabs.search'
local item_listing = require 'EasyAH.gui.item_listing'
local al = require 'EasyAH.gui.auction_listing'
local gui = require 'EasyAH.gui'

local tab = EasyAH.tab 'Post'

local settings_schema = {'tuple', '#', {duration='number'}, {start_price='number'}, {buyout_price='number'}, {hidden='boolean'}}

local scan_id, inventory_records, bid_records, buyout_records = 0, {}, {}, {}

-- minutes. WoW Classic 1.12.1 auction durations = 2h / 8h / 24h (NOT Turtle's 6/24/72).
M.DURATION_2, M.DURATION_8, M.DURATION_24 = 120, 480, 1440

refresh = true

selected_item = nil

function get_default_settings()
	return T.map('duration', EasyAH.account_data.post_duration, 'start_price', 0, 'buyout_price', 0, 'hidden', false)
end

function EasyAH.handle.LOAD2()
	data = EasyAH.faction_data.post
end

function read_settings(item_key)
	item_key = item_key or selected_item.key
	return data[item_key] and persistence.read(settings_schema, data[item_key]) or get_default_settings()
end
function write_settings(settings, item_key)
	item_key = item_key or selected_item.key
	data[item_key] = persistence.write(settings_schema, settings)
end

do
	local bid_selections, buyout_selections = {}, {}
	function get_bid_selection()
		return bid_selections[selected_item.key]
	end
	function set_bid_selection(record)
		bid_selections[selected_item.key] = record
	end
	function get_buyout_selection()
		return buyout_selections[selected_item.key]
	end
	function set_buyout_selection(record)
		buyout_selections[selected_item.key] = record
	end
end

function refresh_button_click()
	scan.abort(scan_id)
	refresh_entries()
	refresh = true
end

function tab.OPEN()
    frame:Show()
    update_inventory_records()
    refresh = true
end

function tab.CLOSE()
    selected_item = nil
    frame:Hide()
end

function tab.USE_ITEM(item_info)
	select_item(item_info.item_key)
end

function get_unit_start_price()
	return selected_item and read_settings().start_price or 0
end

function set_unit_start_price(amount)
	local settings = read_settings()
	settings.start_price = amount
	write_settings(settings)
end

function get_unit_buyout_price()
	return selected_item and read_settings().buyout_price or 0
end

function set_unit_buyout_price(amount)
	local settings = read_settings()
	settings.buyout_price = amount
	write_settings(settings)
end

function update_inventory_listing()
	local records = EasyAH.values(EasyAH.filter(EasyAH.copy(inventory_records), function(record)
		local settings = read_settings(record.key)
		return record.aux_quantity > 0 and (not settings.hidden or show_hidden_checkbox:GetChecked())
	end))
	sort(records, function(a, b) return a.name < b.name end)
	item_listing.populate(inventory_listing, records)
end

function update_auction_listing(listing, records, reference)
	local rows = T.acquire()
	if selected_item then
		local historical_value = history.value(selected_item.key)
		local stack_size = stack_size_slider:GetValue()
		for _, record in records[selected_item.key] or T.empty do
			local price_color = undercut(record, stack_size_slider:GetValue(), listing == 'bid') < reference and EasyAH.color.red
			local price = record.unit_price * (listing == 'bid' and record.stack_size / stack_size_slider:GetValue() or 1)
			tinsert(rows, T.map(
				'cols', T.list(
				T.map('value', record.own and EasyAH.color.green(record.count) or record.count),
				T.map('value', al.time_left(record.duration)),
				T.map('value', record.stack_size == stack_size and EasyAH.color.green(record.stack_size) or record.stack_size),
				T.map('value', money.to_string(price, true, nil, price_color)),
				T.map('value', historical_value and gui.percentage_historical(EasyAH.round(price / historical_value * 100)) or '---')
			),
				'record', record
			))
		end
		if historical_value then
			tinsert(rows, T.map(
				'cols', T.list(
				T.map('value', '---'),
				T.map('value', '---'),
				T.map('value', '---'),
				T.map('value', money.to_string(historical_value, true, nil, EasyAH.color.green)),
				T.map('value', historical_value and gui.percentage_historical(100) or '---')
			),
				'record', T.map('historical_value', true, 'stack_size', stack_size, 'unit_price', historical_value, 'own', true)
			))
		end
		sort(rows, function(a, b)
			return sort_util.multi_lt(
				a.record.unit_price * (listing == 'bid' and a.record.stack_size or 1),
				b.record.unit_price * (listing == 'bid' and b.record.stack_size or 1),

				a.record.historical_value and 1 or 0,
				b.record.historical_value and 1 or 0,

				b.record.own and 0 or 1,
				a.record.own and 0 or 1,

				a.record.stack_size,
				b.record.stack_size,

				a.record.duration,
				b.record.duration
			)
		end)
	end
	if listing == 'bid' then
		bid_listing:SetData(rows)
	elseif listing == 'buyout' then
		buyout_listing:SetData(rows)
	end
end

function update_auction_listings()
	update_auction_listing('bid', bid_records, get_unit_start_price())
	update_auction_listing('buyout', buyout_records, get_unit_buyout_price())
end

function M.select_item(item_key)
    for _, inventory_record in EasyAH.filter(EasyAH.copy(inventory_records), function(record) return record.aux_quantity > 0 end) do
        if inventory_record.key == item_key then
            update_item(inventory_record)
            return
        end
    end
end

function price_update()
    if selected_item then
        local historical_value = history.value(selected_item.key)
        if get_bid_selection() or get_buyout_selection() then
	        set_unit_start_price(undercut(get_bid_selection() or get_buyout_selection(), stack_size_slider:GetValue(), get_bid_selection()))
	        unit_start_price_input:SetText(money.to_string(get_unit_start_price(), true, nil, nil, true))
        end
        if get_buyout_selection() then
	        set_unit_buyout_price(undercut(get_buyout_selection(), stack_size_slider:GetValue()))
	        unit_buyout_price_input:SetText(money.to_string(get_unit_buyout_price(), true, nil, nil, true))
        end
        start_price_percentage:SetText(historical_value and gui.percentage_historical(EasyAH.round(get_unit_start_price() / historical_value * 100)) or '---')
        buyout_price_percentage:SetText(historical_value and gui.percentage_historical(EasyAH.round(get_unit_buyout_price() / historical_value * 100)) or '---')
    end
end

StaticPopupDialogs.EASYAH_POST_LOW_PROFIT = {
	text = 'Selling to a vendor would net more than this auction after fees and deposit. Post anyway?',
	button1 = 'Post Anyway',
	button2 = 'Cancel',
	OnAccept = function() do_post_auctions() end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

function do_post_auctions()
	if selected_item then
        local unit_start_price = get_unit_start_price()
        local unit_buyout_price = get_unit_buyout_price()
        local stack_size = stack_size_slider:GetValue()
        local stack_count
        stack_count = stack_count_slider:GetValue()
        local duration = UIDropDownMenu_GetSelectedValue(duration_dropdown)
		local key = selected_item.key

        local duration_code
		if duration == DURATION_2 then
            duration_code = 2
		elseif duration == DURATION_8 then
            duration_code = 3
		elseif duration == DURATION_24 then
            duration_code = 4
		end

		post.start(
			key,
			stack_size,
			duration,
            unit_start_price,
            unit_buyout_price,
			stack_count,
			function(posted)
				if not frame:IsShown() then
					return
				end
				if unit_start_price > 0 then
                    for i = 1, posted do
                        record_auction(key, stack_size, unit_start_price, unit_buyout_price, duration_code, UnitName'player')
                    end
                end
                update_inventory_records()
				local same
                for _, record in inventory_records do
                    if record.key == key then
	                    same = record
	                    break
                    end
                end
                if same then
	                update_item(same)
                else
                    selected_item = nil
                end
                refresh = true
			end
		)
	end
end

function post_auctions()
	if low_profit then
		StaticPopup_Show('EASYAH_POST_LOW_PROFIT')
	else
		do_post_auctions()
	end
end

function M.post_auctions_bind()
	post_auctions()
end

function M.unhide_all()
	if not data then return end
	local count = 0
	for item_key in data do
		local settings = read_settings(item_key)
		if settings.hidden then
			settings.hidden = false
			write_settings(settings, item_key)
			count = count + 1
		end
	end
	refresh = true
	EasyAH.print('Unhid ' .. count .. ' item(s)')
end

function M.post_all()
	if not frame:IsShown() or not data then return end
	local records = EasyAH.values(EasyAH.filter(EasyAH.copy(inventory_records), function(record)
		return record.aux_quantity > 0 and not read_settings(record.key).hidden
	end))
	sort(records, function(a, b) return a.name < b.name end)
	-- charge items (oils, scopes, etc.) can't be combined/split like normal stacks:
	-- each existing charge-level group becomes its own listing.
	local queue = {}
	for _, record in records do
		if record.max_charges then
			for charge_size = record.max_charges, 1, -1 do
				if (record.availability[charge_size] or 0) > 0 then
					tinsert(queue, {record = record, charge_size = charge_size, count = record.availability[charge_size]})
				end
			end
		else
			-- Post full stacks AND the leftover partial stack, so nothing stays
			-- in the bags (e.g. 36 items with max stack 10 = 3x10 + 1x6).
			local qty = record.aux_quantity or 0
			local ss = min(record.max_stack or 1, qty)
			if ss >= 1 then
				local full = floor(qty / ss)
				if full > 0 then
					tinsert(queue, {record = record, stack_size = ss, count = full})
				end
				local remainder = qty - full * ss
				if remainder > 0 then
					tinsert(queue, {record = record, stack_size = remainder, count = 1})
				end
			end
		end
	end
	local total = getn(queue)
	if total == 0 then
		EasyAH.print('Post All: no auctionable items')
		return
	end
	EasyAH.print('Post All: ' .. total .. ' listing(s)')
	local i = 0
	local last_scanned_key
	local function step()
		i = i + 1
		local entry = queue[i]
		if not entry then
			status_bar:update_status(1, 1)
			status_bar:set_text('Post All complete')
			update_inventory_records()
			refresh = true
			return
		end
		local record = entry.record
		local settings = read_settings(record.key)
		local start_price = (EasyAH.account_data.remember_prices and settings.start_price) or 0
		local buyout_price = (EasyAH.account_data.remember_prices and settings.buyout_price) or 0
		local stack_size, count
		if entry.charge_size then
			stack_size = entry.charge_size
			count = entry.count
		elseif entry.stack_size then
			stack_size = entry.stack_size
			count = entry.count
		else
			stack_size = min(record.max_stack or 1, record.aux_quantity or 0)
			count = floor((record.aux_quantity or 0) / stack_size)
		end
		if stack_size < 1 or not count or count < 1 then return step() end
		local duration = settings.duration or EasyAH.account_data.post_duration
		local duration_code = duration == DURATION_2 and 2 or duration == DURATION_8 and 3 or 4
		local function post_entry()
			status_bar:update_status(i / total, 0)
			status_bar:set_text('Posting ' .. record.name .. '...')
			post.start(record.key, stack_size, duration, start_price, buyout_price, count, function(posted)
				if start_price > 0 then
					for j = 1, posted do
						record_auction(record.key, stack_size, start_price, buyout_price, duration_code, UnitName'player')
					end
				end
				return step()
			end)
		end
		-- Scan this item's live market once before posting it, so auto-price
		-- undercuts the current floor instead of falling back to historical
		-- value. Entries for the same item are adjacent in the queue, so we
		-- only scan when the item changes. Skipped if prices are remembered.
		if not EasyAH.account_data.remember_prices and record.key ~= last_scanned_key then
			last_scanned_key = record.key
			status_bar:update_status(i / total, 0)
			status_bar:set_text('Scanning ' .. record.name .. '...')
			local scan_floor, scan_count = nil, 0
			scan_id = scan.start{
				type = 'list',
				ignore_owner = true,
				queries = T.list(scan_util.item_query(record.item_id)),
				on_auction = function(ar)
					if ar.item_key == record.key and ar.unit_buyout_price and ar.unit_buyout_price > 0 and not info.is_player(ar.owner) then
						scan_count = scan_count + 1
						if not scan_floor or ar.unit_buyout_price < scan_floor then scan_floor = ar.unit_buyout_price end
					end
				end,
				on_complete = function()
					if scan_floor then history.set_market_value(record.key, scan_floor, scan_count) end
					post_entry()
				end,
				on_abort = function()
					status_bar:update_status(1, 1)
					status_bar:set_text('Post All aborted')
				end,
			}
		else
			post_entry()
		end
	end
	step()
end

function validate_parameters()
    if not selected_item then
        post_button:Disable()
        return
    end
    if get_unit_buyout_price() > 0 and get_unit_start_price() > get_unit_buyout_price() then
        post_button:Disable()
        return
    end
    if get_unit_start_price() == 0 then
        post_button:Enable()
        return
    end
    if stack_count_slider:GetValue() == 0 then
        post_button:Disable()
        return
    end
    post_button:Enable()
end

function update_item_configuration()
	if not selected_item then
        refresh_button:Disable()

        item.texture:SetTexture(nil)
        item.count:SetText()
        item.name:SetTextColor(EasyAH.color.label.enabled())
        item.name:SetText('No item selected')

        unit_start_price_input:Hide()
        unit_buyout_price_input:Hide()
        stack_size_slider:Hide()
        stack_count_slider:Hide()
        deposit:Hide()
        profit:Hide()
        duration_dropdown:Hide()
        hide_checkbox:Hide()
    else
		unit_start_price_input:Show()
        unit_buyout_price_input:Show()
        stack_size_slider:Show()
        stack_count_slider:Show()
        deposit:Show()
        profit:Show()
        duration_dropdown:Show()
        hide_checkbox:Show()

        item.texture:SetTexture(selected_item.texture)
        item.name:SetText('[' .. selected_item.name .. ']')
		do
	        local color = ITEM_QUALITY_COLORS[selected_item.quality]
	        item.name:SetTextColor(color.r, color.g, color.b)
        end
		if selected_item.aux_quantity > 1 then
            item.count:SetText(selected_item.aux_quantity)
		else
            item.count:SetText()
        end

        stack_size_slider.editbox:SetNumber(stack_size_slider:GetValue())
        stack_count_slider.editbox:SetNumber(stack_count_slider:GetValue())

        do
            local deposit_factor = (GetAuctionHouseDepositRate and GetAuctionHouseDepositRate() / 100) or (UnitFactionGroup'npc' and .05 or .25)
            local duration_factor = UIDropDownMenu_GetSelectedValue(duration_dropdown) / 120
            local stack_size, stack_count = selected_item.max_charges and 1 or stack_size_slider:GetValue(), stack_count_slider:GetValue()
            local vp = selected_item.unit_vendor_price or 0
            -- Round only once, at the very end. Rounding per-unit first (before
            -- applying stack_count/duration) truncated cheap items to 0 deposit
            -- even though the real total (e.g. 15c vendor x 5% x 8h) is 3c+.
            local amount = floor(vp * deposit_factor * stack_size * stack_count * duration_factor)
            deposit:SetText('Deposit: ' .. (selected_item.unit_vendor_price and money.to_string(amount, nil, nil, EasyAH.color.text.enabled) or '?'))
            local cut = UnitFactionGroup'npc' and 0.05 or 0.15
            local total_qty = stack_size * stack_count
            local unit_buyout = get_unit_buyout_price()
            local using_auto = get_unit_start_price() == 0
            local auto_sp, auto_bp, auto_status
            local similar_items_available
            if using_auto then
                local ii = info.item(selected_item.item_id, selected_item.suffix_id)
                if ii then
                    auto_sp, auto_bp, auto_status = post.auto_price(selected_item.key, selected_item.item_id, ii.slot, ii.quality, ii.level, unit_buyout)
                    similar_items_available = auto_status == 'review_thin_market' and similar_items_query(ii)
                end
            end
            if similar_items_button then
                if similar_items_available then similar_items_button:Show() else similar_items_button:Hide() end
            end
            local effective_buyout = unit_buyout > 0 and unit_buyout or ((using_auto and not auto_status) and auto_bp or nil)
            local net
            if effective_buyout then
                net = floor(effective_buyout * total_qty * (1 - cut)) - amount
            end
            local vendor_total = selected_item.unit_vendor_price and (selected_item.unit_vendor_price * total_qty)
            low_profit = (net ~= nil and vendor_total ~= nil and net < vendor_total * (1 + (EasyAH.account_data.min_profit_margin or 0) / 100)) or false
            local ptext = ''
            if vendor_total then
                ptext = 'Vendor: ' .. money.to_string(vendor_total, nil, nil, low_profit and EasyAH.color.orange or EasyAH.color.text.enabled)
            end
            if net then
                if ptext ~= '' then ptext = ptext .. '  |  ' end
                ptext = ptext .. 'Net if sold: ' .. money.to_string(net, nil, nil, low_profit and EasyAH.color.red or (net >= 0 and EasyAH.color.green or EasyAH.color.red))
            end
            if using_auto then
                local a
                if auto_status == 'disenchant' then
                    a = 'Auto: ' .. EasyAH.color.orange('better to disenchant')
                elseif auto_status == 'vendor' then
                    a = 'Auto: bid ' .. money.to_string(EasyAH.round(auto_sp), nil, nil, EasyAH.color.orange) .. ' / buy ' .. money.to_string(EasyAH.round(auto_bp), nil, nil, EasyAH.color.orange) .. ' ' .. EasyAH.color.orange('(vendor better)')
                elseif auto_status == 'insufficient' then
                    a = 'Auto: ' .. EasyAH.color.red('no data')
                elseif auto_status == 'review' then
                    a = 'Auto: ' .. EasyAH.color.red('price looks off - review & post manually')
                elseif auto_status == 'review_thin_market' then
                    a = 'Auto: ' .. EasyAH.color.red('too few competing listings - review & post manually')
                elseif auto_sp then
                    a = 'Auto: bid ' .. money.to_string(EasyAH.round(auto_sp), nil, nil, EasyAH.color.green) .. ' / buy ' .. money.to_string(EasyAH.round(auto_bp), nil, nil, EasyAH.color.green)
                end
                if a then
                    if ptext == '' then ptext = a else ptext = ptext .. '\n' .. a end
                end
            end
            profit:SetText(ptext)
        end

        refresh_button:Enable()
	end
end

-- Builds a text search filter (same syntax as the Search tab's filter box)
-- for items "like" this one: same class/subclass/slot, a nearby level range,
-- and the same quality. Only meaningful for gear (weapons/armor), where a
-- narrow level band of the same slot tends to sell in a similar range -
-- unlike consumables/reagents/recipes, where the exact item defines its own
-- market and a category average would be meaningless.
function similar_items_query(item_info)
	if not item_info or not item_info.level or item_info.level == 0 then return end
	if item_info.class ~= 'Weapon' and item_info.class ~= 'Armor' then return end
	local level_span = 2
	local min_level = max(1, item_info.level - level_span)
	local max_level = item_info.level + level_span
	local quality_name = item_info.quality and _G['ITEM_QUALITY' .. item_info.quality .. '_DESC']
	local query = strlower(item_info.class)
	if item_info.subclass and item_info.subclass ~= '' then query = query .. '/' .. strlower(item_info.subclass) end
	if item_info.slot and item_info.slot ~= '' then query = query .. '/' .. strlower(item_info.slot) end
	query = query .. '/' .. min_level .. '/' .. max_level
	if quality_name then query = query .. '/' .. strlower(quality_name) end
	return query
end

function show_similar_items()
	if selected_item then
		local ii = info.item(selected_item.item_id, selected_item.suffix_id)
		local query = ii and similar_items_query(ii)
		if query then
			search.set_filter(query)
			search.execute()
			EasyAH.set_tab(1)
		end
	end
end

function undercut(record, stack_size, stack)
    local price = ceil(record.unit_price * (stack and record.stack_size or stack_size))
    if not record.own then
	    local umode = EasyAH.account_data.undercut_mode or 'fixed'
	    if umode == 'percent' then
	        price = price - ceil(price * (EasyAH.account_data.undercut or 1) / 100)
	    elseif umode ~= 'match' then
	        price = price - (EasyAH.account_data.undercut or 1)
	    end
	    price = max(1, price)
    end
    return price / stack_size
end

function quantity_update(maximize_count)
    if selected_item then
        local max_stack_count = selected_item.max_charges and selected_item.availability[stack_size_slider:GetValue()] or floor(selected_item.availability[0] / stack_size_slider:GetValue())
        stack_count_slider:SetMinMaxValues(1, max_stack_count)
        if maximize_count then
            stack_count_slider:SetValue(max_stack_count)
        end
    end
    refresh = true
end

function unit_vendor_price(item_key)
    if CursorHasItem() then return end
    for slot in info.inventory() do
	    T.temp(slot)
        local item_info = T.temp-info.container_item(unpack(slot))
        if item_info and item_info.item_key == item_key then
            if info.auctionable(item_info.tooltip, nil, true) and not item_info.lootable then
                ClearCursor()
                PickupContainerItem(unpack(slot))
                ClickAuctionSellItemButton()
                local auction_sell_item = T.temp-info.auction_sell_item()
                ClearCursor()
                ClickAuctionSellItemButton()
                ClearCursor()
                if auction_sell_item then
                    return auction_sell_item.vendor_price / auction_sell_item.count
                end
            end
        end
    end
end

function update_item(item)
    local settings = read_settings(item.key)

    item.unit_vendor_price = unit_vendor_price(item.key)

    scan.abort(scan_id)

    selected_item = item

    if not EasyAH.account_data.remember_prices then
        settings.start_price = 0
        settings.buyout_price = 0
        set_bid_selection()
        set_buyout_selection()
    end

    UIDropDownMenu_Initialize(duration_dropdown, initialize_duration_dropdown)
    UIDropDownMenu_SetSelectedValue(duration_dropdown, settings.duration)

    hide_checkbox:SetChecked(settings.hidden)
	
	local ii = 1
	if selected_item.max_charges then
		for i = selected_item.max_charges, 1, -1 do
			if selected_item.availability[i] > 0 then
				stack_size_slider:SetMinMaxValues(1, i)
				ii=i
				break
			end
		end
	else
		ii = min(selected_item.max_stack, selected_item.aux_quantity)
		stack_size_slider:SetMinMaxValues(1, min(selected_item.max_stack, selected_item.aux_quantity))
	end
		
	local smode = EasyAH.account_data.stack_mode or (EasyAH.account_data.post_stack and 'max' or 'random')
	if smode == 'random' then	
		stack_size_slider:SetValue(math.random(1,ii))
	else
		stack_size_slider:SetValue(EasyAH.huge)
		--stack_size_slider:SetValue(1)
	end

    quantity_update(true)

    unit_start_price_input:SetText(money.to_string(settings.start_price, true, nil, nil, true))
    unit_buyout_price_input:SetText(money.to_string(settings.buyout_price, true, nil, nil, true))

    if not bid_records[selected_item.key] then
        refresh_entries()
    end

    write_settings(settings, item.key)

    refresh = true
end

function update_inventory_records()
    local auctionable_map = T.temp-T.acquire()
    for slot in info.inventory() do
	    T.temp(slot)
	    local item_info = T.temp-info.container_item(unpack(slot))
        if item_info then
            local charge_class = item_info.charges or 0
            if info.auctionable(item_info.tooltip, nil, true) and not item_info.lootable then
                if not auctionable_map[item_info.item_key] then
                    local availability = T.acquire()
                    for i = 0, 10 do
                        availability[i] = 0
                    end
                    availability[charge_class] = item_info.count
                    auctionable_map[item_info.item_key] = T.map(
	                    'item_id', item_info.item_id,
	                    'suffix_id', item_info.suffix_id,
	                    'key', item_info.item_key,
	                    'itemstring', item_info.itemstring,
	                    'name', item_info.name,
	                    'texture', item_info.texture,
	                    'quality', item_info.quality,
	                    'aux_quantity', item_info.charges or item_info.count,
	                    'max_stack', item_info.max_stack,
	                    'max_charges', item_info.max_charges,
	                    'availability', availability
                    )
                else
                    local auctionable = auctionable_map[item_info.item_key]
                    auctionable.availability[charge_class] = (auctionable.availability[charge_class] or 0) + item_info.count
                    auctionable.aux_quantity = auctionable.aux_quantity + (item_info.charges or item_info.count)
                end
            end
        end
    end
    T.release(inventory_records)
    inventory_records = EasyAH.values(auctionable_map)
    refresh = true
end

function refresh_entries()
	if selected_item then
        local item_key = selected_item.key
		set_bid_selection()
        set_buyout_selection()
        bid_records[item_key], buyout_records[item_key] = nil, nil
        local query = scan_util.item_query(selected_item.item_id)
        status_bar:update_status(0, 0)
        status_bar:set_text('Scanning auctions...')

		scan_id = scan.start{
            type = 'list',
            ignore_owner = true,
			queries = T.list(query),
			on_page_loaded = function(page, total_pages)
                status_bar:update_status(page / total_pages, 0) -- TODO
                status_bar:set_text(format('Scanning Page %d / %d', page, total_pages))
			end,
			on_auction = function(auction_record)
				if auction_record.item_key == item_key then
                    record_auction(
                        auction_record.item_key,
                        auction_record.aux_quantity,
                        auction_record.unit_blizzard_bid,
                        auction_record.unit_buyout_price,
                        auction_record.duration,
                        auction_record.owner
                    )
				end
			end,
			on_abort = function()
				bid_records[item_key], buyout_records[item_key] = nil, nil
                status_bar:update_status(1, 1)
                status_bar:set_text('Scan aborted')
			end,
			on_complete = function()
				bid_records[item_key] = bid_records[item_key] or T.acquire()
				buyout_records[item_key] = buyout_records[item_key] or T.acquire()
				-- Set the market floor directly from the scanned lots the user sees
				-- (excluding our own), so auto-price always undercuts the visible floor.
				local floor, count = nil, 0
				for _, r in buyout_records[item_key] do
					if not r.own then
						count = count + 1
						if not floor or r.unit_price < floor then
							floor = r.unit_price
						end
					end
				end
				if floor then history.set_market_value(item_key, floor, count) end
                refresh = true
                status_bar:update_status(1, 1)
                status_bar:set_text('Scan complete')
            end,
		}
	end
end

function record_auction(key, aux_quantity, unit_blizzard_bid, unit_buyout_price, duration, owner)
    bid_records[key] = bid_records[key] or T.acquire()
    do
	    local entry
	    for _, record in bid_records[key] do
	        if unit_blizzard_bid == record.unit_price and aux_quantity == record.stack_size and duration == record.duration and info.is_player(owner) == record.own then
	            entry = record
	        end
	    end
	    if not entry then
	        entry = T.map('stack_size', aux_quantity, 'unit_price', unit_blizzard_bid, 'duration', duration, 'own', info.is_player(owner), 'count', 0)
	        tinsert(bid_records[key], entry)
	    end
	    entry.count = entry.count + 1
    end
    buyout_records[key] = buyout_records[key] or T.acquire()
    if unit_buyout_price == 0 then return end
    do
	    local entry
	    for _, record in buyout_records[key] do
		    if unit_buyout_price == record.unit_price and aux_quantity == record.stack_size and duration == record.duration and info.is_player(owner) == record.own then
			    entry = record
		    end
	    end
	    if not entry then
		    entry = T.map('stack_size', aux_quantity, 'unit_price', unit_buyout_price, 'duration', duration, 'own', info.is_player(owner), 'count', 0)
		    tinsert(buyout_records[key], entry)
	    end
	    entry.count = entry.count + 1
    end
end

function on_update()
    if refresh then
        refresh = false
        price_update()
        update_item_configuration()
        update_inventory_listing()
        update_auction_listings()
    end
    validate_parameters()
end

function initialize_duration_dropdown()
    local function on_click()
        UIDropDownMenu_SetSelectedValue(duration_dropdown, this.value)
        local settings = read_settings()
        settings.duration = this.value
        write_settings(settings)
        refresh = true
    end
    UIDropDownMenu_AddButton{
        text = '2 Hours',
        value = DURATION_2,
        func = on_click,
    }
    UIDropDownMenu_AddButton{
        text = '8 Hours',
        value = DURATION_8,
        func = on_click,
    }
    UIDropDownMenu_AddButton{
        text = '24 Hours',
        value = DURATION_24,
        func = on_click,
    }
end
