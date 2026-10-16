# Test fixtures

Captured on a Kindle Paperwhite, firmware 5.18.5, unless marked synthetic.

| File | Source |
|---|---|
| `listnames_with_mtp.txt` | Captured 2026-10-16: `dbus-send --system --print-reply ... ListNames` (includes `com.lab126.mtp`) |
| `listnames_without_mtp.txt` | **Synthetic**: the capture above with the `com.lab126.mtp` line removed, for the `:1.N` fallback path |
| `getpid_tizen_mtp.txt` | Captured 2026-10-16: `GetConnectionUnixProcessID string::1.3` (pid 5225, tizen-mtp) |
| `getpid_other.txt` | **Synthetic**: the capture above with the pid changed to 2214 |
| `getpid_error_stderr.txt` | Captured 2026-10-16: what `dbus-send` prints on **stderr** for an unknown name. Its stdout is empty and it exits 1, so `env.sh` returns `"", false`; the parser tests feed this text only to check it is rejected |
| `proc_stat_T.txt` | Captured 2026-10-16: `/proc/<volumd>/stat`, state T (stopped by koreader.sh) |
| `proc_stat_S.txt` | Captured 2026-10-16: `/proc/<tizen-mtp>/stat`, state S (a running process) |
| `syslog_full_run.txt` | Captured 2026-10-16 with debug logs off: the last 60 `mtp-responder` lines of a full 4 → 1 → 2 → 3 → 4 run |
| `syslog_state2.txt` | Lines 9-21 of `syslog_full_run.txt`: from `start MTP callback` to the state-2 line |
| `syslog_no_state2.txt` | Lines 9-15 of `syslog_full_run.txt`: up to state 1 |
| `syslog_debug_on.txt` | Captured 2026-10-15 with `enableDebugLog` on (`mtp-startmtp-log.txt`) |
| `udc_tape_host.txt` | Captured 2026-10-16 (device-checks.sh host trace). `t` is the loop index x 0.25 s; the loop's `sleep 0.5` failed on BusyBox, so real spacing is shorter |
| `udc_tape_charger.txt` | **Synthetic**: no charger-only capture yet |
