-- Production env adapter, run for real on the build machine (sh, files) with lipc stubbed.
local Mtp = require("kindlemtp_core")

local function tmpdir()
    local env = Mtp.posix_env{ liblipc = false }
    local out = env.sh("mktemp -d")
    return (out:gsub("%s+$", "")), env
end

local function recording_env(liblipc)
    local env = Mtp.posix_env{ liblipc = liblipc }
    local cmds = {}
    env.sh = function(cmd)
        cmds[#cmds + 1] = cmd
        return "1\n", true
    end
    return env, cmds
end

describe("posix env", function()
    it("EP-40 sh returns the output and ok for exit 0", function()
        local out, ok = Mtp.posix_env{ liblipc = false }.sh("echo hello")
        assert.are.equal("hello\n", out)
        assert.is_true(ok)
    end)

    it("EP-41 sh reports a non-zero exit as not ok", function()
        local out, ok = Mtp.posix_env{ liblipc = false }.sh("echo partial; exit 3")
        assert.are.equal("partial\n", out)
        assert.is_false(ok)
    end)

    it("EP-42 sh keeps output with no trailing newline", function()
        assert.are.equal("abc", (Mtp.posix_env{ liblipc = false }.sh("printf abc")))
    end)

    it("EP-43 read of a missing file is nil", function()
        assert.is_nil(Mtp.posix_env{ liblipc = false }.read("/nonexistent/kindlemtp"))
    end)

    it("EP-44 write then read round-trips, remove deletes", function()
        local dir, env = tmpdir()
        local path = dir .. "/f"
        assert.is_true(env.write(path, "x=1\n"))
        assert.are.equal("x=1\n", env.read(path))
        env.remove(path)
        assert.is_false(env.exists(path))
        os.remove(dir)
    end)

    it("EP-45 exclusive write fails when the file exists and keeps it", function()
        local dir, env = tmpdir()
        local path = dir .. "/marker"
        assert.is_true(env.write(path, "owner=kobridge pid=1 since=1\n"))
        assert.is_false(env.write(path, "owner=plugin pid=2 since=2\n", true))
        assert.are.equal("owner=kobridge pid=1 since=1\n", env.read(path))
        env.remove(path)
        os.remove(dir)
    end)

    it("EP-46 exclusive write creates a missing file", function()
        local dir, env = tmpdir()
        local path = dir .. "/marker"
        assert.is_true(env.write(path, "owner=plugin pid=2 since=2\n", true))
        assert.are.equal("owner=plugin pid=2 since=2\n", env.read(path))
        env.remove(path)
        os.remove(dir)
    end)

    it("EG-02 exclusive write survives quotes and spaces in text and path", function()
        local dir, env = tmpdir()
        local path = dir .. "/it's a marker"
        assert.is_true(env.write(path, "a 'quoted' $HOME\n", true))
        assert.are.equal("a 'quoted' $HOME\n", env.read(path))
        env.remove(path)
        os.remove(dir)
    end)

    it("EP-47 exists is true for a directory and false for a missing path", function()
        local env = Mtp.posix_env{ liblipc = false }
        assert.is_true(env.exists("/"))
        assert.is_false(env.exists("/nonexistent/kindlemtp"))
    end)

    it("EP-48 without liblipclua, set_int runs lipc-set-prop -i", function()
        local env, cmds = recording_env(false)
        assert.is_true(env.lipc.set_int("com.lab126.mtp", "startMtp", 1))
        assert.are.same({ "lipc-set-prop -i com.lab126.mtp startMtp 1" }, cmds)
    end)

    it("EP-49 without liblipclua, get_int runs lipc-get-prop -eiq and parses the number", function()
        local env, cmds = recording_env(false)
        assert.are.equal(1, env.lipc.get_int("com.lab126.mtp", "isMtpStarted"))
        assert.are.same({ "lipc-get-prop -eiq com.lab126.mtp isMtpStarted" }, cmds)
    end)

    it("EP-50 with liblipclua, calls go through one handle opened as com.github.koreader.kindlemtp", function()
        local inits, props = {}, {}
        local handle = {
            set_int_property = function(_, pub, prop, v) props[pub .. " " .. prop] = v end,
            get_int_property = function(_, pub, prop) return props[pub .. " " .. prop] end,
        }
        local env, cmds = recording_env({ init = function(name) inits[#inits + 1] = name; return handle end })
        assert.is_true(env.lipc.set_int("com.lab126.powerd", "preventScreenSaver", 1))
        assert.are.equal(1, env.lipc.get_int("com.lab126.powerd", "preventScreenSaver"))
        assert.are.same({ "com.github.koreader.kindlemtp" }, inits)
        assert.are.same({}, cmds)
    end)

    it("EP-52 require('liblipclua') failing (forced via package.preload) selects the lipc-*-prop fallback", function()
        local saved_loaded, saved_preload = package.loaded.liblipclua, package.preload.liblipclua
        package.loaded.liblipclua = nil
        package.preload.liblipclua = function() error("module 'liblipclua' not found") end
        local env = Mtp.posix_env{}
        package.loaded.liblipclua, package.preload.liblipclua = saved_loaded, saved_preload
        local cmds = {}
        env.sh = function(cmd) cmds[#cmds + 1] = cmd; return "", true end
        env.lipc.set_int("com.lab126.mtp", "stopMtp", 1)
        assert.are.same({ "lipc-set-prop -i com.lab126.mtp stopMtp 1" }, cmds)
    end)

    it("EP-51 a liblipclua error gives false or nil, never an exception", function()
        local handle = {
            set_int_property = function() error("lipc error 3") end,
            get_int_property = function() error("lipc error 3") end,
        }
        local env = recording_env({ init = function() return handle end })
        assert.is_false(env.lipc.set_int("com.lab126.mtp", "startMtp", 1))
        assert.is_nil(env.lipc.get_int("com.lab126.mtp", "isMtpStarted"))
    end)
end)
