--[[
	HoldPose - how a held cleaning tool looks, for every player on this client.

	  * Anyone holding a tool (character attribute HeldToolIndex > 1) holds it out in front: the
	    right shoulder is raised forward and the elbow and wrist are straightened, set every frame
	    after the animations run (R15 and R6; Motor6D or the newer AnimationConstraint joints).
	    The tool itself is welded to the torso by the server, so it points forward even if a rig
	    can't be posed.
	  * Your own tool follows where you look: it tilts up and down with the camera (the arm with it),
	    so it's always in view and pointing at what you're aiming at.
	  * In first person Roblox hides your whole character, tool included. The held tool and your
	    right arm are shown again after the camera's update, so you can see what you're holding.
	    Your own name tag is hidden in first person (it would float in your face looking up).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local HoldPose = {}

local LocalPlayer = Players.LocalPlayer
local RAISE = CFrame.Angles(math.rad(90), 0, 0)
local RAISE_R6 = CFrame.Angles(0, 0, math.rad(90)) -- the R6 shoulder's joint axis is turned
local ARM_PARTS = { "RightUpperArm", "RightLowerArm", "RightHand", "Right Arm" }

local initialized = false
local MAX_PITCH = math.rad(75)
local localPitch = 0 -- the local player's current aim pitch (radians, up = positive)
local baseC0: { [Weld]: CFrame } = setmetatable({}, { __mode = "k" }) :: any

local function holding(character: Model): boolean
	local index = tonumber(character:GetAttribute("HeldToolIndex"))
	return index ~= nil and index > 1 and character:FindFirstChild("HeldTool") ~= nil
end

local function setJoint(character: Model, partName: string, jointName: string, cf: CFrame)
	local part = character:FindFirstChild(partName)
	local joint = part and part:FindFirstChild(jointName)
	if joint and (joint:IsA("Motor6D") or joint:IsA("AnimationConstraint")) then
		(joint :: any).Transform = cf
	end
end

-- After the Animator has written this frame's joint transforms.
local function poseAll()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character and holding(character) then
			local raise = if player == LocalPlayer then CFrame.Angles(math.rad(90) + localPitch, 0, 0) else RAISE
			if character:FindFirstChild("RightUpperArm") then
				setJoint(character, "RightUpperArm", "RightShoulder", raise)
				setJoint(character, "RightLowerArm", "RightElbow", CFrame.identity)
				setJoint(character, "RightHand", "RightWrist", CFrame.identity)
			else
				setJoint(character, "Torso", "Right Shoulder", RAISE_R6)
			end
		end
	end
end

-- Tilts the local player's tool weld about the right shoulder to the camera's pitch.
local function aimTool(character: Model, camera: Camera)
	local held = character:FindFirstChild("HeldTool")
	local grip = held and (held :: Model).PrimaryPart
	local weld = grip and grip:FindFirstChildOfClass("Weld")
	local torso = weld and weld.Part0
	if not weld or not torso then
		localPitch = 0
		return
	end
	local base = baseC0[weld]
	if not base then
		base = weld.C0
		baseC0[weld] = base
	end
	localPitch = math.clamp(math.asin(math.clamp(camera.CFrame.LookVector.Y, -1, 1)), -MAX_PITCH, MAX_PITCH)
	local r15 = torso.Name == "UpperTorso"
	local shoulder = CFrame.new(1.5 * torso.Size.X / 2, (if r15 then 0.55 else 0.5) * torso.Size.Y / (if r15 then 1.6 else 2), 0)
	weld.C0 = shoulder * CFrame.Angles(localPitch, 0, 0) * shoulder:Inverse() * base
end

-- After the camera's own update (which also hides the character when zoomed right in).
local function showInFirstPerson()
	local character = LocalPlayer.Character
	local camera = Workspace.CurrentCamera
	if not character or not camera then
		return
	end
	local head = character:FindFirstChild("Head")
	local firstPerson = head ~= nil and head:IsA("BasePart") and (camera.CFrame.Position - head.Position).Magnitude <= 1.5
	local tag = head and head:FindFirstChild("NameTag")
	if tag and tag:IsA("BillboardGui") then
		tag.Enabled = not firstPerson and character:GetAttribute("AdminHidden") ~= true
	end
	if not holding(character) then
		localPitch = 0
		return
	end
	aimTool(character, camera)
	if not firstPerson then
		return
	end
	local held = character:FindFirstChild("HeldTool")
	if held then
		for _, d in held:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = 0
			end
		end
	end
	for _, name in ARM_PARTS do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			part.LocalTransparencyModifier = 0
		end
	end
end

function HoldPose.Init()
	if initialized then
		return
	end
	initialized = true
	RunService.Stepped:Connect(poseAll)
	RunService:BindToRenderStep("RinseCycleHeldTool", Enum.RenderPriority.Camera.Value + 1, showInFirstPerson)
end

return HoldPose
