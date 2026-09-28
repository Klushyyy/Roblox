--[[
	CutsceneChapters - picks and builds the run-start cutscene: each level has its own story told in
	chapters (CutsceneFamily / CutscenePizzeria / CutsceneCastle), and each run plays the next one.
	The profile counts the chapters seen per level (MetaState.Episodes), so the story carries on
	across sessions and loops back to chapter 1 after the last.
]]

local Client = script.Parent

local Chapters = {}

local STORIES = {
	require(Client:WaitForChild("CutsceneFamily")),
}

function Chapters.Count(level: number): number
	local list = STORIES[level] or STORIES[1]
	return #list
end

-- The chapter to play for a level after `seen` chapters (1-based).
function Chapters.Pick(level: number, seen: number?): number
	return ((seen or 0) % Chapters.Count(level)) + 1
end

function Chapters.Build(level: number, chapter: number, origin: CFrame, parent: Instance): any
	local list = STORIES[level] or STORIES[1]
	local build = list[math.clamp(chapter, 1, #list)]
	return build(origin, parent)
end

return Chapters
