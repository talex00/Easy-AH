module 'EasyAH'
local T = require 'T'
local event_frame = CreateFrame('Frame')
local listeners, threads, registered = {}, {}, {}
local current_id, sequence = nil, 0
local function new_id() sequence = sequence + 1; return sequence end
function M.thread_id() return current_id end
function M.kill_thread(id) if threads[id] then threads[id].killed = true end end
function M.kill_listener(id) if listeners[id] then listeners[id].killed = true end end
function M.event_listener(name, callback)
    local id = new_id()
    listeners[id] = {event=name, cb=callback, kill=function(value) if value ~= false then kill_listener(id) end end}
    registered[name] = true
    event_frame:RegisterEvent(name)
    return id
end
function M.on_next_event(name, callback)
    return event_listener(name, function(kill) kill(); callback() end)
end
local function continuation(arg)
    -- Never keep pooled T.temp argument tables across frames. The function
    -- and arguments are retained in an ordinary table owned by this closure.
    local f, args, n = arg[1], {}, getn(arg) - 1
    for i = 1, n do args[i] = arg[i + 1] end
    table.setn(args, n)
    return function() return f(unpack(args)) end
end
M.thread = T.vararg-function(arg)
    local id = new_id()
    threads[id] = {k=continuation(arg)}
    return id
end
M.wait = T.vararg-function(arg)
    if current_id and threads[current_id] and not threads[current_id].killed then
        threads[current_id].k = continuation(arg)
    end
end
M.when = T.vararg-function(arg)
    local condition, callback = arg[1], arg[2]
    if condition() then
        local args, n = {}, getn(arg) - 2
        for i = 1, n do args[i] = arg[i + 2] end
        table.setn(args, n)
        return callback(unpack(args))
    end
    return wait(when, unpack(arg))
end
local function report(err)
    require('EasyAH.core.safety').cancel('Lua error')
    if _M.stop_all then stop_all() end
    if geterrorhandler then geterrorhandler()(err) else print(tostring(err)) end
end
function EVENT()
    local ids = {}
    for id, listener in listeners do if not listener.killed and listener.event == event then tinsert(ids, id) end end
    sort(ids)
    for _, id in ipairs(ids) do
        local listener = listeners[id]
        if listener and not listener.killed then
            local ok, err = pcall(listener.cb, listener.kill)
            if not ok then kill_listener(id); report(err) end
        end
    end
end
function UPDATE()
    local needed = {}
    for id, listener in listeners do
        if listener.killed then listeners[id] = nil else needed[listener.event] = true end
    end
    for name in registered do
        if not needed[name] then event_frame:UnregisterEvent(name); registered[name] = nil end
    end
    local ids = {}
    for id in threads do tinsert(ids, id) end
    sort(ids)
    for _, id in ipairs(ids) do
        local task = threads[id]
        if task then
            if task.killed or not task.k then threads[id] = nil
            else
                local k = task.k
                task.k = nil
                current_id = id
                local ok, err = pcall(k)
                current_id = nil
                if not ok then task.killed = true; report(err) end
            end
        end
    end
end
function handle.LOAD()
    event_frame:SetScript('OnUpdate', UPDATE)
    event_frame:SetScript('OnEvent', EVENT)
end
