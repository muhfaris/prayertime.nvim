local uv = vim.uv or vim.loop
local util = require("prayertime.util")
local M = {}

local defaults = {
	city = "Jakarta",
	country = "Indonesia",
	method = 2,
	duha_offset_minutes = 15,
}

M.defaults = vim.deepcopy(defaults)

local config = vim.deepcopy(defaults)

local prayer_times = {}
local derived_times = {}
local derived_ranges = {}
local last_payload = nil
local last_updated = nil

local prayer_order = {
	"Fajr",
	"Sunrise",
	"Duha",
	"Dhuhr",
	"Asr",
	"Maghrib",
	"Isha",
}

local notify = vim.notify
do
	local ok, plugin = pcall(require, "notify")
	if ok then
		notify = plugin
	end
end


local cache_dir = vim.fn.stdpath("cache") .. "/prayertime"
local cache_file = cache_dir .. "/schedule.json"
local MAX_FETCH_ATTEMPTS = 3
local RETRY_DELAY_MS = 1000
local active_fetch_job = nil
local active_retry_timer = nil
local load_cache

local function clone_table(value)
	if value == nil then
		return nil
	end
	return vim.tbl_deep_extend("force", {}, value)
end

local function config_signature(cfg)
	if type(cfg) ~= "table" then
		return ""
	end
	return table.concat({
		cfg.city or defaults.city,
		cfg.country or defaults.country,
		tostring(cfg.method or defaults.method),
		tostring(cfg.duha_offset_minutes or defaults.duha_offset_minutes),
	}, "::")
end

local function ensure_cache_dir()
	local stat = vim.loop.fs_stat(cache_dir)
	if stat and stat.type == "directory" then
		return true
	end
	local ok, result = pcall(vim.fn.mkdir, cache_dir, "p")
	return ok and result ~= 0
end

local function save_cache()
	if vim.tbl_isempty(prayer_times) then
		return
	end
	local payload = {
		config = clone_table(config),
		prayer_times = clone_table(prayer_times),
		last_payload = clone_table(last_payload),
		last_updated = last_updated,
	}
	local ok, encoded = pcall(vim.json.encode, payload)
	if not ok or not encoded then
		return
	end
	if not ensure_cache_dir() then
		return
	end
	pcall(vim.fn.writefile, { encoded }, cache_file)
end

local function warn(msg)
	vim.schedule(function()
		vim.notify(msg, vim.log.levels.WARN)
	end)
end

local function emit_adhan_event(name, time)
	vim.schedule(function()
		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = "PrayertimeAdhan",
			modeline = false,
			data = { prayer = name, time = time },
		})
	end)
end



local function apply_config(opts)
	opts = opts or {}
	local new = clone_table(defaults)
	local previous_signature = config_signature(config)

	if opts.city == nil then
	-- keep default
	elseif type(opts.city) == "string" and opts.city ~= "" then
		new.city = opts.city
	else
		warn("prayertime: invalid city; keeping default")
	end

	if opts.country == nil then
	-- keep default
	elseif type(opts.country) == "string" and opts.country ~= "" then
		new.country = opts.country
	else
		warn("prayertime: invalid country; keeping default")
	end

	local num_method = tonumber(opts.method)
	if num_method and num_method >= 0 then
		new.method = math.floor(num_method)
	elseif opts.method ~= nil then
		warn("prayertime: method must be numeric; keeping default")
	end

	local offset = tonumber(opts.duha_offset_minutes)
	if offset and offset >= 0 and offset <= 180 then
		new.duha_offset_minutes = offset
	elseif opts.duha_offset_minutes ~= nil then
		warn("prayertime: duha_offset_minutes must be between 0 and 180")
	end

	config = new
	local new_signature = config_signature(config)
	if new_signature ~= previous_signature then
		prayer_times = {}
		derived_times = {}
		derived_ranges = {}
		last_payload = nil
		last_updated = nil
	end
	if load_cache then
		load_cache()
	end
end

local function compute_derived_times()
	local derived = clone_table(prayer_times)
	derived_ranges = {}
	local sunrise_minutes = util.parse_time_str(prayer_times.Sunrise)
	local dhuhr_minutes = util.parse_time_str(prayer_times.Dhuhr)

	if sunrise_minutes and dhuhr_minutes and dhuhr_minutes > sunrise_minutes then
		local offset = tonumber(config.duha_offset_minutes) or defaults.duha_offset_minutes
		offset = math.max(0, offset)
			local start_minutes = sunrise_minutes + offset
			if start_minutes < dhuhr_minutes then
				local duha_start = util.minutes_to_time(start_minutes)
				local duha_finish = util.minutes_to_time(dhuhr_minutes)
			derived.Duha = duha_start
			derived_ranges.Duha = {
				start = duha_start,
				finish = duha_finish,
			}
		end
	end

	derived_times = derived
end

load_cache = function()
	local ok, lines = pcall(vim.fn.readfile, cache_file)
	if not ok or not lines or vim.tbl_isempty(lines) then
		return false
	end
	local content = table.concat(lines, "\n")
	local decoded_ok, data = pcall(vim.json.decode, content)
	if not decoded_ok or type(data) ~= "table" then
		return false
	end
	if config_signature(data.config or {}) ~= config_signature(config) then
		return false
	end
	if type(data.prayer_times) == "table" then
		prayer_times = clone_table(data.prayer_times) or {}
		compute_derived_times()
	end
	last_payload = clone_table(data.last_payload)
	last_updated = data.last_updated
	return true
end

load_cache()

local function url_encode(str)
	if not str then
		return ""
	end
	str = tostring(str)
	str = str:gsub("([^%w%.%-%_])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	return str
end

local function request_url()
	local date = os.date("%d-%m-%Y")
	return string.format(
		"http://api.aladhan.com/v1/timingsByCity/%s?city=%s&country=%s&method=%s",
		url_encode(date),
		url_encode(config.city or "Jakarta"),
		url_encode(config.country or "Indonesia"),
		url_encode(config.method or 2)
	)
end

local function run_async_curl(url, callback)
	if vim.system then
		local job
		job = vim.system(
			{ "curl", "-sSL", "-m", "10", "--connect-timeout", "5", url },
			{ text = true },
			vim.schedule_wrap(function(obj)
				callback(job, obj.code, obj.stdout)
			end)
		)
		return job
	else
		local stdout = uv.new_pipe(false)
		local stderr = uv.new_pipe(false)
		local stdin = uv.new_pipe(false) -- dummy stdin pipe to decouple TTY
		local stdout_data = {}

		local handle
		handle = uv.spawn("curl", {
			args = { "-sSL", "-m", "10", "--connect-timeout", "5", url },
			stdio = { stdin, stdout, stderr },
			detached = true,
		}, vim.schedule_wrap(function(code, signal)
			if handle and not handle:is_closing() then handle:close() end
			if stdin and not stdin:is_closing() then stdin:close() end
			if stdout and not stdout:is_closing() then stdout:close() end
			if stderr and not stderr:is_closing() then stderr:close() end

			if signal and signal ~= 0 then
				callback(handle, -1, nil)
				return
			end
			local stdout_str = table.concat(stdout_data)
			callback(handle, code, stdout_str)
		end))

		if not handle then
			if stdin and not stdin:is_closing() then stdin:close() end
			if stdout and not stdout:is_closing() then stdout:close() end
			if stderr and not stderr:is_closing() then stderr:close() end
			return nil
		end

		uv.read_start(stdout, function(err, data)
			if data then
				table.insert(stdout_data, data)
			end
		end)
		uv.read_start(stderr, function(err, data) end)

		return handle
	end
end

function M.setup(opts)
	apply_config(opts)
end

function M.fetch_times(force)
	if vim.fn.executable("curl") ~= 1 then
		warn("prayertime: curl command not found in PATH")
		return
	end

	-- Cancel any active job
	if active_fetch_job then
		if type(active_fetch_job.is_closing) == "function" and not active_fetch_job:is_closing() then
			pcall(active_fetch_job.kill, active_fetch_job, 15)
		end
		active_fetch_job = nil
	end

	-- Stop any active retry timer
	if active_retry_timer then
		pcall(vim.fn.timer_stop, active_retry_timer)
		active_retry_timer = nil
	end

	-- Smart caching validation: check if cache is valid for today (unless forced)
	if not force and last_updated and not vim.tbl_isempty(prayer_times) then
		local cached_date = os.date("%d-%m-%Y", last_updated)
		local today_date = os.date("%d-%m-%Y")
		if cached_date == today_date then
			return
		end
	end

	local url = request_url()

	local attempt_fetch

	local function fetch_done(attempt, ok, data)
		if ok and data then
			last_payload = data
			last_updated = os.time()
			prayer_times = clone_table(data.data.timings or {}) or {}
			compute_derived_times()
			save_cache()
			return
		end
		if attempt >= MAX_FETCH_ATTEMPTS then
			notify(
				("prayertime: failed to fetch schedule after %d attempts"):format(MAX_FETCH_ATTEMPTS),
				vim.log.levels.ERROR
			)
			return
		end
		active_retry_timer = vim.fn.timer_start(RETRY_DELAY_MS, function()
			active_retry_timer = nil
			attempt_fetch(attempt + 1)
		end)
	end

	attempt_fetch = function(attempt)
		local job
		job = run_async_curl(url, function(active_job, code, stdout_str)
			if active_fetch_job ~= active_job then
				return
			end
			active_fetch_job = nil

			if code ~= 0 or not stdout_str or stdout_str == "" then
				fetch_done(attempt, false, nil)
				return
			end

			local ok, data = pcall(vim.json.decode, stdout_str)
			if not ok or not data or not data.data or not data.data.timings then
				fetch_done(attempt, false, nil)
				return
			end

			fetch_done(attempt, true, data)
		end)

		if not job then
			fetch_done(attempt, false, nil)
			return
		end

		active_fetch_job = job
	end

	attempt_fetch(1)
end

function M.get_status()
	if next(prayer_times) == nil then
		return "Loading..."
	end

	local now_minutes = util.parse_time_str(os.date("%H:%M"))
	local duha_range = derived_ranges.Duha
	if duha_range and duha_range.start and now_minutes then
			local duha_start = util.parse_time_str(duha_range.start)
			local duha_end = util.parse_time_str(duha_range.finish or prayer_times.Dhuhr)
		if duha_start and now_minutes >= duha_start then
			if not duha_end or now_minutes < duha_end then
				if duha_range.finish then
					return ("🕌 Duha %s-%s"):format(duha_range.start, duha_range.finish)
				else
					return ("🕌 Duha since %s"):format(duha_range.start)
				end
			end
		end
	end

	local next_name, next_time = nil, nil

	for _, name in ipairs(prayer_order) do
		local time = derived_times[name] or prayer_times[name]
		if time then
				local minutes = util.parse_time_str(time)
			if minutes and now_minutes and minutes >= now_minutes then
				next_name = name
				next_time = time
				break
			end
		end
	end

	if not next_name then
		for _, name in ipairs(prayer_order) do
			local time = derived_times[name] or prayer_times[name]
			if time then
				next_name = name
				next_time = time
				break
			end
		end
	end

	if next_name and next_time then
		if next_name == "Duha" and derived_ranges.Duha then
			local range = derived_ranges.Duha
			if range.start and range.finish then
				return ("🕌 Duha %s-%s"):format(range.start, range.finish)
			elseif range.start then
				return ("🕌 Duha starts at %s"):format(range.start)
			end
		end
		return ("🕌 %s at %s"):format(next_name, next_time)
	end

	return "Prayer times unavailable"
end

function M.check_for_adhan()
	local current_time = os.date("%H:%M")
	for name, time in pairs(derived_times) do
		if current_time == time then
			notify(
				("🕌 %s prayer is starting now (%s)"):format(name, time),
				vim.log.levels.INFO,
				{ title = "Prayer Reminder" }
			)
			emit_adhan_event(name, time)
		end
	end
end

function M.get_cached_payload()
	return clone_table(last_payload)
end

function M.get_prayer_times()
	return clone_table(prayer_times)
end

function M.get_derived_times()
	return clone_table(derived_times)
end

function M.get_derived_ranges()
	return clone_table(derived_ranges)
end

function M.get_config()
	return clone_table(config)
end

function M.get_last_updated()
	return last_updated
end

return M
