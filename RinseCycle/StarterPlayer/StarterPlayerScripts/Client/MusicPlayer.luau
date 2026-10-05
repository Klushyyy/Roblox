--[[
	MusicPlayer - background music. The lobby and dishwasher runs each have their own playlist
	(Config.Music, IDs from StoreIds > Music), played shuffled, one track after another. Each track
	crossfades into the next (the next one starts 30 seconds before the end), and there's a
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

local FADE = 1.2 -- a plain switch (lobby <-> run)
local FADE_OUT = 3 -- the old track fades out over this...
local FADE_IN = 2 -- ...while the next fades in over this

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

-- Plays the given playlist, shuffled, until something else is chosen. There is never silence: a new
-- track is started and loaded first, and only then does the old one fade out (3 s) as the new one
-- fades in (2 s). Tracks hand over 30 seconds before they end (a long track often ends in a quiet
-- tail), or 6 s before for short ones.
local function playList(name: string)
	local ids = listIds(name)
	if name == currentList and current then
		return
	end
	currentList = name
	token += 1
	local myToken = token
	local previous: Sound? = current
	current = nil
	if not enabled or #ids == 0 then
		if previous then
			fadeOut(previous, FADE)
		end
		return
	end
	task.spawn(function()
		local order = table.clone(ids)
		local index = 0
		local failures = 0
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
			-- wait for it to load before the old one fades out (a track that never loads is skipped)
			local started = os.clock()
			while myToken == token and sound.Parent and not sound.IsLoaded and os.clock() - started < 8 do
				task.wait(0.1)
			end
			if myToken ~= token or not sound.Parent then
				return -- another playlist took over (it fades this one out)
			end
			if not sound.IsLoaded then
				sound:Destroy()
				current = previous
				failures += 1
				if failures >= #order * 2 then
					if previous then
						fadeOut(previous, FADE)
						current = nil
					end
					return
				end
				continue
			end
			TweenService:Create(sound, TweenInfo.new(FADE_IN), { Volume = Config.Music.Volume }):Play()
			if previous then
				fadeOut(previous, FADE_OUT)
				previous = nil
			end
			-- play until it is time to hand over to the next track
			while myToken == token and sound.Parent do
				if sound.IsLoaded and sound.TimeLength > 0 then
					local handOver = if sound.TimeLength > 75 then sound.TimeLength - 30 else math.max(1, sound.TimeLength - 6)
					if sound.TimePosition >= handOver then
						break
					end
				end
				if not sound.IsPlaying and os.clock() - started > 12 then
					break -- it stopped by itself
				end
				task.wait(0.4)
			end
			if myToken ~= token then
				return
			end
			previous = sound
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
