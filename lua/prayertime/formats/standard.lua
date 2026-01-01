local util = require("prayertime.util")
local M = {}

local defaults = {
	city = "Jakarta",
	country = "Indonesia",
	method = 2,
	duha_offset_minutes = 15,
	prayers = {
		Fajr = true,
		Dhuhr = true,
		Asr = true,
		Maghrib = true,
		Isha = true,
	},
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

local curl_client = nil
local cache_dir = vim.fn.stdpath("cache") .. "/prayertime"
local cache_file = cache_dir .. "/schedule.json"
local MAX_FETCH_ATTEMPTS = 3
local RETRY_DELAY_MS = 1000
local load_cache
local lock = require("prayertime.lock")
local state_dir = vim.fn.stdpath("state")
local lock_path = state_dir .. "/prayertime.lock"
local lock_ttl = 6 -- seconds
local lock_warning_emitted = false

pcall(vim.fn.mkdir, state_dir, "p")
-- on lock init
lock.start_heartbeat({ lock_path = lock_path, ttl = lock_ttl })

local function clone_table(value)
	if value == nil then
		return nil
	end
	return vim.tbl_deep_extend("force", {}, value)
end

local function merge_prayers(base, overrides)
	if type(base) ~= "table" then
		base = {}
	end
	if type(overrides) ~= "table" then
		return base
	end
	for name, enabled in pairs(overrides) do
		if type(name) == "string" then
			base[name] = not not enabled
		end
	end
	return base
end

local function prayers_signature(prayers)
	if type(prayers) ~= "table" then
		return ""
	end
	local pieces = {}
	for name, enabled in pairs(prayers) do
		table.insert(pieces, ("%s=%s"):format(name, enabled and "1" or "0"))
	end
	table.sort(pieces)
	return table.concat(pieces, ",")
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
		prayers_signature(cfg.prayers or defaults.prayers),
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
	local ok, leader = pcall(lock.try_acquire, { lock_path = lock_path, ttl = lock_ttl })
	if not ok then
		if not lock_warning_emitted then
			warn("prayertime: shared lock unavailable; duplicate adhans may occur")
			lock_warning_emitted = true
		end
		leader = true
	end

	-- Only leader emits the user event (so only one session triggers user's autocmd)
	if not leader then
		return
	end

	local prayers = config.prayers or defaults.prayers or {}

	vim.schedule(function()
		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = "PrayertimeAdhan",
			modeline = false,
			data = { prayer = name, time = time, prayers = prayers or {} },
		})
	end)
end

local function get_curl()
	if curl_client then
		return curl_client
	end
	local ok, mod = pcall(require, "plenary.curl")
	if not ok then
		warn("prayertime: plenary.curl not available; install nvim-lua/plenary.nvim")
		return nil
	end
	curl_client = mod
	return curl_client
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

	new.prayers = merge_prayers(clone_table(defaults.prayers), opts.prayers)

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

local function request_url()
	local date = os.date("%d-%m-%Y")
	return string.format(
		"http://api.aladhan.com/v1/timingsByCity/%s?city=%s&country=%s&method=%s",
		vim.fn.escape(date, " "),
		vim.fn.escape(config.city or "Jakarta", " "),
		vim.fn.escape(config.country or "Indonesia", " "),
		config.method or 2
	)
end

function M.setup(opts)
	apply_config(opts)
	M.fetch_times()
end

function M.fetch_times()
	local curl = get_curl()
	if not curl then
		return
	end
	local url = request_url()
	local function attempt_fetch(attempt)
		curl.get(url, {
			callback = vim.schedule_wrap(function(res)
				local status = res and tonumber(res.status) or nil
				local body = res and res.body or nil
				if not status or status < 200 or status >= 400 or not body or body == "" then
					if attempt >= MAX_FETCH_ATTEMPTS then
						notify(
							("prayertime: failed to fetch schedule after %d attempts"):format(MAX_FETCH_ATTEMPTS),
							vim.log.levels.ERROR
						)
						return
					end
					vim.defer_fn(function()
						attempt_fetch(attempt + 1)
					end, RETRY_DELAY_MS)
					return
				end

				local ok, data = pcall(vim.json.decode, body)
				if not ok or not data or not data.data or not data.data.timings then
					if attempt >= MAX_FETCH_ATTEMPTS then
						notify("prayertime: failed to decode prayer times", vim.log.levels.ERROR)
						return
					end
					vim.defer_fn(function()
						attempt_fetch(attempt + 1)
					end, RETRY_DELAY_MS)
					return
				end

				last_payload = data
				last_updated = os.time()
				prayer_times = clone_table(data.data.timings or {}) or {}
				compute_derived_times()
				save_cache()
			end),
		})
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
