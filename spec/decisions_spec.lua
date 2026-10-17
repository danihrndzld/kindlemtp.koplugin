-- Decision tables for main.lua's event handling: which KOReader events stop, and when Charging auto-starts.
local Mtp = require("kindlemtp_core")

describe("stop triggers", function()
    it("DT-R20 NotCharging while active and UDC not configured stops", function()
        assert.is_true(Mtp.stop_trigger("NotCharging", true, false))
    end)

    it("DT-R21 NotCharging while active and UDC configured (battery Full) does not stop", function()
        assert.is_false(Mtp.stop_trigger("NotCharging", true, true))
    end)

    it("DT-R35 NotCharging while waiting for the host, still charging (battery Full), does not stop", function()
        assert.is_false(Mtp.stop_trigger("NotCharging", true, false, true, true))
    end)

    it("DT-R36 NotCharging while waiting for the host, no longer charging (unplugged), stops", function()
        assert.is_true(Mtp.stop_trigger("NotCharging", true, false, true, false))
    end)

    it("DT-R22 NotCharging while idle does not stop", function()
        assert.is_false(Mtp.stop_trigger("NotCharging", false, false))
    end)

    it("DT-R23 Suspend while active stops", function()
        assert.is_true(Mtp.stop_trigger("Suspend", true, true))
    end)

    it("DT-R24 Suspend while idle does not stop", function()
        assert.is_false(Mtp.stop_trigger("Suspend", false, false))
    end)

    it("DT-R25 CloseWidget while active stops", function()
        assert.is_true(Mtp.stop_trigger("CloseWidget", true, true))
    end)

    it("DT-R26 CloseWidget while idle does not stop", function()
        assert.is_false(Mtp.stop_trigger("CloseWidget", false, false))
    end)

    it("DT-R27 stopPlugin while active stops", function()
        assert.is_true(Mtp.stop_trigger("stopPlugin", true, true))
    end)

    it("DT-R28 stopPlugin while idle does not stop", function()
        assert.is_false(Mtp.stop_trigger("stopPlugin", false, false))
    end)

    it("DT-R29 Charging while active does not stop", function()
        assert.is_false(Mtp.stop_trigger("Charging", true, false))
    end)
end)

describe("cable detection", function()
    it("DT-R70 charging means a cable", function()
        assert.is_true(Mtp.cable_detected(true, "", ""))
    end)

    it("DT-R71 not charging, UDC configured: a cable", function()
        assert.is_true(Mtp.cable_detected(false, "configured\n", ""))
    end)

    it("DT-R72 Full battery: not charging, UDC not attached, a power supply online: a cable", function()
        assert.is_true(Mtp.cable_detected(false, "not attached\n", "1\n"))
    end)

    it("DT-R73 not charging, UDC not attached, every supply offline: no cable", function()
        assert.is_false(Mtp.cable_detected(false, "not attached\n", "0\n0\n"))
    end)

    it("DT-R74 not charging and no UDC or power-supply files: no cable", function()
        assert.is_false(Mtp.cable_detected(false, "", ""))
        assert.is_false(Mtp.cable_detected(false, nil, nil))
    end)

    it("EP-59 several power supplies, one online", function()
        assert.is_true(Mtp.cable_detected(false, "not attached", "0\n1\n"))
    end)
end)

describe("auto-start", function()
    it("DT-R30 setting on, file manager, idle: starts", function()
        assert.is_true(Mtp.should_autostart(true, true, false))
    end)

    it("DT-R31 setting off: no start", function()
        assert.is_false(Mtp.should_autostart(false, true, false))
    end)

    it("DT-R32 reader instance: no start", function()
        assert.is_false(Mtp.should_autostart(true, false, false))
    end)

    it("DT-R33 already active: no start", function()
        assert.is_false(Mtp.should_autostart(true, true, true))
    end)

    it("DT-R34 setting never saved (nil): no start", function()
        assert.is_false(Mtp.should_autostart(nil, true, false))
    end)
end)
