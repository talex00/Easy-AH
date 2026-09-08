module 'EasyAH.core.tooltip'

local T = require 'T'
local EasyAH = require 'EasyAH'
local info = require 'EasyAH.util.info'
local money =  require 'EasyAH.util.money'
local disenchant = require 'EasyAH.core.disenchant'
local history = require 'EasyAH.core.history'
local gui = require 'EasyAH.gui'

local UNKNOWN = GRAY_FONT_COLOR_CODE .. '?' .. FONT_COLOR_CODE_CLOSE

local game_tooltip_hooks, game_tooltip_money = {}, 0

function EasyAH.handle.LOAD()
	settings = EasyAH.character_data.tooltip
	do
		local inside_hook = false
	    for name, f in game_tooltip_hooks do
	        local name, f = name, f
	        -- Only hook setters this client actually has, so that a method
	        -- missing on some 1.12 build can never break tooltips.
	        if GameTooltip[name] then
	            EasyAH.hook(name, GameTooltip, T.vararg-function(arg)
                    game_tooltip_money = 0
                    inside_hook = true
	                local tmp = T.list(EasyAH.orig[GameTooltip][name](unpack(arg)))
	                inside_hook = false
	                f(unpack(arg))
	                return T.unpack(tmp)
	            end)
	        end
	    end
        SetTooltipMoney = SetTooltipMoney
        _G.SetTooltipMoney = T.vararg-function(arg)
            if inside_hook then
                game_tooltip_money = arg[2]
            else
                return SetTooltipMoney(unpack(arg))
            end
        end
    end
    local orig = SetItemRef
    setglobal('SetItemRef', T.vararg-function(arg)
        local name, _, quality = GetItemInfo(arg[1])
        local tmp = T.list(orig(unpack(arg)))
        if not IsShiftKeyDown() and not IsControlKeyDown() and (name or arg[1]) then
            local link = arg[1]
            if not strfind(link, '|Hitem:') and name then
                local color_code = EasyAH.select(4, GetItemQualityColor(quality))
                link = color_code ..  '|H' .. arg[1] .. '|h[' .. name .. ']|h' .. FONT_COLOR_CODE_CLOSE
            end
            extend_tooltip(ItemRefTooltip, link, 1)
        end
        return T.unpack(tmp)
    end)
end

local function L(en, ru)
    if GetLocale and GetLocale() == 'ruRU' then
        return ru
    end
    return en
end

local function has_easyah_line(tooltip)
    local name = tooltip and tooltip:GetName()
    if not name then return false end
    for i = 1, tooltip:NumLines() do
        local line = _G[name .. 'TextLeft' .. i]
        local text = line and line:GetText()
        if text and (strfind(text, '^Vendor') or strfind(text, '^Цена торговца') or strfind(text, '^Вендор') or strfind(text, '^Value:') or strfind(text, '^Стоимость:') or strfind(text, '^Рыночная цена:')) then
            return true
        end
    end
    return false
end

-- 'Vendor: 3s 45c', with '(x5 = 17s 25c)' appended for stacks when enabled.
function vendor_line(label, unit_price, stack_size)
    local text = label .. ': ' .. money.to_string2(unit_price)
    if settings.merchant_stack and stack_size and stack_size > 1 then
        text = text .. ' |cffa0a0a0(x' .. stack_size .. ' = ' .. FONT_COLOR_CODE_CLOSE .. money.to_string2(unit_price * stack_size) .. '|cffa0a0a0)' .. FONT_COLOR_CODE_CLOSE
    end
    return text
end

function M.extend_tooltip(tooltip, link, quantity)
    local item_id, suffix_id = info.parse_link(link)
    if not item_id or item_id == 0 then return end
    if has_easyah_line(tooltip) then return end
    -- Vendor lines always show the unit price plus an optional stack total, so
    -- they need the true stack size rather than the shift-modified quantity.
    local stack_size = quantity or 1
    quantity = IsShiftKeyDown() and quantity or 1
    local item_info = T.temp-info.item(item_id)
    if item_info then
        local distribution = disenchant.distribution(item_info.slot, item_info.quality, item_info.level, item_id)
        if getn(distribution) > 0 then
            if settings.disenchant_distribution then
                tooltip:AddLine(L('Disenchants into:', 'Распыляется на:'), EasyAH.color.tooltip.disenchant.distribution())
                sort(distribution, function(a,b) return a.probability > b.probability end)
                for _, event in ipairs(distribution) do
                    tooltip:AddLine(format('  %s%% %s (%s-%s)', event.probability * 100, info.display_name(event.item_id, true) or 'item:' .. event.item_id, event.min_quantity, event.max_quantity), EasyAH.color.tooltip.disenchant.distribution())
                end
            end
            if settings.disenchant_value then
                local disenchant_value = disenchant.value(item_info.slot, item_info.quality, item_info.level, item_id)
                tooltip:AddLine(L('Disenchant: ', 'Распыление: ') .. (disenchant_value and money.to_string2(disenchant_value) or UNKNOWN), EasyAH.color.tooltip.disenchant.value())
            end
        end
    end
    if settings.merchant_sell then
        local price = info.vendor_sell_price(item_id)
        local max_charges = info.max_item_charges(item_id)
        if price and max_charges then
            local charges = max_charges
            if tooltip == GameTooltip then
                local lines = {}
                for i = 1, tooltip:NumLines() do
                    local left, right = _G[tooltip:GetName() .. 'TextLeft' .. i], _G[tooltip:GetName() .. 'TextRight' .. i]
                    tinsert(lines, {left_text=left and left:GetText(), right_text=right and right:GetText()})
                end
                charges = info.item_charges(lines) or max_charges
            end
            price = price * charges
        end
        if price then
            tooltip:AddLine(vendor_line(L('Vendor', 'Цена торговца'), price, stack_size), EasyAH.color.tooltip.merchant())
        elseif settings.merchant_unknown and item_id and item_id ~= 0 then
            tooltip:AddLine(L('Vendor: ', 'Цена торговца: ') .. UNKNOWN, EasyAH.color.tooltip.merchant())
        end
    end
    if settings.merchant_buy then
        local _, price, limited = info.merchant_info(item_id)
        if price and price > 0 then
            tooltip:AddLine(vendor_line(L('Vendor buy', 'Цена покупки') .. (limited and L(' (limited)', ' (ограничено)') or ''), price, stack_size), EasyAH.color.tooltip.merchant())
        end
    end
    local auctionable = not item_info or info.auctionable(T.temp-info.tooltip('link', item_info.itemstring), item_info.quality)
    local item_key = (item_id or 0) .. ':' .. (suffix_id or 0)
    local value = history.value(item_key)
    if auctionable then
        if settings.value then
            tooltip:AddLine(L('Value: ', 'Рыночная цена: ') .. (value and money.to_string2(value * quantity) or UNKNOWN), EasyAH.color.tooltip.value())
        end
        if settings.daily  then
            local market_value = history.daily_value(item_key)
            tooltip:AddLine(L('Today: ', 'Сегодня: ') .. (market_value and money.to_string2(market_value * quantity) .. ' (' .. (value and value > 0 and gui.percentage_historical(EasyAH.round(market_value / value * 100)) or '?') .. ')' or UNKNOWN), EasyAH.color.tooltip.value())
        end
    end

    if tooltip == GameTooltip and game_tooltip_money > 0 then
        SetTooltipMoney(tooltip, game_tooltip_money)
    end
    tooltip:Show()
end

function game_tooltip_hooks:SetHyperlink(itemstring)
    if not itemstring then return end
    if strfind(itemstring, '|Hitem:') then
        extend_tooltip(GameTooltip, itemstring, 1)
        return
    end
    local name, _, quality = GetItemInfo(itemstring)
    if name then
        local hex = EasyAH.select(4, GetItemQualityColor(quality))
        local link = hex ..  '|H' .. itemstring .. '|h[' .. name .. ']|h' .. FONT_COLOR_CODE_CLOSE
        extend_tooltip(GameTooltip, link, 1)
    else
        extend_tooltip(GameTooltip, itemstring, 1)
    end
end

function game_tooltip_hooks:SetAuctionItem(type, index)
	local link = GetAuctionItemLink(type, index)
    if link then
        extend_tooltip(GameTooltip, link, EasyAH.select(3, GetAuctionItemInfo(type, index)))
    end
end

function game_tooltip_hooks:SetLootItem(slot)
	local link = GetLootSlotLink(slot)
    if link then
        extend_tooltip(GameTooltip, link, EasyAH.select(3, GetLootSlotInfo(slot)))
    end
end

function game_tooltip_hooks:SetQuestItem(qtype, slot)
	local link = GetQuestItemLink(qtype, slot)
    if link then
        extend_tooltip(GameTooltip, link, EasyAH.select(3, GetQuestItemInfo(qtype, slot)))
    end
end

function game_tooltip_hooks:SetQuestLogItem(qtype, slot)
	local link = GetQuestLogItemLink(qtype, slot)
    if link then
        extend_tooltip(GameTooltip, link, EasyAH.select(3, GetQuestLogRewardInfo(slot)))
    end
end

function game_tooltip_hooks:SetBagItem(bag, slot)
	local link = GetContainerItemLink(bag, slot)
    if link then
        extend_tooltip(GameTooltip, link, EasyAH.select(2, GetContainerItemInfo(bag, slot)))
    end
end

function game_tooltip_hooks:SetInboxItem(index)
    local name, _, quantity = GetInboxItem(index)
    local id = name and info.item_id(name)
    if id then
        local _, itemstring, quality = GetItemInfo('item:' .. id)
		if quality and itemstring then
			local hex = EasyAH.select(4, GetItemQualityColor(tonumber(quality)))
			local link = hex ..  '|H' .. itemstring .. '|h[' .. name .. ']|h' .. FONT_COLOR_CODE_CLOSE
			extend_tooltip(GameTooltip, link, quantity)
		end
    end
end

function game_tooltip_hooks:SetInventoryItem(unit, slot)
	local link = GetInventoryItemLink(unit, slot)
    if link then
        extend_tooltip(GameTooltip, link, 1)
    end
end

function game_tooltip_hooks:SetMerchantItem(slot)
	local link = GetMerchantItemLink(slot)
    if link then
        local quantity = EasyAH.select(4, GetMerchantItemInfo(slot))
        extend_tooltip(GameTooltip, link, quantity)
    end
end

function game_tooltip_hooks:SetCraftItem(skill, slot)
    local link, quantity
    if slot then
        link, quantity = GetCraftReagentItemLink(skill, slot), EasyAH.select(3, GetCraftReagentInfo(skill, slot))
    else
        link, quantity = GetCraftItemLink(skill), 1
    end
    if link then
	    extend_tooltip(GameTooltip, link, quantity)
    end
end

function game_tooltip_hooks:SetCraftSpell(slot)
	local link = GetCraftItemLink(slot)
    if link then
        extend_tooltip(GameTooltip, link, 1)
    end
end

function game_tooltip_hooks:SetTradeSkillItem(skill, slot)
    local link, quantity
    if slot then
        link, quantity = GetTradeSkillReagentItemLink(skill, slot), EasyAH.select(3, GetTradeSkillReagentInfo(skill, slot))
    else
        link, quantity = GetTradeSkillItemLink(skill), 1
    end
    if link then
        extend_tooltip(GameTooltip, link, quantity)
    end
end

function game_tooltip_hooks:SetAuctionSellItem()
    local name, _, quantity = GetAuctionSellItemInfo()
    if name then
        for slot in info.inventory() do
	        T.temp(slot)
            local link = GetContainerItemLink(unpack(slot))
            if link and EasyAH.select(5, info.parse_link(link)) == name then
                extend_tooltip(GameTooltip, link, quantity)
                return
            end
        end
    end
end

-- Extra tooltip surfaces, so vendor prices also show up outside the auction
-- house: the trade window, group loot rolls and the merchant buyback tab.
function game_tooltip_hooks:SetTradePlayerItem(index)
    local link = GetTradePlayerItemLink and GetTradePlayerItemLink(index)
    if link then
        extend_tooltip(GameTooltip, link, EasyAH.select(3, GetTradePlayerItemInfo(index)))
    end
end

function game_tooltip_hooks:SetTradeTargetItem(index)
    local link = GetTradeTargetItemLink and GetTradeTargetItemLink(index)
    if link then
        extend_tooltip(GameTooltip, link, EasyAH.select(3, GetTradeTargetItemInfo(index)))
    end
end

function game_tooltip_hooks:SetLootRollItem(id)
    local link = GetLootRollItemLink and GetLootRollItemLink(id)
    if link then
        extend_tooltip(GameTooltip, link, EasyAH.select(3, GetLootRollItemInfo(id)))
    end
end

function game_tooltip_hooks:SetBuybackItem(slot)
    local link = GetBuybackItemLink and GetBuybackItemLink(slot)
    if link then
        extend_tooltip(GameTooltip, link, EasyAH.select(4, GetBuybackItemInfo(slot)))
    end
end
