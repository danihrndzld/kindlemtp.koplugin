# kindlemtp.koplugin design (2026-10-15)

A KOReader plugin that lets a computer browse and copy files over the USB cable (MTP) on MTP-era Kindles while KOReader runs, without restarting into the stock Kindle UI.

## Problem

On MTP-era Kindles (firmware 5.16+; verified on a Paperwhite with 5.18.5, kernel 5.15.41-lab126), the stock USB flow is:

1. `volumd` sees the cable and sets `startMtp` on `com.lab126.mtp`.
2. `tizen-mtp` (with `libmtp-helper.so.1`) binds the USB gadget. When the host configures USB it tears down its minimal transport, runs `mtp.sh notify configured` and waits.
3. `volumd` answers `usbConfigured` with the `com.lab126.volumd driveModeStateChanged` event, value 1. `tizen-mtp` re-binds the gadget and serves files.

KOReader's launcher (`platform/kindle/koreader.sh`) sends SIGSTOP to `volumd` in every launch mode, so steps 1 and 3 never happen and the computer sees nothing.

## Recipe (verified 2026-10-15)

| Step | Command | tizen-mtp state |
|---|---|---|
| Claim | `set -C; echo 'owner=… pid=… since=…' > /tmp/kindlemtp.active` (fails if the file exists) | unchanged |
| Reset | `/usr/bin/mtp.sh udc disable`; `lipc-set-prop -i com.lab126.mtp stopMtp 1` | any → 4 |
| Start | `lipc-set-prop -i com.lab126.mtp startMtp 1` | 0/4 → 1; host configures USB → 2 |
| Drive mode | `dbus-send --system --dest=<tizen-mtp's bus name> --type=signal /default com.lab126.volumd.driveModeStateChanged int32:1` | 2 → 3, host can open a session |
| Stop | `lipc-set-prop -i com.lab126.mtp stopMtp 1`; `/usr/bin/mtp.sh udc disable` | 3 → 4 |
| Wedged | `restart mtp` | restarts the responder |

- The drive-mode signal must be **unicast**. A broadcast also reaches `cmd`, which turns Wi-Fi off, and `blanket`, which draws the stock USB screen over KOReader. Both were observed.
- `lipc-send-event` cannot send it: it must `LipcOpen("com.lab126.volumd")`, a name the stopped `volumd` still owns. liblipc subscribers match only interface and member, never the sender, so a plain D-Bus signal is accepted.
- Destination: `--dest=com.lab126.mtp`. liblipc's open path calls `dbus_bus_request_name` on the source name, and libmtp-helper opens lipc as `com.lab126.mtp`, so `tizen-mtp` owns that well-known name (to confirm with `ListNames`). Fallback only: match `GetConnectionUnixProcessID` of each `:1.N` against `pidof tizen-mtp` (`:1.3` on 2026-10-15; changes per boot).
- MTP serves `/mnt/base-us` directly, bypassing the `fsp` FUSE layer that KOReader reads at `/mnt/us`.

## Scope

- In: start and stop MTP from KOReader's menu; optional start when the cable is plugged in; keep the device awake and the screen blocked during the transfer; refresh the file browser afterwards; recover a wedged responder.
- Out: USB mass storage (the userstore is ext4 mounted read-write; not viable), USB networking, older Kindles with USB mass storage (they don't need this), Kobo and other devices.

## Name and placement

- Repo, folder and Storefront entry: `kindlemtp.koplugin`. Storefront renames the extracted folder to `repo.name` (storefront_installer.lua:230-236), so equal names avoid a mismatch.
- `_meta.lua`: `fullname = _("USB file transfer (MTP)")`, `description`. The plugin `name = "kindlemtp"` goes in `WidgetContainer:extend`.
- Menu: `menu_items.kindlemtp` with `sorting_hint = "network"`, next to SSH. Without a hint MenuSorter prefixes "NEW: ".

## User experience

**Menu** (Network → USB file transfer (MTP)):
- "Start USB file transfer". Enabled only in the file manager (`self.ui.document == nil`); in the reader its help text says "Close the book first".
- "Start when plugged in" (checkbox, off by default). KOReader gets `Charging` for a wall charger too, so it can't be on by default.
- "Reset the USB responder" (for a wedged `tizen-mtp`), behind a ConfirmBox.
- "About" with the device check results.

**While active:** a non-dismissable `ButtonDialog` with one "Stop transfer" button and a status line:
- "Waiting for the computer…" after Start.
- "Connected. Your computer can see the Kindle's files." after the drive-mode signal.
- An error text with the step that failed.

**Start needs power on the cable.** `startMtp` is silently skipped by the responder without USB power (`usb_plugin` unset), while `isMtpStarted` still reads 1 (it is a flag, not a state). Start is refused when `Device.powerd:isCharging()` is false ("Connect the cable first").

**Stops automatically** on:
- `NotCharging`, but only when `/sys/class/udc/*/state` is not `configured`. `NotCharging` also fires when the battery reads Full with the cable still in.
- `Suspend`.
- `CloseWidget` (the file manager closing, which includes KOReader exiting). `stopPlugin` is not an exit hook; it runs only when the user disables the plugin, and also stops.
- The responder dropping out (`isMtpStarted` reads 0 during the poll): the dialog closes.

After stopping, the file browser runs `refreshPath()`. A crash during a transfer leaves `preventScreenSaver 1` and the gadget bound until the next Start or Reset; the README explains recovery.

**Keeps awake:** saves the current `preventScreenSaver` value and `PluginShare.keepalive`, then sets `PluginShare.pause_auto_suspend = true`, `PluginShare.keepalive = true` and `preventScreenSaver 1`. Stop restores the saved values, so a KeepAlive user keeps theirs. Without this, powerd's own timer can suspend the device mid-copy while charging.

**Auto-start** ("Start when plugged in") acts only in a file manager instance; in the reader it does nothing.

## Architecture

```
kindlemtp.koplugin/
  _meta.lua      fullname, description
  main.lua       WidgetContainer: menu, events, dialogs, scheduling (thin)
  mtp.lua        KOReader-free core: probe, bus-name lookup, state machine, commands
spec/            busted tests for mtp.lua (no KOReader needed)
```

`mtp.lua` takes an injected environment so it runs under plain LuaJIT and busted:

```lua
local env = {
  sh = function(cmd) return output, ok end,   -- io.popen in production
  read = function(path) return text end,       -- file read, nil when missing
  write = function(path, text, exclusive) return ok end,
  remove = function(path) end,
  exists = function(path) return bool end,
  getenv = function(name) return value end,
  lipc = { set_int = fn, get_int = fn },        -- liblipclua or lipc-set-prop fallback
  charging = function() return bool end,        -- Device.powerd:isCharging()
  now = function() return seconds end,         -- monotonic, for the 20 s timeout and polling
  epoch = function() return seconds end,       -- device wall clock (os.time()), for the marker's since=
  log = function(level, msg) end,
}
```

Fixtures (captured on the device, in `spec/fixtures/`): `ListNames` with and without `com.lab126.mtp`; a `GetConnectionUnixProcessID` reply; a timed tape of UDC file, UDC state and `isMtpStarted` for a host connect and for a charger only; `/proc/<pid>/stat` with `T` and `S`; syslog tails with and without the state-2 line.

### Probe (runs once at load and before Start)

Every check returns a reason the UI can show:

1. `Device:isKindle()`; otherwise `return { disabled = true }` at load.
2. `/usr/bin/mtp.sh` exists.
3. `/sys/kernel/config/usb_gadget/mtpgadget` exists.
4. `pidof tizen-mtp` returns a pid.
5. `/usr/bin/dbus-send` exists.
6. `lipc-get-prop -eiq com.lab126.mtp isMtpStarted` answers.
7. `volumd` is stopped: `os.getenv("VOLUMD_STOPPED") == "yes"` (set by koreader.sh), else `/proc/<pid of volumd>/stat` state `T`. If `volumd` runs, the stock flow already handles USB and the plugin refuses with a message.

### State machine (`mtp.lua`)

States: `idle → starting → waiting_host → connected → stopping → idle`, plus `failed`.

- **start()**: refuses with `already_active` when the marker exists and is valid, or `owner_other` when another owner holds it; refuses `no_power` without charging. Then claim the marker (exclusive write), and only after that reset, record the syslog line count and send `startMtp 1`. The marker is the lock shared with KOBridge, so it must be taken before touching the responder: a lost race (the exclusive write fails because a KOBridge marker exists) returns `owner_other` with zero device commands, and any failure after the claim tears down and removes our own marker. Moves to `waiting_host`. (Revised 2026-10-16; the first version wrote the marker after `startMtp`, so a lost race had already reset KOBridge's session.) The responder itself ignores a second `startMtp` outside states 0 and 4.
- **poll()** (every 250 ms from `UIManager:scheduleIn`, never blocking): detects state 2 (rule below), then sends the drive-mode signal once and moves to `connected`. After 20 s without a host it stops quietly and returns `timeout`. In `connected`, a 0 from `isMtpStarted` means the responder dropped out: stop.
- **stop()**: idempotent from every state, whoever owns the marker: `stopMtp 1`, then `mtp.sh udc disable` (needed: `stopMtp` from state 3 does not unbind the UDC), restore keep-awake, remove the marker. Moves to `idle`. After an unplug in `waiting_host` the responder parks in state 1 or 2 and only `stopMtp` clears it, so `NotCharging` must drive stop.
- **reset()**: `restart mtp`, then stop.
- No "active" flag lives in the widget instance (instances die on every file manager ↔ reader switch). The truth is the marker plus `isMtpStarted`.

### Marker contract (shared with KOBridge)

- Path `/tmp/kindlemtp.active`, one line: `owner=plugin|kobridge pid=<N> since=<epoch>`.
- Created atomically (`set -C; echo … > file`), before any command reaches the responder. `since` comes from the Kindle's own clock on both sides (the plugin's `os.time()`, KOBridge's `date +%s` run on the device), so ages compare on one clock.
- Stale rule (revised 2026-10-16): a marker is stale only when `isMtpStarted` reads 0 **and** `since` is at least 30 s old. Only a stale marker may be removed by the other side. 30 s covers the 20 s host wait plus margin, and closes the window between a fresh claim and its `startMtp`, when `isMtpStarted` still reads 0. The pid is not used (KOBridge's is a dead shell pid). A marker with an unparsable or future `since` counts as fresh. A failed `isMtpStarted` read refuses Start (`no_lipc`) and keeps the marker.
- Start refuses when a fresh marker exists: `owner_other` for another owner, `already_active` for the plugin's own. Stop always tears down, whatever the owner.
- The plugin's poll closes its dialog when the marker disappears or `isMtpStarted` drops to 0 (KOBridge stopped it).

### Host detection

The responder goes 1 → 2 within one second (19:37:43 in `mtp-startmtp-log.txt`), and the UDC file is empty both before the bind and at state 2, so polling the UDC file can't see "bound, then empty".

- Primary: record `wc -l < /var/log/messages` before `startMtp`, then poll for a new line matching `handled state_change_event \[12\] event \[2\] current mtp state`. It is logged at priority 6 outside the debug flag (libmtp-helper.c:1124). To confirm on the device without `enableDebugLog`.
- Secondary hint: UDC file empty and `isMtpStarted` = 1 after having seen it bound.
- Not used: `usbConfigured` on `com.lab126.hal`, which `mtp.sh` skips under `FLAG_NO_TRANSITIONS` / `FLAG_FONT_UPDATE`.

### Bus name

1. `--dest=com.lab126.mtp` (primary, see Recipe).
2. Fallback if `ListNames` lacks it: scan `:1.N` with `GetConnectionUnixProcessID` against `pidof tizen-mtp`, a few calls at most once per Start. Parsing `--print-reply` output is a pure function with fixtures from the device.

### lipc

Use `pcall(require, "liblipclua")` with `lipc.init("com.github.koreader.kindlemtp")`, as `kindleEnableWifi` does in `frontend/device/kindle/device.lua`. Fall back to `lipc-set-prop -i` / `lipc-get-prop -eiq` through `sh`.

## Safety

- Refuse to start with a book open: ReaderUI rewrites the sidecar on every flush and would overwrite edits made from the computer.
- `UIManager:flushSettings()` before Start, so `settings.reader.lua` and sidecars on disk are current.
- The dialog blocks the menus for the whole transfer.
- README warning: don't delete or edit the `koreader` folder from the computer while KOReader runs.
- To verify on the device: a file copied over MTP shows in `lfs.dir("/mnt/us/…")` at once (fsp may cache attributes).

## Errors

Each failing step maps to a message naming it (`startMtp` refused, no host within 20 s, bus name not found, `dbus-send` failed, wedged responder). Messages use `_()` for translation. Logs go through `logger.info/warn` with the prefix `kindlemtp:`.

## Testing

**Unit (busted, plain LuaJIT, no KOReader):** `mtp.lua` with a fake `env` that records commands and replays device outputs captured on 2026-10-15.
- Probe: each of the 7 checks failing gives its own reason; all passing gives `ok`.
- Bus-name lookup: well-known name present; `:1.N` scan finds the pid; pid absent → error; malformed `--print-reply` text.
- State machine: start → waiting_host → connected sends the signal exactly once; charger-only → 20 s timeout → stop; stop is idempotent from every state; stop during `waiting_host`; reset; command order matches the recipe; the signal is always unicast (`--dest=` present, never a broadcast).
- Every test is checked to fail when the behavior it guards is broken (mutation check).

**Lint:** `luacheck` with KOReader globals.

**CI:** GitHub Action runs busted and luacheck on push and pull request.

**Device checklist (before each release):** start from the file manager; host lists files (KindleMTP app, Android File Transfer, OpenMTP, Linux gvfs); copy a book and see it after stop; Wi-Fi stays up; no stock USB screen; wall charger with auto-start on → quiet timeout; unplug mid-copy → stop and refresh; sleep cover → stop; exit KOReader during a transfer → stock USB works afterwards; Reset recovers a wedged responder; Start refused with a book open; Start refused when `volumd` runs.

## Repo and release

- `README.md`: what it does, supported devices, requirements (jailbreak, KOReader launched from KUAL so `volumd` is stopped), install (Storefront or manual), usage, what's blocked and why, computer-side apps per OS (Windows Explorer and Linux file managers work natively; macOS needs an MTP app, and `ptpcamerad` may claim the device first), troubleshooting and recovery (what Reset does; a crash leaves the screensaver blocked and the gadget bound until the next Start or Reset), how it works (the recipe), limits (KOBridge's Files view writes through `/mnt/us` while MTP writes `/mnt/base-us`: don't use both at once), credits, license.
- `LICENSE`: AGPL-3.0-or-later (runs in-process with KOReader's AGPL frontend).
- `.github/workflows/test.yml`: busted + luacheck.
- `.github/workflows/release.yml`: on tag `v*`, `zip -r kindlemtp.koplugin.zip kindlemtp.koplugin -x "*.git*" "*/.*"`, published (not draft; build_catalog.py skips drafts and plugins with no release).
- Tags `v1.0.0`; avoid alpha/beta/rc/dev/preview/test in tags.
- Topics: `koreader-plugin`, `koreader`, `kindle`, `mtp`. The GitHub description becomes the Storefront description. Storefront's catalog rebuilds on its own schedule, so listing can lag.
