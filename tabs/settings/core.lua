module 'EasyAH.tabs.settings'

local EasyAH = require 'EasyAH'
local gui = require 'EasyAH.gui'
local post = require 'EasyAH.tabs.post'
local core_post = require 'EasyAH.core.post'
local info = require 'EasyAH.util.info'

local refreshers = {}
local frame

local function refresh_all()
	for _, f in refreshers do f() end
end

-- Standalone settings window. Not part of the Auction House tab bar: opened
-- only via the /eah slash command, independent of whether the AH is open.
function M.show()
	frame:Show()
	refresh_all()
end

function M.hide()
	frame:Hide()
end

local function checkbox_row(panel, x, y, text, get, set)
	local cb = gui.checkbox(panel)
	cb:SetPoint('TOPLEFT', x, y)
	cb:SetScript('OnClick', function()
		set(this:GetChecked() and true or false)
	end)
	local label = gui.label(cb, gui.font_size.medium)
	label:SetPoint('LEFT', cb, 'RIGHT', 6, 0)
	label:SetPoint('RIGHT', panel, 'RIGHT', -8, 0)
	label:SetJustifyH('LEFT')
	label:SetText(text)
	tinsert(refreshers, function() cb:SetChecked(get()) end)
end

local function dropdown_row(panel, x, y, labeltext, options, get, set)
	local dd = gui.dropdown(panel)
	dd:SetPoint('TOPLEFT', x, y)
	dd:SetWidth(130)
	local lbl = gui.label(dd, gui.font_size.small)
	lbl:SetPoint('BOTTOMLEFT', dd, 'TOPLEFT', 2, 2)
	lbl:SetText(labeltext)
	local function init()
		for i = 1, getn(options), 2 do
			local text, value = options[i], options[i + 1]
			UIDropDownMenu_AddButton{
				text = text,
				value = value,
				func = function()
					UIDropDownMenu_SetSelectedValue(dd, this.value)
					set(this.value)
				end,
			}
		end
	end
	UIDropDownMenu_Initialize(dd, init)
	dd:SetScript('OnShow', function() UIDropDownMenu_Initialize(this, init) end)
	tinsert(refreshers, function()
		UIDropDownMenu_Initialize(dd, init)
		UIDropDownMenu_SetSelectedValue(dd, get())
	end)
end

-- allow_decimal: when true, the value editbox accepts a decimal point (used
-- for auto-price coefficients like 0.95, not just whole numbers/percents).
local function slider_row(panel, x, y, labeltext, lo, hi, step, get, set, allow_decimal)
	local s = gui.slider(panel)
	s:SetPoint('TOPLEFT', x, y)
	s:SetWidth(130)
	s:SetValueStep(step)
	s:SetMinMaxValues(lo, hi)
	s.label:SetText(labeltext)
	s.editbox:SetNumeric(not allow_decimal)
    local updating = false
    local function show_value(v)
        if allow_decimal then s.editbox:SetText(format('%.2f', v)) else s.editbox:SetNumber(v) end
    end
    s:SetScript('OnValueChanged', function()
        if updating then return end
        updating = true
        local v = max(lo, min(hi, this:GetValue()))
        set(v); show_value(v)
        updating = false
    end)
    s.editbox.change = function()
        if updating then return end
        local v = tonumber(s.editbox:GetText())
        if v and v == v then
            updating = true
            v = max(lo, min(hi, v))
            s:SetValue(v); set(s:GetValue())
            updating = false
        end
    end
    tinsert(refreshers, function()
        updating = true
        local v = max(lo, min(hi, tonumber(get()) or lo))
        s:SetValue(v); show_value(v)
        updating = false
    end)
end

local function button_row(panel, x, y, text, width, onclick)
	local btn = gui.button(panel, gui.font_size.small)
	btn:SetPoint('TOPLEFT', x, y)
	btn:SetWidth(width or 180)
	btn:SetHeight(24)
	btn:SetText(text)
	btn:SetScript('OnClick', onclick)
	return btn
end

local function section(panel, y, text)
	local lbl = gui.label(panel, gui.font_size.medium)
	lbl:SetPoint('TOPLEFT', 12, y)
	lbl:SetText(EasyAH.color.label.enabled(text))
	gui.horizontal_line(panel, y - 14)
end

local function autoprice_get(key)
	local t = EasyAH.account_data.autoprice
	local v = t and t[key]
	if v == nil then return core_post.AUTOPRICE_DEFAULTS[key] end
	return v
end

local function autoprice_set(key, v)
	EasyAH.account_data.autoprice = EasyAH.account_data.autoprice or {}
	EasyAH.account_data.autoprice[key] = v
end

do
	frame = CreateFrame('Frame', 'EasyAH_settings_frame', UIParent)
	tinsert(UISpecialFrames, 'EasyAH_settings_frame')
	gui.set_window_style(frame)
	gui.set_size(frame, 900, 660)
	frame:SetPoint('CENTER', 0, 40)
	frame:SetToplevel(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:SetClampedToScreen(true)
	frame:CreateTitleRegion():SetAllPoints()
	frame:Hide()

	do
		local title = gui.label(frame, gui.font_size.large)
		title:SetPoint('TOPLEFT', 14, -12)
		title:SetText('EasyAH Settings')
	end
	do
		local btn = gui.button(frame)
		btn:SetPoint('TOPRIGHT', -12, -14)
		gui.set_size(btn, 60, 24)
		btn:SetText('Close')
		btn:SetScript('OnClick', function() frame:Hide() end)
	end

	frame.content = CreateFrame('Frame', nil, frame)
	frame.content:SetPoint('TOPLEFT', 8, -40)
	frame.content:SetPoint('BOTTOMRIGHT', -8, 8)

	local col_width = 288
	frame.col1 = gui.panel(frame.content)
	frame.col1:SetPoint('TOPLEFT', 0, 0)
	frame.col1:SetWidth(col_width)
	frame.col1:SetPoint('BOTTOMLEFT', 0, 0)

	frame.col2 = gui.panel(frame.content)
	frame.col2:SetPoint('TOPLEFT', frame.col1, 'TOPRIGHT', 4, 0)
	frame.col2:SetWidth(col_width)
	frame.col2:SetPoint('BOTTOMLEFT', frame.col1, 'BOTTOMRIGHT', 4, 0)

	frame.col3 = gui.panel(frame.content)
	frame.col3:SetPoint('TOPLEFT', frame.col2, 'TOPRIGHT', 4, 0)
	frame.col3:SetPoint('BOTTOMRIGHT', 0, 0)

	-- Column 1: General + Tooltip + UI scale
	do
		local title = gui.label(frame.col1, gui.font_size.large)
		title:SetPoint('TOPLEFT', 12, -10)
		title:SetText('General')
	end
	checkbox_row(frame.col1, 15, -34, 'Ignore owner names when scanning (faster)',
		function() return EasyAH.account_data.ignore_owner end,
		function(v) EasyAH.account_data.ignore_owner = v end)
	checkbox_row(frame.col1, 15, -58, 'Show bid column in Post (after /reload)',
		function() return EasyAH.account_data.post_bid end,
		function(v) EasyAH.account_data.post_bid = v end)
	checkbox_row(frame.col1, 15, -82, 'Show crafting cost in profession window',
		function() return EasyAH.account_data.crafting_cost end,
		function(v) EasyAH.account_data.crafting_cost = v end)
	checkbox_row(frame.col1, 15, -106, 'Round auto-prices to clean values',
		function() return EasyAH.account_data.round_prices end,
		function(v) EasyAH.account_data.round_prices = v end)
	checkbox_row(frame.col1, 15, -130, 'Remember manual prices per item',
		function() return EasyAH.account_data.remember_prices end,
		function(v) EasyAH.account_data.remember_prices = v end)

	section(frame.col1, -166, 'Tooltip (shown when hovering items)')
	checkbox_row(frame.col1, 15, -190, 'Historical value',
		function() return EasyAH.character_data.tooltip.value end,
		function(v) EasyAH.character_data.tooltip.value = v end)
	checkbox_row(frame.col1, 15, -214, 'Daily min buyout',
		function() return EasyAH.character_data.tooltip.daily end,
		function(v) EasyAH.character_data.tooltip.daily = v end)
	checkbox_row(frame.col1, 15, -238, 'Disenchant value',
		function() return EasyAH.character_data.tooltip.disenchant_value end,
		function(v) EasyAH.character_data.tooltip.disenchant_value = v end)
	checkbox_row(frame.col1, 15, -262, 'Disenchant value distribution',
		function() return EasyAH.character_data.tooltip.disenchant_distribution end,
		function(v) EasyAH.character_data.tooltip.disenchant_distribution = v end)

	section(frame.col1, -298, 'Vendor price (shown anywhere in the world)')
	checkbox_row(frame.col1, 15, -322, 'Show vendor sell price on item tooltips',
		function() return EasyAH.character_data.tooltip.merchant_sell end,
		function(v) EasyAH.character_data.tooltip.merchant_sell = v end)
	checkbox_row(frame.col1, 15, -346, 'Show vendor buy price on item tooltips',
		function() return EasyAH.character_data.tooltip.merchant_buy end,
		function(v) EasyAH.character_data.tooltip.merchant_buy = v end)
	checkbox_row(frame.col1, 15, -370, 'Add stack total next to the unit price',
		function() return EasyAH.character_data.tooltip.merchant_stack end,
		function(v) EasyAH.character_data.tooltip.merchant_stack = v end)
	checkbox_row(frame.col1, 15, -394, 'Mark unknown prices with a "?" line',
		function() return EasyAH.character_data.tooltip.merchant_unknown end,
		function(v) EasyAH.character_data.tooltip.merchant_unknown = v end)
	do
		local status = gui.label(frame.col1, gui.font_size.small)
		status:SetPoint('TOPLEFT', 15, -420)
		status:SetPoint('RIGHT', frame.col1, 'RIGHT', -12, 0)
		status:SetJustifyH('LEFT')
		tinsert(refreshers, function()
			local sell_count, buy_count, db_count = info.vendor_price_count()
			local text = format('Prices known: %d sell / %d buy', sell_count, buy_count)
			if db_count > 0 then text = text .. format(' (+%d built-in)', db_count) end
			status:SetText(EasyAH.color.text.disabled(text))
		end)
	end
	do
		local note = gui.label(frame.col1, gui.font_size.small)
		note:SetPoint('TOPLEFT', 15, -440)
		note:SetPoint('RIGHT', frame.col1, 'RIGHT', -12, 0)
		note:SetJustifyH('LEFT')
		-- Not present on every 1.12 client; the label wraps anyway because it
		-- is anchored left and right, which gives it a width.
		if note.SetWordWrap then note:SetWordWrap(true) end
		note:SetText(EasyAH.color.text.disabled('The 1.12 client never sends vendor prices to addons. EasyAH learns them from your bags every time you open a vendor window, ships with a built-in vanilla price database covering items you never sold yet, and also reads the ShaguTweaks price database when that addon is installed.'))
	end

	slider_row(frame.col1, 15, -510, 'UI scale (%)', 50, 200, 5,
		function() return EasyAH.round((EasyAH.account_data.scale or 1) * 100) end,
		function(v) EasyAH.account_data.scale = v / 100; EasyAH.frame:SetScale(v / 100) end)

	-- Column 2: Posting + Pricing & safety + Maintenance
	do
		local title = gui.label(frame.col2, gui.font_size.large)
		title:SetPoint('TOPLEFT', 12, -10)
		title:SetText('Posting')
	end
	dropdown_row(frame.col2, 12, -50, 'Default auction duration',
		{'2 Hours', post.DURATION_2, '8 Hours', post.DURATION_8, '24 Hours', post.DURATION_24},
		function() return EasyAH.account_data.post_duration end,
		function(v) EasyAH.account_data.post_duration = v end)
	dropdown_row(frame.col2, 12, -96, 'Stack size strategy',
		{'Max stack', 'max', 'Random', 'random'},
		function() return EasyAH.account_data.stack_mode or (EasyAH.account_data.post_stack and 'max' or 'random') end,
		function(v) EasyAH.account_data.stack_mode = v; EasyAH.account_data.post_stack = v == 'max' end)
	dropdown_row(frame.col2, 12, -142, 'Undercut mode',
		{'Fixed (copper)', 'fixed', 'Percent', 'percent', 'Match lowest', 'match'},
		function() return EasyAH.account_data.undercut_mode or 'fixed' end,
		function(v) EasyAH.account_data.undercut_mode = v end)
	slider_row(frame.col2, 15, -188, 'Undercut amount (copper or %)', 0, 500, 1,
		function() return EasyAH.account_data.undercut or 1 end,
		function(v) EasyAH.account_data.undercut = v end)

	section(frame.col2, -228, 'Pricing & safety')
	-- Slider captions float above the slider itself (up to ~21px), so this
	-- needs more clearance below the section line than a plain row would -
	-- otherwise the caption overlaps the section title above it.
	slider_row(frame.col2, 15, -268, 'Market percentile (0 = lowest)', 0, 100, 1,
		function() return EasyAH.account_data.market_percentile or 0 end,
		function(v) EasyAH.account_data.market_percentile = v end)
	slider_row(frame.col2, 15, -310, 'Min profit margin over vendor (%)', 0, 100, 1,
		function() return EasyAH.account_data.min_profit_margin or 5 end,
		function(v) EasyAH.account_data.min_profit_margin = v end)

	section(frame.col2, -350, 'Maintenance')
	button_row(frame.col2, 15, -374, 'Unhide all hidden items', 220, function()
		post.unhide_all()
	end)
	button_row(frame.col2, 15, -404, 'Clear item cache', 220, function()
		info.rebuild_cache()
		EasyAH.print('Item cache cleared.')
	end)
	button_row(frame.col2, 15, -434, 'Populate item database', 220, function()
		info.populate_wdb()
	end)

	-- Column 3: Advanced auto-price coefficients (previously /eah post autoprice only)
	do
		local title = gui.label(frame.col3, gui.font_size.large)
		title:SetPoint('TOPLEFT', 12, -10)
		title:SetText('Advanced Auto-Price Coefficients')
	end

	local coefficients = {
		{'value_buyout', 'No-competition buyout: x historical value', 0.01, 2, 0.01},
		{'merchant_buy_buyout', 'Buyout vs. vendor buy price', 0.01, 3, 0.01},
		{'vendor_base', 'Vendor multiplier: base', 0.01, 5, 0.01},
		{'vendor_amp', 'Vendor multiplier: amplitude', 0, 10, 0.01},
		{'vendor_decay', 'Vendor multiplier: decay (copper)', 50, 10000, 50},
		{'bid_vs_buyout', 'Bid as fraction of buyout', 0.01, 1, 0.01},
		{'de_reco_factor', 'Disenchant recommendation: value factor', 0, 2, 0.01},
		{'de_reco_flat', 'Disenchant recommendation: flat bonus (copper)', 0, 500, 5},
		{'vendor_reco', 'Vendor recommendation threshold multiplier', 0, 5, 0.01},
		{'review_multiple', 'Skip auto-post above this x historical (0 = off)', 0, 20, 0.5},
		{'min_market_sample', 'Min competing listings to trust market price (0 = off)', 0, 10, 1},
	}

	local y = -46
	for _, c in ipairs(coefficients) do
		local key, label, lo, hi, step = c[1], c[2], c[3], c[4], c[5]
		slider_row(frame.col3, 15, y, label, lo, hi, step,
			function() return autoprice_get(key) end,
			function(v) autoprice_set(key, v) end,
			true)
		y = y - 34
	end

	button_row(frame.col3, 15, y - 6, 'Reset to defaults', 150, function()
		EasyAH.account_data.autoprice = {}
		refresh_all()
		EasyAH.print('Auto-price coefficients reset to defaults.')
	end)
	do
		local note = gui.label(frame.col3, gui.font_size.small)
		note:SetPoint('TOPLEFT', 15, y - 36)
		note:SetPoint('RIGHT', frame.col3, 'RIGHT', -12, 0)
		note:SetJustifyH('LEFT')
		-- Not present on every 1.12 client; the label wraps anyway because it
		-- is anchored left and right, which gives it a width.
		if note.SetWordWrap then note:SetWordWrap(true) end
		note:SetText(EasyAH.color.text.disabled('These control the auto-price heuristic used in Post when Unit Starting Price is 0.'))
	end
end


do
    local theme = require 'EasyAH.gui.theme'
    local button = gui.button(frame, 13)
    button:SetPoint('TOPRIGHT', -88, -14)
    button:SetWidth(156); button:SetHeight(24)
    button:SetScript('OnClick', function() theme.toggle() end)
    button:SetScript('OnUpdate', function() button:SetText(theme.current() == 'classic' and 'Theme: Classic' or 'Theme: Modern') end)
end
