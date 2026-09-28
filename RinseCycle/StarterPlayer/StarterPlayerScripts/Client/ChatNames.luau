--[[
	ChatNames - VIPs get a gold name in the chat (their overhead name is gold too; see NameTags).

	The server sets Player.VIP (attribute) from the VIP game pass; this client colours the name
	prefix of every message from a VIP. TextChatService.OnIncomingMessage is a single callback, so
	this is the only place that sets it.
]]

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local ChatNames = {}

local GOLD_HEX = "#FFD24A"
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
		if player and player:GetAttribute("VIP") == true and message.PrefixText ~= "" then
			props.PrefixText = string.format('<font color="%s">%s</font>', GOLD_HEX, message.PrefixText)
		end
		return props
	end
end

return ChatNames
