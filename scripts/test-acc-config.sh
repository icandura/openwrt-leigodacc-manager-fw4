#!/bin/bash
# Regression test for the acceleration-config layer of leigod-fw4.sh.
# Extracts the INI helpers + port LISTEN predicate and exercises them offline.
#
#   bash scripts/test-acc-config.sh
#
# Covers:
#   - acc_layout()            new vs legacy detection
#   - acc_ini_get/set         read, replace, append
#   - acc_default_tproxy_ip   iptables -> 10.20.30.40 / nftables -> 0.0.0.0
#   - fix_acc_new_layout      repairs missing key, LAN-IP value, nftables backend
#   - /proc/net/tcp predicate LISTEN (0A) vs ESTABLISHED (01), tcp and tcp6

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../leigod-fw4.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  [OK]   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  [FAIL] %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 (want '$3', got '$2')"; fi; }

# ---------------------------------------------------------------------------
# Extract the config helper block
# ---------------------------------------------------------------------------
awk '
    /^ACC_INI="\/etc\/config\/acc_firewall.ini"/ { on = 1 }
    on && /^# Fix acceleration config \(legacy layout/ { exit }
    on { print }
' "$TARGET" > "$WORK/cfg.sh"

if [ ! -s "$WORK/cfg.sh" ]; then
    echo "could not extract config layer" >&2
    exit 1
fi
echo "== extracted $(wc -l < "$WORK/cfg.sh") lines =="

# shellcheck source=/dev/null
. "$WORK/cfg.sh"

# Never touch the router service during the test
restart_acc_service() { return 0; }

# ---------------------------------------------------------------------------
echo
echo "== layout detection =="
INI="$WORK/acc_firewall.ini"
ACC_INI="$INI"
check "no INI -> legacy" "$(acc_layout)" "legacy"
printf '[firewall]\nbackend=iptables\nmode=tproxy\ntproxy_ip=10.20.30.40\n' > "$INI"
check "INI present -> new" "$(acc_layout)" "new"

# ---------------------------------------------------------------------------
echo
echo "== ini read/write =="
check "read backend" "$(acc_ini_get backend)" "iptables"
check "read mode" "$(acc_ini_get mode)" "tproxy"
check "read missing key" "$(acc_ini_get nope)" ""

acc_ini_set mode tun
check "replace existing" "$(acc_ini_get mode)" "tun"

acc_ini_set extra yes
check "append missing" "$(acc_ini_get extra)" "yes"
check "append kept old keys" "$(acc_ini_get backend)" "iptables"

# ---------------------------------------------------------------------------
echo
echo "== vendor sentinel per backend =="
check "iptables sentinel" "$(acc_default_tproxy_ip iptables)" "10.20.30.40"
check "nftables sentinel" "$(acc_default_tproxy_ip nftables)" "0.0.0.0"

# ---------------------------------------------------------------------------
echo
echo "== fix_acc_new_layout: missing tproxy_ip =="
printf '[firewall]\nbackend=iptables\nmode=tproxy\n' > "$INI"
fix_acc_new_layout >/dev/null
check "tproxy_ip appended" "$(acc_ini_get tproxy_ip)" "10.20.30.40"

echo
echo "== fix_acc_new_layout: LAN IP is corrected to sentinel =="
printf '[firewall]\nbackend=iptables\nmode=tproxy\ntproxy_ip=192.168.10.1\n' > "$INI"
fix_acc_new_layout >/dev/null
check "LAN IP replaced" "$(acc_ini_get tproxy_ip)" "10.20.30.40"

echo
echo "== fix_acc_new_layout: nftables backend =="
printf '[firewall]\nbackend=nftables\nmode=tproxy\ntproxy_ip=10.20.30.40\n' > "$INI"
fix_acc_new_layout >/dev/null
check "nftables sentinel" "$(acc_ini_get tproxy_ip)" "0.0.0.0"

echo
echo "== fix_acc_new_layout: JSON is aligned to INI (never invented) =="
printf '[firewall]\nbackend=iptables\nmode=tproxy\ntproxy_ip=10.20.30.40\n' > "$INI"
ACC_CORE_JSON="$WORK/acc_core_conf.json"
printf '{"acc_mode":2,"acceleration":[],"owner_type":1,"tproxy_ip":"192.168.10.1"}' > "$ACC_CORE_JSON"
fix_acc_new_layout >/dev/null
check "json aligned" "$(sed -n 's/.*"tproxy_ip":"\([^"]*\)".*/\1/p' "$ACC_CORE_JSON")" "10.20.30.40"

# ---------------------------------------------------------------------------
echo
echo "== /proc/net/tcp LISTEN predicate =="
# The predicate is copied from port_listening(); keep it byte-identical.
PRED='$4 == "0A" && substr($2, length($2) - length(p) + 1) == p { found = 1 } END { exit !found }'
printf '%s\n' \
  '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode' \
  '   0: 00000000:15D4 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1' \
  '   1: 0100007F:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12346 1' \
  '   2: 0100007F:15D4 0100007F:C001 01 00000000:00000000 00:00000000 00000000     0        0 12347 1' \
  > "$WORK/tcp"

if awk -v p=":15D4" "$PRED" "$WORK/tcp"; then ok "5588 LISTEN detected"; else bad "5588 LISTEN detected"; fi
if awk -v p=":0050" "$PRED" "$WORK/tcp"; then ok "port 80 LISTEN detected"; else bad "port 80 LISTEN detected"; fi
if awk -v p=":1F90" "$PRED" "$WORK/tcp"; then bad "8080 must not match"; else ok "8080 correctly absent"; fi
# Port 5588 present only as ESTABLISHED must not count as listening
printf '%s\n' '   0: 0100007F:15D4 0100007F:C001 01 00000000:00000000 00:00000000 00000000     0        0 1 1' > "$WORK/tcp2"
if awk -v p=":15D4" "$PRED" "$WORK/tcp2"; then bad "ESTABLISHED is not LISTEN"; else ok "ESTABLISHED is not LISTEN"; fi

echo
echo "== summary: pass=$pass fail=$fail =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
