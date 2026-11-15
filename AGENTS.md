# openwrt-leigodacc-manager-fw4

Leigod game accelerator manager for iStoreOS 25.12 (OpenWrt 25.12, apk) fw4/nftables. Single-file shell script (`leigod-fw4.sh`, ~5000 lines) with an embedded LuCI web UI. Wraps the closed-source `acc-gw` binary from Leigod's CDN (`119.3.40.126`).

## Commands

No build step. The script is self-contained.

- **Deploy**: `scp leigod-fw4.sh root@<router>:/root/ && ssh ... chmod +x ... && ./leigod-fw4.sh`
- **Reinstall LuCI files**: menu option 3 (runs `apply_luci_fw4_patch()` which writes all embedded Lua/HTML into `/usr/lib/lua/luci/`)
- **Clear LuCI cache**: `rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* && /etc/init.d/uhttpd restart`
- **Diagnose**: `./leigod-fw4.sh diagnose` (CLI) or LuCI → 网络诊断
- **Network tuning**: `./leigod-fw4.sh tune-network` (BBR, fq_codel, conntrack_max=65536)
- **Fix tproxy**: `./leigod-fw4.sh fix-tproxy` (cron: `*/5`)

## Architecture

```
leigod-fw4.sh          ← Single-file entry point: installer + runtime manager + LuCI embedder
├── detect_firewall()       fw3 vs fw4 detection, loads nft_tproxy kernel module
├── install_leigodacc()     Downloads official plugin_install.sh → extracts binary to /usr/sbin/leigod/
├── apply_luci_fw4_patch()  Writes ALL LuCI files from heredocs into /usr/lib/lua/luci/
├── fix_acc_core_conf()     Config repair dispatcher: new layout → acc_firewall.ini (sentinel tproxy_ip), legacy → acc_core_conf.json (LAN IP)
├── acc_health_check()      Post-install wait/verify for TCP 5588 + crash-loop hints
├── port_listening()        /proc/net/tcp based LISTEN check (no `ss` on 25.12)
├── auto_pause_menu()       Idle detection → Leigod API pause; config in /etc/leigod-auto-pause.conf
├── diagnose_latency()      6-stage bufferbloat/QoS diagnosis
├── install_tproxy_watcher() Cron that calls fix-tproxy (self-deploys to /usr/sbin/leigod/)
└── main menu               13 options: install/uninstall/reinstall/toggle/service/diagnose etc.

luci-fw4-patch/           ← Standalone copies of LuCI files (also embedded in leigod-fw4.sh)
└── luasrc/
    ├── controller/acc.lua     21 routes: debug, token, autopause, status endpoints
    ├── model/cbi/leigod/      6 CBI models: service, device, autopause, debug, notice, app
    └── view/leigod/           5 HTML templates (autopause & debug have embedded JS)
```

**External dependencies**: closed-source `acc-gw` router plugin (engine `1.2.2.71` as of 2026-11; installer constant in `lib/setup.sh` still says `1.2.1.40`), OpenWrt packages (`iptables-nft`, `kmod-nft-tproxy`, `kmod-nft-nat`, `luci-compat`, `luci-lua-runtime`).

**Target platforms**:
| Platform | Package manager | LuCI runtime |
|---|---|---|
| OpenWrt ≤ 24.10 | `opkg` (`.ipk`, `/etc/opkg/distfeeds.conf`) | Lua CBI + `luci-compat` |
| OpenWrt ≥ 25.12 / iStoreOS 25.12 | `apk` (`.apk`, `/etc/apk/repositories.d/*.list`), **no opkg binary** | ucode dispatcher + Lua bridge (`luci-lua-runtime`) |

**Key files on router**:
| Path | Purpose |
|------|---------|
| `/usr/sbin/leigod/acc-gw` | The binary |
| `/usr/sbin/leigod/leigod-fw4.sh` | Deployed script (fix-tproxy cron target) |
| `/usr/sbin/leigod-auto-pause.sh` | Auto-pause cron script |
| `/tmp/acc/acc_core_conf.json` | Runtime config (tproxy_ip, acc_mode) — written by the engine |
| `/etc/config/acc_firewall.ini` | **Authoritative** config on v1.2.2.x (`backend`/`mode`/`tproxy_ip` sentinel) |
| `/etc/config/accelerator.ini` | Engine endpoints/env (url, appid, heartbeat); `[device]` is filled by the APP |
| `/etc/leigod-auto-pause.conf` | Auto-pause settings (MANUAL_DISABLE, ACCOUNT_TOKEN, etc.) |
| `/etc/config/accelerator` | UCI config for LuCI CBI |

## Conventions

- **Acceleration config**: official acc-gw has two layouts. `new` (v1.2.2.x) uses `/etc/config/acc_firewall.ini` (`[firewall] backend/mode/tproxy_ip`) as the single source of truth; `tproxy_ip` is a **per-backend sentinel** (iptables → `10.20.30.40`, nftables → `0.0.0.0`), never the LAN IP. `legacy` (v1.2.2.13) uses `/tmp/acc/acc_core_conf.json` where `tproxy_ip` must equal the LAN IP and `acc_mode` must be 2. Always branch on `acc_layout()`; never blindly rewrite `tproxy_ip`.
- **Port checks**: use `port_listening()` (`/proc/net/tcp`, hex port, state `0A`). iStoreOS 25.12 has no `ss`; `netstat` may be absent too.
- **Package manager**: never call `opkg` directly. Use `pkg_installed` / `pkg_available` / `pkg_install_raw` / `pkg_remove_raw` / `pkg_arch` / `pkg_hint` / `pkg_show_feeds`. `detect_pkg_mgr` must run before `set_fw_packages` (it sets `PKG_LIBPCAP`/`PKG_UPNP`). The official installer still calls `opkg`; `install_opkg_shim()` injects a `/tmp/leigod-pkgshim/opkg` shim through PATH for that one call.
- **Package names**: `libpcap` (opkg) vs `libpcap1` (apk); `miniupnpd` (opkg) vs `miniupnpd-nftables` (apk). Always go through `$PKG_LIBPCAP` / `$PKG_UPNP`.
- **LuCI on 25.12**: the ucode dispatcher only loads `/usr/lib/lua/luci/controller/*.lua` when `luci-lua-runtime` is installed (`load_luabridge`). Without `luci-compat` + `luci-lua-runtime` the Lua menus are silently skipped and the URL returns 404 `No page is registered`. Clear `/tmp/luci-indexcache*` and restart `rpcd` after deploying files.
- **Shell**: POSIX `#!/bin/sh`, `local` variables inside functions, `printf` over `echo` for portability.
- **LuCI CBI**: `on_commit` callbacks fail silently when ALL options are virtual (`_`-prefixed). Need at least one non-virtual option to force commit. Newer LuCI uses anonymous `TypedSection` internal IDs (e.g. `cfg0a1234`) for form field names — never hardcode `cbid.accelerator.system.xxx`.
- **Async JS in LuCI views**: CBI renders form elements AFTER `DOMContentLoaded` fires — use `document.addEventListener('change', ...)` delegation, not `querySelector` in `DOMContentLoaded`.
- **LuCI AJAX**: Use `<%=luci.dispatcher.build_url(...)%>` in templates; endpoints return JSON.
- **Auto-pause config**: `load_config()` shells the file (`. "$CONFIG_FILE"`); duplicate keys = last wins. Use `printf "# header\n" > file` then `>>` for appends.
- **Binary behavior**: `new` engines keep `/etc/config/acc_firewall.ini` as the config source and write `/tmp/acc/acc_core_conf.json` themselves (align only, never invent values). `legacy` engines regenerate the JSON on restart with `tproxy_ip=10.20.30.40`, which must be patched to the LAN IP.
- **Cron management**: `install_tproxy_watcher()` self-deploys to `/usr/sbin/leigod/` before registering cron. Check `grep -q` to skip re-registration.

## Key bugs fixed (v2.4.1+)

- **`on_commit` never fires**: all CBI options were `_`-virtual → no UCI change → Map skips commit. Fixed by replacing virtual `_ap_manual` with real `manual_disable` (later reverted to virtual + AJAX bypass due to UCI conflict).
- **Form field name mismatch**: anonymous TypedSection uses internal IDs, not `"system"`. Fixed by `find_flag()` suffix-scanning `luci.http.formvalues()`.
- **CBI render timing**: checkboxes render after `DOMContentLoaded`. Fixed with `document.addEventListener('change', ...)` event delegation.
- **fix-tproxy restart storm**: unconditionally restarted acc-gw every 2 min. Fixed: only restart if `! pgrep acc-gw`; cron interval → 5 min.
- **Script never updated**: `auto_pause_install()` skipped if script already existed. Fixed: always overwrite from embedded heredoc.
- **Token parse bug**: `key, val = line:match("ACCOUNT_TOKEN='(.*)'")` had 1 capture but 2 destructured vars (`val` always nil). Fixed to single variable.

## Notes

