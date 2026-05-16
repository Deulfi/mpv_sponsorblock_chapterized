-- Simple plugin to create a uosc button to toggle the sponsorblock_chapterized script
-- needs uosc_controls_modifier.lua  https://github.com/Deulfi/uosc-controls-modifier
-- and add to your uosc.conf control=
--  button:Sponsorblock_Button
-- and set use_ucm_plugin to yes in sponsorblock_chapterized.conf
local mp = require 'mp'
mp.utils = require "mp.utils"

local button_name = "Sponsorblock_Button"

local button = {
    state_1 = {
        icon = "shield",
        tooltip = "Sponsorblock",
        command = "script-message sponsorblock toggle",
        badge = nil,
        hide = "true"
    },
    state_2 = {
        tooltip = "Manual pull",
        command = "script-message-to sponsorblock_chapterized manual_sponsorblock_pull",
        badge = "false", -- otherwise it would inherit from state_1
        hide = false
    },
}

mp.register_script_message('update-icon', function(state, num_seg_found)
    mp.msg.debug("update-icon sponsorblock enabled:", state, "segements:", num_seg_found)
    button.state_1.icon = (state == "true") and "shield" or "remove_moderator"
    button.state_1.hide = false
    button.state_1.badge = num_seg_found
    mp.commandv('script-message-to', 'uosc_controls_modifier', 'set-button', button_name, mp.utils.format_json(button))
end)

-- Register message handler
mp.register_script_message('ucm_ready', function(_)
    local result = mp.commandv('script-message-to', 'uosc_controls_modifier', 'set-button', button_name, mp.utils.format_json(button))

    if result then
        mp.msg.info("Button created/updated")
    else
        mp.msg.error("Button creation failed")
    end

end)



