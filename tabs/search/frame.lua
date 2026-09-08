module 'EasyAH.tabs.search'

local T = require 'T'
local EasyAH = require 'EasyAH'
local info = require 'EasyAH.util.info'
local completion = require 'EasyAH.util.completion'
local filter_util = require 'EasyAH.util.filter'
local scan = require 'EasyAH.core.scan'
local gui = require 'EasyAH.gui'
local listing = require 'EasyAH.gui.listing'
local auction_listing = require 'EasyAH.gui.auction_listing'

local FILTER_SPACING = 28.5

frame = CreateFrame('Frame', nil, EasyAH.frame)
frame:SetAllPoints()
frame:SetScript('OnUpdate', on_update)
frame:Hide()

frame.filter = gui.panel(frame)
frame.filter:SetAllPoints(EasyAH.frame.content)

frame.results = gui.panel(frame)
frame.results:SetAllPoints(EasyAH.frame.content)

frame.saved = CreateFrame('Frame', nil, frame)
frame.saved:SetAllPoints(EasyAH.frame.content)

frame.saved.favorite = gui.panel(frame.saved)
frame.saved.favorite:SetWidth(393)
frame.saved.favorite:SetPoint('TOPLEFT', 0, 0)
frame.saved.favorite:SetPoint('BOTTOMLEFT', 0, 0)

frame.saved.recent = gui.panel(frame.saved)
frame.saved.recent:SetWidth(364.5)
frame.saved.recent:SetPoint('TOPRIGHT', 0, 0)
frame.saved.recent:SetPoint('BOTTOMRIGHT', 0, 0)
do
    local btn = gui.button(frame, 25)
    btn:SetPoint('TOPLEFT', 5, -8)
    btn:SetWidth(30)
    btn:SetHeight(25)
    btn:SetText('<')
    btn:SetScript('OnClick', previous_search)
    previous_button = btn
end
do
    local btn = gui.button(frame, 25)
    btn:SetPoint('LEFT', previous_button, 'RIGHT', 4, 0)
    btn:SetWidth(30)
    btn:SetHeight(25)
    btn:SetText('>')
    btn:SetScript('OnClick', next_search)
    next_button = btn
end
-- Range/Real-Time toggle removed for simplicity: the search box + Search
-- button now always scan. A single filter runs in real-time mode; several
-- ;-separated filters (multi-filter) automatically run a full scan across
-- all pages, since real-time mode can't combine multiple queries.
do
    local btn = gui.button(frame)
    btn:SetHeight(25)
    btn:SetPoint('TOPRIGHT', -5, -8)
    btn:SetText('Search')
    btn:RegisterForClicks('LeftButtonUp', 'RightButtonUp')
    btn:SetScript('OnClick', function()
        if arg1 == 'RightButton' then
            set_filter(current_search().filter_string)
        end
        execute()
    end)
    start_button = btn
end
do
    local btn = gui.button(frame)
    btn:SetHeight(25)
    btn:SetPoint('TOPRIGHT', -5, -8)
    btn:SetText('Pause')
    btn:SetScript('OnClick', function()
        scan.abort(search_scan_id)
    end)
    stop_button = btn
end
do
    local btn = gui.button(frame)
    btn:SetHeight(25)
    btn:SetPoint('RIGHT', start_button, 'LEFT', -4, 0)
    btn:SetBackdropColor(EasyAH.color.state.enabled())
    btn:SetText('Resume')
    btn:SetScript('OnClick', function()
        execute(true)
    end)
    resume_button = btn
end
do
	local editbox = gui.editbox(frame)
	editbox:EnableMouse(1)
	editbox:SetPoint('LEFT', next_button, 'RIGHT', 4, 0)
	editbox.formatter = function(str)
		local queries = filter_util.queries(str)
		return queries and EasyAH.join(EasyAH.map(EasyAH.copy(queries), function(query) return query.prettified end), ';') or EasyAH.color.red(str)
	end
	editbox.complete = completion.complete_filter
    editbox.escape = function() this:SetText(current_search().filter_string or '') end
	editbox:SetHeight(25)
	editbox.char = function()
		this:complete()
	end
	editbox:SetScript('OnTabPressed', function()
        this:HighlightText(0, 0)
	end)
	editbox.enter = execute
	search_box = editbox
end
do
    gui.horizontal_line(frame, -40)
end
do
    local btn = gui.button(frame, gui.font_size.large)
    btn:SetPoint('BOTTOMLEFT', EasyAH.frame.content, 'TOPLEFT', 10, 8)
    btn:SetWidth(243)
    btn:SetHeight(22)
    btn:SetText('Search Results')
    btn:SetScript('OnClick', function() set_subtab(RESULTS) end)
    search_results_button = btn
end
do
    local btn = gui.button(frame, gui.font_size.large)
    btn:SetPoint('TOPLEFT', search_results_button, 'TOPRIGHT', 5, 0)
    btn:SetWidth(243)
    btn:SetHeight(22)
    btn:SetText('Saved Searches')
    btn:SetScript('OnClick', function() set_subtab(SAVED) end)
    saved_searches_button = btn
end
do
    local btn = gui.button(frame, gui.font_size.large)
    btn:SetPoint('TOPLEFT', saved_searches_button, 'TOPRIGHT', 5, 0)
    btn:SetWidth(243)
    btn:SetHeight(22)
    btn:SetText('Filter Builder')
    btn:SetScript('OnClick', function() set_subtab(FILTER) end)
    new_filter_button = btn
end
do
    local frame = CreateFrame('Frame', nil, frame)
    frame:SetWidth(265)
    frame:SetHeight(25)
    frame:SetPoint('TOPLEFT', EasyAH.frame.content, 'BOTTOMLEFT', 8, -6)
    status_bar_frame = frame
end
do
    local btn = gui.button(frame.results)
    btn:SetPoint('TOPLEFT', status_bar_frame, 'TOPRIGHT', 5, 0)
    btn:SetText('Bid')
    btn:Disable()
    bid_button = btn
end
do
    local btn = gui.button(frame.results)
    btn:SetPoint('TOPLEFT', bid_button, 'TOPRIGHT', 5, 0)
    btn:SetText('Buyout')
    btn:Disable()
    buyout_button = btn
end
do
    local btn = gui.button(frame.results)
    btn:SetPoint('TOPLEFT', buyout_button, 'TOPRIGHT', 5, 0)
    btn:SetText('Clear')
    btn:SetScript('OnClick', function()
        while tremove(current_search().records) do end
        current_search().table:SetDatabase()
    end)
end
do
    local btn = gui.button(frame.saved)
    btn:SetPoint('TOPLEFT', status_bar_frame, 'TOPRIGHT', 5, 0)
    btn:SetText('Favorite')
    btn:SetScript('OnClick', function()
        add_favorite(search_box:GetText())
    end)
end
-- Filter Builder actions are grouped in two clusters, separated by a gap:
--   Replace (left cluster) sets the main search box to exactly this one filter.
--   Multi-filter (right cluster) accumulates several filters, run via the
--   always-visible Search button at the top of the window.
do
    local lbl = gui.label(frame.filter, gui.font_size.small)
    lbl:SetPoint('BOTTOMLEFT', status_bar_frame, 'TOPRIGHT', 5, 16)
    lbl:SetText(EasyAH.color.text.disabled('Replace'))

    local btn2 = gui.button(frame.filter)
    btn2:SetPoint('TOPLEFT', status_bar_frame, 'TOPRIGHT', 5, 0)
    btn2:SetText('Export')
    btn2:SetScript('OnClick', export_filter_string)

    local lbl2 = gui.label(frame.filter, gui.font_size.small)
    lbl2:SetPoint('BOTTOMLEFT', btn2, 'TOPRIGHT', 20, 16)
    lbl2:SetText(EasyAH.color.text.disabled('Multi-filter'))

    local btn2b = gui.button(frame.filter)
    btn2b:SetPoint('LEFT', btn2, 'RIGHT', 15, 0)
    btn2b:SetText('Add')
    btn2b:SetScript('OnClick', function()
        add_filter(get_filter_builder_query())
        clear_form()
    end)

    local btn3 = gui.button(frame.filter)
    btn3:SetPoint('LEFT', btn2b, 'RIGHT', 5, 0)
    btn3:SetText('Import')
    btn3:SetScript('OnClick', import_filter_string)
end
do
    local editbox = gui.editbox(frame.filter)
    editbox.complete_item = completion.complete(function() return EasyAH.account_data.auctionable_items end)
    editbox:SetPoint('TOPLEFT', 14, -FILTER_SPACING)
    editbox:SetWidth(260)
    editbox.char = function()
        if blizzard_query.exact then
            this:complete_item()
        end
    end
    editbox:SetScript('OnTabPressed', function()
	    if blizzard_query.exact then
		    return
	    end
        if IsShiftKeyDown() then
            max_level_input:SetFocus()
        else
            min_level_input:SetFocus()
        end
    end)
    editbox.change = update_form
    editbox.enter = function() editbox:ClearFocus() end
    local label = gui.label(editbox, gui.font_size.small)
    label:SetPoint('BOTTOMLEFT', editbox, 'TOPLEFT', -2, 1)
    label:SetText('Name')
    name_input = editbox
end
do
    local checkbox = gui.checkbox(frame.filter)
    checkbox:SetPoint('TOPLEFT', name_input, 'TOPRIGHT', 16, 0)
    checkbox:SetScript('OnClick', update_form)
    local label = gui.label(checkbox, gui.font_size.small)
    label:SetPoint('BOTTOMLEFT', checkbox, 'TOPLEFT', -2, 1)
    label:SetText('Exact')
    exact_checkbox = checkbox
end
do
    local editbox = gui.editbox(frame.filter)
    editbox:SetPoint('TOPLEFT', name_input, 'BOTTOMLEFT', 0, -FILTER_SPACING)
    editbox:SetWidth(125)
    editbox:SetAlignment('CENTER')
    editbox:SetNumeric(true)
    editbox:SetScript('OnTabPressed', function()
        if IsShiftKeyDown() then
            name_input:SetFocus()
        else
            max_level_input:SetFocus()
        end
    end)
    editbox.enter = function() editbox:ClearFocus() end
    editbox.change = function()
	    local valid_level = valid_level(this:GetText())
	    if tostring(valid_level) ~= this:GetText() then
		    this:SetText(valid_level or '')
	    end
	    update_form()
    end
    local label = gui.label(editbox, gui.font_size.small)
    label:SetPoint('BOTTOMLEFT', editbox, 'TOPLEFT', -2, 1)
    label:SetText('Level Range')
    min_level_input = editbox
end
do
    local editbox = gui.editbox(frame.filter)
    editbox:SetPoint('TOPLEFT', min_level_input, 'TOPRIGHT', 10, 0)
    editbox:SetWidth(125)
    editbox:SetAlignment('CENTER')
    editbox:SetNumeric(true)
    editbox:SetScript('OnTabPressed', function()
        if IsShiftKeyDown() then
            min_level_input:SetFocus()
        else
            name_input:SetFocus()
        end
    end)
    editbox.enter = function() editbox:ClearFocus() end
    editbox.change = function()
	    local valid_level = valid_level(this:GetText())
	    if tostring(valid_level) ~= this:GetText() then
		    this:SetText(valid_level or '')
	    end
	    update_form()
    end
    local label = gui.label(editbox, gui.font_size.medium)
    label:SetPoint('RIGHT', editbox, 'LEFT', -3, 0)
    label:SetText('-')
    max_level_input = editbox
end
do
    local checkbox = gui.checkbox(frame.filter)
    checkbox:SetPoint('TOPLEFT', max_level_input, 'TOPRIGHT', 16, 0)
    checkbox:SetScript('OnClick', update_form)
    local label = gui.label(checkbox, gui.font_size.small)
    label:SetPoint('BOTTOMLEFT', checkbox, 'TOPLEFT', -2, 1)
    label:SetText('Usable')
    usable_checkbox = checkbox
end
do
    local dropdown = gui.dropdown(frame.filter)
    class_dropdown = dropdown
    dropdown:SetPoint('TOPLEFT', min_level_input, 'BOTTOMLEFT', 0, 5 - FILTER_SPACING)
    dropdown:SetWidth(300)
    local label = gui.label(dropdown, gui.font_size.small)
    label:SetPoint('BOTTOMLEFT', dropdown, 'TOPLEFT', -2, -3)
    label:SetText('Item Class')
    UIDropDownMenu_Initialize(dropdown, initialize_class_dropdown)
    dropdown:SetScript('OnShow', function()
        UIDropDownMenu_Initialize(this, initialize_class_dropdown)
    end)
end
do
    local dropdown = gui.dropdown(frame.filter)
    subclass_dropdown = dropdown
    dropdown:SetPoint('TOPLEFT', class_dropdown, 'BOTTOMLEFT', 0, 10 - FILTER_SPACING)
    dropdown:SetWidth(300)
    local label = gui.label(dropdown, gui.font_size.small)
    label:SetPoint('BOTTOMLEFT', dropdown, 'TOPLEFT', -2, -3)
    label:SetText('Item Subclass')
    UIDropDownMenu_Initialize(dropdown, initialize_subclass_dropdown)
    dropdown:SetScript('OnShow', function()
        UIDropDownMenu_Initialize(this, initialize_subclass_dropdown)
    end)
end
do
    local dropdown = gui.dropdown(frame.filter)
    slot_dropdown = dropdown
    dropdown:SetPoint('TOPLEFT', subclass_dropdown, 'BOTTOMLEFT', 0, 10 - FILTER_SPACING)
    dropdown:SetWidth(300)
    local label = gui.label(dropdown, gui.font_size.small)
    label:SetPoint('BOTTOMLEFT', dropdown, 'TOPLEFT', -2, -3)
    label:SetText('Item Slot')
    UIDropDownMenu_Initialize(dropdown, initialize_slot_dropdown)
    dropdown:SetScript('OnShow', function()
        UIDropDownMenu_Initialize(this, initialize_slot_dropdown)
    end)
end
do
    local dropdown = gui.dropdown(frame.filter)
    quality_dropdown = dropdown
    dropdown:SetPoint('TOPLEFT', slot_dropdown, 'BOTTOMLEFT', 0, 10 - FILTER_SPACING)
    dropdown:SetWidth(300)
    local label = gui.label(dropdown, gui.font_size.small)
    label:SetPoint('BOTTOMLEFT', dropdown, 'TOPLEFT', -2, -3)
    label:SetText('Min Quality')
    UIDropDownMenu_Initialize(dropdown, initialize_quality_dropdown)
    dropdown:SetScript('OnShow', function()
        UIDropDownMenu_Initialize(this, initialize_quality_dropdown)
    end)
end
-- The advanced "post filter" builder (Component dropdown + live preview) was
-- removed: the left-side fields already fully build the filter and show it
-- in the search box via Export/Add, so the extra panel was redundant.

status_bars = {}
tables = {}
for _ = 1, 5 do
    local status_bar = gui.status_bar(frame)
    status_bar:SetAllPoints(status_bar_frame)
    status_bar:Hide()
    tinsert(status_bars, status_bar)

    local table = auction_listing.new(frame.results, 16, auction_listing.search_columns)
    table:SetHandler('OnClick', function(row, button)
	    if IsAltKeyDown() then
		    if current_search().table:GetSelection().record == row.record then
			    if button == 'LeftButton' then
	                buyout_button:Click()
	            elseif button == 'RightButton' then
	                bid_button:Click()
			    end
		    end
	    elseif button == 'RightButton' then
	        EasyAH.set_tab(1)
		    set_filter(strlower(info.item(this.record.item_id).name) .. '/exact')
		    execute(nil, false)
	    end
    end)
    table:SetHandler('OnSelectionChanged', function(rt, datum)
	    bid_button:Disable()
        buyout_button:Disable()
        if not datum then return end
        find_auction(datum.record)
    end)
    table:Hide()
    tinsert(tables, table)
end

favorite_searches_listing = listing.new(frame.saved.favorite)
favorite_searches_listing:SetColInfo{{name='Auto', width=.07, align='CENTER'}, {name='Favorite Searches', width=.93}}

recent_searches_listing = listing.new(frame.saved.recent)
recent_searches_listing:SetColInfo{{name='Recent Searches', width=1}}

for listing in T.temp-T.set(favorite_searches_listing, recent_searches_listing) do
	for k, v in handlers do
		listing:SetHandler(k, v)
	end
end