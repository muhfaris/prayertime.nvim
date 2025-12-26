local M = {}

local function clamp_minutes(hour, minute)
	if not hour or not minute then
		return nil
	end
	if hour < 0 or hour > 23 or minute < 0 or minute > 59 then
		return nil
	end
	return hour * 60 + minute
end

function M.parse_time_str(value)
	if type(value) ~= "string" then
		return nil
	end
	local trimmed = value:match("^%s*(%d%d?:%d%d)") or value
	local hour_str, minute_str = trimmed:match("^(%d%d?):(%d%d)$")
	if not hour_str then
		return nil
	end
	return clamp_minutes(tonumber(hour_str), tonumber(minute_str))
end

function M.minutes_to_time(total)
	total = total % (24 * 60)
	local hours = math.floor(total / 60)
	local minutes = total % 60
	return ("%02d:%02d"):format(hours, minutes)
end

return M
