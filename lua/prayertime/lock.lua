-- lua/prayertime/lock.lua
local uv = vim.uv or vim.loop

local M = {}

local function now()
	return os.time()
end

local function read_json(path)
	local fd = uv.fs_open(path, "r", 420)
	if not fd then
		return nil
	end
	local stat = uv.fs_fstat(fd)
	if not stat or stat.size <= 0 then
		uv.fs_close(fd)
		return nil
	end
	local data = uv.fs_read(fd, stat.size, 0)
	uv.fs_close(fd)
	if not data then
		return nil
	end
	local ok, obj = pcall(vim.json.decode, data)
	if not ok then
		return nil
	end
	return obj
end

local function atomic_write_json(path, obj)
	local tmp = path .. ".tmp"
	local fd = assert(uv.fs_open(tmp, "w", 420))
	local s = vim.json.encode(obj)
	uv.fs_write(fd, s, 0)
	uv.fs_close(fd)
	-- atomic replace on POSIX
	uv.fs_rename(tmp, path)
end

-- Try to become leader. Returns true if this nvim should emit sound events.
function M.try_acquire(opts)
	opts = opts or {}
	local lock_path = opts.lock_path
	local ttl = opts.ttl or 5

	local current = read_json(lock_path)
	local t = now()

	-- If lock exists and not expired -> not leader
	if current and current.expires_at and current.expires_at > t then
		return false
	end

	-- Attempt to "win" by writing our lock (best-effort)
	local lock = {
		pid = uv.getpid(),
		hostname = uv.os_gethostname(),
		expires_at = t + ttl,
	}
	pcall(atomic_write_json, lock_path, lock)

	-- Re-read and confirm we're the leader (avoids “both think they won”)
	local confirm = read_json(lock_path)
	if
		confirm
		and confirm.pid == lock.pid
		and confirm.hostname == lock.hostname
		and confirm.expires_at == lock.expires_at
	then
		return true
	end

	return false
end

-- Refresh leadership periodically (optional, but recommended)
function M.start_heartbeat(opts)
	opts = opts or {}
	local lock_path = opts.lock_path
	local ttl = opts.ttl or 5
	local interval_ms = math.floor((ttl * 1000) / 2)

	local timer = uv.new_timer()
	timer:start(interval_ms, interval_ms, function()
		local t = now()
		local cur = read_json(lock_path)
		if not cur then
			return
		end

		-- Only refresh if we're the current leader
		if cur.pid == uv.getpid() and cur.hostname == uv.os_gethostname() then
			cur.expires_at = t + ttl
			pcall(atomic_write_json, lock_path, cur)
		end
	end)

	return timer
end

return M
