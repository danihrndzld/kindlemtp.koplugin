-- Loads kindlemtp.koplugin/main.lua with stub KOReader modules and the fake device env.
-- Every UI effect is appended to k.log in order, next to the device commands in e.calls.
local F = require("fake_env")

local S = {}

local STUBBED = {
    "device", "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/infomessage",
    "ui/widget/container/widgetcontainer", "pluginshare", "ui/uimanager", "logger", "ui/time",
    "gettext", "apps/filemanager/filemanager", "kindlemtp_core",
}

local function widget(k, class)
    return {
        new = function(_, t)
            t = t or {}
            t.class = class
            function t.setTitle(self, title)
                self.title = title
                k.log[#k.log + 1] = "title " .. title
            end
            return t
        end,
    }
end

--- opts: kindle (default true), autostart, keepalive (PluginShare.keepalive before start), setup(e).
function S.load(opts)
    opts = opts or {}
    local k = { log = {}, scheduled = {}, settings = { kindlemtp_autostart = opts.autostart }, charging = true }
    local e = F.new()
    if opts.setup then opts.setup(e) end
    k.share = { keepalive = opts.keepalive }
    k.fm = {
        file_chooser = { refreshPath = function() k.log[#k.log + 1] = "refreshPath" end },
    }

    for _, name in ipairs(STUBBED) do package.loaded[name] = nil end
    package.preload["device"] = function()
        return {
            isKindle = function() return opts.kindle ~= false end,
            getPowerDevice = function() return { isCharging = function() return k.charging end } end,
        }
    end
    package.preload["ui/widget/buttondialog"] = function() return widget(k, "ButtonDialog") end
    package.preload["ui/widget/confirmbox"] = function() return widget(k, "ConfirmBox") end
    package.preload["ui/widget/infomessage"] = function() return widget(k, "InfoMessage") end
    package.preload["ui/widget/container/widgetcontainer"] = function()
        return {
            extend = function(_, class)
                class.new = function(cls, o) return setmetatable(o or {}, { __index = cls }) end
                return class
            end,
        }
    end
    package.preload["pluginshare"] = function() return k.share end
    package.preload["logger"] = function()
        local noop = function() end
        return { info = noop, warn = noop, dbg = noop, err = noop }
    end
    package.preload["ui/time"] = function() return { to_number = function(t) return t end } end
    package.preload["gettext"] = function() return function(s) return s end end
    k.FileManager = { instance = k.fm }
    package.preload["apps/filemanager/filemanager"] = function() return k.FileManager end
    package.preload["ui/uimanager"] = function()
        return {
            show = function(_, w)
                k.log[#k.log + 1] = "show " .. w.class .. " " .. (w.title or w.text or "")
                k.top = w
            end,
            close = function(_, w) k.log[#k.log + 1] = "close " .. w.class end,
            scheduleIn = function(_, s, f) k.scheduled[#k.scheduled + 1] = { s = s, f = f } end,
            unschedule = function(_, f)
                for i = #k.scheduled, 1, -1 do
                    if k.scheduled[i].f == f then table.remove(k.scheduled, i) end
                end
            end,
            flushSettings = function() k.log[#k.log + 1] = "flush at call " .. #e.calls end,
            forceRePaint = function() k.log[#k.log + 1] = "repaint at call " .. #e.calls end,
            getElapsedTimeSinceBoot = function() return e.t end,
        }
    end
    package.preload["kindlemtp_core"] = function()
        package.preload["kindlemtp_core"] = nil
        package.loaded["kindlemtp_core"] = nil
        local Mtp = require("kindlemtp_core")
        Mtp.posix_env = function() return e end
        local new = Mtp.new
        Mtp.new = function(env, o)
            local core = new(env, o)
            e.core, k.core = core, core
            return core
        end
        return Mtp
    end
    rawset(_G, "G_reader_settings", {
        isTrue = function(_, key) return k.settings[key] == true end,
        flipNilOrFalse = function(_, key) k.settings[key] = not k.settings[key] end,
    })

    local Plugin = dofile("kindlemtp.koplugin/main.lua")
    for _, name in ipairs(STUBBED) do package.loaded[name] = nil end

    --- A plugin instance; document = true gives a reader instance.
    function k.instance(document)
        local inst = Plugin:new{ ui = { document = document and {} or nil,
            menu = { registerToMainMenu = function() end } } }
        inst:init()
        local items = {}
        inst:addToMainMenu(items)
        inst.menu = items.kindlemtp
        return inst
    end

    --- Runs the first scheduled function and returns its delay.
    function k.run_next()
        local job = table.remove(k.scheduled, 1)
        job.f()
        return job.s
    end

    --- Runs every scheduled function (the delayed refresh, for instance).
    function k.run_all()
        while #k.scheduled > 0 do k.run_next() end
    end

    function k.has(prefix)
        for _, l in ipairs(k.log) do
            if l:sub(1, #prefix) == prefix then return true end
        end
        return false
    end

    return Plugin, k, e
end

return S
