-- ---------------------------------------------------------------------------
-- StaticPather v0.2 -- crowdsourced actor catalog + host-pathfinder shim.
--
-- The plugin loads merged WarMap data for the current zone, exposing a
-- catalog of points of interest (chests, vendors, portals, obelisks,
-- traversals, ...) plus a pathfinding API that delegates to the QQT host's
-- world:calculate_path().  The hand-rolled A* + walkability grid that
-- v0.1 shipped is gone; the host's pathfinder is faster, collision-aware,
-- and always up-to-date with the live world.
--
-- Cross-zone travel (teleport-to-town legs, world-graph waypoints) still
-- lives in core/travel.lua + core/world_graph.lua -- the host pathfinder
-- only operates within the current zone, so cross-zone planning is
-- explicitly handled here.
--
-- Public global: StaticPatherPlugin.* (see core/pather.lua).
-- ---------------------------------------------------------------------------

local gui        = require 'gui'
local settings   = require 'core.settings'
local pather     = require 'core.pather'
local loader     = require 'core.loader'
local visualizer = require 'core.visualizer'
local travel     = require 'core.travel'
local world      = require 'core.world_graph'

local local_player
local last_zone = nil
local last_pulse_t = -math.huge

local function update_locals()
    local_player = get_local_player()
end

-- Refresh status line shown in the GUI (cheap; re-evaluated every ~0.5s).
local function refresh_status()
    if not settings.enabled then
        gui.status_line = '(disabled)'
        return
    end
    local s = pather.get_status()
    if s.supported then
        gui.status_line = string.format(
            'Loaded %s [%s]: %d cells, %d actors%s',
            tostring(s.key), tostring(s.key_type),
            s.cells or 0, s.actors or 0,
            s.saturated and ' (SATURATED)' or '')
    else
        gui.status_line = 'No curated data for ' .. tostring(s.current_key or '?')
    end
end

-- ----- Demo: cross-zone travel planning ---------------------------------
--
-- Reads `gui.travel_request` (set by a button click), finds the target
-- in the universal actor index, plans the route (teleport + walk if
-- needed), and visualizes it. Walking segments only get an A* path drawn
-- if the player is already in the target zone -- otherwise the line is
-- a "future" segment we'll route once we arrive there.
local function demo_travel(req)
    if not local_player then return end
    local pp = local_player:get_position()
    local current_zone = (get_current_world() and get_current_world():get_current_zone_name()) or nil

    local find_opts = {}
    if req.kind == 'kind' then find_opts.kind = req.value
    else find_opts.skin = req.value end

    local plan, reason = travel.plan(find_opts,
        current_zone,
        { x = pp:x(), y = pp:y(), z = pp:z() })

    if not plan then
        gui.travel_line = string.format(
            'No plan: %s (target=%s/%s, current zone=%s)',
            tostring(reason), find_opts.kind or '?', find_opts.skin or '?',
            tostring(current_zone))
        visualizer.clear()
        return
    end

    local target = plan.target
    gui.travel_line = string.format(
        'Plan to %s in %s @(%.1f,%.1f) -- %d step(s)',
        target.skin, target.key, target.x, target.y, #plan.plan)

    -- Walk-only case (already in target's zone): full A* + visualize.
    if #plan.plan == 1 and plan.plan[1].kind == 'walk' then
        local goal = vec3:new(target.x, target.y, pp:z())
        local path, stats = pather.find_path(pp, goal)
        if path then
            visualizer.set_path(path, target.skin)
            gui.travel_line = gui.travel_line ..
                string.format(' [A* %dms, %d waypoints]',
                    math.floor((stats and stats.time_ms) or 0), #path)
        else
            gui.travel_line = gui.travel_line ..
                ' [A* failed: ' .. tostring(stats and stats.reason or '?') .. ']'
        end
        console.print('[StaticPather] ' .. gui.travel_line)
        return
    end

    -- Cross-zone case: visualize the line segment from player to target
    -- using a synthetic "teleport then walk" path. Because the bot isn't
    -- in the target's zone yet we can't run A* there until after the
    -- teleport. Show a long line from current pos -> target pos so the
    -- user sees the intent. (Once integrated with a real mover, the
    -- second leg's A* runs after teleport completes.)
    local synthetic = {
        vec3:new(pp:x(), pp:y(), pp:z()),
        vec3:new(target.x, target.y, pp:z()),
    }
    visualizer.set_path(synthetic,
        target.skin .. '\n(teleport ' .. (plan.plan[1].name or '?') .. ', then walk)')
    console.print(string.format(
        '[StaticPather] travel plan: %s -> teleport SNO=0x%X (%s) -> walk to (%.1f,%.1f)',
        tostring(current_zone), plan.plan[1].sno, plan.plan[1].name,
        target.x, target.y))
    -- Print the full step list for transparency
    for i, step in ipairs(plan.plan) do
        if step.kind == 'teleport' then
            console.print(string.format(
                '  step %d: TELEPORT to %s (SNO 0x%X)',
                i, step.name, step.sno))
        elseif step.kind == 'walk' then
            console.print(string.format(
                '  step %d: WALK to (%.1f, %.1f) in %s',
                i, step.to_x, step.to_y, step.in_zone))
        end
    end
end

-- ----- Demo: compute path to nearest affordable helltide chest ------------
local function demo_path_to_nearest_chest()
    if not local_player then return end
    if not pather.is_zone_supported() then
        gui.demo_line = 'No curated data for this zone -- fall back to Batmobile.'
        return
    end
    local pp = local_player:get_position()
    local cinders = (get_helltide_coin_cinders and get_helltide_coin_cinders()) or 0
    local target = pather.nearest_affordable_chest(pp, cinders)
    if not target then
        gui.demo_line = string.format(
            'No affordable chest found (cinders=%d). ' ..
            'Try walking through helltide first to populate the actor list.',
            cinders)
        visualizer.clear()
        return
    end
    local goal = vec3:new(target.x, target.y, pp:z())
    local path, stats = pather.find_path(pp, goal)
    if not path then
        gui.demo_line = string.format(
            'Found chest at (%.1f, %.1f) but pathfind failed: %s',
            target.x, target.y, tostring(stats and stats.reason or 'unknown'))
        visualizer.clear()
        return
    end
    local label = string.format('%s\n%d cinders', target.skin or 'Chest', cinders)
    visualizer.set_path(path, label)
    gui.demo_line = string.format(
        'Path to %s @(%.1f,%.1f) -- %d waypoints, A* %dms',
        target.skin or '?', target.x, target.y, #path,
        math.floor((stats and stats.time_ms) or 0))
    console.print('[StaticPather] ' .. gui.demo_line)
end

local function main_pulse()
    settings.update_settings()
    if not local_player then return end
    if not settings.enabled then return end

    -- Handle demo button presses (cheap; usually no-op).
    if gui.demo_chest_pressed then
        gui.demo_chest_pressed = false
        demo_path_to_nearest_chest()
    end
    if gui.demo_clear_pressed then
        gui.demo_clear_pressed = false
        visualizer.clear()
        gui.demo_line = nil
        gui.travel_line = nil
    end
    if gui.travel_request then
        local req = gui.travel_request
        gui.travel_request = nil
        demo_travel(req)
    end

    local now = (get_time_since_inject and get_time_since_inject()) or 0
    if (now - last_pulse_t) < 0.5 then return end
    last_pulse_t = now

    -- Detect zone changes so we can drop stale state and reload.
    local w = get_current_world()
    local zone = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    if zone ~= last_zone then
        if last_zone and settings.debug_mode then
            console.print('[StaticPather] zone change ' .. tostring(last_zone) ..
                ' -> ' .. tostring(zone))
        end
        last_zone = zone
        pather.reload()
        visualizer.clear()    -- old path is no longer valid in the new zone
    end

    refresh_status()
end

-- ---------------------------------------------------------------------------
-- Plugin global. Mirrors pather.lua's API plus a couple of management
-- methods. Other scripts call StaticPatherPlugin.find_path() etc.
-- ---------------------------------------------------------------------------
StaticPatherPlugin = {
    -- Status / introspection
    is_zone_supported = function ()
        if not settings.enabled then return false end
        return pather.is_zone_supported()
    end,
    get_status = pather.get_status,

    -- Pathing primitives.  find_path delegates to the host's
    -- world:calculate_path(); path_to is a player-as-start convenience.
    find_path = pather.find_path,
    path_to   = pather.path_to,

    -- Actor queries
    get_actors    = pather.get_actors,
    nearest_actor = pather.nearest_actor,
    nearest_affordable_chest = pather.nearest_affordable_chest,

    -- Visualization (in-game line drawing). Consumers can push their own
    -- computed paths to render them, or call clear() when done.
    show_path  = visualizer.set_path,
    clear_path = visualizer.clear,

    -- Cross-zone travel API (universal actor index + waypoint graph).
    -- Returns { plan, target } | nil, reason
    plan_travel  = travel.plan,
    plan_to_skin = travel.plan_to_skin,
    plan_to_kind = travel.plan_to_kind,
    travel_stats = travel.stats,
    waypoint_for = world.waypoint_for,

    -- Lifecycle
    reload = function ()
        pather.reload()
        travel.reload()
    end,
    set_pit_floor = pather.set_pit_floor,

    -- Bulk-refresh: re-pull every zone from the server (background).
    -- Same call that runs once at module load; expose for GUI / dev use.
    bulk_fetch = function () pcall(loader.bulk_fetch) end,

    -- Plugin enable/disable so WarMachine can toggle remotely if it wants.
    enable = function ()
        gui.elements.main_toggle:set(true)
        settings.update_settings()
    end,
    disable = function ()
        gui.elements.main_toggle:set(false)
        settings.update_settings()
    end,
}

-- ---------------------------------------------------------------------------
-- Forward-compat alias.  StaticPather is being renamed to WarPath; new
-- code should reference WarPathPlugin.  StaticPatherPlugin stays in
-- place so existing consumers (WarMachine activities) keep working
-- through the transition.  Eventually the folder + canonical name swap
-- happens and we can drop the alias.
-- ---------------------------------------------------------------------------
WarPathPlugin = StaticPatherPlugin

on_update(function ()
    update_locals()
    main_pulse()
end)

on_render_menu(gui.render)
on_render(function ()
    if not settings.enabled then return end
    visualizer.render()
end)
