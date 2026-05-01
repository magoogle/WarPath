-- ---------------------------------------------------------------------------
-- core/centerline.lua
--
-- Centerline path smoothing.  The QQT host pathfinder returns the
-- shortest walkable path between A and B, which often hugs walls
-- because diagonal cell-to-cell movement is cheaper across narrow
-- gaps than the longer route through the middle of a corridor.
-- The bot ends up scraping along walls, looks bad, and gets stuck on
-- corner-collision more often.
--
-- This module post-processes a host path: for each interior waypoint,
-- it nudges the position toward the nearest high-wall-distance cell
-- in our merged walkable grid.  Endpoints (start + goal) stay put so
-- we don't disrupt entry/exit precision.
--
-- "wall-distance" = BFS distance from each walkable cell to the nearest
-- non-walkable cell.  Computed once per zone (cheap, linear in cell
-- count) and stashed on the per-zone state.
-- ---------------------------------------------------------------------------

local M = {}

local ADJ = { {1, 0}, {-1, 0}, {0, 1}, {0, -1} }

-- ---------------------------------------------------------------------------
-- Build the wall-distance map for a flattened cell array.  The merged
-- zone JSON has cells per floor; callers typically pass floors[1] or
-- whatever floor the player is on.
--
-- Cell format (matches the merger's emit): { cx, cy, walkable_bool, conf }
--
-- Returns:
--   dist: { ['cx,cy'] = distance }   -- only walkable cells; others omitted
-- ---------------------------------------------------------------------------
M.build_wall_dist = function (cells)
    -- Three cell formats supported, in order of preference:
    --
    --   1. Parallel arrays { cxs = {..}, cys = {..}, wds = {..} }
    --      -- the latest nav-emit format from the server, ~50%
    --      smaller than per-cell tuples.  Detected by `cells.cxs`
    --      being a table.
    --
    --   2. Per-cell precomputed tuples [[cx, cy, dist], ...].  An
    --      earlier nav format kept around for backward compat with
    --      already-cached files.  Detected by cells[1][3] being a
    --      number >= 1 (precomputed wall_dist).
    --
    --   3. Legacy full format [[cx, cy, walkable_bool, conf, total],
    --      ...].  No precomputed distance -- falls through to the
    --      in-Lua BFS below.  Used by older deploys / dev sandboxes.
    --
    -- All three converge on the same { "cx,cy" = N } return shape so
    -- centerline.snap_waypoint and friends don't need to know.
    if cells and type(cells.cxs) == 'table' then
        -- Format 1: parallel arrays.
        local cxs, cys, wds = cells.cxs, cells.cys, cells.wds
        local n = #cxs
        local dist = {}
        for i = 1, n do
            dist[cxs[i] .. ',' .. cys[i]] = wds[i]
        end
        return dist
    end

    local n = (type(cells) == 'table') and #cells or 0
    if n > 0 then
        -- Format 2: per-cell precomputed tuples.  Sniff cells[1][3]'s
        -- type -- numeric = precomputed wall_dist, boolean = legacy
        -- walkable flag (Format 3, BFS path below).
        local first = cells[1]
        if first and type(first[3]) == 'number' and first[3] >= 1 then
            local dist = {}
            for i = 1, n do
                local c = cells[i]
                dist[c[1] .. ',' .. c[2]] = c[3]
            end
            return dist
        end
    end

    -- Legacy path: full-format cells, build wall_dist via in-Lua BFS.
    local cell_set = {}
    for i = 1, n do
        local c = cells[i]
        if c[3] then     -- walkable flag (boolean here)
            cell_set[c[1] .. ',' .. c[2]] = true
        end
    end

    local dist = {}
    local queue = {}
    local qn = 0

    -- Seed: every walkable cell with at least one non-walkable
    -- 4-neighbor gets dist=1.
    for k, _ in pairs(cell_set) do
        local cx_s, cy_s = k:match('(-?%d+),(-?%d+)')
        local cx, cy = tonumber(cx_s), tonumber(cy_s)
        for i = 1, 4 do
            local nk = (cx + ADJ[i][1]) .. ',' .. (cy + ADJ[i][2])
            if not cell_set[nk] then
                dist[k] = 1
                qn = qn + 1
                queue[qn] = { cx, cy, 1 }
                break
            end
        end
    end

    -- BFS outward.  Use a head pointer so it stays O(N); table.remove
    -- on index 1 would be O(N^2).
    local head = 1
    while head <= qn do
        local node = queue[head]
        head = head + 1
        local cx, cy, d = node[1], node[2], node[3]
        local nd = d + 1
        for i = 1, 4 do
            local nx = cx + ADJ[i][1]
            local ny = cy + ADJ[i][2]
            local nk = nx .. ',' .. ny
            if cell_set[nk] and not dist[nk] then
                dist[nk] = nd
                qn = qn + 1
                queue[qn] = { nx, ny, nd }
            end
        end
    end

    return dist
end

-- ---------------------------------------------------------------------------
-- Snap a single waypoint toward the highest-wall-distance cell within a
-- small search radius.  Cell resolution is the merged grid's cell size
-- (typically 0.5m; pulled from data.grid.resolution).
--
-- Returns a vec3 (the original or a new center-of-room one with the
-- same z).  Falls through and returns the input unchanged when:
--   * dist map is empty (no merged data for this zone)
--   * the waypoint's cell isn't in the dist map (unmapped territory)
--   * already at a local max within the search radius
-- ---------------------------------------------------------------------------
M.snap_waypoint = function (wp, dist, cell_res, search_radius)
    if not dist or not wp or not wp.x or not wp.y then return wp end
    local res = cell_res or 0.5
    local r   = search_radius or 3
    local wx  = wp:x()
    local wy  = wp:y()
    local cx  = math.floor(wx / res + 0.5)
    local cy  = math.floor(wy / res + 0.5)

    local cur_key = cx .. ',' .. cy
    local cur_d   = dist[cur_key] or 0
    local best_d  = cur_d
    local best_cx, best_cy = cx, cy

    for dy = -r, r do
        for dx = -r, r do
            if dx ~= 0 or dy ~= 0 then
                local k = (cx + dx) .. ',' .. (cy + dy)
                local d = dist[k]
                if d and d > best_d then
                    -- Tie-break: prefer cells closer to the original
                    -- (don't drift more than necessary).
                    best_d = d
                    best_cx = cx + dx
                    best_cy = cy + dy
                end
            end
        end
    end

    if best_cx == cx and best_cy == cy then
        return wp
    end
    return vec3:new(best_cx * res, best_cy * res, wp:z())
end

-- ---------------------------------------------------------------------------
-- Smooth an entire host path.  First and last waypoints stay anchored
-- (caller probably picked them deliberately for entry/exit precision).
-- All interior waypoints get snap_waypoint'd.
-- ---------------------------------------------------------------------------
M.smooth_path = function (path, dist, cell_res, search_radius)
    if not path or #path < 3 or not dist then return path end
    local out = {}
    out[1] = path[1]
    for i = 2, #path - 1 do
        out[i] = M.snap_waypoint(path[i], dist, cell_res, search_radius)
    end
    out[#path] = path[#path]
    return out
end

return M
