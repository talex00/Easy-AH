module 'EasyAH.gui.theme'
local EasyAH = require 'EasyAH'
local styles, fonts = {}, {}
local active = 'modern'
function M.current() return active end
local function paint(frame, entry)
    if active ~= 'classic' then
        if entry.role == 'button' then frame:SetNormalTexture(nil); frame:SetPushedTexture(nil) end
        entry.normal()
        return
    end
    local window = entry.role == 'window'
    local button = entry.role == 'button'
    frame:SetBackdrop{
        bgFile=window and [[Interface\DialogFrame\UI-DialogBox-Background]] or [[Interface\Tooltips\UI-Tooltip-Background]],
        edgeFile=window and [[Interface\DialogFrame\UI-DialogBox-Border]] or [[Interface\Tooltips\UI-Tooltip-Border]],
        tile=true, tileSize=32, edgeSize=window and 24 or 12,
        insets={left=window and 7 or 3, right=window and 7 or 3, top=window and 7 or 3, bottom=window and 7 or 3}}
    if window then frame:SetBackdropColor(1, 1, 1, 1); frame:SetBackdropBorderColor(1, .92, .72, 1)
    elseif button then
        frame:SetBackdropColor(.36, .06, .04, 1); frame:SetBackdropBorderColor(.8, .62, .28, 1)
        frame:SetNormalTexture([[Interface\Buttons\UI-Panel-Button-Up]])
        frame:SetPushedTexture([[Interface\Buttons\UI-Panel-Button-Down]])
        frame:GetNormalTexture():SetTexCoord(0, .625, 0, .6875)
        frame:GetPushedTexture():SetTexCoord(0, .625, 0, .6875)
    elseif entry.role == 'panel' then
        frame:SetBackdropColor(.1, .085, .065, .98); frame:SetBackdropBorderColor(.60, .49, .30, 1)
    else frame:SetBackdropColor(.07, .06, .05, 1); frame:SetBackdropBorderColor(.48, .40, .26, 1) end
end
local function paint_font(fs, entry)
    local font = active == 'classic' and (STANDARD_TEXT_FONT or [[Fonts\FRIZQT__.TTF]]) or [[Fonts\ARIALN.TTF]]
    fs:SetFont(font, entry.size)
    if entry.label then
        if active == 'classic' then fs:SetTextColor(1, .82, 0) else fs:SetTextColor(EasyAH.color.label.enabled()) end
    end
end
function M.style(frame, role, normal)
    styles[frame] = {role=role, normal=normal}
    paint(frame, styles[frame])
end
function M.button(frame)
    local old = styles[frame]
    if old then old.role='button'; paint(frame, old) end
end
function M.font(fs, size, label)
    fonts[fs] = {size=size, label=label}
    paint_font(fs, fonts[fs])
end
function M.set(name)
    active = name == 'classic' and 'classic' or 'modern'
    if EasyAH.account_data then EasyAH.account_data.ui_theme=active end
    for frame, entry in styles do paint(frame, entry) end
    for fs, entry in fonts do paint_font(fs, entry) end
end
function M.toggle() set(active == 'classic' and 'modern' or 'classic') end
function EasyAH.handle.LOAD2() set(EasyAH.account_data.ui_theme or 'modern') end
