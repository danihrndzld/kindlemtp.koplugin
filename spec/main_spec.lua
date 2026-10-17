-- main.lua driven through stub KOReader modules (spec/koreader_stubs.lua) and the fake device.
local S = require("koreader_stubs")
local F = require("fake_env")

local function start(opts)
    local _, k, e = S.load(opts)
    local fm = k.instance()
    fm.menu.sub_item_table[1].callback()
    return k, e, fm
end

local function connect(k, e)
    e.t = 0.5
    e.append_log(F.fixture("syslog_state2.txt"))
    k.run_next()
end

describe("main.lua", function()
    it("AC-11 Start flushes settings first, keeps the device awake, shows the dialog and polls every 250 ms", function()
        local k, e = start({ keepalive = false })
        local flushed_at = tonumber(k.log[1]:match("^flush at call (%d+)$"))
        for i = 1, flushed_at do
            assert.are_not.equal("set", e.calls[i].kind) -- only probe reads before the flush
        end
        assert.are.equal("show ButtonDialog Waiting for the computer…", k.log[2])
        assert.are.equal("waiting_host", k.core.state)
        assert.is_true(k.share.pause_auto_suspend)
        assert.is_true(k.share.keepalive)
        assert.are.equal(1, #k.scheduled)
        assert.are.equal(0.25, k.scheduled[1].s)
        assert.are.equal(1, e.count("startMtp"))
    end)

    it("AC-12 connected, then Stop: dialog closes, settings restored, browser refreshed, polling ends", function()
        local k, e = start({ keepalive = false })
        connect(k, e)
        assert.are.equal("title Connected. Your computer can see the Kindle's files.", k.log[#k.log])
        assert.are.equal(1, #k.scheduled)
        k.top.buttons[1][1].callback()
        assert.are.equal("idle", k.core.state)
        assert.are.equal("close ButtonDialog", k.log[#k.log])
        assert.is_nil(k.share.pause_auto_suspend)
        assert.is_false(k.share.keepalive)
        -- Only the refresh is left, 1 s later (fsp lag); the poll is gone.
        assert.are.equal(1, #k.scheduled)
        assert.are.equal(1, k.run_next())
        assert.are.equal("refreshPath", k.log[#k.log])
        assert.are.equal(0, #k.scheduled)
    end)

    it("DT-R60 NotCharging with the UDC configured (battery Full) keeps the transfer", function()
        local k, e, fm = start()
        connect(k, e)
        e.udc_state = "configured"
        fm:onNotCharging()
        assert.are.equal("connected", k.core.state)
    end)

    it("DT-R61 NotCharging with the UDC not configured (unplugged) stops and refreshes", function()
        local k, e, fm = start()
        connect(k, e)
        e.udc_state = "not attached"
        fm:onNotCharging()
        assert.are.equal("idle", k.core.state)
        k.run_all()
        assert.are.equal("refreshPath", k.log[#k.log])
    end)

    it("DT-R67 NotCharging while waiting for the host with the cable still charging keeps the start", function()
        local k, e, fm = start()
        e.udc_state = "not attached"
        fm:onNotCharging()
        assert.are.equal("waiting_host", k.core.state)
        assert.are.equal(0, e.count("cat /sys/class/udc"))
    end)

    it("DT-R68 NotCharging while waiting for the host after an unplug stops", function()
        local k, e, fm = start()
        e.is_charging = false
        fm:onNotCharging()
        assert.are.equal("idle", k.core.state)
    end)

    it("DT-R69 NotCharging while waiting with a Full battery and the cable in keeps the start", function()
        local k, e, fm = start()
        e.is_charging = false
        e.supplies = F.fixture("power_supply_ac_online.txt")
        fm:onNotCharging()
        assert.are.equal("waiting_host", k.core.state)
    end)

    it("DT-R62 CloseWidget stops without refreshing the closing browser", function()
        local k, e, fm = start()
        connect(k, e)
        fm:onCloseWidget()
        assert.are.equal("idle", k.core.state)
        assert.are.equal(0, #k.scheduled)
        assert.is_false(k.has("refreshPath"))
    end)

    it("DT-R63 Suspend stops", function()
        local k, e, fm = start()
        connect(k, e)
        fm:onSuspend()
        assert.are.equal("idle", k.core.state)
    end)

    it("DT-R64 Charging in the file manager with auto-start on starts after 2 s", function()
        local _, k = S.load({ autostart = true })
        k.instance():onCharging()
        assert.are.equal(1, #k.scheduled)
        assert.are.equal(2, k.run_next())
        assert.are.equal("waiting_host", k.core.state)
    end)

    it("DT-R65 Charging in the reader with auto-start on does nothing", function()
        local _, k = S.load({ autostart = true })
        k.instance(true):onCharging()
        assert.are.equal(0, #k.scheduled)
        assert.are.equal("idle", k.core.state)
    end)

    it("DT-R66 a book opened during the 2 s auto-start delay cancels the start", function()
        local _, k = S.load({ autostart = true })
        k.instance():onCharging()
        k.FileManager.instance = nil
        k.run_next()
        assert.are.equal("idle", k.core.state)
    end)

    it("AC-13 with a book open Start is disabled and refused", function()
        local _, k, e = S.load()
        local reader = k.instance(true)
        local item = reader.menu.sub_item_table[1]
        assert.is_false(item.enabled_func())
        item.callback()
        assert.matches("^show InfoMessage Close the book first", k.log[#k.log])
        assert.are.equal(0, e.count("startMtp"))
    end)

    it("AC-14 an auto-started transfer times out without a message", function()
        local _, k, e = S.load({ autostart = true })
        k.instance():onCharging()
        k.run_next()
        e.t = 20
        k.run_next()
        assert.are.equal("idle", k.core.state)
        assert.is_false(k.has("show InfoMessage"))
    end)

    it("AC-15 a manual Start that times out says so", function()
        local k, e = start()
        e.t = 20
        k.run_next()
        assert.matches("^show InfoMessage No computer answered within 20 seconds", k.log[#k.log])
    end)

    it("AC-16 Reset shows Resetting and repaints before restart mtp runs", function()
        local _, k, e = S.load()
        local fm = k.instance()
        fm.menu.sub_item_table[3].callback()
        local n = #e.calls
        k.top.ok_callback()
        assert.is_true(k.has("show InfoMessage Resetting…"))
        assert.is_true(k.has("repaint at call " .. n))
        assert.are.equal(1, e.count("restart mtp"))
        assert.matches("^show InfoMessage The USB responder was reset", k.log[#k.log])
    end)

    it("AC-17 on a non-Kindle the plugin disables itself", function()
        local Plugin = S.load({ kindle = false })
        assert.are.same({ disabled = true }, Plugin)
    end)

    it("AC-18 loading the plugin never reads lipc", function()
        local _, _, e = S.load()
        assert.are.equal(0, e.count("isMtpStarted"))
    end)

    it("AC-19 the menu sits under Network with 4 entries", function()
        local _, k = S.load()
        local menu = k.instance().menu
        assert.are.equal("network", menu.sorting_hint)
        assert.are.equal("USB file transfer (MTP)", menu.text)
        assert.are.equal(4, #menu.sub_item_table)
    end)
end)
