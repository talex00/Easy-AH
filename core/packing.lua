module 'EasyAH.core.packing'
local safety = require 'EasyAH.core.safety'
function M.stack_size(record, configured)
    local cap = max(1, floor(record.max_stack or 1))
    local size = tonumber(configured)
    if not safety.finite(size) or size < 1 or size ~= floor(size) then size = cap end
    return min(cap, size, max(0, floor(record.aux_quantity or 0)))
end
function M.build(records, size_for)
    local queue = {}
    for _, record in ipairs(records) do
        if record.max_charges then
            -- Charges belong to one physical item, not to a splittable stack.
            for size = record.max_charges, 1, -1 do
                local count = record.availability[size] or 0
                if count > 0 then tinsert(queue, {record=record, charge_size=size, count=count}) end
            end
        else
            local qty = max(0, floor(record.aux_quantity or 0))
            local size = stack_size(record, size_for(record))
            if size > 0 then
                local count = floor(qty / size)
                if count > 0 then tinsert(queue, {record=record, stack_size=size, count=count}) end
                local rest = qty - count * size
                if rest > 0 then tinsert(queue, {record=record, stack_size=rest, count=1}) end
            end
        end
    end
    return queue
end
