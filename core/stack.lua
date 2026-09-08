module 'EasyAH.core.stack'

local T = require 'T'
local EasyAH = require 'EasyAH'
local info = require 'EasyAH.util.info'
local safety = require 'EasyAH.core.safety'

local state

function EasyAH.handle.CLOSE()
	stop()
end

function stack_size(slot)
    local container_item_info = T.temp-info.container_item(unpack(slot))
    return container_item_info and container_item_info.count or 0
end

function charges(slot)
    local container_item_info = T.temp-info.container_item(unpack(slot))
	return container_item_info and container_item_info.charges
end

function max_stack(slot)
	local container_item_info = T.temp-info.container_item(unpack(slot))
	return container_item_info and container_item_info.max_stack
end

function locked(slot)
	local container_item_info = T.temp-info.container_item(unpack(slot))
	return container_item_info and container_item_info.locked
end

function find_item_slot(partial)
	for slot in info.inventory() do
		if matching_item(slot, partial) and not EasyAH.eq(slot, state.target_slot) then
			return slot
		end
	end
end

function matching_item(slot, partial)
	local item_info = T.temp-info.container_item(unpack(slot))
	return item_info and item_info.item_key == state.item_key and info.auctionable(item_info.tooltip, nil, true) and (not partial or item_info.count < item_info.max_stack)
end

function find_empty_slot()
	for slot, type in info.inventory() do
		if type == 1 and not GetContainerItemInfo(unpack(slot)) then
			return slot
		end
	end
end

function find_charge_item_slot()
	for slot in info.inventory() do
		if matching_item(slot) and charges(slot) == state.target_size then
			return slot
		end
	end
end

function move_item(from_slot, to_slot, amount, k)
    if CursorHasItem() then return stop('cursor_busy') end
    if not max_stack(from_slot) then return stop('inventory_changed') end
	if locked(from_slot) or locked(to_slot) then
		return EasyAH.wait(k)
	end

	amount = min(max_stack(from_slot) - stack_size(to_slot), stack_size(from_slot), amount)
	local expected_size = stack_size(to_slot) + amount

	ClearCursor()
	SplitContainerItem(from_slot[1], from_slot[2], amount)
	PickupContainerItem(unpack(to_slot))

	local s = state
    local deadline = EasyAH.later(8)
    return EasyAH.when(function() return state ~= s or deadline() or stack_size(to_slot) == expected_size end, function()
        if state ~= s then return end
        if deadline() then return stop('timeout') end
        if CursorHasItem() then ClearCursor(); return stop('move_failed') end
        return k()
    end)
end

function process()
    if not state then return end
    if not safety.is_open() then return stop('cancelled') end
    if GetTime() - state.started > 20 then return stop('timeout') end
	if not state.target_slot or not matching_item(state.target_slot) then
		state.target_slot = find_item_slot()
		if not state.target_slot then
			return complete()
		end
	end
	if charges(state.target_slot) then
		state.target_slot = find_charge_item_slot()
		return complete()
	end
	if stack_size(state.target_slot) > state.target_size then
		local slot = find_item_slot(true) or find_empty_slot()
		if slot then
			return move_item(
				state.target_slot,
				slot,
				stack_size(state.target_slot) - state.target_size,
				process
			)
		end
	elseif stack_size(state.target_slot) < state.target_size then
		local slot = find_item_slot()
		if slot then
			return move_item(
				slot,
				state.target_slot,
				state.target_size - stack_size(state.target_slot),
				process
			)
		end
	end
	return complete()
end

local function finish(slot, result)
    local s = state
    if not s then return end
    state = nil
    EasyAH.kill_thread(s.thread_id)
    if s.callback then EasyAH.thread(s.callback, slot, result) end
end
function complete()
    local slot = state and state.target_slot
    if slot and matching_item(slot) and (charges(slot) or stack_size(slot)) == state.target_size then
        return finish(slot, 'success')
    end
    return finish(nil, 'failed')
end
function M.stop(reason) finish(nil, reason or 'cancelled') end
function M.start(key, size, callback)
    if state or CursorHasItem() then
        if callback then EasyAH.thread(callback, nil, 'busy') end
        return false
    end
    state = {item_key=key, target_size=size, callback=callback, started=GetTime()}
    state.thread_id = EasyAH.thread(process)
    return true
end
