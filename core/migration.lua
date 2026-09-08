module 'EasyAH.core.migration'
local EasyAH = require 'EasyAH'
local safety = require 'EasyAH.core.safety'
function EasyAH.handle.LOAD2()
    local a = EasyAH.account_data
    local numeric = {scale={1,.5,2}, undercut={1,0,500}, market_percentile={0,0,100}, min_profit_margin={5,0,100},
        market_ttl={300,30,3600}, auto_budget={10000,1,2147483647}, auto_max_lot={1000,1,2147483647},
        auto_reserve={10000,0,2147483647}, auto_max_quantity={20,1,10000}}
    for key, rule in numeric do
        local v = tonumber(a[key])
        a[key] = safety.finite(v) and max(rule[2], min(rule[3], v)) or rule[1]
    end
    if a.post_duration ~= 120 and a.post_duration ~= 480 and a.post_duration ~= 1440 then a.post_duration = 1440 end
    if a.undercut_mode ~= 'fixed' and a.undercut_mode ~= 'percent' and a.undercut_mode ~= 'match' then a.undercut_mode = 'fixed' end
    if a.undercut_mode == 'percent' then a.undercut = min(100, a.undercut) end
    if type(a.autoprice) ~= 'table' then a.autoprice = {} end
    local defaults = require('EasyAH.core.post').AUTOPRICE_DEFAULTS
    for key, default in defaults do
        local v = tonumber(a.autoprice[key])
        if not safety.finite(v) or v < 0 then a.autoprice[key] = default end
    end
    for _, key in ipairs({'value_buyout','merchant_buy_buyout','vendor_base','vendor_decay','bid_vs_buyout'}) do
        if a.autoprice[key] <= 0 then a.autoprice[key] = defaults[key] end
    end
    a.autoprice.bid_vs_buyout = min(1, a.autoprice.bid_vs_buyout)
    a.schema_version = 2
    EasyAH.frame:SetScale(a.scale)
end
