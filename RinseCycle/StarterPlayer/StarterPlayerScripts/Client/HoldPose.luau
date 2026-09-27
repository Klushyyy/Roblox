--[[
	HoldPose - how a held cleaning tool looks, for every player on this client.

	  * Anyone holding a tool (character attribute HeldToolIndex > 1) holds it out in front: the
	    right shoulder is raised forward and the elbow and wrist are straightened, set every frame
	    after the animations run (R15 and R6; Motor6D or the newer AnimationConstraint joints).
	    The tool itself is welded to the torso by the server, so it points forward even if a rig
	    can't be posed.
	  * In first person Roblox hides your whole character, tool included. The held tool and your
	    right arm are shown again after the camera's update, so you can see what you're holding.
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
			if character:FindFirstChild("RightUpperArm") then
				setJoint(character, "RightUpperArm", "RightShoulder", RAISE)
				setJoint(character, "RightLowerArm", "RightElbow", CFrame.identity)
				setJoint(character, "RightHand", "RightWrist", CFrame.identity)
			else
				setJoint(character, "Torso", "Right Shoulder", RAISE_R6)
			end
		end
	end
end

-- After the camera's transparency pass (which hides the character when zoomed right in).
local function showInFirstPerson()
	local character = LocalPlayer.Character
	local camera = Workspace.CurrentCamera
	if not character or not camera or not holding(character) then
		return
	end
	local head = character:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") or (camera.CFrame.Position - head.Position).Magnitude > 1.5 then
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
