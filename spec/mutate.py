"""Mutation check: applies each mutant to kindlemtp_core.lua or main.lua, runs busted, restores the file.

Usage (repo root, busted on PATH): python3 spec/mutate.py [results.json]
Exits 1 if any mutant survives.
"""
import json, os, re, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
F = "kindlemtp.koplugin/kindlemtp_core.lua"
M = [
 ("M01", "Drive-mode signal broadcast (no --dest=)", '" --system --dest=" .. self.dest\n            .. " --type=signal', '" --system"\n            .. " --type=signal'),
 ("M02", "Signal re-sent on every tick in connected", 'if self.state == "connected" then return nil end', ''),
 ("M03", "Timeout uses > instead of >=", '>= M.TIMEOUT then', '> M.TIMEOUT then'),
 ("M04", "Timeout 30 s instead of 20 s", 'M.TIMEOUT = 20', 'M.TIMEOUT = 30'),
 ("M05", "Stop: udc disable before stopMtp", '    self:mtp("stop")\n    -- stopMtp from state 3 does not unbind the UDC.\n    self:sh(M.MTP_SH .. " udc disable")', '    self:sh(M.MTP_SH .. " udc disable")\n    self:mtp("stop")'),
 ("M06", "Stop skips udc disable", '    -- stopMtp from state 3 does not unbind the UDC.\n    self:sh(M.MTP_SH .. " udc disable")', ''),
 ("M07", "Stop leaves the marker", '    env.remove(M.MARKER)\n    -- Leftovers', '    -- Leftovers'),
 ("M08", "Start ignores the cable check", 'if not self:cable_in() then return nil, "no_power" end', 'if false then return nil, "no_power" end'),
 ("M09", "Marker written non-exclusively", 'env.write(M.MARKER, line, true)', 'env.write(M.MARKER, line, false)'),
 ("M10", "Owner check inverted", 'marker.owner == "plugin") and "already_active"', 'marker.owner == "kobridge") and "already_active"'),
 ("M11", "volumd state test uses S instead of T", 'st ~= nil and st ~= "T"', 'st ~= nil and st ~= "S"'),
 ("M12", "VOLUMD_STOPPED flag ignored", 'getenv("VOLUMD_STOPPED") == "yes"', 'getenv("VOLUMD_STOPPED") == "never"'),
 ("M13", "Well-known bus name skipped", 'if n == M.BUS then return n end', 'if false then return n end'),
 ("M14", "NotCharging ignores the UDC gate", 'return not udc_configured', 'return true'),
 ("M15", "Keep-awake never restored", 'if v ~= nil then self.env.lipc.set_int', 'if false then self.env.lipc.set_int'),
 ("M16", "Syslog baseline ignored (reads whole log)", '(self.baseline or 0) + 1', '1'),
 ("M17", "Dropout test on nil instead of 0", 'if started == 0 and (', 'if started == nil and ('),
 ("M18", "UDC hint disabled", 'return self.udc_seen and started == 1', 'return false'),
 ("M19", "Release deletes another owner's marker", '        self:restore_keep_awake(false)\n        self.state = "idle"\n        return "released"', '        self.env.remove(M.MARKER)\n        self:restore_keep_awake(false)\n        self.state = "idle"\n        return "released"'),
 ("M20", "Probe reports the last failure", 'if not c[2] and result.ok then', 'if not c[2] then'),
 ("M21", "GetConnectionUnixProcessID parser broken", '"\\n%s*uint32 (%d+)"', '"\\n%s*int32 (%d+)"'),
 ("M22", "sh ignores the exit code", 'return body, rc == "0"', 'return body, true'),
 ("M23", "lipc fallback drops -i", '"lipc-set-prop -i %s %s %d"', '"lipc-set-prop %s %s %d"'),
 ("M24", "Auto-start also in the reader", 'enabled == true and in_filemanager == true and not active', 'enabled == true and not active'),
 ("M25", "Crash leftover keeps preventScreenSaver 1", 'if v == nil and plugin_marker then v = 0 end', ''),
 ("M27", "isMtpStarted read on every tick", 'now - self.lipc_at >= M.LIPC_INTERVAL', 'true'),
 ("M28", "Unreadable lipc treated as a stale marker", 'if started == nil then return nil, "no_lipc" end', ''),
 ("M29", "Load-time probe still reads lipc", 'skip_lipc == true or self:started() ~= nil', 'self:started() ~= nil'),
 ("M37", "Losing the marker race tears down KOBridge's session", 'if other and other.owner ~= "plugin" then', 'if false then'),
 ("M38", "Reset before the marker claim", '    -- The marker is the lock shared with KOBridge: take it before touching the responder.\n',
  '    self:sh(M.MTP_SH .. " udc disable")\n    self:mtp("stop")\n'),
 ("M39", "A failed claim tears down", '        self:log("warn", "failed: marker_failed")\n', '        self:stop()\n'),
 ("M40", "Marker stale one second late (> instead of >=)", 'epoch - since >= M.STALE_AFTER', 'epoch - since > M.STALE_AFTER'),
 ("M41", "Marker age ignored (stale whenever isMtpStarted is 0)", 'return since ~= nil and since <= epoch and epoch - since >= M.STALE_AFTER', 'return true'),
 ("M42", "Marker since not taken from the device clock", 'pid=%d since=%d\\n", self.pid, env.epoch())', 'pid=%d since=%d\\n", self.pid, env.epoch() - 1)'),
 ("M59", "5.19: helper never used", 'if self:control() == "ipcf" then\n        local _, ok', 'if false then\n        local _, ok'),
 ("M60", "5.19: failed ping cached as lipc", 'elseif out:find("no_ipcn", 1, true) then self.mode = "lipc"', 'else self.mode = "lipc"'),
 ("M61", "5.19: started read from lipc instead of the UDC", 'if self:control() == "ipcf" then\n        return trim', 'if false then\n        return trim'),
 ("M62", "5.19: UDC drop at state 2 taken for a dropout", ' and (self.mode ~= "ipcf" or rebound)', ''),
 ("M63", "5.19: helper failure on start ignored", '        local _, ok = self:sh(sq(self.env.ipcf) .. " " .. what)\n        return ok', '        self:sh(sq(self.env.ipcf) .. " " .. what)\n        return true'),
 ("M64", "5.19: no rebind grace after connecting", 'now - self.connected_at >= M.REBIND_GRACE', 'true'),
 ("M65", "5.19: rebind grace never ends", 'now - self.connected_at >= M.REBIND_GRACE', 'false'),
 ('M66', '5.19: UDC fallback needs isMtpStarted 1 (never true on 5.19)', 'return self.udc_seen and (started == 1 or self.mode == "ipcf")', 'return self.udc_seen and started == 1'),
 ('M67', 'UMS: lun0/file never written on start', '        if not env.write(self:ums_lun(), M.LOOP_DEV .. "\\n") then', '        if false then'),
 ('M68', 'UMS: lun0/file not emptied on stop', '        env.write(self:ums_lun(), "\\n")\n', ''),
 ('M69', 'UMS: vfat cache not refreshed on stop', '        self:sh(M.UMS_FLUSH)\n', ''),
 ('M70', 'UMS: loop device not required', 'self.env.exists(M.MTP_SH) and self:ums_lun() ~= nil', 'self:ums_lun() ~= nil'),
 ('M71', 'UMS: lun0/file wins over mtp.sh', 'not self.env.exists(M.MTP_SH) and self:ums_lun() ~= nil', 'self:ums_lun() ~= nil'),
 ('M72', 'UMS: host never detected', '        if self:udc_configured() then\n            self.state, self.connected_at = "connected", now', '        if false then\n            self.state, self.connected_at = "connected", now'),
 ('M73', 'UMS: eject not detected', 'self.last_started = 0', 'self.last_started = 1'),
 ('M74', 'Unplug is not checked by poll', 'if not self:cable_in() then\n            self:log("info", "cable unplugged, stopping")', 'if false then\n            self:log("info", "cable unplugged, stopping")'),
 ('M75', 'UMS: probe still demands the MTP responder', 'ums or M.first_pid(self:sh("pidof tizen-mtp")) ~= nil', 'M.first_pid(self:sh("pidof tizen-mtp")) ~= nil'),
 ("M26", "Host check after the timeout check", None, None),
]
MAIN = "kindlemtp.koplugin/main.lua"
M += [
 ("M30", "CloseWidget refreshes a closing browser", 'finish(nil, event == "CloseWidget")', 'finish()', MAIN),
 ("M31", "No repaint before Reset", '                            UIManager:forceRePaint()\n', '', MAIN),
 ("M32", "NotCharging ignores the UDC state", 'not_charging and not waiting and core:udc_configured()', 'false', MAIN),
 ("M33", "Settings not flushed before Start", '    UIManager:flushSettings()\n', '', MAIN),
 ("M34", "Load-time probe reads lipc", 'local probe_result = core:probe(true, true)', 'local probe_result = core:probe(true)', MAIN),
 ("M35", "PluginShare never restored", '    PluginShare.keepalive = saved_share.keepalive\n', '', MAIN),
 ("M43", "File browser refreshed at once, before fsp catches up", 'UIManager:scheduleIn(REFRESH_DELAY, refreshFileManager)', 'refreshFileManager()', MAIN),
 ("M44", "NotCharging while waiting ignores the charging re-read", 'if waiting then return not charging end', ''),
 ("M45", "main.lua never re-reads the cable at NotCharging", 'local charging = not_charging and waiting and core:cable_in()', 'local charging = false', MAIN),
 ("M36", "Auto-start ignores that the file manager closed during the delay", 'if fm and not core:active()', 'if not core:active()', MAIN),
 ("M48", "Stop skips sync", '    self:sh("sync")\n', ''),
 ("M49", "Cleanup ignores isMtpStarted", 'if self:started() == 0 and not env.read(M.MARKER) then', 'if not env.read(M.MARKER) then'),
 ("M50", "Cleanup ignores a new marker", 'if self:started() == 0 and not env.read(M.MARKER) then', 'if self:started() == 0 then'),
 ("M51", "Cleanup skipped", '        self:sh("rm -rf " .. M.MTP_TMP)\n', ''),
 ("M52", "Cable test ignores power supplies", 'if cable_type and online == "1" then return true end', 'if false then return true end'),
 ("M57", "Cable test drops the power-supply type filter", 'if cable_type and online == "1" then return true end', 'if online == "1" then return true end'),
 ("M58", "USB_WET counted as a cable", 'kind:find("^USB") ~= nil and kind ~= "USB_WET"', 'kind:find("^USB") ~= nil'),
 ("M53", "Cable test ignores the UDC state", 'if state ~= "" and state ~= "not attached" then return true end', 'if false then return true end'),
 ("M54", "Start only accepts charging as a cable", 'if not self:cable_in() then return nil, "no_power" end', 'if not env.charging() then return nil, "no_power" end'),
 ("M55", "main.lua waiting gate reads isCharging, not the cable", 'local charging = not_charging and waiting and core:cable_in()', 'local charging = not_charging and waiting and Device:getPowerDevice():isCharging()', MAIN),
 ("M56", "sync duration not logged", '    self:log("info", string.format("sync took %.2f s", env.now() - t0))\n', ''),
 ("M46", "Failed liblipclua read gives up instead of using lipc-get-prop", 'if ok and tonumber(v) then return tonumber(v) end', 'do return ok and tonumber(v) or nil end'),
 ("M47", "Failed liblipclua write gives up instead of using lipc-set-prop", 'if h and pcall(h.set_int_property, h, pub, prop, value) then return true end', 'if h then return (pcall(h.set_int_property, h, pub, prop, value)) end'),
 ('M76', 'Transfer dialog shown regardless of the setting', 'if G_reader_settings:isTrue("kindlemtp_show_dialog") then', 'if true then', MAIN),
 ('M77', 'Book opened during a background transfer is ignored', 'if core:active() and isBookOpen() then', 'if false then', MAIN),
]
env = dict(os.environ)
res = []
for mid, desc, old, new, *target in M:
    F = target[0] if target else "kindlemtp.koplugin/kindlemtp_core.lua"
    orig = open(os.path.join(ROOT, F)).read()
    src = orig
    if mid == "M26":
        a = '    if self:host_configured(started) then'
        i = src.index(a); j = src.index('    if now - self.started_at >= M.TIMEOUT then'); k = src.index('    return nil\nend\n\n--- Tears down')
        src = src[:i] + src[j:k] + src[i:j] + src[k:]
    else:
        assert src.count(old) == 1, (mid, src.count(old))
        src = src.replace(old, new)
    line = orig[:orig.index(old if old else '    if self:host_configured(started) then')].count("\n") + 1
    open(os.path.join(ROOT, F), "w").write(src)
    out = subprocess.run("busted -o junit", shell=True, cwd=ROOT, capture_output=True, text=True, env=env).stdout
    open(os.path.join(ROOT, F), "w").write(orig)
    failed = [re.search(r"name='[^']*?((?:EP|BVA|DT|ST|AC|EG)-[RTI]?\d+)", a).group(1)
              for a in re.findall(r"<testcase ([^>]*[^/])>\s*<(?:failure|error)", out)]
    res.append({"id": mid, "desc": desc, "line": f"{F}:{line}", "killed": bool(failed), "tests": sorted(set(failed))})
    print(mid, "KILLED" if failed else "SURVIVED", len(failed), " ".join(sorted(set(failed))[:8]))
if len(sys.argv) > 1:
    json.dump(res, open(sys.argv[1], "w"), indent=1)
sys.exit(0 if all(r["killed"] for r in res) else 1)
