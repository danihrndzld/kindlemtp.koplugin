-- Probe: 7 checks, each with its own reason (decision table, one failing condition per rule).
local Mtp = require("kindlemtp_core")
local F = require("fake_env")

local function probe(setup, is_kindle)
    local core, e = F.core(setup)
    return core:probe(is_kindle ~= false), e
end

describe("probe", function()
    it("DT-R1 every check passes", function()
        local r = probe()
        assert.is_true(r.ok)
        assert.is_nil(r.reason)
        assert.are.equal(7, #r.checks)
    end)

    it("DT-R2 not a Kindle", function()
        assert.are.equal("not_kindle", probe(nil, false).reason)
    end)

    it("DT-R3 /usr/bin/mtp.sh missing", function()
        assert.are.equal("no_mtp_sh", probe(function(e) e.exists_set[Mtp.MTP_SH] = nil end).reason)
    end)

    it("DT-R4 mtpgadget missing", function()
        assert.are.equal("no_gadget", probe(function(e) e.exists_set[Mtp.GADGET] = nil end).reason)
    end)

    it("DT-R5 tizen-mtp not running", function()
        assert.are.equal("no_responder", probe(function(e) e.pids["tizen-mtp"] = nil end).reason)
    end)

    it("DT-R6 dbus-send missing", function()
        assert.are.equal("no_dbus_send", probe(function(e) e.exists_set[Mtp.DBUS_SEND] = nil end).reason)
    end)

    it("DT-R7 lipc does not answer", function()
        assert.are.equal("no_lipc", probe(function(e) e.lipc_dead = true end).reason)
    end)

    it("DT-R8 volumd running", function()
        local r = probe(function(e)
            e.vars.VOLUMD_STOPPED = nil
            e.contents["/proc/5237/stat"] = F.fixture("proc_stat_S.txt")
        end)
        assert.are.equal("volumd_running", r.reason)
    end)

    it("DT-R9 several failures report the first and list all", function()
        local r = probe(function(e)
            e.exists_set[Mtp.MTP_SH] = nil
            e.vars.VOLUMD_STOPPED = "no"
            e.contents["/proc/5237/stat"] = F.fixture("proc_stat_S.txt")
        end)
        assert.are.equal("no_mtp_sh", r.reason)
        assert.is_false(r.checks[2].ok)
        assert.is_false(r.checks[7].ok)
        assert.is_true(r.checks[3].ok)
    end)

    it("DT-R15 load-time probe skips lipc: passes with lipc dead and never reads it", function()
        local core, e = F.core(function(e) e.lipc_dead = true end)
        local r = core:probe(true, true)
        assert.is_true(r.ok)
        assert.are.equal(0, e.count("isMtpStarted"))
    end)

    it("DT-R10 VOLUMD_STOPPED=yes wins without reading /proc", function()
        local r, e = probe(function(e)
            e.contents["/proc/5237/stat"] = F.fixture("proc_stat_S.txt")
        end)
        assert.is_true(r.ok)
        assert.are.equal(0, e.count("pidof volumd"))
    end)

    it("DT-R11 no env flag, volumd in state T", function()
        local r = probe(function(e)
            e.vars.VOLUMD_STOPPED = nil
            e.contents["/proc/5237/stat"] = F.fixture("proc_stat_T.txt")
        end)
        assert.is_true(r.ok)
    end)

    it("DT-R12 VOLUMD_STOPPED=no, volumd in state S", function()
        local r = probe(function(e)
            e.vars.VOLUMD_STOPPED = "no"
            e.contents["/proc/5237/stat"] = F.fixture("proc_stat_S.txt")
        end)
        assert.are.equal("volumd_running", r.reason)
    end)

    it("DT-R13 no env flag and no volumd process", function()
        local r = probe(function(e)
            e.vars.VOLUMD_STOPPED = nil
            e.pids.volumd = nil
        end)
        assert.is_true(r.ok)
    end)

    it("DT-R14 no env flag, volumd vanished before its stat was read", function()
        local r = probe(function(e) e.vars.VOLUMD_STOPPED = nil end)
        assert.is_true(r.ok)
    end)
end)

describe("bus name", function()
    it("EP-20 well-known name present: no pid scan", function()
        local core, e = F.core()
        assert.are.equal("com.lab126.mtp", core:bus_name())
        assert.are.equal(0, e.count("GetConnectionUnixProcessID"))
    end)

    it("EP-21 well-known name absent: :1.N scan finds tizen-mtp's pid", function()
        local core, e = F.core(function(e) e.listnames = F.fixture("listnames_without_mtp.txt") end)
        assert.are.equal(":1.3", core:bus_name())
        assert.are.equal(40, e.count("GetConnectionUnixProcessID")) -- :1.3 is the 40th :1.N name
    end)

    it("EP-22 no connection has tizen-mtp's pid", function()
        local core, e = F.core(function(e)
            e.listnames = F.fixture("listnames_without_mtp.txt")
            e.getpid = {}
        end)
        assert.is_nil(core:bus_name())
        assert.are.equal(47, e.count("GetConnectionUnixProcessID"))
    end)

    it("EP-23 failed GetConnectionUnixProcessID calls (empty stdout, exit 1) are skipped", function()
        local core = F.core(function(e)
            e.listnames = F.fixture("listnames_without_mtp.txt")
            e.getpid = { [":1.0"] = false, [":1.3"] = false }
        end)
        assert.is_nil(core:bus_name())
    end)

    it("EP-24 tizen-mtp not running: no scan at all", function()
        local core, e = F.core(function(e)
            e.listnames = F.fixture("listnames_without_mtp.txt")
            e.pids["tizen-mtp"] = nil
        end)
        assert.is_nil(core:bus_name())
        assert.are.equal(0, e.count("GetConnectionUnixProcessID"))
    end)

    it("EP-25 ListNames fails", function()
        local core = F.core(function(e) e.listnames, e.listnames_ok = "", false end)
        assert.is_nil(core:bus_name())
    end)
end)

describe("udc state", function()
    it("EP-30 configured", function()
        local core = F.core(function(e) e.udc_state = "configured" end)
        assert.is_true(core:udc_configured())
    end)

    it("EP-31 not attached", function()
        local core = F.core(function(e) e.udc_state = "not attached" end)
        assert.is_false(core:udc_configured())
    end)

    it("EP-32 powered by a charger, from the charger tape", function()
        local row = F.tape("udc_tape_charger.txt")[2]
        local core = F.core(function(e) e.udc_state = row.state end)
        assert.is_false(core:udc_configured())
    end)

    it("EP-33 two UDCs, one configured", function()
        local core = F.core(function(e) e.udc_state = "not attached\nconfigured" end)
        assert.is_true(core:udc_configured())
    end)
end)
