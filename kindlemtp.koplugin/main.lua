--[[--
USB file transfer (MTP) for KOReader on MTP-era Kindles.

Thin widget layer: menu, events, dialogs and scheduling. The device logic is in mtp.lua.
The core, the dialog and the poll function are module-level: plugin instances die on every
file manager <-> reader switch, and UIManager:unschedule() needs the same function reference.
]]

local Device = require("device")

if not Device:isKindle() then
    return { disabled = true, }
end

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local Mtp = require("mtp")

-- Wait after Charging before an auto-start, so the responder has seen the cable (usb_plugin) first.
local AUTOSTART_DELAY = 2

local function ownPid()
    local f = io.open("/proc/self/stat", "r")
    if not f then return 0 end
    local pid = f:read("*n")
    f:close()
    return pid or 0
end

local core = Mtp.new(Mtp.posix_env{
    charging = function() return Device:getPowerDevice():isCharging() end,
    now = function() return time.to_number(UIManager:getElapsedTimeSinceBoot()) end,
    log = function(level, msg) logger[level](msg) end,
}, { pid = ownPid() })

local REASONS = {
    not_kindle = _("This device is not a Kindle."),
    no_mtp_sh = _("/usr/bin/mtp.sh is missing. This Kindle does not use MTP (firmware 5.16 or later is needed)."),
    no_gadget = _("The MTP USB gadget (/sys/kernel/config/usb_gadget/mtpgadget) is missing."),
    no_responder = _("The MTP responder (tizen-mtp) is not running. Try \"Reset the USB responder\"."),
    no_dbus_send = _("/usr/bin/dbus-send is missing."),
    no_lipc = _("The MTP responder does not answer over lipc (com.lab126.mtp isMtpStarted)."),
    volumd_running = _("volumd is running, so the Kindle already handles USB itself. Launch KOReader from KUAL to use this plugin."),
    book_open = _("Close the book first. KOReader rewrites the book's settings while it is open."),
    no_power = _("Connect the USB cable to the computer first."),
    already_active = _("A USB transfer is already active. If it was left over by a crash, use \"Reset the USB responder\"."),
    owner_other = _("Another app (KOBridge) is running a USB transfer. Stop it there first."),
    bus_name_not_found = _("Could not find the MTP responder on D-Bus."),
    startmtp_failed = _("The MTP responder refused startMtp."),
    marker_failed = _("Could not create /tmp/kindlemtp.active."),
    signal_failed = _("dbus-send failed to switch the responder to drive mode."),
    restart_failed = _("Restarting the MTP responder (restart mtp) failed."),
    timeout = _("No computer answered within 20 seconds. Check that the cable carries data and that the computer is awake."),
}

local CHECK_LABELS = {
    not_kindle = _("Kindle"),
    no_mtp_sh = _("/usr/bin/mtp.sh"),
    no_gadget = _("MTP USB gadget"),
    no_responder = _("tizen-mtp running"),
    no_dbus_send = _("/usr/bin/dbus-send"),
    no_lipc = _("lipc answers"),
    volumd_running = _("volumd stopped"),
}

local probe_result = core:probe(true)
logger.info("kindlemtp: probe at load:", probe_result.ok and "ok" or probe_result.reason)

local dialog, auto_started, saved_share, tick

local function showReason(reason)
    UIManager:show(InfoMessage:new{
        icon = "notice-warning",
        text = REASONS[reason] or reason,
    })
end

-- preventScreenSaver is handled by mtp.lua; these keep KOReader's own timers off.
local function keepAwake()
    if saved_share then return end
    saved_share = { pause = PluginShare.pause_auto_suspend, keepalive = PluginShare.keepalive }
    PluginShare.pause_auto_suspend = true
    PluginShare.keepalive = true
end

local function releaseAwake()
    if not saved_share then return end
    PluginShare.pause_auto_suspend = saved_share.pause
    PluginShare.keepalive = saved_share.keepalive
    saved_share = nil
end

local function refreshFileManager()
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    if fm and fm.file_chooser and not fm.tearing_down then
        fm.file_chooser:refreshPath()
    end
end

local function finish(reason)
    UIManager:unschedule(tick)
    releaseAwake()
    if dialog then
        UIManager:close(dialog)
        dialog = nil
    end
    refreshFileManager()
    if reason and not (reason == "timeout" and auto_started) then
        showReason(reason)
    end
end

tick = function()
    local event, reason = core:poll()
    if core:active() then
        if event == "connected" and dialog then
            dialog:setTitle(_("Connected. Your computer can see the Kindle's files."))
        end
        UIManager:scheduleIn(Mtp.POLL_INTERVAL, tick)
    elseif event == "failed" then
        finish(reason)
    elseif event == "timeout" then
        finish("timeout")
    else
        finish()
    end
end

local function startTransfer(ui, auto)
    if core:active() then return end
    local function refuse(reason)
        logger.info("kindlemtp: start refused:", reason)
        if not auto then showReason(reason) end
    end
    if ui.document then return refuse("book_open") end
    probe_result = core:probe(true)
    if not probe_result.ok then return refuse(probe_result.reason) end

    UIManager:flushSettings()
    keepAwake()
    local ok, err = core:start()
    if not ok then
        releaseAwake()
        return refuse(err)
    end
    auto_started = auto
    dialog = ButtonDialog:new{
        title = _("Waiting for the computer…"),
        dismissable = false,
        buttons = {{{
            text = _("Stop transfer"),
            callback = function()
                core:stop()
                finish()
            end,
        }}},
    }
    UIManager:show(dialog)
    UIManager:unschedule(tick)
    UIManager:scheduleIn(Mtp.POLL_INTERVAL, tick)
end

local function stopOn(event)
    local active = core:active()
    local udc_configured = event == "NotCharging" and active and core:udc_configured()
    if Mtp.stop_trigger(event, active, udc_configured) then
        logger.info("kindlemtp: stopping on", event)
        core:stop()
        finish()
    end
end

local function aboutText()
    local lines = {
        _("Lets a computer browse and copy the Kindle's files over the USB cable (MTP) while KOReader runs."),
        "",
        _("Device checks:"),
    }
    for i = 1, #probe_result.checks do
        local c = probe_result.checks[i]
        table.insert(lines, CHECK_LABELS[c.reason] .. ": " .. (c.ok and _("OK") or _("failed")))
    end
    if not probe_result.ok then
        table.insert(lines, "")
        table.insert(lines, REASONS[probe_result.reason])
    end
    return table.concat(lines, "\n")
end

local KindleMTP = WidgetContainer:extend{
    name = "kindlemtp",
    is_doc_only = false,
}

function KindleMTP:init()
    self.ui.menu:registerToMainMenu(self)
end

function KindleMTP:addToMainMenu(menu_items)
    menu_items.kindlemtp = {
        text = _("USB file transfer (MTP)"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text = _("Start USB file transfer"),
                enabled_func = function() return self.ui.document == nil end,
                help_text = _("Lets a computer browse and copy the Kindle's files over the USB cable. Works only from the file browser: close the book first."),
                callback = function()
                    startTransfer(self.ui, false)
                end,
            },
            {
                text = _("Start when plugged in"),
                checked_func = function() return G_reader_settings:isTrue("kindlemtp_autostart") end,
                help_text = _("Starts the transfer when a cable is plugged in while the file browser is open. KOReader cannot tell a computer from a wall charger, so on a charger the transfer stops by itself after 20 seconds."),
                callback = function()
                    G_reader_settings:flipNilOrFalse("kindlemtp_autostart")
                end,
                separator = true,
            },
            {
                text = _("Reset the USB responder"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Restart the MTP responder (tizen-mtp) and unbind the USB gadget?\n\nUse this when the computer no longer sees the Kindle, or after KOReader crashed during a transfer."),
                        ok_text = _("Reset"),
                        ok_callback = function()
                            local ok, err = core:reset()
                            finish(not ok and err or nil)
                            if ok then
                                UIManager:show(InfoMessage:new{
                                    text = _("The USB responder was reset."),
                                    timeout = 3,
                                })
                            end
                        end,
                    })
                end,
            },
            {
                text = _("About"),
                keep_menu_open = true,
                callback = function()
                    probe_result = core:probe(true)
                    UIManager:show(InfoMessage:new{ text = aboutText() })
                end,
            },
        },
    }
end

function KindleMTP:onCharging()
    local in_fm = self.ui.document == nil
    if not Mtp.should_autostart(G_reader_settings:isTrue("kindlemtp_autostart"), in_fm, core:active()) then
        return
    end
    UIManager:scheduleIn(AUTOSTART_DELAY, function()
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        if fm and not core:active() and Device:getPowerDevice():isCharging() then
            startTransfer(fm, true)
        end
    end)
end

function KindleMTP:onNotCharging()
    stopOn("NotCharging")
end

function KindleMTP:onSuspend()
    stopOn("Suspend")
end

function KindleMTP:onCloseWidget()
    stopOn("CloseWidget")
end

function KindleMTP:stopPlugin()
    stopOn("stopPlugin")
    return true
end

return KindleMTP
