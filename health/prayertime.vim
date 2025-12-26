lua <<'EOF'
local ok, mod = pcall(require, "prayertime.health")
if not ok then
  local health = vim.health or require("health")
  local reporter = health.error or health.report_error
  if reporter then
    reporter("Failed to load prayertime.health: " .. tostring(mod))
  end
  return
end
if type(mod.check) == "function" then
  mod.check()
end
EOF
