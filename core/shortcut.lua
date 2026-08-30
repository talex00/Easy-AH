module 'EasyAH.core.shortcut'

local T = require 'T'
local EasyAH = require 'EasyAH'
local info = require 'EasyAH.util.info'

do
    local orig = SetItemRef
    _G.SetItemRef = T.vararg-function(arg)
        if arg[3] ~= 'RightButton' or not EasyAH.index(EasyAH.get_tab(), 'CLICK_LINK') or not strfind(arg[1], '^item:%d+') then
            return orig(unpack(arg))
        end
        local item_info = info.item(tonumber(EasyAH.select(3, strfind(arg[1], '^item:(%d+)'))))
        if item_info then
            return EasyAH.get_tab().CLICK_LINK(item_info)
        end
    end
end

do
    local orig = UseContainerItem
    _G.UseContainerItem = T.vararg-function(arg)
        if EasyAH.modified() or not EasyAH.get_tab() then
            return orig(unpack(arg))
        end
        local item_info = info.container_item(arg[1], arg[2])
        if item_info and EasyAH.get_tab().USE_ITEM then
            EasyAH.get_tab().USE_ITEM(item_info)
        end
    end
end