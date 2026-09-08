module 'EasyAH.core.safety'

local EasyAH = require 'EasyAH'
local info = require 'EasyAH.util.info'
local current, uncertain, armed, opened = nil, false, false, false
local spent, quantities, next_id, session = 0, {}, 0, 0
local blocked_until = 0
local history = require 'EasyAH.core.history'

function M.is_open() return opened end
function M.session_id() return session end
function M.busy() return current ~= nil end
function M.blocked() return uncertain or GetTime() < blocked_until end
function M.is_armed() return armed and opened and not blocked() end
function M.finite(v) return type(v) == 'number' and v == v and v > -1/0 and v < 1/0 end
function M.money(v) return finite(v) and v >= 0 and v <= 2147483647 and v == floor(v) end

function M.log(kind, result, detail, amount)
    local data = EasyAH.character_data
    if not data then return end
    data.operation_log = data.operation_log or {}
    tinsert(data.operation_log, {time=time(), kind=kind, result=result, detail=tostring(detail or ''), amount=amount})
    while getn(data.operation_log) > 100 do tremove(data.operation_log, 1) end
end
function M.show_log()
    local rows = EasyAH.character_data.operation_log or {}
    for i = max(1, getn(rows) - 19), getn(rows) do
        local r = rows[i]
        EasyAH.print(date('%H:%M:%S', r.time), r.kind, r.result, r.detail)
    end
    if getn(rows) == 0 then EasyAH.print('No operations logged.') end
end
function M.show_log_window()
    local rows = EasyAH.character_data.operation_log or {}

    local tw = require 'EasyAH.gui.text_window'
    local money = require 'EasyAH.util.money'
    local lines = {}
    tinsert(lines, {text=format('Last %d operations (max 100 stored):', min(getn(rows), 100)), r=0.8, g=0.8, b=1})
    tinsert(lines, getn(rows) == 0 and 'No operations yet. Confirmed actions and failures will appear here.' or '')
    for i = getn(rows), max(1, getn(rows) - 99), -1 do
        local r = rows[i]
        local rc, gc, bc
        if r.result == 'success' then rc, gc, bc = 0.3, 0.8, 0.3 else rc, gc, bc = 1, 0.4, 0.4 end
        local amount_str = r.amount and money.to_string(r.amount, nil, true, nil, true) or ''
        tinsert(lines, {text=date('%d/%m %H:%M:%S', r.time) .. '  ' .. (r.kind or '') .. '  ' .. (r.result or '') .. '  ' .. (r.detail or '') .. (amount_str ~= '' and ('  ' .. amount_str) or ''), r=rc, g=gc, b=bc})
    end
    tw.show('EasyAHLogWindow', 'Operation Log', lines, 620, 440, show_log_window)
end

function M.open()
    opened, armed, uncertain = true, false, false
    session = session + 1
    -- Spending limits last for the login session, not just an AH visit.
    history.select_market(not UnitFactionGroup('npc'))
end
function M.disarm() armed = false end
function M.arm()
    if not opened or current or blocked() then return false, 'Close/reopen the auction house before arming.' end
    local a = EasyAH.account_data
    if not money(a.auto_budget) or a.auto_budget <= 0 or not money(a.auto_max_lot) or a.auto_max_lot <= 0
        or not money(a.auto_reserve) or not money(a.auto_max_quantity) or a.auto_max_quantity < 1 then
        return false, 'Set positive budget, lot and quantity limits first.'
    end
    armed = true
    return true
end
function M.auto_check(record, amount)
    local a = EasyAH.account_data
    if not is_armed() then return false, 'not_armed' end
    if not record.owner then return false, 'owner_unknown' end
    if info.is_player(record.owner) then return false, 'own_auction' end
    if not money(amount) or amount < 1 then return false, 'invalid_price' end
    local qty = record.aux_quantity
    if not finite(qty) or qty < 1 then return false, 'invalid_quantity' end
    if amount > a.auto_max_lot then return false, 'lot_limit' end
    if spent + amount > a.auto_budget then return false, 'budget_limit' end
    if GetMoney() - amount < a.auto_reserve then return false, 'gold_reserve' end
    if (quantities[record.item_key] or 0) + qty > a.auto_max_quantity then return false, 'quantity_limit' end
    return true
end
function M.reserve_auto(record, amount)
    -- Conservative: attempted bids count in full, including uncertain results.
    spent = spent + amount
    quantities[record.item_key] = (quantities[record.item_key] or 0) + record.aux_quantity
end
function M.budget_used() return spent end

local function finish(op, result, detail)
    if current ~= op or op.finished then return end
    op.finished = true
    current = nil
    for _, id in ipairs(op.listeners) do EasyAH.kill_listener(id) end
    EasyAH.kill_thread(op.timer)
    if result ~= 'success' then
        armed = false
        -- Vanilla success messages have no transaction ID. Do not let a late
        -- message confirm a different operation after a failed/cancelled send.
        if op.sent then uncertain = true; blocked_until = GetTime() + 15 end
    end
    log(op.kind, result, detail or op.detail, op.amount)
    EasyAH.thread(function() op.callback(result, detail) end)
end
function M.cancel(reason)
    armed = false
    if current then finish(current, 'cancelled', reason or 'Stopped by user') end
end
function M.close()
    opened = false
    cancel('Auction house closed')
    history.select_market(false)
end

function M.begin(kind, success_message, issue, callback, detail, amount)
    if not opened then return nil, 'auction_closed' end
    if current then return nil, 'busy' end
    if blocked() then return nil, 'uncertain_result_wait_15s_and_reopen_auction' end
    next_id = next_id + 1
    local op = {id=next_id, kind=kind, callback=callback or pass, listeners={}, detail=detail, amount=amount}
    current = op
    tinsert(op.listeners, EasyAH.event_listener('CHAT_MSG_SYSTEM', function()
        if arg1 == success_message then finish(op, 'success') end
    end))
    tinsert(op.listeners, EasyAH.event_listener('UI_ERROR_MESSAGE', function()
        finish(op, 'failed', tostring(arg1 or 'Server rejected operation'))
    end))
    local deadline = EasyAH.later(12)
    op.timer = EasyAH.thread(EasyAH.when, deadline, function() finish(op, 'timeout', 'No confirmation; reopen AH and verify.') end)
    op.sent = true
    local ok, err = pcall(issue)
    if not ok then finish(op, 'failed', err) end
    return op.id
end
