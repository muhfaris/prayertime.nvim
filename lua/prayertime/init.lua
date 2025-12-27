local util = require("prayertime.util")
local formats = {
	standard = require("prayertime.formats.standard"),
}

local active_format = formats.standard
local active_name = "standard"

local notify = vim.notify
do
	local ok, plugin = pcall(require, "notify")
	if ok then
		notify = plugin
	end
end

local REQUIRED_EXPORTS = { "fetch_times", "get_status", "check_for_adhan" }
local TODAY_COLUMNS = {
	{ key = "Fajr", label = "Fajr" },
	{ key = "Dhuhr", label = "Dhuhr" },
	{ key = "Asr", label = "Asr" },
	{ key = "Maghrib", label = "Maghrib" },
	{ key = "Isha", label = "Isya" },
}

local function format_duration(minutes)
	if not minutes or minutes < 0 then
		return "??"
	end
	local hours = math.floor(minutes / 60)
	local mins = minutes % 60
	local parts = {}
	if hours > 0 then
		table.insert(parts, ("%dh"):format(hours))
	end
	if mins > 0 then
		table.insert(parts, ("%dm"):format(mins))
	end
	if #parts == 0 then
		return "0m"
	end
	return table.concat(parts, " ")
end

local function sanitize_opts(opts)
	if type(opts) ~= "table" then
		return nil
	end
	return vim.tbl_deep_extend("force", {}, opts)
end

local function validate_format(name, module)
	for _, field in ipairs(REQUIRED_EXPORTS) do
		if type(module[field]) ~= "function" then
			error(("Format '%s' must implement %s()"):format(name, field))
		end
	end
end

validate_format("standard", formats.standard)

local M = {}

local timer_id = nil
local timer_key = "__prayertime_timer_id"
local today_display = { token = 0 }

local function stop_existing_timer()
	local existing = vim.g[timer_key]
	if existing and existing ~= 0 then
		pcall(vim.fn.timer_stop, existing)
		vim.g[timer_key] = nil
	end
end

local function timer_callback()
	if active_format and type(active_format.check_for_adhan) == "function" then
		local ok, err = pcall(active_format.check_for_adhan)
		if not ok then
			notify(("prayertime: check_for_adhan failed: %s"):format(err), vim.log.levels.ERROR)
		end
	end
end

local function ensure_timer()
	if timer_id then
		return timer_id
	end
	stop_existing_timer()
	timer_id = vim.fn.timer_start(60000, timer_callback, { ["repeat"] = -1 })
	vim.g[timer_key] = timer_id
	return timer_id
end

local function reset_timer()
	if timer_id then
		pcall(vim.fn.timer_stop, timer_id)
		timer_id = nil
		vim.g[timer_key] = nil
	end
	ensure_timer()
end

local function use_format(name)
	local module = formats[name]
	if not module then
		return nil, ("Unknown prayer time format: %s"):format(name or "nil")
	end
	validate_format(name, module)
	active_format = module
	active_name = name
	reset_timer()
	return module
end

local function call_active(method, ...)
	if not active_format then
		return nil
	end
	local fn = active_format[method]
	if type(fn) ~= "function" then
		return nil
	end
	return fn(...)
end

local function close_today_display()
	if today_display.win and vim.api.nvim_win_is_valid(today_display.win) then
		vim.api.nvim_win_close(today_display.win, true)
	end
	if today_display.buf and vim.api.nvim_buf_is_valid(today_display.buf) then
		vim.api.nvim_buf_delete(today_display.buf, { force = true })
	end
	today_display.win = nil
	today_display.buf = nil
	today_display.token = (today_display.token or 0) + 1
end

function M.register_format(name, module)
	if type(name) ~= "string" or name == "" then
		error("Format name must be a non-empty string")
	end
	if type(module) ~= "table" then
		error("Format module must be a table")
	end
	validate_format(name, module)
	formats[name] = module
end

local function apply_format_from_opts(opts)
	opts = opts or {}
	local format_name = opts.format or "standard"
	local forwarded_opts = sanitize_opts(opts)
	if forwarded_opts then
		forwarded_opts.format = nil
	end
	local module, err = use_format(format_name)
	if not module then
		notify(err, vim.log.levels.ERROR)
		module = formats.standard
		active_format = module
		active_name = "standard"
		ensure_timer()
	end
	if module and type(module.setup) == "function" then
		module.setup(forwarded_opts)
	end
	return module
end

function M.setup(opts)
	local module = apply_format_from_opts(opts)
	if module then
		call_active("fetch_times")
	end
end

function M.use_format(name, opts)
	local forwarded_opts = sanitize_opts(opts)
	if forwarded_opts then
		forwarded_opts.format = nil
	end
	local module, err = use_format(name)
	if not module then
		notify(err, vim.log.levels.ERROR)
		return
	end
	if type(module.setup) == "function" then
		module.setup(forwarded_opts)
	end
	call_active("fetch_times")
end

function M.refresh()
	return call_active("fetch_times")
end

function M.get_status(...)
	local ok, result = pcall(call_active, "get_status", ...)
	if not ok then
		notify(("prayertime: get_status failed: %s"):format(result), vim.log.levels.ERROR)
		return "Prayer times unavailable"
	end
	return result or "Prayer times unavailable"
end

function M.get_prayer_times()
	return call_active("get_prayer_times") or {}
end

function M.get_cached_payload()
	return call_active("get_cached_payload")
end

function M.get_derived_times()
	return call_active("get_derived_times") or {}
end

function M.get_derived_ranges()
	return call_active("get_derived_ranges") or {}
end

function M.get_last_updated()
	return call_active("get_last_updated")
end

function M.get_config()
	return call_active("get_config")
end

function M.active_format_name()
	return active_name
end

local function build_today_lines()
	local base_times = M.get_prayer_times()
	if not base_times or vim.tbl_isempty(base_times) then
		return nil
	end

	local derived = M.get_derived_times()
	local entries = {}
	local label_width = 0
	for _, column in ipairs(TODAY_COLUMNS) do
		local label = column.label or column.key
		local value = derived[column.key] or base_times[column.key]
		if type(value) ~= "string" or value == "" then
			value = "--:--"
		end
		local minutes = util.parse_time_str(value)
		entries[#entries + 1] = {
			key = column.key,
			label = label,
			value = value,
			minutes = minutes,
		}
		label_width = math.max(label_width, vim.fn.strdisplaywidth(label))
	end

	local now_minutes = util.parse_time_str(os.date("%H:%M")) or 0
	local next_index, current_index = nil, nil
	local valid_indices = {}

	for idx, entry in ipairs(entries) do
		if entry.minutes then
			table.insert(valid_indices, idx)
			if not next_index and entry.minutes >= now_minutes then
				next_index = idx
			end
			if entry.minutes <= now_minutes then
				current_index = idx
			end
		end
	end

	if not next_index then
		next_index = valid_indices[1]
	end

	if
		not current_index
		and next_index
		and entries[next_index]
		and entries[next_index].minutes
		and entries[next_index].minutes > now_minutes
	then
	-- before the first prayer of the day, leave current nil
	elseif not current_index and #valid_indices > 0 then
		current_index = valid_indices[#valid_indices]
	end

	local next_entry = next_index and entries[next_index] or nil
	local next_delta = nil
	if next_entry and next_entry.minutes then
		local target = next_entry.minutes
		if target < now_minutes then
			target = target + (24 * 60)
		end
		next_delta = target - now_minutes
	end

	local cfg = M.get_config() or {}
	local city = (cfg.city and cfg.city ~= "") and cfg.city or nil
	local country = (cfg.country and cfg.country ~= "") and cfg.country or nil
	local location
	if city and country then
		location = ("%s, %s"):format(city, country)
	else
		location = city or country or "Prayer Schedule"
	end
	local header = ("🕌 %s — Today"):format(location)

	local next_line
	if next_entry and next_entry.minutes then
		next_line = ("NEXT  ⏱  %s in %s"):format(next_entry.label, format_duration(next_delta))
	else
		next_line = "NEXT  ⏱  --"
	end

	local rows = {}
	local row_width = math.max(vim.fn.strdisplaywidth(header), vim.fn.strdisplaywidth(next_line))

	local function status_for(idx, entry)
		if not entry.minutes then
			return " "
		end
		if next_index == idx then
			return "★"
		end
		if current_index == idx then
			return "→"
		end
		if entry.minutes < now_minutes then
			return "✓"
		end
		return " "
	end

	for idx, entry in ipairs(entries) do
		local status = status_for(idx, entry)
		local line = string.format("%-" .. label_width .. "s  %5s  %s", entry.label, entry.value, status)
		row_width = math.max(row_width, vim.fn.strdisplaywidth(line))
		table.insert(rows, line)
	end

	local separator = string.rep("-", math.max(row_width, 24))

	local lines = { header, "", next_line, separator }
	vim.list_extend(lines, rows)
	return lines
end

local function open_today_float(lines, opts)
	close_today_display()
	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	width = math.max(width, 20)
	local height = #lines

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "prayertime"

	local row = math.max(0, vim.o.lines - height - 3)
	local col = math.max(0, vim.o.columns - width - 4)

	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
	})

	today_display.buf = buf
	today_display.win = win
	local token = today_display.token or 0
	local duration = (opts and opts.duration) or 6000

	vim.keymap.set("n", "q", close_today_display, { buffer = buf, nowait = true, silent = true })
	vim.keymap.set("n", "<Esc>", close_today_display, { buffer = buf, nowait = true, silent = true })

	if duration and duration > 0 then
		vim.defer_fn(function()
			if today_display.token ~= token then
				return
			end
			close_today_display()
		end, duration)
	end
end

local function notify_table(title, tbl)
	if not tbl or vim.tbl_isempty(tbl) then
		notify("prayertime: no cached data", vim.log.levels.WARN)
		return
	end
	local lines = {}
	for key, value in pairs(tbl) do
		table.insert(lines, ("%s: %s"):format(key, value))
	end
	table.sort(lines)
	notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = title })
end

vim.api.nvim_create_user_command("PrayerReload", function()
	local ok, err = pcall(M.refresh)
	if not ok then
		notify(("prayertime: refresh failed: %s"):format(err), vim.log.levels.ERROR)
	else
		notify("prayertime: fetching latest schedule…", vim.log.levels.INFO)
	end
end, { desc = "Fetch latest prayer times" })

vim.api.nvim_create_user_command("PrayerFormat", function(params)
	local name = vim.trim(params.args or "")
	if name == "" then
		notify("Usage: :PrayerFormat <format>", vim.log.levels.WARN)
		return
	end
	local ok, err = pcall(M.use_format, name)
	if not ok then
		notify(("prayertime: failed to switch format: %s"):format(err), vim.log.levels.ERROR)
	else
		notify(("prayertime: switched to %s"):format(name), vim.log.levels.INFO)
	end
end, {
	desc = "Switch active prayer-time format",
	nargs = 1,
	complete = function()
		return vim.tbl_keys(formats)
	end,
})

vim.api.nvim_create_user_command("PrayerTimes", function()
	notify_table("Prayer Times", M.get_prayer_times())
end, { desc = "Show cached prayer times" })

vim.api.nvim_create_user_command("PrayerTest", function(params)
	local raw = vim.trim(params.args or "")
	local pieces = {}
	if raw ~= "" then
		pieces = vim.split(raw, "\\s+", { trimempty = true })
	end
	local payload = {
		prayer = (pieces[1] and pieces[1] ~= "" and pieces[1]) or "Test",
		time = (pieces[2] and pieces[2] ~= "" and pieces[2]) or os.date("%H:%M"),
	}
	local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
		pattern = "PrayertimeAdhan",
		modeline = false,
		data = payload,
	})
	if not ok then
		notify(("prayertime: failed to fire PrayertimeAdhan: %s"):format(err), vim.log.levels.ERROR)
		return
	end
	notify(("prayertime: fired PrayertimeAdhan for %s at %s"):format(payload.prayer, payload.time), vim.log.levels.INFO)
end, {
	desc = "Trigger PrayertimeAdhan manually for testing",
	nargs = "*",
})

function M.show_today(opts)
	opts = opts or {}
	local lines = build_today_lines()
	if not lines then
		notify("prayertime: no cached schedule yet", vim.log.levels.WARN)
		return
	end
	local mode = opts.mode or "float"
	if type(mode) == "string" then
		mode = mode:lower()
	end
	if mode ~= "float" then
		close_today_display()
	end
	if mode == "notify" then
		local title = lines[1]
		local body_lines = {}
		for i = 2, #lines do
			table.insert(body_lines, lines[i])
		end
		local body = table.concat(body_lines, "\n")
		notify(body, vim.log.levels.INFO, { title = title })
	elseif mode == "float" then
		open_today_float(lines, opts)
	else
		notify("prayertime: unknown display mode (use 'float' or 'notify')", vim.log.levels.WARN)
	end
end

vim.api.nvim_create_user_command("PrayerToday", function(params)
	local mode = vim.trim(params.args or "")
	if mode == "" then
		mode = "float"
	end
	M.show_today({ mode = mode })
end, {
	desc = "Show today's prayer times",
	nargs = "?",
	complete = function()
		return { "float", "notify" }
	end,
})

ensure_timer()
vim.schedule(function()
	call_active("fetch_times")
end)

return M
