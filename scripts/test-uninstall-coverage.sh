#!/bin/bash
# Coverage lint for uninstall_leigodacc().
#
# Offline we cannot actually execute the uninstall (it touches absolute /etc
# paths and needs uci/apk), so instead we assert that the function body still
# references every artifact the official installer / this manager creates.
# Each entry is a substring that must appear inside the function body.
#
#   bash scripts/test-uninstall-coverage.sh

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$DIR/../leigod-fw4.sh"

BODY="$(mktemp)"
trap 'rm -f "$BODY"' EXIT

awk '
    /^uninstall_leigodacc\(\) \{/ { on = 1 }
    on && /^# Reinstall LeigodAcc/ { exit }
    on { print }
' "$TARGET" > "$BODY"

if [ ! -s "$BODY" ]; then
    echo "could not extract uninstall_leigodacc()" >&2
    exit 1
fi
echo "== uninstall body: $(wc -l < "$BODY") lines =="

fail=0
check() {
    # check <human label> <literal substring>
    if grep -qF -- "$2" "$BODY"; then
        printf '  [OK]   %s\n' "$1"
    else
        printf '  [FAIL] %s (missing: %s)\n' "$1" "$2"
        fail=$((fail + 1))
    fi
}

echo
echo "== service / binaries =="
check "init script"            "/etc/init.d/acc"
check "install dir"            "/usr/sbin/leigod"
check "vendor uninstaller"     "leigod_uninstall.sh"
check "kill engine processes"  "acc_upgrade_monitor"

echo
echo "== engine configuration =="
check "UCI accelerator (legacy manager)" "/etc/config/accelerator"
check "accelerator.ini"        "/etc/config/accelerator.ini"
check "acc_firewall.ini"       "/etc/config/acc_firewall.ini"
check "acc_version.ini"        "/etc/config/acc_version.ini"
check "core conf json"         "/etc/config/acc_core_conf.json"
check "ip database xdb"        "/etc/config/ipdatacloud_country.xdb"
check "upgrade data"           "/etc/config/upgrade_data.json"

echo
echo "== runtime state =="
check "runtime dir"            "/tmp/acc"
check "install log"            "/tmp/leigod_acc_install.log"
check "opkg shim cleanup"      "remove_opkg_shim"

echo
echo "== LuCI files =="
check "controller"             "/usr/lib/lua/luci/controller/acc.lua"
check "cbi models"             "/usr/lib/lua/luci/model/cbi/leigod"
check "views"                  "/usr/lib/lua/luci/view/leigod"
check "i18n lmo"               "/usr/lib/lua/luci/i18n/acc.zh-cn.lmo"
check "menu.d leftover"        "/usr/share/luci/menu.d/luci-app-leigod-acc.json"
check "acl.d leftover"         "/usr/share/rpcd/acl.d/luci-app-leigod-acc.json"
check "index cache"            "/tmp/luci-indexcache"
check "rpcd restart"           "/etc/init.d/rpcd restart"
check "uhttpd restart"         "/etc/init.d/uhttpd restart"

echo
echo "== cron / auto-pause =="
check "crontab"                "/etc/crontabs/root"
check "auto-pause script"      "/usr/sbin/leigod-auto-pause.sh"
check "auto-pause config"      "/etc/leigod-auto-pause.conf"
check "auto-pause state"       "/tmp/leigod-auto-pause.state"

echo
echo "== firewall =="
check "firewall UCI rule"      "LeigodAcc"
check "hotplug guard"          "/etc/hotplug.d/firewall/99-leigodacc-restart"
check "GAMEACC chains"         "GAMEACC"
check "ipset collections"      "ipset"
check "nft table"              "tproxy_table"

echo
if [ "$fail" -eq 0 ]; then
    echo "== summary: all artifacts covered =="
    exit 0
fi
echo "== summary: $fail artifact(s) NOT covered =="
exit 1
