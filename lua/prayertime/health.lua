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

local function check_dependencies()
	report("start", "Dependencies")
	if vim.fn.executable("curl") == 1 then
		report("ok", "curl executable available")
	else
		report("error", "curl executable not found in PATH")
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
	if vim.fn.executable("curl") ~= 1 then
		report("warn", "Skipping API test because curl is unavailable")
		return
	end

	local ok_std, standard = pcall(require, "prayertime.formats.standard")
	local cfg = ok_std and standard.get_config and standard.get_config() or nil
	cfg = cfg or (ok_std and standard.defaults) or { city = "Jakarta", country = "Indonesia", method = 2 }

	local url = request_url(cfg)
	local success, obj = pcall(function()
		if vim.system then
			return vim.system(
				{ "curl", "-sSL", "-w", "%{http_code}", "-o", "/dev/null", "-m", "3", url },
				{ text = true }
			):wait(3000)
		else
			local res = vim.fn.system({ "curl", "-sSL", "-w", "%{http_code}", "-o", "/dev/null", "-m", "3", url })
			return { stdout = res, code = vim.v.shell_error }
		end
	end)

	if not success or not obj then
		report("warn", "Prayer times API request failed: " .. tostring(obj))
		return
	end

	local status = tonumber(obj.stdout)
	if status and status >= 200 and status < 400 then
		report("ok", "Prayer times API reachable (" .. status .. ")")
		return
	end
	report("warn", "Prayer times API returned status " .. tostring(status or obj.code))
end

function M.check()
	check_neovim()
	check_dependencies()
	check_notify()
	check_api()
end

return M
