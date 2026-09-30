--[[
	ChatNames - VIPs get a gold [VIP] tag before their name in the chat, "[VIP] Klushy: hi" (their
	overhead name has the same tag; see NameTags). Staff get [MOD] / [ADMIN] / [DEV] / [OWNER]
	instead (player attribute StaffTag, set by AdminServer).

	The server sets Player.VIP (attribute) from the VIP game pass; this client adds the tag to the
	prefix of every message from a VIP. TextChatService.OnIncomingMessage is a single callback, so
	this is the only place that sets it.
]]

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local ChatNames = {}

local GOLD_HEX = "#FFD24A"
-- Staff get their rank's tag instead: [MOD] green, [ADMIN] red, [DEV] blue, [OWNER] purple.
local STAFF_HEX = { MOD = "#50DC64", ADMIN = "#FF4B4B", DEV = "#50A0FF", OWNER = "#B964FF" }
local initialized = false

function ChatNames.Init()
	if initialized then
		return
	end
	initialized = true
	TextChatService.OnIncomingMessage = function(message: TextChatMessage)
		local props = Instance.new("TextChatMessageProperties")
		local source = message.TextSource
		local player = source and Players:GetPlayerByUserId(source.UserId)
		local staff = player and player:GetAttribute("StaffTag")
		local staffHex = type(staff) == "string" and STAFF_HEX[staff]
		if staffHex and message.PrefixText ~= "" then
			props.PrefixText = string.format('<font color="%s"><b>[%s]</b></font> %s', staffHex, staff, message.PrefixText)
		elseif player and player:GetAttribute("VIP") == true and message.PrefixText ~= "" then
			props.PrefixText = string.format('<font color="%s"><b>[VIP]</b></font> %s', GOLD_HEX, message.PrefixText)
		end
		return props
	end
end

return ChatNames
