-- ---------------------------------------------------------------------------
-- WarMap data loader.
--
-- Finds + reads + parses `<key>.json` for the player's current zone (or
-- pit-template world for pit floors).
--
-- StaticPather is fully self-contained: its cache lives in
--    `<plugin>/cache/<key>.json`
-- and the HTTP fetcher is
--    `<plugin>/bin/fetch_zone.py`.
-- The fetcher runs in a detached cmd window (`start "" /B cmd /c ...`)
-- so it never blocks the game thread.
--
-- Lookup order on each load(key):
--   1. <plugin>/cache/<key>.json     -- StaticPather's own cache, refreshed
--                                       in the background by fetch_zone.py
--   2. <data_dir>/<key>.json         -- WarMap uploader's pulled_zones, if
--                                       the WarMap uploader is installed
--                                       alongside (incidental fallback)
--   3. <scripts>/../WarMap/data/zones/<key>.json   -- developer sibling repo
--   4. <scripts>/WarMapData/zones/<key>.json       -- legacy sidecar drop
--
-- Background fetch policy (per key, since module load):
--   * No cache file yet:  retry every FETCH_COOLDOWN_S
--   * Cache file present: refresh every REFRESH_COOLDOWN_S (cheap -- the
--     server returns 304 with no body when nothing has changed)
--
-- Returns the parsed table, or nil if no curated data exists for that key
-- yet.  A nil result on first load(key) for an unknown zone is normal --
-- the fetcher has been kicked off in the background; the next call (a
-- pulse or two later) will find the file.
-- ---------------------------------------------------------------------------

local json = require 'core.json_parser'

local M = {}

local SCHEMA_SUPPORTED    = 1
local FETCH_COOLDOWN_S    = 30      -- retry interval when cache is missing
local REFRESH_COOLDOWN_S  = 1800    -- how often to re-check a cached zone

-- ---------------------------------------------------------------------------
-- Path resolution
-- ---------------------------------------------------------------------------

local function get_scripts_root()
    -- package.path inside QQT looks like '<scripts>\<plugin>\?.lua'.
    -- Strip the plugin's own folder + '?\?.lua' to land on scripts/.
    for entry in package.path:gmatch('[^;]+') do
        local cleaned = entry:gsub('%?%.lua$', ''):gsub('\\$', '')
        local cut = cleaned:find('scripts', 1, true)
        if cut then
            return cleaned:sub(1, cut + #'scripts' - 1)
        end
    end
    return nil
end

local function get_plugin_root()
    local scripts = get_scripts_root()
    if not scripts then return nil end
    -- Derive the actual plugin folder from package.path rather than
    -- hardcoding it.  When the plugin was renamed StaticPather ->
    -- WarPath, the prior hardcode pointed at a non-existent folder,
    -- so the plugin's primary on-disk cache (cache/<key>.json) was
    -- unreachable -- every zone load silently fell through to the
    -- uploader's pulled_zones fallback, and zones missing from
    -- pulled_zones (or with permission/IO issues there) reported
    -- "no curated data" even when the cache had a fresh copy.
    --
    -- package.path under QQT is '<scripts>\<plugin>\?.lua;...';
    -- extract '<scripts>\<plugin>' by stripping the '?.lua' suffix
    -- from the first entry that begins with our scripts root.
    -- Hardcoded 'WarPath' fallback in case package.path is unusual.
    for entry in package.path:gmatch('[^;]+') do
        local m = entry:match('^(.+)[/\\]%?%.lua$')
        if m and m ~= '' and m:find(scripts, 1, true) == 1 then
            return m
        end
    end
    return scripts .. '\\WarPath'
end

local function plugin_cache_dir()
    local root = get_plugin_root()
    return root and (root .. '\\cache') or nil
end

local function plugin_cache_path(key)
    local d = plugin_cache_dir()
    return d and (d .. '\\' .. key .. '.json') or nil
end

local function fetcher_path()
    local root = get_plugin_root()
    return root and (root .. '\\bin\\fetch_zone.py') or nil
end

-- ---------------------------------------------------------------------------
-- Tiny file helpers
-- ---------------------------------------------------------------------------

local function read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local content = f:read('*a')
    f:close()
    return content
end

local function file_exists(path)
    local f = io.open(path, 'rb')
    if f then f:close(); return true end
    return false
end

-- Best-effort directory create.  os.execute('mkdir ...') is the typical
-- Lua way on Windows; the fetcher also creates its cache dir, but we
-- pre-create here so the very first load() doesn't race with start /B.
local _ensured_dirs = {}
local function ensure_dir(path)
    if not path or _ensured_dirs[path] then return end
    _ensured_dirs[path] = true
    os.execute('mkdir "' .. path .. '" 2> nul')
end

-- ---------------------------------------------------------------------------
-- uploader_config.lua (sibling) -- holds server_url + python interpreter
-- + (optionally) the uploader's pulled_zones path for fallback reads.
-- ---------------------------------------------------------------------------

local _uploader_cfg = false   -- false = not loaded yet, nil = loaded but missing
local function uploader_cfg()
    if _uploader_cfg ~= false then return _uploader_cfg end
    local scripts = get_scripts_root()
    if not scripts then _uploader_cfg = nil; return nil end
    local cfg_path = scripts .. '\\WarMapData\\uploader_config.lua'
    local chunk, _ = loadfile(cfg_path)
    if not chunk then _uploader_cfg = nil; return nil end
    local ok, result = pcall(chunk)
    if ok and type(result) == 'table' then
        _uploader_cfg = result
    else
        _uploader_cfg = nil
    end
    return _uploader_cfg
end

-- ---------------------------------------------------------------------------
-- Background fetcher spawn (non-blocking, throttled)
-- ---------------------------------------------------------------------------

-- Per-key throttle: { [key] = monotonic_seconds_when_last_spawned }
local _last_spawn = {}

local function now_s()
    return (get_time_since_inject and get_time_since_inject()) or os.time()
end

-- Returns true if a spawn was attempted, false if throttled / unavailable.
local function spawn_fetch(key)
    local cfg = uploader_cfg()
    local server = cfg and cfg.server_url
    if not server or server == '' then return false, 'no_server_url' end

    local cache_dir = plugin_cache_dir()
    local fetcher   = fetcher_path()
    if not (cache_dir and fetcher) then return false, 'paths_unresolved' end

    -- Cooldown: shorter when there's no cache yet (we want the file to
    -- show up quickly); longer when we already have data (just a refresh).
    local has_cache = file_exists(plugin_cache_path(key))
    local cooldown  = has_cache and REFRESH_COOLDOWN_S or FETCH_COOLDOWN_S

    local last = _last_spawn[key]
    local t = now_s()
    if last and (t - last) < cooldown then return false, 'throttled' end
    _last_spawn[key] = t

    ensure_dir(cache_dir)

    -- File-IPC instead of os.execute.  Lua's os.execute on Windows
    -- ALWAYS allocates a cmd.exe child to interpret the command line,
    -- even when the command itself is just 'start "" /B pythonw ...' --
    -- the parent cmd.exe flashes a console window briefly before
    -- exiting.  Even after switching to pythonw, the wrapping cmd
    -- still flashes -- /B suppresses console for whatever cmd
    -- LAUNCHES, but not for cmd.exe itself.
    --
    -- Solution: don't spawn anything from Lua.  Append a one-line
    -- "please fetch this zone" request to a queue file the long-lived
    -- uploader watcher reads each cycle.  Zero process spawns from
    -- Lua = zero CMD flashes regardless of how many cache misses.
    --
    -- The watcher is expected to be running already (started by the
    -- scheduled task at logon -- install.ps1 registers the task).  If
    -- it isn't, requests just queue up until something starts reading.
    local queue_path = (cfg and cfg.sidecar_dir) and (cfg.sidecar_dir .. '\\fetch_queue.txt') or nil
    if not queue_path then return false, 'no_sidecar_dir' end

    -- Simple newline-delimited format: 'fetch_zone:<key>'.  Unknown
    -- line prefixes are no-ops in the watcher so we can extend later
    -- (e.g. 'refresh_all', 'fetch_actor_index') without breaking older
    -- watchers.
    local f = io.open(queue_path, 'a')
    if not f then return false, 'queue_open_failed' end
    f:write(string.format('fetch_zone:%s\n', key))
    f:close()
    return true
end

-- ---------------------------------------------------------------------------
-- Candidate path list (lookup order documented at top of file)
-- ---------------------------------------------------------------------------

-- Candidate paths.  Within each directory we list the slim "meta"
-- variant FIRST and the full file second.  Meta files don't carry
-- the per-floor cell arrays (which dominate parse time on big zones
-- -- ~500ms in pure Lua for a 12 MB Hawe_Verge), so loading the
-- meta gives sub-30ms zone-change parse times.  WarPath lazy-loads
-- the full file only when wall-distance smoothing is actually
-- requested (see core/pather.lua's ensure_wall_dist).
local function candidate_paths(key)
    local out = {}
    local own_dir = plugin_cache_dir()
    if own_dir then
        out[#out + 1] = own_dir .. '\\' .. key .. '.meta.json'
        out[#out + 1] = own_dir .. '\\' .. key .. '.json'
    end
    local cfg = uploader_cfg()
    if cfg and cfg.data_dir and cfg.data_dir ~= '' then
        out[#out + 1] = cfg.data_dir .. '\\' .. key .. '.meta.json'
        out[#out + 1] = cfg.data_dir .. '\\' .. key .. '.json'
    end
    local scripts = get_scripts_root()
    if scripts then
        local repo = scripts:gsub('scripts$', '')
        out[#out + 1] = repo .. 'WarMap\\data\\zones\\' .. key .. '.meta.json'
        out[#out + 1] = repo .. 'WarMap\\data\\zones\\' .. key .. '.json'
        out[#out + 1] = scripts .. '\\WarMapData\\zones\\' .. key .. '.meta.json'
        out[#out + 1] = scripts .. '\\WarMapData\\zones\\' .. key .. '.json'
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Lazy cells loader.  Used by core/pather.lua's ensure_wall_dist when
-- it actually needs the per-floor cell arrays.  Searches the same
-- candidate dirs as candidate_paths but ONLY looks for the FULL
-- (non-.meta) JSON file.  Returns the parsed grid.floors table or
-- nil when no full file exists locally.
-- ---------------------------------------------------------------------------
local function full_file_paths(key)
    local out = {}
    local own_dir = plugin_cache_dir()
    if own_dir then out[#out + 1] = own_dir .. '\\' .. key .. '.json' end
    local cfg = uploader_cfg()
    if cfg and cfg.data_dir and cfg.data_dir ~= '' then
        out[#out + 1] = cfg.data_dir .. '\\' .. key .. '.json'
    end
    local scripts = get_scripts_root()
    if scripts then
        local repo = scripts:gsub('scripts$', '')
        out[#out + 1] = repo .. 'WarMap\\data\\zones\\' .. key .. '.json'
        out[#out + 1] = scripts .. '\\WarMapData\\zones\\' .. key .. '.json'
    end
    return out
end

M.load_full_floors = function (key)
    if not key or key == '' then return nil end
    for _, p in ipairs(full_file_paths(key)) do
        local content = read_file(p)
        if content then
            local data, err = json.decode(content)
            if data and data.grid and data.grid.floors then
                return data.grid.floors
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Drop the cached uploader_config.lua (e.g. after re-running install.bat
-- with different paths).  Next load() call re-reads it.
M.invalidate_cache = function ()
    _uploader_cfg = false
end

M.config = function ()
    return uploader_cfg()
end

M.plugin_root     = get_plugin_root
M.plugin_cache_dir = plugin_cache_dir
M.scripts_root    = get_scripts_root

-- Manually nudge the fetcher (e.g. from a GUI 'refresh' button).
M.fetch = function (key)
    if not key or key == '' then return false, 'no_key' end
    return spawn_fetch(key)
end

-- Attempt to load curated data for a key.
-- Returns: { data = table, source_path = string } | nil
--
-- Note: this function NO LONGER triggers a per-zone refresh fetch.  All
-- zone data is bulk-pulled once per Lua reload by spawn_fetch_all() at
-- module load (see bottom of this file), so a cache hit means "freshest
-- data available since the most recent /reload".  The only reason to
-- spawn a per-zone fetch from M.load() is when the cache is missing
-- the requested key entirely -- e.g. a brand-new zone uploaded since
-- the bulk fetch ran.
M.load = function (key)
    if not key or key == '' then return nil end

    local result = nil
    for _, p in ipairs(candidate_paths(key)) do
        local content = read_file(p)
        if content then
            local data, err = json.decode(content)
            if not data then
                console.print('[WarPath] parse error for ' .. key .. ': ' .. tostring(err))
                -- Corrupt cache file -- fetch from server to replace it.
                spawn_fetch(key)
            elseif data.schema_version ~= SCHEMA_SUPPORTED then
                console.print('[WarPath] unsupported schema_version=' ..
                    tostring(data.schema_version) .. ' for ' .. key)
            else
                result = { data = data, source_path = p }
                break
            end
        end
    end

    -- Cache miss: nudge a per-zone fetch.  Bulk fetch on /reload covers
    -- the common case; this is the fallback for zones added to the
    -- server after our last reload.
    if not result then
        spawn_fetch(key)
    end

    return result
end

-- Returns the activity-aware lookup key for the player's current location.
-- For pit (zone='PIT_Subzone'), returns the world name (template).
-- For everything else, returns the zone name.
M.compute_key = function ()
    local w = get_current_world()
    if not w then return nil, nil, nil end
    local zone     = w.get_current_zone_name and w:get_current_zone_name() or nil
    local world    = w.get_name             and w:get_name()             or nil
    local world_id = w.get_world_id         and w:get_world_id()         or nil

    if zone == 'PIT_Subzone' and world then
        return world, 'pit_world', { zone = zone, world = world, world_id = world_id }
    end
    return zone, 'zone', { zone = zone, world = world, world_id = world_id }
end

-- ---------------------------------------------------------------------------
-- One-shot bulk fetch on module load.  Pulls every zone the server knows
-- about into the local cache so subsequent zone selections are pure cache
-- hits.  Re-running (e.g. on /reload) refreshes only the zones whose
-- Last-Modified is newer than the local cache (If-Modified-Since
-- handling in fetch_all.py).
--
-- This replaces the old "spawn fetch_zone.py on every cache miss + every
-- 30 minutes per zone" strategy that was popping a Python window every
-- couple minutes during play.  Now it's one bulk spawn per /reload.
-- ---------------------------------------------------------------------------
local function fetch_all_path()
    local root = get_plugin_root()
    return root and (root .. '\\bin\\fetch_all.py') or nil
end

local function spawn_fetch_all()
    -- File-IPC: queue a 'refresh_all' command for the long-lived
    -- uploader watcher to handle on its next cycle.  Zero process
    -- spawns from Lua = zero CMD flashes on /reload.  Watcher
    -- discovers the request, calls fetch_all.py itself, writes results
    -- into cache/.  See spawn_fetch() above for the same pattern.
    local cfg = uploader_cfg()
    if not cfg then
        console.print('[WarPath] bulk fetch skipped: no uploader config')
        return
    end
    local queue_path = cfg.sidecar_dir and (cfg.sidecar_dir .. '\\fetch_queue.txt') or nil
    if not queue_path then
        console.print('[WarPath] bulk fetch skipped: no sidecar_dir')
        return
    end
    local f = io.open(queue_path, 'a')
    if not f then
        console.print('[WarPath] bulk fetch skipped: queue write failed')
        return
    end
    f:write('refresh_all\n')
    f:close()
    console.print('[WarPath] bulk fetch queued for the uploader watcher')
    return
end


-- Fire once when the module loads.  Idempotent on re-loads -- the per-
-- zone IMS handling means unchanged zones return 304 with no body.
spawn_fetch_all()

-- Public: kick a fresh bulk fetch (e.g. from a GUI button after the
-- operator added new ignore patterns and wants the recorder + bot to
-- see updated zone data sooner than the next /reload).
M.bulk_fetch = spawn_fetch_all

return M
