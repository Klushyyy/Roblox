-- Number and time formatting for UI text.

local Format = {}

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi" }

-- 950 -> "950", 1234 -> "1.2K", 15300 -> "15.3K", 2500000 -> "2.5M"
function Format.Short(n: number): string
	n = math.floor(n or 0)
	local negative = n < 0
	n = math.abs(n)
	if n < 1000 then
		return (negative and "-" or "") .. tostring(n)
	end
	local i = 1
	local value = n
	while value >= 1000 and i < #SUFFIXES do
		value /= 1000
		i += 1
	end
	local text
	if value >= 100 then
		text = string.format("%d", math.floor(value))
	elseif value >= 10 then
		text = string.format("%.1f", math.floor(value * 10) / 10)
	else
		text = string.format("%.2f", math.floor(value * 100) / 100)
	end
	text = text:gsub("%.?0+$", "")
	return (negative and "-" or "") .. text .. SUFFIXES[i]
end

-- 1234567 -> "1,234,567"
function Format.Commas(n: number): string
	local s = tostring(math.floor(n or 0))
	local negative = s:sub(1, 1) == "-"
	if negative then
		s = s:sub(2)
	end
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if out:sub(1, 1) == "," then
		out = out:sub(2)
	end
	return (negative and "-" or "") .. out
end

-- 75 -> "1:15", 3725 -> "1:02:05"
function Format.Time(seconds: number): string
	seconds = math.max(0, math.floor(seconds or 0))
	local h = seconds // 3600
	local m = (seconds % 3600) // 60
	local s = seconds % 60
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%d:%02d", m, s)
end

-- 0.05 -> "+5%", 0.125 -> "+12.5%"
function Format.Percent(fraction: number): string
	local pct = math.floor(fraction * 1000 + 0.5) / 10
	local text = if pct == math.floor(pct) then string.format("%d", pct) else string.format("%.1f", pct)
	return (fraction >= 0 and "+" or "") .. text .. "%"
end

-- 0.5 -> "0.5%", 3.5 -> "3.5%", 60 -> "60%"  (already a percentage)
function Format.Chance(pct: number): string
	if pct == math.floor(pct) then
		return string.format("%d%%", pct)
	end
	return (string.format("%.2f", pct):gsub("0+$", "")) .. "%"
end

return Format
