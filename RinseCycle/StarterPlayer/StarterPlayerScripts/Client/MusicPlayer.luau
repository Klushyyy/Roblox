--[[
	MusicPlayer - background music. The lobby and dishwasher runs each have their own playlist
	(Config.Music, IDs from StoreIds > Music), played shuffled, one track after another. Each track
	crossfades into the next (the next one starts CROSSFADE seconds before the end), and there's a
	short fade when switching between lobby and run. A "Music" button in the left column turns it
	off / on (remembered for this session). Plays nothing until track IDs are filled in.
]]

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))

local MusicPlayer = {}

local FADE = 0.6
local CROSSFADE = 4 -- seconds the end of one track overlaps the start of the next

local initialized = false
local enabled = true
local current: Sound? = nil
local currentList = ""
local token = 0

local function fadeOut(sound: Sound, seconds: number?)
	local t = seconds or FADE
	TweenService:Create(sound, TweenInfo.new(t), { Volume = 0 }):Play()
	task.delay(t + 0.1, function()
		sound:Destroy()
	end)
end

-- Plays the given playlist, shuffled, until something else is chosen.
local function listIds(name: string): { number }
	local show = (Config.AbuseShow :: any).Music
	if string.sub(name, 1, 5) == "Abuse" and show then
		return show[string.sub(name, 6)] or {}
	end
	return (Config.Music :: any)[name] or {}
end

local function playList(name: string)
	local ids = listIds(name)
	if name == currentList and current then
		return
	end
	currentList = name
	token += 1
	local myToken = token
	if current then
		fadeOut(current)
		current = nil
	end
	if not enabled or #ids == 0 then
		return
	end
	task.spawn(function()
		local order = table.clone(ids)
		local firstTrack = true
		local index = 0
		while myToken == token do
			index += 1
			if index > #order then
				-- reshuffle for the next round
				for i = #order, 2, -1 do
					local j = math.random(1, i)
					order[i], order[j] = order[j], order[i]
				end
				index = 1
			end
			local sound = Instance.new("Sound")
			sound.Name = "Music"
			sound.SoundId = "rbxassetid://" .. tostring(order[index])
			sound.Volume = 0
			sound.Parent = SoundService
			current = sound
			sound:Play()
			TweenService:Create(sound, TweenInfo.new(if firstTrack then FADE else CROSSFADE), { Volume = Config.Music.Volume }):Play()
			firstTrack = false
			-- Wait for the track to near its end (or something else to take over); a track that
			-- never loads is skipped after a while.
			local started = os.clock()
			local crossfading = false
			while myToken == token and sound.Parent do
				if sound.IsLoaded and not sound.IsPlaying and os.clock() - started > 2 then
					break
				end
				if sound.IsLoaded and sound.TimeLength > CROSSFADE * 3 and sound.TimePosition >= sound.TimeLength - CROSSFADE then
					crossfading = true
					break
				end
				if not sound.IsLoaded and os.clock() - started > 15 then
					break
				end
				task.wait(0.5)
			end
			if myToken == token and sound.Parent then
				if crossfading then
					fadeOut(sound, CROSSFADE) -- the next track fades in over it
				else
					sound:Destroy()
				end
			end
		end
	end)
end

local function refresh()
	-- During the Admin Abuse show its own music plays (the server sets the attribute "AbuseMusic").
	local show = ReplicatedStorage:GetAttribute("AbuseMusic")
	if show == "Warm" or show == "Heat" then
		playList("Abuse" .. show)
		return
	end
	playList(if ClientState.Run then "Run" else "Lobby")
end

function MusicPlayer.IsEnabled(): boolean
	return enabled
end

function MusicPlayer.SetEnabled(on: boolean)
	enabled = on
	currentList = ""
	if current then
		fadeOut(current)
		current = nil
	end
	token += 1
	refresh()
end

-- Loads the show tracks ahead of time, so there is no gap when it starts.
local function preloadShow()
	local ContentProvider = game:GetService("ContentProvider")
	local list = {}
	local show = (Config.AbuseShow :: any).Music
	for _, key in { "Warm", "Heat" } do
		for _, id in (show and show[key]) or {} do
			local sound = Instance.new("Sound")
			sound.SoundId = "rbxassetid://" .. tostring(id)
			table.insert(list, sound)
		end
	end
	pcall(function()
		ContentProvider:PreloadAsync(list)
	end)
	for _, sound in list do
		sound:Destroy()
	end
end

function MusicPlayer.Init()
	if initialized then
		return
	end
	initialized = true
	task.spawn(function()
		task.wait(8)
		preloadShow()
	end)
	ClientState.Changed:Connect(function(kind)
		if kind == "Run" then
			refresh()
		end
	end)
	ReplicatedStorage:GetAttributeChangedSignal("AbuseMusic"):Connect(refresh)
	refresh()
end

return MusicPlayer
