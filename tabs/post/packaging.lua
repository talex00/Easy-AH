module 'EasyAH.tabs.post'
local EasyAH = require 'EasyAH'
local gui = require 'EasyAH.gui'
local safety = require 'EasyAH.core.safety'
local core_post = require 'EasyAH.core.post'
local theme = require 'EasyAH.gui.theme'
local owner, mode, syncing
local buttons = {}

function fit_post_window()
    local scale = EasyAH.account_data.scale or 1
    scale = min(scale, (UIParent:GetWidth() - 32) / 768, (UIParent:GetHeight() - 64) / 600)
    if scale > 0 and EasyAH.frame:GetScale() ~= scale then EasyAH.frame:SetScale(scale) end
end
local function cap() return owner and max(1, floor(owner.max_stack or 1)) or 1 end
local function busy() return batch_busy() or core_post.busy() or safety.busy() end
local function feedback(text, invalid)
    packaging_feedback:SetText(text)
    packaging_feedback:SetTextColor(invalid and 1 or .6, invalid and .3 or .82, invalid and .25 or .55)
end
local function saved_label(size)
    return size == 0 and 'Saved: maximum stacks. Remainder posted separately.' or ('Saved: ' .. size .. ' per lot. Remainder posted separately.')
end
function commit_packaging()
    if not owner or syncing or owner.max_charges then return true end
    if not selected_item or owner.key ~= selected_item.key then return true end
    if busy() then return true end
    local size = mode == 'max' and 0 or mode == 'single' and 1 or tonumber(post_all_stack_input:GetText())
    if not safety.finite(size) or size < 0 or size ~= floor(size) or size > cap() or (mode == 'custom' and size < 1) then
        feedback('Enter a whole number from 1 to ' .. cap() .. ', or choose Max.', true)
        return false
    end
    local settings = read_settings(owner.key)
    settings.post_all_stack_size = size
    write_settings(settings, owner.key)
    feedback(saved_label(size))
    return true
end
local function choose(value)
    if not owner or busy() or owner.max_charges then return end
    mode = value
    syncing = true
    if value == 'max' then post_all_stack_input:SetText('0')
    elseif value == 'single' then post_all_stack_input:SetText('1')
    else
        local old = read_settings(owner.key).post_all_stack_size
        post_all_stack_input:SetText(tostring(min(cap(), old > 1 and old or 5)))
    end
    syncing = false
    commit_packaging()
    packaging_update_enabled()
    if value == 'custom' then post_all_stack_input:SetFocus() end
end
function load_packaging(record)
    owner = record
    local size = read_settings(record.key).post_all_stack_size
    size = min(size, cap())
    mode = size == 0 and 'max' or size == 1 and 'single' or 'custom'
    syncing = true
    post_all_stack_input:SetText(tostring(size))
    syncing = false
    if record.max_charges then feedback('Charge items stay whole; packaging does not split charges.')
    else commit_packaging() end
    packaging_update_enabled()
end
function packaging_update_enabled()
    local enabled = selected_item and owner and owner.key == selected_item.key and not owner.max_charges and not busy()
    for name, button in buttons do
        if enabled and name ~= mode then button:Enable() else button:Disable() end
        button:SetText((name == mode and '* ' or '') .. (name == 'max' and 'Max' or name == 'single' and 'Single' or 'Custom'))
    end
    if enabled and mode == 'custom' then post_all_stack_input:Show(); packaging_save:Enable()
    else post_all_stack_input:Hide(); packaging_save:Disable() end
    packaging_limit:SetText(owner and owner.max_charges and 'Physical items only' or ('Custom: 1 - ' .. cap()))
end

gui.horizontal_line(frame.parameters, -220)
packaging_panel = CreateFrame('Frame', nil, frame.parameters)
packaging_panel:SetPoint('TOPLEFT', 12, -226)
packaging_panel:SetPoint('BOTTOMRIGHT', -12, 8)
local title = gui.label(packaging_panel, 13)
title:SetPoint('TOPLEFT', 2, -2); title:SetText('Post All packaging - this item only')
local function mode_button(name, text, x, width)
    local btn = gui.button(packaging_panel, 13)
    btn:SetPoint('TOPLEFT', x, -24); gui.set_size(btn, width, 24)
    btn:SetText(text); btn:SetScript('OnClick', function() choose(name) end)
    buttons[name] = btn
end
mode_button('max', 'Max', 2, 86)
mode_button('single', 'Single', 94, 64)
mode_button('custom', 'Custom', 164, 72)
post_all_stack_input = gui.editbox(packaging_panel)
post_all_stack_input:SetPoint('TOPLEFT', 242, -24)
gui.set_size(post_all_stack_input, 44, 24)
post_all_stack_input:SetNumeric(true); post_all_stack_input:SetMaxLetters(4)
post_all_stack_input:SetAlignment('CENTER')
post_all_stack_input.char = function() commit_packaging() end
post_all_stack_input.enter = function() if commit_packaging() then post_all_stack_input:ClearFocus() end end
post_all_stack_input.focus_loss = function() commit_packaging() end
post_all_stack_input.escape = function() if owner then load_packaging(owner) end end
packaging_save = gui.button(packaging_panel, 13)
packaging_save:SetPoint('TOPLEFT', 294, -24); gui.set_size(packaging_save, 62, 24)
packaging_save:SetText('Save'); packaging_save:SetScript('OnClick', function() if commit_packaging() then post_all_stack_input:ClearFocus() end end)
packaging_limit = gui.label(packaging_panel, 12)
packaging_limit:SetPoint('TOPLEFT', 364, -24); gui.set_size(packaging_limit, 148, 24)
packaging_limit:SetJustifyH('LEFT')
packaging_feedback = gui.label(packaging_panel, 12)
packaging_feedback:SetPoint('TOPLEFT', 2, -53); packaging_feedback:SetWidth(510); packaging_feedback:SetHeight(14)
packaging_feedback:SetJustifyH('LEFT')
packaging_panel:Hide()

local function tool_button(text, x, width, callback)
    local btn = gui.button(frame.parameters, 13)
    btn:SetPoint('TOPLEFT', x, -12); gui.set_size(btn, width, 26)
    btn:SetText(text); btn:SetScript('OnClick', callback)
    return btn
end
plan_button = tool_button('Plan', 318, 58, show_plan)
log_button = tool_button('Log', 382, 54, function() safety.show_log_window() end)
theme_button = tool_button('Classic: Off', 442, 90, function() theme.toggle() end)
theme_button:SetScript('OnUpdate', function() theme_button:SetText(theme.current() == 'classic' and 'Classic: On' or 'Classic: Off') end)
