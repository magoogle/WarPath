local gui = require 'gui'

local settings = {
    plugin_label   = gui.plugin_label,
    plugin_version = gui.plugin_version,
    enabled    = false,
    debug_mode = false,
}

settings.update_settings = function ()
    settings.enabled    = gui.elements.main_toggle:get()
    settings.debug_mode = gui.elements.debug_mode:get()
end

return settings
