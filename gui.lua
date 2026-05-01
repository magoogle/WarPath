-- ---------------------------------------------------------------------------
-- WarPath GUI -- toggle + live status panel showing whether the
-- current zone has curated data loaded.
--
-- Naming history: this plugin was originally StaticPather; on rename
-- to WarPath we kept `plugin_label = 'static_pather'` as the GUI-state
-- hash seed so users' existing checkbox states (main toggle, debug
-- mode, etc.) survive the rename.  Changing the label would invalidate
-- those saved hashes and reset every toggle silently.  All user-
-- facing strings now read "WarPath".
-- ---------------------------------------------------------------------------

local plugin_label   = 'static_pather'
local plugin_version = '0.2'
console.print('Lua Plugin - WarPath v' .. plugin_version)

local gui = {}

local function cb(default, key)
    return checkbox:new(default, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

local function btn(key)
    return button:new(get_hash(plugin_label .. '_' .. key))
end

gui.elements = {
    main_tree           = tree_node:new(0),
    main_toggle         = cb(false, 'main_toggle'),
    debug_mode          = cb(false, 'debug_mode'),
    demo_tree           = tree_node:new(1),
    demo_btn_chest      = btn('demo_chest'),
    demo_btn_clear      = btn('demo_clear'),
    travel_tree         = tree_node:new(1),
    travel_btn_pit      = btn('travel_pit_obelisk'),
    travel_btn_uc       = btn('travel_undercity_obelisk'),
    travel_btn_tyrael   = btn('travel_tyrael'),
    travel_btn_warplans = btn('travel_warplans'),
    travel_btn_blacksmith = btn('travel_blacksmith'),
    travel_btn_alchemist  = btn('travel_alchemist'),
    travel_btn_healer     = btn('travel_healer'),
}

gui.status_line = '(disabled)'
gui.demo_line   = nil
gui.travel_line = nil

gui.demo_chest_pressed = false
gui.demo_clear_pressed = false
gui.travel_request     = nil   -- { kind = 'kind', value = 'pit_obelisk' } or { kind = 'skin', value = 'Blacksmith' }

gui.render = function ()
    if not gui.elements.main_tree:push('WarPath v' .. plugin_version) then return end
    gui.elements.main_toggle:render('Enable',
        'Master toggle. While ON, exposes WarPathPlugin (alias: ' ..
        'StaticPatherPlugin for backward compat) globally so other ' ..
        'scripts can query precomputed walkability + paths instead ' ..
        'of going through Batmobile.')
    render_menu_header(gui.status_line)

    if gui.elements.demo_tree:push('Demo: nearest chest') then
        render_menu_header('Helltide-only. Reads cinder count, finds nearest ' ..
            'affordable chest, plots A* path, draws it on screen for 60s.')
        if gui.elements.demo_btn_chest:render('Path to nearest chest', '') then
            gui.demo_chest_pressed = true
        end
        if gui.elements.demo_btn_clear:render('Clear path', '') then
            gui.demo_clear_pressed = true
        end
        if gui.demo_line then
            render_menu_header(gui.demo_line)
        end
        gui.elements.demo_tree:pop()
    end

    if gui.elements.travel_tree:push('Travel to (cross-zone)') then
        render_menu_header('Find an actor anywhere in the curated data and ' ..
            'plot a route. Uses teleport_to_waypoint when target is in a ' ..
            'different zone, then A* to the actor.')

        if gui.elements.travel_btn_pit:render('Pit Obelisk', '') then
            gui.travel_request = { kind = 'kind', value = 'pit_obelisk' }
        end
        if gui.elements.travel_btn_uc:render('Undercity Obelisk', '') then
            gui.travel_request = { kind = 'kind', value = 'undercity_obelisk' }
        end
        if gui.elements.travel_btn_warplans:render('War Plans Vendor', '') then
            gui.travel_request = { kind = 'kind', value = 'warplans_vendor' }
        end
        if gui.elements.travel_btn_tyrael:render('Tyrael', '') then
            gui.travel_request = { kind = 'kind', value = 'tyrael' }
        end
        if gui.elements.travel_btn_blacksmith:render('Blacksmith', '') then
            gui.travel_request = { kind = 'skin', value = 'Blacksmith' }
        end
        if gui.elements.travel_btn_alchemist:render('Alchemist', '') then
            gui.travel_request = { kind = 'skin', value = 'Alchemist' }
        end
        if gui.elements.travel_btn_healer:render('Healer', '') then
            gui.travel_request = { kind = 'skin', value = 'Healer' }
        end

        if gui.travel_line then
            render_menu_header(gui.travel_line)
        end
        gui.elements.travel_tree:pop()
    end

    gui.elements.debug_mode:render('Debug logging',
        'Verbose console output: zone-change loads, A* timings.')
    gui.elements.main_tree:pop()
end

return gui
