-- ---------------------------------------------------------------------------
-- Cross-zone travel planner.
--
-- Loads the universal actor index produced by the merger, plus the world
-- graph (waypoint SNOs), and produces a step-by-step plan to reach any
-- known target.
--
-- Plan steps:
--   { kind = 'walk',     to_x, to_y, to_z, in_zone, path = vec3[] }
--   { kind = 'teleport', sno, to_zone }
--   { kind = 'interact', actor }              -- placeholder for future
--
-- The planner only has the data it has. If the target's zone has no
-- waypoint SNO, it returns nil with a reason. Caller is expected to fall
-- back (e.g., manual walk, Batmobile exploration).
-- ---------------------------------------------------------------------------

local json   = require 'core.json_parser'
local loader = require 'core.loader'
local world  = require 'core.world_graph'

local M = {}

-- ----- Actor index loader (cached per session) ----------------------------
local index_cache = {
    by_skin = nil,
    by_kind = nil,
    loaded_at = -math.huge,
}
local INDEX_TTL = 60.0         -- re-read every 60s in case merger updated it

local function find_index_path()
    local scripts = loader.scripts_root()
    if not scripts then return nil end
    -- Sibling repo: scripts/.. /WarMap/data/zones/_actor_index.json
    return scripts:gsub('scripts$', '') .. 'WarMap\\data\\zones\\_actor_index.json'
end

local function ensure_index()
    local now = (get_time_since_inject and get_time_since_inject()) or 0
    if index_cache.by_skin and (now - index_cache.loaded_at) < INDEX_TTL then
        return true
    end
    local path = find_index_path()
    if not path then return false end
    local f = io.open(path, 'r')
    if not f then return false end
    local content = f:read('*a')
    f:close()
    if not content or content == '' then return false end
    local data, err = json.decode(content)
    if not data then
        console.print('[travel] _actor_index parse error: ' .. tostring(err))
        return false
    end
    index_cache.by_skin = data.by_skin or {}
    index_cache.by_kind = data.by_kind or {}
    index_cache.loaded_at = now
    return true
end

-- ----- Lookups -----------------------------------------------------------

-- Returns array of {skin, key, kind, x, y, z, floor, sessions_seen}
-- entries matching the predicate. Predicate is given each candidate row
-- with its skin attached.
local function search_index(predicate)
    if not ensure_index() then return {} end
    local results = {}
    for skin, rows in pairs(index_cache.by_skin) do
        for _, r in ipairs(rows) do
            local row = {
                skin = skin,
                key  = r.key,
                kind = r.kind,
                x    = r.x, y = r.y, z = r.z,
                floor = r.floor,
                sessions_seen = r.sessions_seen,
            }
            if predicate(row) then
                results[#results + 1] = row
            end
        end
    end
    return results
end

-- Public: find candidates by skin (exact or substring) and/or kind.
M.find = function (opts)
    opts = opts or {}
    local want_skin = opts.skin
    local want_kind = opts.kind
    local exact     = opts.exact

    return search_index(function (row)
        if want_kind and row.kind ~= want_kind then return false end
        if want_skin then
            if exact then
                if row.skin ~= want_skin then return false end
            else
                if not row.skin:find(want_skin, 1, true) then return false end
            end
        end
        return true
    end)
end

-- ----- Distance ranking --------------------------------------------------

local function dist2(a_x, a_y, b_x, b_y)
    local dx, dy = a_x - b_x, a_y - b_y
    return dx * dx + dy * dy
end

-- Picks the candidate that minimises an estimated travel cost. We prefer
-- targets in the player's CURRENT zone (no teleport needed); among those
-- that aren't, we prefer ones whose zone has a known waypoint and whose
-- in-zone position is closest to the waypoint.  Without coordinates for
-- waypoint arrival points we fall back to "any zone with a waypoint".
local function rank_candidate(c, current_zone, current_pos)
    local score = 0
    if c.key == current_zone then
        score = score + 0    -- best: same zone
        if current_pos then
            score = score + dist2(c.x, c.y, current_pos.x, current_pos.y) * 0.0001
        end
        return score
    end
    if not world.can_teleport_to(c.key) then
        return math.huge   -- unreachable
    end
    score = score + 1000   -- penalty for needing a teleport
    -- Among teleportable destinations, prefer ones we have data for
    if c.sessions_seen and c.sessions_seen > 0 then
        score = score - math.min(c.sessions_seen, 5)
    end
    return score
end

-- ----- Path planning -----------------------------------------------------

-- Public: plan a travel route from `current_pos` (in `current_zone`) to
-- the best-matching candidate found by `find_opts`.
--
-- Returns: { plan = step[], target = candidate, reason? = string } | nil
-- where step is one of:
--   { kind='walk',     in_zone, to_x, to_y, to_z, path=vec3[] (filled by caller using StaticPather) }
--   { kind='teleport', sno, to_zone, name }
M.plan = function (find_opts, current_zone, current_pos)
    local candidates = M.find(find_opts)
    if #candidates == 0 then
        return nil, 'no_match'
    end

    -- Rank
    local best, best_score = nil, math.huge
    for _, c in ipairs(candidates) do
        local s = rank_candidate(c, current_zone, current_pos)
        if s < best_score then
            best, best_score = c, s
        end
    end
    if not best or best_score == math.huge then
        return nil, 'unreachable'
    end

    local steps = {}

    if best.key ~= current_zone then
        -- Step 1: teleport
        local sno = world.waypoint_for(best.key)
        if not sno then
            return nil, 'no_waypoint'
        end
        steps[#steps + 1] = {
            kind     = 'teleport',
            sno      = sno,
            to_zone  = best.key,
            name     = (world.zones[best.key] and world.zones[best.key].name) or best.key,
        }
    end

    -- Step 2: walk from waypoint arrival (or current pos) to actor
    steps[#steps + 1] = {
        kind     = 'walk',
        in_zone  = best.key,
        to_x     = best.x,
        to_y     = best.y,
        to_z     = best.z,
    }

    return {
        plan   = steps,
        target = best,
    }
end

-- Public: convenience -- "go to <skin contains>".
M.plan_to_skin = function (skin_substring, current_zone, current_pos)
    return M.plan({ skin = skin_substring }, current_zone, current_pos)
end

-- Public: convenience -- "go to nearest <kind>".
M.plan_to_kind = function (kind, current_zone, current_pos)
    return M.plan({ kind = kind }, current_zone, current_pos)
end

-- Public: drop the cached index so next call re-reads from disk. Useful
-- after the merger runs mid-session.
M.reload = function ()
    index_cache.by_skin = nil
    index_cache.by_kind = nil
    index_cache.loaded_at = -math.huge
end

-- ----- Diagnostics -------------------------------------------------------

-- Returns counts + sample skins so a GUI can show "we know about N actors".
M.stats = function ()
    if not ensure_index() then return { loaded = false } end
    local skin_count, kind_count, total = 0, 0, 0
    for _, rows in pairs(index_cache.by_skin) do
        skin_count = skin_count + 1
        total = total + #rows
    end
    for _ in pairs(index_cache.by_kind) do kind_count = kind_count + 1 end
    return {
        loaded = true,
        skins  = skin_count,
        kinds  = kind_count,
        total_entries = total,
    }
end

return M
