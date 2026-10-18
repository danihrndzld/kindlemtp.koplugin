# kindlemtp.koplugin

A KOReader plugin that lets a computer browse and copy the Kindle's files over the USB cable (MTP) while KOReader is running. You no longer have to exit KOReader and go back to the stock Kindle interface to copy books.

It is for Kindles that talk MTP over USB, firmware 5.16 or later. Support for firmware 5.19 and 5.20 is new and has not been confirmed on a device yet (see [Supported devices](#supported-devices)). Older Kindles show up as a USB drive and do not need it.

## Contents

- [What it does](#what-it-does)
- [Supported devices](#supported-devices)
- [Requirements](#requirements)
- [Install](#install)
- [Usage](#usage)
- [What is blocked during a transfer, and why](#what-is-blocked-during-a-transfer-and-why)
- [Safety](#safety)
- [Apps on the computer](#apps-on-the-computer)
- [Troubleshooting and recovery](#troubleshooting-and-recovery)
- [How it works](#how-it-works)
- [Limits](#limits)
- [Device checklist for testers](#device-checklist-for-testers)
- [Development](#development)
- [Credits](#credits)
- [License](#license)

## What it does

When you plug a Kindle into a computer, the stock firmware starts an MTP responder (`tizen-mtp`) and a daemon (`volumd`) tells it when the computer is ready. KOReader's launcher pauses `volumd` (SIGSTOP) every time it starts, so with KOReader running the computer sees nothing.

This plugin does `volumd`'s part from inside KOReader. It starts the responder, waits for the computer to configure USB, and sends the responder the one message it was waiting for. The computer then sees the Kindle's storage as an MTP device. When you press Stop, the plugin shuts the responder down and refreshes KOReader's file browser so new books show up.

It also:

- keeps the Kindle awake and the screensaver off during the transfer, and restores your previous settings afterwards;
- stops by itself when you unplug the cable, close the sleep cover, exit KOReader, or the responder quits;
- can start by itself when you plug in the cable (off by default);
- can restart a responder that stopped answering.

## Supported devices

| Device | Status |
|---|---|
| Kindle Paperwhite, firmware 5.18.5 (kernel 5.15.41-lab126) | The command sequence was verified by hand on 2026-10-15, and the same sequence passed a live USB test from KOBridge on 2026-10-16 (responder states 4 → 1 → 2 → 3 → 4, Wi-Fi up, marker and keep-awake restored). The test fixtures are captures from this device. The plugin itself still has to pass the [device checklist](#device-checklist-for-testers) |
| Other Kindles on firmware 5.16 to 5.18.x that have `/usr/bin/mtp.sh` | Expected to work, not tested yet |
| Kindles on firmware 5.19.x and 5.20.x (reported: Scribe 5.19.5, Colorsoft 5.19.5) | Untested. 5.19 moved MTP control from lipc to an IPCF4 service, `com.lab126.mtp.service`. Since v1.1.0 the plugin calls that service through a small helper, `bin/kindlemtp-ipcf`, built from the firmware's own libraries (5.19.5 and 5.20.1 checked). The About check "Responder answers (lipc or IPCF4)" shows whether the helper reaches the service. Please report the result |
| Kindles on firmware older than 5.16 | Not needed: they use USB mass storage, which works without this plugin |
| Kobo, PocketBook, Android and other KOReader platforms | Not supported; the plugin disables itself |

If you test another model, please open an issue with the model, the firmware version and the result of the [device checklist](#device-checklist-for-testers).

## Requirements

- A jailbroken Kindle with KOReader installed.
- KOReader started through its normal launcher (`koreader.sh`, for example from KUAL). The launcher is what pauses `volumd`. If `volumd` is running, the Kindle already handles USB on its own and the plugin refuses to start.
- Firmware 5.16 or later, so that `/usr/bin/mtp.sh`, the `tizen-mtp` responder and the MTP USB gadget exist.
- A USB cable that carries data, not only power.

The plugin's About screen checks all of this on the device. See [Usage](#usage).

## Install

### With Storefront

1. Open Storefront in KOReader.
2. Search for `kindlemtp`.
3. Install it and restart KOReader.

Storefront rebuilds its catalog on its own schedule, so a new release can take a while to appear there.

### By hand

1. Download `kindlemtp.koplugin.zip` from the [Releases](../../releases) page.
2. Connect the Kindle to the computer the usual way (stock interface, or SSH) and unzip the file into `koreader/plugins/`. You should end up with:

   ```
   koreader/plugins/kindlemtp.koplugin/_meta.lua
   koreader/plugins/kindlemtp.koplugin/main.lua
   koreader/plugins/kindlemtp.koplugin/kindlemtp_core.lua
   ```

3. Restart KOReader.

## Usage

The plugin lives in the Network menu, next to the SSH server.

1. Go to the file browser. If a book is open, close it.
2. Plug the Kindle into the computer.
3. Open the top menu, go to the Network tab, then **USB file transfer (MTP)** → **Start USB file transfer**.
4. A dialog shows "Waiting for the computer…". Within a second or two it changes to "Connected. Your computer can see the Kindle's files."
5. Copy files with the computer. Books go in the `documents` folder as usual.
6. Tap **Stop transfer** when you are done. The file browser refreshes and shows the new files.

Other entries in the same menu:

| Entry | What it does |
|---|---|
| Start when plugged in | When checked, plugging in a cable while the file browser is open starts a transfer by itself, 2 seconds after KOReader reports charging. Off by default, because KOReader reports a wall charger the same way as a computer. On a wall charger the transfer ends by itself after 20 seconds without showing an error. |
| Reset the USB responder | Asks for confirmation, then restarts `tizen-mtp` (`restart mtp`) and unbinds the USB gadget. Use it when the computer no longer sees the Kindle, or after KOReader crashed during a transfer. |
| About | Shows the 7 device checks and whether each one passed. |

If no computer answers within 20 seconds of Start, the plugin stops and says so.

## What is blocked during a transfer, and why

- **Opening books.** Start is only available in the file browser, and the transfer dialog cannot be dismissed, so no book can be opened while the computer has access. KOReader rewrites a book's settings file (`.sdr/metadata.*.lua`) whenever it saves; if a book were open, it could overwrite changes made from the computer.
- **The rest of KOReader's interface.** The dialog covers the menus for the whole transfer. Tap **Stop transfer** to get them back.
- **Sleep.** The plugin turns the screensaver off (`preventScreenSaver`) and pauses KOReader's auto-suspend, because the Kindle could otherwise go to sleep in the middle of a copy while charging. Both settings go back to what they were when you stop. If you use the KeepAlive plugin, its setting is kept.

Before starting, the plugin asks KOReader to write all its settings to disk, so the files the computer sees are current.

**Do not delete or edit the `koreader` folder from the computer while KOReader is running.** KOReader keeps files open there (settings, history, the statistics database) and will write over your changes or fail. See [Safety](#safety).

## Safety

A community report warned that USB transfers with a jailbroken Kindle can corrupt the user storage. We read the stock `volumd`, `fsp` and `tizen-mtp` binaries to check what applies here.

**Why MTP is different from USB mass storage.** With USB mass storage the computer writes raw blocks to the same partition the Kindle has mounted, so two file systems drivers write one disk. With MTP there is one writer: `tizen-mtp` receives files over USB and writes them through the Kindle's own ext4 driver. Corrupting the ext4 file system is therefore not the risk here.

**The real risks, and what to do about them:**

- **Editing or updating `koreader/` from the computer while KOReader runs.** KOReader reads its own files through `/mnt/us`, which is the `fsp` layer. `fsp` opens the path again on every read and write and keeps no open files, so a file replaced or deleted from the computer is seen at once, even in the middle of a read. KOReader can then load a mix of old and new files, or crash. The stock firmware avoids this by blocking all of `/mnt/us` during a transfer; that is not possible here because KOReader runs from `/mnt/us`. Update KOReader or its plugins with KOReader closed.
- **Unplugging before Stop.** `tizen-mtp` never calls `fsync`: it writes each transfer to `/mnt/base-us/.mtp-tmp` and renames it into place. Tap **Stop transfer** and wait for the dialog to close before you unplug or put the Kindle to sleep. Stop runs `sync`, so the copied books reach flash memory, and then removes leftovers in `.mtp-tmp` from an interrupted transfer.
- **Power loss right after a copy** (empty battery, forced reboot) can leave a book as a zero-length file. The stock firmware has the same exposure. Copy the book again.
- **Books open in KOReader.** Start is refused while a book is open, as described above.

## Apps on the computer

| System | What to use |
|---|---|
| Windows | File Explorer. The Kindle appears under "This PC". No extra software. |
| Linux | Most file managers (GNOME Files, Dolphin, Thunar with gvfs-mtp or kio-mtp). Command line: `gio mount`, `jmtpfs` or `go-mtpfs`. |
| macOS | macOS has no built-in MTP support. Use an MTP app such as KindleMTP, OpenMTP or Android File Transfer. macOS's `ptpcamerad` sometimes claims the device first; if the app cannot connect, quit Photos and Image Capture, or run `killall ptpcamerad` in Terminal, and try again. |

## Troubleshooting and recovery

**The menu entry is greyed out.** A book is open. Close it and start from the file browser.

**"Connect the USB cable to the computer first."** The plugin found no sign of a cable. It counts a cable when KOReader reports charging, when the USB controller (`/sys/class/udc/*/state`) reads anything other than `not attached`, or when a power supply of type `Mains` or `USB` (not `USB_WET`) in `/sys/class/power_supply/` reads `online` 1; the last two cover a Full battery, which stops charging with the cable still in. The battery, the moisture sensor (`USB_WET`) and the wireless supply are skipped because they read online 1 with no cable. Not yet verified: whether `bd71827_ac` (type Mains) reads 1 on a computer's USB port with a Full battery. Check the cable and the port. The responder silently ignores a start request without USB power, so the plugin refuses instead.

**"volumd is running, so the Kindle already handles USB itself."** KOReader was not started through `koreader.sh`. Start it from KUAL. In this case the stock USB flow works anyway: exit KOReader and the Kindle's own USB screen appears.

**"No computer answered within 20 seconds."** The cable may be power-only, the computer may be asleep, or on macOS no MTP app is running. Check those and try again.

**"A USB transfer is already active."** A transfer is still registered from before, usually after KOReader crashed during one. Use **Reset the USB responder**.

**"Another app (KOBridge) is running a USB transfer."** The KOBridge desktop app started MTP. Stop it from KOBridge first.

**The computer stopped seeing the Kindle, or shows it but cannot list files.** Stop the transfer and start it again. If that does not help, use **Reset the USB responder**, then start again.

**After a crash.** If KOReader crashed during a transfer, two things stay on until the next Start or Reset: the screensaver stays off, and the USB gadget stays bound. **Reset the USB responder** clears both. Rebooting the Kindle also clears them.

What Reset does, step by step: `restart mtp` (restarts the `tizen-mtp` responder), `lipc-set-prop -i com.lab126.mtp stopMtp 1`, `/usr/bin/mtp.sh udc disable`, `sync`, restores `preventScreenSaver`, removes `/tmp/kindlemtp.active`, and removes `/mnt/base-us/.mtp-tmp` once the responder reads stopped.

Logs: every line the plugin writes to KOReader's `crash.log` starts with `kindlemtp:`. The responder logs to `/var/log/messages` as `mtp-responder`.

## How it works

The stock USB flow on firmware 5.16 and later:

1. `volumd` sees the cable and sets `startMtp` on `com.lab126.mtp`.
2. `tizen-mtp` binds the USB gadget. When the computer configures USB, the responder tears down its minimal transport, runs `mtp.sh notify configured` and waits (responder state 2).
3. `volumd` answers with the D-Bus signal `com.lab126.volumd.driveModeStateChanged`, value 1. `tizen-mtp` re-binds the gadget and serves files (state 3).

With KOReader running, `volumd` is paused, so steps 1 and 3 never happen. The plugin runs them itself:

| Step | Command | Responder state |
|---|---|---|
| Claim | write `/tmp/kindlemtp.active` with the shell's noclobber option (fails if the file exists) | unchanged |
| Reset | `/usr/bin/mtp.sh udc disable`; `lipc-set-prop -i com.lab126.mtp stopMtp 1` | any → 4 |
| Start | `lipc-set-prop -i com.lab126.mtp startMtp 1` | 0 or 4 → 1; the computer configures USB → 2 |
| Drive mode | `dbus-send --system --dest=com.lab126.mtp --type=signal /default com.lab126.volumd.driveModeStateChanged int32:1` | 2 → 3, the computer can open a session |
| Stop | `lipc-set-prop -i com.lab126.mtp stopMtp 1`; `/usr/bin/mtp.sh udc disable`; `sync`; then, if `isMtpStarted` reads 0 and no new marker exists, `rm -rf /mnt/base-us/.mtp-tmp` | 3 → 4 |
| Wedged | `restart mtp` | restarts the responder |

Details that matter:

- **The drive-mode signal is sent only to the responder** (`--dest=`). A broadcast also reaches `cmd`, which turns Wi-Fi off, and `blanket`, which draws the stock USB screen over KOReader.
- **`lipc-send-event` cannot send it**, because it would have to register as `com.lab126.volumd`, a name the paused `volumd` still owns. The responder's lipc subscription matches only the interface and member name, not the sender, so a plain D-Bus signal works.
- **Destination.** `tizen-mtp` opens lipc as `com.lab126.mtp` and so owns that D-Bus name. If it is not in `ListNames`, the plugin finds the responder's unique name (`:1.N`) by comparing `GetConnectionUnixProcessID` with `pidof tizen-mtp`.
- **Detecting the computer.** The responder goes from state 1 to state 2 in under a second. The plugin records the line count of `/var/log/messages` before Start and then, every 250 ms, looks for a new `mtp-responder` line containing `handled state_change_event [12] event [2] current mtp state`. As a second signal it also watches the gadget's `UDC` file go from bound to empty. It reads `isMtpStarted` at most once per second, because a lipc read can block for up to 10 seconds when the responder hangs.
- **Stopping needs both commands.** `stopMtp` from state 3 does not unbind the USB gadget, so the plugin also runs `mtp.sh udc disable`.
- **The marker file** `/tmp/kindlemtp.active` holds one line, `owner=plugin pid=<N> since=<epoch>`, created atomically with the shell's noclobber option. The KOBridge desktop app uses the same file, so the two never run a transfer at the same time. The marker is the lock, so Start takes it before sending anything to the responder: if KOBridge got there first, Start backs off without touching its session. A marker is only treated as a leftover, and removed by the other side, when `lipc-get-prop com.lab126.mtp isMtpStarted` reads 0 and its `since` (the Kindle's own clock) is at least 30 seconds old. A marker with an unreadable or future `since` is never removed that way; Stop and Reset still clear it.
- **Firmware 5.19 and later** dropped the lipc properties `startMtp`, `stopMtp` and `isMtpStarted`. The responder now takes `startMtpAsync` and `stopMtpAsync` from an IPCF4 (binder) service, `com.lab126.mtp.service`, and they set the same flag and send the same events as the old properties. No shell tool can call it, so the plugin ships `bin/kindlemtp-ipcf`, a small C program (`ipcf/kindlemtp-ipcf.c`) that loads the firmware's `libipcn.so.0` and makes those two calls. Its `ping` command only connects. On older firmware there is no `libipcn`, the helper prints `no_ipcn`, and the plugin uses lipc. Nothing reports the responder state on 5.19, so there the gadget's `UDC` file being bound stands in for `isMtpStarted`. Every other step is the same. The reverse engineering is in [docs/design.md](docs/design.md#firmware-519-2026-10-18).
- **Before Start** the plugin runs 7 checks: the device is a Kindle; `/usr/bin/mtp.sh` exists; `/sys/kernel/config/usb_gadget/mtpgadget` exists; `tizen-mtp` is running; `/usr/bin/dbus-send` exists; the responder answers over lipc or IPCF4; and `volumd` is paused (`VOLUMD_STOPPED=yes` from the launcher, or state `T` in `/proc/<pid>/stat`).

All of this is in `kindlemtp.koplugin/kindlemtp_core.lua`, which does not depend on KOReader. `main.lua` holds the menu, the dialog and the event handling. The full design is in [docs/design.md](docs/design.md).

## Limits

- **KOBridge's Files view and MTP see the storage through different paths.** MTP serves `/mnt/base-us` directly. KOReader and KOBridge's Files view use `/mnt/us`, which goes through the Kindle's `fsp` layer. Do not write to the same files from both at once.
- **`fsp` lags behind MTP for deletions.** A file copied over MTP shows in `/mnt/us` at once, but a file deleted over MTP can still be listed there for about 1 second (measured on 2026-10-16). The plugin refreshes the file browser 1 second after Stop for that reason.
- **A wall charger looks like a computer** to KOReader. With "Start when plugged in" on, a charger starts a transfer that waits 20 seconds and then ends quietly.
- **The 2-second auto-start delay** gives the responder time to notice the cable. It has not been tuned on many devices; if auto-start fails on yours but manual Start works, please report it.
- **One computer at a time.** MTP does not allow two hosts.
- **USB mass storage is not possible**: the storage is an ext4 file system mounted read-write by the Kindle, which a computer cannot share safely.
- **USB networking** is out of scope.

## Device checklist for testers

Run this list on a real Kindle before each release, and when reporting a new model. Note the model, firmware, computer and app for each run.

1. About shows all 7 checks as OK.
2. Start from the file browser with a cable to a computer: the dialog changes to "Connected" within a few seconds.
3. The computer lists the Kindle's files: KindleMTP or OpenMTP or Android File Transfer on macOS, File Explorer on Windows, a gvfs file manager on Linux.
4. Copy a book to `documents`, tap Stop: the book appears in the file browser.
5. Wi-Fi stays connected during and after the transfer (for example, an SSH session keeps working).
6. The stock USB screen never appears over KOReader.
7. With "Start when plugged in" on, plug into a wall charger: the dialog appears and closes by itself after about 20 seconds with no error.
8. Unplug the cable in the middle of a copy: the transfer stops and the file browser refreshes.
9. Close the sleep cover (or press the power button) during a transfer: the transfer stops.
10. Exit KOReader during a transfer: the transfer stops, and the stock USB flow works after KOReader has exited.
11. Make the responder stop answering (or simulate it with `stop mtp` over SSH), then use Reset: a new Start works.
12. With a book open, Start is greyed out.
13. Start KOReader without pausing `volumd` (for example `killall -CONT volumd` over SSH): Start is refused with the volumd message.
14. After Stop, `cat /tmp/kindlemtp.active` reports no such file and `lipc-get-prop com.lab126.powerd preventScreenSaver` shows the value from before the transfer.

## Development

The core (`kindlemtp_core.lua`) takes all its side effects through an injected `env` table (shell commands, file access, lipc, clock, charging state, logging), so its tests run on any computer with LuaJIT. The tests use a fake env that records every command in order (`spec/fake_env.lua`) and device outputs in `spec/fixtures/`. `main.lua` is tested by loading it with stub KOReader modules (`spec/koreader_stubs.lua`) that record each dialog, message and scheduled call.

Install the tools once (macOS with Homebrew LuaJIT shown; on Linux drop `--lua-dir`):

```sh
luarocks --lua-dir=/opt/homebrew/opt/luajit --lua-version=5.1 install --local busted
luarocks --lua-dir=/opt/homebrew/opt/luajit --lua-version=5.1 install --local luacheck
luarocks --lua-dir=/opt/homebrew/opt/luajit --lua-version=5.1 install --local luacov   # coverage only
```

Run the tests and the linter:

```sh
export PATH=$HOME/.luarocks/bin:$PATH
eval $(luarocks --lua-dir=/opt/homebrew/opt/luajit --lua-version=5.1 path)
busted
luacheck kindlemtp.koplugin spec
```

Every test name starts with a test-design ID (`EP-` equivalence partition, `BVA-` boundary value, `DT-R` decision-table rule, `ST-T`/`ST-I` valid and invalid state transition, `AC-` criterion from the design, `EG-` error guess).

Mutation check (breaks 63 key behaviors in `kindlemtp_core.lua` and `main.lua` one at a time and fails if any change goes unnoticed; the file is restored after each run):

```sh
python3 spec/mutate.py docs/test-report/mutants.json
```

Coverage:

```sh
busted -c && luacov && python3 spec/luacov_summary.py docs/test-report/coverage.json && rm luacov.*
```

The test report (in Spanish, with the technique behind every test and the mutation results) is in [docs/test-report/reporte.pdf](docs/test-report/reporte.pdf).

Fixtures: the `dbus-send` replies, `/proc` stat lines, syslog lines (with debug logs off) and the host UDC tape were captured on a Paperwhite on 2026-10-16. Three files stay synthetic: `listnames_without_mtp.txt` (for the `:1.N` fallback), `getpid_other.txt` and the charger-only UDC tape. [spec/fixtures/README.md](spec/fixtures/README.md) lists the source of each file.

GitHub Actions runs busted and luacheck on every push and pull request. Pushing a tag such as `v1.0.0` builds `kindlemtp.koplugin.zip` and publishes a release. Avoid `alpha`, `beta`, `rc`, `dev`, `preview` and `test` in tag names; Storefront treats those as pre-releases. To check the zip locally:

```sh
zip -r kindlemtp.koplugin.zip kindlemtp.koplugin -x "*.git*" "*/.*"
unzip -l kindlemtp.koplugin.zip
```

## Credits

- [KOReader](https://github.com/koreader/koreader) and its contributors. The lipc and plugin code here follows KOReader's own Kindle code and SSH plugin.
- The `tizen-mtp` responder that Amazon ships on the Kindle, based on Samsung's Tizen mtp-responder.
- [Storefront](https://github.com/ultimatejimmy/storefront.koplugin) for KOReader plugin distribution.
- KOBridge, the desktop app that shares the marker-file contract with this plugin.

## License

AGPL-3.0-or-later. The plugin runs inside KOReader's process alongside its AGPL frontend. See [LICENSE](LICENSE).
