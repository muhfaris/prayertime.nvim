local M = {}

local health = vim.health or require("health")
local reporter = {
	start = health.start or health.report_start,
	ok = health.ok or health.report_ok,
	warn = health.warn or health.report_warn,
	info = health.info or health.report_info,
	error = health.error or health.report_error,
}

local function report(method, msg)
	if reporter[method] then
		reporter[method](msg)
	end
end

local function check_neovim()
	report("start", "Environment")
	if vim.fn.has("nvim-0.9") == 1 then
		report("ok", "Neovim >= 0.9 detected")
	else
		report("warn", "Neovim 0.9+ required for vim.json and timers")
	end
end

local function check_plenary()
	report("start", "Dependencies")
	if pcall(require, "plenary.curl") then
		report("ok", "plenary.curl available")
	else
		report("error", "Missing dependency: nvim-lua/plenary.nvim (plenary.curl not found)")
	end
end

local function check_notify()
	if pcall(require, "notify") then
		report("ok", "rcarriga/nvim-notify detected (optional)")
	else
		report("info", "rcarriga/nvim-notify not found; falling back to vim.notify")
	end
end

local function request_url(cfg)
	local date = os.date("%d-%m-%Y")
	return string.format(
		"http://api.aladhan.com/v1/timingsByCity/%s?city=%s&country=%s&method=%s",
		vim.fn.escape(date, " "),
		vim.fn.escape(cfg.city or "Jakarta", " "),
		vim.fn.escape(cfg.country or "Indonesia", " "),
		cfg.method or 2
	)
end

local function check_api()
	local ok, curl = pcall(require, "plenary.curl")
	if not ok then
		report("warn", "Skipping API test because plenary.curl is unavailable")
		return
	end

	local ok_std, standard = pcall(require, "prayertime.formats.standard")
	local cfg = ok_std and standard.get_config and standard.get_config() or nil
	cfg = cfg or (ok_std and standard.defaults) or { city = "Jakarta", country = "Indonesia", method = 2 }

	local url = request_url(cfg)
	local success, res = pcall(curl.get, url, { timeout = 3000 })
	if not success then
		report("warn", "Prayer times API request failed: " .. tostring(res))
		return
	end
	if not res then
		report("warn", "Prayer times API returned no response body")
		return
	end
	local status = tonumber(res.status)
	if status and status >= 200 and status < 400 then
		report("ok", "Prayer times API reachable (" .. status .. ")")
		return
	end
	report("warn", "Prayer times API returned status " .. tostring(res.status))
end

function M.check()
	check_neovim()
	check_plenary()
	check_notify()
	check_api()
end

return M
