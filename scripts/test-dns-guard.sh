#!/bin/bash
# Regression test for the DNS guard (leigod-fw4.sh dns-guard).
#
# Extracts the guard block and runs it against a stub `nslookup`:
#   * the default resolver returns only a CNAME (the real-world MosDNS/dnsmasq bug)
#   * the public resolver (223.5.5.5) returns the A records
# It then asserts that /etc/hosts (redirected to a temp file) gets a managed
# block with IPv4 pins, that a healthy domain is left alone, and that removal
# restores the original file.
#
#   bash scripts/test-dns-guard.sh

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$DIR/../leigod-fw4.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  [OK]   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  [FAIL] %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

# ---- extract the DNS guard block -----------------------------------------
awk '
    /^# DNS guard for the engine/ { on = 1 }
    on && /^dns_guard_menu\(\)/ { on = 2 }
    on { print }
    on == 2 && /^}/ { exit }
' "$TARGET" > "$WORK/guard.sh"
sed -i '1i # extracted' "$WORK/guard.sh"
if ! grep -q 'dns_guard_apply' "$WORK/guard.sh"; then
    echo "could not extract guard block" >&2; exit 1
fi
echo "== extracted $(wc -l < "$WORK/guard.sh") lines =="

# ---- stub nslookup --------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/nslookup" <<'STUB'
#!/bin/sh
domain="$1"; server="${2:-}"
case "$server" in
    ""|127.0.0.1)  # local resolver: CNAME only (the bug we work around)
        printf 'Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\n'
        printf 'Non-authoritative answer:\n%s\tcanonical name = %s.w.kunluncan.com\n' "$domain" "$domain"
        ;;
    *)   # public resolver: full A records
        printf 'Server:\t\t%s\nAddress:\t%s:53\n\n' "$server" "$server"
        printf 'Non-authoritative answer:\nName:\t%s\nAddress: 222.84.188.18\nAddress: 124.226.73.172\n' "$domain"
        ;;
esac
STUB
chmod +x "$WORK/bin/nslookup"

# ---- run ------------------------------------------------------------------
. "$WORK/guard.sh"
PATH="$WORK/bin:$PATH"
DNS_GUARD_HOSTS="$WORK/hosts"
printf '127.0.0.1 localhost\n10.0.0.1 keepme\n' > "$DNS_GUARD_HOSTS"

echo
echo "== apply =="
dns_guard_apply >/dev/null 2>&1
grep -q '>>> leigod-fw4 dns guard' "$DNS_GUARD_HOSTS" && ok "begin marker" || bad "begin marker"
grep -q '=== leigod-fw4 dns guard end ===' "$DNS_GUARD_HOSTS" && ok "end marker" || bad "end marker"
grep -q '^10.0.0.1 keepme$' "$DNS_GUARD_HOSTS" && ok "existing entries preserved" || bad "existing entries preserved"
check "pinned dfs01" "$(grep -c '^222\.84\.188\.18 dfs01\.nn\.com$' "$DNS_GUARD_HOSTS")" "1"
check "pinned opapi" "$(grep -c '^222\.84\.188\.18 opapi\.xxghh\.biz$' "$DNS_GUARD_HOSTS")" "1"
check "no duplicate pins" "$(grep -c '^222\.84\.188\.18 ' "$DNS_GUARD_HOSTS")" "4"

echo
echo "== idempotent re-apply =="
dns_guard_apply >/dev/null 2>&1
check "single marker block" "$(grep -c '>>> leigod-fw4 dns guard' "$DNS_GUARD_HOSTS")" "1"

echo
echo "== healthy resolution is not pinned =="
mkdir -p "$WORK/bin2"
cat > "$WORK/bin2/nslookup" <<'STUB'
#!/bin/sh
printf 'Server:\t\t127.0.0.1\nAddress:\t127.0.0.1:53\n\n'
printf 'Name:\t%s\nAddress: 1.2.3.4\n' "$1"
STUB
chmod +x "$WORK/bin2/nslookup"
PATH="$WORK/bin2:$PATH"
printf '127.0.0.1 localhost\n' > "$DNS_GUARD_HOSTS"
dns_guard_apply >/dev/null 2>&1
check "nothing pinned" "$(grep -c '^1\.2\.3\.4 ' "$DNS_GUARD_HOSTS")" "0"

echo
echo "== remove =="
PATH="$WORK/bin:$PATH"
dns_guard_apply >/dev/null 2>&1
dns_guard_remove >/dev/null 2>&1
check "markers gone" "$(grep -c 'leigod-fw4 dns guard' "$DNS_GUARD_HOSTS")" "0"
check "pins gone" "$(grep -c '^222\.84\.188\.18 ' "$DNS_GUARD_HOSTS")" "0"
grep -q '^127.0.0.1 localhost$' "$DNS_GUARD_HOSTS" && ok "original line kept" || bad "original line kept"

echo
echo "== summary: pass=$pass fail=$fail =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
