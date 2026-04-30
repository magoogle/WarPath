-- ---------------------------------------------------------------------------
-- In-game path visualization. Draws line segments between path waypoints
-- as a color-graded ribbon on the ground (3D). Optional goal marker at
-- the last waypoint.
--
-- Updated by `pather` whenever a new path is computed; cleared on demand
-- or when the player reaches the end.
-- ---------------------------------------------------------------------------

local M = {}

-- Currently displayed path (array of vec3) and metadata.
local path = nil
local label = nil
local set_at_t = -math.huge

-- Auto-clear after this long with no refresh, so stale paths don't linger
-- when the bot moves on.
local TTL_S = 60.0

M.set_path = function (waypoints, lbl)
    if not waypoints or #waypoints == 0 then
        path = nil
        label = nil
        return
    end
    path = waypoints
    label = lbl
    set_at_t = (get_time_since_inject and get_time_since_inject()) or 0
end

M.clear = function ()
    path = nil
    label = nil
end

M.has_path = function ()
    return path ~= nil and #path > 0
end

M.path_length = function ()
    if not path then return 0 end
    return #path
end

-- ---------------------------------------------------------------------------
-- Render hook -- called from main.lua on_render. Cheap when there's no
-- path; otherwise draws #path-1 line segments.
-- ---------------------------------------------------------------------------
M.render = function ()
    if not path or #path < 1 then return end
    local now = (get_time_since_inject and get_time_since_inject()) or 0
    if (now - set_at_t) > TTL_S then
        path = nil
        label = nil
        return
    end

    -- Lift each waypoint slightly so the line sits visibly above ground.
    -- D4's terrain isn't perfectly flat so a small Z offset helps prevent
    -- the line from clipping in/out of the floor mesh.
    local LIFT = 0.4

    local n = #path
    for i = 1, n - 1 do
        local a = path[i]
        local b = path[i + 1]
        if a and b then
            local u = (i - 1) / math.max(n - 1, 1)
            local r = math.floor(80 + u * 175)
            local g = math.floor(255 - u * 100)
            local bl = math.floor(80 + u * 80)
            local seg = vec3:new(a:x(), a:y(), (a:z() or 0) + LIFT)
            local end_ = vec3:new(b:x(), b:y(), (b:z() or 0) + LIFT)
            graphics.line(seg, end_, color_new(r, g, bl, 220), 3)
        end
    end

    -- Marker on the goal: a small circle at z + LIFT.
    local goal = path[n]
    if goal then
        local center = vec3:new(goal:x(), goal:y(), (goal:z() or 0) + LIFT)
        graphics.circle_3d(center, 1.5, color_new(255, 200, 50, 220), 2)
        if label then
            graphics.text_3d(label, center, 16, color_new(255, 240, 120, 240))
        end
    end
end

return M
