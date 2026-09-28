-- Serializes a mock GUI tree to plain tables (for the Python GUI renderer).
local function ser(v)
	local t = typeof(v)
	if t == "UDim2" then
		return { t = "UDim2", xs = v.X.Scale, xo = v.X.Offset, ys = v.Y.Scale, yo = v.Y.Offset }
	elseif t == "UDim" then
		return { t = "UDim", s = v.Scale, o = v.Offset }
	elseif t == "Vector2" then
		return { t = "Vector2", x = v.X, y = v.Y }
	elseif t == "Color3" then
		return { t = "Color3", r = v.R, g = v.G, b = v.B }
	elseif t == "ColorSequence" then
		local k = {}
		for _, kp in v.Keypoints do
			table.insert(k, { kp.Time, kp.Value.R, kp.Value.G, kp.Value.B })
		end
		return { t = "ColorSequence", k = k }
	elseif t == "NumberSequence" then
		local k = {}
		for _, kp in v.Keypoints do
			table.insert(k, { kp.Time, kp.Value })
		end
		return { t = "NumberSequence", k = k }
	elseif t == "EnumItem" then
		return { t = "Enum", v = v.Name }
	elseif t == "number" or t == "string" or t == "boolean" then
		return v
	end
	return nil
end
local function dump(inst, methods)
	local p = rawget(inst, "__p")
	local props = {}
	for k, v in p do
		if k ~= "Parent" then
			local s = ser(v)
			if s ~= nil then
				props[k] = s
			end
		end
	end
	local attrs = {}
	for k, v in rawget(inst, "__attrs") do
		attrs[k] = ser(v)
	end
	local kids = {}
	for _, c in methods.GetChildren(inst) do
		table.insert(kids, dump(c, methods))
	end
	return { props = props, attrs = attrs, children = kids }
end
return dump
