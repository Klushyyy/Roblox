-- v2.21.0: the leaderboard arrows' click zones sit over the arrow that is DRAWN there. (They were mirrored: the arrow on the
-- right turned the page back, so the Fastest Clean board went Family Dinner -> Royal Banquet -> Pizza Party.)
-- A part's front face is -Z; a viewer standing in front sees the part's -X on their right.
local total, failed = 0, 0
local function check(name, ok, detail)
	total += 1
	if not ok then failed += 1 end
	out(string.format("%3d %s %s%s", total, if ok then "PASS" else "FAIL", name, if detail ~= nil then "   [" .. tostring(detail) .. "]" else ""))
end
local found = 0
for _, d in game:GetService("Workspace"):GetDescendants() do
	if d.Name == "BoardArrow" and d:GetAttribute("Dir") ~= nil then
		found += 1
		local board = d.Parent
		local localPos = board.CFrame:PointToObjectSpace(d.Position)
		local dir = d:GetAttribute("Dir")
		-- the viewer's right is -X
		local viewerRight = -localPos.X
		check(string.format("%s arrow on %s is on the %s of the board as seen from the front", if dir > 0 then "right" else "left", board.Name, if dir > 0 then "right" else "left"),
			(dir > 0 and viewerRight > 3) or (dir < 0 and viewerRight < -3), string.format("viewer-right offset %.1f", viewerRight))
		check("...in front of the board's face (toward the viewer)", localPos.Z < 0, localPos.Z)
		check("...near the top of the board", localPos.Y > 0, localPos.Y)
	end
end
check("the lobby has the board arrows (2 per paged board)", found >= 4, found)
out(string.format("== %d CHECKS: %d passed, %d FAILED", total, total - failed, failed))
