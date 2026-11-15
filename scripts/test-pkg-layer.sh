#!/bin/bash
# Regression test for the apk/opkg abstraction layer in leigod-fw4.sh.
# Run with a POSIX shell that supports bash syntax:
#   bash scripts/test-pkg-layer.sh
#
# It extracts only the package-manager section of the script and exercises it
# against a stub `apk` (and stub `opkg`) so the mapping logic can be verified
# without a router.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../leigod-fw4.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  [OK]   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  [FAIL] %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (want '$3', got '$2')"; fi; }

# ---------------------------------------------------------------------------
# Build a fake apk / opkg
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/log"

cat > "$WORK/bin/apk" <<'STUB'
#!/bin/sh
echo "apk $*" >> "$APK_LOG"
case "$1" in
    info)
        case "$2" in
            -e) [ "$3" = "libpcap1" ] || [ "$3" = "luci-compat" ] ; exit $? ;;
            *)  echo libpcap1; echo luci-compat; echo kmod-nft-nat ;;
        esac
        ;;
    search)
        [ "$2" = "-x" ] && [ "$3" = "kmod-netem" ] && { echo "kmod-netem-6.12.1-r1"; exit 0; }
        exit 1
        ;;
    --print-arch) echo x86_64 ;;
    add) exit 0 ;;
    del) exit 0 ;;
    update) exit 0 ;;
    *) exit 0 ;;
esac
STUB

cat > "$WORK/bin/opkg" <<'STUB'
#!/bin/sh
echo "opkg $*" >> "$APK_LOG"
case "$1" in
    list-installed) echo "libpcap - 1.10.6-r1"; echo "luci-compat - 1.0" ;;
    list) echo "kmod-netem - 6.12.1-r1" ;;
    print-architecture) echo "arch x86_64 10" ;;
    *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/apk" "$WORK/bin/opkg"

# ---------------------------------------------------------------------------
# Extract the package layer from the real script
# ---------------------------------------------------------------------------
awk '
    /^PKG_MGR=""/ { on = 1 }
    on && /^# fw4: install kmod-nft-tproxy/ { exit }
    on { print }
' "$TARGET" > "$WORK/pkglayer.sh"

if [ ! -s "$WORK/pkglayer.sh" ]; then
    echo "could not extract package layer" >&2
    exit 1
fi

echo "== extracted $(wc -l < "$WORK/pkglayer.sh") lines of package layer =="

# ---------------------------------------------------------------------------
# Case 1: apk system (no opkg on PATH)
# ---------------------------------------------------------------------------
echo
echo "== case 1: apk system =="
(
    export APK_LOG="$WORK/log/apk1.log"
    PATH="$WORK/bin:/usr/bin:/bin"
    # hide opkg by pointing at a PATH without it
    rm -f "$WORK/bin/opkg"
    # shellcheck source=/dev/null
    . "$WORK/pkglayer.sh"

    FW_TYPE="fw4"          # set by detect_firewall() in the real script
    detect_pkg_mgr
    check "detect_pkg_mgr" "$PKG_MGR" "apk"

    pkg_installed libpcap1 && ok "pkg_installed libpcap1" || bad "pkg_installed libpcap1"
    pkg_installed kmod-tun && bad "pkg_installed kmod-tun should be false" || ok "pkg_installed kmod-tun false"
    pkg_available kmod-netem && ok "pkg_available kmod-netem" || bad "pkg_available kmod-netem"
    pkg_available kmod-tun && bad "pkg_available kmod-tun should be false" || ok "pkg_available kmod-tun false"
    check "pkg_arch" "$(pkg_arch)" "x86_64"
    check "pkg_hint" "$(pkg_hint sqm-scripts)" "apk update && apk add sqm-scripts"

    set_fw_packages
    check "PKG_LIBPCAP" "$PKG_LIBPCAP" "libpcap1"
    check "PKG_UPNP" "$PKG_UPNP" "miniupnpd-nftables"

    install_opkg_shim >/dev/null 2>&1
    if [ -x "$APK_SHIM_DIR/opkg" ]; then ok "shim created"; else bad "shim created"; fi
    "$APK_SHIM_DIR/opkg" install luci-compat >/dev/null 2>&1
    grep -q "apk add --allow-untrusted luci-compat" "$APK_LOG" \
        && ok "shim opkg install -> apk add" || bad "shim opkg install -> apk add"

    remove_opkg_shim
    [ -d "$APK_SHIM_DIR" ] && bad "shim removed" || ok "shim removed"

    echo "$pass $fail" > "$WORK/result1"
)

# ---------------------------------------------------------------------------
# Case 2: opkg system (no apk)
# ---------------------------------------------------------------------------
echo
echo "== case 2: opkg system =="
(
    export APK_LOG="$WORK/log/apk2.log"
    mkdir -p "$WORK/bin-opkg"
    cat > "$WORK/bin-opkg/opkg" <<'STUB'
#!/bin/sh
case "$1" in
    list-installed) echo "libpcap - 1.10.6-r1" ;;
    list) echo "kmod-netem - 6.12.1-r1" ;;
    print-architecture) echo "arch x86_64 10" ;;
    *) exit 0 ;;
esac
STUB
    chmod +x "$WORK/bin-opkg/opkg"
    PATH="$WORK/bin-opkg:/usr/bin:/bin"
    . "$WORK/pkglayer.sh"

    FW_TYPE="fw4"
    detect_pkg_mgr
    check "detect_pkg_mgr" "$PKG_MGR" "opkg"
    pkg_installed libpcap && ok "pkg_installed libpcap" || bad "pkg_installed libpcap"
    check "pkg_arch" "$(pkg_arch)" "x86_64"
    set_fw_packages
    check "PKG_LIBPCAP" "$PKG_LIBPCAP" "libpcap"
    check "PKG_UPNP" "$PKG_UPNP" "miniupnpd"

    echo "$pass $fail" > "$WORK/result2"
)

r1="$(cat "$WORK/result1" 2>/dev/null || echo "0 0")"
r2="$(cat "$WORK/result2" 2>/dev/null || echo "0 0")"
P1="${r1%% *}"; F1="${r1##* }"
P2="${r2%% *}"; F2="${r2##* }"

echo
echo "== summary: apk pass=$P1 fail=$F1 | opkg pass=$P2 fail=$F2 =="
TOTAL_FAIL=$((F1 + F2))
[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
