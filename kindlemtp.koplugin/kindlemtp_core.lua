--[[--
KOReader-free core of kindlemtp: probe, bus-name lookup, state machine and device commands.

Every side effect goes through an injected `env` (see docs/design.md), so the module runs under
plain LuaJIT and busted. `M.posix_env()` builds the production env.

States: idle -> starting -> waiting_host -> connected -> stopping -> idle, plus failed.
"starting" and "stopping" only exist while start() and stop() run.
]]

local M = {}
M.__index = M

M.POLL_INTERVAL = 0.25 -- seconds between poll() calls
M.TIMEOUT = 20 -- seconds to wait for a host after startMtp
-- A marker only goes stale this long after its `since` (device clock), so a session that has
-- claimed the marker but not yet sent startMtp is never taken for a leftover. Covers TIMEOUT plus margin.
M.STALE_AFTER = 30
-- A lipc property read can block for liblipc's 10 s timeout when the responder hangs,
-- so poll() reads isMtpStarted at most this often (seconds).
M.LIPC_INTERVAL = 1
M.MARKER = "/tmp/kindlemtp.active"
M.MTP_SH = "/usr/bin/mtp.sh"
M.GADGET = "/sys/kernel/config/usb_gadget/mtpgadget"
M.DBUS_SEND = "/usr/bin/dbus-send"
M.SYSLOG = "/var/log/messages"
M.BUS = "com.lab126.mtp" -- lipc publisher and D-Bus name owned by tizen-mtp
M.POWERD = "com.lab126.powerd"

-- libmtp-helper logs this at priority 6 when the host configures USB (responder state 2).
local STATE2 = "handled state_change_event %[12%] event %[2%] current mtp state"
local LIST_NAMES = M.DBUS_SEND .. " --system --print-reply --dest=org.freedesktop.DBus"
    .. " /org/freedesktop/DBus org.freedesktop.DBus.ListNames"
local GET_PID = M.DBUS_SEND .. " --system --print-reply --dest=org.freedesktop.DBus"
    .. " /org/freedesktop/DBus org.freedesktop.DBus.GetConnectionUnixProcessID string:"

local function trim(s)
    return ((s or ""):match("^%s*(.-)%s*$"))
end

local function sq(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

---------------------------------------------------------------- pure helpers

--- Names in a `dbus-send --print-reply ... ListNames` reply.
function M.parse_names(text)
    local names = {}
    for name in ("\n" .. (text or "")):gmatch('\n%s*string "([^"]*)"') do
        names[#names + 1] = name
    end
    return names
end

--- Pid in a `GetConnectionUnixProcessID` reply, nil for an error reply or garbage.
function M.parse_pid(text)
    return tonumber(("\n" .. (text or "")):match("\n%s*uint32 (%d+)"))
end

--- First pid printed by `pidof`.
function M.first_pid(text)
    return tonumber(trim(text):match("^(%d+)"))
end

--- Process state letter from /proc/<pid>/stat. The comm field may itself hold ") ", so take the last one.
function M.proc_state(text)
    return text and text:match("^%d+ %(.*%) (%a)") or nil
end

--- `owner=<o> pid=<n> since=<epoch>` -> table, nil when missing or malformed.
--- Stale marker rule shared with KOBridge: isMtpStarted reads 0 and `since` is at least STALE_AFTER
--- seconds old on the device clock. Unparsable or future `since` counts as fresh.
function M.marker_stale(text, started, epoch)
    if started ~= 0 then return false end
    local since = tonumber(trim(text):match("since=(%d+)$"))
    return since ~= nil and since <= epoch and epoch - since >= M.STALE_AFTER
end

function M.parse_marker(text)
    local owner, pid, since = trim(text):match("^owner=(%S+) pid=(%d+) since=(%d+)$")
    if not owner then return nil end
    return { owner = owner, pid = tonumber(pid), since = tonumber(since) }
end

--- True when the syslog text has the responder's state-2 line.
function M.host_seen(text)
    return (text or ""):find(STATE2) ~= nil
end

--- Stop-trigger decision for KOReader events (main.lua). NotCharging also fires when the battery reads
--- Full with the cable still in. Connected, the UDC reads "configured" steadily, so that is the test.
--- While waiting for the host the UDC is not configured yet (about 1 s), so the test there is
--- `charging`, re-read at the event.
function M.stop_trigger(event, active, udc_configured, waiting, charging)
    if not active then return false end
    if event == "NotCharging" then
        if waiting then return not charging end
        return not udc_configured
    end
    return event == "Suspend" or event == "CloseWidget" or event == "stopPlugin"
end

--- Auto-start decision for the Charging event.
function M.should_autostart(enabled, in_filemanager, active)
    return enabled == true and in_filemanager == true and not active
end

---------------------------------------------------------------- instance

function M.new(env, opts)
    opts = opts or {}
    return setmetatable({ env = env, state = "idle", pid = opts.pid or 0 }, M)
end

function M:log(level, msg)
    self.env.log(level, "kindlemtp: " .. msg)
end

function M:sh(cmd)
    local out, ok = self.env.sh(cmd)
    return out or "", ok
end

function M:started()
    return self.env.lipc.get_int(M.BUS, "isMtpStarted")
end

function M:active()
    return self.state == "waiting_host" or self.state == "connected"
end

function M:volumd_running()
    if self.env.getenv("VOLUMD_STOPPED") == "yes" then return false end
    local pid = M.first_pid(self:sh("pidof volumd"))
    if not pid then return false end
    local st = M.proc_state(self.env.read("/proc/" .. pid .. "/stat"))
    return st ~= nil and st ~= "T"
end

--- Runs the 7 checks. Returns { ok, reason = first failing check, checks = { {reason, ok}... } }.
--- `skip_lipc` leaves out the lipc check (it can block up to 10 s), counting it as passed.
function M:probe(is_kindle, skip_lipc)
    local env = self.env
    local checks = {
        { "not_kindle", is_kindle == true },
        { "no_mtp_sh", env.exists(M.MTP_SH) == true },
        { "no_gadget", env.exists(M.GADGET) == true },
        { "no_responder", M.first_pid(self:sh("pidof tizen-mtp")) ~= nil },
        { "no_dbus_send", env.exists(M.DBUS_SEND) == true },
        { "no_lipc", skip_lipc == true or self:started() ~= nil },
        { "volumd_running", not self:volumd_running() },
    }
    local result = { ok = true, checks = {} }
    for i, c in ipairs(checks) do
        result.checks[i] = { reason = c[1], ok = c[2] }
        if not c[2] and result.ok then
            result.ok, result.reason = false, c[1]
        end
    end
    return result
end

--- D-Bus destination for the drive-mode signal: the well-known name, else the :1.N owned by tizen-mtp.
function M:bus_name()
    local out, ok = self:sh(LIST_NAMES)
    if not ok then return nil end
    local names = M.parse_names(out)
    for _, n in ipairs(names) do
        if n == M.BUS then return n end
    end
    local pid = M.first_pid(self:sh("pidof tizen-mtp"))
    if not pid then return nil end
    for _, n in ipairs(names) do
        if n:match("^:1%.%d+$") then
            local reply, rok = self:sh(GET_PID .. n)
            if rok and M.parse_pid(reply) == pid then return n end
        end
    end
    return nil
end

function M:udc_configured()
    for line in self:sh("cat /sys/class/udc/*/state 2>/dev/null"):gmatch("[^\n]+") do
        if trim(line) == "configured" then return true end
    end
    return false
end

function M:restore_keep_awake(plugin_marker)
    local v = self.saved_pss
    -- A plugin marker we did not write in this process is a crash leftover that set preventScreenSaver 1.
    if v == nil and plugin_marker then v = 0 end
    if v ~= nil then self.env.lipc.set_int(M.POWERD, "preventScreenSaver", v) end
    self.saved_pss = nil
end

function M:fail(reason)
    self:log("warn", "failed: " .. reason)
    self:stop()
    self.state, self.error = "failed", reason
    return nil, reason
end

function M:start()
    local env = self.env
    if self:active() then return nil, "already_active" end
    local stale_plugin = false
    local text = env.read(M.MARKER)
    if text then
        local marker = M.parse_marker(text)
        local started = self:started()
        -- A failed read keeps the marker.
        if started == nil then return nil, "no_lipc" end
        if not M.marker_stale(text, started, env.epoch()) then
            return nil, (marker and marker.owner == "plugin") and "already_active" or "owner_other"
        end
        self:log("info", "removing stale marker: " .. trim(text))
        env.remove(M.MARKER)
        stale_plugin = marker ~= nil and marker.owner == "plugin"
    end
    if not env.charging() then return nil, "no_power" end

    self.state, self.error = "starting", nil
    -- The marker is the lock shared with KOBridge: take it before touching the responder.
    local line = string.format("owner=plugin pid=%d since=%d\n", self.pid, env.epoch())
    if not env.write(M.MARKER, line, true) then
        local other = M.parse_marker(env.read(M.MARKER))
        if other and other.owner ~= "plugin" then
            -- Lost the race to KOBridge: nothing was sent, its session stays as it is.
            self:log("warn", "marker taken by " .. other.owner .. ", backing off")
            self.state = "idle"
            return nil, "owner_other"
        end
        self:log("warn", "failed: marker_failed")
        self.state, self.error = "failed", "marker_failed"
        return nil, "marker_failed"
    end
    -- From here on a failure tears down and removes our marker (fail -> stop).
    self.dest = self:bus_name()
    if not self.dest then return self:fail("bus_name_not_found") end
    -- Reset, as in the recipe: leaves the responder in state 4.
    self:sh(M.MTP_SH .. " udc disable")
    env.lipc.set_int(M.BUS, "stopMtp", 1)
    self.baseline = tonumber(trim(self:sh("wc -l < " .. M.SYSLOG)))
    if not env.lipc.set_int(M.BUS, "startMtp", 1) then return self:fail("startmtp_failed") end
    self.saved_pss = stale_plugin and 0 or (env.lipc.get_int(M.POWERD, "preventScreenSaver") or 0)
    env.lipc.set_int(M.POWERD, "preventScreenSaver", 1)

    self.started_at, self.udc_seen, self.lipc_at = env.now(), false, nil
    self.state = "waiting_host"
    self:log("info", "waiting for host, signal goes to " .. self.dest)
    return true
end

-- One shell round trip per tick: gadget UDC file, syslog line count, new responder lines.
function M:host_configured(started)
    local out = self:sh(string.format(
        "cat %s/UDC 2>/dev/null; echo @@; wc -l < %s; echo @@; tail -n +%d %s | grep -F mtp-responder",
        M.GADGET, M.SYSLOG, (self.baseline or 0) + 1, M.SYSLOG))
    local udc, count, log = out:match("^(.-)\n?@@\n(.-)\n?@@\n?(.*)$")
    if not udc then return false end
    count = tonumber(trim(count))
    if count and not self.baseline then
        self.baseline, log = count, "" -- wc failed at start: watch from now on
    elseif count and count < self.baseline then
        -- ponytail: syslog rotated after start; the new file only holds lines written since, so read it whole.
        self.baseline = 0
    end
    if M.host_seen(log) then return true end
    -- Secondary hint: the responder unbinds the gadget at state 2.
    udc = trim(udc)
    if udc ~= "" then
        self.udc_seen = true
        return false
    end
    return self.udc_seen and started == 1
end

--- Called every POLL_INTERVAL. Returns an event when something changed:
--- "connected", "timeout", "dropped", "released", or "failed" plus a reason.
function M:poll()
    if not self:active() then return nil end
    local marker = M.parse_marker(self.env.read(M.MARKER))
    if not marker or marker.owner ~= "plugin" then
        -- Someone else (KOBridge) stopped or took over: release our side only.
        self:log("info", "marker gone or taken over, releasing")
        self:restore_keep_awake(false)
        self.state = "idle"
        return "released"
    end
    local now = self.env.now()
    if not self.lipc_at or now - self.lipc_at >= M.LIPC_INTERVAL then
        self.lipc_at, self.last_started = now, self:started()
    end
    local started = self.last_started
    if started == 0 then
        self:log("warn", "responder dropped out (isMtpStarted 0)")
        self:stop()
        return "dropped"
    end
    if self.state == "connected" then return nil end

    if self:host_configured(started) then
        local _, ok = self:sh(M.DBUS_SEND .. " --system --dest=" .. self.dest
            .. " --type=signal /default com.lab126.volumd.driveModeStateChanged int32:1")
        if not ok then
            local _, reason = self:fail("signal_failed")
            return "failed", reason
        end
        self.state = "connected"
        self:log("info", "host configured USB, drive mode sent")
        return "connected"
    end
    if now - self.started_at >= M.TIMEOUT then
        self:log("info", "no host within " .. M.TIMEOUT .. " s")
        self:stop()
        return "timeout"
    end
    return nil
end

--- Tears down from any state, whoever owns the marker.
function M:stop()
    local env = self.env
    self.state = "stopping"
    env.lipc.set_int(M.BUS, "stopMtp", 1)
    -- stopMtp from state 3 does not unbind the UDC.
    self:sh(M.MTP_SH .. " udc disable")
    local marker = M.parse_marker(env.read(M.MARKER))
    self:restore_keep_awake(marker ~= nil and marker.owner == "plugin")
    env.remove(M.MARKER)
    self.state = "idle"
    return true
end

--- Restarts a wedged responder, then stops.
function M:reset()
    local _, ok = self:sh("restart mtp")
    self:stop()
    if not ok then return nil, "restart_failed" end
    return true
end

---------------------------------------------------------------- production env

--- Env backed by io.popen, io/lfs and liblipclua (lipc-set-prop/lipc-get-prop when it is missing).
--- `o` may set charging, now, log and, for tests, liblipc (a liblipclua stand-in, or false for none).
function M.posix_env(o)
    o = o or {}
    local env = {
        getenv = os.getenv,
        now = o.now or os.time,
        epoch = os.time, -- device wall clock, for the marker's since=
        charging = o.charging or function() return false end,
        log = o.log or function() end,
    }

    function env.sh(cmd)
        local f = io.popen("(" .. cmd .. ")\necho \"@kindlemtp_rc=$?\"", "r")
        if not f then return "", false end
        local out = f:read("*a") or ""
        f:close()
        local body, rc = out:match("^(.-)@kindlemtp_rc=(%d+)%s*$")
        if not body then return out, false end
        return body, rc == "0"
    end

    function env.read(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local text = f:read("*a")
        f:close()
        return text
    end

    function env.write(path, text, exclusive)
        if exclusive then
            -- set -C (noclobber) makes the shell create the file with O_EXCL.
            local _, ok = env.sh("set -C; printf '%s' " .. sq(text) .. " 2>/dev/null > " .. sq(path))
            return ok
        end
        local f = io.open(path, "wb")
        if not f then return false end
        f:write(text)
        f:close()
        return true
    end

    function env.remove(path)
        os.remove(path)
    end

    local has_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not has_lfs then has_lfs, lfs = pcall(require, "lfs") end
    function env.exists(path)
        if has_lfs then return lfs.attributes(path, "mode") ~= nil end
        local f = io.open(path, "rb")
        if f then f:close() end
        return f ~= nil
    end

    local liblipc = o.liblipc
    if liblipc == nil then
        local ok, mod = pcall(require, "liblipclua")
        liblipc = ok and mod or false
    end
    local handle
    local function lipc_handle()
        if liblipc and handle == nil then
            local ok, h = pcall(liblipc.init, "com.github.koreader.kindlemtp")
            handle = ok and h or false
        end
        return handle
    end
    env.lipc = {
        set_int = function(pub, prop, value)
            local h = lipc_handle()
            if h then return (pcall(h.set_int_property, h, pub, prop, value)) end
            local _, ok = env.sh(string.format("lipc-set-prop -i %s %s %d", pub, prop, value))
            return ok
        end,
        get_int = function(pub, prop)
            local h = lipc_handle()
            if h then
                local ok, v = pcall(h.get_int_property, h, pub, prop)
                return ok and tonumber(v) or nil
            end
            local out, ok = env.sh(string.format("lipc-get-prop -eiq %s %s", pub, prop))
            return ok and tonumber(out:match("%-?%d+")) or nil
        end,
    }
    return env
end

return M
