-- Every RemoteEvent / RemoteFunction the game uses, in one place.
-- The server creates them (Remotes.Setup() from Main); clients wait for them.
-- Payload shapes are documented in DESIGN.md ("Remotes").

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

Remotes.Events = {
	"PartyAction", -- C->S (action: string, value: any)
	"PartyState", -- S->C (state: PartyState?)
	"Scrub", -- C->S (aimPosition: Vector3, holding: boolean)
	"RunState", -- S->C (state: RunState?)
	"RunFX", -- S->C (kind: string, data: table)
	"MetaState", -- S->C (state: MetaState)
	"Notify", -- S->C (text: string, kind: "Info" | "Good" | "Bad")
}

Remotes.Functions = {
	"RunRequest", -- C->S (action: string, value: any) -> { Ok: boolean, Error: string? }
	"MetaRequest", -- C->S (action: string, value: any) -> { Ok: boolean, Error: string?, ... }
	"GetMeta", -- C->S () -> MetaState?
}

local FOLDER_NAME = "Remotes"

local function getFolder(): Folder
	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			folder.Parent = ReplicatedStorage
		end
		return folder :: Folder
	end
	return ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
end

-- Server only: create every remote up front so clients never wait forever.
function Remotes.Setup()
	assert(RunService:IsServer(), "Remotes.Setup is server-only")
	local folder = getFolder()
	for _, name in Remotes.Events do
		if not folder:FindFirstChild(name) then
			local r = Instance.new("RemoteEvent")
			r.Name = name
			r.Parent = folder
		end
	end
	for _, name in Remotes.Functions do
		if not folder:FindFirstChild(name) then
			local r = Instance.new("RemoteFunction")
			r.Name = name
			r.Parent = folder
		end
	end
end

function Remotes.Event(name: string): RemoteEvent
	assert(table.find(Remotes.Events, name), "Unknown RemoteEvent " .. name)
	local folder = getFolder()
	if RunService:IsServer() then
		local r = folder:FindFirstChild(name)
		assert(r, "Remotes.Setup() has not created " .. name)
		return r :: RemoteEvent
	end
	return folder:WaitForChild(name) :: RemoteEvent
end

function Remotes.Function(name: string): RemoteFunction
	assert(table.find(Remotes.Functions, name), "Unknown RemoteFunction " .. name)
	local folder = getFolder()
	if RunService:IsServer() then
		local r = folder:FindFirstChild(name)
		assert(r, "Remotes.Setup() has not created " .. name)
		return r :: RemoteFunction
	end
	return folder:WaitForChild(name) :: RemoteFunction
end

return Remotes
