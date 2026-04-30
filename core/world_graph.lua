-- ---------------------------------------------------------------------------
-- World graph -- catalog of zones we can travel TO, with the waypoint SNO
-- the game accepts for `teleport_to_waypoint(sno)` calls.
--
-- This is currently a hardcoded seed sourced from existing sub-plugin data
-- (HelltideRevamped/enums.lua, ArkhamAsylum/teleport_cerrigar.lua, etc).
-- Future improvement: have the merger learn this from session transitions
-- and emit it as data/world_graph.json the way the actor index works.
--
-- A zone entry exists if we know how to teleport TO it. If a zone is in
-- the actor index but NOT here, we know things ARE there but we can't
-- get the player there directly -- the planner will fail cleanly.
-- ---------------------------------------------------------------------------

local M = {}

-- Hex SNOs from existing scripts. Decimal values shown for clarity.
M.zones = {
    -- Towns / hubs
    Scos_Cerrigar = {
        name        = 'Cerrigar',
        kind        = 'town',
        waypoint_sno = 0x76D58,      -- 486232
    },
    Naha_KurastDocks = {
        name        = 'Kurast Bazar',
        kind        = 'town',
        waypoint_sno = 0x1EAACC,     -- 2009804
    },

    -- Helltide-region waypoints (sourced from
    -- HelltideRevamped/data/enums.lua's helltide_tps table)
    Frac_Tundra_S = {
        name        = 'Menestad',
        kind        = 'overworld',
        region      = 'Frac_',
        waypoint_sno = 0xACE9B,      -- 708763
    },
    Scos_Coast = {
        name        = 'Marowen',
        kind        = 'overworld',
        region      = 'Scos_',
        waypoint_sno = 0x27E01,      -- 163329
    },
    Kehj_Oasis = {
        name        = 'Iron Wolves Camp',
        kind        = 'overworld',
        region      = 'Kehj_',
        waypoint_sno = 0xDEAFC,      -- 911100
    },
    Hawe_Verge = {
        name        = 'Wejinhani',
        kind        = 'overworld',
        region      = 'Hawe_',
        waypoint_sno = 0x9346B,      -- 603243
    },
    Step_South = {
        name        = 'Jirandai',
        kind        = 'overworld',
        region      = 'Step_',
        waypoint_sno = 0x462E2,      -- 287970
    },

    -- TODO: Skov_Temis SNO unknown. Once discovered (search via brute-
    -- force or future API exposure), add it here and the planner can
    -- automatically route to S07 town.
    Skov_Temis = {
        name        = 'Temis',
        kind        = 'town',
        waypoint_sno = nil,           -- not yet discovered
        notes       = 'S07 main hub. Add SNO once known.',
    },
}

-- Returns waypoint SNO for `zone_name`, or nil if unknown.
M.waypoint_for = function (zone_name)
    if not zone_name then return nil end
    local z = M.zones[zone_name]
    return z and z.waypoint_sno or nil
end

-- Returns true if we have a teleport edge into this zone.
M.can_teleport_to = function (zone_name)
    return M.waypoint_for(zone_name) ~= nil
end

-- Returns the zone whose `region` prefix matches the given zone name.
-- Useful for "I'm in some Hawe_* zone, what's the nearest waypoint?"
M.nearest_waypoint_zone = function (current_zone)
    if not current_zone then return nil end
    -- First exact match
    if M.zones[current_zone] and M.zones[current_zone].waypoint_sno then
        return current_zone
    end
    -- Region prefix match (e.g. 'Hawe_' covers all Hawe_* helltide zones)
    for zname, z in pairs(M.zones) do
        if z.region and current_zone:sub(1, #z.region) == z.region
           and z.waypoint_sno
        then
            return zname
        end
    end
    return nil
end

-- Pretty list of teleportable zones (for GUI dropdowns).
M.teleportable_zones = function ()
    local out = {}
    for zname, z in pairs(M.zones) do
        if z.waypoint_sno then
            out[#out + 1] = { zone = zname, name = z.name, kind = z.kind }
        end
    end
    table.sort(out, function (a, b) return a.zone < b.zone end)
    return out
end

return M
