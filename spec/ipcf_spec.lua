-- Firmware 5.19: tizen-mtp has no lipc properties; bin/kindlemtp-ipcf calls its IPCF4 service.
local Mtp = require("kindlemtp_core")
local F = require("fake_env")

local IPCF = "/mnt/us/koreader/plugins/kindlemtp.koplugin/bin/kindlemtp-ipcf"
local function q(what) return "sh '" .. IPCF .. "' " .. what end

-- A 5.19 Kindle: helper answers, every lipc read fails.
local function fw519(e)
    e.ipcf, e.lipc_dead = IPCF, true
end

local function has(list, item)
    for _, v in ipairs(list) do if v == item then return true end end
    return false
end

describe("firmware 5.19 (IPCF4)", function()
    it("AC-I1 start pings once, then stop and start go through the helper in the recipe's order", function()
        local core, e = F.core(fw519)
        assert.is_true(core:start())
        local a = e.actions()
        assert.are.equal("sh /usr/bin/mtp.sh udc disable", a[3])
        assert.are.same({ q("ping"), q("stop"), "sh wc -l < /var/log/messages", q("start") },
            { a[4], a[5], a[6], a[7] })
        assert.are.equal("set com.lab126.powerd preventScreenSaver 1", a[8])
        assert.are.equal(1, e.count("' ping"))
        assert.are.equal(0, e.count("startMtp"))
    end)

    it("AC-I2 the UDC drop while the host configures is not a dropout; the host line connects", function()
        local core, e = F.waiting(fw519)
        e.udc, e.t = "", 1.5 -- state 2: no binding yet
        assert.is_nil(core:poll())
        assert.are.equal("waiting_host", core.state)
        e.append_log(F.fixture("syslog_state2.txt"))
        e.t = 2
        assert.are.equal("connected", core:poll())
        assert.are.equal(1, #e.signals())
        assert.matches("%-%-dest=com%.lab126%.mtp ", e.signals()[1])
    end)

    it("BVA-I8 right after connecting, a UDC read from state 2 is no dropout; at REBIND_GRACE it is", function()
        local core, e = F.waiting(fw519)
        e.udc, e.t = "", 1 -- state 2: read and cached as 0
        assert.is_nil(core:poll())
        e.append_log(F.fixture("syslog_state2.txt"))
        e.t = 1.25
        assert.are.equal("connected", core:poll())
        e.t = 1.5 -- cached 0, rebind still pending
        assert.is_nil(core:poll())
        e.t = 1.25 + Mtp.REBIND_GRACE - 0.25 -- fresh read, still unbound, inside the window
        assert.is_nil(core:poll())
        e.udc = "musb-hdrc.1.auto"
        e.t = 1.25 + Mtp.REBIND_GRACE + 1
        assert.is_nil(core:poll())
        assert.are.equal("connected", core.state)
        e.udc, e.t = "", 1.25 + Mtp.REBIND_GRACE + 2
        assert.are.equal("dropped", core:poll())
    end)

    it("EG-I9 a missing or non-executable helper is not cached and lipc does the work", function()
        local core, e = F.core(function(x) x.ipcf, x.ipcf_answer = IPCF, "fail" end)
        assert.is_true(core:start())
        assert.are.equal(1, e.count("startMtp 1"))
        assert.is_nil(core.mode)
    end)

    it("AC-I3 connected, an unbound UDC is a dropout and stop goes through the helper", function()
        local core, e = F.connected(fw519)
        e.udc, e.t = "", 0.5 + Mtp.REBIND_GRACE
        local from = #e.calls + 1
        assert.are.equal("dropped", core:poll())
        assert.is_true(has(e.actions(from), q("stop")))
        assert.are.equal(0, e.count("stopMtp"))
        assert.are.equal("idle", core.state)
    end)

    it("AC-I4 on 5.18 the helper answers no_ipcn once and lipc does the rest", function()
        local core, e = F.core(function(x) x.ipcf, x.ipcf_answer = IPCF, "no_ipcn" end)
        assert.is_true(core:start())
        core:stop()
        assert.are.equal(1, e.count("' ping"))
        assert.are.equal(1, e.count("startMtp 1"))
        assert.are.equal(2, e.count("stopMtp 1"))
    end)

    it("EG-I5 a failed ping is not cached: probe reports no_lipc and the next call asks again", function()
        local core, e = F.core(function(x) fw519(x); x.ipcf_answer = "fail" end)
        local r = core:probe(true)
        assert.is_false(r.ok)
        assert.are.equal("no_lipc", r.reason)
        e.ipcf_answer = "ok"
        assert.is_true(core:probe(true).ok)
        assert.are.equal(2, e.count("' ping"))
        assert.are.equal("ipcf", core:control())
    end)

    it("EG-I6 a failed helper start fails the start and tears down through the helper", function()
        local core, e = F.core(function(x) fw519(x); x.start_ok = false end)
        local ok, reason = core:start()
        assert.is_nil(ok)
        assert.are.equal("startmtp_failed", reason)
        assert.are.equal("failed", core.state)
        assert.are.equal(2, e.count("' stop"))
        assert.is_nil(e.contents[Mtp.MARKER])
    end)

    it("DT-I7 the stale-marker rule reads the UDC: unbound and 30 s old is stale, bound is not", function()
        local core, e = F.core(fw519)
        e.contents[Mtp.MARKER] = "owner=kobridge pid=9 since=" .. (e.wall - 30) .. "\n"
        e.udc = "musb-hdrc.1.auto"
        assert.are.same({ nil, "owner_other" }, { core:start() })
        e.udc = ""
        assert.is_true(core:start())
    end)
end)
