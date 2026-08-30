module 'EasyAH.core.slash'

local T = require 'T'
local EasyAH = require 'EasyAH'
local settings = require 'EasyAH.tabs.settings'

-- /eah is the only slash command. It always opens the standalone Settings
-- window (independent of whether the Auction House is open). All
-- configuration now lives in that window instead of chat commands.
_G.SLASH_EAH1 = '/eah'
function SlashCmdList.EAH(command)
	settings.show()
end
