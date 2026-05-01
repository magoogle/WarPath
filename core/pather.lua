-- ---------------------------------------------------------------------------
-- StaticPather public-facing API.
--
-- Loads the merged WarMap data for the player's current zone (curated actor
-- catalog) and exposes a small, stable surface to consumers:
--
--   is_zone_supported()              -> bool
--   get_status()                     -> { key, key_type, cells, actors, ... }
--   find_path(start, goal, opts?)    -> vec3[] | nil, stats
--   path_to(goal, opts?)             -> vec3[] | nil, stats     (start = player)
--   get_actors(kind?)                -> array of actor entries
--   nearest_actor(kind, pos, skin?)  -> actor entry | nil
--   nearest_affordable_chest(pos, cinders?, kind?) -> actor entry | nil
--   reload()                         -> drops cache
--
-- Pathfinding is delegated to the QQT host's `world:calculate_path()` --
-- our own A*/grid is gone.  The actor catalog remains the high-value
-- crowdsourced data this plugin exists to serve.
-- ---------------------------------------------------------------------------

local loader      = require 'core.loader'
local host_pather = require 'core.host_pather'
local centerline  = require 'core.centerline'

local M = {}

-- Loaded state for the current key. nil when no data exists for current zone.
local state = nil
local last_key = nil

-- ---------------------------------------------------------------------------
-- Internal: lazy-load curated data for the current zone/pit-world.
-- Returns true if data is loaded, false otherwise.
-- ---------------------------------------------------------------------------
local function ensure_loaded()
    local key, key_type, ctx = loader.compute_key()
    if not key then return false end

    if last_key == key and state then return true end

    last_key = key
    state = nil

    local result = loader.load(key)
    if not result then return false end

    -- Cell count for the status display.  Three paths:
    --   1. Meta file        -- cells_omitted=true, count via
    --                          floors_meta[fid].cell_count
    --   2. Nav (parallel)   -- floors[fid] = {cxs, cys, wds},
    --                          count via #cxs
    --   3. Full / nav-tuple -- floors[fid] = [...], count via #f
    local floors = (result.data.grid and result.data.grid.floors) or {}
    local cell_count = 0
    if result.data.cells_omitted then
        local fm = (result.data.grid and result.data.grid.floors_meta) or {}
        for _, entry in pairs(fm) do
            cell_count = cell_count + (entry.cell_count or 0)
        end
    else
        for _, f in pairs(floors) do
            if type(f.cxs) == 'table' then
                cell_count = cell_count + #f.cxs
            else
                cell_count = cell_count + #f
            end
        end
    end

    -- Cell resolution + the floors table get stashed for the wall_dist
    -- builder to consume on first smooth_path call.  Eager build here
    -- was the source of multi-second hangs on zone change for big
    -- overworld zones (Hawe_Verge: 616k cells -> seconds of pure-Lua
    -- BFS on the game thread).  Most zone changes never trigger a
    -- find_path, so most pay nothing.
    local cell_res = (result.data.grid and result.data.grid.resolution) or 0.5

    state = {
        key            = key,
        key_type       = key_type,
        ctx            = ctx,
        data           = result.data,
        path           = result.source_path,
        actors         = result.data.actors or {},
        cells          = cell_count,
        wall_dist      = nil,             -- lazy: built on first smooth_path
        wall_dist_tried = false,          -- set after first build attempt
                                          -- so we don't retry on every call
                                          -- when there's no walkable data
        floors         = floors,          -- stashed for the lazy builder
        cell_res       = cell_res,
        loaded_at      = (get_time_since_inject and get_time_since_inject()) or 0,
    }
    console.print(string.format(
        '[WarPath] loaded %s: cells=%d actors=%d centerline=lazy (%s)',
        key, cell_count, #state.actors,
        result.data.saturated and 'SATURATED' or 'in-progress'))
    return true
end

-- ---------------------------------------------------------------------------
-- Build the wall-distance map for the currently-loaded state.  Called
-- only when smooth_path actually needs it -- big zones (overworld
-- 600k+ cells) take seconds to BFS in pure Lua, and most consumers
-- never request smoothed paths, so pre-building at zone-load time
-- was a multi-second hang for nothing.  Cached on first build so
-- subsequent smooth_path calls don't pay again.
local function ensure_wall_dist()
    if not state then return false end
    if state.wall_dist or state.wall_dist_tried then
        return state.wall_dist ~= nil
    end
    state.wall_dist_tried = true

    -- The fast load path uses the slim *.meta.json file which omits
    -- per-floor cell arrays (cells_omitted=true on the parsed table).
    -- For wall_dist we need the cells, so lazy-pull them from the
    -- full-file JSON now -- the full file's parse cost (~500ms on
    -- the biggest zones) is paid only here, the first time someone
    -- actually asks for path smoothing in this zone.
    local floors = state.floors
    if (not floors) or (next(floors) == nil) or state.data.cells_omitted then
        local pulled = loader.load_full_floors(state.key)
        if not pulled then
            console.print(string.format(
                '[WarPath] centerline skipped for %s: full-file cells not yet cached',
                state.key))
            return false
        end
        floors = pulled
        state.floors = pulled
        -- Recompute cells count from the freshly-loaded floors so the
        -- status display lines up with reality.  Two cell shapes:
        --   * parallel arrays {cxs, cys, wds} -- count via #cxs
        --   * sequence arrays  [{cx, cy, ...}] -- count via #f
        local n = 0
        for _, f in pairs(pulled) do
            if type(f.cxs) == 'table' then n = n + #f.cxs
            else                            n = n + #f end
        end
        state.cells = n
    end
    if (state.cells or 0) == 0 then return false end

    -- Build wall_dist by merging all floors' cells into one input.
    -- Parallel-array floors stay as {cxs, cys, wds} -- centerline.build_wall_dist
    -- detects that shape directly; we only flatten when floors are
    -- sequence-of-tuples so the function gets a uniform input.
    local first_floor
    for _, f in pairs(floors) do first_floor = f; break end

    local input
    if first_floor and type(first_floor.cxs) == 'table' then
        -- Parallel-array path: concatenate per-floor cxs/cys/wds.
        local cxs, cys, wds = {}, {}, {}
        for _, f in pairs(floors) do
            local fx, fy, fd = f.cxs, f.cys, f.wds
            for i = 1, #fx do
                cxs[#cxs + 1] = fx[i]
                cys[#cys + 1] = fy[i]
                wds[#wds + 1] = fd[i]
            end
        end
        input = { cxs = cxs, cys = cys, wds = wds }
    else
        -- Sequence-of-tuples path (legacy + per-cell-precomputed).
        input = {}
        for _, f in pairs(floors) do
            for i = 1, #f do input[#input + 1] = f[i] end
        end
    end

    local t0 = (get_time_since_inject and get_time_since_inject()) or 0
    state.wall_dist = centerline.build_wall_dist(input)
    local elapsed = ((get_time_since_inject and get_time_since_inject()) or 0) - t0
    console.print(string.format(
        '[WarPath] centerline built for %s: %.2fs (%d cells)',
        state.key, elapsed, state.cells))
    return state.wall_dist ~= nil
end

-- ---------------------------------------------------------------------------
-- Public: is the current zone supported by curated data?
-- ---------------------------------------------------------------------------
M.is_zone_supported = function ()
    return ensure_loaded() and state ~= nil
end

-- ---------------------------------------------------------------------------
-- Pit-only stub kept for backwards-compat with main.lua.  We no longer
-- maintain a per-floor grid since the host pathfinder operates on the
-- live world, so the floor index is informational only.
-- ---------------------------------------------------------------------------
M.set_pit_floor = function (_) end

-- ---------------------------------------------------------------------------
-- Public: status dictionary for GUI / probes.
-- ---------------------------------------------------------------------------
M.get_status = function ()
    if not ensure_loaded() or not state then
        local key, _ = loader.compute_key()
        return {
            supported   = false,
            current_key = key,
            host_pather = host_pather.has_pathfinder(),
        }
    end
    return {
        supported   = true,
        key         = state.key,
        key_type    = state.key_type,
        path        = state.path,
        cells       = state.cells,
        actors      = #state.actors,
        saturated   = state.data.saturated and true or false,
        sessions    = state.data.sessions_merged,
        host_pather = host_pather.has_pathfinder(),
    }
end

-- ---------------------------------------------------------------------------
-- Public: find a path from start_pos to goal_pos using the host pathfinder.
-- Returns:
--   path  : list of vec3 waypoints, or nil
--   stats : { reason } | { backend = 'host', n = N }
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Centerline-smooth a host-returned path using the cached wall-distance
-- map.  Cheap O(N * search_radius^2) where N is path length; smoothing
-- a typical 30-waypoint path is under a millisecond.
--
-- opts.smooth = false disables this for callers that want the raw host
-- output (e.g. exit-precision navigation where hugging the wall is
-- actually desired -- you're trying to step ONTO a portal switch).
-- ---------------------------------------------------------------------------
local function maybe_smooth(path, opts)
    if not path or #path < 3 then return path end
    if opts and opts.smooth == false then return path end
    if not state then return path end
    -- Lazy wall_dist: built on first smoothing request rather than at
    -- zone load.  Hides the BFS-cost behind an actual API user.
    if not state.wall_dist then
        if not ensure_wall_dist() then return path end
    end
    return centerline.smooth_path(path, state.wall_dist, state.cell_res, 3)
end

M.find_path = function (start_pos, goal_pos, opts)
    if not goal_pos  then return nil, { reason = 'bad_input' } end
    if not start_pos then return nil, { reason = 'bad_input' } end
    ensure_loaded()    -- parse the cache JSON if not already
    local path, err = host_pather.path_to(goal_pos, start_pos)
    if not path then return nil, { reason = err or 'unreachable' } end
    path = maybe_smooth(path, opts)
    return path, { backend = 'host_centerline', n = #path }
end

-- ---------------------------------------------------------------------------
-- Public: convenience -- path from the player's current position.
-- ---------------------------------------------------------------------------
M.path_to = function (goal_pos, opts)
    if not goal_pos then return nil, { reason = 'bad_input' } end
    ensure_loaded()
    local path, err = host_pather.path_to(goal_pos)
    if not path then return nil, { reason = err or 'unreachable' } end
    path = maybe_smooth(path, opts)
    return path, { backend = 'host_centerline', n = #path }
end

-- ---------------------------------------------------------------------------
-- Public: list curated actors. Optional kind filter.
-- ---------------------------------------------------------------------------
M.get_actors = function (kind)
    if not ensure_loaded() or not state then return {} end
    if not kind then return state.actors end
    local out = {}
    for _, a in ipairs(state.actors) do
        if a.kind == kind then out[#out + 1] = a end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Public: find the actor of a given kind nearest to pos. Optional skin
-- filter (exact or substring match).
-- ---------------------------------------------------------------------------
M.nearest_actor = function (kind, pos, skin)
    if not ensure_loaded() or not state then return nil end
    local px = (pos.x and pos:x()) or pos[1] or 0
    local py = (pos.y and pos:y()) or pos[2] or 0
    local best, best_d2 = nil, math.huge
    for _, a in ipairs(state.actors) do
        if (not kind or a.kind == kind)
           and (not skin or a.skin == skin or a.skin:find(skin, 1, true))
        then
            local dx, dy = a.x - px, a.y - py
            local d2 = dx * dx + dy * dy
            if d2 < best_d2 then
                best, best_d2 = a, d2
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Public: helltide-aware "find nearest affordable chest".
--
-- Given the player's current cinder count, returns the curated chest
-- entry that is:
--   1. Of the requested kind (chest_helltide_random/_silent/_targeted)
--      or any chest if kind == nil.
--   2. Affordable at the given cinder count (or any if cinders == nil).
--   3. Closest to from_pos.
-- ---------------------------------------------------------------------------
local CHEST_COST_DEFAULT = {
    chest_helltide_random   = 75,
    chest_helltide_silent   = 0,    -- key required, not cinders
    chest_helltide_targeted = 250,  -- conservative
    chest                   = 75,
}

local function default_cost_for(kind)
    return CHEST_COST_DEFAULT[kind] or 75
end

M.nearest_affordable_chest = function (from_pos, cinders, kind_filter)
    if not ensure_loaded() or not state then return nil end
    local px = (from_pos.x and from_pos:x()) or from_pos[1] or 0
    local py = (from_pos.y and from_pos:y()) or from_pos[2] or 0
    local best, best_d2 = nil, math.huge
    for _, a in ipairs(state.actors) do
        local k = a.kind
        local is_chest = k == 'chest_helltide_random'
                      or k == 'chest_helltide_silent'
                      or k == 'chest_helltide_targeted'
                      or k == 'chest'
        if is_chest and (not kind_filter or k == kind_filter) then
            local cost = default_cost_for(k)
            local affordable = (cinders == nil) or (cinders >= cost)
            if affordable then
                local dx, dy = a.x - px, a.y - py
                local d2 = dx * dx + dy * dy
                if d2 < best_d2 then
                    best, best_d2 = a, d2
                end
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Public: drop the in-memory cache. Next API call re-reads from disk.
-- Useful after the merger writes fresh data.
-- ---------------------------------------------------------------------------
M.reload = function ()
    state = nil
    last_key = nil
end

return M
