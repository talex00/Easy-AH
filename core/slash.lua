module 'EasyAH.core.slash'
local EasyAH = require 'EasyAH'
local settings = require 'EasyAH.tabs.settings'
local safety = require 'EasyAH.core.safety'
local post = require 'EasyAH.tabs.post'
local money = require 'EasyAH.util.money'
_G.SLASH_EAH1 = '/eah'
function SlashCmdList.EAH(command)
    command = strlower(EasyAH.trim(command or ''))
    if command == 'stop' then EasyAH.stop_all(); EasyAH.print('Stopped; auto buying disarmed.'); return end
    if command == 'log' then safety.show_log_window(); return end
    if command == 'plan' then post.show_plan(); return end
    if command == 'vendor' then
        local t = EasyAH.character_data.tooltip
        t.merchant_sell = not t.merchant_sell
        EasyAH.print('Vendor tooltip:', t.merchant_sell and 'on' or 'off'); return
    end
    if command == 'auto off' then safety.disarm(); EasyAH.print('Auto Buy/Bid disarmed.'); return end
    if command == 'auto on' then
        local ok, reason = safety.arm()
        EasyAH.print(ok and 'Auto Buy/Bid armed for this AH visit. Saved filters still apply.' or reason); return
    end
    local _, _, key, text = strfind(command, '^auto (%a+) (.+)$')
    local fields = {budget='auto_budget', lot='auto_max_lot', reserve='auto_reserve', quantity='auto_max_quantity'}
    if key and fields[key] then
        local value = key == 'quantity' and tonumber(text) or money.from_string(text)
        if not safety.money(value) or (key ~= 'reserve' and value < 1) then EasyAH.print('Invalid positive limit. Examples: 1g, 10s, quantity 20.'); return end
        safety.disarm()
        EasyAH.account_data[fields[key]] = value
        EasyAH.print('Auto limit updated; re-arm explicitly.'); return
    end
    if command == 'auto' or command == 'help' then
        local a = EasyAH.account_data
        EasyAH.print('/eah auto on | off; /eah auto budget 1g; lot 10s; reserve 1g; quantity 20')
        EasyAH.print('Budget:', money.to_string(a.auto_budget), 'used:', money.to_string(safety.budget_used()), 'lot:', money.to_string(a.auto_max_lot), 'reserve:', money.to_string(a.auto_reserve), 'quantity:', a.auto_max_quantity)
        EasyAH.print('/eah stop | plan | log | vendor. Limits reset usage only on login/reload.'); return
    end
    settings.show()
end
