-- Pure parsers of device output, fed with fixtures in spec/fixtures/.
local Mtp = require("kindlemtp_core")
local F = require("fake_env")

describe("parsers", function()
    it("EP-01 ListNames reply lists every name, com.lab126.mtp included", function()
        local names = Mtp.parse_names(F.fixture("listnames_with_mtp.txt"))
        assert.are.equal(18, #names)
        assert.are.equal("org.freedesktop.DBus", names[1])
        assert.are.equal("com.lab126.mtp", names[9])
    end)

    it("EP-02 a ListNames error or garbage gives no names", function()
        assert.are.same({}, Mtp.parse_names(F.fixture("getpid_error.txt")))
        assert.are.same({}, Mtp.parse_names(nil))
    end)

    it("EP-03 GetConnectionUnixProcessID reply gives the pid", function()
        assert.are.equal(5225, Mtp.parse_pid(F.fixture("getpid_tizen_mtp.txt")))
    end)

    it("EP-04 an error reply gives no pid", function()
        assert.is_nil(Mtp.parse_pid(F.fixture("getpid_error.txt")))
        assert.is_nil(Mtp.parse_pid(F.fixture("listnames_with_mtp.txt")))
    end)

    it("EP-05 pidof with one pid", function()
        assert.are.equal(5225, Mtp.first_pid("5225\n"))
    end)

    it("EP-06 pidof with no output", function()
        assert.is_nil(Mtp.first_pid(""))
        assert.is_nil(Mtp.first_pid(nil))
    end)

    it("EP-07 pidof with several pids takes the first", function()
        assert.are.equal(5225, Mtp.first_pid("5225 4100\n"))
    end)

    it("EP-08 /proc stat of a stopped volumd reads T", function()
        assert.are.equal("T", Mtp.proc_state(F.fixture("proc_stat_T.txt")))
    end)

    it("EP-09 /proc stat of a sleeping volumd reads S", function()
        assert.are.equal("S", Mtp.proc_state(F.fixture("proc_stat_S.txt")))
    end)

    it("EP-10 missing /proc stat gives no state", function()
        assert.is_nil(Mtp.proc_state(nil))
    end)

    it("EG-01 a comm field holding ') S ' does not fool the state parser", function()
        assert.are.equal("T", Mtp.proc_state("77 (a) S b) T 1 77 77 0 -1"))
    end)

    it("EP-11 syslog tail with the state-2 line means a host", function()
        assert.is_true(Mtp.host_seen(F.fixture("syslog_state2.txt")))
    end)

    it("EP-12 syslog tail that stops at state 1 means no host", function()
        assert.is_false(Mtp.host_seen(F.fixture("syslog_no_state2.txt")))
    end)

    it("EP-13 empty syslog tail means no host", function()
        assert.is_false(Mtp.host_seen(""))
        assert.is_false(Mtp.host_seen(nil))
    end)

    it("EP-14 marker owned by the plugin", function()
        assert.are.same({ owner = "plugin", pid = 4321, since = 1760557063 },
            Mtp.parse_marker("owner=plugin pid=4321 since=1760557063\n"))
    end)

    it("EP-15 marker owned by KOBridge", function()
        assert.are.equal("kobridge", Mtp.parse_marker("owner=kobridge pid=900 since=1760557000").owner)
    end)

    it("EP-16 malformed marker is not a marker", function()
        assert.is_nil(Mtp.parse_marker("owner=plugin"))
        assert.is_nil(Mtp.parse_marker("owner=plugin pid=x since=1"))
    end)

    it("EP-17 missing marker", function()
        assert.is_nil(Mtp.parse_marker(nil))
    end)

    it("EG-03 marker with surrounding whitespace still parses", function()
        assert.are.equal(4321, Mtp.parse_marker("  owner=plugin pid=4321 since=1  \n\n").pid)
    end)
end)
