-- test/ci_runner.lua
-- Runs tests via plenary.test_harness (test-only dependency; not needed at runtime)
-- and writes a minimal JUnit report for CI visibility.

local ok, harness = pcall(require, "plenary.test_harness")
if not ok then
	vim.api.nvim_err_writeln("plenary.nvim not found on runtimepath (test dependency)")
	vim.cmd("cq")
end

local function write_junit(path, failed)
	local f = assert(io.open(path, "w"))
	local tests = 1
	local failures = failed and 1 or 0
	f:write('<?xml version="1.0" encoding="UTF-8"?>\n')
	f:write(string.format('<testsuite name="prayertime" tests="%d" failures="%d">\n', tests, failures))
	f:write('  <testcase classname="prayertime" name="test-suite">\n')
	if failed then
		f:write('    <failure message="Tests failed">See workflow logs for details</failure>\n')
	end
	f:write("  </testcase>\n")
	f:write("</testsuite>\n")
	f:close()
end

-- Monkeypatch vim.cmd to capture plenary's exit
local original_cmd = vim.cmd
vim.cmd = function(cmd)
	if cmd == "0cq" then
		write_junit("test-results/junit.xml", false)
		original_cmd("0cq")
	elseif cmd == "1cq" then
		write_junit("test-results/junit.xml", true)
		original_cmd("1cq")
	else
		return original_cmd(cmd)
	end
end

-- Run directory
harness.test_directory("test", { minimal_init = "test/minimal_init.lua" })
