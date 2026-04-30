-- ---------------------------------------------------------------------------
-- Host-pathfinder shim.
--
-- The QQT host exposes:
--     world:calculate_path(start_vec3, end_vec3) -> vector<vec3>
--     pathfinder.calculate_and_get_path_points(start, end) -> vector<vec3>
--     pathfinder.request_move(...) / move_to_cpathfinder(...) -> drive movement
--
-- This module is a tiny, allocation-conscious wrapper that gives the rest
-- of StaticPather a one-call API: `path_to(target_vec3)` returns a list of
-- waypoints from the player's current position to `target_vec3`, or nil if
-- unreachable.
--
-- The host pathfinder is in-zone only.  Cross-zone planning lives in
-- core/travel.lua + core/world_graph.lua; this shim handles the local leg.
-- ---------------------------------------------------------------------------

local M = {}

-- ---------------------------------------------------------------------------
-- path_to(target_vec3, start_vec3?)
--   target_vec3 : vec3 (world coords)
--   start_vec3  : optional override; defaults to local player's position
--
-- Returns:
--   waypoints : array of vec3, or nil if unreachable / no current world
--   reason    : nil on success, otherwise short string for diagnostics
-- ---------------------------------------------------------------------------
M.path_to = function (target_vec3, start_vec3)
    if not target_vec3 then return nil, 'no_target' end

    local w = get_current_world and get_current_world() or nil
    if not w or not w.calculate_path then return nil, 'no_world_pathfinder' end

    local start
    if start_vec3 then
        start = start_vec3
    else
        local lp = get_local_player and get_local_player() or nil
        if not lp or not lp.get_position then return nil, 'no_player' end
        start = lp:get_position()
        if not start then return nil, 'no_player_pos' end
    end

    local ok, path = pcall(function () return w:calculate_path(start, target_vec3) end)
    if not ok then return nil, 'pathfinder_error: ' .. tostring(path):sub(1, 80) end
    if type(path) ~= 'table' then return nil, 'bad_return' end
    if #path == 0 then return nil, 'unreachable' end
    return path, nil
end

-- ---------------------------------------------------------------------------
-- request_move(target_vec3): kick the host pathfinder to actually move the
-- character toward target_vec3. Returns true on success; false if the host
-- doesn't expose request_move on this version.
-- ---------------------------------------------------------------------------
M.request_move = function (target_vec3)
    if not target_vec3 then return false end
    if pathfinder and pathfinder.request_move then
        local ok, _ = pcall(pathfinder.request_move, target_vec3)
        return ok
    end
    if pathfinder and pathfinder.move_to_cpathfinder then
        local ok, _ = pcall(pathfinder.move_to_cpathfinder, target_vec3)
        return ok
    end
    return false
end

-- ---------------------------------------------------------------------------
-- has_pathfinder(): cheap probe so callers can short-circuit if the host
-- this script is loaded in doesn't have the pathfinder API. Lets us keep
-- old behavior available as a fallback.
-- ---------------------------------------------------------------------------
M.has_pathfinder = function ()
    local w = get_current_world and get_current_world() or nil
    return w and w.calculate_path ~= nil
end

return M
