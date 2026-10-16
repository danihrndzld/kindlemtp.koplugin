-- State machine of mtp.lua: transitions, the recipe's command order, timeout boundaries, marker contract.
local Mtp = require("mtp")
local F = require("fake_env")

local LIST_NAMES = "sh /usr/bin/dbus-send --system --print-reply --dest=org.freedesktop.DBus"
    .. " /org/freedesktop/DBus org.freedesktop.DBus.ListNames"
local SIGNAL = "/usr/bin/dbus-send --system --dest=com.lab126.mtp --type=signal /default"
    .. " com.lab126.volumd.driveModeStateChanged int32:1"
local STOP = {
    "set com.lab126.mtp stopMtp 1",
    "sh /usr/bin/mtp.sh udc disable",
    "set com.lab126.powerd preventScreenSaver 0",
    "remove /tmp/kindlemtp.active",
}

-- State the core was in at the last call matching `text`.
local function state_at(e, text)
    local state
    for _, c in ipairs(e.calls) do
        if c.kind .. " " .. c.text == text then state = c.state end
    end
    return state
end

local function host(e)
    e.append_log(F.fixture("syslog_state2.txt"))
end

local function marker(e, owner)
    e.contents[Mtp.MARKER] = "owner=" .. owner .. " pid=900 since=1760557000\n"
end

describe("start", function()
    it("ST-T1 idle -> starting -> waiting_host", function()
        local core, e = F.core()
        assert.are.equal("idle", core.state)
        assert.is_true(core:start())
        assert.are.equal("waiting_host", core.state)
        assert.are.equal("starting", state_at(e, "set com.lab126.mtp startMtp 1"))
    end)

    it("AC-01 start sends the recipe in order: lookup, reset, line count, startMtp, marker, keep-awake", function()
        local core, e = F.core()
        core:start()
        local a = e.actions()
        assert.are.equal(7, #a)
        assert.are.equal(LIST_NAMES, a[1])
        assert.are.equal("sh /usr/bin/mtp.sh udc disable", a[2])
        assert.are.equal("set com.lab126.mtp stopMtp 1", a[3])
        assert.are.equal("sh wc -l < /var/log/messages", a[4])
        assert.are.equal("set com.lab126.mtp startMtp 1", a[5])
        assert.matches("^write /tmp/kindlemtp%.active owner=plugin pid=4321 since=%d+ exclusive$", a[6])
        assert.are.equal("set com.lab126.powerd preventScreenSaver 1", a[7])
    end)

    it("AC-09 marker is one line, written exclusively", function()
        local _, e = F.waiting()
        local text = e.contents[Mtp.MARKER]
        assert.matches("^owner=plugin pid=4321 since=%d+\n$", text)
        assert.are.equal("plugin", Mtp.parse_marker(text).owner)
    end)

    it("DT-R50 valid marker of the plugin refuses with already_active", function()
        local core, e = F.core(function(e)
            marker(e, "plugin")
            e.props["com.lab126.mtp isMtpStarted"] = 1
        end)
        assert.are.same({ nil, "already_active" }, { core:start() })
        assert.are.same({}, e.actions())
    end)

    it("DT-R51 valid marker of KOBridge refuses with owner_other", function()
        local core, e = F.core(function(e)
            marker(e, "kobridge")
            e.props["com.lab126.mtp isMtpStarted"] = 1
        end)
        assert.are.same({ nil, "owner_other" }, { core:start() })
        assert.are.same({}, e.actions())
    end)

    it("DT-R52 malformed marker while the responder runs refuses with owner_other", function()
        local core = F.core(function(e)
            e.contents[Mtp.MARKER] = "garbage\n"
            e.props["com.lab126.mtp isMtpStarted"] = 1
        end)
        assert.are.same({ nil, "owner_other" }, { core:start() })
    end)

    it("DT-R53 stale marker (isMtpStarted 0) is removed and start goes on", function()
        local core, e = F.core(function(e) marker(e, "kobridge") end)
        assert.is_true(core:start())
        assert.are.equal("remove /tmp/kindlemtp.active", e.actions()[1])
        assert.are.equal("plugin", Mtp.parse_marker(e.contents[Mtp.MARKER]).owner)
    end)

    it("DT-R54 no power refuses with no_power and touches nothing", function()
        local core, e = F.core(function(e) e.is_charging = false end)
        assert.are.same({ nil, "no_power" }, { core:start() })
        assert.are.equal("idle", core.state)
        assert.are.same({}, e.actions())
    end)

    it("DT-R55 stale plugin marker from a crash: stop restores preventScreenSaver to 0", function()
        local core, e = F.core(function(e)
            marker(e, "plugin")
            e.props["com.lab126.powerd preventScreenSaver"] = 1
        end)
        core:start()
        core:stop()
        assert.are.equal(0, e.props["com.lab126.powerd preventScreenSaver"])
    end)

    it("AC-08 keep-awake: a user value of 1 is saved and restored", function()
        local core, e = F.waiting(function(e) e.props["com.lab126.powerd preventScreenSaver"] = 1 end)
        core:stop()
        assert.are.equal("set com.lab126.powerd preventScreenSaver 1", e.actions()[#e.actions() - 1])
        assert.are.equal(1, e.props["com.lab126.powerd preventScreenSaver"])
    end)

    it("ST-T8 idle -> failed when no bus name is found", function()
        local core = F.core(function(e) e.listnames = F.fixture("listnames_without_mtp.txt"); e.getpid = {} end)
        assert.are.same({ nil, "bus_name_not_found" }, { core:start() })
        assert.are.equal("failed", core.state)
    end)

    it("ST-T9 idle -> failed when startMtp is refused", function()
        local core, e = F.core(function(e) e.start_ok = false end)
        assert.are.same({ nil, "startmtp_failed" }, { core:start() })
        assert.are.equal("failed", core.state)
        assert.is_nil(e.contents[Mtp.MARKER])
    end)

    it("ST-T10 idle -> failed when the marker cannot be written", function()
        local core, e = F.core(function(e) e.write_ok = false end)
        assert.are.same({ nil, "marker_failed" }, { core:start() })
        assert.are.equal("failed", core.state)
        assert.are.equal(0, e.props["com.lab126.mtp isMtpStarted"])
    end)

    it("ST-T12 failed -> waiting_host on a new start", function()
        local core, e = F.core(function(e) e.start_ok = false end)
        core:start()
        e.start_ok = true
        assert.is_true(core:start())
        assert.are.equal("waiting_host", core.state)
    end)

    it("ST-I1 start in waiting_host is refused and sends nothing", function()
        local core, e = F.waiting()
        local n = #e.calls
        assert.are.same({ nil, "already_active" }, { core:start() })
        assert.are.equal(n, #e.calls)
    end)

    it("ST-I2 start in connected is refused and sends nothing", function()
        local core, e = F.connected()
        local n = #e.calls
        assert.are.same({ nil, "already_active" }, { core:start() })
        assert.are.equal(n, #e.calls)
    end)
end)

describe("poll", function()
    it("ST-T2 waiting_host -> connected when the state-2 line shows up", function()
        local core, e = F.waiting()
        e.t = 0.5
        host(e)
        assert.are.equal("connected", core:poll())
        assert.are.equal("connected", core.state)
    end)

    it("AC-03 the drive-mode signal goes out exactly once, unicast to com.lab126.mtp", function()
        local core, e = F.connected()
        for i = 1, 40 do
            e.t = 0.5 + i * Mtp.POLL_INTERVAL
            core:poll()
        end
        assert.are.same({ SIGNAL }, e.signals())
    end)

    it("AC-04 with no well-known name the signal is unicast to tizen-mtp's :1.N", function()
        local core, e = F.connected(function(e) e.listnames = F.fixture("listnames_without_mtp.txt") end)
        core:stop()
        local s = e.signals()
        assert.are.equal(1, #s)
        assert.matches("%-%-dest=:1%.3 ", s[1])
        for _, c in ipairs(e.calls) do
            if c.text:find("--type=signal", 1, true) then assert.matches("%-%-dest=", c.text) end
        end
    end)

    it("AC-06 host tape with syslog: connected at t=0.5", function()
        local core, e = F.waiting()
        local tape = F.tape("udc_tape_host.txt")
        local got
        for i = 2, 3 do
            e.apply(tape[i])
            if tape[i].t == 0.5 then host(e) end
            got = core:poll()
        end
        assert.are.equal("connected", got)
        assert.are.equal(1, #e.signals())
    end)

    it("AC-07 UDC hint alone (bound, then empty) also means a host", function()
        local core, e = F.waiting()
        local tape = F.tape("udc_tape_host.txt")
        e.apply(tape[2])
        assert.is_nil(core:poll())
        e.apply(tape[3])
        assert.are.equal("connected", core:poll())
    end)

    it("EG-04 a state-2 line from an earlier session never counts", function()
        local core, e = F.waiting()
        assert.are.equal(F.OLD_STATE2, e.syslog[2])
        e.t = 1
        assert.is_nil(core:poll())
        assert.are.equal("waiting_host", core.state)
    end)

    it("AC-05 charger-only tape: no host, timeout at 20 s, teardown, no signal", function()
        local core, e = F.waiting()
        local tape = F.tape("udc_tape_charger.txt")
        e.apply(tape[2])
        assert.is_nil(core:poll())
        e.apply(tape[3])
        assert.are.equal("timeout", core:poll())
        assert.are.equal("idle", core.state)
        assert.are.same({}, e.signals())
        assert.are.equal(0, e.props["com.lab126.mtp isMtpStarted"])
    end)

    it("ST-T7 waiting_host -> failed when dbus-send fails", function()
        local core, e = F.waiting(function(e) e.signal_ok = false end)
        e.t = 0.5
        host(e)
        assert.are.same({ "failed", "signal_failed" }, { core:poll() })
        assert.are.equal("failed", core.state)
        assert.is_nil(e.contents[Mtp.MARKER])
    end)

    it("ST-T6 connected -> idle when isMtpStarted drops to 0", function()
        local core, e = F.connected()
        e.props["com.lab126.mtp isMtpStarted"] = 0
        local from = #e.calls + 1
        assert.are.equal("dropped", core:poll())
        assert.are.equal("idle", core.state)
        assert.are.same(STOP, e.actions(from))
    end)

    it("DT-R40 marker gone (KOBridge stopped): release without teardown", function()
        local core, e = F.connected()
        e.contents[Mtp.MARKER] = nil
        local from = #e.calls + 1
        assert.are.equal("released", core:poll())
        assert.are.equal("idle", core.state)
        assert.are.same({ "set com.lab126.powerd preventScreenSaver 0" }, e.actions(from))
    end)

    it("DT-R41 marker taken over by KOBridge: release, its marker stays", function()
        local core, e = F.waiting()
        marker(e, "kobridge")
        assert.are.equal("released", core:poll())
        assert.are.equal("kobridge", Mtp.parse_marker(e.contents[Mtp.MARKER]).owner)
    end)

    it("DT-R42 isMtpStarted 0 while waiting for the host: dropped with teardown", function()
        local core, e = F.waiting()
        e.props["com.lab126.mtp isMtpStarted"] = 0
        assert.are.equal("dropped", core:poll())
        assert.are.equal(1, e.count("udc disable") - 1)
    end)

    it("DT-R43 a failed lipc read (nil) is not a dropout", function()
        local core, e = F.connected()
        e.lipc_dead = true
        assert.is_nil(core:poll())
        assert.are.equal("connected", core.state)
    end)

    it("ST-I3 poll in idle does nothing", function()
        local core, e = F.core()
        assert.is_nil(core:poll())
        assert.are.same({}, e.calls)
    end)

    it("ST-I4 poll in failed does nothing", function()
        local core, e = F.core(function(e) e.start_ok = false end)
        core:start()
        local n = #e.calls
        assert.is_nil(core:poll())
        assert.are.equal(n, #e.calls)
    end)

    it("ST-I5 the state-2 line seen again in connected sends nothing", function()
        local core, e = F.connected()
        host(e)
        local from = #e.calls + 1
        assert.is_nil(core:poll())
        assert.are.same({}, e.actions(from))
    end)

    it("AC-10 log lines carry the kindlemtp: prefix", function()
        local core, e = F.connected()
        core:stop()
        assert.is_true(#e.logs > 0)
        for _, l in ipairs(e.logs) do assert.matches("^%a+ kindlemtp: ", l) end
    end)
end)

describe("timeout boundaries", function()
    it("BVA-07 poll interval is 250 ms and the timeout 20 s", function()
        assert.are.equal(0.25, Mtp.POLL_INTERVAL)
        assert.are.equal(20, Mtp.TIMEOUT)
    end)

    it("BVA-01 at 19.75 s the plugin still waits", function()
        local core, e = F.waiting()
        e.t = 19.75
        assert.is_nil(core:poll())
        assert.are.equal("waiting_host", core.state)
    end)

    it("BVA-02 at 20.00 s it times out", function()
        local core, e = F.waiting()
        e.t = 20
        assert.are.equal("timeout", core:poll())
    end)

    it("BVA-03 at 20.25 s it times out", function()
        local core, e = F.waiting()
        e.t = 20.25
        assert.are.equal("timeout", core:poll())
    end)

    it("BVA-04 with 250 ms ticks, tick 79 waits and tick 80 times out", function()
        local core, e = F.waiting()
        for i = 1, 79 do
            e.t = i * 0.25
            assert.is_nil(core:poll())
        end
        e.t = 80 * 0.25
        assert.are.equal("timeout", core:poll())
    end)

    it("BVA-05 a host seen on the 20.00 s tick wins over the timeout", function()
        local core, e = F.waiting()
        e.t = 20
        host(e)
        assert.are.equal("connected", core:poll())
    end)

    it("BVA-06 syslog shorter than at start (rotated): read from line 1 and still detect", function()
        local core, e = F.waiting()
        e.syslog = {}
        e.t = 0.25
        assert.is_nil(core:poll())
        assert.are.equal(0, core.baseline)
        host(e)
        e.t = 0.5
        assert.are.equal("connected", core:poll())
    end)

    it("EG-05 wc fails at start: watch syslog from the first tick on", function()
        local core, e = F.waiting(function(e) e.wc_ok = false end)
        e.t = 0.25
        assert.is_nil(core:poll())
        assert.are.equal(2, core.baseline)
        host(e)
        e.t = 0.5
        assert.are.equal("connected", core:poll())
    end)
end)

describe("stop and reset", function()
    it("ST-T4 waiting_host -> idle on stop", function()
        local core = F.waiting()
        core:stop()
        assert.are.equal("idle", core.state)
    end)

    it("ST-T5 connected -> stopping -> idle", function()
        local core, e = F.connected()
        core:stop()
        assert.are.equal("idle", core.state)
        assert.are.equal("stopping", state_at(e, "sh /usr/bin/mtp.sh udc disable"))
    end)

    it("AC-02 stop sends stopMtp, udc disable, keep-awake restore, marker removal in order", function()
        local core, e = F.connected()
        local from = #e.calls + 1
        core:stop()
        assert.are.same(STOP, e.actions(from))
    end)

    it("ST-T11 failed -> idle on stop", function()
        local core, e = F.waiting(function(e) e.signal_ok = false end)
        host(e)
        core:poll()
        assert.are.equal("failed", core.state)
        core:stop()
        assert.are.equal("idle", core.state)
    end)

    it("ST-T13 stop in idle tears down and is idempotent", function()
        local core, e = F.core()
        core:stop()
        local first = e.actions()
        core:stop()
        local all = e.actions()
        assert.are.same(first, { all[4], all[5], all[6] })
        assert.are.same({ "set com.lab126.mtp stopMtp 1", "sh /usr/bin/mtp.sh udc disable",
            "remove /tmp/kindlemtp.active" }, first)
    end)

    it("ST-T17 double stop from waiting_host ends idle with the saved keep-awake", function()
        local core, e = F.waiting(function(e) e.props["com.lab126.powerd preventScreenSaver"] = 1 end)
        core:stop()
        core:stop()
        assert.are.equal("idle", core.state)
        assert.are.equal(1, e.props["com.lab126.powerd preventScreenSaver"])
        assert.are.equal(1, e.count("preventScreenSaver 1") - 1)
    end)

    it("ST-T18 double stop from connected ends idle, responder stopped, marker gone", function()
        local core, e = F.connected()
        core:stop()
        core:stop()
        assert.are.equal("idle", core.state)
        assert.are.equal(0, e.props["com.lab126.mtp isMtpStarted"])
        assert.is_nil(e.contents[Mtp.MARKER])
    end)

    it("ST-T19 double stop from failed ends idle", function()
        local core = F.core(function(e) e.start_ok = false end)
        core:start()
        core:stop()
        core:stop()
        assert.are.equal("idle", core.state)
    end)

    it("ST-T20 stop tears down a KOBridge session too", function()
        local core, e = F.core(function(e)
            marker(e, "kobridge")
            e.props["com.lab126.mtp isMtpStarted"] = 1
        end)
        core:stop()
        assert.is_nil(e.contents[Mtp.MARKER])
        assert.are.equal(0, e.props["com.lab126.mtp isMtpStarted"])
    end)

    it("ST-T14 reset from connected: restart mtp, then the stop sequence", function()
        local core, e = F.connected()
        local from = #e.calls + 1
        assert.is_true(core:reset())
        local a = e.actions(from)
        assert.are.equal("sh restart mtp", a[1])
        assert.are.same(STOP, { a[2], a[3], a[4], a[5] })
        assert.are.equal("idle", core.state)
    end)

    it("ST-T15 reset whose restart fails still stops and reports it", function()
        local core, e = F.connected(function(e) e.restart_ok = false end)
        assert.are.same({ nil, "restart_failed" }, { core:reset() })
        assert.are.equal("idle", core.state)
        assert.are.equal(0, e.props["com.lab126.mtp isMtpStarted"])
    end)
end)
