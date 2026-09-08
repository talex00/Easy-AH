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
local safety = require 'EasyAH.core.safety'
local batch, pending_post, pending_plan
local market_scanning = false
local latest_plan = {}

local tab = EasyAH.tab 'Post'

local settings_schema = {'tuple', '#', {duration='number'}, {start_price='number'}, {buyout_price='number'}, {hidden='boolean'}, {post_all_stack_size='number'}}

local scan_id, inventory_records, bid_records, buyout_records = 0, {}, {}, {}

-- minutes. WoW Classic 1.12.1 auction durations = 2h / 8h / 24h (NOT Turtle's 6/24/72).
M.DURATION_2, M.DURATION_8, M.DURATION_24 = 120, 480, 1440

refresh = true

selected_item = nil

function get_default_settings()
	return T.map('duration', EasyAH.account_data.post_duration, 'start_price', 0, 'buyout_price', 0, 'hidden', false, 'post_all_stack_size', 0)
end

function EasyAH.handle.LOAD2()
	data = EasyAH.faction_data.post
end

function read_settings(item_key)
	item_key = item_key or selected_item.key
	local settings
    if data[item_key] then
        local ok, value = pcall(persistence.read, settings_schema, data[item_key])
        if ok then settings = value end
    end
    settings = settings or get_default_settings()
    if not post.valid_duration(settings.duration) then settings.duration = EasyAH.account_data.post_duration end
    if not safety.finite(settings.start_price) or settings.start_price < 0 then settings.start_price = 0 end
    if not safety.finite(settings.buyout_price) or settings.buyout_price < 0 then settings.buyout_price = 0 end
    if not safety.finite(settings.post_all_stack_size) or settings.post_all_stack_size < 0 or settings.post_all_stack_size ~= floor(settings.post_all_stack_size) then settings.post_all_stack_size = 0 end
    return settings
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
    if batch or post.busy() or safety.busy() then return end
	scan.abort(scan_id)
	refresh_entries()
	refresh = true
end

function tab.OPEN()
    EasyAH.frame:SetHeight(600)
    fit_post_window()
    frame:Show()
    update_inventory_records()
    refresh = true
end

function tab.CLOSE()
    stop_all()
    selected_item = nil
    frame:Hide()
    EasyAH.frame:SetHeight(447)
    EasyAH.frame:SetScale(EasyAH.account_data.scale or 1)
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

local function item_details(record)
    local ii = info.item(record.item_id, record.suffix_id)
    if ii then ii.item_id = record.item_id end
    return ii
end
local function start_confirmed(p, allow_low)
    if not p or p.session ~= safety.session_id() or not safety.is_open() or GetTime() - p.created > 60 then
        EasyAH.print('Confirmation expired; refresh and try again.'); return
    end
    post.start(p.key, p.size, p.duration, p.q.unit_bid, p.q.unit_buyout, p.count, function(posted, result, detail)
        if result ~= 'success' then EasyAH.print('Posting stopped:', detail or result) end
        if frame:IsShown() then update_inventory_records(); selected_item = nil; refresh = true end
    end, {allow_low_profit=allow_low, expected=p.q})
end
StaticPopupDialogs.EASYAH_POST_LOW_PROFIT = {
    text = 'Starting bid or buyout is below the vendor safety floor. Post this confirmed lot configuration anyway?',
    button1 = 'Post Anyway', button2 = 'Cancel', timeout = 0, whileDead = 1, hideOnEscape = 1,
    OnAccept = function() local p = pending_post; pending_post = nil; start_confirmed(p, true) end,
    OnCancel = function() pending_post = nil end,
}
function post_auctions()
    if not selected_item or market_scanning or batch or post.busy() or safety.busy() or safety.blocked() then return end
    if price_input_invalid then EasyAH.print('Correct the price input first.'); return end
    local size, count = stack_size_slider:GetValue(), stack_count_slider:GetValue()
    local duration = UIDropDownMenu_GetSelectedValue(duration_dropdown)
    if count < 1 then return end
    local q, reason = post.quote(selected_item.key, item_details(selected_item), size, duration, get_unit_start_price(), get_unit_buyout_price())
    if not q then EasyAH.print(post.reason_text(reason)); return end
    local p = {key=selected_item.key, size=size, count=count, duration=duration, q=q, session=safety.session_id(), created=GetTime()}
    if q.low_profit then pending_post = p; StaticPopup_Show('EASYAH_POST_LOW_PROFIT') else start_confirmed(p, false) end
end
function M.post_auctions_bind() post_auctions() end
function M.stop_all()
    batch, pending_plan, pending_post = nil, nil, nil
    market_scanning = false
    scan.abort(scan_id)
    post.stop('Stopped by user')
    safety.cancel('Stopped by user')
    safety.disarm()
    StaticPopup_Hide('EASYAH_POST_LOW_PROFIT')
    StaticPopup_Hide('EASYAH_POST_ALL_CONFIRM')
    refresh = true
end
function EasyAH.handle.CLOSE() stop_all() end
function M.show_plan()

    local tw = require 'EasyAH.gui.text_window'
    local lines = {}
    if getn(latest_plan) == 0 then tinsert(lines, 'No plan yet. Press Post All to prepare one; nothing is posted before confirmation.') end
    local b = pending_plan or batch
    if b then
        tinsert(lines, {text=format('Lots: %d  Skipped: %d  Est. deposit: %s', b.lots or 0, b.skipped or 0, money.to_string(b.deposits or 0, nil, true, nil, true)), r=0.8, g=0.8, b=1})
        tinsert(lines, '')
    end
    for _, line in ipairs(latest_plan) do
        local is_skip = strsub(line, 1, 4) == 'SKIP'
        if is_skip then
            tinsert(lines, {text=line, r=1, g=0.4, b=0.4})
        else
            tinsert(lines, {text=line, r=0.4, g=0.9, b=0.4})
        end
    end
    tw.show('EasyAHPlanWindow', 'Post All Plan', lines, 620, 440, show_plan)
end
function M.batch_busy() return batch ~= nil end

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

StaticPopupDialogs.EASYAH_POST_ALL_CONFIRM = {
    text = '%s', button1 = 'Post All', button2 = 'Cancel', timeout = 0, whileDead = 1, hideOnEscape = 1,
    OnAccept = function()
        local b = pending_plan
        pending_plan = nil
        if not b or batch ~= b or b.session ~= safety.session_id() or not safety.is_open() or GetTime() - b.ready_at > 60 then
            stop_all(); EasyAH.print('Plan expired. Build a fresh plan.'); return
        end
        local i = 0
        local function step()
            if batch ~= b or not safety.is_open() then return end
            i = i + 1
            local p = b.plan[i]
            if not p then
                batch = nil
                status_bar:set_text('Post All complete'); status_bar:update_status(1, 1)
                update_inventory_records(); selected_item = nil; refresh = true
                return
            end
            status_bar:set_text('Posting ' .. p.record.name .. '...')
            status_bar:update_status((i - 1) / getn(b.plan), 0)
            post.start(p.record.key, p.size, p.duration, p.q.unit_bid, p.q.unit_buyout, p.count,
                function(posted, result, detail)
                    if batch ~= b then return end
                    if result ~= 'success' then
                        batch = nil
                        EasyAH.print('Post All stopped:', detail or result)
                        status_bar:set_text('Post All stopped: ' .. tostring(detail or result))
                        update_inventory_records(); selected_item = nil; refresh = true
                        return
                    end
                    step()
                end, {expected=p.q})
        end
        step()
    end,
    OnCancel = function() pending_plan = nil; batch = nil; refresh = true end,
}
function M.post_all()
    if not frame:IsShown() or not data or batch or post.busy() or safety.busy() or safety.blocked() or not safety.is_open() then return end
    if commit_packaging and not commit_packaging() then return end
    scan.abort(scan_id)
    update_inventory_records()
	local records = EasyAH.values(EasyAH.filter(EasyAH.copy(inventory_records), function(record)
		return record.aux_quantity > 0 and not read_settings(record.key).hidden
	end))
	sort(records, function(a, b) return a.name < b.name end)
    local queue = require('EasyAH.core.packing').build(records, function(record) return read_settings(record.key).post_all_stack_size end)

    if getn(queue) == 0 then EasyAH.print('No auctionable items.'); return end
    safety.disarm()
    latest_plan = {}
    local b = {plan={}, session=safety.session_id(), deposits=0, lots=0, skipped=0}
    batch = b
    local i, last_key = 0, nil
    local function prepare()
        if batch ~= b or not safety.is_open() then return end
        i = i + 1
        local e = queue[i]
        if not e then
            market_scanning = false
            if getn(b.plan) == 0 then batch = nil; show_plan(); return end
            b.ready_at = GetTime(); pending_plan = b
            status_bar:set_text('Plan ready - confirm to post')
            show_plan()
            local text = format('%d auctions ready; %d groups skipped. Estimated deposit: %s. Prices are frozen. Details: Plan button. Confirm within 60 seconds.', b.lots, b.skipped, money.to_string(b.deposits, nil, true, nil, true))
            StaticPopup_Show('EASYAH_POST_ALL_CONFIRM', text)
            return
        end
        local r = e.record
        local size, count = e.charge_size or e.stack_size, e.count
        local settings = read_settings(r.key)
        local duration = settings.duration or EasyAH.account_data.post_duration
        local sp = EasyAH.account_data.remember_prices and settings.start_price or 0
        local bp = EasyAH.account_data.remember_prices and settings.buyout_price or 0
        local function price_entry()
            if batch ~= b then return end
            local q, reason = post.quote(r.key, item_details(r), size, duration, sp, bp)
            if not q or q.low_profit then
                b.skipped = b.skipped + 1
                local text = 'SKIP ' .. r.name .. ': ' .. post.reason_text(reason or 'low_profit')
                tinsert(latest_plan, text); safety.log('plan', 'skipped', text)
            else
                tinsert(b.plan, {record=r, size=size, count=count, duration=duration, q=q})
                b.lots = b.lots + count
                local physical_size = r.max_charges and 1 or size
                b.deposits = b.deposits + floor((r.unit_vendor_price or 0) * physical_size * (history.context() == 'neutral' and .25 or .05) * duration / 120) * count
                tinsert(latest_plan, r.name .. ' ' .. count .. ' x' .. size .. ' bid ' .. money.to_string(q.bid, nil, true, nil, true) .. ' buy ' .. money.to_string(q.buyout, nil, true, nil, true) .. ' [' .. q.source .. ']')
            end
            EasyAH.thread(prepare)
        end
        if r.key ~= last_key then
            last_key = r.key
            r.unit_vendor_price = unit_vendor_price(r.key)
            if sp == 0 then
                local q = scan_util.item_query(r.item_id)
                if not q then b.skipped=b.skipped+1; tinsert(latest_plan, 'SKIP '..r.name..': item unavailable'); return EasyAH.thread(prepare) end
                market_scanning = true
                status_bar:set_text('Planning: scanning ' .. r.name)
                status_bar:update_status((i - 1) / getn(queue), 0)
                scan_id = scan.start{type='list', require_owner=true, market_item_keys={r.key}, queries={q},
                    on_complete=function() market_scanning=false; price_entry() end,
                    on_abort=function(reason)
                        if batch ~= b then return end
                        market_scanning=false; batch=nil
                        EasyAH.print('Plan stopped:', reason or 'cancelled')
                        status_bar:set_text('Plan stopped; refresh and try again')
                    end}
                return
            end
        end
        price_entry()
    end
    prepare()
end

function validate_parameters()
    if packaging_update_enabled then packaging_update_enabled() end
    if post_all_button then
        if batch or post.busy() or safety.busy() or safety.blocked() then post_all_button:Disable() else post_all_button:Enable() end
    end
    if market_scanning or batch or post.busy() or safety.busy() or safety.blocked() or price_input_invalid then post_button:Disable(); return end
    if not selected_item then
        post_button:Disable()
        return
    end
    if get_unit_buyout_price() > 0 and get_unit_start_price() > get_unit_buyout_price() then
        post_button:Disable()
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
        if packaging_panel then packaging_panel:Hide() end
    else
		unit_start_price_input:Show()
        unit_buyout_price_input:Show()
        stack_size_slider:Show()
        stack_count_slider:Show()
        deposit:Show()
        profit:Show()
        duration_dropdown:Show()
        hide_checkbox:Show()
        if packaging_panel then packaging_panel:Show() end

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
            local size, count = stack_size_slider:GetValue(), stack_count_slider:GetValue()
            local duration = UIDropDownMenu_GetSelectedValue(duration_dropdown)
            local q, reason = post.quote(selected_item.key, item_details(selected_item), size, duration, get_unit_start_price(), get_unit_buyout_price())
            local physical_size = selected_item.max_charges and 1 or size
            local estimated = floor((selected_item.unit_vendor_price or 0) * physical_size * (history.context() == 'neutral' and .25 or .05) * (duration or 1440) / 120) * count
            deposit:SetText('Deposit ~ ' .. money.to_string(estimated, nil, true))
            low_profit = q and q.low_profit or false
            if q then
                local net = q.buyout_net or q.bid_net
                profit:SetText('Net: ' .. money.to_string(net * count, nil, true) .. '\n' .. (q.low_profit and 'Warning: below vendor floor' or ('Source: ' .. q.source)))
            else profit:SetText(post.reason_text(reason)) end
            if similar_items_button then
                if reason == 'review_thin_market' then similar_items_button:Show() else similar_items_button:Hide() end
            end
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
	if item_info.slot and item_info.slot ~= '' then query = query .. '/' .. strlower(_G[item_info.slot] or item_info.slot) end
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
    local reference = record.unit_price * (stack and record.stack_size or stack_size)
    return post.undercut(reference / stack_size, stack_size, record.own)
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
    if safety.busy() or post.busy() then return end
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
                    EasyAH.account_data.merchant_sell[item_info.item_id] = auction_sell_item.vendor_price / (item_info.max_charges or auction_sell_item.count)
                    return auction_sell_item.vendor_price / auction_sell_item.count
                end
            end
        end
    end
end

function update_item(item)
    if batch or post.busy() or safety.busy() then return end
    if commit_packaging and not commit_packaging() then return end
    price_input_invalid = false
    unit_start_price_input.invalid_price, unit_buyout_price_input.invalid_price = false, false
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
    if load_packaging then load_packaging(item) end
	
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
        market_scanning = true
		set_bid_selection()
        set_buyout_selection()
        bid_records[item_key], buyout_records[item_key] = nil, nil
        local query = scan_util.item_query(selected_item.item_id)
        if not query then market_scanning = false; return end
        status_bar:update_status(0, 0)
        status_bar:set_text('Scanning auctions...')

		scan_id = scan.start{
            type = 'list',
            require_owner = true,
            market_item_keys = {item_key},
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
                    market_scanning = false
				bid_records[item_key], buyout_records[item_key] = nil, nil
                status_bar:update_status(1, 1)
                status_bar:set_text('Scan aborted')
			end,
			on_complete = function()
				bid_records[item_key] = bid_records[item_key] or T.acquire()
				buyout_records[item_key] = buyout_records[item_key] or T.acquire()
				market_scanning = false
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
    fit_post_window()
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
