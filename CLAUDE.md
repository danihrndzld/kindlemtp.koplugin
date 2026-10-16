# CLAUDE.md

KOReader plugin that turns on USB file transfer (MTP) on MTP-era Kindles while KOReader runs. Released on GitHub (danihrndzld/kindlemtp.koplugin) and listed by Storefront. The design and its revisions are in `docs/design.md`; read it before changing behavior.

## Commands

```sh
export PATH=$HOME/.luarocks/bin:$PATH
eval $(luarocks --lua-dir=/opt/homebrew/opt/luajit --lua-version=5.1 path)
busted                              # all specs
busted spec/state_spec.lua          # one file
luacheck kindlemtp.koplugin spec    # must stay at 0 warnings
python3 spec/mutate.py              # mutation check: exits 1 if any mutant survives
```

Install on the Kindle for a manual test (KOReader must be restarted to load it):
`COPYFILE_DISABLE=1 tar cf - kindlemtp.koplugin | ssh kindle 'cd /mnt/us/koreader/plugins && tar xf -'`. Without `COPYFILE_DISABLE=1`, macOS adds `._*` files.

## Layout

- `kindlemtp.koplugin/kindlemtp_core.lua`: everything KOReader-free: probe, marker, bus name, host detection, state machine, decision helpers (`stop_trigger`, `should_autostart`, `marker_stale`), plus the production `posix_env`. It takes an injected `env`, so it runs under plain LuaJIT.
- `kindlemtp.koplugin/main.lua`: thin `WidgetContainer`: menu, dialog, events, `UIManager:scheduleIn` polling. Never block the UI thread and never shell out to `sleep`.
- `spec/`: busted specs; `fake_env.lua` records every command and errors on unexpected ones; `koreader_stubs.lua` preloads KOReader modules for `main_spec.lua`; `fixtures/` (its README marks which are captured from the device and which are synthetic).
- `docs/test-report/`: report generated with the `testing-and-continuous-delivery` skill (Spanish). Regenerate it when test or mutant counts change.

The core file is named `kindlemtp_core.lua`, not `mtp.lua`: KOReader puts every plugin folder on one `package.path`, so a generic name can collide.

## Rules

- **The recipe is shared with KOBridge.** `~/Developer/KOBridge/src-tauri/src/usb.rs` duplicates it and copies the fixtures. Any change to the order, marker contract, stale rule or host detection goes to both repos in the same session.
- **Claim the marker first.** `/tmp/kindlemtp.active` is the lock: claim it with an exclusive write before touching the responder. A lost claim sends no device command. Any failure after the claim tears down and removes our marker.
- **Never broadcast the drive-mode signal.** Always `--dest=com.lab126.mtp`; a broadcast turns Wi-Fi off and draws the stock USB screen.
- **lipc reads can block 10 s** against a wedged responder: at most one `isMtpStarted` read per second, and none at plugin load.
- **Every behavior change needs a test and a mutant** in `spec/mutate.py` that the test kills.
- Commits: author Daniel Hernández <danisnowman@gmail.com>, no Co-Authored-By or Claude lines.

## Release

Tag `vX.Y.Z` and push the tag. `release.yml` zips `kindlemtp.koplugin/` into `kindlemtp.koplugin.zip` and publishes a full release. Storefront's `build_catalog.py` skips drafts and drops plugins without a release, so never publish as a draft, and keep words like alpha, beta, rc, dev, preview or test out of tags. The repo name, folder name and topic `koreader-plugin` are what Storefront discovers; don't rename them.

CI (`test.yml`) installs busted and luacheck with luarocks on PUC Lua 5.1 and runs the tests with `busted --lua=luajit`. luarocks running under LuaJIT can't load the luarocks.org manifest ("more than 65536 constants").

## Verified so far

Only a Kindle Paperwhite on firmware 5.18.5 (2026-10-16): start from the menu, a host lists files, a copied book opens. Not yet run on a device: wall-charger auto-start, sleep cover, exiting mid-transfer, Reset recovery. Device facts and their sources are in `docs/design.md` under "Device facts".
