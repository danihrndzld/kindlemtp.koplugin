-- Kindle 5.19.2 (issue #3): no MTP at all, the userstore is exported through g_mass_storage lun0/file.
local Mtp = require("kindlemtp_core")
local F = require("fake_env")

local LOOP = Mtp.LOOP_DEV .. "\n"

describe("UMS Kindle (5.19.2)", function()
    it("DT-R80 probe passes without mtp.sh, gadget, tizen-mtp or lipc", function()
        local core = F.core(function(e) F.ums(e); e.lipc_dead = true end)
        local r = core:probe(true)
        assert.is_true(r.ok)
        assert.are.equal(7, #r.checks)
    end)

    it("DT-R81 without mtp.sh and without a lun0/file the probe still says no_mtp_sh", function()
        local core = F.core(function(e) e.exists_set[Mtp.MTP_SH] = nil end)
        assert.are.equal("no_mtp_sh", core:probe(true).reason)
    end)

    it("DT-R82 lun0/file without the loop device is not a UMS Kindle", function()
        local core = F.core(function(e) F.ums(e); e.exists_set[Mtp.LOOP_DEV] = nil end)
        assert.are.equal("no_mtp_sh", core:probe(true).reason)
    end)

    it("DT-R83 an MTP Kindle with a lun0/file keeps using MTP", function()
        local core = F.core(function(e) e.lun = F.LUN; e.exists_set[Mtp.LOOP_DEV] = true end)
        assert.are.equal("lipc", core:control())
    end)

    it("AC-U1 start syncs, exports the loop device and keeps the device awake", function()
        local core, e = F.core(F.ums)
        assert.is_true(core:start())
        assert.are.equal("waiting_host", core.state)
        assert.are.equal("ums", core:control())
        assert.are.equal(LOOP, e.contents[F.LUN])
        assert.are.equal(1, e.count("preventScreenSaver 1"))
        assert.are.equal(0, e.count("startMtp"))
        assert.are.equal(0, e.count("ListNames"))
    end)

    it("AC-U2 a failed lun0/file write fails the start and removes the marker", function()
        local core, e = F.core(function(x) F.ums(x); x.write_ok = true end)
        local write = e.write
        e.write = function(path, text, exclusive)
            if path == F.LUN then return false end
            return write(path, text, exclusive)
        end
        assert.are.same({ nil, "ums_export_failed" }, { core:start() })
        assert.are.equal("failed", core.state)
        assert.is_nil(e.contents[Mtp.MARKER])
    end)

    it("ST-U1 the host configuring the UDC moves waiting_host to connected, no signal sent", function()
        local core, e = F.waiting(F.ums)
        e.udc_state, e.t = "configured", 0.5
        assert.are.equal("connected", core:poll())
        assert.are.same({}, e.signals())
    end)

    it("BVA-U1 UMS times out after 20 s without a host", function()
        local core, e = F.waiting(F.ums)
        e.t = 19.75
        assert.is_nil(core:poll())
        e.t = 20
        assert.are.equal("timeout", core:poll())
        assert.are.equal("idle", core.state)
    end)

    it("ST-U2 the host ejecting (lun0/file emptied) ends the transfer", function()
        local core, e = F.waiting(F.ums)
        e.udc_state, e.t = "configured", 0.5
        core:poll()
        e.contents[F.LUN] = "\n"
        e.t = 1.5
        assert.are.equal("dropped", core:poll())
        assert.are.equal("idle", core.state)
    end)

    it("ST-U7 connected, the host dropping the UDC while the cable stays in ends the transfer", function()
        local core, e = F.waiting(F.ums)
        e.udc_state, e.t = "configured", 0.5
        core:poll()
        e.udc_state, e.t = "not attached", 1.5
        assert.are.equal("dropped", core:poll())
        assert.are.equal("idle", core.state)
    end)

    it("ST-U3 stop empties lun0/file, syncs, refreshes the vfat mount and removes the marker", function()
        local core, e = F.waiting(F.ums)
        local from = #e.calls + 1
        core:stop()
        local a = e.actions(from)
        assert.are.equal("write " .. F.LUN .. " ", a[1])
        assert.are.equal("sh sync", a[2])
        assert.are.equal("sh " .. Mtp.UMS_FLUSH, a[3])
        assert.is_nil(e.contents[Mtp.MARKER])
        assert.are.equal(0, e.count("rm -rf"))
        assert.are.equal(0, e.count("stopMtp"))
    end)

    it("ST-U4 reset on a UMS Kindle only stops", function()
        local core, e = F.waiting(F.ums)
        assert.is_true(core:reset())
        assert.are.equal(0, e.count("restart mtp"))
        assert.are.equal("idle", core.state)
    end)
end)

describe("unplug detection", function()
    it("ST-U5 poll stops the transfer once the cable is gone (MTP)", function()
        local core, e = F.connected()
        e.is_charging = false
        e.t = 1.5
        assert.are.equal("unplugged", core:poll())
        assert.are.equal("idle", core.state)
        assert.is_nil(e.contents[Mtp.MARKER])
    end)

    it("ST-U6 poll stops the transfer once the cable is gone (UMS)", function()
        local core, e = F.waiting(F.ums)
        e.is_charging = false
        e.t = 1.5
        assert.are.equal("unplugged", core:poll())
        assert.are.equal("idle", core.state)
    end)

    it("BVA-U2 the cable is read at most once per second", function()
        local core, e = F.waiting(F.ums)
        e.t = 1
        core:poll()
        e.is_charging = false
        e.t = 1.5
        assert.is_nil(core:poll())
        e.t = 2
        assert.are.equal("unplugged", core:poll())
    end)

    it("DT-R84 a Full battery with the cable in is not an unplug", function()
        local core, e = F.connected(function(x) x.udc_state = "configured" end)
        e.is_charging = false
        e.supplies = F.fixture("power_supply_ac_online.txt")
        e.t = 1.5
        assert.is_nil(core:poll())
    end)
end)

describe("5.19 IPCF4 fallback", function()
    it("AC-U3 the UDC fallback connects on 5.19 after the gadget unbinds", function()
        local IPCF = "/x/bin/kindlemtp-ipcf"
        local core, e = F.waiting(function(x) x.ipcf, x.lipc_dead = IPCF, true end)
        e.udc, e.t = "musb-hdrc.1.auto", 0.5
        assert.is_nil(core:poll())
        e.udc, e.t = "", 1.5
        assert.are.equal("connected", core:poll())
    end)
end)
