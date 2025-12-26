# 🕌 prayertime.nvim
---

prayertime.nvim is a lightweight, standalone Neovim plugin that integrates accurate Islamic prayer schedules directly into your workflow. Stay mindful with live statusline countdowns, floating timetables, and automated Adhan notifications without leaving your editor.

![Preview PrayerTime.Nvim](https://github.com/user-attachments/assets/c7471b94-5653-4275-94b6-462dc67489e2)

<table>
  <tr>
    <td align="center">
      <img src="https://github.com/user-attachments/assets/c7471b94-5653-4275-94b6-462dc67489e2" alt="Preview PrayerToday and Status Line" style="width: 200px;"/>
      <br />
      <em>Preview PrayerToday and Status Line</em>
    </td>
    <td align="center">
      <img src="https://github.com/user-attachments/assets/33f80afe-512a-45d8-96ae-310391246341" alt="Preview PrayerToday Notification" style="width: 200px;"/>
      <br />
      <em>Preview PrayerToday Notification</em>
    </td>
    <td align="center">
      <img src="https://github.com/user-attachments/assets/ce65bddd-fd3f-4701-8c7c-7b8db5c076c0" alt="Prayer Reminder" style="width: 200px;"/>
      <br />
      <em>Prayer Reminder</em>
    </td>
  </tr>
</table>


## ✨ Features
- *Live Statusline:* Real-time countdown to the next prayer.
- *Smart Caching:* Works offline by persisting the last successful fetch to disk.
- *Automated Alerts:* Hook into User autocommands to trigger custom notifications or scripts at prayer times.
- *Duha Support:* Automatically calculates the Duha window (Sunrise offset).
- *Extensible:* Register custom formats or data providers.

## 📋 Requirements
- Neovim 0.9+ (`vim.pack`, `vim.json`)
- [`nvim-lua/plenary.nvim`](https://github.com/nvim-lua/plenary.nvim)
- Optional: [`rcarriga/nvim-notify`](https://github.com/rcarriga/nvim-notify) for nicer alerts

## 🚀 Installation examples

### lazy.nvim
```lua
{
  "muhfaris/prayertime.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = { city = "Jakarta", country = "Indonesia", method = 2 },
}
```

### packer.nvim
```lua
use({
  "muhfaris/prayertime.nvim",
  requires = { "nvim-lua/plenary.nvim" },
  config = function()
    require("prayertime").setup({ city = "Jakarta" })
  end,
})
```

### vim-plug
```vim
Plug "nvim-lua/plenary.nvim"
Plug "muhfaris/prayertime.nvim"
lua << EOF
require("prayertime").setup({
  city = "Jakarta",
  country = "Indonesia",
})
EOF
```

## 🧪 Usage

### 🧱 Basic setup
```lua
local prayer = require("prayertime")

prayer.setup({
  city = "Jakarta",
  country = "Indonesia",
  method = 2,
})
```

### 🎚️ Lualine integration (optional)
You can surface the statusline string anywhere—here’s a Lualine example:

```lua
require("lualine").setup({
  sections = {
    lualine_y = { require("prayertime").get_status, "progress" },
  },
})
```

### ⌨️ Key mappings
Trigger your favorite commands quickly from normal mode:

```lua
vim.keymap.set("n", "<leader>pt", function()
  require("prayertime").show_today({ mode = "float" })
end, { desc = "PrayerTime: show today" })

vim.keymap.set("n", "<leader>pr", function()
  require("prayertime").refresh()
end, { desc = "PrayerTime: refresh schedule" })
```

The default `standard` format fetches timings from Aladhan, then calculates the Duha window (sunrise + offset until Dhuhr). You can register alternate formats and switch to them at runtime:

```lua
local prayer = require("prayertime")
prayer.register_format("custom", require("my_custom_format"))
prayer.use_format("custom", { city = "Medina" })
```

## ⚙️ Configuration

`require("prayertime").setup()` accepts:

| Option | Default | Notes |
| --- | --- | --- |
| `format` | `"standard"` | Which format module to load. |
| `city` | `"Jakarta"` | Must be a non-empty string. |
| `country` | `"Indonesia"` | Must be a non-empty string. |
| `method` | `2` | Numeric method ID per Aladhan’s API. Non-numeric values are ignored with a warning. |
| `duha_offset_minutes` | `15` | Minutes after sunrise before Duha begins (0-180). |

Invalid values fall back to the defaults and emit a `vim.notify` warning so mistakes are obvious.

### 🗺️ Method reference

The `method` option follows [Aladhan’s calculation methods](https://aladhan.com/prayer-times-api). Set the numeric identifier shown below:

| ID | Authority |
| --- | --- |
| 0 | Jafari / Shia Ithna-Ashari |
| 1 | University of Islamic Sciences, Karachi |
| 2 | Islamic Society of North America |
| 3 | Muslim World League |
| 4 | Umm Al-Qura University, Makkah |
| 5 | Egyptian General Authority of Survey |
| 7 | Institute of Geophysics, University of Tehran |
| 8 | Gulf Region |
| 9 | Kuwait |
| 10 | Qatar |
| 11 | Majlis Ugama Islam Singapura, Singapore |
| 12 | Union Organization Islamique de France |
| 13 | Diyanet İşleri Başkanlığı, Turkey |
| 14 | Spiritual Administration of Muslims of Russia |
| 15 | Moonsighting Committee Worldwide *(requires `shafaq` parameter via a custom format)* |
| 16 | Dubai (experimental) |
| 17 | Jabatan Kemajuan Islam Malaysia (JAKIM) |
| 18 | Tunisia |
| 19 | Algeria |
| 20 | KEMENAG – Kementerian Agama Republik Indonesia |
| 21 | Morocco |
| 22 | Comunidade Islamica de Lisboa |
| 23 | Ministry of Awqaf, Islamic Affairs and Holy Places, Jordan |
| 99 | (Reserved for custom methods) |

If you omit `method`, Aladhan picks the closest authority for the provided city/country/coordinates, but specifying it removes that ambiguity.

## 🎮 Commands

| Command | Description |
| --- | --- |
| `:PrayerReload` | Triggers an immediate fetch (`fetch_times`). Useful if the API key/city changed mid-session. |
| `:PrayerFormat <name>` | Switches to another registered format (tab-completion lists available formats). |
| `:PrayerTimes` | Shows the cached daily schedule from the active format. |
| `:PrayerToday [float\|notify]` | Displays today’s schedule in a bottom-right floating window (default) or via notification. |

These commands keep timers in sync—only one 60-second timer is ever active, even if the plugin is reloaded multiple times.

## 🔔 Events & Automation

Each time a prayer window starts, prayertime.nvim fires a `User`
autocommand named `PrayertimeAdhan`. Handlers receive `ev.data.prayer`
and `ev.data.time`, making it easy to wire extra alerts:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "PrayertimeAdhan",
  callback = function(ev)
    vim.notify(("Time for %s (%s)"):format(ev.data.prayer, ev.data.time))
  end,
})
```

Use this hook for chimes, integration scripts, or analytics.

Available fields inside the autocmd callback:

| Field | Type | Description |
| --- | --- | --- |
| `ev.data.prayer` | `string` | Name of the prayer that just started (`"Fajr"`, `"Dhuhr"`, etc.). |
| `ev.data.time` | `string` | Scheduled HH:MM timestamp for that prayer. |

## 🪟 Quick display

To preview today’s schedule from Lua, call:

```lua
require("prayertime").show_today({ mode = "float" }) -- or "notify"
```

The floating view anchors to the bottom-right corner and auto-closes after a few seconds (press `q` or `<Esc>` to dismiss immediately).

## 🔍 Introspection

The standard format caches the raw API payload and exposes helpers so you can build custom UIs:

```lua
local prayer = require("prayertime")
local payload = prayer.get_cached_payload() -- deep copy of the last JSON response
local last_synced = prayer.get_last_updated()
local derived_ranges = prayer.get_derived_ranges()
```

`payload` includes Aladhan’s original metadata (Hijri date, timezone, etc.), so you can inspect additional fields without firing your own HTTP requests.

## 💾 Caching & Reliability

The latest schedule is persisted at `stdpath("cache") .. "/prayertime/schedule.json"`.
If Neovim starts while offline (or before the next refresh completes), the plugin
reuses that cache whenever the city/country/method match your configuration, so
statuslines and `:PrayerToday` remain populated immediately after launch.

Network requests retry up to three times (with a one-second delay) before an
error notification is shown.

## 🩺 Health Check

Run `:checkhealth prayertime` to verify:

- Neovim version and optional `rcarriga/nvim-notify` integration.
- `nvim-lua/plenary.nvim` availability (required for HTTP).
- Reachability of Aladhan’s API using your current/default location settings.
