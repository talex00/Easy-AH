module 'EasyAH'

local T = require 'T'
local post = require 'EasyAH.tabs.post'

M.print = T.vararg-function(arg)
	DEFAULT_CHAT_FRAME:AddMessage(LIGHTYELLOW_FONT_COLOR_CODE .. '<EasyAH> ' .. join(map(arg, tostring), ' '))
end

local bids_loaded
function M.bids_loaded() return bids_loaded end

local current_owner_page
function M.current_owner_page() return current_owner_page end

local event_frame = CreateFrame'Frame'
for event in T.temp-T.set('ADDON_LOADED', 'VARIABLES_LOADED', 'PLAYER_LOGIN', 'AUCTION_HOUSE_SHOW', 'AUCTION_HOUSE_CLOSED', 'AUCTION_BIDDER_LIST_UPDATE', 'AUCTION_OWNED_LIST_UPDATE') do
	event_frame:RegisterEvent(event)
end

local set_handler = {}
M.handle = setmetatable({}, {__metatable=false, __newindex=function(_, k, v) set_handler[k](v) end})

do
	local handlers, handlers2 = {}, {}
	function set_handler.LOAD(f)
		tinsert(handlers, f)
	end
	function set_handler.LOAD2(f)
		tinsert(handlers2, f)
	end
	event_frame:SetScript('OnEvent', function()
		if event == 'ADDON_LOADED' then
			if arg1 == 'Blizzard_AuctionUI' then
                auction_ui_loaded()
			end
		elseif event == 'VARIABLES_LOADED' then
			for _, f in handlers do f() end
		elseif event == 'PLAYER_LOGIN' then
			for _, f in handlers2 do f() end
			print('loaded - /eah')
		else
			_M[event]()
		end
	end)
end

function handle.LOAD()
    _G.EasyAH = EasyAH or {}
    math.randomseed(time())
    assign(EasyAH, {
        account = {},
        realm = {},
        faction = {},
        character = {},
    })
    M.account_data = assign(EasyAH.account, {
        scale = 1,
        ignore_owner = true,
        crafting_cost = true,
        post_bid = false,
        post_duration = post.DURATION_24,
		post_stack = true,
        undercut = 1,
        undercut_mode = 'fixed',
        round_prices = false,
        remember_prices = false,
        min_profit_margin = 5,
        autoprice = {},
        market_percentile = 0,
        items = {},
        item_ids = {},
        auctionable_items = {},
        merchant_buy = {},
        merchant_sell = {},
    })
    do
        local key = format('%s|%s', GetCVar'realmName', UnitName'player')
        EasyAH.character[key] = EasyAH.character[key] or {}
        M.character_data = assign(EasyAH.character[key], {
            tooltip = {
                value = true,
                merchant_sell = false,
                merchant_buy = false,
                daily = false,
                disenchant_value = false,
                disenchant_distribution = false,
            }
        })
    end
    do
        local key = GetCVar'realmName'
        EasyAH.realm[key] = EasyAH.realm[key] or {}
        M.realm_data = assign(EasyAH.realm[key], {
            characters = {},
            recent_searches = {},
            favorite_searches = {},
        })
    end
end

function handle.LOAD2()
    local key = format('%s|%s', GetCVar'realmName', UnitFactionGroup'player')
    EasyAH.faction[key] = EasyAH.faction[key] or {}
    M.faction_data = assign(EasyAH.faction[key], {
        history = {},
        post = {},
    })
end

-- One-time migration from the old "aux" addon (if it is still installed alongside this one).
-- Overwrites freshly-seeded defaults with the old real values, without discarding new keys.
local function migrate_merge(dst, src)
    for k, v in src do
        if type(v) == 'table' then
            if type(dst[k]) ~= 'table' then dst[k] = {} end
            migrate_merge(dst[k], v)
        else
            dst[k] = v
        end
    end
end

function handle.LOAD2()
    if _G.aux and type(_G.aux) == 'table' and not EasyAH.account.migrated_from_aux then
        if _G.aux.account then migrate_merge(EasyAH.account, _G.aux.account) end
        if _G.aux.realm then migrate_merge(EasyAH.realm, _G.aux.realm) end
        if _G.aux.faction then migrate_merge(EasyAH.faction, _G.aux.faction) end
        if _G.aux.character then migrate_merge(EasyAH.character, _G.aux.character) end
        EasyAH.account.migrated_from_aux = true
        print('|cffffff00<EasyAH>|r settings, price history, and favorites migrated from the old aux addon. You can now remove the old aux-addon folder.')
    end
end

tab_info = {}
function M.tab(name)
	local tab = T.map('name', name)
	local tab_event = {
		OPEN = function(f) tab.OPEN = f end,
		CLOSE = function(f) tab.CLOSE = f end,
		USE_ITEM = function(f) tab.USE_ITEM = f end,
		CLICK_LINK = function(f) tab.CLICK_LINK = f end,
	}
	tinsert(tab_info, tab)
	return setmetatable({}, {__metatable=false, __newindex=function(_, k, v) tab_event[k](v) end})
end

do
	local index
	function M.get_tab() return tab_info[index] end
	function on_tab_click(i)
		CloseDropDownMenus()
		do (index and get_tab().CLOSE or pass)() end
		index = i
		do (index and get_tab().OPEN or pass)() end
	end
end

M.orig = setmetatable({[_G]=T.acquire()}, {__index=function(self, key) return self[_G][key] end})
M.hook = T.vararg-function(arg)
	local name, object, handler
	if getn(arg) == 3 then
		name, object, handler = unpack(arg)
	else
		object, name, handler = _G, unpack(arg)
	end
	handler = handler or getfenv(3)[name]
	orig[object] = orig[object] or T.acquire()
	assert(not orig[object][name], '"' .. name .. '" is already hooked into.')
	orig[object][name], object[name] = object[name], handler
	return hook
end

do
	local locked
	function M.bid_in_progress() return locked end
	function M.place_bid(type, index, amount, on_success)
		if locked then return end
		local money = GetMoney()
		PlaceAuctionBid(type, index, amount)
		if money >= amount then
			locked = true
			local send_signal, signal_received = signal()
			thread(when, signal_received, function()
				do (on_success or pass)() end
				locked = false
			end)
			thread(when, later(5), send_signal)
			event_listener('CHAT_MSG_SYSTEM', function(kill)
				if arg1 == ERR_AUCTION_BID_PLACED then
					send_signal()
					kill()
				end
			end)
		end
	end
end

do
	local locked
	function M.cancel_in_progress() return locked end
	function M.cancel_auction(index, on_success)
		if locked then return end
		locked = true
		CancelAuction(index)
		local send_signal, signal_received = signal()
		thread(when, signal_received, function()
			do (on_success or pass)() end
			locked = false
		end)
		thread(when, later(5), send_signal)
		event_listener('CHAT_MSG_SYSTEM', function(kill)
			if arg1 == ERR_AUCTION_REMOVED then
				send_signal()
				kill()
			end
		end)
	end
end

function handle.LOAD2()
	frame:SetScale(account_data.scale)
end

function AUCTION_HOUSE_SHOW()
	AuctionFrame:Hide()
	frame:Show()
	set_tab(1)
end

do
	local handlers = {}
	function set_handler.CLOSE(f)
		tinsert(handlers, f)
	end
	function AUCTION_HOUSE_CLOSED()
		bids_loaded = false
		current_owner_page = nil
		for _, handler in handlers do
			handler()
		end
		set_tab()
		frame:Hide()
	end
end

function AUCTION_BIDDER_LIST_UPDATE()
	bids_loaded = true
end

do
	local last_owner_page_requested
	function GetOwnerAuctionItems(index)
		last_owner_page_requested = index
		return orig.GetOwnerAuctionItems(index)
	end
	function AUCTION_OWNED_LIST_UPDATE()
		current_owner_page = last_owner_page_requested or 0
	end
end

function auction_ui_loaded()
	AuctionFrame:UnregisterEvent('AUCTION_HOUSE_SHOW')
	AuctionFrame:SetScript('OnHide', nil)
	hook('ShowUIPanel', T.vararg-function(arg)
		if arg[1] == AuctionFrame then return AuctionFrame:Show() end
		return orig.ShowUIPanel(unpack(arg))
	end)
	hook 'GetOwnerAuctionItems' 'SetItemRef' 'UseContainerItem' 'AuctionFrameAuctions_OnEvent'
end

AuctionFrameAuctions_OnEvent = T.vararg-function(arg)
    if AuctionFrameAuctions:IsVisible() then
	    return orig.AuctionFrameAuctions_OnEvent(unpack(arg))
    end
end
