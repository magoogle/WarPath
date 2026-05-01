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

local function main_pulse()
    settings.update_settings()
    if not local_player then return end
    if not settings.enabled then return end

    local now = (get_time_since_inject and get_time_since_inject()) or 0
    if (now - last_pulse_t) < 0.5 then return end
    last_pulse_t = now

    -- Detect zone changes so we can drop stale state and reload.
    local w = get_current_world()
    local zone = w and w.get_current_zone_name and w:get_current_zone_name() or nil
    if zone ~= last_zone then
        if last_zone and settings.debug_mode then
            console.print('[WarPath] zone change ' .. tostring(last_zone) ..
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
