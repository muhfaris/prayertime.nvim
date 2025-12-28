-- test/ci_runner.lua
-- Runs plenary tests and writes a very small JUnit report.
-- Not perfect, but good enough for CI visibility.

local ok, harness = pcall(require, "plenary.test_harness")
if not ok then
	vim.api.nvim_err_writeln("plenary not found on runtimepath")
	vim.cmd("cq")
end

local results = {
	tests = 0,
	failures = 0,
	cases = {},
}

-- Monkeypatch busted's `it` to collect failures is messy.
-- So we run the suite and rely on exit code for pass/fail,
-- and only produce a minimal report with pass/fail totals.
-- If you want per-test cases, you’ll need deeper busted hooks.

local function write_junit(path, failed)
	local f = assert(io.open(path, "w"))
	local tests = 1
	local failures = failed and 1 or 0
	f:write('<?xml version="1.0" encoding="UTF-8"?>\n')
	f:write(string.format('<testsuite name="plenary" tests="%d" failures="%d">\n', tests, failures))
	f:write('  <testcase classname="plenary" name="test-suite">\n')
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
