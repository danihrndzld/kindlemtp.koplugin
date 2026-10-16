-- Fake env for kindlemtp_core.lua: a scripted Kindle that records every side effect in order.
local Mtp = require("kindlemtp_core")

local F = {}

function F.fixture(name)
    local f = assert(io.open("spec/fixtures/" .. name, "rb"))
    local text = f:read("*a")
    f:close()
    return text
end

local function lines(text)
    local out = {}
    for l in text:gmatch("[^\n]+") do out[#out + 1] = l end
    return out
end

--- Rows of a UDC tape fixture: { t, udc, state, started }.
function F.tape(name)
    local rows = {}
    for _, l in ipairs(lines(F.fixture(name))) do
        local t, udc, state, started = l:match("^t=(%S+) udc=%[(.-)%] state=(.-) started=(%d)$")
        if t then
            rows[#rows + 1] = { t = tonumber(t), udc = udc, state = state, started = tonumber(started) }
        end
    end
    return rows
end

-- A line from an earlier session, before the baseline: must never count as a host.
F.OLD_STATE2 = "261015:180102 mtp-responder[5225]: handled state_change_event [12] event [2] current mtp state"

function F.new()
    local e = {
        calls = {},
        logs = {},
        exists_set = { [Mtp.MTP_SH] = true, [Mtp.GADGET] = true, [Mtp.DBUS_SEND] = true },
        contents = {},
        vars = { VOLUMD_STOPPED = "yes" },
        props = { ["com.lab126.mtp isMtpStarted"] = 0, ["com.lab126.powerd preventScreenSaver"] = 0 },
        pids = { ["tizen-mtp"] = "5225", volumd = "2187" },
        listnames = F.fixture("listnames_with_mtp.txt"),
        listnames_ok = true,
        getpid = { [":1.3"] = F.fixture("getpid_tizen_mtp.txt") },
        syslog = { "261015:180059 kernel: [100.1] mtu3 11211000.usb: gadget RESET", F.OLD_STATE2 },
        udc = "",
        udc_state = "not attached",
        is_charging = true,
        t = 0,
        signal_ok = true,
        start_ok = true,
        write_ok = true,
        restart_ok = true,
        wc_ok = true,
        lipc_dead = false,
    }

    local function rec(kind, text)
        e.calls[#e.calls + 1] = { kind = kind, text = text, state = e.core and e.core.state }
    end

    function e.sh(cmd)
        rec("sh", cmd)
        local pidof = cmd:match("^pidof (%S+)$")
        if pidof then
            local p = e.pids[pidof]
            return p and (p .. "\n") or "", p ~= nil
        end
        if cmd:find("ListNames", 1, true) then
            return e.listnames, e.listnames_ok
        end
        local name = cmd:match("GetConnectionUnixProcessID string:(%S+)$")
        if name then
            local reply = e.getpid[name] or F.fixture("getpid_other.txt")
            return reply, not reply:find("^Error")
        end
        if cmd:find("--type=signal", 1, true) then
            return "", e.signal_ok
        end
        if cmd == Mtp.MTP_SH .. " udc disable" then
            e.udc = ""
            return "", true
        end
        if cmd == "wc -l < " .. Mtp.SYSLOG then
            if not e.wc_ok then return "", false end
            return "    " .. #e.syslog .. "\n", true
        end
        if cmd:find("^cat " .. Mtp.GADGET .. "/UDC") then
            local from = tonumber(cmd:match("tail %-n %+(%d+)"))
            local new = {}
            for i = from, #e.syslog do
                if e.syslog[i]:find("mtp-responder", 1, true) then new[#new + 1] = e.syslog[i] end
            end
            local log = #new > 0 and (table.concat(new, "\n") .. "\n") or ""
            return e.udc .. "\n@@\n" .. #e.syslog .. "\n@@\n" .. log, #new > 0
        end
        if cmd == "restart mtp" then
            return "mtp start/running, process 6001\n", e.restart_ok
        end
        if cmd == "cat /sys/class/udc/*/state 2>/dev/null" then
            return e.udc_state .. "\n", true
        end
        error("unexpected command: " .. cmd)
    end

    e.lipc = {
        set_int = function(pub, prop, v)
            rec("set", pub .. " " .. prop .. " " .. v)
            if prop == "startMtp" then
                if not e.start_ok then return false end
                e.props["com.lab126.mtp isMtpStarted"] = 1
            elseif prop == "stopMtp" then
                e.props["com.lab126.mtp isMtpStarted"] = 0
            else
                e.props[pub .. " " .. prop] = v
            end
            return true
        end,
        get_int = function(pub, prop)
            rec("get", pub .. " " .. prop)
            if e.lipc_dead then return nil end
            return e.props[pub .. " " .. prop]
        end,
    }

    function e.read(path)
        rec("read", path)
        return e.contents[path]
    end

    function e.write(path, text, exclusive)
        rec("write", path .. " " .. text:gsub("\n$", "") .. (exclusive and " exclusive" or ""))
        if not e.write_ok or (exclusive and e.contents[path]) then return false end
        e.contents[path] = text
        return true
    end

    function e.remove(path)
        rec("remove", path)
        e.contents[path] = nil
    end

    function e.exists(path) return e.exists_set[path] == true end
    function e.getenv(name) return e.vars[name] end
    function e.charging() return e.is_charging end
    function e.now() return e.t end
    function e.log(level, msg) e.logs[#e.logs + 1] = level .. " " .. msg end

    --- Side effects only (sh, lipc set, write, remove) as "kind text" strings.
    function e.actions(from)
        local out = {}
        for i = from or 1, #e.calls do
            local c = e.calls[i]
            if c.kind ~= "get" and c.kind ~= "read" then out[#out + 1] = c.kind .. " " .. c.text end
        end
        return out
    end

    function e.count(pattern)
        local n = 0
        for _, c in ipairs(e.calls) do
            if c.text:find(pattern, 1, true) then n = n + 1 end
        end
        return n
    end

    function e.signals()
        local out = {}
        for _, c in ipairs(e.calls) do
            if c.kind == "sh" and c.text:find("driveModeStateChanged", 1, true) then out[#out + 1] = c.text end
        end
        return out
    end

    function e.apply(row)
        e.t, e.udc, e.udc_state = row.t, row.udc, row.state
        e.props["com.lab126.mtp isMtpStarted"] = row.started
    end

    function e.append_log(text)
        for _, l in ipairs(lines(text)) do e.syslog[#e.syslog + 1] = l end
    end

    return e
end

--- A core attached to a fresh fake env.
function F.core(setup)
    local e = F.new()
    if setup then setup(e) end
    local core = Mtp.new(e, { pid = 4321 })
    e.core = core
    return core, e
end

--- A core in waiting_host at t = 0.
function F.waiting(setup)
    local core, e = F.core(setup)
    assert(core:start())
    return core, e
end

--- A core in connected (host seen through syslog at t = 0.5).
function F.connected(setup)
    local core, e = F.waiting(setup)
    e.t = 0.5
    e.append_log(F.fixture("syslog_state2.txt"))
    assert(core:poll() == "connected")
    return core, e
end

return F
