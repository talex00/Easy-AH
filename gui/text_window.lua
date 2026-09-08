module 'EasyAH.gui.text_window'
local EasyAH = require 'EasyAH'
local gui = require 'EasyAH.gui'
local theme = require 'EasyAH.gui.theme'
local windows = {}
local function build(name, width, height)
    local frame = CreateFrame('Frame', name, UIParent)
    tinsert(UISpecialFrames, name)
    gui.set_window_style(frame); gui.set_size(frame, width, height)
    frame:SetPoint('CENTER', 0, 20); frame:SetToplevel(true)
    frame:SetFrameStrata('HIGH'); frame:SetMovable(true)
    frame:EnableMouse(true); frame:SetClampedToScreen(true)
    local drag = frame:CreateTitleRegion()
    drag:SetPoint('TOPLEFT', 8, -6); drag:SetPoint('TOPRIGHT', -166, -6); drag:SetHeight(30)
    local title = gui.label(frame, 18)
    title:SetPoint('TOPLEFT', 16, -14); title:SetWidth(width - 192); title:SetHeight(22); title:SetJustifyH('LEFT')
    local close = gui.button(frame, 13)
    close:SetPoint('TOPRIGHT', -14, -14); gui.set_size(close, 62, 26)
    close:SetText('Close'); close:SetScript('OnClick', function() frame:Hide() end)
    local refresh = gui.button(frame, 13)
    refresh:SetPoint('RIGHT', close, 'LEFT', -6, 0); gui.set_size(refresh, 72, 26)
    refresh:SetText('Refresh'); refresh:SetScript('OnClick', function() if frame.reload then frame.reload() end end)
    local panel = gui.panel(frame)
    panel:SetPoint('TOPLEFT', 12, -46); panel:SetPoint('BOTTOMRIGHT', -12, 14)
    local scroll = CreateFrame('ScrollFrame', name .. 'Scroll', panel, 'UIPanelScrollFrameTemplate')
    scroll:SetPoint('TOPLEFT', 8, -8); scroll:SetPoint('BOTTOMRIGHT', -30, 8)
    local content = CreateFrame('Frame', name .. 'Content', scroll)
    content:SetWidth(width - 64); content:SetHeight(1)
    scroll:SetScrollChild(content); content.lines = {}
    frame.title_label, frame.content, frame.scroll, frame.refresh_button = title, content, scroll, refresh
    frame:Hide()
    return frame
end
function M.show(name, title, lines, width, height, reload)
    width, height = width or 620, height or 440
    local win = windows[name]
    if not win then win=build(name, width, height); windows[name]=win end
    win.title_label:SetText(title); win.reload = reload
    win:SetScale(min(1, max(.25, (UIParent:GetWidth() - 32) / width), max(.25, (UIParent:GetHeight() - 48) / height)))
    win:Show()
    local content, y = win.content, -4
    for _, fs in ipairs(content.lines) do fs:Hide() end
    for i, line in ipairs(lines) do
        local fs = content.lines[i]
        if not fs then fs=content:CreateFontString(); content.lines[i]=fs; theme.font(fs, 14) end
        fs:ClearAllPoints(); fs:SetPoint('TOPLEFT', 4, y)
        fs:SetWidth(content:GetWidth() - 8); fs:SetJustifyH('LEFT'); fs:SetJustifyV('TOP')
        if type(line) == 'table' then fs:SetText(line.text or ''); fs:SetTextColor(line.r or .9, line.g or .9, line.b or .9)
        else fs:SetText(tostring(line)); fs:SetTextColor(EasyAH.color.text.enabled()) end
        fs:Show()
        y = y - max(16, fs:GetHeight()) - 6
    end
    content:SetHeight(max(1, -y + 8))
    win.scroll:SetVerticalScroll(0)
    local bar = _G[name .. 'ScrollScrollBar']
    if bar then bar:SetValue(0) end
    return win
end
