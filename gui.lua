-- ---------------------------------------------------------------------------
-- WarPath GUI -- minimal toggle + live status panel.
--
-- Naming history: this plugin was originally StaticPather.  On rename
-- to WarPath we kept `plugin_label = 'static_pather'` as the GUI-state
-- hash seed so users' existing checkbox states (main toggle, debug
-- mode) survive the rename.  Changing the label would silently
-- invalidate every saved hash and reset toggles.  All user-visible
-- strings now read "WarPath".
--
-- Why no demo / travel buttons here:  WarPath is a *library* plugin --
-- its real surface is the WarPathPlugin (alias: StaticPatherPlugin)
-- global table consumed by sibling plugins (WarMachine activities,
-- the future nightmare runner, etc.).  The earlier demo / travel
-- sub-trees were dev-time test harnesses; they didn't fit production
-- use, didn't always work, and confused users into thinking the
-- plugin needed manual driving.  Removed entirely -- the API is
-- the supported way to invoke pathfinding / travel planning.
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

gui.elements = {
    main_tree   = tree_node:new(0),
    main_toggle = cb(false, 'main_toggle'),
    debug_mode  = cb(false, 'debug_mode'),
}

gui.status_line = '(disabled)'

gui.render = function ()
    if not gui.elements.main_tree:push('WarPath v' .. plugin_version) then return end
    gui.elements.main_toggle:render('Enable',
        'Master toggle.  While ON, exposes WarPathPlugin (alias: ' ..
        'StaticPatherPlugin for backward compat) globally so sibling ' ..
        'scripts can query precomputed walkability + cross-zone travel ' ..
        'plans without going through Batmobile.  Pure library plugin -- ' ..
        'no UI driving required, just enable and let the consumers use it.')
    render_menu_header(gui.status_line)
    gui.elements.debug_mode:render('Debug logging',
        'Verbose console output: zone-change loads, A* timings, travel ' ..
        'plan step-by-step.')
    gui.elements.main_tree:pop()
end

return gui
