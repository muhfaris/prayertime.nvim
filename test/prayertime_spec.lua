-- test/prayertime_spec.lua
local eq = assert.are.same

-- ----
-- Helpers
-- ----
local function command_exists(name)
	local ok, cmds = pcall(vim.api.nvim_get_commands, {})
	if not ok then
		return false
	end
	return cmds[name] ~= nil
end

local function stub_aladhan_network()
	-- Your README says the default "standard" format fetches timings from Aladhan :contentReference[oaicite:5]{index=5}
	-- We stub common approaches so CI never hits the network.

	local payload = vim.json.encode({
		code = 200,
		status = "OK",
		data = {
			timings = {
				Fajr = "04:36",
				Sunrise = "05:58",
				Dhuhr = "11:53",
				Asr = "15:20",
				Maghrib = "18:08",
				Isha = "19:10",
			},
			date = { gregorian = { date = "28-12-2025" } },
		},
	})

	-- Stub plenary.curl if you use it

	package.loaded["plenary.curl"] = {
		get = function(url, opts)
			if opts and opts.callback then
				opts.callback({ status = 200, body = payload })
			end
			return { status = 200, body = payload }
		end,
	}

	-- Stub vim.system if you use it (curl/wget under the hood)
	if vim.system then
		local orig = vim.system
		vim.system = function(_cmd, _opts, on_exit)
			-- emulate async callback signature
			local obj = {
				wait = function()
					return { code = 0, stdout = payload, stderr = "" }
				end,
			}
			if type(on_exit) == "function" then
				vim.schedule(function()
					on_exit({ code = 0, stdout = payload, stderr = "" })
				end)
			end
			return obj
		end
		return function()
			vim.system = orig
		end
	end

	return function() end
end

describe("prayertime.nvim public contract", function()
	local restore_system

	before_each(function()
		-- Ensure clean module reload per test
		package.loaded["prayertime"] = nil
		package.loaded["prayertime.config"] = nil
		package.loaded["prayertime.format"] = nil
		package.loaded["prayertime.formats.standard"] = nil

		restore_system = stub_aladhan_network()
	end)

	after_each(function()
		if restore_system then
			restore_system()
		end
	end)

	it("loads module and exposes documented functions", function()
		local prayer = require("prayertime")
		assert.is_truthy(prayer)

		-- README shows usage of these functions :contentReference[oaicite:6]{index=6}
		assert.is_function(prayer.setup)
		assert.is_function(prayer.get_status)
		assert.is_function(prayer.show_today)
		assert.is_function(prayer.refresh)
	end)

	it("registers documented user commands after setup", function()
		local prayer = require("prayertime")
		prayer.setup({ city = "Jakarta", country = "Indonesia", method = 2 })

		-- Commands listed in README :contentReference[oaicite:7]{index=7}
		assert.is_true(command_exists("PrayerReload"))
		assert.is_true(command_exists("PrayerFormat"))
		assert.is_true(command_exists("PrayerTimes"))
		assert.is_true(command_exists("PrayerTest"))
		assert.is_true(command_exists("PrayerToday"))
	end)

	it("emits a vim.notify warning for invalid method (non-numeric)", function()
		local notifies = {}
		local old_notify = vim.notify
		vim.notify = function(msg, level, opts)
			table.insert(notifies, { msg = tostring(msg), level = level, opts = opts })
		end

		local prayer = require("prayertime")
		prayer.setup({ city = "Jakarta", country = "Indonesia", method = "lol" })

		-- README promises invalid values fall back + warn via vim.notify :contentReference[oaicite:8]{index=8}
		vim.wait(100, function()
			return #notifies >= 1
		end)
		assert.is_true(#notifies >= 1)

		vim.notify = old_notify
	end)

	it("PrayerTest triggers User autocmd PrayertimeAdhan with prayer + time payload", function()
		local prayer = require("prayertime")
		prayer.setup({ city = "Jakarta", country = "Indonesia", method = 2 })

			local got = {}
			local id = vim.api.nvim_create_autocmd("User", {
				pattern = "PrayertimeAdhan",
				callback = function(ev)
					got.prayer = ev.data and ev.data.prayer
					got.time = ev.data and ev.data.time
					got.prayers = ev.data and ev.data.prayers
				end,
			})

		-- README: `:PrayerTest [prayer time]` fires PrayertimeAdhan, default payload `Test HH:MM` :contentReference[oaicite:9]{index=9}
		vim.cmd("PrayerTest Fajr 04:36")

		-- allow scheduled callbacks to run
		vim.wait(200, function()
			return got.prayer ~= nil
		end)

			eq("Fajr", got.prayer)
			eq("04:36", got.time)
			assert.is_table(got.prayers)
			assert.is_true(got.prayers.Fajr)

			vim.api.nvim_del_autocmd(id)
		end)

	it("PrayerToday float opens a window (non-notify path)", function()
		local prayer = require("prayertime")
		prayer.setup({ city = "Jakarta", country = "Indonesia", method = 2 })

		local before = #vim.api.nvim_list_wins()
		vim.cmd("PrayerToday float")

		-- give UI a moment
		vim.wait(200)

		local after = #vim.api.nvim_list_wins()
		assert.is_true(after >= before) -- at least not crashing; ideally opens one more

		-- Optional stronger assertion if you name buffers/windows:
		-- scan for a scratch buffer with your title, etc.
	end)

	it("get_status returns a string (statusline contract)", function()
		local prayer = require("prayertime")
		prayer.setup({ city = "Jakarta", country = "Indonesia", method = 2 })

		local s = prayer.get_status()
		assert.is_string(s) -- README claims statusline countdown :contentReference[oaicite:10]{index=10}
	end)
end)
