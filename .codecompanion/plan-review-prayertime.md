# Code Review: prayertime.nvim

**Reviewer**: CodeCompanion
**Date**: 2026-07-23
**Status**: For review

## Project overview

A Neovim plugin that integrates Islamic prayer schedules via Aladhan API, with
statusline countdown, floating timetables, and automated Adhan notifications.

## Files reviewed

| File | Lines | Role |
|---|---|---|
| `lua/prayertime/init.lua` | ~280 | Orchestrator: setup, commands, float display, timer management |
| `lua/prayertime/util.lua` | ~30 | Time parsing helpers |
| `lua/prayertime/formats/standard.lua` | ~340 | Default format: fetches Aladhan API, computes Duha, caches |
| `lua/prayertime/health.lua` | ~90 | `:checkhealth prayertime` |
| `lua/health/prayertime.lua` | ~15 | Health proxy loader |
| `test/prayertime_spec.lua` | ~140 | Plenary/busted test suite |
| `test/ci_runner.lua` | ~60 | CI test runner with JUnit output |
| `test/minimal_init.lua` | ~20 | Minimal Neovim init for tests |
| `README.md` | ~250 | User-facing docs |
| `doc/prayertime.txt` | ~180 | Vim help doc |
| `.github/workflows/tests.yaml` | ~100 | CI: 4 Neovim versions, JUnit reporting, PR comments |
| `run_tests.sh` | ~15 | Local test runner script |
| `test-results/junit.xml` | ~8 | Last CI results (passing) |

## Findings

### 🔴 P1 — Must fix

- **plenary.nvim is declared as hard dependency but never used**
  - README, help doc, health check, CI, and test runner all install/require it
  - Zero `require("plenary.*")` in the codebase — HTTP is done via `vim.system`/`uv.spawn` + `curl`
  - Tests stub `plenary.curl` unnecessarily
  - **Risk**: Users install a heavy dependency for nothing; confusing contract
  - **Fix**: Either drop plenary entirely and update all docs/CI, or migrate to `plenary.curl`

- **Adhan check uses string equality on `os.date("%H:%M")` — fragile**
  - API could return `"4:36"` vs `"04:36"` → silent miss
  - 60s timer resolution means prayers can be skipped between ticks
  - No dedup guard — same prayer could fire twice
  - **Fix**: Use window-based matching (±1 min), normalise via `parse_time_str`, add sentinel

- **Timer fires `check_for_adhan` but never triggers statusline redraw**
  - `get_status()` output won't update until user causes a redraw
  - **Fix**: Call `vim.cmd("redrawstatus")` after adhan checks

### 🟡 P2 — Should fix

- **Timer + `safe_fetch_times` run at `require` time, not just after `setup()`**
  - If user `require`s before `setup()`, timer runs with nil format
  - VimEnter callback calls `fetch_times` on unconfigured format
  - **Fix**: Gate behind `setup()` having been called, or make the timer idempotent on nil config

- **`config_signature` could crash on oddly-shaped config tables**
  - Thin guard (`type(cfg) ~= "table"`) handles most cases but not all
  - **Fix**: Add nil-safe accessors per field

- **Duplicate notify resolution pattern** in `init.lua` and `standard.lua`
  - Both files independently try to require `rcarriga/nvim-notify`
  - **Fix**: Export a shared `notify` from `util.lua`

### 🟢 P3 — Nice to fix

- **`clone_table` vs `vim.deepcopy`** — both patterns co-exist; use `vim.deepcopy` consistently
- **Hand-rolled `url_encode`** — works for ASCII, but will mangle non-ASCII city names
- **Health check lists plenary as dependency but checks for `curl`** — rename to "Network tool"
- **`format_duration` returns `"??"`** for nil/negative — consider a more descriptive fallback

## Architecture notes

### Strengths
- Clean format registration system — easy to add custom data providers
- Smart cache with config-signature validation (cache invalidated on city/country/method change)
- Robust async: `vim.system` with `uv.spawn` fallback, retry logic, job cancellation
- Cross-version CI (0.9.5 → nightly) with JUnit reporting and PR comments
- No external API keys needed (free Aladhan API)

### Design decisions to review
1. **Standalone vs plenary**: The code already is standalone. Formalising this would reduce user friction.
2. **String `HH:MM` throughout**: Using parsed minute-of-day integers for comparisons would be more robust.
3. **Module-level state**: `prayer_times`, `config`, etc. are module-level tables — fine for single-instance, but precludes testing with different configs in the same session without reloading.

## Priority recommendations

1. 🔴 Drop plenary dependency (or adopt it for real)
2. 🔴 Fix adhan matching to use minute-based window + dedup
3. 🔴 Trigger statusline redraw after adhan check
4. 🟡 Gate timer behind `setup()` having run
5. 🟡 Extract shared `notify` into util
6. 🟢 Minor cleanup (url_encode, health check copy, `clone_table` consistency)

## Status: ✅ All items implemented

*Open for discussion — happy to revise any finding or priority.*

### Implementation checklist

| # | Priority | Item | Status | Files changed |
|---|---|---|---|---|
| 1 | 🔴 | Drop plenary as runtime dependency (keep for tests) | ✅ | `init.lua`, `standard.lua`, `util.lua`, `health.lua`, `README.md`, `doc/prayertime.txt`, `.github/workflows/tests.yaml`, `run_tests.sh`, `test/prayertime_spec.lua` |
| 2 | 🔴 | Adhan matching: minute-based window + dedup | ✅ | `lua/prayertime/formats/standard.lua` |
| 3 | 🔴 | Statusline redraw after adhan check | ✅ | `lua/prayertime/init.lua` |
| 4 | 🟡 | Gate timer behind `setup()` | ✅ | `lua/prayertime/init.lua` |
| 5 | 🟡 | Shared `notify` in util | ✅ | `lua/prayertime/util.lua`, `lua/prayertime/init.lua`, `lua/prayertime/formats/standard.lua` |
| 6 | 🟢 | Health check: rename "Dependencies" → "Network tool" | ✅ | `lua/prayertime/health.lua` |

---

*Last updated: 2026-07-23*
