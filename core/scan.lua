module 'EasyAH.core.scan'

local T = require 'T'
local EasyAH = require 'EasyAH'
local info = require 'EasyAH.util.info'
local history = require 'EasyAH.core.history'
local safety = require 'EasyAH.core.safety'
local PAGE_SIZE = 50
local states = {}

local function cleanup(s)
    for _, id in ipairs(s.listeners) do EasyAH.kill_listener(id) end
    s.listeners = {}
end
local function finish(s, success, reason)
    if states[s.params.type] ~= s then return end
    cleanup(s)
    states[s.params.type] = nil
    EasyAH.kill_thread(s.id)
    if success and s.snapshot and not history.commit(s.snapshot) then success, reason = false, 'Incomplete market owners' end
    if success then (s.params.on_complete or pass)()
    else (s.params.on_abort or pass)(reason or 'cancelled') end
end
function M.abort(scan_id)
    local pending = {}
    for _, s in states do if not scan_id or s.id == scan_id then tinsert(pending, s) end end
    for _, s in ipairs(pending) do finish(s, false, 'cancelled') end
end
function EasyAH.handle.CLOSE() abort() end
local function get_state()
    for _, s in states do if s.id == EasyAH.thread_id() then return s end end
end
function M.stop()
    local s = get_state()
    if s then s.stopped = true end
end
local function query(s) return s.params.queries[s.query_index] end
local function ignore_owner(s)
    if s.params.require_owner or s.snapshot or safety.is_armed() then return false end
    if s.params.ignore_owner ~= nil then return s.params.ignore_owner end
    return EasyAH.account_data.ignore_owner
end
local scan_next, submit, scan_page, accept

local function already_loaded(s)
    -- The 1.12 client does not re-fire AUCTION_OWNED_LIST_UPDATE when the
    -- already-loaded owner page is re-requested (same for bidder data via
    -- AUCTION_BIDDER_LIST_UPDATE). Accept the cached page like the original
    -- scan did; otherwise revisiting the Auctions/Bids tab always aborts.
    if s.params.type == 'owner' then return EasyAH.current_owner_page() == s.page end
    if s.params.type == 'bidder' then return EasyAH.bids_loaded() end
    return false
end

scan_next = function()
    local s = get_state()
    if not s then return end
    if s.stopped then return finish(s, true) end
    s.query_index = s.query_index + 1
    local q = query(s)
    if not q then return finish(s, true) end
    do (s.params.on_start_query or pass)(s.query_index) end
    s.retries = 0
    if q.blizzard_query then
        s.page = q.blizzard_query.first_page or 0
        if s.page > (q.blizzard_query.last_page or EasyAH.huge) then return scan_next() end
        return submit()
    end
    s.page = nil
    s.batch, s.total = GetNumAuctionItems(s.params.type)
    s.batch = min(PAGE_SIZE, s.batch or 0)
    return scan_page(1)
end

scan_page = function(i)
    local s = get_state()
    if not s then return end
    if s.stopped then return finish(s, true) end
    i = i or 1
    if i > s.batch then
        do (s.params.on_page_scanned or pass)() end
        if query(s).blizzard_query and s.page < s.last_page then
            s.page = s.page + 1
            return submit()
        end
        return scan_next()
    end
    local ar = info.auction(i, s.params.type)
    if not ar then return finish(s, false, 'Incomplete item data; refresh and try again') end
    ar.index, ar.page, ar.query_type = i, s.page, s.params.type
    ar.blizzard_query = query(s).blizzard_query
    if s.params.type == 'list' then
        history.process_auction(ar)
        if s.snapshot then history.observe(s.snapshot, ar) end
    end
    if ar.owner or ignore_owner(s) then
        local amount
        if safety.is_armed() and ar.owner and not info.is_player(ar.owner) then
            if ar.buyout_price > 0 and (s.params.auto_buy_validator or pass)(ar) then amount = ar.buyout_price
            elseif not ar.high_bidder and (s.params.auto_bid_validator or pass)(ar) then amount = ar.bid_price end
        end
        if amount then
            local allowed, reason = safety.auto_check(ar, amount)
            if not allowed then
                safety.log('auto', 'skipped', reason .. ': ' .. ar.name, amount)
                if reason == 'budget_limit' or reason == 'gold_reserve' then safety.disarm() end
            else
                local result, failure
                EasyAH.when(function() return result ~= nil end, function()
                    if result then
                        -- Buyouts shift indexes. Never reuse an unrefreshed page.
                        return submit()
                    end
                    safety.disarm()
                    return finish(s, false, failure or 'Bid failed')
                end)
                return EasyAH.place_bid(ar.query_type, i, amount,
                    function() result = true end,
                    function(err) result = false; failure = err end, ar)
            end
        end
        if not query(s).validator or query(s).validator(ar) then (s.params.on_auction or pass)(ar) end
    end
    if states[s.params.type] ~= s then return end
    return scan_page(i + 1)
end

accept = function()
    local s = get_state()
    s.batch, s.total = GetNumAuctionItems(s.params.type)
    s.batch, s.total = min(PAGE_SIZE, s.batch or 0), s.total or 0
    s.last_page = max(0, ceil(s.total / PAGE_SIZE) - 1)
    local q = query(s).blizzard_query
    s.last_page = min(s.last_page, q.last_page or s.last_page)
    local page_count = max(1, s.last_page - (q.first_page or 0) + 1)
    do (s.params.on_page_loaded or pass)(s.page - (q.first_page or 0) + 1, page_count, max(0, ceil(s.total / PAGE_SIZE) - 1)) end
    return scan_page(1)
end

submit = function()
    local s = get_state()
    if not s then return end
    if s.stopped then return finish(s, true) end
    if not safety.is_open() then return finish(s, false, 'Auction closed') end
    local deadline = EasyAH.later(15)
    return EasyAH.when(function()
        return deadline() or (not safety.busy() and (s.params.type ~= 'list' or CanSendAuctionQuery()))
    end, function()
        if deadline() then return finish(s, false, 'Query throttle timeout') end
        cleanup(s)
        local updated = false
        local event_name = s.params.type == 'list' and 'AUCTION_ITEM_LIST_UPDATE'
            or s.params.type == 'owner' and 'AUCTION_OWNED_LIST_UPDATE' or 'AUCTION_BIDDER_LIST_UPDATE'
        tinsert(s.listeners, EasyAH.event_listener(event_name, function() updated = true end))
        local sent_at = GetTime()
        local q = query(s).blizzard_query
        if s.params.type == 'owner' then GetOwnerAuctionItems(s.page)
        elseif s.params.type == 'bidder' then GetBidderAuctionItems(s.page)
        else QueryAuctionItems(q.name, q.min_level, q.max_level, q.slot, q.class, q.subclass, s.page, q.usable, q.quality) end
        local ready = false
        return EasyAH.when(function()
            if updated or already_loaded(s) then
                ready = true
                local n = GetNumAuctionItems(s.params.type)
                for i = 1, min(n or 0, PAGE_SIZE) do
                    local ar = T.temp-info.auction(i, s.params.type)
                    if not ar or (not ignore_owner(s) and not ar.owner) then ready = false; break end
                end
            end
            return ready or GetTime() - sent_at > 8
        end, function()
            cleanup(s)
            if not ready then
                s.retries = (s.retries or 0) + 1
                if s.retries > 2 then return finish(s, false, 'Incomplete auction response/owners') end
                return submit()
            end
            s.retries = 0
            return accept()
        end)
    end)
end

function M.start(params)
    local old = states[params.type]
    if old then finish(old, false, 'replaced') end
    if not safety.is_open() or safety.busy() then
        do (params.on_abort or pass)('Auction closed or operation in progress') end
        return 0
    end
    local s = {params=params, query_index=0, listeners={}}
    if params.market_item_keys and params.type == 'list' then s.snapshot = history.new_snapshot(params.market_item_keys) end
    s.id = EasyAH.thread(scan_next)
    states[params.type] = s
    do (params.on_scan_start or pass)() end
    return s.id
end
