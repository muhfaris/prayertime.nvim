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

local curl_client = nil

local function time_to_minutes(value)
  if type(value) ~= "string" then
    return nil
  end
  local hour_str, minute_str = value:match("^(%d%d?):(%d%d)$")
  if not hour_str then
    return nil
  end
  local hour = tonumber(hour_str)
  local minute = tonumber(minute_str)
  if not hour or not minute then
    return nil
  end
  if hour < 0 or hour > 23 or minute < 0 or minute > 59 then
    return nil
  end
  return hour * 60 + minute
end

local function minutes_to_time(total)
  total = total % (24 * 60)
  local hours = math.floor(total / 60)
  local minutes = total % 60
  return ("%02d:%02d"):format(hours, minutes)
end

local function clone_table(value)
  if value == nil then
    return nil
  end
  return vim.tbl_deep_extend("force", {}, value)
end

local function warn(msg)
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.WARN)
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
end

local function compute_derived_times()
  local derived = clone_table(prayer_times)
  derived_ranges = {}
  local sunrise_minutes = time_to_minutes(prayer_times.Sunrise)
  local dhuhr_minutes = time_to_minutes(prayer_times.Dhuhr)

  if sunrise_minutes and dhuhr_minutes and dhuhr_minutes > sunrise_minutes then
    local offset = tonumber(config.duha_offset_minutes) or defaults.duha_offset_minutes
    offset = math.max(0, offset)
    local start_minutes = sunrise_minutes + offset
    if start_minutes < dhuhr_minutes then
      local duha_start = minutes_to_time(start_minutes)
      local duha_finish = minutes_to_time(dhuhr_minutes)
      derived.Duha = duha_start
      derived_ranges.Duha = {
        start = duha_start,
        finish = duha_finish,
      }
    end
  end

  derived_times = derived
end

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
  curl.get(url, {
    callback = vim.schedule_wrap(function(res)
      local ok, data = pcall(vim.json.decode, res.body or "")
      if not ok or not data or not data.data or not data.data.timings then
        vim.notify("Failed to decode prayer times", vim.log.levels.ERROR)
        return
      end
      last_payload = data
      last_updated = os.time()
      prayer_times = data.data.timings or {}
      compute_derived_times()
    end),
  })
end

function M.get_status()
  if next(prayer_times) == nil then
    return "Loading..."
  end

  local now_minutes = time_to_minutes(os.date("%H:%M"))
  local duha_range = derived_ranges.Duha
  if duha_range and duha_range.start and now_minutes then
    local duha_start = time_to_minutes(duha_range.start)
    local duha_end = time_to_minutes(duha_range.finish or prayer_times.Dhuhr)
    if duha_start and now_minutes >= duha_start then
      if not duha_end or now_minutes < duha_end then
        if duha_range.finish then
          return ("Duha %s-%s"):format(duha_range.start, duha_range.finish)
        else
          return ("Duha since %s"):format(duha_range.start)
        end
      end
    end
  end

  local next_name, next_time = nil, nil

  for _, name in ipairs(prayer_order) do
    local time = derived_times[name] or prayer_times[name]
    if time then
      local minutes = time_to_minutes(time)
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
      notify("It is time for " .. name, "info", { title = "Prayer Alert" })
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
