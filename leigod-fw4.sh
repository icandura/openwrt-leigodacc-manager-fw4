#!/bin/sh

# ============================================================
# OpenWrt LeigodAcc Manager - fw4/nftables adapted version
# 版本: v3.1.3 (2026-11-06)
# 变更: DNS 兜底 + 数据面诊断
#       - 新增菜单 D / CLI dns-guard: 把引擎 CDN 域名固定 IPv4 写入 /etc/hosts
#         (解决 dnsmasq+MosDNS 只返回 CNAME 导致分流表下载失败的问题)
#       - 诊断新增: 隧道心跳 / 分流表 direct_Game / CDN 可解析 / 策略路由 / 规则注入
#       - 卸载彻底化: INI/JSON/xdb/临时文件/cron/自动暂停/LuCI 菜单残留/三表 GAMEACC
#       - 桥自检改为 HTTP 探测 LuCI 页面 (404=未注册)
#       - 双布局识别: /etc/config/acc_firewall.ini (new) vs JSON (legacy)
#       - tproxy_ip 恢复为官方哨兵值 (iptables 10.20.30.40 / nftables 0.0.0.0)
#       - 端口检测改用 /proc/net/tcp (iStoreOS 25.12 无 ss)
# 项目: https://github.com/xxx/openwrt-leigodacc-manager-fw4
# 基于: miaoermua/openwrt-leigodacc-manager
# AI 辅助: DeepSeek AI 生成和修改
# 适配 OpenWrt 24.10+ fw4 / OpenWrt 25.12+ apk 防火墙环境
# ============================================================

# Check ROOT & OpenWrt
if [ "$(id -u)" != "0" ]; then
    echo "Error: You must be root to run this script, please use root user"
    exit 1
fi

# Prevent Xiaomi Routers and Qunou Routers from running openwrt-leigodacc-manager
if [ -e /etc/asus_release ]; then
    echo "TONY 别肘! 我爱 BCM!"
    echo ""
    echo "[ERROR] 检测到 ASUS 路由器，无法运行 OpenWrt LeigodAcc 管理器，你不是 OpenWrt 系统!"

    if [ ! -d /jffs/softcenter ]; then
        echo "[INFO] 检测到官改 or Koolcenter 版本，即将脱离 OpenWrt 管理器运行官方脚本开始安装."
        echo "[INFO] 以下内容均与 OpenWrt 管理器作者无关，本人并无华硕路由器 Debug!"
        echo
        sleep 5
        cd /tmp || { echo "[ERROR] 无法切换到 /tmp 目录"; exit 1; }
        sh -c "$(curl -fsSL https://119.3.40.126/router_plugin_new/plugin_install.sh 2>/dev/null || curl -fsSL http://119.3.40.126/router_plugin_new/plugin_install.sh)"
    fi
    exit 0
fi

if [ -d /userdisk/appdata ]; then
    echo "R u OK?"
    echo ""
    echo "[ERROR] 检测到小米路由器，无法运行 OpenWrt LeigodAcc 管理器，你不是 OpenWrt 系统!"
    name=$(uci get misc.hardware.displayName 2>/dev/null)
    if [ "$?" != "0" ] || [ -z "$name" ]; then
        name=$(uci get misc.hardware.model 2>/dev/null)
    fi
    if [ -n "$name" ]; then
        echo "[INFO] 小米路由器: ${name}"
        sleep 5
        echo "[INFO] 检测到小米已经解锁了 SSH，即将脱离 OpenWrt 管理器运行官方脚本开始安装."
        echo "[INFO] 以下内容均与 OpenWrt 管理器作者无关，本人并无小米路由器 Debug!"
        echo
        cd /tmp || { echo "[ERROR] 无法切换到 /tmp 目录"; exit 1; }
        sh -c "$(curl -fsSL https://119.3.40.126/router_plugin_new/plugin_install.sh 2>/dev/null || curl -fsSL http://119.3.40.126/router_plugin_new/plugin_install.sh)"
        exit 0
    fi
fi

if ! grep -qi -E "OpenWrt|LEDE|QWRT|ImmortalWrt|iStoreOS" /etc/openwrt_release; then
    echo "Your system is not supported!"
    echo "[INFO]你的系统可能无法运行 OpenWrt Leigodacc 插件!"
    echo "当前系统环境并非常见或标准的 OpenWrt，可能是论坛版本修改发行版文件导致无法识别"
    echo "可能导致无法正常支持全部依赖，部分组件可能无法正常启用导致加速问题"
    echo "你可以无视风险继续安装，5s 后将进入管理器菜单，详情参考管理器发布于博客信息"
    echo
    sleep 5
fi

# ============================================================
# Package manager abstraction
# OpenWrt <= 24.10 : opkg  (ipk, /etc/opkg/distfeeds.conf)
# OpenWrt >= 25.12 : apk   (apk,  /etc/apk/repositories.d/*.list)
#
# iStoreOS 25.12 ships apk-tools 3.x and NO opkg binary at all.
# Every opkg call site in this script goes through these wrappers.
# ============================================================
PKG_MGR=""
APK_SHIM_DIR="/tmp/leigod-pkgshim"
PKG_FAILED=""

detect_pkg_mgr() {
    if command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MGR="opkg"
    else
        PKG_MGR="none"
    fi
}

# Package manager human readable name
pkg_mgr_name() {
    case "$PKG_MGR" in
        apk)  echo "apk (OpenWrt 25.12+)" ;;
        opkg) echo "opkg (OpenWrt <= 24.10)" ;;
        *)    echo "未知 (无包管理器)" ;;
    esac
}

# Is the given package installed? (exact name match)
pkg_installed() {
    [ -n "$1" ] || return 1
    case "$PKG_MGR" in
        apk)
            # -e is exact-match existence check; fall back to the plain list
            if apk info -e "$1" >/dev/null 2>&1; then
                return 0
            fi
            apk info 2>/dev/null | grep -qx "$1"
            return $?
            ;;
        opkg)
            opkg list-installed 2>/dev/null | grep -q "^$1 "
            return $?
            ;;
        *)
            return 1
            ;;
    esac
}

# Is the given package available in the configured repositories?
pkg_available() {
    [ -n "$1" ] || return 1
    case "$PKG_MGR" in
        apk)
            if apk search -x "$1" >/dev/null 2>&1; then
                return 0
            fi
            apk search "$1" 2>/dev/null | grep -q "^$1-[0-9]"
            return $?
            ;;
        opkg)
            opkg list 2>/dev/null | grep -q "^$1 "
            return $?
            ;;
        *)
            return 1
            ;;
    esac
}

pkg_update() {
    case "$PKG_MGR" in
        apk)  apk update >/dev/null 2>&1 ;;
        opkg) opkg update >/dev/null 2>&1 ;;
    esac
    return 0
}

pkg_install_raw() {
    case "$PKG_MGR" in
        apk)  apk add "$@" ;;
        opkg) opkg install "$@" ;;
        *)    return 1 ;;
    esac
}

pkg_remove_raw() {
    case "$PKG_MGR" in
        apk)  apk del "$@" ;;
        opkg) opkg remove "$@" ;;
        *)    return 1 ;;
    esac
}

# Install a list of packages one by one, collecting failures in $PKG_FAILED
safe_pkg_install() {
    for pkg in "$@"; do
        echo "[INFO] 安装 $pkg ..."
        if pkg_install_raw "$pkg"; then
            :
        else
            echo "[ERROR] 安装失败: $pkg"
            PKG_FAILED="$PKG_FAILED $pkg"
        fi
    done
}

# Print an install command hint that matches the active package manager
pkg_hint() {
    case "$PKG_MGR" in
        apk)  echo "apk update && apk add $*" ;;
        opkg) echo "opkg update && opkg install $*" ;;
        *)    echo "# 请先安装包管理器: $*" ;;
    esac
}

# Print the machine architecture (opkg/APK compatible string)
pkg_arch() {
    case "$PKG_MGR" in
        apk)  apk --print-arch 2>/dev/null ;;
        opkg) opkg print-architecture 2>/dev/null | grep "arch" | awk '{print $2}' | grep -vE "all|noarch" | head -1 ;;
    esac
}

# Show the configured feeds (used by the installer banner)
pkg_show_feeds() {
    case "$PKG_MGR" in
        apk)
            if [ -d /etc/apk/repositories.d ]; then
                for f in /etc/apk/repositories.d/*.list; do
                    [ -f "$f" ] || continue
                    echo "[$f]"
                    grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -v '^[[:space:]]*$'
                done
            elif [ -f /etc/apk/repositories ]; then
                echo "[/etc/apk/repositories]"
                grep -v '^[[:space:]]*#' /etc/apk/repositories 2>/dev/null | grep -v '^[[:space:]]*$'
            else
                echo "[INFO] 未找到 /etc/apk/repositories.d 配置"
            fi
            ;;
        opkg)
            [ -f /etc/opkg/customfeeds.conf ] && { echo "[customfeeds.conf]"; cat /etc/opkg/customfeeds.conf; } || echo "[INFO] customfeeds.conf 不存在"
            [ -f /etc/opkg/distfeeds.conf ] && { echo "[distfeeds.conf]"; cat /etc/opkg/distfeeds.conf; } || echo "[INFO] distfeeds.conf 不存在"
            ;;
    esac
}

# ============================================================
# opkg → apk shim
# The official Leigod plugin_install.sh still calls `opkg`.
# On apk systems we inject this shim through PATH for that one
# invocation only, so nothing is written into /usr/sbin.
# ============================================================
install_opkg_shim() {
    if [ "$PKG_MGR" != "apk" ]; then
        return 0
    fi
    if command -v opkg >/dev/null 2>&1; then
        return 0
    fi

    mkdir -p "$APK_SHIM_DIR"
    cat > "$APK_SHIM_DIR/opkg" << 'OPKGSHIM'
#!/bin/sh
# opkg -> apk compatibility shim (leigod-fw4.sh)
# Only used for the official installer; removed on uninstall.
sub="$1"
[ -n "$sub" ] && shift

# opkg 时代的包名 → OpenWrt 25.12 apk 包名
apk_name_alias() {
    case "$1" in
        libpcap)             echo libpcap1 ;;
        miniupnpd)           echo miniupnpd-nftables ;;
        iptables)            echo iptables-nft ;;
        kmod-ipt-nat)        echo kmod-nft-nat ;;
        kmod-ipt-tproxy)     echo kmod-nft-tproxy ;;
        ip6tables)           echo ip6tables-nft ;;
        luci-compat)         echo luci-compat ;;
        *)                   echo "$1" ;;
    esac
}

case "$sub" in
    update)
        exec apk update
        ;;
    install|-i|--force-reinstall)
        [ $# -eq 0 ] && exit 0
        # 丢弃 opkg 专有标志 (-y / --force-* / --autoremove ...)
        force=""
        for a in "$@"; do
            case "$a" in
                --force-reinstall|-f) force="--force-overwrite" ;;
                --*|-y|-q) : ;;
                *)
                    # 先按原名安装；失败再按 25.12 的包名映射重试一次
                    if ! apk add --allow-untrusted $force "$a" >/dev/null 2>&1; then
                        m=$(apk_name_alias "$a")
                        [ "$m" != "$a" ] && apk add --allow-untrusted "$m" >/dev/null 2>&1
                    fi
                    ;;
            esac
        done
        # 依赖已由 leigod-fw4.sh 预装并校验，此处不再让官方脚本中断
        exit 0
        ;;
    remove|-r|--force-depends)
        [ $# -eq 0 ] && exit 0
        pkgs=""
        for a in "$@"; do
            case "$a" in
                --*|-y|-q) ;;
                *) pkgs="$pkgs $a" ;;
            esac
        done
        [ -z "$pkgs" ] && exit 0
        exec apk del $pkgs
        ;;
    list-installed)
        apk info 2>/dev/null
        ;;
    list-upgradable)
        apk version -l '<' 2>/dev/null
        ;;
    list)
        if [ -n "$1" ]; then
            apk search "$1" 2>/dev/null
        else
            apk list 2>/dev/null
        fi
        ;;
    info)
        if [ -n "$1" ]; then
            apk info "$1" 2>/dev/null
        else
            apk info 2>/dev/null
        fi
        ;;
    files)
        [ -n "$1" ] && apk info --contents "$1" 2>/dev/null
        ;;
    print-architecture)
        printf 'arch\t%s\t1\n' "$(apk --print-arch 2>/dev/null)"
        ;;
    depends|whatdepends)
        # 官方安装器不使用；返回成功避免中断
        exit 0
        ;;
    *)
        # 未知子命令：静默成功，避免官方脚本因 set -e 中断
        exit 0
        ;;
esac
OPKGSHIM
    chmod +x "$APK_SHIM_DIR/opkg"
    echo "[INFO] 已生成 opkg→apk 垫片: $APK_SHIM_DIR/opkg"
}

remove_opkg_shim() {
    [ -n "$APK_SHIM_DIR" ] || return 0
    case "$APK_SHIM_DIR" in
        /tmp/*) rm -rf "$APK_SHIM_DIR" ;;
    esac
}

# ============================================================
# DNS guard for the engine's CDN domains
# ============================================================
# Symptom this solves: on some routers (iStoreOS + MosDNS/dnsmasq chains) the
# local resolver returns only the CNAME of the engine's CDN hostnames without an
# A record.  The engine (which resolves through libc) then cannot download its
# routing data:
#     https://dfs01.nn.com/.../mac.json          device type table
#     https://dfs01.nn.com/.../cidrs.txt         destinations to tunnel (6624)
#     https://dfs01.nn.com/.../cidrs_direct.txt  destinations kept direct (9)
# Without those lists the engine tunnels nothing: the tunnel only carries
# heartbeats, direct_Game stays empty and games are never accelerated.
#
# The guard resolves the domains through a public resolver and pins IPv4
# addresses into /etc/hosts between markers.
DNS_GUARD_BEGIN="# >>> leigod-fw4 dns guard >>>"
DNS_GUARD_END="# === leigod-fw4 dns guard end ==="
DNS_GUARD_DOMAINS="dfs01.nn.com opapi.xxghh.biz opapi1.xxghh.biz nbox.nn.com"
DNS_GUARD_DNS="${DNS_GUARD_DNS:-223.5.5.5}"
DNS_GUARD_HOSTS="${DNS_GUARD_HOSTS:-/etc/hosts}"
# Probe the resolver directly: busybox `nslookup <name> <server>` bypasses
# /etc/hosts, otherwise an existing pin would mask a still-broken resolver.
DNS_GUARD_LOCAL_SERVER="${DNS_GUARD_LOCAL_SERVER:-127.0.0.1}"

# Extract the first IPv4 answer from `nslookup` output (busybox compatible).
# The "Address: <server>:53" line is skipped because the value contains a colon.
_dns_first_ipv4() {
    awk '/^Address: *[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2; exit }' 2>/dev/null
}

dns_resolve_ipv4() {   # dns_resolve_ipv4 <domain> [server]
    if [ -n "${2:-}" ]; then
        nslookup "$1" "$2" 2>/dev/null | _dns_first_ipv4
    else
        nslookup "$1" 2>/dev/null | _dns_first_ipv4
    fi
}

dns_guard_status() {
    echo "[INFO] 引擎关键域名解析状态 (浏览器/引擎都依赖它们下载分流表):"
    for _d in $DNS_GUARD_DOMAINS; do
        _local=$(dns_resolve_ipv4 "$_d" "$DNS_GUARD_LOCAL_SERVER")
        _pub=$(dns_resolve_ipv4 "$_d" "$DNS_GUARD_DNS")
        if [ -n "$_local" ]; then
            echo "  [OK]   $_d -> $_local (本机解析正常)"
        elif [ -n "$_pub" ]; then
            echo "  [FAIL] $_d 本机解析失败 (公共 DNS $DNS_GUARD_DNS 可解析为 $_pub)"
        else
            echo "  [WARN] $_d 本机与公共 DNS 均无法解析 (上游 DNS 故障?)"
        fi
    done
}

dns_guard_apply() {
    local _tmp="/tmp/leigod-hosts.$$" _d _local _pub _ip _added=0 _n
    [ -f "$DNS_GUARD_HOSTS" ] || : > "$DNS_GUARD_HOSTS"

    # Strip a previous block (and its entries) before writing a fresh one
    awk -v b="$DNS_GUARD_BEGIN" -v e="$DNS_GUARD_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
    ' "$DNS_GUARD_HOSTS" > "$_tmp"

    {
        echo "$DNS_GUARD_BEGIN"
        echo "# generated by leigod-fw4.sh dns-guard; refreshed by cron"
        for _d in $DNS_GUARD_DOMAINS; do
            _local=$(dns_resolve_ipv4 "$_d" "$DNS_GUARD_LOCAL_SERVER")
            _pub=$(dns_resolve_ipv4 "$_d" "$DNS_GUARD_DNS")
            if [ -n "$_local" ]; then
                echo "  [OK]   $_d 本机可解析 ($_local)，无需固定" >&2
                continue
            fi
            if [ -z "$_pub" ]; then
                echo "  [WARN] $_d 无法解析 (公共 DNS 也失败)，跳过" >&2
                continue
            fi
            # Pin up to two addresses for basic redundancy
            for _ip in $(nslookup "$_d" "$DNS_GUARD_DNS" 2>/dev/null \
                        | awk '/^Address: *[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2 }' \
                        | sort -u | head -2); do
                echo "$_ip $_d"
                _added=$((_added + 1))
            done
            echo "  [FIX]  $_d -> 固定 $_pub" >&2
        done
        echo "$DNS_GUARD_END"
    } >> "$_tmp"

    cat "$_tmp" > "$DNS_GUARD_HOSTS"
    rm -f "$_tmp"

    if [ "$_added" -gt 0 ]; then
        echo "[INFO] 已写入 $_added 条 hosts 记录 (块标记: $DNS_GUARD_BEGIN)"
        echo "[INFO] 引擎需要重启才能重新解析: /etc/init.d/acc restart"
        return 0
    fi
    echo "[INFO] 无需固定 (本机解析均正常)"
    return 0
}

dns_guard_remove() {
    local _tmp="/tmp/leigod-hosts.$$"
    [ -f "$DNS_GUARD_HOSTS" ] || return 0
    awk -v b="$DNS_GUARD_BEGIN" -v e="$DNS_GUARD_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
    ' "$DNS_GUARD_HOSTS" > "$_tmp"
    cat "$_tmp" > "$DNS_GUARD_HOSTS"
    rm -f "$_tmp"
    echo "[INFO] 已移除 leigod-fw4 dns guard 写入的 hosts 记录"
}

dns_guard_install_cron() {
    local _cron="0 */6 * * * /usr/sbin/leigod/leigod-fw4.sh dns-guard >/dev/null 2>&1"
    [ -f /usr/sbin/leigod/leigod-fw4.sh ] || return 0
    if grep -q "leigod-fw4.sh dns-guard" /etc/crontabs/root 2>/dev/null; then
        echo "[INFO] dns-guard cron 已存在"
        return 0
    fi
    echo "$_cron" >> /etc/crontabs/root
    /etc/init.d/cron restart >/dev/null 2>&1
    echo "[INFO] 已安装 dns-guard cron (每 6 小时刷新)"
}

dns_guard_menu() {
    echo
    echo "============================="
    echo "  DNS 兜底 (引擎分流数据源)"
    echo "============================="
    dns_guard_status
    echo
    echo "  1. 写入/刷新 hosts 固定记录"
    echo "  2. 移除固定记录"
    echo "  3. 仅查看状态"
    echo "  0. 返回"
    echo -n "选择: "
    read _c
    case "$_c" in
        1)
            dns_guard_apply
            dns_guard_install_cron
            echo -n "是否立即重启服务使解析生效? (y/n): "
            read _y
            case "$_y" in
                [Yy]) /etc/init.d/acc restart >/dev/null 2>&1; sleep 6
                      port_listening 5588 && echo "[INFO] 服务已重启, 5588 正常" \
                                           || echo "[WARN] 5588 未监听，查看 /tmp/acc/log/web_api.log" ;;
            esac
            ;;
        2)
            dns_guard_remove
            sed -i '/leigod-fw4.sh dns-guard/d' /etc/crontabs/root 2>/dev/null
            /etc/init.d/cron restart >/dev/null 2>&1
            ;;
        3)
            ;;
        *)
            ;;
    esac
    echo "============================="
}

# ============================================================
# Vendor auto-upgrade control
# ============================================================
# The 1.2.2.78 release only shipped an arm64 payload (acc_version.json lists
# "name": "acc-gw.router.arm64" and an arm64-only md5_list). On an amd64 router
# the upgrade downloads the bundle, extracts it and then fails to exec
# acc-setup.arm64 — but not before killing the running daemon, which silently
# interrupts acceleration every few minutes.
#
# Disabling the monitor removes the second procd instance from
# /etc/init.d/acc (backup kept as acc.leigod_bak). Re-enable restores it.
_ACC_UPGRADE_AWK='
/procd_open_instance[ \t]*$/ { blk = $0 "\n"; keep = 1; inb = 1; next }
inb {
    blk = blk $0 "\n"
    if ($0 ~ /acc_upgrade_monitor/) keep = 0
    if ($0 ~ /procd_close_instance/) {
        inb = 0
        if (keep) printf "%s", blk
        else print "# [leigod-fw4] upgrade monitor disabled (vendor shipped a wrong-arch bundle)"
        blk = ""
    }
    next
}
{ print }
'

acc_upgrade_disabled() {
    [ -f /etc/init.d/acc ] && grep -q 'leigod-fw4] upgrade monitor disabled' /etc/init.d/acc 2>/dev/null
}

acc_upgrade_disable() {
    local init="/etc/init.d/acc" tmp="/tmp/acc.init.$$"
    [ -f "$init" ] || { echo "[ERROR] 未安装 (/etc/init.d/acc 不存在)"; return 1; }
    if acc_upgrade_disabled; then
        echo "[INFO] 自动升级已经处于禁用状态"
        return 0
    fi
    cp -a "$init" "${init}.leigod_bak" 2>/dev/null
    if awk "$_ACC_UPGRADE_AWK" "$init" > "$tmp" && [ -s "$tmp" ]; then
        cat "$tmp" > "$init"
        chmod +x "$init"
        rm -f "$tmp"
        echo "[INFO] 已禁用 acc_upgrade_monitor (备份: ${init}.leigod_bak)"
        echo "[INFO] 副作用: 不会再自动升级。恢复请用菜单 U → 2"
        /etc/init.d/acc restart >/dev/null 2>&1
        sleep 5
        if port_listening 5588; then
            echo "[INFO] 服务已重启，5588 正常"
        else
            echo "[WARN] 5588 未监听，查看 /tmp/acc/log/web_api.log"
        fi
        return 0
    fi
    rm -f "$tmp"
    echo "[ERROR] 改写 /etc/init.d/acc 失败，未做任何修改"
    return 1
}

acc_upgrade_enable() {
    local init="/etc/init.d/acc"
    if [ -f "${init}.leigod_bak" ]; then
        cp -a "${init}.leigod_bak" "$init"
        chmod +x "$init"
        rm -f "${init}.leigod_bak"
        echo "[INFO] 已恢复自动升级 (从备份还原)"
    elif acc_upgrade_disabled; then
        echo "[WARN] 有禁用标记但没有备份，重装插件可恢复"
        return 1
    else
        echo "[INFO] 自动升级本来就是启用状态"
        return 0
    fi
    /etc/init.d/acc restart >/dev/null 2>&1
    sleep 4
    return 0
}

acc_upgrade_menu() {
    echo
    echo "============================="
    echo "  官方自动升级 开/关"
    echo "============================="
    if acc_upgrade_disabled; then
        echo "  当前状态: 已禁用 (acc_upgrade_monitor 不在 init 中)"
    else
        echo "  当前状态: 启用中"
    fi
    echo
    echo "  说明: 官方 1.2.2.78 只发布了 arm64 包，amd64 上会反复"
    echo "        下载→解包→exec 失败，并在过程中杀掉 daemon，"
    echo "        导致加速每隔几分钟被中断。"
    echo
    echo "  1. 禁用自动升级"
    echo "  2. 恢复自动升级"
    echo "  0. 返回"
    echo -n "选择: "
    read _u
    case "$_u" in
        1) acc_upgrade_disable ;;
        2) acc_upgrade_enable ;;
        *) ;;
    esac
    echo "============================="
}

# ============================================================
# Firewall detection: fw3 (iptables) vs fw4 (nftables)
# ============================================================
detect_firewall() {
    # Multi-layered detection: some OpenWrt 24.10 derivatives (ImmortalWrt etc.)
    # use nftables as the firewall backend but don't install the firewall4
    # package by default. We check for the nft userspace tool as a more
    # reliable indicator of the underlying nftables subsystem.
    if [ -x /usr/sbin/fw4 ] || [ -x /usr/sbin/nft ]; then
        FW_TYPE="fw4"
        FW_NAME="nftables (fw4)"
        echo ""
        echo "[INFO] 检测到 fw4/nftables 防火墙 - OpenWrt 24.10+ 适配版"
        echo "[INFO] 将使用 nftables 兼容模式安装依赖"
        echo ""
        sleep 1
    else
        FW_TYPE="fw3"
        FW_NAME="iptables (fw3)"
        echo "[INFO] 检测到 fw3/iptables 防火墙，使用传统模式"
    fi
}

# Set package lists based on firewall type
set_fw_packages() {
    if [ "$FW_TYPE" = "fw4" ]; then
        # fw4/nftables packages
        PKG_IPTABLES="iptables-nft"
        PKG_NAT="kmod-nft-nat"
        PKG_TPROXY=""          # handled separately via ensure_fw4_tproxy()
        PKG_IPSET=""           # nftables has built-in set support
        PKG_IPSET_TOOL=""      # nftables uses nft sets natively
        PKG_IPT_TPROXY_MOD=""  # not needed for nftables
    else
        # fw3/iptables packages (original)
        PKG_IPTABLES="iptables"
        PKG_NAT="kmod-ipt-nat"
        PKG_TPROXY="kmod-ipt-tproxy"
        PKG_IPSET="kmod-ipt-ipset"
        PKG_IPSET_TOOL="ipset"
        PKG_IPT_TPROXY_MOD="iptables-mod-tproxy"
    fi

    # --- package naming differences between opkg and apk feeds ---
    # OpenWrt 25.12: libpcap runtime package is libpcap1 (was libpcap)
    if [ "$PKG_MGR" = "apk" ]; then
        PKG_LIBPCAP="libpcap1"
        # fw4 uses the nftables flavour of miniupnpd
        PKG_UPNP="miniupnpd-nftables"
    else
        PKG_LIBPCAP="libpcap"
        PKG_UPNP="miniupnpd"
    fi
    PKG_LUCI_UPNP="luci-app-upnp"
}

# Leigod's official router plugin needs UPnP/SSDP so the phone APP can
# discover the router. On 25.12 the miniupnpd package is split by backend.
ensure_upnpd() {
    if pkg_installed "$PKG_UPNP"; then
        return 0
    fi
    echo "[INFO] 未检测到 $PKG_UPNP，尝试安装 UPnP 服务..."
    pkg_install_raw "$PKG_UPNP" >/dev/null 2>&1
    pkg_installed "$PKG_UPNP"
}

# fw4: install kmod-nft-tproxy with fallback checks.
# On some OpenWrt 24.10 builds, the nft_tproxy module may be built into
# the kernel (CONFIG_NFT_TPROXY=y) rather than shipped as a separate kmod.
ensure_fw4_tproxy() {
    if [ "$FW_TYPE" != "fw4" ]; then
        return 0
    fi

    echo "[INFO] 检查 nftables TPROXY 支持..."

    # Already loaded? Nothing to do.
    if lsmod 2>/dev/null | grep -q "nft_tproxy"; then
        echo "[INFO] nft_tproxy 模块已加载"
        return 0
    fi

    # Try loading the module directly (maybe it's already installed)
    if modprobe nft_tproxy 2>/dev/null; then
        echo "[INFO] nft_tproxy 模块加载成功"
        return 0
    fi

    # Try installing the kmod package
    if pkg_available "kmod-nft-tproxy"; then
        echo "[INFO] 正在安装 kmod-nft-tproxy..."
        if pkg_install_raw kmod-nft-tproxy >/dev/null 2>&1; then
            modprobe nft_tproxy 2>/dev/null
            echo "[INFO] kmod-nft-tproxy 安装成功"
            return 0
        fi
    fi

    # Check if TPROXY is built into the kernel
    if [ -f /proc/config.gz ] && zcat /proc/config.gz 2>/dev/null | grep -q "CONFIG_NFT_TPROXY=y"; then
        echo "[INFO] nft_tproxy 已编译进内核 (CONFIG_NFT_TPROXY=y)"
        return 0
    fi

    # Nothing worked — TPROXY is unavailable
    echo "[WARN] nftables TPROXY 不可用 (kmod-nft-tproxy 未找到且未编译进内核)"
    echo "[WARN] TPROXY 不可用。注意: 此 acc-gw 版本可能仅支持 TPROXY，加速将无法工作"
    echo "[INFO] 请运行选项 S 诊断确认 tproxy_ip 配置是否正确"
    return 1
}

# Check available disk space before installation (>10MB free on /).
# OpenWrt devices often have limited flash (128-256MB).
check_disk_space() {
    free_kb=$(df / 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$free_kb" ]; then
        echo "[WARN] 无法检测磁盘空间，继续安装..."
        return 0
    fi
    if [ "$free_kb" -lt 10240 ]; then
        echo "[ERROR] 磁盘空间不足! 可用: $((free_kb / 1024))MB, 需要至少 10MB"
        echo "[ERROR] 请到 系统→软件包 中卸载不用的包或扩容后重试"
        return 1
    fi
    echo "[INFO] 磁盘空间: $((free_kb / 1024))MB 可用"
    return 0
}

# Check network connectivity before attempting opkg update or downloads.
# Returns 0 if reachable, 1 if not.
# Uses multiple geographically diverse hosts to avoid regional false negatives.
check_network() {
    # Global CDN (works worldwide)
    if curl -sL --connect-timeout 3 -o /dev/null https://httpbin.org/ip 2>/dev/null; then
        return 0
    fi
    # Fallback: China mirror (for users in China)
    if curl -sL --connect-timeout 3 -o /dev/null https://mirrors.pku.edu.cn 2>/dev/null; then
        return 0
    fi
    # Final fallback: any reachable
    if curl -sL --connect-timeout 3 -o /dev/null https://cloudflare.com 2>/dev/null; then
        return 0
    fi
    echo "[WARN] 网络不可达，后续操作可能失败"
    return 1
}

# Legacy wrapper name kept so older call sites keep working.
OPKG_FAILED=""
safe_opkg_install() {
    safe_pkg_install "$@"
    OPKG_FAILED="$PKG_FAILED"
}

# Check if netem (network emulation / QoS) is already available in the kernel.
# On kernel 6.x, CONFIG_NET_SCH_NETEM is often built-in rather than a module,
# so the kmod-netem package may not exist.
# Returns 0 if netem is available (or if the package doesn't exist at all).
has_netem() {
    lsmod 2>/dev/null | grep -q sch_netem && return 0
    zcat /proc/config.gz 2>/dev/null | grep -q 'CONFIG_NET_SCH_NETEM=y' && return 0
    # If the package doesn't exist in the repo, skip it gracefully
    pkg_available "kmod-netem" || return 0
    return 1
}

# Get the essential packages list for the current firewall
get_essential_packages() {
    local pkgs="$PKG_LIBPCAP $PKG_IPTABLES $PKG_NAT $PKG_TPROXY"
    [ -n "$PKG_IPT_TPROXY_MOD" ] && pkgs="$pkgs $PKG_IPT_TPROXY_MOD"
    [ -n "$PKG_IPSET" ] && pkgs="$pkgs $PKG_IPSET"
    [ -n "$PKG_IPSET_TOOL" ] && pkgs="$pkgs $PKG_IPSET_TOOL"
    echo "$pkgs"
}

# Get the optional packages list for the current firewall
get_optional_packages() {
    local pkgs="kmod-tun $PKG_TPROXY tc-full conntrack ipset"
    # kmod-netem may not exist on kernel 6.x — netem is built into the kernel
    has_netem || pkgs="$pkgs kmod-netem"
    [ -n "$PKG_IPSET" ] && pkgs="$pkgs $PKG_IPSET"
    echo "$pkgs"
}

# Get the full check list for the current firewall
get_check_packages() {
    local pkgs="kmod-tun $PKG_TPROXY tc-full"
    has_netem || pkgs="$pkgs kmod-netem"
    [ -n "$PKG_IPSET" ] && pkgs="$pkgs $PKG_IPSET"
    pkgs="$pkgs conntrack curl $PKG_LIBPCAP $PKG_IPTABLES $PKG_NAT"
    [ -n "$PKG_IPT_TPROXY_MOD" ] && pkgs="$pkgs $PKG_IPT_TPROXY_MOD"
    [ -n "$PKG_IPSET_TOOL" ] && pkgs="$pkgs $PKG_IPSET_TOOL"
    echo "$pkgs"
}

# ============================================================
# fw4 firewall integration
# ============================================================
setup_fw4_integration() {
    if [ "$FW_TYPE" != "fw4" ]; then
        return 0
    fi

    echo "[INFO] 配置 fw4/nftables 防火墙集成..."

    # Create firewall hotplug script to restore LeigodAcc rules
    # after fw4 reload (which flushes the entire nftables ruleset).
    # When LeigodAcc runs in TPROXY mode, acc-gw injects rules via
    # iptables-nft at runtime. These are lost on fw4 reload, so we
    # restart the service to re-inject them.
    # TUN mode is unaffected by fw4 reloads and is the recommended
    # mode for fw4 systems.
    mkdir -p /etc/hotplug.d/firewall
    cat > /etc/hotplug.d/firewall/99-leigodacc-restart << 'HOTPLUGEOF'
#!/bin/sh
# LeigodAcc - restart after fw4 reload to restore dynamic rules

[ "$ACTION" = "reload" ] || exit 0
[ -x /etc/init.d/acc ] || exit 0

# Restart if the service was running (fw4 reload clears dynamic iptables-nft rules)
if /etc/init.d/acc running >/dev/null 2>&1 || ps | grep -q "[a]cc-gw"; then
    # Debounce: skip if recently restarted (within 30s)
    last_restart=$(cat /tmp/leigod-hotplug-restart.ts 2>/dev/null)
    now=$(date +%s)
    if [ -n "$last_restart" ] && [ $((now - last_restart)) -lt 30 ]; then
        exit 0
    fi
    echo "$now" > /tmp/leigod-hotplug-restart.ts
    logger -t leigodacc "fw4 reload detected, re-injecting rules..."
    /etc/init.d/acc restart >/dev/null 2>&1 &
fi
HOTPLUGEOF
    chmod +x /etc/hotplug.d/firewall/99-leigodacc-restart

    # Add firewall rule to allow phone app → acc-gw API (TCP 5588).
    # On fw4 the default ruleset may drop LAN→router traffic on non-standard
    # ports, which blocks the phone from sending acceleration commands.
    if ! grep -q "LeigodAcc" /etc/config/firewall 2>/dev/null; then
        uci add firewall rule
        uci set firewall.@rule[-1].name='LeigodAcc'
        uci set firewall.@rule[-1].src='lan'
        uci set firewall.@rule[-1].dest_port='5588'
        uci set firewall.@rule[-1].proto='tcp'
        uci set firewall.@rule[-1].target='ACCEPT'
        uci commit firewall
        /etc/init.d/firewall restart >/dev/null 2>&1
        echo "[INFO] 已添加防火墙规则：允许 LAN 访问 acc-gw API (TCP 5588)"
    fi

    echo "[INFO] fw4 防火墙集成配置完成"
    echo "[INFO] 已安装 fw4 热插拔脚本: /etc/hotplug.d/firewall/99-leigodacc-restart"
    echo "[INFO] fw4 重载防火墙后会自动恢复 LeigodAcc 规则"
}

# On fw4, ensure iptables → iptables-nft symlinks exist so the LeigodAcc
# binary's iptables calls are transparently translated to nftables.
setup_iptables_nft_compat() {
    if [ "$FW_TYPE" != "fw4" ]; then
        return 0
    fi
    if [ ! -x /usr/sbin/iptables ]; then
        if [ -x /usr/sbin/iptables-nft ]; then
            ln -sf /usr/sbin/iptables-nft /usr/sbin/iptables 2>/dev/null
            ln -sf /usr/sbin/iptables-nft-restore /usr/sbin/iptables-restore 2>/dev/null
            ln -sf /usr/sbin/iptables-nft-save /usr/sbin/iptables-save 2>/dev/null
            echo "[INFO] 已配置 iptables-nft 兼容层"
        else
            echo "[WARN] iptables-nft 未安装，跳过兼容层配置"
        fi
    fi
}

# Apply fw4 compatibility patches to the installed LuCI interface.
# The upstream luci-app-leigod-acc was written for fw3/iptables.
# This replaces key Lua/HTML files with fw4-aware versions.
apply_luci_fw4_patch() {
    if [ "$FW_TYPE" != "fw4" ]; then
        return 0
    fi

    local luci_src="/usr/lib/lua/luci"
    local patch_dir=""

    # Locate patch files: check script dir, CWD, common paths
    script_dir=$(cd "$(dirname "$0")" && pwd 2>/dev/null || dirname "$0")
    for d in "$script_dir/luci-fw4-patch" "./luci-fw4-patch" \
             "/tmp/luci-fw4-patch" "/tmp/leigod-fw4/luci-fw4-patch" \
             "$HOME/leigod-fw4/luci-fw4-patch" "/root/leigod-fw4/luci-fw4-patch"; do
        [ -d "$d/luasrc" ] && patch_dir="$d" && break
    done

    if [ -z "$patch_dir" ]; then
        # Patch files bundled inline — write them directly
        echo "[INFO] 正在应用 LuCI fw4 适配补丁..."

        # controller/acc.lua
        mkdir -p "$luci_src/controller"
        cat > "$luci_src/controller/acc.lua" << 'LUAEOF'
module("luci.controller.acc", package.seeall)

function index()
  entry({ "admin", "services", "acc" }, alias("admin", "services", "acc", "service"), "雷神加速器", 50)
  entry({ "admin", "services", "acc", "service" }, cbi("leigod/service"), "服务配置", 30)
  entry({ "admin", "services", "acc", "device" }, cbi("leigod/device"), "设备管理", 50)
  entry({ "admin", "services", "acc", "app" }, cbi("leigod/app"), "APP下载", 60)
  entry({ "admin", "services", "acc", "notice" }, cbi("leigod/notice"), "使用须知", 80)
  entry({ "admin", "services", "acc", "autopause" }, cbi("leigod/autopause"), "自动暂停", 70)
  entry({ "admin", "services", "acc", "debug" }, cbi("leigod/debug"), "网络诊断", 90)
  entry({ "admin", "services", "acc", "status" }, call("get_acc_status")).leaf = true
  entry({ "admin", "services", "acc", "start_acc_service" }, call("start_acc_service"))
  entry({ "admin", "services", "acc", "stop_acc_service" }, call("stop_acc_service"))
  entry({ "admin", "services", "acc", "schedule_pause" }, call("schedule_pause"))
  entry({ "admin", "services", "acc", "ap_status" }, call("get_autopause_status")).leaf = true
  entry({ "admin", "services", "acc", "ap_save" }, call("save_autopause_config"))
  entry({ "admin", "services", "acc", "ap_trigger" }, call("trigger_autopause"))
  entry({ "admin", "services", "acc", "ap_toggle" }, call("toggle_autopause_cron"))
  entry({ "admin", "services", "acc", "debug_status" }, call("get_debug_status")).leaf = true
  entry({ "admin", "services", "acc", "debug_report" }, call("get_debug_report")).leaf = true
  entry({ "admin", "services", "acc", "save_token" }, call("save_token")).leaf = true
end

-- get_acc_status get acc status (fw4 adapted)
-- Reads device acceleration state from acc_core_conf.json (daemon writes
-- state here, NOT to UCI). Falls back to UCI for backward compat.
function get_acc_status()
  local util      = require "luci.util"
  local uci       = require "luci.model.uci".cursor()
  local fs        = require "nixio.fs"
  local resp      = {}
  resp.service    = "已停止"
  resp.state      = {}

  if fs.access("/usr/sbin/fw4") or fs.access("/usr/sbin/nft") then
    resp.firewall = "nftables (fw4)"
  else
    resp.firewall = "iptables (fw3)"
  end

  local exist = util.exec("ps | grep acc-gw | grep -v grep")
  if exist ~= "" then resp.service = "已启用" end

  -- Initialize all categories to "无"
  for _, typ in pairs({ "手机", "电脑", "游戏主机", "未知设备" }) do
    resp.state[typ] = "无"
  end

  -- Parse acc_core_conf.json for live acceleration state
  -- Daemon writes state in nested JSON: "PC":{"...","state":1,...}
  -- Lua [^{] breaks on nested { so use a two-pass approach:
  -- 1. Find all category keys (Phone/PC/Game/Unknown) at top level
  -- 2. Search for "state":N near each category
  local json_raw = ""
  if fs.access("/tmp/acc/acc_core_conf.json") then
    for line in io.lines("/tmp/acc/acc_core_conf.json") do json_raw = json_raw .. line end

    -- Map device_type to label: 1-3=Game, 4-6=PC, 7-8=Phone, 20-21=VR, other=Unknown
    local dt_label = { [0]="未知设备", [1]="游戏主机", [2]="游戏主机", [3]="游戏主机",
                       [4]="电脑", [5]="电脑", [6]="电脑",
                       [7]="手机", [8]="手机",
                       [20]="VR设备", [21]="VR设备", [22]="未知设备" }

    -- Find category key position, then search for "state":N after it
    -- This avoids .- getting confused by nested/escaped JSON
    local cat_label = { Phone="手机", PC="电脑", Game="游戏主机", Unknown="未知设备" }
    for _, cat in ipairs({"Phone","PC","Game","Unknown"}) do
      local pos = json_raw:find('"'..cat..'":')
      if pos then
        local after = json_raw:sub(pos)
        local st = after:match('"state":(%d+)')
        if st then
          local label = cat_label[cat] or cat
          local st_num = tonumber(st)
          if st_num == 1 then resp.state[label] = "加速中"
          elseif st_num == 2 then resp.state[label] = "已停止"
          elseif st_num == 3 then resp.state[label] = "已暂停" end
        end
      end
    end
  end

  resp.hotplug = fs.access("/etc/hotplug.d/firewall/99-leigodacc-restart") and "installed" or "not_installed"
  luci.http.prepare_content("application/json")
  luci.http.write_json(resp)
end

-- start_acc_service
function start_acc_service()
  local util = require "luci.util"
  util.exec("/etc/init.d/acc enable")
  util.exec("/etc/init.d/acc restart")
  luci.http.prepare_content("application/json")
  luci.http.write_json({ result = "OK" })
end

-- stop_acc_service
function stop_acc_service()
  local util = require "luci.util"
  util.exec("/etc/init.d/acc stop")
  util.exec("/etc/init.d/acc disable")
  luci.http.prepare_content("application/json")
  luci.http.write_json({ result = "OK" })
end

-- schedule_pause
function schedule_pause()
  local util = require "luci.util"
  local uci = require "luci.model.uci".cursor()
  local schedule_enabled = uci:get("accelerator", "system", "schedule_enabled") or "0"
  local pause_time = uci:get("accelerator", "system", "pause_time") or "01:00"
  local username = uci:get("accelerator", "system", "username") or ""
  local password = uci:get("accelerator", "system", "password") or ""
  util.exec("sed -i '/\\/usr\\/sbin\\/leigod\\/leigod-helper.sh/d' /etc/crontabs/root")
  if schedule_enabled == "1" then
    local hour, minute = pause_time:match("(%d+):(%d+)")
    local safe_username = username:gsub("'", "'\\''")
    local safe_password = password:gsub("'", "'\\''")
    local cron_time = string.format("%s %s * * * USERNAME='%s' PASSWORD='%s' /usr/sbin/leigod/leigod-helper.sh", tonumber(minute), tonumber(hour), safe_username, safe_password)
    util.exec("echo '" .. cron_time .. "' >> /etc/crontabs/root")
    util.exec("/etc/init.d/cron restart")
  end
  luci.http.prepare_content("application/json")
  luci.http.write_json({ result = "OK" })
end

-- ============================================================
-- Auto-Pause API endpoints (fw4 adapted)
-- ============================================================

local AP_CONF = "/etc/leigod-auto-pause.conf"
local AP_STATE = "/tmp/leigod-auto-pause.state"
local AP_CRON = "/etc/crontabs/root"
local AP_SCRIPT = "/usr/sbin/leigod-auto-pause.sh"

-- Read auto-pause config file, return table
local function read_ap_conf()
  local fs = require "nixio.fs"
  local conf = {}
  if not fs.access(AP_CONF) then
    return conf
  end
  for line in io.lines(AP_CONF) do
    local key, val = line:match("^([A-Z_]+)='(.*)'$")
    if key and val then
      conf[key] = val
    elseif line:match("^IDLE_CHECKS_BEFORE_PAUSE=(%d+)") then
      conf["IDLE_CHECKS_BEFORE_PAUSE"] = line:match("=(%d+)")
    elseif line:match("^API_TIMEOUT=(%d+)") then
      conf["API_TIMEOUT"] = line:match("=(%d+)")
    elseif line:match("^NOTIFY_ON_PAUSE=(%d+)") then
      conf["NOTIFY_ON_PAUSE"] = line:match("=(%d+)")
    elseif line:match("^MANUAL_DISABLE=(%d+)") then
      conf["MANUAL_DISABLE"] = line:match("=(%d+)")
    end
  end
  return conf
end

-- Read auto-pause state file
local function read_ap_state()
  local fs = require "nixio.fs"
  local state = { idle_count = "0", last_pause_epoch = "0" }
  if not fs.access(AP_STATE) then
    return state
  end
  for line in io.lines(AP_STATE) do
    local key, val = line:match("^([a-z_]+)=(%d+)$")
    if key and val then
      state[key] = val
    end
  end
  return state
end

-- Mask token: show first 8 + last 4 characters
local function mask_token(token)
  if not token or #token <= 12 then
    return token and string.rep("*", #token) or "(not set)"
  end
  return token:sub(1, 8) .. "..." .. token:sub(-4)
end

-- get_autopause_status — AJAX polling endpoint
function get_autopause_status()
  local util = require "luci.util"
  local fs   = require "nixio.fs"

  local resp = {}
  local conf = read_ap_conf()

  -- Token status
  resp.token_configured = conf["ACCOUNT_TOKEN"] ~= nil and conf["ACCOUNT_TOKEN"] ~= ""
  resp.token_masked = mask_token(conf["ACCOUNT_TOKEN"])

  -- Config values
  resp.idle_checks = conf["IDLE_CHECKS_BEFORE_PAUSE"] or "3"
  resp.api_timeout  = conf["API_TIMEOUT"] or "10"
  resp.manual_disable = conf["MANUAL_DISABLE"] or "0"

  -- Cron status
  local cron_enabled = false
  if fs.access(AP_CRON) then
    for line in io.lines(AP_CRON) do
      if line:match("leigod%-auto%-pause") then
        cron_enabled = true
        break
      end
    end
  end
  resp.cron_enabled = cron_enabled

  -- Runtime state
  local state = read_ap_state()
  resp.idle_count = state["idle_count"] or "0"
  resp.last_pause_epoch = state["last_pause_epoch"] or "0"

  -- Format last pause time
  if tonumber(resp.last_pause_epoch) > 0 then
    local now = tonumber(os.date("%s"))
    local ago = now - tonumber(resp.last_pause_epoch)
    if ago < 60 then
      resp.last_pause_text = "just now"
    elseif ago < 3600 then
      resp.last_pause_text = string.format("%d min ago", math.floor(ago / 60))
    else
      resp.last_pause_text = string.format("%d hr ago", math.floor(ago / 3600))
    end
  else
    resp.last_pause_text = "never"
  end

  -- Script exists
  resp.script_installed = fs.access(AP_SCRIPT)

  -- Is potentially already paused (API cooldown active)
  if tonumber(state["last_pause_epoch"] or 0) > 0 then
    local now = tonumber(os.date("%s"))
    resp.in_cooldown = (now - tonumber(state["last_pause_epoch"])) < 600
  else
    resp.in_cooldown = false
  end

  luci.http.prepare_content("application/json")
  luci.http.write_json(resp)
end

-- save_autopause_config — partial-update handler.
-- Only fields explicitly passed in the request are updated;
-- all others are preserved from the existing config file.
function save_autopause_config()
  local util = require "luci.util"
  local conf = read_ap_conf()

  -- Read request values, fall back to existing config
  local token = luci.http.formvalue("account_token")
  if not token or token == "" or token:match("^%*+$") then
    token = conf["ACCOUNT_TOKEN"]  -- preserve existing
  else
    token = token:gsub("[^a-zA-Z0-9_-]", "")  -- sanitize (prevent config breakage)
  end
  local idle_checks = luci.http.formvalue("idle_checks") or conf["IDLE_CHECKS_BEFORE_PAUSE"] or "3"
  local api_timeout = luci.http.formvalue("api_timeout") or conf["API_TIMEOUT"] or "10"
  local notify = luci.http.formvalue("notify_on_pause") or conf["NOTIFY_ON_PAUSE"] or "1"
  local manual_disable = luci.http.formvalue("manual_disable")
  if manual_disable == nil or manual_disable == "" then
    manual_disable = conf["MANUAL_DISABLE"] or "0"
  end

  local file = io.open(AP_CONF, "w")
  if not file then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "Cannot write config file" })
    return
  end

  file:write("# LeigodAcc Auto-Pause configuration\n")
  if token and token ~= "" then
    file:write(string.format("ACCOUNT_TOKEN='%s'\n", token))
  end
  file:write(string.format("IDLE_CHECKS_BEFORE_PAUSE=%d\n", tonumber(idle_checks) or 3))
  file:write(string.format("API_TIMEOUT=%d\n", tonumber(api_timeout) or 10))
  file:write(string.format("API_ENDPOINT=\"https://webapi.leigod.com\"\n"))
  file:write(string.format("NOTIFY_ON_PAUSE=%d\n", tonumber(notify) or 1))
  file:write(string.format("MANUAL_DISABLE=%d\n", tonumber(manual_disable) or 0))
  file:close()

  util.exec(string.format("chmod 600 %s", AP_CONF))
  luci.http.prepare_content("application/json")
  luci.http.write_json({ result = "OK" })
end

-- trigger_autopause — manual pause trigger
function trigger_autopause()
  local util = require "luci.util"
  local fs   = require "nixio.fs"

  if not fs.access(AP_SCRIPT) then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "auto-pause.sh not installed" })
    return
  end

  -- Respect manual disable (away mode)
  local conf = read_ap_conf()
  if conf["MANUAL_DISABLE"] == "1" then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "离家模式已启用, 手动暂停被禁止" })
    return
  end

  local token = ""
  if conf["ACCOUNT_TOKEN"] then
    token = conf["ACCOUNT_TOKEN"]
  end

  if token == "" then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "account_token not configured" })
    return
  end

  -- Send a direct pause API call (same as auto-pause.sh does)
  local safe_token = token:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("'", "'\\''")
  local cmd = string.format(
    "curl -sL --connect-timeout 10 -X POST 'https://webapi.leigod.com/api/user/pause' " ..
    "-H 'Content-Type: application/json' " ..
    "-H 'User-Agent: LeigodAcc-AutoPause/1.0' " ..
    "-d '{\"account_token\":\"%s\",\"lang\":\"zh_CN\"}'", safe_token)
  local resp_body = util.exec(cmd)
  local code = resp_body:match('"code":%s*(%d+)')

  if code == "0" then
    -- Record pause timestamp via Lua I/O (echo '\n' is literal on BusyBox)
    local now = os.date("%s")
    local sf = io.open(AP_STATE, "w")
    if sf then
      sf:write("idle_count=0\n")
      sf:write("last_pause_epoch=" .. now .. "\n")
      sf:close()
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "OK", message = "Pause successful" })
  elseif code == "400803" then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "OK", message = "Already paused" })
  else
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "API returned code: " .. (code or "nil") })
  end
end

-- toggle_autopause_cron — enable/disable the cron job
function toggle_autopause_cron()
  local util = require "luci.util"
  local fs   = require "nixio.fs"
  local enable = luci.http.formvalue("enable")

  if not fs.access(AP_SCRIPT) then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "auto-pause.sh not installed" })
    return
  end

  if enable == "1" then
    -- Add cron if not present
    if fs.access(AP_CRON) then
      local has_cron = false
      for line in io.lines(AP_CRON) do
        if line:match("leigod%-auto%-pause") then has_cron = true; break end
      end
      if not has_cron then
        local f = io.open(AP_CRON, "a")
        if f then
          f:write(string.format("*/2 * * * * %s >> /tmp/leigod-auto-pause.log 2>&1\n", AP_SCRIPT))
          f:close()
        end
        util.exec("/etc/init.d/cron restart 2>/dev/null")
      end
    end
  else
    -- Remove cron
    util.exec(string.format("sed -i '/leigod-auto-pause/d' %s", AP_CRON))
    util.exec("/etc/init.d/cron restart 2>/dev/null")
  end

  luci.http.prepare_content("application/json")
  luci.http.write_json({ result = "OK" })
end

-- ============================================================
-- Diagnostic debug endpoint (fw4 adapted)
-- Collects system state and automatically flags issues.
-- ============================================================
function get_debug_status()
  local util  = require "luci.util"
  local uci   = require "luci.model.uci".cursor()
  local fs    = require "nixio.fs"

  local resp = {
    system         = {},
    process        = {},
    init_script    = {},
    network        = {},
    packages       = {},
    devices        = {},
    autopause      = {},
    logs           = {},
    issues         = {},
    checks_passed  = 0,
    checks_total   = 0,
    checks_failed  = 0,
    checks_warn    = 0
  }

  local function check(name, ok, level)
    level = level or "error"
    resp.checks_total = resp.checks_total + 1
    if ok then
      resp.checks_passed = resp.checks_passed + 1
    else
      if level == "error" then
        resp.checks_failed = resp.checks_failed + 1
      else
        resp.checks_warn = resp.checks_warn + 1
      end
    end
    return ok
  end

  local function issue(severity, msg)
    resp.issues[#resp.issues + 1] = { severity = severity, message = msg }
  end

  -- === System ===
  local release = util.exec("cat /etc/openwrt_release 2>/dev/null | head -1") or ""
  release = release:gsub("\n", ""):gsub("^%s+", ""):gsub("%s+$", "")
  resp.system.firmware = release ~= "" and release or "Unknown"
  resp.system.kernel   = (util.exec("uname -r"):gsub("\n", ""))
  resp.system.arch     = (util.exec("uname -m"):gsub("\n", ""))
  resp.system.uptime   = (util.exec("uptime"):gsub("\n", "") or "")
  resp.system.lan_ip   = (uci:get("network", "lan", "ipaddr") or "unknown")
  resp.system.lan_mask = (uci:get("network", "lan", "netmask") or "unknown")

  local has_fw4 = fs.access("/usr/sbin/fw4")
  local has_nft = fs.access("/usr/sbin/nft")
  resp.system.fw4_exists = has_fw4
  resp.system.nft_exists = has_nft

  if has_fw4 or has_nft then
    resp.system.firewall_type = "nftables (fw4)"
  else
    resp.system.firewall_type = "iptables (fw3)"
  end

  -- === Process ===
  -- Use 'ps ww' (unlimited width) to avoid BusyBox truncating long command lines
  -- Without 'ww', '-m tproxy' gets truncated to '-m tp'
  local ps_out = util.exec("ps ww | grep acc-gw | grep -v grep 2>/dev/null") or ""
  resp.process.running = ps_out ~= ""
  -- Take first line only (daemon process) to avoid multi-line concatenation
  local cmdline = (ps_out:match("[^\n]+") or ""):gsub("%s+", " ")
  resp.process.cmdline = cmdline ~= "" and cmdline or "N/A"

  -- Extract mode from actual process command line
  local pid_mode = cmdline:match("%-m (%S+)")
  resp.process.mode_cmdline = pid_mode or "not detected"
  resp.process.mode_ok = (pid_mode == "tun" or pid_mode == "tproxy")

  -- PID and memory (VSZ)
  -- BusyBox ps columns: PID USER VSZ STAT COMMAND (no RSS by default)
  -- $1=PID, $3=VSZ (virtual memory in KB) — use VSZ since RSS is not available
  local pid_raw = util.exec("ps ww | grep acc-gw | grep -v grep | head -1 | awk '{print $1,$3}' 2>/dev/null") or ""
  pid_raw = pid_raw:gsub("\n", ""):gsub("%s+", " ")
  local pid_parts = {}
  for p in pid_raw:gmatch("%S+") do pid_parts[#pid_parts+1] = p end
  resp.process.pid = pid_parts[1] or "N/A"
  resp.process.vsz_kb = pid_parts[2] or "N/A"

  -- Port listening check: parse /proc/net/tcp directly.
  -- iStoreOS 25.12 has no `ss` binary and netstat may be absent as well;
  -- /proc/net/tcp prints the port in hex (5588 -> 0x15D4), state 0A = LISTEN.
  local function port_listen(port)
    local hex = string.format("%04X", port)
    local f, line
    for _, path in ipairs({ "/proc/net/tcp", "/proc/net/tcp6" }) do
      f = io.open(path, "r")
      if f then
        for line in f:lines() do
          local addr, st = line:match("^%s*%d+:%s*(%S+)%s+%S+%s+(%S+)")
          if st == "0A" and addr and #addr >= #hex and addr:sub(-#hex) == hex then
            f:close()
            return true
          end
        end
        f:close()
      end
    end
    return false
  end
  resp.process.port_listening = port_listen(5588)

  -- Init script enabled: procd's `enabled` prints nothing, only sets an exit
  -- code, so a text match can never work (and always reported "No").
  local init_rc = os.execute("/etc/init.d/acc enabled >/dev/null 2>&1")
  resp.process.init_enabled = (init_rc == 0)

  -- === Init Script Analysis ===
  resp.init_script.exists = fs.access("/etc/init.d/acc")
  if resp.init_script.exists then
    local args_line = ""
    for line in io.lines("/etc/init.d/acc") do
      if line:match("^%s*args=") then
        args_line = line:gsub("^%s*", ""):gsub("%s*$", "")
        break
      end
    end
    resp.init_script.args_line = args_line ~= "" and args_line or "(args= line not found)"

    -- Detect mode flag format
    local short_tun  = args_line:match("%-m tun")
    local short_tpr  = args_line:match("%-m tproxy")
    local long_tun   = args_line:match("%-%mode tun")
    local long_tpr   = args_line:match("%-%mode tproxy")
    -- 25.12 init script uses a template: args="-r daemon -m ${mode} -p 5588"
    -- (${mode} is filled in from acc_firewall.ini at start time)
    local tpl_mode   = args_line:find("-m ${mode}", 1, true) ~= nil

    resp.init_script.short_format = (short_tun ~= nil or short_tpr ~= nil or tpl_mode)
    resp.init_script.has_long_format = (long_tun ~= nil or long_tpr ~= nil)
    resp.init_script.template_mode = tpl_mode

    if short_tun then
      resp.init_script.mode_flag = "-m tun"
      resp.init_script.mode_name = "TUN"
    elseif short_tpr then
      resp.init_script.mode_flag = "-m tproxy"
      resp.init_script.mode_name = "TPROXY"
    elseif tpl_mode then
      resp.init_script.mode_flag = "-m ${mode}"
      resp.init_script.mode_name = "由 acc_firewall.ini 的 mode 决定"
    elseif long_tun then
      resp.init_script.mode_flag = "--mode tun"
      resp.init_script.mode_name = "TUN (LONG FORMAT)"
    elseif long_tpr then
      resp.init_script.mode_flag = "--mode tproxy"
      resp.init_script.mode_name = "TPROXY (LONG FORMAT)"
    else
      resp.init_script.mode_flag = "MISSING"
      resp.init_script.mode_name = "UNKNOWN"
    end

    resp.init_script.has_port = args_line:match("%-p %d+") ~= nil
  else
    resp.init_script.args_line = "N/A"
    resp.init_script.mode_flag = "N/A"
    resp.init_script.mode_name = "N/A"
    resp.init_script.short_format = false
    resp.init_script.has_long_format = false
    resp.init_script.has_port = false
  end

  -- === Core Config (acc_core_conf.json) ===
  resp.core_config = { exists = false, tproxy_ip = "N/A", tproxy_ip_ok = false,
    acc_mode = "N/A", acc_mode_name = "N/A", acc_mode_ok = false }
  if fs.access("/tmp/acc/acc_core_conf.json") then
    resp.core_config.exists = true
    local conf_raw = ""
    for line in io.lines("/tmp/acc/acc_core_conf.json") do
      conf_raw = conf_raw .. line
    end
    local tproxy = conf_raw:match('"tproxy_ip":"([^"]*)"')
    resp.core_config.tproxy_ip = tproxy or "not found"
    local lan_ip = uci:get("network", "lan", "ipaddr") or ""
    -- New layout: acc_firewall.ini carries the authoritative TPROXY target
    -- (a per-backend sentinel, NOT the LAN IP). Legacy: LAN IP.
    local expect = lan_ip
    local ini_present = fs.access("/etc/config/acc_firewall.ini")
    if ini_present then
      for line in io.lines("/etc/config/acc_firewall.ini") do
        local v = line:match("^tproxy_ip=(.*)$")
        if v then expect = v end
      end
    end
    resp.core_config.expected_tproxy_ip = expect
    resp.core_config.tproxy_ip_ok = (tproxy == expect)
    local acc_mode = conf_raw:match('"acc_mode":(%d+)')
    resp.core_config.acc_mode = acc_mode or "not found"
    if acc_mode == "1" then
      resp.core_config.acc_mode_name = "TUN"
      resp.core_config.acc_mode_ok = true
    elseif acc_mode == "2" then
      resp.core_config.acc_mode_name = "TPROXY"
      resp.core_config.acc_mode_ok = true
    else
      resp.core_config.acc_mode_name = "UNKNOWN (" .. (acc_mode or "nil") .. ")"
      resp.core_config.acc_mode_ok = false
    end
  end

  -- === Network ===
  local ip_link = util.exec("ip link show 2>/dev/null") or ""
  local tun_match = ip_link:match("(tun%d+):")
  resp.network.tun_iface = tun_match or nil

  -- Firewall rule for TCP 5588
  local fw_rules = util.exec("uci show firewall 2>/dev/null | grep '5588'") or ""
  resp.network.fw_rule_5588 = fw_rules ~= ""

  resp.network.hotplug = fs.access("/etc/hotplug.d/firewall/99-leigodacc-restart")

  -- TURN relay connectivity
  local turn_ping = util.exec("ping -c 1 -W 2 route-turn.xxghh.biz 2>/dev/null | grep -c 'bytes from'") or "0"
  resp.network.turn_reachable = (tonumber(turn_ping:match("%d+")) or 0) > 0

  -- API endpoint reachability
  local api_curl = util.exec("curl -sLo /dev/null -w '%{http_code}' --connect-timeout 3 https://webapi.leigod.com 2>/dev/null") or "000"
  resp.network.api_reachable = api_curl:match("^[23]%d%d$") ~= nil
  resp.network.api_http_code = api_curl:gsub("%s+","")

  -- GAMEACC chain check (iptables-legacy or iptables-nft)
  -- GAMEACC chain: use exit code for reliable detection
  local ga_ok = os.execute("iptables -L GAMEACC -n >/dev/null 2>&1")
  local gameacc_rules = util.exec("iptables -L GAMEACC -n -v 2>/dev/null | head -20") or ""
  if ga_ok == 0 then
    resp.network.gameacc_exists = true
    local counter_line = gameacc_rules:match("\n%s*(%d+%s+%d+%s+[A-Z]+.*)")
    resp.network.gameacc_sample = counter_line and counter_line:gsub("^%s+",""):gsub("%s+$","") or "规则存在 (无计数器行)"
  else
    resp.network.gameacc_exists = false
    resp.network.gameacc_sample = "N/A"
  end

  -- === TPROXY policy routing ===
  -- The engine marks intercepted packets with 0x99 and relies on
  --   ip rule add fwmark 0x99 pref 99 lookup 99
  --   ip route add local default dev lo table 99
  -- to deliver them to the local proxy.  When either is missing the packets
  -- are still marked by GAMEACC but fall through to the default route, which
  -- looks exactly like "APP says accelerating but traffic is not proxied".
  local rule_out = util.exec("ip rule show 2>/dev/null") or ""
  resp.network.tproxy_rule = rule_out:find("fwmark 0x99", 1, true) ~= nil
  local rt_out = util.exec("ip route show table 99 2>/dev/null") or ""
  resp.network.tproxy_route = rt_out:find("local default dev lo", 1, true) ~= nil

  -- Engine rule-injection failures (its own log wording)
  local inject_fail = util.exec(
    "grep -l -E 'add ip route failed|add ip routes failed|create tproxy common rules failed|create acc tproxy rules failed' /tmp/acc/log/*.log 2>/dev/null | head -1") or ""
  resp.network.tproxy_inject_failed = inject_fail ~= ""

  -- === Acceleration tunnel health ===
  -- The engine keeps a heartbeat to each relay server it may use; a missing
  -- heartbeat means the tunnel is not up and nothing will be accelerated.
  resp.tunnel = { servers = {}, ok = false, data_plane = false }
  local tlog = "/tmp/acc/log/acc_Game.log"
  if not fs.access(tlog) then tlog = "/tmp/acc/log/acc_acc.log" end
  if fs.access(tlog) then
    resp.tunnel.log = tlog
    local out = util.exec("grep -a 'TunnelHeartBeat' " .. tlog .. " 2>/dev/null | tail -60") or ""
    local seen = {}
    for line in out:gmatch("[^\n]+") do
      local ip, port, loss, avg = line:match(
        "server%\([^)]*%\):([%d%.]+):(%d+).-lost_persent:(%d+)%-*.-average_delay:(%d+)")
      if not avg then
        ip, port, loss = line:match("server%\([^)]*%\):([%d%.]+):(%d+).-lost_persent:(%d+)")
      end
      local addr = ip and (ip .. ":" .. port) or nil
      if addr and not seen[addr] then
        seen[addr] = true
        resp.tunnel.servers[#resp.tunnel.servers + 1] = {
          addr = addr,
          loss = tonumber(loss) or 0,
          delay = tonumber(avg) or 0
        }
      end
    end
    resp.tunnel.ok = #resp.tunnel.servers > 0
    local s5 = util.exec("grep -ac 'S5 UDP' " .. tlog .. " 2>/dev/null") or "0"
    resp.tunnel.data_plane = (tonumber(s5:match("%d+")) or 0) > 0
  end

  -- === Latency Diagnostics ===
  resp.latency = {}
  local function ping_host(host)
    local out = util.exec("ping -c 5 -W 2 " .. host .. " 2>/dev/null") or ""
    local loss = out:match("(%d+)%% packet loss") or "?"
    local rtt = out:match("([%d.]+/[%d.]+/[%d.]+) ms") or out:match("min/avg/max = ([%d./]+)") or ""
    local min, avg, max = "?", "?", "?"
    if rtt ~= "" then
      min, avg, max = rtt:match("([%d.]+)/([%d.]+)/([%d.]+)")
      min, avg, max = min or "?", avg or "?", max or "?"
    end
    return { loss = loss, min = min, avg = avg, max = max }
  end

  -- Ping gateway (local network)
  local gw = uci:get("network", "lan", "gateway") or uci:get("network", "lan", "ipaddr") or "192.168.10.1"
  resp.latency.gateway = ping_host(gw)
  resp.latency.gateway.host = gw

  -- Ping public DNS (internet baseline)
  local dns_host = "223.5.5.5"
  resp.latency.dns = ping_host(dns_host)
  resp.latency.dns.host = dns_host
  -- If first DNS fails, try alternate
  if resp.latency.dns.loss == "100" or resp.latency.dns.avg == "?" then
    resp.latency.dns = ping_host("8.8.8.8")
    resp.latency.dns.host = "8.8.8.8"
  end

  -- Ping TURN relay (accelerator server)
  resp.latency.turn = ping_host("route-turn.xxghh.biz")
  resp.latency.turn.host = "route-turn.xxghh.biz"

  -- Extract acceleration server nodes with their ping values from JSON
  resp.latency.nodes = {}
  if fs.access("/tmp/acc/acc_core_conf.json") then
    local raw = ""
    for line in io.lines("/tmp/acc/acc_core_conf.json") do raw = raw .. line end
    -- Extract server host:port and ping values
    -- Pattern: "node":"s5://...@IP:PORT","ping":NN
    for ip, port, ping_val in raw:gmatch('//[^@]+@([%d.]+):(%d+)"[^}]-"ping":(%d+)') do
      resp.latency.nodes[#resp.latency.nodes + 1] = {
        ip = ip, port = port, ping_ms = tonumber(ping_val) }
    end
    -- Try alternate pattern for node IP
    if #resp.latency.nodes == 0 then
      for ip, ping_val in raw:gmatch('"node":"[^"]+@([%d.]+):%d+","ping":(%d+)') do
        resp.latency.nodes[#resp.latency.nodes + 1] = { ip = ip, ping_ms = tonumber(ping_val) }
      end
    end
  end

  -- === Packages ===
  local pkg_check = {
    ["iptables-nft"]    = "iptables-nft",
    ["kmod-nft-nat"]    = "kmod-nft-nat",
    ["kmod-nft-tproxy"] = "kmod-nft-tproxy",
    ["kmod-tun"]        = "kmod-tun",
    ["tc-full"]         = "tc-full",
    ["conntrack"]       = "conntrack",
    ["libpcap1"]        = "libpcap1",
    ["luci-compat"]     = "luci-compat",
    ["luci-lua-runtime"] = "luci-lua-runtime"
  }
  resp.packages = {}
  -- Package names differ between opkg (<=24.10) and apk (>=25.12);
  -- probe both so the diagnostics page works on either backend.
  local function pkg_installed_lua(pkg)
    local alt = pkg
    if pkg == "libpcap1" then alt = "libpcap" end
    for _, cand in ipairs({ pkg, alt }) do
      if util.exec("apk info -e '" .. cand .. "' >/dev/null 2>&1 && echo yes || echo no"):match("yes") then
        return true
      end
      if util.exec("opkg list-installed 2>/dev/null | grep -q '^" .. cand .. " ' && echo yes || echo no"):match("yes") then
        return true
      end
    end
    return false
  end
  for name, pkg in pairs(pkg_check) do
    resp.packages[name] = pkg_installed_lua(pkg)
  end

  -- === Devices ===
  resp.devices = { Phone = "None", PC = "None", Game = "None", Unknown = "None" }
  if fs.access("/tmp/acc/acc_core_conf.json") then
    local raw = ""
    for line in io.lines("/tmp/acc/acc_core_conf.json") do raw = raw .. line end
    for _, cat in ipairs({"Phone","PC","Game","Unknown"}) do
      local pos = raw:find('"'..cat..'":')
      if pos then
        local st = raw:sub(pos):match('"state":(%d+)')
        if st then
          local state = tonumber(st)
          if state == 1 then resp.devices[cat] = "Accelerating"
          elseif state == 2 then resp.devices[cat] = "Idle"
          elseif state == 3 then resp.devices[cat] = "Paused" end
        end
      end
    end
  end

  -- === Auto-Pause ===
  resp.autopause = {
    script_installed = fs.access("/usr/sbin/leigod-auto-pause.sh"),
    token_configured = false,
    token_masked     = "(not set)",
    daemon_token_ok  = false,
    cron_enabled     = false,
    manual_disable   = "0"
  }
  -- Check manual token
  if fs.access("/etc/leigod-auto-pause.conf") then
    for line in io.lines("/etc/leigod-auto-pause.conf") do
      local token_val = line:match("ACCOUNT_TOKEN='(.*)'")
      if token_val and token_val ~= "" then
        resp.autopause.token_configured = true
        if #token_val > 12 then
          resp.autopause.token_masked = token_val:sub(1, 8) .. "..." .. token_val:sub(-4)
        else
          resp.autopause.token_masked = string.rep("*", #token_val)
        end
        -- no break: continue loop to parse MANUAL_DISABLE and other keys
      end
      local md = line:match("^MANUAL_DISABLE=(%d+)")
      if md then resp.autopause.manual_disable = md end
    end
  end
  -- Check daemon token (fallback source, always fresh via heartbeat)
  if fs.access("/tmp/acc/acc_core_conf.json") then
    local dt = util.exec("grep -o '\\\\\"token\\\\\":\\\\\"[^\\\\]*' /tmp/acc/acc_core_conf.json 2>/dev/null | head -1 | sed 's/.*\\\\\"//'")
    dt = dt:gsub("\n",""):gsub("%s+","")
    resp.autopause.daemon_token_ok = (#dt > 10)
  end
  if fs.access("/etc/crontabs/root") then
    for line in io.lines("/etc/crontabs/root") do
      if line:match("leigod%-auto%-pause") then
        resp.autopause.cron_enabled = true
        break
      end
    end
  end

  -- === Logs ===
  local raw_logs = util.exec("logread -l 20 2>/dev/null | grep -iE 'leigod|acc-gw|auto.pause' | tail -5") or ""
  resp.logs = {}
  if raw_logs ~= "" and raw_logs ~= "\n" then
    for line in raw_logs:gmatch("[^\n]+") do
      resp.logs[#resp.logs + 1] = line
    end
  end

  -- === Error Log Scan (/tmp/acc/log/) ===
  resp.error_logs = {}
  local log_dir = "/tmp/acc/log/"
  if fs.access(log_dir) then
    local log_files = { "acc_daemon.log", "acc_web.log", "acc_acc.log" }
    for _, lf in ipairs(log_files) do
      local path = log_dir .. lf
      if fs.access(path) then
        -- Only real ERROR/WARN lines: "child process exit ... INFO" is routine
        local content = util.exec("tail -n 200 " .. path ..
          " 2>/dev/null | grep -E ' (ERROR|WARN|FATAL) ' | grep -v -E 'acc_objs is empty|delete iptables rule failed|delete rule failed|unknow acc mode|acceleration is empty|log report switch failed|router_log_report_config' | tail -5") or ""
        if content ~= "" and content ~= "\n" then
          for line in content:gmatch("[^\n]+") do
            resp.error_logs[#resp.error_logs + 1] = { file = lf, line = line }
          end
        end
      end
    end
  end

  -- === Web child crash loop ===
  -- New engines fork `-r web` and, when it cannot start (e.g. it fails to pull
  -- the global config from opapi.xxghh.biz), it exits and is reforked ~5s.
  -- acc_daemon.log then repeats "child process exit, ... status:0".
  local loop_n = util.exec("tail -60 /tmp/acc/log/acc_daemon.log 2>/dev/null | grep -c 'child process exit'") or "0"
  resp.web_loop_count = tonumber(loop_n:match("%d+")) or 0

  -- === acc_firewall.ini (authoritative on 25.12 builds) ===
  resp.firewall_ini = { exists = fs.access("/etc/config/acc_firewall.ini") }
  if resp.firewall_ini.exists then
    for line in io.lines("/etc/config/acc_firewall.ini") do
      local k, v = line:match("^([%w_]+)=(.*)$")
      if k == "backend" then
        resp.firewall_ini.backend = v
      elseif k == "mode" then
        resp.firewall_ini.mode = v
      elseif k == "tproxy_ip" then
        resp.firewall_ini.tproxy_ip = v
      end
    end
    -- Vendor sentinel per backend (see lib/setup.sh get_tproxy_ip_by_backend)
    local want = "10.20.30.40"
    if resp.firewall_ini.backend == "nftables" then want = "0.0.0.0" end
    resp.firewall_ini.expected_tproxy_ip = want
    resp.firewall_ini.tproxy_sentinel_ok = (resp.firewall_ini.tproxy_ip == want)
  end

  -- ============================================================
  -- Automatic issue detection
  -- ============================================================

  -- CRITICAL: Long format mode flag
  if resp.init_script.has_long_format then
    issue("error", "Init script uses GNU long format (" .. (resp.init_script.mode_flag or "--mode") .. "). The acc-gw binary only recognizes short format (-m tun / -m tproxy). This flag is SILENTLY IGNORED and the binary defaults to TPROXY.")
    check("Init script mode flag uses short format (-m)", false, "error")
  else
    check("Init script mode flag uses short format (-m)", resp.init_script.short_format, "error")
  end

  -- Process running
  if resp.process.running then
    check("acc-gw process is running", true)
  else
    issue("error", "acc-gw process is NOT running. Acceleration is completely non-functional.")
    check("acc-gw process is running", false, "error")
  end

  -- Mode consistency: is the process actually running in the mode the init script specifies?
  if resp.process.running and resp.init_script.short_format
     and not resp.init_script.template_mode then
    local init_mode = resp.init_script.mode_flag:match("%-m (%S+)")
    if init_mode and pid_mode and init_mode ~= pid_mode then
      issue("warning", "Mode mismatch: init script specifies " .. init_mode .. " but process is running as " .. pid_mode .. ". Try restarting the service (menu option 5).")
      check("Process mode matches init script", false, "warning")
    else
      check("Process mode matches init script", true)
    end
  end

  -- Mode check: this binary ONLY supports TPROXY (not TUN)
  if resp.process.running then
    if pid_mode == "tun" then
      -- TUN was selected but binary may ignore it; check if it actually took effect
      if resp.network.tun_iface then
        check("TUN mode active (TUN interface exists)", true)
      else
        issue("info", "选择了 TUN 模式但二进制不支持 TUN，实际运行在 TPROXY。风险: 低(如加速正常则无影响)")
        check("TUN mode active", false, "info")
      end
    elseif pid_mode == "tproxy" then
      -- TPROXY is the only supported mode for this binary — no issue
      check("运行模式 (TPROXY)", true, "info")
    end
  end

  -- TUN interface
  if pid_mode == "tun" then
    if resp.network.tun_iface then
      check("TUN interface exists (TUN mode active)", true)
    else
      issue("warning", "Process claims TUN mode but no tunX interface found. The TUN device may have failed to create.")
      check("TUN interface exists (TUN mode active)", false, "warning")
    end
  end

  -- Port 5588
  if resp.process.running then
    if resp.process.port_listening then
      check("API port 5588 is listening", true)
    else
      issue("error", "Port 5588 is NOT listening. Phone APP cannot communicate with acc-gw. Clicking 'accelerate' will hang.")
      check("API port 5588 is listening", false, "error")
    end
  end

  -- Firewall rule for 5588
  if not resp.network.fw_rule_5588 and (has_fw4 or has_nft) then
    issue("warning", "No firewall rule for TCP 5588. fw4 may block LAN traffic to the acc-gw API. Run menu option 1 or install via script to auto-configure.")
    check("Firewall rule allows TCP 5588", false, "warning")
  else
    check("Firewall rule allows TCP 5588", resp.network.fw_rule_5588 or not (has_fw4 or has_nft))
  end

  -- Hotplug
  if has_fw4 or has_nft then
    if resp.network.hotplug then
      check("fw4 hotplug script installed", true)
    else
      issue("warning", "fw4 hotplug script not installed. After fw4 reload, acceleration rules may be lost.")
      check("fw4 hotplug script installed", false, "warning")
    end
  end

  -- Init script has port
  if resp.init_script.exists then
    if resp.init_script.has_port then
      check("Init script specifies API port (-p)", true)
    else
      issue("error", "Init script missing -p <port>. acc-gw may not listen on the correct port.")
      check("Init script specifies API port (-p)", false, "error")
    end
  end

  -- Critical packages
  if resp.packages["kmod-tun"] ~= nil and not resp.packages["kmod-tun"] then
    issue("warning", "kmod-tun is not installed. TUN mode will NOT work without it.")
    check("kmod-tun is installed", false, "warning")
  else
    check("kmod-tun is installed", resp.packages["kmod-tun"] ~= false)
  end

  if (has_fw4 or has_nft) then
    if resp.packages["iptables-nft"] ~= nil and not resp.packages["iptables-nft"] then
      issue("warning", "iptables-nft is not installed. iptables commands will not translate to nftables rules.")
      check("iptables-nft is installed", false, "warning")
    else
      check("iptables-nft is installed", resp.packages["iptables-nft"] ~= false)
    end

    if resp.packages["kmod-nft-nat"] ~= nil and not resp.packages["kmod-nft-nat"] then
      issue("warning", "kmod-nft-nat is not installed. NAT rules required for acceleration may not work.")
      check("kmod-nft-nat is installed", false, "warning")
    else
      check("kmod-nft-nat is installed", resp.packages["kmod-nft-nat"] ~= false)
    end
  end

  -- Init script file exists
  if resp.init_script.exists then
    check("Init script /etc/init.d/acc exists", true)
  else
    issue("error", "Init script /etc/init.d/acc not found. LeigodAcc may not be installed.")
    check("Init script /etc/init.d/acc exists", false, "error")
  end

  -- Is anything actually accelerating?
  local any_accel = false
  for _, state in pairs(resp.devices) do
    if state == "Accelerating" then any_accel = true; break end
  end
  if resp.process.running and not any_accel then
    issue("info", "当前无设备在加速。如未开始游戏则属正常，开始游戏后设备状态应变为 Accelerating。")
  end

  -- Init script enabled
  if not resp.process.init_enabled and resp.init_script.exists then
    issue("info", "服务未设为开机自启 (路由器重启后需手动启动)。建议: /etc/init.d/acc enable")
    check("开机自启", false, "info")
  else
    check("开机自启", resp.process.init_enabled, "info")
  end

  -- Core config: tproxy_ip correctness
  if resp.core_config.exists then
    if resp.core_config.tproxy_ip_ok then
      check("acc_core_conf.json tproxy_ip matches configured target", true)
    else
      if pid_mode == "tproxy" then
        issue("error", "acc_core_conf.json tproxy_ip (" .. tostring(resp.core_config.tproxy_ip) .. ") does not match the configured target (" .. tostring(resp.core_config.expected_tproxy_ip) .. "). The web subprocess may crash-loop and the phone APP cannot communicate. Run 'leigod-fw4.sh fix-tproxy' to align it.")
        check("acc_core_conf.json tproxy_ip matches configured target", false, "error")
      else
        issue("warning", "acc_core_conf.json tproxy_ip (" .. tostring(resp.core_config.tproxy_ip) .. ") does not match the configured target (" .. tostring(resp.core_config.expected_tproxy_ip) .. ").")
        check("acc_core_conf.json tproxy_ip matches configured target", false, "warning")
      end
    end

    if resp.core_config.acc_mode_ok then
      check("acc_core_conf.json acc_mode is valid", true)
    else
      issue("error", "acc_core_conf.json has invalid acc_mode (" .. resp.core_config.acc_mode .. "). The daemon may reject this configuration.")
      check("acc_core_conf.json acc_mode is valid", false, "error")
    end
  else
    issue("warning", "acc_core_conf.json not found at /tmp/acc/acc_core_conf.json. The acc-gw daemon has not generated its runtime config yet. Try starting the service first.")
    check("acc_core_conf.json exists", false, "warning")
  end

  -- TURN relay reachability
  if resp.network.turn_reachable then
    check("TURN relay route-turn.xxghh.biz is reachable", true)
  else
    issue("error", "TURN relay host route-turn.xxghh.biz is NOT reachable. This is the relay server that forwards accelerated game traffic. Without it, acceleration will have NO effect on latency. Check your internet connection and DNS.")
    check("TURN relay route-turn.xxghh.biz is reachable", false, "error")
  end

  -- API endpoint reachability
  if resp.network.api_reachable then
    check("Leigod API webapi.leigod.com is reachable", true)
  else
    issue("error", "Leigod API endpoint webapi.leigod.com returned HTTP " .. resp.network.api_http_code .. ". Auto-pause and device status sync will NOT work. Check your internet connection.")
    check("Leigod API webapi.leigod.com is reachable", false, "error")
  end

  -- CDN resolution + routing table (why "tunnel up but nothing accelerated")
  if resp.process.running and pid_mode == "tproxy" then
    if resp.cdn.dfs_resolvable then
      check("引擎 CDN 域名本机可解析 (dfs01.nn.com)", true)
    else
      issue("error", "本机无法解析 dfs01.nn.com：引擎下载不到分流表 (cidrs.txt / cidrs_direct.txt / mac.json)，隧道会空转、游戏不会被加速。处理: 管理器菜单 D 写入 DNS 兜底，然后 /etc/init.d/acc restart。")
      check("引擎 CDN 域名本机可解析 (dfs01.nn.com)", false, "error")
    end

    if resp.cdn.direct_cidrs > 0 then
      check("分流表已加载 (direct_Game 有 " .. resp.cdn.direct_cidrs .. " 条)", true)
    else
      issue("warning", "direct_Game 集合为空：引擎尚未加载直连网段。若刚点加速请稍等再看；持续为空说明分流表没有下载成功（见上一条）。")
      check("分流表已加载 (direct_Game 非空)", false, "warning")
    end
  end

  -- Tunnel heartbeat: without it nothing is accelerated at all
  if resp.process.running and pid_mode == "tproxy" then
    if resp.tunnel and resp.tunnel.ok then
      local best, best_delay = nil, nil
      for _, s in ipairs(resp.tunnel.servers) do
        if s.delay and (not best_delay or s.delay < best_delay) then
          best, best_delay = s, s.delay
        end
      end
      check("加速隧道心跳正常 (" .. (best and best.addr or "?") .. " / " ..
            tostring(best_delay or "?") .. "ms)", true)
    else
      issue("warning", "未检测到加速隧道心跳 (acc_Game.log 内无 TunnelHeartBeat)。隧道未建立时流量不会被转发，请查看该日志。")
      check("加速隧道心跳正常", false, "warning")
    end
  end

  -- === Engine CDN resolution / routing-table availability ===
  -- The engine downloads its routing data from dfs01.nn.com
  -- (mac.json, cidrs.txt, cidrs_direct.txt). When the local resolver returns
  -- only a CNAME (seen with dnsmasq behind MosDNS), every download fails with
  -- "HTTP Status: 0", the tunnel carries only heartbeats and games are never
  -- accelerated. Menu D (dns guard) pins IPv4 into /etc/hosts.
  resp.cdn = { dfs_resolvable = false, direct_cidrs = 0 }
  local cdn_ip = util.exec(
    "nslookup dfs01.nn.com 2>/dev/null | awk '/^Address: *[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$/ {print $2; exit}'") or ""
  resp.cdn.dfs_resolvable = (cdn_ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil)
  local dg = util.exec("ipset list direct_Game 2>/dev/null | grep -c '^[0-9]'") or "0"
  resp.cdn.direct_cidrs = tonumber(dg:match("%d+")) or 0

  -- TPROXY policy routing (new engine: fwmark 0x99 -> table 99 -> local)
  if resp.process.running and pid_mode == "tproxy" then
    if resp.network.tproxy_inject_failed then
      issue("error", "引擎报告加速规则注入失败 (日志含 'add ip routes failed' 或 'create tproxy rules failed')。表现为 APP 显示加速中但游戏流量未被代理。常见原因: ip 命令不可用/策略路由被其他代理插件覆盖/权限不足。")
      check("加速规则注入成功", false, "error")
    else
      check("加速规则注入成功", true)
    end

    if resp.network.tproxy_rule and resp.network.tproxy_route then
      check("TPROXY 策略路由 (fwmark 0x99 / table 99)", true)
    else
      issue("error", "TPROXY 策略路由缺失: ip rule 中没有 'fwmark 0x99' 或 table 99 中没有 'local default dev lo'。此时数据包会被标记却不会交付给代理进程 → 加速看起来成功但出口 IP 不变。")
      check("TPROXY 策略路由 (fwmark 0x99 / table 99)", false, "error")
    end
  end

  -- GAMEACC chain
  if resp.network.gameacc_exists then
    check("GAMEACC iptables chain exists", true)
  else
    if resp.process.running then
      issue("warning", "GAMEACC iptables 链未找到。如手机 APP 已发起加速则规则注入失败, 请重启服务。如未发起加速则属正常。")
      check("GAMEACC iptables chain exists", false, "warning")
    end
  end

  -- Error log scan issues
  if #resp.error_logs > 0 then
    local msgs = {}
    for _, entry in ipairs(resp.error_logs) do
      msgs[#msgs+1] = "[" .. entry.file .. "] " .. entry.line
    end
    issue("warning", "Found " .. #resp.error_logs .. " error/warning lines in acc-gw logs: see Error Logs table for details.")
    check("acc-gw internal logs are error-free", false, "warning")
  else
    check("acc-gw internal logs are error-free", true)
  end

  -- Web child crash loop (new engine refork every ~5s, exit status 0)
  if (resp.web_loop_count or 0) >= 3 then
    issue("error", "检测到 web 子进程崩溃循环: 最近 60 行 acc_daemon.log 出现 " .. resp.web_loop_count .. " 次 'child process exit'。API 端口 5588 不会就绪，手机 APP 无法通信。请查看 /tmp/acc/log/web_api.log 中 start_web 的报错（常见: start global config manager failed = 拉取雷神全局配置失败）。")
    check("web 子进程稳定 (未反复退出)", false, "error")
  else
    check("web 子进程稳定 (未反复退出)", true, "info")
  end

  -- acc_firewall.ini sanity (new layout only)
  if resp.firewall_ini and resp.firewall_ini.exists then
    if resp.firewall_ini.tproxy_sentinel_ok then
      check("acc_firewall.ini tproxy_ip 符合 " .. tostring(resp.firewall_ini.backend) .. " 后端标准值", true)
    else
      issue("warning", "acc_firewall.ini tproxy_ip=" .. tostring(resp.firewall_ini.tproxy_ip) .. "，该后端标准值为 " .. tostring(resp.firewall_ini.expected_tproxy_ip) .. "。执行 leigod-fw4.sh fix-tproxy 可自动校正。")
      check("acc_firewall.ini tproxy_ip 符合后端标准值", false, "warning")
    end
  end

  -- Legacy only: tproxy_ip != LAN IP causes an exit-255 crash loop
  if not (resp.firewall_ini and resp.firewall_ini.exists)
     and resp.core_config.exists and pid_mode == "tproxy"
     and not resp.core_config.tproxy_ip_ok then
    issue("error", "旧版引擎: tproxy_ip 与 LAN IP 不一致会让 web 子进程以 255 退出。运行 leigod-fw4.sh fix-tproxy 修复。")
  end

  luci.http.prepare_content("application/json")
  luci.http.write_json(resp)
end

-- ============================================================
-- Plain-text diagnostic report for copy-paste bug analysis
-- ============================================================
function get_debug_report()
  local util = require "luci.util"
  local uci  = require "luci.model.uci".cursor()
  local fs   = require "nixio.fs"

  local lines = {}
  local function w(s) lines[#lines+1] = s end
  local function ok(b) return b and "PASS" or "FAIL" end
  local function yn(b) return b and "Yes" or "No" end

  local now = os.date("%Y-%m-%d %H:%M:%S")
  w("============================================================")
  w("  Leigod Accelerator Diagnostic Report")
  w("  Generated: " .. now)
  w("============================================================")
  w("")

  -- System
  local release = util.exec("cat /etc/openwrt_release 2>/dev/null | head -1"):gsub("\n","")
  w("--- System ---")
  w("  Firmware:    " .. (release ~= "" and release or "Unknown"))
  w("  Kernel:      " .. util.exec("uname -r"):gsub("\n",""))
  w("  Arch:        " .. util.exec("uname -m"):gsub("\n",""))
  w("  Uptime:      " .. util.exec("uptime"):gsub("\n",""))
  w("  LAN IP:      " .. (uci:get("network","lan","ipaddr") or "unknown"))
  w("  Firewall:    " .. (fs.access("/usr/sbin/fw4") and "nftables (fw4)" or "iptables (fw3)"))

  -- Process
  local ps_raw = (util.exec("ps ww | grep acc-gw | grep -v grep 2>/dev/null"):match("[^\n]+") or "")
  local running = ps_raw ~= ""
  w("")
  w("--- Process ---")
  w("  Running:     " .. yn(running))
  if running then
    w("  Cmdline:     " .. ps_raw:gsub("%s+"," "))
    local pm = ps_raw:match("%-m (%S+)") or "not detected"
    w("  Mode:        " .. pm)
    local pid = ps_raw:match("^(%d+)") or "N/A"
    w("  PID:         " .. pid)
  end
  -- Port 5588 via /proc/net/tcp (no `ss` on iStoreOS 25.12)
  local function port_listen_rep(port)
    local hex = string.format("%04X", port)
    local f, line
    for _, p in ipairs({ "/proc/net/tcp", "/proc/net/tcp6" }) do
      f = io.open(p, "r")
      if f then
        for line in f:lines() do
          local addr, st = line:match("^%s*%d+:%s*(%S+)%s+%S+%s+(%S+)")
          if st == "0A" and addr and #addr >= #hex and addr:sub(-#hex) == hex then
            f:close()
            return true
          end
        end
        f:close()
      end
    end
    return false
  end
  w("  Port 5588:   " .. yn(port_listen_rep(5588)))

  -- Init script
  local init_exists = fs.access("/etc/init.d/acc")
  w("")
  w("--- Init Script /etc/init.d/acc ---")
  w("  Exists:      " .. yn(init_exists))
  if init_exists then
    local args_line = "N/A"
    for line in io.lines("/etc/init.d/acc") do
      if line:match("^%s*args=") then args_line = line:gsub("^%s*",""):gsub("%s*$",""); break end
    end
    w("  Args:        " .. args_line)
    local has_short = args_line:match("%-m tun") or args_line:match("%-m tproxy")
                    or args_line:find("-m ${mode}", 1, true)
    w("  Short fmt:   " .. yn(has_short ~= nil))
    local has_port = args_line:match("%-p %d+")
    w("  Has port:    " .. yn(has_port ~= nil))
  end

  -- Core config
  local conf_exists = fs.access("/tmp/acc/acc_core_conf.json")
  w("")
  w("--- Core Config /tmp/acc/acc_core_conf.json ---")
  w("  Exists:      " .. yn(conf_exists))
  if conf_exists then
    local conf_raw = ""
    for line in io.lines("/tmp/acc/acc_core_conf.json") do conf_raw = conf_raw .. line end
    local tproxy_ip = conf_raw:match('"tproxy_ip":"([^"]*)"') or "not found"
    local lan_ip = uci:get("network","lan","ipaddr") or ""
    -- New layout: the INI sentinel is authoritative; legacy: LAN IP
    local ini_ip = ""
    if fs.access("/etc/config/acc_firewall.ini") then
      for line in io.lines("/etc/config/acc_firewall.ini") do
        local v = line:match("^tproxy_ip=(.*)$")
        if v then ini_ip = v end
      end
    end
    if ini_ip ~= "" then
      w("  tproxy_ip:   " .. tproxy_ip .. " (INI: " .. ini_ip .. ") [" .. ok(tproxy_ip == ini_ip) .. "]")
    else
      w("  tproxy_ip:   " .. tproxy_ip .. " (LAN: " .. lan_ip .. ") [" .. ok(tproxy_ip == lan_ip) .. "]")
    end
    local acc_mode = conf_raw:match('"acc_mode":(%d+)') or "not found"
    local mode_name = acc_mode == "1" and "TUN" or (acc_mode == "2" and "TPROXY" or "UNKNOWN")
    w("  acc_mode:    " .. mode_name .. " (" .. acc_mode .. ")")
  end

  -- Network
  w("")
  w("--- Network & Firewall ---")
  local tun = util.exec("ip link show 2>/dev/null | grep -o 'tun[0-9]*'"):gsub("\n"," ")
  w("  TUN ifaces:  " .. (tun ~= "" and tun or "none"))
  local fw_rule = util.exec("uci show firewall 2>/dev/null | grep -c 5588"):gsub("\n","")
  w("  FW rule 5588:" .. (tonumber(fw_rule) > 0 and " Yes" or " No"))
  w("  Hotplug:     " .. yn(fs.access("/etc/hotplug.d/firewall/99-leigodacc-restart")))
  local turn_ok = (tonumber((util.exec("ping -c 1 -W 2 route-turn.xxghh.biz 2>/dev/null | grep -c 'bytes from'") or "0"):match("%d+")) or 0) > 0
  w("  TURN relay:  " .. ok(turn_ok) .. " (route-turn.xxghh.biz)")
  local api_code = util.exec("curl -sLo /dev/null -w '%{http_code}' --connect-timeout 3 https://webapi.leigod.com 2>/dev/null"):gsub("%s+","")
  w("  API endpoint: HTTP " .. api_code .. " [" .. ok(api_code:match("^[23]%d%d$") ~= nil) .. "]")

  -- GAMEACC
  local gameacc = util.exec("iptables -L GAMEACC -n 2>/dev/null | wc -l"):gsub("%s+","")
  w("  GAMEACC rules: " .. (tonumber(gameacc) > 2 and gameacc .. " lines" or "MISSING"))

  -- Packages
  w("")
  w("--- Critical Packages ---")
  local function pkg_ok_lua(pkg)
    local alt = (pkg == "libpcap") and "libpcap1" or ((pkg == "libpcap1") and "libpcap" or pkg)
    for _, cand in ipairs({ pkg, alt }) do
      if util.exec("apk info -e '" .. cand .. "' >/dev/null 2>&1 && echo yes || echo no"):match("yes") then
        return true
      end
      if util.exec("opkg list-installed 2>/dev/null | grep -q '^" .. cand .. " ' && echo yes || echo no"):match("yes") then
        return true
      end
    end
    return false
  end
  for _, pkg in ipairs({"iptables-nft","kmod-nft-nat","kmod-nft-tproxy","kmod-tun","tc-full","conntrack","libpcap1","luci-compat","luci-lua-runtime"}) do
    local inst = pkg_ok_lua(pkg)
    w("  " .. pkg .. ": " .. string.rep(" ", 20 - #pkg) .. yn(inst))
  end

  -- Devices
  w("")
  w("--- Device Acceleration State ---")
  for _, cat in ipairs({"Phone","PC","Game","Unknown"}) do
    local state = uci:get("accelerator", cat, "state") or "0"
    local text = state == "1" and "Accelerating" or (state == "2" and "Idle" or (state == "3" and "Paused" or "None"))
    w("  " .. cat .. ": " .. string.rep(" ", 10 - #cat) .. text)
  end

  -- Auto-pause
  w("")
  w("--- Auto-Pause ---")
  w("  Script:      " .. yn(fs.access("/usr/sbin/leigod-auto-pause.sh")))
  local token_ok = false
  local token_masked = "(not set)"
  local manual_disable = false
  if fs.access("/etc/leigod-auto-pause.conf") then
    for line in io.lines("/etc/leigod-auto-pause.conf") do
      local token_val = line:match("ACCOUNT_TOKEN='(.*)'")
      if token_val and token_val ~= "" and not token_ok then
        token_ok = true
        token_masked = #token_val > 12 and (token_val:sub(1,8) .. "..." .. token_val:sub(-4)) or string.rep("*",#token_val)
      end
      local md = line:match("^MANUAL_DISABLE=(%d+)")
      if md == "1" then manual_disable = true end
    end
  end
  w("  Token:       " .. token_masked .. " [" .. ok(token_ok) .. "]")
  if manual_disable then
    w("  AwayMode:    已启用 (自动暂停禁用)")
  end
  local cron_ok = false
  if fs.access("/etc/crontabs/root") then
    for line in io.lines("/etc/crontabs/root") do
      if line:match("leigod%-auto%-pause") then cron_ok = true; break end
    end
  end
  w("  Cron:        " .. yn(cron_ok))

  -- Error logs
  w("")
  w("--- acc-gw Internal Error Logs ---")
  local log_dir = "/tmp/acc/log/"
  local found_errors = false
  if fs.access(log_dir) then
    for _, lf in ipairs({"acc_daemon.log","acc_web.log","acc_acc.log"}) do
      local path = log_dir .. lf
      if fs.access(path) then
        -- Only real ERROR/WARN lines: "child process exit ... INFO" is routine
        local content = util.exec("tail -n 200 " .. path ..
          " 2>/dev/null | grep -E ' (ERROR|WARN|FATAL) ' | grep -v -E 'acc_objs is empty|delete iptables rule failed|delete rule failed|unknow acc mode|acceleration is empty|log report switch failed|router_log_report_config' | tail -5") or ""
        if content ~= "" and content ~= "\n" then
          found_errors = true
          w("  [" .. lf .. "]")
          for line in content:gmatch("[^\n]+") do
            w("    " .. line)
          end
        end
      end
    end
  end
  if not found_errors then w("  (no errors found)") end

  -- System logs (recent)
  w("")
  w("--- Recent System Logs (logread) ---")
  local sys_logs = util.exec("logread -l 20 2>/dev/null | grep -iE 'leigod|acc-gw|auto.pause' | tail -5") or ""
  if sys_logs ~= "" and sys_logs ~= "\n" then
    for line in sys_logs:gmatch("[^\n]+") do w("  " .. line) end
  else
    w("  (no matching log entries)")
  end

  w("")
  w("============================================================")
  w("  Report complete. Copy this text to share for bug analysis.")
  w("============================================================")

  luci.http.prepare_content("text/plain; charset=utf-8")
  luci.http.write(table.concat(lines, "\n"))
end

-- ============================================================
-- One-click token save — called by bookmarklet from leigod.com
-- Accepts POST {token: "..."} and writes to auto-pause config
-- ============================================================
function save_token()
  local util = require "luci.util"
  local fs   = require "nixio.fs"

  -- Support both POST JSON and GET ?token=...
  local token = nil
  if luci.http.getenv("REQUEST_METHOD") == "POST" then
    local body = luci.http.content() or ""
    token = body:match('"token":"([^"]*)"') or body:match("token=([^&]+)")
  end
  if not token then
    token = luci.http.formvalue("token")
  end

  if not token or #token < 10 then
    luci.http.status(400, "Bad Request")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "无效的 token" })
    return
  end

  token = token:gsub("[^a-zA-Z0-9_-]", "")  -- sanitize

  local conf_file = "/etc/leigod-auto-pause.conf"
  local lines = {}
  local has_user, has_pwd = false, false

  -- Preserve existing USERNAME/PASSWORD_MD5 if present
  if fs.access(conf_file) then
    for line in io.lines(conf_file) do
      if line:match("^USERNAME=") then has_user = true; lines[#lines+1] = line
      elseif line:match("^PASSWORD_MD5=") then has_pwd = true; lines[#lines+1] = line
      elseif not line:match("^ACCOUNT_TOKEN=") and not line:match("^#") and line ~= "" then
        lines[#lines+1] = line
      elseif line:match("^#") then
        lines[#lines+1] = line
      end
    end
  end

  -- Rewrite config with new token
  local file = io.open(conf_file, "w")
  if not file then
    luci.http.status(500, "Internal Server Error")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "ERROR", message = "无法写入配置文件" })
    return
  end

  local wrote_token = false
  for _, line in ipairs(lines) do
    file:write(line .. "\n")
    -- Insert token after USERNAME/PASSWORD_MD5 lines (or at top if none)
    if not wrote_token and (line:match("^PASSWORD_MD5=") or (not has_user and line:match("^IDLE_"))) then
      file:write(string.format("ACCOUNT_TOKEN='%s'\n", token))
      wrote_token = true
    end
  end
  if not wrote_token then
    file:write(string.format("ACCOUNT_TOKEN='%s'\n", token))
    -- Ensure default settings exist
    if not has_user then
      file:write("IDLE_CHECKS_BEFORE_PAUSE=3\nAPI_TIMEOUT=10\nAPI_ENDPOINT=\"https://webapi.leigod.com\"\nNOTIFY_ON_PAUSE=1\nMANUAL_DISABLE=0\n")
    end
  end
  file:close()
  util.exec(string.format("chmod 600 %s", conf_file))

  -- For bookmarklet (GET) return HTML; for manual save (POST JSON) return JSON
  if luci.http.getenv("HTTP_CONTENT_TYPE") and luci.http.getenv("HTTP_CONTENT_TYPE"):match("application/json") then
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "OK", message = "Token 已保存，下次检测时生效" })
  elseif luci.http.formvalue("token") and luci.http.getenv("REQUEST_METHOD"):upper() ~= "POST" then
    luci.http.prepare_content("text/html; charset=utf-8")
    luci.http.write([[
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Token 已保存</title>
<style>body{font-family:sans-serif;text-align:center;padding:40px 20px;background:#f5f5f5}
.msg{font-size:24px;color:#080;font-weight:bold}.sub{color:#666;margin-top:8px}
</style></head><body><div class="msg">Token 已保存到路由器!</div>
<div class="sub">3秒后自动关闭窗口...</div>
<script>setTimeout(function(){window.close()},3000)</script></body></html>]])
  else
    luci.http.prepare_content("application/json")
    luci.http.write_json({ result = "OK", message = "Token 已保存，下次检测时生效" })
  end
end

LUAEOF

        # model/cbi/leigod/service.lua
        mkdir -p "$luci_src/model/cbi/leigod"
        cat > "$luci_src/model/cbi/leigod/service.lua" << 'LUAEOF'
-- fw4 adapted: Leigod Service configuration
local uci  = require "luci.model.uci".cursor()
local fs   = require "nixio.fs"

-- Detect firewall type
local fw_type = "iptables (fw3)"
local fw_recommend = ""
if fs.access("/usr/sbin/fw4") or fs.access("/usr/sbin/nft") then
    fw_type = "nftables (fw4)"
    fw_recommend = "检测到 fw4: 实际加速参数保存在 /etc/config/acc_firewall.ini (backend/mode/tproxy_ip)。如加速失败请运行诊断。"
end

m = Map("accelerator")
m.title = "雷神加速器配置"
m.description = "控制加速器设置。注意: v1.2.2.x 引擎的设备加速由手机 APP 通过 5588 接口下发，本页的 UCI 开关可能不生效；切换 TUN/TPROXY 请用管理器菜单 5 或直接修改 acc_firewall.ini 的 mode 字段。"

-- Firewall info (read-only, fw4 adapted)
s = m:section(TypedSection, "system")
s.addremove = false
s.anonymous = true

fw_info = s:option(DummyValue, "_fw_info", "防火墙类型")
fw_info.value = fw_type
fw_info.rmempty = false
if fw_recommend ~= "" then
    fw_info.description = fw_recommend
end

enable = s:option(Flag, "enabled", "启用加速")
enable.rmempty = false
enable.default = 0

tun = s:option(Flag, "tun", "TUN 隧道模式")
tun.rmempty = false
tun.default = 0
tun.description = "切换为 TUN 隧道模式可避免与其他代理插件冲突。注意: 部分 acc-gw 版本仅支持 TPROXY，如加速失败请运行诊断。"

schedule_enabled = s:option(Flag, "schedule_enabled", "定时暂停")
schedule_enabled.rmempty = false
schedule_enabled.default = 0
schedule_enabled.description = "为雷神加速器启用定时暂停"

pause_time = s:option(ListValue, "pause_time", "暂停时间")
pause_time:depends("schedule_enabled", 1)
for i = 0, 23 do
    pause_time:value(string.format("%02d:00", i), string.format("%02d:00", i))
end
pause_time.rmempty = true

username = s:option(Value, "username", "手机号")
username:depends("schedule_enabled", 1)
username.rmempty = true

password = s:option(Value, "password", "雷神密码")
password:depends("schedule_enabled", 1)
password.password = true
password.rmempty = true

m:section(SimpleSection).template = "leigod/service"

return m

LUAEOF

        # model/cbi/leigod/notice.lua (fw4 adapted)
        cat > "$luci_src/model/cbi/leigod/notice.lua" << 'LUAEOF'
-- fw4 adapted: Leigod Notice page
local uci = require "luci.model.uci".cursor()
local fs  = require "nixio.fs"

m                                 = Map("accelerator")
m.title                           = "雷神公告"
m.description                     = "雷神加速器使用须知"

-- fw4 compatibility note
if fs.access("/usr/sbin/fw4") or fs.access("/usr/sbin/nft") then
    m.description = m.description .. "\n" ..
        "防火墙: nftables (fw4) — 通过 iptables-nft 翻译层兼容。" .. " " ..
        "请确保 acc_core_conf.json 中 tproxy_ip 为路由器 LAN IP。"
end

m:section(SimpleSection).template = "leigod/notice"

return m

LUAEOF

        # view/leigod/service.htm
        mkdir -p "$luci_src/view/leigod"
        cat > "$luci_src/view/leigod/service.htm" << 'HTMEOF'
<!-- fw4 adapted: acc service state + firewall info -->
<fieldset class="cbi-section">
  <legend>加速状态</legend>
  <table class="cbi-section-table" id="acc_catalog_state_table">
    <tr class="cbi-section-table-title">
      <th class="cbi-section-table-cell">设备类型</th>
      <th class="cbi-section-table-cell">加速状态</th>
    </tr>
  </table>
</fieldset>

<script type="text/javascript">//<![CDATA[
    XHR.poll(5, '<%=url('admin/services/acc/status')%>', null, function(x, st) {
      var catalog_table = document.getElementById("acc_catalog_state_table");
      if (st && catalog_table) {
        while(catalog_table.rows.length > 1)
          catalog_table.deleteRow(1);
        var status_map = st["state"];
        for (var typ in status_map) {
          var tr = catalog_table.insertRow(-1);
          tr.insertCell(-1).innerHTML = typ;
          tr.insertCell(-1).innerHTML = status_map[typ];
        }
        var tr = catalog_table.insertRow(-1);
        tr.insertCell(-1).innerHTML = '<em>防火墙</em>';
        tr.insertCell(-1).innerHTML = '<em>' + (st["firewall"] || "unknown") + '</em>';
      }
    });
//]]></script>

HTMEOF

        # model/cbi/leigod/autopause.lua
        cat > "$luci_src/model/cbi/leigod/autopause.lua" << 'LUAEOF'
-- fw4 adapted: Auto-Pause configuration page
local uci  = require "luci.model.uci".cursor()
local fs   = require "nixio.fs"
local util = require "luci.util"

local AP_CONF = "/etc/leigod-auto-pause.conf"

-- Read existing config
local existing_token = ""
local existing_idle = 3
local existing_interval = 2
local existing_timeout = 10
local existing_notify = 1
local existing_manual = 0
if fs.access(AP_CONF) then
    for line in io.lines(AP_CONF) do
        local tv = line:match("^ACCOUNT_TOKEN='(.*)'$")
        if tv then existing_token = tv end
        local idc = line:match("^IDLE_CHECKS_BEFORE_PAUSE=(%d+)")
        if idc then existing_idle = tonumber(idc) end
        local inv = line:match("^IDLE_CHECK_INTERVAL=(%d+)")
        if inv then existing_interval = tonumber(inv) end
        local tmo = line:match("^API_TIMEOUT=(%d+)")
        if tmo then existing_timeout = tonumber(tmo) end
        local nfy = line:match("^NOTIFY_ON_PAUSE=(%d+)")
        if nfy then existing_notify = tonumber(nfy) end
        local man = line:match("^MANUAL_DISABLE=(%d+)")
        if man then existing_manual = tonumber(man) end
    end
end

m = Map("accelerator", "自动暂停配置",
    "检测到所有设备停止加速后，自动暂停时长计费。Token 通过书签一键获取。")

-- Section: Settings
s = m:section(TypedSection, "system", "设置")
s.addremove = false
s.anonymous = true

-- Account token
token = s:option(Value, "_ap_token", "账号令牌 (Token)")
token.rmempty = false
token.password = true
if existing_token and existing_token ~= "" then
    local masked
    if #existing_token > 12 then
        masked = existing_token:sub(1, 8) .. string.rep("*", math.min(8, #existing_token - 12)) .. existing_token:sub(-4)
    else
        masked = string.rep("*", #existing_token)
    end
    token.value = masked
    token.placeholder = "(已配置)"
end
token.description = "将下方运行状态区的书签拖到浏览器书签栏，登录 leigod.com 后点击即可自动获取"

-- Idle check interval (cron frequency)
interval = s:option(Value, "_ap_interval", "检测间隔 (分钟)")
interval.datatype = "range(1,30)"
interval.default = existing_interval
interval.value = existing_interval
interval.description = "每 N 分钟检测一次设备是否空闲。修改后自动更新定时任务"

-- Idle checks before pause
idle = s:option(Value, "_ap_idle", "空闲检测次数")
idle.datatype = "range(1,30)"
idle.default = existing_idle
idle.value = existing_idle
idle.description = string.format("连续检测到空闲 N 次后触发暂停 (总空闲 = %d分钟 × %d次 = %d分钟)",
    existing_interval, existing_idle, existing_interval * existing_idle)

-- API timeout
timeout = s:option(Value, "_ap_timeout", "API 超时 (秒)")
timeout.datatype = "range(5,30)"
timeout.default = existing_timeout
timeout.value = existing_timeout
timeout.description = "调用雷神 API 的连接超时时间"

-- Notify on pause
notify = s:option(Flag, "_ap_notify", "暂停时通知")
notify.default = existing_notify
notify.value = existing_notify
notify.description = "暂停成功时打印通知到系统日志"

-- Manual disable (away mode)
manual = s:option(Flag, "_ap_manual", "离家模式 (禁止自动暂停)")
manual.default = existing_manual
manual.value = existing_manual
manual.description = "离家时开启：禁止自动暂停时长计费。用于异地 PC 客户端加速场景，防止路由器误判无设备而暂停时长"

-- Cron enable/disable
cron_enable = s:option(Button, "_ap_toggle_cron")
if fs.access("/etc/crontabs/root") then
    local has_cron = false
    for line in io.lines("/etc/crontabs/root") do
        if line:match("leigod%-auto%-pause") then has_cron = true; break end
    end
    if has_cron then
        cron_enable.title = "禁用自动暂停定时任务"
        cron_enable.inputstyle = "reset"
    else
        cron_enable.title = "启用自动暂停定时任务"
        cron_enable.inputstyle = "apply"
    end
else
    cron_enable.title = "启用自动暂停定时任务"
    cron_enable.inputstyle = "apply"
end
cron_enable.description = "启用或禁用定时检测任务"

-- Manual trigger
trigger = s:option(Button, "_ap_trigger", "立即暂停")
trigger.inputstyle = "apply"
trigger.description = "立即调用暂停 API (用于测试)"

-- Section: Status (filled by JavaScript polling)
s2 = m:section(SimpleSection, "运行状态")
s2.template = "leigod/autopause"

-- Form write handler
-- Scan all submitted form values for a Flag option by name suffix.
-- TypedSection uses internal CBI IDs (e.g. cfg0a1234), not the type name,
-- so we can't hardcode the full form field name. Scan by suffix instead.
-- luci.http.formvalues() (no args) returns {key = last_value, ...}, so
-- for Flag (hidden=0 + checkbox=1), checked → value "1", unchecked → "0".
local function find_flag(option_name, default)
    for k, v in pairs(luci.http.formvalues()) do
        if type(k) == "string" and k:match(option_name .. "$") then
            return v == "1" and "1" or "0"
        end
    end
    return default
end

m.on_commit = function(self)
    local token_val = luci.http.formvalue("cbid.accelerator.system._ap_token") or ""
    local interval_val = luci.http.formvalue("cbid.accelerator.system._ap_interval") or ""
    local idle_val = luci.http.formvalue("cbid.accelerator.system._ap_idle") or "3"
    local timeout_val = luci.http.formvalue("cbid.accelerator.system._ap_timeout") or "10"
    local notify_val = find_flag("_ap_notify", "1")
    -- manual_disable is a real UCI-backed Flag; CBI writes it to
    -- /etc/config/accelerator before on_commit fires. Read the raw file
    -- to avoid UCI cursor caching and form-field name mismatch.
    local manual_val = "0"
    local uf = io.open("/etc/config/accelerator")
    if uf then
        for line in uf:lines() do
            local v = line:match("^%s*option manual_disable%s+'([01])'")
            if v then manual_val = v; break end
        end
        uf:close()
    end

    local file = io.open(AP_CONF, "w")
    if not file then return end

    file:write("# LeigodAcc Auto-Pause configuration\n")

    -- Token
    if token_val ~= "" and not token_val:match("%*%*%*%*%*%*") then
        token_val = token_val:gsub("[^a-zA-Z0-9_-]", "")  -- sanitize
        file:write(string.format("ACCOUNT_TOKEN='%s'\n", token_val))
    elseif existing_token ~= "" then
        file:write(string.format("ACCOUNT_TOKEN='%s'\n", existing_token))
    end

    -- Idle settings
    local iv = tonumber(interval_val)
    if not iv or iv < 1 then iv = existing_interval end
    file:write(string.format("IDLE_CHECK_INTERVAL=%d\n", iv))

    local ic = tonumber(idle_val)
    if not ic or ic < 1 then ic = existing_idle end
    file:write(string.format("IDLE_CHECKS_BEFORE_PAUSE=%d\n", ic))

    file:write(string.format("API_TIMEOUT=%d\n", tonumber(timeout_val) or 10))
    file:write(string.format("API_ENDPOINT=\"https://webapi.leigod.com\"\n"))
    file:write(string.format("NOTIFY_ON_PAUSE=%d\n", tonumber(notify_val) or 1))
    file:write(string.format("MANUAL_DISABLE=%d\n", tonumber(manual_val) or 0))
    file:close()

    util.exec(string.format("chmod 600 %s", AP_CONF))

    -- Update cron interval
    local old_cron = "*/2 * * * *"
    local new_cron = string.format("*/%d * * * *", iv)
    util.exec(string.format("sed -i 's|%s %s|%s %s|' /etc/crontabs/root 2>/dev/null",
        old_cron:gsub("%*", "\\*"), "/usr/sbin/leigod-auto-pause.sh",
        new_cron, "/usr/sbin/leigod-auto-pause.sh"))
    util.exec("/etc/init.d/cron restart 2>/dev/null")
end

return m

LUAEOF

        # view/leigod/autopause.htm
        cat > "$luci_src/view/leigod/autopause.htm" << 'HTMEOF'
<!-- Auto-Pause status display (fw4 adapted) -->
<fieldset class="cbi-section">
  <legend>自动暂停运行状态</legend>
  <table class="cbi-section-table" id="ap_status_table">
    <tr class="cbi-section-table-title">
      <th class="cbi-section-table-cell">项目</th>
      <th class="cbi-section-table-cell">状态</th>
    </tr>
  </table>
  <div id="ap_actions" style="margin-top:8px;"></div>
</fieldset>

<fieldset class="cbi-section" style="margin-top:12px">
  <legend>一键获取 Token</legend>

  <div style="padding:8px 0">
    <p style="margin:0 0 6px 0"><b>方法一 (推荐)：</b>将下方按钮拖到浏览器书签栏。然后打开 <a href="https://www.leigod.com" target="_blank">leigod.com</a> 并登录，点击书签即可自动将 Token 发送到路由器。</p>

    <div id="bm_container" style="margin:8px 0;padding:8px 12px;background:#f0f0f0;border-radius:4px;display:inline-block">
      <span style="font-size:13px;color:#666;margin-right:8px">📌 拖我到书签栏 →</span>
      <a id="bm_link" href="" onclick="return false" class="cbi-button cbi-button-action" style="text-decoration:none;cursor:grab">🔑 获取雷神Token</a>
    </div>
    <small style="color:#888">点击书签后页面会弹出提示 "Token已发送到路由器!"</small>

    <hr style="margin:12px 0">

    <p style="margin:0 0 6px 0"><b>方法二 (手动)：</b>从 <a href="https://www.leigod.com" target="_blank">leigod.com</a> 登录后，F12 → Console 执行以下代码，然后粘贴到这里：</p>
    <code style="display:block;padding:4px 8px;background:#1e1e1e;color:#0c0;margin:4px 0 8px">JSON.parse(localStorage.getItem('account_token')).account_token</code>

    <div style="display:flex;align-items:center;gap:8px">
      <input type="text" id="ap_quick_token" placeholder="粘贴 Token 到这里..." style="flex:1;padding:4px 8px">
      <button class="cbi-button cbi-button-apply" onclick="ap_save_token()" style="white-space:nowrap">保存</button>
    </div>
    <div id="ap_save_msg" style="margin-top:4px;font-size:12px;display:none"></div>
  </div>
</fieldset>

<script type="text/javascript">//<![CDATA[
    // Generate bookmarklet with router URL
    (function() {
      var saveUrl = '<%=luci.dispatcher.build_url("admin", "services", "acc", "save_token")%>';
      var absUrl = window.location.origin + saveUrl;
      var bmJs = "(function(){try{" +
        "var t=JSON.parse(localStorage.getItem('account_token')).account_token;" +
        "window.open('" + absUrl + "?token='+encodeURIComponent(t),'_blank','width=450,height=250');" +
        "}catch(e){alert('请先在 leigod.com 登录!\\n错误:'+e.message);}})();";
      document.getElementById('bm_link').href = 'javascript:' + encodeURIComponent(bmJs);
    })();

    function ap_update_table(data) {
      var table = document.getElementById("ap_status_table");
      if (!table || !data) return;
      while (table.rows.length > 1) table.deleteRow(1);

      var items = [
        ["脚本", data.script_installed ? "&#x2705; 已安装" : "&#x26A0; 未安装"],
        ["令牌", data.token_configured ? "&#x2705; " + data.token_masked : "&#x26A0; 未配置"],
        ["离家模式", data.manual_disable == "1" ? "&#x1F3E0; 已启用 (自动暂停禁用)" : "自动模式"],
        ["定时任务", data.cron_enabled ? "&#x2705; 已启用 (每2分钟)" : "&#x26A0; 已禁用"],
        ["空闲计数", data.idle_count + " / " + data.idle_checks],
        ["上次暂停", data.last_pause_text],
        ["冷却中", data.in_cooldown ? "冷却中" : "就绪"]
      ];

      for (var i = 0; i < items.length; i++) {
        var tr = table.insertRow(-1);
        tr.insertCell(-1).innerHTML = '<strong>' + items[i][0] + '</strong>';
        tr.insertCell(-1).innerHTML = items[i][1];
      }

      var cron_btn = document.getElementById("cbid.accelerator.system._ap_toggle_cron");
      if (cron_btn) {
        cron_btn.value = data.cron_enabled ? "禁用自动暂停定时任务" : "启用自动暂停定时任务";
        cron_btn.className = data.cron_enabled ? "cbi-button cbi-button-reset" : "cbi-button cbi-button-apply";
      }
    }

    function ap_save_token() {
      var token = document.getElementById('ap_quick_token').value.trim();
      var msg = document.getElementById('ap_save_msg');
      if (!token || token.length < 10) {
        msg.style.display = 'block'; msg.style.color = '#c00';
        msg.textContent = 'Token 无效，请粘贴完整 token'; return;
      }

      var x = new XMLHttpRequest();
      x.open('POST', '<%=luci.dispatcher.build_url("admin", "services", "acc", "save_token")%>', true);
      x.setRequestHeader('Content-Type', 'application/json');
      x.onload = function() {
        var r = JSON.parse(x.responseText || '{}');
        msg.style.display = 'block';
        if (r.result === 'OK') {
          msg.style.color = '#080'; msg.textContent = 'Token 已保存!';
          document.getElementById('ap_quick_token').value = '';
          ap_poll(); // refresh status
        } else {
          msg.style.color = '#c00'; msg.textContent = '保存失败: ' + (r.message || x.status);
        }
      };
      x.onerror = function() {
        msg.style.display = 'block'; msg.style.color = '#c00';
        msg.textContent = '网络错误，无法连接路由器';
      };
      x.send(JSON.stringify({token: token}));
    }

    function ap_toggle_cron() {
      var cron_btn = document.getElementById("cbid.accelerator.system._ap_toggle_cron");
      var enable = cron_btn && cron_btn.value.indexOf("启用") >= 0 ? 1 : 0;
      XHR.get('<%=luci.dispatcher.build_url("admin", "services", "acc", "ap_toggle")%>' + '?enable=' + (enable ? '1' : '0'), null, function(x) {
        setTimeout(function() { ap_poll(); }, 500);
      });
    }

    function ap_trigger_pause() {
      if (!confirm("确认手动暂停? 将调用雷神 API。")) return;
      XHR.get('<%=luci.dispatcher.build_url("admin", "services", "acc", "ap_trigger")%>', null, function(x) {
        try {
          var resp = JSON.parse(x.responseText);
          alert(resp.message || resp.result);
        } catch(e) {
          alert("请求失败: " + (x.statusText || "网络错误"));
        }
        setTimeout(function() { ap_poll(); }, 1000);
      });
    }

    function ap_poll() {
      XHR.get('<%=luci.dispatcher.build_url("admin", "services", "acc", "ap_status")%>', null, function(x, st) {
        try {
          var data = JSON.parse(x.responseText);
          ap_update_table(data);
        } catch(e) { /* silently retry on next poll */ }
      });
    }

    document.addEventListener("DOMContentLoaded", function() {
      var trigger_btn = document.getElementById("cbid.accelerator.system._ap_trigger");
      if (trigger_btn) {
        trigger_btn.type = "button";
        trigger_btn.onclick = function(e) { e.preventDefault(); ap_trigger_pause(); };
      }
      var cron_btn = document.getElementById("cbid.accelerator.system._ap_toggle_cron");
      if (cron_btn) {
        cron_btn.type = "button";
        cron_btn.onclick = function(e) { e.preventDefault(); ap_toggle_cron(); };
      }
    });

    // Away mode checkbox: event delegation (CBI renders checkboxes after DOMContentLoaded)
    document.addEventListener('change', function(e) {
      if (e.target.name && e.target.name.match('_ap_manual$')) {
        XHR.get('<%=luci.dispatcher.build_url("admin", "services", "acc", "ap_save")%>?manual_disable=' + (e.target.checked ? '1' : '0'), null, function() {
          ap_poll();
        });
      }
    });

    ap_poll();
    setInterval(ap_poll, 10000);
//]]></script>

HTMEOF

        # Non-patched LuCI files (deleted by official installer's uninstall step)
        cat > "$luci_src/model/cbi/leigod/device.lua" << 'LUAEOF'
local uci     = require "luci.model.uci".cursor()
local util    = require "luci.util"
local fs      = require "nixio.fs"
local pairs   = pairs
local io      = io

-- config
m             = Map("accelerator")
m.title       = "雷神设备配置"
m.description = "管理加速设备"

-- get neigh info
neigh         = m:section(NamedSection, "base", "system", "监听接口")
neigh_tab     = neigh:option(ListValue, "neigh", "加速接口")
local sys_dir = util.exec("ls /sys/class/net")
if sys_dir ~= nil then
  neigh_tab:value("br-lan")
  for ifc in string.gmatch(sys_dir, "[^\n]+") do
    neigh_tab:value(ifc)
  end
end

-- range all device
device = m:section(NamedSection, "device", "hardware", "设备信息")
device:tab("none_catalog", "未分类")
device:tab("phone_catalog", "手机")
device:tab("pc_catalog", "电脑")
device:tab("game_catalog", "游戏主机")
device:tab("vr_catalog", "VR设备")
device:tab("unknown_catalog", "未知设备")


local dhcp_map = {}
-- check dhcp file
if fs.access("/tmp/dhcp.leases") then
  for line in io.lines("/tmp/dhcp.leases") do
    -- check if read empty line
    if line == "" then
      break
    end
    -- split line
    local valueSl = string.gmatch(line, "[^ ]+")
    -- read time
    valueSl()
    -- read mac
    local mac = valueSl() or ""
    -- get ip
    local ip = valueSl() or ""
    -- get host name
    local hostname = valueSl() or ""
    -- skip malformed entries
    if not (mac == "" or mac:match("^%*")) then
      -- key
      local key = string.gsub(mac, ":", "")
      -- store key
      dhcp_map[key] = {
        ["key"] = key,
        ["mac"] = mac,
        ["ip"] = ip,
        ["name"] = hostname
      }
    end
  end
end

ifc = uci:get("accelerator", "base", "neigh")
if ifc == nil then
  ifc = "br-lan"
end

local arp_map = {}
-- check if arp exist
if fs.access("/proc/net/arp") then
  -- read all item from arp
  for line in io.lines("/proc/net/arp") do
    -- check if line is not exist
    if line == "" then
      break
    end
    -- split item
    local valueSl = string.gmatch(line, "[^ ]+")
    -- get ip
    local ip = valueSl()
    -- get type
    valueSl()
    -- get flag
    local flag = valueSl()
    -- get mac
    local mac = valueSl() or ""
    -- get mask
    valueSl()
    -- get device
    local dev = valueSl() or ""
    -- get key
    if not (mac == "" or mac:match("^%*")) then
      local key = string.gsub(mac, ":", "")
      -- check if device and flag state
      if dev == ifc and flag == "0x2" then
        -- get current name
        local name = mac
        if dhcp_map[key] ~= nil then
          name = dhcp_map[key].name or mac
          if name == "*" then name = mac end
        end
        arp_map[key] = {
          ["key"] = key,
          ["mac"] = mac,
          ["ip"] = ip,
          ["name"] = name
        }
      end
    end
  end
end

-- get device config
for key, item in pairs(arp_map) do
  local typ = uci:get("accelerator", "device", key)
  -- get device catalog from type
  local catalog = "none_catalog"
  -- default to unknown device
  if typ == nil then
    typ = 9
  else
    typ = tonumber(typ)
  end

  if typ == nil then
    catalog = "unknown_catalog"
  elseif typ >= 1 and typ <= 3 then
    catalog = "game_catalog"
  elseif typ >= 4 and typ <= 6 then
    catalog = "pc_catalog"
  elseif typ >= 7 and typ <= 8 then
    catalog = "phone_catalog"
  elseif typ >= 20 and typ <= 21 then
    catalog = "vr_catalog"
  else
    catalog = "unknown_catalog"
  end
  -- device type
  device_typ = device:taboption(catalog, ListValue, key, item.name)
  device_typ:value("0", "未设置")
  device_typ:value("1", "XBox")
  device_typ:value("2", "Switch")
  device_typ:value("3", "PlayStation")
  device_typ:value("4", "Steam Deck")
  device_typ:value("5", "Windows")
  device_typ:value("6", "MacBook")
  device_typ:value("7", "安卓手机")
  device_typ:value("8", "iPhone")
  device_typ:value("20", "Oculus")
  device_typ:value("21", "HTC Vive")
  device_typ:value("22", "Pico")
  device_typ:value("9", "未知")
end

-- set
device.write = function()
  util.exec("/etc/init.d/acc restart")
end

return m

LUAEOF

        cat > "$luci_src/model/cbi/leigod/app.lua" << 'LUAEOF'
require("luci.util")

mp = Map("accelerator")

mp:section(SimpleSection).template  = "leigod/app"

return mp

LUAEOF

        cat > "$luci_src/model/cbi/leigod/debug.lua" << 'LUAEOF'
require("luci.util")

mp = Map("accelerator")

mp:section(SimpleSection).template = "leigod/debug"

return mp

LUAEOF

        cat > "$luci_src/view/leigod/app.htm" << 'HTMEOF'
<fieldset class="cbi-section">
  <legend>雷神加速器 APP</legend>
  <p>下载 <b>雷神加速器</b> APP:</p>
  <p><a href="https://www.leigod.com" target="_blank">https://www.leigod.com</a></p>
  <p>绑定路由器: 打开 APP → 硬件加速 → 安装路由器插件</p>
</fieldset>

HTMEOF

        cat > "$luci_src/view/leigod/notice.htm" << 'HTMEOF'
<fieldset>
  <legend>声明</legend>
  此插件为 LEDE/QWRT 官方合作版插件, 需要配合雷神手机APP使用
  </p>
  <legend>更新信息</legend>
  <p>
    2024-8-1 <br>
    支持LEDE/QWRT性能优化 <br>
    2024-7-25 <br>
    支持非桥接模式下的旁路由 <br>
    2024-6-5 <br>
    扩充ipset容量, 以支持大容量代理ip库 <br>
    2024-1-22 <br>
    新增自动选择低延迟线路 <br>
    新增下载不限速(switch除外) <br>
    设备名为*时, 显示mac地址 <br>
    <hr/>
    2023-11-28 <br>
    新增对mips设备的支持 <br>
    新增对旁路由的支持 <br>
    解决翻译异常的问题 <br>
    设备管理页面可以显示未识别设备 <br>
  </p>
  <legend>安装依赖</legend>
  <p>
    插件运行需要借助一些依赖才能运行, 一般第三方固件默认已经集成了大部分的依赖, <br>
    如果使用的是openwrt官方的固件, 则需要确保依赖安装好了, 以下列出依赖包和注意事项 <br>
    <b>OpenWrt 25.12 / iStoreOS 25.12 (apk)</b>: libpcap1, iptables-nft, kmod-nft-nat, kmod-nft-tproxy, kmod-tun, tc-full, ipset <br>
    <b>OpenWrt 24.10 及更早 (opkg)</b>: libpcap, iptables, kmod-ipt-nat, iptables-mod-tproxy, kmod-ipt-tproxy, kmod-ipt-ipset, ipset <br>
    kmod-netem(非必须, 针对于一些icmp测速的游戏使用, 只影响界面显示, 实际游戏效果不影响) <br>
    tc-full(非必须, 同kmod-netem) <br>
    curl(谨慎更新, 某些三方固件升级curl, 会导致curl出现问题) <br>
  </p>
  <legend>LuCI 兼容层 (重要)</legend>
  <p>
    OpenWrt 25.12 起 LuCI 调度器改为 ucode, 本插件的网页界面为 Lua CBI, <br>
    必须安装 luci-compat 与 luci-lua-runtime 才能被加载, 缺失时菜单不会出现, <br>
    访问地址会提示 404 "No page is registered at ..." <br>
    安装命令: apk add luci-compat luci-lua-runtime <br>
  </p>
  <legend>网桥模式</legend>
  <p>
    加速插件无法探知当前插件应该使用什么模式,  <br>
    当前默认使用网桥作为流量转发的设备, <br>
    如果使用旁路由模式或者docker时, 此时默认设备不是网桥, <br>
    此时需要手动调整接口, <br>
    改变接口的地址在 设备管理->路由设备, 选择对应的设备 <br>
  </p>
  <legend>加速模式</legend>
    <p>
    当前雷神路由器支持两种加速模式, tproxy 和 tun <br>
    当前默认采用的是tproxy模式, 原因在于tproxy有更好的性能<br>
    tun模式暂时屏蔽, 后续luci会完善一键切换模式
    </p>
  <legend>使用说明</legend>
    <p>
    当前雷神加速插件是根据设备类型进行加速的, 也就是说, 如果加速了相应的类型后, 理论上只要连接该路由器的设备都将获得加速效果<br>
    当前支持的设备类型有以下几种:  <br>
    手机:  Android iPhone <br>
    电脑:  Windows MacOS SteamDeck <br>
    主机:  XBox Switch PlayStation <br>
    未识别: Others  <br>
    可以在设备管理中, 插件自己的设备是否被成功识别成对应的设备, 如果不是, 可以选择对应的设备, 这样设备就能成功加速了 <br>
    </p>
    <p>
    一些特殊的说明: <br>
    关于ios设备, 最好是在安装插件之前, 先忘记网络, 等安装完插件后, 再重新连接网络 <br>
    关于android设备, 需要关闭dhcpv6后, 手机重连网络, 以下给出一个 /etc/config/dhcp 的配置 <br>
    config dhcp 'lan'  <br>
    ... 此处是一些其他配置 <br>
    ra 'disable'  <br>
    dhcpv6 'disable' <br>
    list ra_flags 'none' <br>
    ... 此处是一些其他配置 <br>
    </p>
</fieldset>

HTMEOF

        # view/leigod/debug.htm — diagnostic page
        mkdir -p "$luci_src/view/leigod"
        cat > "$luci_src/view/leigod/debug.htm" << 'HTMEOF'
<!-- fw4 adapted: Diagnostic debug page -->
<fieldset class="cbi-section">
  <legend>诊断报告</legend>
  <div class="cbi-value" id="debug_status_bar" style="padding:6px 0">
    <div id="debug_status_text" style="font-weight:bold">加载中...</div>
  </div>
  <div id="debug_issues" style="margin-bottom:8px"></div>
  <div style="width:100%; background:#1e1e1e; border:1px solid #3c3c3c; border-radius:3px; overflow:auto; max-height:70vh">
    <pre id="debug_output" style="margin:0; padding:12px; font-family:'Courier New',monospace; font-size:13px; line-height:1.35; white-space:pre; color:#ccc; background:transparent; border:none">加载诊断数据...</pre>
  </div>
  <div class="cbi-page-actions" style="margin-top:12px">
    <button class="cbi-button cbi-button-apply" onclick="debug_refresh()">刷新</button>
    <button class="cbi-button cbi-button-action" onclick="debug_copy()">复制报告</button>
  </div>
</fieldset>

<script type="text/javascript">//<![CDATA[
var DEBUG_POLL_MS = 15000, _debug_data = null;

function debug_refresh() {
  var x = new XMLHttpRequest();
  x.onreadystatechange = function() {
    if (x.readyState !== 4 || x.status !== 200) return;
    try { _debug_data = JSON.parse(x.responseText); debug_render(_debug_data); }
    catch(e) { debug_show_err('解析失败: ' + e.message); }
  };
  x.open('GET', '<%=luci.dispatcher.build_url("admin", "services", "acc", "debug_status")%>', true);
  x.send();
}

function debug_render(data) {
  if (!data) { debug_show_err('无数据'); return; }
  var to = function(s) { return (s||'N/A').replace(/</g,'&lt;').replace(/>/g,'&gt;'); };
  var yn = function(b) { return b ? 'Yes' : 'No'; };
  var ok = function(b) { return b ? 'PASS' : 'FAIL'; };

  // Status bar
  var allClear = data.checks_total > 0 && data.checks_failed === 0 && data.checks_warn === 0;
  var hasErrors = data.checks_failed > 0, hasWarns = data.checks_warn > 0;
  var color = allClear ? '#080' : (hasErrors ? '#c00' : '#b85c00');
  var txt = allClear ? '全部通过 ('+data.checks_passed+'/'+data.checks_total+')'
    : data.checks_passed+'/'+data.checks_total+' 通过'+(hasErrors?', '+data.checks_failed+' 失败':'')+(hasWarns?', '+data.checks_warn+' 警告':'');
  document.getElementById('debug_status_text').innerHTML = '<span style="color:'+color+'">'+txt+'</span>';

  // Issues
  var issDiv = document.getElementById('debug_issues'); issDiv.innerHTML = '';
  if (data.issues && data.issues.length > 0) {
    for (var i = 0; i < data.issues.length; i++) {
      var iss = data.issues[i];
      var bg = iss.severity==='error'?'#ffe0e0':(iss.severity==='warning'?'#fff8e0':'#e0f0ff');
      var fg = iss.severity==='error'?'#c00':(iss.severity==='warning'?'#b85c00':'#036');
      issDiv.innerHTML += '<div style="padding:4px 8px;margin:2px 0;border-radius:2px;background:'+bg+';color:'+fg+';font-weight:bold;font-size:13px">'+(iss.severity==='error'?'✘ ':'⚠ ')+iss.message+'</div>';
    }
  }

  // === Build aligned text report ===
  var L = [];
  // Chinese-aware visual width for alignment
  var vl = function(s) { var w=0; for(var i=0;i<s.length;i++) w+=s.charCodeAt(i)>127?2:1; return w; };
  var pd = function(s,w) { var n=w-vl(s); return n>0?s+' '.repeat(n):s+' '; };
  var COL = 14; // label column width (Chinese chars)
  var rw = function(label, value) { L.push('  '+pd(label,COL)+' │ '+value); };
  var sec = function(title) { L.push(''); L.push('── '+title); };

  var now = new Date();
  L.push('═══════════════════════════════════════');
  L.push('  Leigod Accelerator 诊断报告');
  L.push('  '+now.toLocaleString());
  L.push('═══════════════════════════════════════');

  sec('系统信息');
  rw('固件',to(data.system.firmware)); rw('内核',to(data.system.kernel));
  rw('架构',to(data.system.arch)); rw('防火墙',to(data.system.firewall_type));
  rw('LAN IP',to(data.system.lan_ip)+' / '+to(data.system.lan_mask));
  rw('运行时间',to(data.system.uptime));

  sec('进程状态');
  rw('运行中',yn(data.process.running)); rw('PID',to(data.process.pid));
  rw('内存(VSZ)',to(data.process.vsz_kb)+' KB'); rw('模式',to(data.process.mode_cmdline)+(data.process.mode_ok?'':' [INVALID]'));
  rw('端口 5588',yn(data.process.port_listening)); rw('开机自启',yn(data.process.init_enabled));

  sec('Init 脚本 (/etc/init.d/acc)');
  rw('文件存在',yn(data.init_script.exists)); rw('Args 行',to(data.init_script.args_line));
  rw('模式标志',to(data.init_script.mode_flag)+' → '+to(data.init_script.mode_name));
  rw('短格式(-m)',yn(data.init_script.short_format)); rw('有 -p 端口',yn(data.init_script.has_port));

  if (data.core_config) {
    var cfg = data.core_config;
    sec('运行时配置 (acc_core_conf.json)');
    rw('文件存在',yn(cfg.exists));
    if (cfg.exists) { rw('tproxy_ip',to(cfg.tproxy_ip)+' ['+ok(cfg.tproxy_ip_ok)+']'); rw('acc_mode',to(cfg.acc_mode_name)+' ['+ok(cfg.acc_mode_ok)+']'); }
  }

  sec('网络与防火墙');
  rw('TUN 接口',to(data.network.tun_iface||'无')); rw('FW 5588',yn(data.network.fw_rule_5588));
  rw('Hotplug',yn(data.network.hotplug)); rw('TURN 中继',ok(data.network.turn_reachable)+' (route-turn.xxghh.biz)');
  rw('API 端点','HTTP '+to(data.network.api_http_code)+' ['+ok(data.network.api_reachable)+']');
  rw('GAMEACC 链',yn(data.network.gameacc_exists));
  if (data.network.gameacc_sample && data.network.gameacc_sample !== 'N/A') L.push('  '+pd('',COL)+' │ '+to(data.network.gameacc_sample));

  // Latency
  if (data.latency) {
    sec('延迟诊断 (ping 5次, ms)');
    L.push('  '+pd('目标',30)+'Min     Avg     Max     丢包');
    L.push('  '+pd('─'.repeat(28),30)+'─────  ─────  ─────  ────');
    var pRow = function(lb,r) {
      var s = '  '+pd(lb,30);
      s += pd(r.min||'?',7)+' '+pd(r.avg||'?',7)+' '+pd(r.max||'?',7)+(r.loss||'?')+'%';
      return s;
    };
    if (data.latency.gateway) L.push(pRow('网关 ('+(data.latency.gateway.host||'')+')',data.latency.gateway));
    if (data.latency.dns) L.push(pRow('DNS ('+(data.latency.dns.host||'')+')',data.latency.dns));
    if (data.latency.turn) L.push(pRow('TURN 中继 ('+(data.latency.turn.host||'')+')',data.latency.turn));
    if (data.latency.nodes && data.latency.nodes.length > 0) {
      L.push(''); L.push('  加速节点 (雷神分配):');
      L.push('  IP 地址              测速延迟');
      L.push('  ──────────────────   ────────');
      for (var i = 0; i < Math.min(data.latency.nodes.length,9); i++) {
        var n = data.latency.nodes[i];
        L.push('  '+pd(n.ip||'?',20)+(n.ping_ms||'?')+' ms');
      }
    }
    var gwAvg = parseFloat((data.latency.gateway||{}).avg);
    var turnAvg = parseFloat((data.latency.turn||{}).avg);
    if (!isNaN(gwAvg) && gwAvg > 10) L.push('  ⚠ 网关延迟 >10ms → 检查 WiFi/LAN 干扰');
    if (!isNaN(gwAvg) && !isNaN(turnAvg) && turnAvg-gwAvg > 50) L.push('  ⚠ TURN-网关 = '+(turnAvg-gwAvg).toFixed(0)+'ms → 宽带/服务器延迟');
  }

  sec('依赖包');
  var pkgs = data.packages || {}, pKeys = Object.keys(pkgs).sort();
  for (var ki = 0; ki < pKeys.length; ki++) rw(pKeys[ki],yn(pkgs[pKeys[ki]]));

  sec('设备加速状态');
  var devs = data.devices || { Phone:'None',PC:'None',Game:'None',Unknown:'None' };
  for (var dn in devs) rw(dn,to(devs[dn]));

  if (data.autopause) {
    var ap = data.autopause;
    sec('自动暂停');
    rw('脚本',yn(ap.script_installed));
    rw('手动令牌',ap.token_configured?to(ap.token_masked)+' [OK]':'未配置 ['+ok(false)+']');
    rw('离家模式',ap.manual_disable=='1'?'已启用 (自动暂停禁用)':'自动模式');
    rw('daemon 令牌',yn(ap.daemon_token_ok)+' (从 acc_core_conf.json 提取)');
    rw('定时任务',yn(ap.cron_enabled));
  }

  sec('acc-gw 内部错误日志 (/tmp/acc/log/)');
  var errLogs = data.error_logs || [];
  if (errLogs.length > 0) for (var i = 0; i < errLogs.length; i++) L.push('  ['+errLogs[i].file+'] '+to(errLogs[i].line));
  else L.push('  (无错误)');

  sec('最近系统日志 (logread)');
  var logs = data.logs || [];
  if (logs.length > 0) for (var i = 0; i < logs.length; i++) L.push('  '+to(logs[i]));
  else L.push('  (无相关日志)');

  L.push(''); L.push('═══════════════════════════════════════'); L.push('  报告结束');
  document.getElementById('debug_output').textContent = L.join('\n');
}

function debug_show_err(msg) {
  document.getElementById('debug_status_text').innerHTML = '<span style="color:#c00">'+msg+'</span>';
  document.getElementById('debug_output').textContent = 'ERROR: '+msg;
}

function debug_copy() {
  var text = document.getElementById('debug_output').textContent;
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(function() {
      var s = document.getElementById('debug_status_text'), old = s.innerHTML;
      s.innerHTML = '<span style="color:#080">已复制到剪贴板</span>';
      setTimeout(function(){s.innerHTML=old},2000);
    });
  } else {
    var ta = document.createElement('textarea'); ta.value = text;
    ta.style.position='fixed'; ta.style.left='-9999px';
    document.body.appendChild(ta); ta.select();
    document.execCommand('copy'); document.body.removeChild(ta);
  }
}

document.addEventListener('DOMContentLoaded', function() {
  debug_refresh(); setInterval(debug_refresh, DEBUG_POLL_MS);
});
//]]></script>

HTMEOF

        echo "[INFO] LuCI fw4 适配补丁已应用 (含自动暂停页面+诊断调试页)"

    else
        echo "[INFO] 正在从 $patch_dir 部署 LuCI fw4 补丁..."
        cp -r "$patch_dir/luasrc"/* "$luci_src/"
        echo "[INFO] LuCI fw4 适配补丁已应用 (from $patch_dir)"
    fi

    # Clear LuCI dispatch cache so changes take effect and the new menu
    # entry is not hidden by a stale /tmp/luci-indexcache*.
    rm -f /tmp/luci-indexcache* 2>/dev/null; rm -rf /tmp/luci-modulecache 2>/dev/null
    /etc/init.d/rpcd restart >/dev/null 2>&1
    echo "[INFO] LuCI 缓存已清除，刷新 Web 页面即可看到更新"
}

# ============================================================
# Menu
# ============================================================
leigod_menu() {
    echo
    echo "============================="
    echo "OpenWrt LeigodAcc Manager"
    echo "防火墙: $FW_NAME"
    echo "包管理: $(pkg_mgr_name)"
    echo
    echo "1. 安装"
    echo "2. 卸载"
    echo "3. 重装/更新"
    echo "4. 禁用/启用 雷神服务"
    echo "5. 切换运行模式   (TUN/Tproxy)"
    echo "6. 安装兼容性依赖 (主机优化)"
    echo "7. 禁用/启用 IPv6 (手机优化)"
    echo "8. 安装 Lean IPKG 版"
    echo "9. 自动暂停时长   (省时长)"
    echo "S. 查看服务状态   (诊断)"
    echo "L. 延迟波动诊断   (bufferbloat/QoS)"
    echo "T. 内核网络调优   (低延迟优化)"
    echo "D. DNS 兜底       (引擎分流表下载)"
    echo "U. 自动升级 开/关 (防错架构包)"
    echo "H. 反馈/帮助"
    echo "0. 退出"
    echo "============================="
    echo -n "选择数字/字母并回车执行: "
}

# ============================================================
# Install LeigodAcc
# ============================================================
install_leigodacc() {
    if [ -d /usr/sbin/leigod ]; then
        echo -n "[INFO] 检测到已经安装 LeigodAcc ([1]继续安装 / [2]取消): "
        read choice
        case "$choice" in
            1)
                ;;
            2)
                return
                ;;
            *)
                echo "[ERROR] 无效的选项，请重新输入"
                return
                ;;
        esac
    fi

    # --- Software feed overview ---
    echo "[INFO] 包管理器: $(pkg_mgr_name)"
    pkg_show_feeds
    if [ "$PKG_MGR" = "none" ]; then
        echo "[ERROR] 未检测到 apk / opkg，无法安装依赖包"
        return 1
    fi

    release_info=$(cat /etc/openwrt_release)
    if echo "$release_info" | grep -qE "iStoreOS|QWRT|ImmortalWrt|LEDE"; then
        echo "Detected third-party firmware: $(echo "$release_info" | grep -E "iStoreOS|QWRT|ImmortalWrt|LEDE")"
    fi

    # Check disk space before installing
    if ! check_disk_space; then
        return 1
    fi

    # Wait for a busy package manager instead of blindly deleting its lock.
    # apk has no /var/lock/opkg.lock, so this block is opkg-only.
    if [ -e /var/lock/opkg.lock ] && [ "$PKG_MGR" = "opkg" ]; then
        if pgrep -x "opkg" > /dev/null 2>&1; then
            echo "[WARN] 检测到其他 opkg 进程正在运行，等待完成 (最多30秒)..."
            local _i=0
            while [ $_i -lt 30 ] && pgrep -x "opkg" > /dev/null 2>&1; do
                sleep 2
                _i=$((_i + 2))
            done
        fi
        # Only remove lock if no opkg is currently running
        if ! pgrep -x "opkg" > /dev/null 2>&1; then
            rm -f /var/lock/opkg.lock
        else
            echo "[WARN] opkg 仍在运行, 保留锁文件"
        fi
    fi
    if ! check_network; then
        echo "[WARN] 网络不可达，后续依赖安装及下载可能会失败"
        echo -n "是否继续? (y/n): "
        read proceed
        [ "$proceed" != "y" ] && [ "$proceed" != "Y" ] && return
    fi

    # Install essential packages based on firewall type
    echo "[INFO] 安装必备组件 (防火墙: $FW_NAME)..."
    PKG_FAILED=""
    for pkg in $(get_essential_packages); do
        if pkg_installed "$pkg"; then
            echo "[INFO] $pkg 必备组件已安装，跳过"
        else
            safe_pkg_install "$pkg"
        fi
    done

    # Install optional/enhanced packages
    echo "[INFO] 安装增强组件..."
    for pkg in $(get_optional_packages); do
        if pkg_installed "$pkg"; then
            echo "[INFO] $pkg 已安装，跳过"
        else
            safe_pkg_install "$pkg"
        fi
    done

    # fw4: ensure TPROXY kernel support (with fallback)
    if ! ensure_fw4_tproxy; then
        echo "[WARN] TPROXY 不可用。注意: 部分 acc-gw 版本仅支持 TPROXY，此情况下加速将无法工作"
    fi

    # Setup fw4 integration if needed
    setup_fw4_integration
    # LuCI: on OpenWrt 24.10+ the Lua CBI pages need the compat layer.
    # Since 25.12 the dispatcher is ucode and only loads /usr/lib/lua/luci
    # controllers when luci-compat + luci-lua-runtime are present.
    if ! pkg_installed "luci-compat"; then
        echo "[INFO] 安装 luci-compat (LuCI Lua CBI 兼容层)..."
        safe_pkg_install luci-compat
    fi
    if ! pkg_installed "luci-lua-runtime"; then
        echo "[INFO] 安装 luci-lua-runtime (Lua 调度运行时)..."
        safe_pkg_install luci-lua-runtime
    fi
    if [ -d /usr/lib/lua/luci ]; then
        apply_luci_fw4_patch
    else
        echo "[WARN] /usr/lib/lua/luci 不存在，LuCI 页面无法部署 (缺少 luci-lua-runtime)"
    fi

    # UPnP for device discovery (needed by the phone APP)
    if ! pkg_installed "$PKG_LUCI_UPNP"; then
        safe_pkg_install "$PKG_LUCI_UPNP"
    fi
    if ensure_upnpd; then
        if [ -f /etc/config/upnpd ]; then
            echo "[INFO] 正在启用 UPnP..."
            uci set upnpd.config.enabled='1' 2>/dev/null
            uci commit upnpd 2>/dev/null

            /etc/init.d/miniupnpd enable >/dev/null 2>&1
            /etc/init.d/miniupnpd restart >/dev/null 2>&1

            echo "[INFO] UPnP 已启用并运行"
            echo "安装成功后可以在雷神加速器 APP 发现并绑定设备"
            echo
        else
            echo "[WARN] $PKG_UPNP 已安装但 /etc/config/upnpd 不存在，跳过 UPnP 启用"
            echo "[WARN] 手机 APP 可能无法通过 SSDP 发现路由器"
        fi
    else
        echo "[WARN] UPnP 服务不可用 ($PKG_UPNP)，继续安装但不启用 UPnP"
        echo "[WARN] 手机 APP 可能无法发现路由器；可稍后手动安装 $PKG_LUCI_UPNP"
    fi

    echo "[INFO] 下面是雷神官方提供的脚本,打印内容偏长如遇到问题请提供输出内容(截图/文字)反馈到群里."

    install_script=$(curl -fsSL --connect-timeout 10 --max-time 60 \
        https://119.3.40.126/router_plugin_new/plugin_install.sh 2>/dev/null || \
        curl -fsSL --connect-timeout 10 --max-time 60 \
        http://119.3.40.126/router_plugin_new/plugin_install.sh 2>/dev/null)
    if [ -z "$install_script" ]; then
        echo "[ERROR] 无法下载雷神官方安装脚本！请检查网络或雷神服务器状态"
        return 1
    fi

    # On apk systems the official script still calls `opkg`. Provide a shim
    # through PATH for this single invocation only.
    install_opkg_shim
    _old_path="$PATH"
    case "$PKG_MGR" in
        apk) PATH="$APK_SHIM_DIR:$PATH" ;;
    esac
    ( cd /tmp && printf '%s\n' "$install_script" | sh )
    _install_rc=$?
    PATH="$_old_path"
    if [ "$_install_rc" != "0" ]; then
        echo "[WARN] 官方安装脚本返回非零状态 ($_install_rc)，继续做后续检查"
    fi

    if [ ! -d /usr/sbin/leigod ]; then
        echo "[ERROR] 检测到 LeigodAcc 未安装，有可能是设备存储空间已满或者雷神服务器挂了!"
        echo "请登录 OpenWrt 路由器后台: 系统-软件包 查看当前可用空间诊断."
    else
        echo "[INFO] LeigodAcc 已成功安装"

        # Initialize UCI config for LuCI pages (device.lua needs base/device sections)
        ensure_uci_config

        # The official installer may write `--mode tun` (GNU long format)
        # which the acc-gw binary silently ignores, defaulting to TPROXY.
        # Correct it to the short format (-m tun) that the binary recognizes.
        if grep -q -- "--mode tun" /etc/init.d/acc 2>/dev/null; then
            sed -i 's|--mode tun|-m tun|' /etc/init.d/acc
            echo "[INFO] 已修正加速模式参数格式 (--mode tun → -m tun)"
        elif grep -q -- "--mode tproxy" /etc/init.d/acc 2>/dev/null; then
            sed -i 's|--mode tproxy|-m tproxy|' /etc/init.d/acc
            echo "[INFO] 已修正加速模式参数格式 (--mode tproxy → -m tproxy)"
        fi

        setup_iptables_nft_compat

        # The official installer removes existing LuCI files as part of its
        # uninstall step. Re-apply our patch so all 12 files are present.
        apply_luci_fw4_patch
        # Verify: ensure critical LuCI files were actually written.
        local luci_missing=""
        for f in /usr/lib/lua/luci/controller/acc.lua \
                 /usr/lib/lua/luci/model/cbi/leigod/service.lua \
                 /usr/lib/lua/luci/model/cbi/leigod/device.lua \
                 /usr/lib/lua/luci/model/cbi/leigod/autopause.lua \
                 /usr/lib/lua/luci/view/leigod/debug.htm; do
            [ ! -f "$f" ] && luci_missing="$luci_missing  $f\n"
        done
        if [ -n "$luci_missing" ]; then
            echo "[WARN] LuCI 文件缺失! 可能是补丁目录未上传或内联写入失败:"
            printf "$luci_missing"
            echo "[INFO] 请确保 luci-fw4-patch/ 目录已上传到 /tmp/ 或 /root/"
            echo "[INFO] 或手动运行: leigod-fw4.sh 内联补丁将自动写入"
        else
            echo "[INFO] LuCI fw4 适配文件完整性验证: 通过"
        fi

        # The official installer creates Lua LuCI files of its own; make sure
        # ours win and clear the LuCI dispatch cache (25.12 keeps an indexcache).
        rm -f /tmp/luci-indexcache* 2>/dev/null; rm -rf /tmp/luci-modulecache 2>/dev/null
        /etc/init.d/rpcd restart >/dev/null 2>&1
        /etc/init.d/uhttpd restart >/dev/null 2>&1

        # Install tproxy_ip watcher cron (daemon regenerates JSON with fake IP)
        install_tproxy_watcher

        # A failed in-app upgrade (e.g. the vendor served an arm64-only build to
        # an amd64 box) can leave this flag behind. While it exists, the engine's
        # monitor/init deliberately refuse to spawn processes ("upgrade window").
        if [ -f /tmp/acc/upgrade_flag ]; then
            rm -f /tmp/acc/upgrade_flag
            echo "[INFO] 已清理残留的升级标志 /tmp/acc/upgrade_flag"
        fi

        # Normalize the acceleration config (INI is authoritative on new builds)
        fix_acc_core_conf

        # Verify the API port really listens; report a clear cause if it does not
        acc_health_check

        # The engine pulls its routing tables from dfs01.nn.com. When the local
        # resolver cannot give an A record for it, nothing will be accelerated.
        if [ -z "$(dns_resolve_ipv4 dfs01.nn.com)" ]; then
            echo "[WARN] 本机无法解析 dfs01.nn.com —— 引擎下载不到分流表，加速不会生效"
            echo "[WARN] 运行菜单 D (DNS 兜底) 固定 IPv4 后执行 /etc/init.d/acc restart"
        fi

        # Inform user about LuCI and TUN mode
        echo ""
        echo "=========================================="
        echo "  [提示] LuCI 网页管理 & 加速模式"
        echo "=========================================="
        if [ -f /usr/lib/lua/luci/controller/acc.lua ]; then
            echo "  LuCI 网页界面: 已就绪"
            echo "  可通过路由器 Web 后台 → 服务 → 雷神加速器 访问"
        else
            echo "  LuCI 网页界面: 未安装 (缺少 /usr/lib/lua/luci/controller/acc.lua)"
            echo "  请检查 luci-compat / luci-lua-runtime 是否安装"
        fi
        if [ -e /var/run/docker.sock ] || [ -e /run/docker.sock ] || \
           { command -v ip >/dev/null 2>&1 && ip -4 addr show docker0 >/dev/null 2>&1; }; then
            echo "  [注意] 检测到 Docker 网桥 (172.17.0.0/16)"
            echo "         该网段不在 acc-gw 默认直连列表中，如容器流量异常可先暂停加速测试"
        fi
        echo "=========================================="
        echo ""
    fi

    # Post-install check
    echo "[INFO] 正在执行安装后检查..."
    for pkg in $(get_check_packages); do
        if ! pkg_installed "$pkg"; then
            echo "[WARN] 缺少组件包: $pkg"
            echo "[INFO] 你可以通过管理器中的安装依赖性组件进行补充!"
        fi
    done

    if [ "$FW_TYPE" = "fw4" ]; then
        echo ""
        echo "=========================================="
        echo "  [重要] fw4 防火墙 — 环境适配"
        echo "=========================================="
        echo "  当前系统使用 fw4/nftables 防火墙。"
        echo "  请确保 acc_core_conf.json 中 tproxy_ip"
        echo "  正确设置为路由器 LAN IP。"
        echo ""
        echo "  运行菜单选项 S (诊断) 可自动检测和修复。"
        echo "=========================================="
        echo ""

        # Initialize UCI config for LuCI pages
        ensure_uci_config
        # Fix acc_core_conf.json if needed (covers both fresh and re-installs)
        fix_acc_core_conf
        # Install tproxy_ip watcher cron
        install_tproxy_watcher

        echo -n "是否需要检查服务运行状态? (y/n, 默认 n): "
        read check_status
        case "$check_status" in
            [Yy]|[Yy][Ee][Ss])
                check_service_status
                ;;
            *)
                echo "[INFO] 可稍后通过菜单选项 S 查看"
                ;;
        esac
        echo ""
    fi

    # Run LuCI integrity verification after install
    if [ -d /usr/lib/lua/luci ]; then
        verify_luci
    fi
}

# ============================================================
# Install compatibility dependencies
# ============================================================
install_compatibility_dependencies() {
    if ! check_disk_space; then
        return 1
    fi

    arch=$(pkg_arch)
    if [ -z "$arch" ]; then
        echo "[ERROR] 无法确定系统架构"
        return
    fi
    echo "[INFO] 系统架构: $arch / 包管理器: $(pkg_mgr_name)"

    # For fw4, try official repos first since OpenWrt 24.10 should have these packages
    if [ "$FW_TYPE" = "fw4" ]; then
        echo "[INFO] fw4 系统，优先使用官方软件源安装兼容依赖..."
        for pkg in tc-full conntrack conntrackd ipset; do
            if ! pkg_available "$pkg"; then
                echo "[INFO] $pkg 不在当前软件源中，跳过"
                continue
            fi
            if ! pkg_installed "$pkg"; then
                safe_pkg_install "$pkg"
            else
                echo "[INFO] $pkg 已安装，跳过"
            fi
        done
        # fw4: skip immortalwrt 23.05.3 fallback — those packages are for an older
        # kernel/libc ABI and may fail to install or cause runtime issues.
        echo "[INFO] fw4 系统已通过官方源安装兼容依赖，跳过旧版 immortalwrt 23.05.3 回退"
        if ! ensure_fw4_tproxy; then
            echo "[WARN] TPROXY 不可用。注意: 部分 acc-gw 版本仅支持 TPROXY，此情况下加速将无法工作"
        fi
    fi

    # Fallback: architecture-specific packages (opkg/fw3 only — never on apk)
    if [ "$PKG_MGR" = "opkg" ] && [ "$FW_TYPE" != "fw4" ]; then
    case "$arch" in
        x86_64)
            packages="tc-full conntrack conntrackd libnetfilter-cttimeout1 libnetfilter-cthelper0"
            urls="https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/x86_64/packages/libnetfilter-cttimeout1_1.0.0-2_x86_64.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/x86_64/packages/libnetfilter-cthelper0_1.0.0-2_x86_64.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/x86_64/base/tc-full_6.3.0-1_x86_64.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/x86_64/packages/conntrackd_1.4.8-1_x86_64.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/x86_64/packages/conntrack_1.4.8-1_x86_64.ipk"
            ;;
        mipsel_24kc)
            packages="tc-full conntrack conntrackd libnetfilter-cttimeout1 libnetfilter-cthelper0"
            urls="https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/mipsel_24kc/packages/conntrackd_1.4.8-1_mips_24kc.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/mipsel_24kc/packages/conntrack_1.4.8-1_mips_24kc.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/mipsel_24kc/packages/libnetfilter-cthelper0_1.0.0-2_mips_24kc.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/mipsel_24kc/packages/libnetfilter-cttimeout1_1.0.0-2_mips_24kc.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/mipsel_24kc/base/tc-full_6.3.0-1_mips_24kc.ipk"
            ;;
        aarch64_cortex-a53|aarch64_cortex-a53+crypto)
            packages="tc-full conntrack conntrackd libnetfilter-cttimeout1 libnetfilter-cthelper0"
            urls="https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_cortex-a53/base/tc-full_6.3.0-1_aarch64_cortex-a53.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_cortex-a53/packages/conntrack_1.4.8-1_aarch64_cortex-a53.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_cortex-a53/packages/conntrackd_1.4.8-1_aarch64_cortex-a53.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_cortex-a53/packages/libnetfilter-cttimeout1_1.0.0-2_aarch64_cortex-a53.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_cortex-a53/packages/libnetfilter-cthelper0_1.0.0-2_aarch64_cortex-a53.ipk"
            ;;
        aarch64_generic|aarch64_cortex-a72*|aarch64_cortex-a76*|aarch64_cortex-a55*|aarch64_cortex-a73*)
            packages="tc-full conntrack conntrackd libnetfilter-cttimeout1 libnetfilter-cthelper0"
            urls="https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_generic/packages/conntrack_1.4.8-1_aarch64_generic.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_generic/packages/conntrackd_1.4.8-1_aarch64_generic.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_generic/packages/libnetfilter-cthelper0_1.0.0-2_aarch64_generic.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_generic/packages/libnetfilter-cttimeout1_1.0.0-2_aarch64_generic.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/aarch64_generic/base/tc-full_6.3.0-1_aarch64_generic.ipk"
            ;;
        arm_cortex-a9*)
            packages="tc-full conntrack conntrackd libnetfilter-cttimeout1 libnetfilter-cthelper0"
            urls="https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/arm_cortex-a9/packages/conntrack_1.4.8-1_arm_cortex-a9.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/arm_cortex-a9/packages/conntrackd_1.4.8-1_arm_cortex-a9.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/arm_cortex-a9/packages/libnetfilter-cthelper0_1.0.0-2_arm_cortex-a9.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/arm_cortex-a9/packages/libnetfilter-cttimeout1_1.0.0-2_arm_cortex-a9.ipk
            https://mirrors.pku.edu.cn/immortalwrt/releases/23.05.3/packages/arm_cortex-a9/base/tc-full_6.3.0-1_arm_cortex-a9.ipk"
            ;;
        arm_cortex-a7*|arm_cortex-a15*|arm_cortex-a17*)
            echo "[WARN] 架构 $arch — 无预编译 IPK, 仅尝试 opkg 安装"
            packages="tc-full conntrack conntrackd"
            urls=""
            ;;
        arm_mpcore|arm_xscale)
            echo "[WARN] 架构 $arch 为 ARMv5，第三方源可能不兼容"
            echo "[WARN] 建议使用固件自带软件源安装依赖，或升级设备固件"
            packages=""
            # ARMv5: no compatible pre-built packages — skip manual downloads
            return
            ;;
        *)
            echo "[ERROR] 不支持的架构: $arch"
            return
            ;;
    esac

    for pkg in $packages; do
        if ! pkg_installed "$pkg"; then
            safe_pkg_install "$pkg"
        else
            echo "[INFO] $pkg 已安装，跳过"
        fi
    done

    for pkg in $packages; do
        if ! pkg_installed "$pkg"; then
            echo "[INFO] $pkg 未在官方源中找到，尝试使用第三方源"
            echo "[INFO] 正在使用天灵 immortalwrt pku 的软件源，并不是原生支持的软件包可能会存在你所在的第三方固件源除外的问题"
            tmp_dir=$(mktemp -d)
            for url in $urls; do
                wget -P "$tmp_dir" "$url"
            done
            pkg_install_raw "$tmp_dir"/*.ipk
            rm -rf "$tmp_dir"
            break
        fi
    done
    fi  # end opkg/fw3-only fallback block

    # Final check
    for pkg in $(get_check_packages); do
        if ! pkg_installed "$pkg"; then
            echo "[ERROR] 缺少包: $pkg"
            echo "Tip: 请检查软件源配置是否正确:"
            case "$PKG_MGR" in
                apk)  echo "     /etc/apk/repositories.d/*.list   (apk update 可刷新索引)" ;;
                opkg) echo "     /etc/opkg/distfeeds.conf" ;;
            esac
            echo
        fi
    done
}

# ============================================================
# Uninstall LeigodAcc
# ============================================================
# True if anything belonging to the plugin/manager is still present.
# Do NOT rely on /usr/sbin/leigod alone: a half-finished uninstall may already
# have deleted it while configs, LuCI files and cron entries remain.
leigod_installed() {
    [ -d /usr/sbin/leigod ] && return 0
    [ -f /etc/init.d/acc ] && return 0
    [ -f /etc/config/accelerator ] && return 0
    [ -f /etc/config/acc_firewall.ini ] && return 0
    [ -f /usr/lib/lua/luci/controller/acc.lua ] && return 0
    pkg_installed leigod-acc && return 0
    return 1
}

uninstall_leigodacc() {
    if ! leigod_installed; then
        echo "[ERROR] 未检测到雷神加速器插件或管理器文件，无需卸载"
        return
    fi

    echo "[INFO] 确定卸载? 输入数字后回车或 10s 后自动取消 ([1]确定 / [2]取消): "
    read -t 10 choice
    case "$choice" in
        1)
            ;;
        *)
            echo "[INFO] 取消卸载"
            return
            ;;
    esac

    echo "[INFO] 开始卸载 LeigodAcc ..."

    # --- 1. Vendor uninstaller first (best effort) ---------------------------
    # The bundle ships leigod_uninstall.sh; it knows the layout we do not.
    if [ -x /usr/sbin/leigod/leigod_uninstall.sh ]; then
        echo "[INFO] 调用官方卸载脚本 leigod_uninstall.sh ..."
        sh /usr/sbin/leigod/leigod_uninstall.sh </dev/null >/dev/null 2>&1 || \
            echo "[WARN] 官方卸载脚本返回非零，继续手动清理"
    fi

    # --- 2. Stop the service and kill leftovers ------------------------------
    if [ -x /etc/init.d/acc ]; then
        /etc/init.d/acc stop >/dev/null 2>&1
        /etc/init.d/acc disable >/dev/null 2>&1
    fi
    for pat in "/usr/sbin/leigod/acc-gw" "acc_upgrade_monitor" "leigod/monitor.sh"; do
        pids=$(pgrep -f "$pat" 2>/dev/null)
        [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    done
    echo "[INFO] 服务已停止 (残留进程已清理)"

    # --- 3. Package-provided files (Lean IPK installs) ----------------------
    if pkg_installed "leigod-acc"; then
        echo "[INFO] 通过包管理器移除 leigod-acc 相关包 ..."
        pkg_remove_raw luci-i18n-leigod-acc-zh-cn luci-app-leigod-acc leigod-acc >/dev/null 2>&1
    fi

    # --- 4. All engine configuration (new INI layout + legacy JSON/UCI) ------
    rm -f /etc/config/accelerator \
          /etc/config/leigod \
          /etc/config/accelerator.ini \
          /etc/config/acc_firewall.ini \
          /etc/config/acc_version.ini \
          /etc/config/acc_core_conf.json \
          /etc/config/ipdatacloud_country.xdb \
          /etc/config/upgrade_data.json \
          /etc/config/accelerator.lock \
          /etc/config/accelerator.ini.lock \
          /etc/config/acc_firewall.ini.lock \
          /etc/config/acc_version.ini.lock
    echo "[INFO] 已清理引擎配置 (accelerator / accelerator.ini / acc_firewall.ini / acc_version.ini / *.xdb)"

    # --- 5. Runtime state under /tmp (locks, logs, sockets, downloads) ------
    rm -rf /tmp/acc
    rm -rf /tmp/acc_install_lib
    rm -f /tmp/acc-lib.tar.gz /tmp/acc-bundle-*.tar.gz \
          /tmp/acc_domain_config_*.json /tmp/upgrade_data.json \
          /tmp/leigod_acc_install.log /tmp/leigod_acc_init.log \
          /tmp/leigod_acc_monitor.log /tmp/leigod-hotplug-restart.ts \
          /tmp/acc_firewall.ini.bak 2>/dev/null
    echo "[INFO] 已清理运行时文件 (/tmp/acc 等)"

    # --- 6. Service + binaries ----------------------------------------------
    rm -f /etc/init.d/acc
    rm -rf /usr/sbin/leigod
    echo "[INFO] 已删除服务脚本与安装目录 (/etc/init.d/acc, /usr/sbin/leigod)"

    # --- 7. LuCI files (Lua CBI + i18n + any JS-era leftovers) --------------
    rm -f /usr/lib/lua/luci/controller/acc.lua \
          /usr/lib/lua/luci/i18n/acc.zh-cn.lmo \
          /usr/share/luci/menu.d/luci-app-leigod-acc.json \
          /usr/share/rpcd/acl.d/luci-app-leigod-acc.json
    rm -rf /usr/lib/lua/luci/model/cbi/leigod \
           /usr/lib/lua/luci/view/leigod \
           /www/luci-static/resources/view/leigodacc \
           /www/luci-static/resources/view/leigod
    echo "[INFO] 已删除 LuCI 页面文件 (12 个 Lua 文件 + 菜单/ACL 残留)"

    # --- 8. Cron entries (unconditional) ------------------------------------
    if [ -f /etc/crontabs/root ]; then
        sed -i '/leigod-auto-pause/d' /etc/crontabs/root 2>/dev/null
        sed -i '/leigod-fw4\.sh/d' /etc/crontabs/root 2>/dev/null
        sed -i '/\/usr\/sbin\/leigod\//d' /etc/crontabs/root 2>/dev/null
        /etc/init.d/cron restart >/dev/null 2>&1
        echo "[INFO] 已清理 crontab 中的雷神相关任务"
    fi

    # --- 9. Auto-pause component (unconditional) ----------------------------
    rm -f /usr/sbin/leigod-auto-pause.sh \
          /etc/leigod-auto-pause.conf \
          /tmp/leigod-auto-pause.state \
          /tmp/leigod-auto-pause.log \
          /tmp/leigod-away.logged
    echo "[INFO] 已清理自动暂停组件"

    # --- 10. Firewall integration -------------------------------------------
    # 10.1 UCI allow rule for TCP 5588 (remove every match)
    local i=0
    while [ "$i" -lt 5 ] && grep -q "LeigodAcc" /etc/config/firewall 2>/dev/null; do
        fw_idx=$(uci show firewall 2>/dev/null | grep "LeigodAcc" | head -1 | cut -d. -f1-2)
        case "$fw_idx" in
            firewall.*) ;;
            *) break ;;
        esac
        uci delete "$fw_idx" 2>/dev/null || break
        i=$((i + 1))
    done
    if [ "$i" -gt 0 ]; then
        uci commit firewall 2>/dev/null
        echo "[INFO] 已移除防火墙规则 LeigodAcc (TCP 5588)"
    fi

    # 10.2 hotplug guard script
    rm -f /etc/hotplug.d/firewall/99-leigodacc-restart

    # 10.3 Engine-injected rules: iptables chains (mangle/filter/nat), ipsets, nft table
    if command -v iptables >/dev/null 2>&1; then
        for tbl in mangle filter nat; do
            case "$tbl" in filter) built="INPUT" ;; *) built="PREROUTING" ;; esac
            iptables -t "$tbl" -D "$built" -j GAMEACC 2>/dev/null
            iptables -t "$tbl" -F GAMEACC 2>/dev/null
            iptables -t "$tbl" -X GAMEACC 2>/dev/null
        done
        # engine-level ACCEPT rules for the API / discovery ports
        iptables -t filter -D INPUT -p tcp -m multiport --dports 5588 -j ACCEPT 2>/dev/null
        iptables -t filter -D INPUT -p udp -m multiport --dports 6066 -j ACCEPT 2>/dev/null
    fi
    if command -v ipset >/dev/null 2>&1; then
        for name in $(ipset list -n 2>/dev/null); do
            case "$name" in
                direct_*|target_*|proxy_*) ipset destroy "$name" 2>/dev/null ;;
            esac
        done
    fi
    command -v nft >/dev/null 2>&1 && nft delete table inet tproxy_table 2>/dev/null
    echo "[INFO] 已清理加速规则 (GAMEACC 链 / ipset 集合 / nft 表)"

    # 10.4 Reload firewall so the removed rule takes effect
    if [ -x /etc/init.d/firewall ]; then
        /etc/init.d/firewall reload >/dev/null 2>&1
    fi

    # --- 11. iptables-nft symlink we may have created -----------------------
    # Never leave the system without a working `iptables`: prefer restoring the
    # package's own alternatives target (xtables-nft-multi) over deleting.
    if [ -L /usr/sbin/iptables ]; then
        _ipt_tgt=$(readlink /usr/sbin/iptables 2>/dev/null)
        case "$_ipt_tgt" in
            *iptables-nft*)
                if [ -x /usr/sbin/xtables-nft-multi ]; then
                    ln -sf xtables-nft-multi /usr/sbin/iptables
                    echo "[INFO] 已恢复 /usr/sbin/iptables -> xtables-nft-multi"
                else
                    rm -f /usr/sbin/iptables /usr/sbin/iptables-restore /usr/sbin/iptables-save
                    echo "[WARN] iptables-nft 不可用，已移除兼容符号链接"
                fi
                ;;
        esac
    fi

    # --- 12. opkg→apk shim ---------------------------------------------------
    remove_opkg_shim

    # --- 13. LuCI caches + web stack restart --------------------------------
    # The menu entry lives in the dispatch cache on the server and in the
    # browser session; dropping both forces a clean menu on next login.
    rm -f /tmp/luci-indexcache* 2>/dev/null; rm -rf /tmp/luci-modulecache 2>/dev/null
    /etc/init.d/rpcd restart >/dev/null 2>&1
    /etc/init.d/uhttpd restart >/dev/null 2>&1
    echo "[INFO] LuCI 缓存已清除，rpcd/uhttpd 已重启 (需要重新登录后台)"

    # --- 14. Leftover self-check -------------------------------------------
    leftovers=""
    for f in /etc/config/accelerator /etc/config/accelerator.ini \
             /etc/config/acc_firewall.ini /etc/config/acc_version.ini \
             /etc/config/acc_core_conf.json /etc/config/ipdatacloud_country.xdb \
             /etc/init.d/acc /usr/sbin/leigod-auto-pause.sh \
             /etc/leigod-auto-pause.conf \
             /etc/hotplug.d/firewall/99-leigodacc-restart \
             /usr/lib/lua/luci/controller/acc.lua; do
        [ -e "$f" ] && leftovers="$leftovers $f"
    done
    [ -d /usr/sbin/leigod ] && leftovers="$leftovers /usr/sbin/leigod"
    [ -d /tmp/acc ] && leftovers="$leftovers /tmp/acc"
    [ -d /usr/lib/lua/luci/model/cbi/leigod ] && leftovers="$leftovers /usr/lib/lua/luci/model/cbi/leigod"
    [ -d /usr/lib/lua/luci/view/leigod ] && leftovers="$leftovers /usr/lib/lua/luci/view/leigod"
    if grep -q 'leigod' /etc/crontabs/root 2>/dev/null; then
        leftovers="$leftovers crontab(leigod)"
    fi

    echo ""
    if [ -n "$leftovers" ]; then
        echo "[WARN] 以下项目未能自动清理，请手动处理:"
        for x in $leftovers; do echo "        $x"; done
    else
        echo "[OK] 卸载完成，未发现残留"
    fi
    echo "[INFO] 保留项（如需一并清除请手动处理）:"
    echo "        /etc/config/upnpd      — 安装时启用的 UPnP 设置"
    echo "        /etc/sysctl.d/99-leigod-latency.conf — 内核网络调优 (如执行过选项 T)"
    echo "[INFO] 浏览器侧菜单缓存: 重新登录后台，或 Ctrl+Shift+R 强制刷新"
}

# ============================================================
# Reinstall LeigodAcc (preserves user config across reinstall)
# ============================================================
reinstall_leigodacc() {
    # Backup user configuration before uninstall wipes it.
    # uninstall_leigodacc() does rm -f /etc/config/accelerator which
    # destroys all user-configured device bindings and settings.
    local cfg_backup=""
    if [ -f /etc/config/accelerator ]; then
        cfg_backup="/tmp/accelerator.bak.$$"
        cp /etc/config/accelerator "$cfg_backup"
        echo "[INFO] 已备份 UCI 配置到 $cfg_backup"
    fi

    # Backup auto-pause config
    local ap_backup=""
    if [ -f /etc/leigod-auto-pause.conf ]; then
        ap_backup="/tmp/leigod-auto-pause.conf.bak.$$"
        cp /etc/leigod-auto-pause.conf "$ap_backup"
    fi

    # Backup LuCI files in case the official installer's uninstall step
    # deletes them and apply_luci_fw4_patch fails
    local luci_backup=""
    if [ -d /usr/lib/lua/luci/model/cbi/leigod ] || [ -d /usr/lib/lua/luci/view/leigod ]; then
        luci_backup="/tmp/luci-leigod-backup.$$"
        mkdir -p "$luci_backup"
        [ -f /usr/lib/lua/luci/controller/acc.lua ] && cp /usr/lib/lua/luci/controller/acc.lua "$luci_backup/"
        [ -d /usr/lib/lua/luci/model/cbi/leigod ] && cp -r /usr/lib/lua/luci/model/cbi/leigod "$luci_backup/"
        [ -d /usr/lib/lua/luci/view/leigod ] && cp -r /usr/lib/lua/luci/view/leigod "$luci_backup/"
        echo "[INFO] 已备份 LuCI 文件到 $luci_backup"
    fi

    uninstall_leigodacc
    install_leigodacc

    # Restore user configuration
    if [ -n "$cfg_backup" ] && [ -f "$cfg_backup" ]; then
        cp "$cfg_backup" /etc/config/accelerator
        rm -f "$cfg_backup"
        echo "[INFO] 已恢复 UCI 配置 (设备绑定/加速状态等)"
    fi
    if [ -n "$ap_backup" ] && [ -f "$ap_backup" ]; then
        cp "$ap_backup" /etc/leigod-auto-pause.conf
        rm -f "$ap_backup"
        echo "[INFO] 已恢复自动暂停配置"
    fi

    # If LuCI files are still missing after install, restore from backup
    if [ -n "$luci_backup" ] && [ -d "$luci_backup" ]; then
        if [ ! -f /usr/lib/lua/luci/controller/acc.lua ]; then
            mkdir -p /usr/lib/lua/luci/controller
            cp "$luci_backup/acc.lua" /usr/lib/lua/luci/controller/ 2>/dev/null
        fi
        if [ ! -d /usr/lib/lua/luci/model/cbi/leigod ] && [ -d "$luci_backup/model/cbi/leigod" ]; then
            mkdir -p /usr/lib/lua/luci/model/cbi/leigod
            cp -r "$luci_backup/model/cbi/leigod"/* /usr/lib/lua/luci/model/cbi/leigod/ 2>/dev/null
        fi
        if [ ! -d /usr/lib/lua/luci/view/leigod ] && [ -d "$luci_backup/view/leigod" ]; then
            mkdir -p /usr/lib/lua/luci/view/leigod
            cp -r "$luci_backup/view/leigod"/* /usr/lib/lua/luci/view/leigod/ 2>/dev/null
        fi
        rm -rf "$luci_backup"
        # Clear LuCI cache so restored files take effect
        rm -rf /tmp/luci-*
        echo "[INFO] LuCI 文件已从备份恢复"
    fi

    # Run LuCI integrity verification
    verify_luci
}

# ============================================================
# Ensure UCI accelerator config is initialized
# device.lua and other LuCI pages require base/device sections
# to exist; without them the Device Config page renders blank.
# ============================================================
ensure_uci_config() {
    lan_if=$(uci get network.lan.ifname 2>/dev/null | awk '{print $1}' | head -1)
    if [ -z "$lan_if" ]; then
        # DSA / 25.12: network.lan.ifname is often unset; prefer the bridge
        lan_if=$(uci get network.lan.device 2>/dev/null)
    fi
    [ -z "$lan_if" ] && lan_if="br-lan"

    # OpenWrt 25.12's uci refuses to set sections in a config file that does
    # not exist ("uci: Entry not found"), so create the file skeleton first.
    if [ ! -f /etc/config/accelerator ]; then
        printf '# Leigod accelerator (managed by leigod-fw4.sh)\n' > /etc/config/accelerator
        echo "[INFO] 已创建 /etc/config/accelerator"
    fi

    if ! uci -q get accelerator.base >/dev/null 2>&1; then
        uci set accelerator.base=system 2>/dev/null
        uci set accelerator.base.neigh="$lan_if" 2>/dev/null
        echo "[INFO] 已初始化 accelerator.base (监听接口: $lan_if)"
    fi
    if ! uci -q get accelerator.device >/dev/null 2>&1; then
        uci set accelerator.device=hardware 2>/dev/null
        echo "[INFO] 已初始化 accelerator.device"
    fi
    # Ensure a system section exists for service config
    if ! uci -q get accelerator.@system[0] >/dev/null 2>&1; then
        uci add accelerator system >/dev/null 2>&1
        echo "[INFO] 已初始化 accelerator system section"
    fi
    uci commit accelerator 2>/dev/null
}

# ============================================================
# Verify LuCI installation integrity
# ============================================================
# Checks that all 12 LuCI files exist, luci-compat is installed,
# and UCI config has required sections.  Returns 0 if all pass,
# non-zero if any check fails.
verify_luci() {
    local luci_src="/usr/lib/lua/luci"
    local errors=0

    echo
    echo "============================="
    echo "  LuCI 完整性验证"
    echo "============================="

    # --- 1. LuCI Lua compatibility layer ---
    # Since OpenWrt 25.12 the LuCI dispatcher is ucode based and only loads
    # /usr/lib/lua/luci/controller/*.lua when the Lua runtime is present.
    echo ""
    echo "[1/5] LuCI Lua 兼容层"
    for p in luci-compat luci-lua-runtime lua; do
        if pkg_installed "$p"; then
            echo "  [OK] $p 已安装"
        else
            echo "  [FAIL] $p 未安装"
            errors=$((errors + 1))
        fi
    done
    if [ ! -d /usr/lib/lua/luci/controller ]; then
        echo "  [FAIL] /usr/lib/lua/luci/controller 不存在 (Lua 控制器不会被加载)"
        errors=$((errors + 1))
    fi

    # --- 2. Lua bridge / menu registration self test ---
    # Without the bridge the controller file is scanned but skipped, the menu
    # entry never appears, and the URL answers 404 "No page is registered".
    #
    # NOTES on what can actually be tested from a shell:
    #   * `lua -e 'require("luci.dispatcher")'` can NEVER work: dispatcher.lua
    #     starts with `local http = _G.L.http`, and _G.L only exists inside the
    #     ucode→Lua bridge.
    #   * A standalone `ucode` process cannot fully build the bridge either,
    #     because luci.ucodebridge expects a CGI/uhttpd environment.
    # So probe the *effect* instead: request the page and look for HTTP 404.
    # 401/403/200/302 all mean "the route is registered" (we are simply not
    # logged in), while 404 means the Lua controller was not loaded.
    echo ""
    echo "[2/5] Lua 调度桥 / 菜单注册自检"
    local luci_port=""
    luci_port=$(uci -q get uhttpd.main.listen_http 2>/dev/null | sed -n '1s/.*[^0-9]\([0-9][0-9]*\)$/\1/p')
    [ -z "$luci_port" ] && luci_port=$(uci -q get uhttpd.main.listen_https 2>/dev/null | sed -n '1s/.*[^0-9]\([0-9][0-9]*\)$/\1/p')
    [ -z "$luci_port" ] && luci_port=80

    local luci_code=""
    for _scheme in http https; do
        luci_code=$(curl -sk -o /dev/null -m 4 -w '%{http_code}' \
            "$_scheme://127.0.0.1:${luci_port}/cgi-bin/luci/admin/services/acc/service" 2>/dev/null)
        [ -n "$luci_code" ] && [ "$luci_code" != "000" ] && break
    done

    case "$luci_code" in
        404)
            echo "  [FAIL] 页面返回 404：Lua 控制器未被加载 (菜单未注册)"
            echo "         修复: $(pkg_hint luci-compat luci-lua-runtime)"
            echo "               rm -f /tmp/luci-indexcache* && /etc/init.d/rpcd restart && /etc/init.d/uhttpd restart"
            errors=$((errors + 1))
            ;;
        200|301|302|401|403)
            echo "  [OK] 页面已注册 (HTTP $luci_code，未登录返回鉴权码属正常)"
            ;;
        000|"")
            echo "  [WARN] 无法从本机访问 LuCI (端口 $luci_port)，跳过页面探测"
            ;;
        *)
            echo "  [INFO] 页面返回 HTTP $luci_code"
            ;;
    esac

    for f in /usr/lib/lua/luci/ucodebridge.lua /usr/lib/lua/luci/cbi.lua /usr/lib/lua/luci/controller/acc.lua; do
        if [ -f "$f" ]; then
            echo "  [OK] $f"
        else
            echo "  [FAIL] 缺少 $f"
            errors=$((errors + 1))
        fi
    done
    if [ -f /usr/share/ucode/luci/dispatcher.uc ]; then
        echo "  [OK] ucode 调度器存在 (dispatcher.uc)"
    else
        echo "  [INFO] 未找到 /usr/share/ucode/luci/dispatcher.uc (非 25.12 结构)"
    fi

    # --- 3. LuCI files ---
    echo ""
    echo "[3/5] LuCI 文件完整性"
    local required_files="
        controller/acc.lua
        model/cbi/leigod/service.lua
        model/cbi/leigod/device.lua
        model/cbi/leigod/app.lua
        model/cbi/leigod/notice.lua
        model/cbi/leigod/autopause.lua
        model/cbi/leigod/debug.lua
        view/leigod/service.htm
        view/leigod/app.htm
        view/leigod/notice.htm
        view/leigod/autopause.htm
        view/leigod/debug.htm"
    local missing=""
    for f in $required_files; do
        if [ ! -f "$luci_src/$f" ]; then
            echo "  [FAIL] 缺失: $f"
            missing="$missing $f"
            errors=$((errors + 1))
        fi
    done
    if [ -z "$missing" ]; then
        echo "  [OK] 全部 12 个文件已就位"
    else
        echo "  → 修复: 确保 luci-fw4-patch/ 已上传到 /tmp/ 或 /root/"
        echo "  →      然后运行 leigod-fw4.sh，脚本将自动写入内联补丁"
    fi

    # --- 4. UCI config ---
    echo ""
    echo "[4/5] UCI 配置 (accelerator)"
    if [ -f /etc/config/accelerator ]; then
        local uci_ok=0
        if uci get accelerator.base >/dev/null 2>&1; then
            local neigh
            neigh=$(uci get accelerator.base.neigh 2>/dev/null)
            echo "  [OK] accelerator.base (neigh=$neigh)"
            uci_ok=$((uci_ok + 1))
        else
            echo "  [FAIL] accelerator.base 缺失"
            errors=$((errors + 1))
        fi
        if uci get accelerator.device >/dev/null 2>&1; then
            echo "  [OK] accelerator.device"
            uci_ok=$((uci_ok + 1))
        else
            echo "  [FAIL] accelerator.device 缺失"
            errors=$((errors + 1))
        fi
        if uci get accelerator.@system[0] >/dev/null 2>&1; then
            echo "  [OK] accelerator.@system[0] (服务配置)"
            uci_ok=$((uci_ok + 1))
        else
            echo "  [FAIL] accelerator.@system[0] 缺失"
            errors=$((errors + 1))
        fi
        # Check device-specific sections exist
        local dev_count
        # grep -c already prints 0 and exits 1 on no match — do not `|| echo 0`
        dev_count=$(uci show accelerator 2>/dev/null | grep -c "accelerator\.@device\[" 2>/dev/null)
        [ -n "$dev_count" ] || dev_count=0
        dev_count=$(printf '%s' "$dev_count" | head -1)
        echo "  [INFO] 设备条目数: $dev_count (0 = 首次安装/重装后正常)"
    else
        echo "  [FAIL] /etc/config/accelerator 文件不存在!"
        errors=$((errors + 1))
    fi

    # --- 5. auto-pause config ---
    echo ""
    echo "[5/5] 自动暂停配置"
    if [ -f /etc/leigod-auto-pause.conf ]; then
        . /etc/leigod-auto-pause.conf
        if [ -n "$ACCOUNT_TOKEN" ]; then
            echo "  [OK] /etc/leigod-auto-pause.conf (token 已配置)"
        else
            echo "  [WARN] /etc/leigod-auto-pause.conf (token 未配置)"
            echo "  → 通过 LuCI 自动暂停页面书签一键获取"
        fi
        if [ "$MANUAL_DISABLE" = "1" ]; then
            echo "  [INFO] 离家模式已启用 (自动暂停暂时禁用)"
        fi
    else
        echo "  [INFO] /etc/leigod-auto-pause.conf 未配置 (首次安装正常)"
    fi

    # --- Summary ---
    echo
    echo "============================="
    if [ "$errors" -eq 0 ]; then
        echo "  验证结果: [OK] LuCI 安装完整"
        return 0
    else
        echo "  验证结果: [FAIL] 发现 $errors 个问题"
        echo ""
        echo "  === 自动修复 ==="
        echo "  正在尝试自动修复..."
        local fixed=0

        # Fix: install the Lua compatibility layer
        for p in luci-compat luci-lua-runtime; do
            if ! pkg_installed "$p"; then
                echo "  → 安装 $p ..."
                pkg_update
                pkg_install_raw "$p" >/dev/null 2>&1 && \
                    { echo "  [OK] $p 已安装"; fixed=$((fixed + 1)); } || \
                    echo "  [WARN] $p 安装失败, 请手动安装"
            fi
        done

        # Fix: write missing LuCI files from inline patches
        if [ -n "$missing" ]; then
            echo "  → 写入内联补丁..."
            # Trigger the inline patching path of apply_luci_fw4_patch
            apply_luci_fw4_patch
            # Re-check
            local still_missing=""
            for f in $missing; do
                [ ! -f "$luci_src/$f" ] && still_missing="$still_missing $f"
            done
            if [ -z "$still_missing" ]; then
                echo "  [OK] 缺失文件已修复"
                fixed=$((fixed + 1))
            else
                echo "  [WARN] 以下文件仍缺失: $still_missing"
                echo "  → 请手动将 luci-fw4-patch/ 上传到 /tmp/ 后重试"
            fi
        fi

        # Fix: ensure UCI config
        ensure_uci_config

        # Clear LuCI dispatch cache and reload the web stack.
        # 25.12 keeps /tmp/luci-indexcache*; a stale cache hides new menu entries.
        rm -f /tmp/luci-indexcache* 2>/dev/null; rm -rf /tmp/luci-modulecache 2>/dev/null
        /etc/init.d/rpcd restart >/dev/null 2>&1
        /etc/init.d/uhttpd restart >/dev/null 2>&1
        echo "  → LuCI 缓存已清除 (rpcd/uhttpd 已重启)"

        if [ "$fixed" -gt 0 ]; then
            echo ""
            echo "  已自动修复 $fixed 个问题，请刷新 Web 页面"
        fi
        return 1
    fi
}

# ============================================================
# Service enable/disable
# ============================================================
service() {
    if [ ! -f /etc/init.d/acc ]; then
        echo "[ERROR] 雷神服务文件不存在，是不是还没安装捏."
        return
    fi

    if /etc/init.d/acc enabled; then
        /etc/init.d/acc disable
        /etc/init.d/acc stop
        echo "[INFO] LeigodAcc 服务已禁用并关闭"
    else
        /etc/init.d/acc enable
        /etc/init.d/acc start
        echo "[INFO] LeigodAcc 服务已启用并启动"
    fi
}

# ============================================================
# Switch mode (TUN/Tproxy)
# ============================================================
# ============================================================
# Acceleration config: layout detection + repair
# ============================================================
# Two on-disk layouts exist in the wild:
#
#   new    (acc-gw v1.2.2.x, 2026+)
#     /etc/config/acc_firewall.ini is authoritative:
#         [firewall]
#         backend=iptables|nftables
#         mode=tproxy|tun
#         tproxy_ip=10.20.30.40        (iptables)   <- fixed sentinel
#         tproxy_ip=0.0.0.0            (nftables)   <- fixed sentinel
#     The init script and monitor.sh read these three fields; tproxy_ip is a
#     dummy address the engine binds with IP_TRANSPARENT.  It is NOT the LAN IP
#     (the old manager patched the LAN IP in and broke the rule targets).
#     /tmp/acc/acc_core_conf.json is written by the engine itself.
#
#   legacy (acc-gw v1.2.2.13 and older)
#     No INI.  The init script hardcodes `-l <ip> -m <mode>` and
#     /tmp/acc/acc_core_conf.json acts as the source of truth; its tproxy_ip
#     must equal the router LAN IP or the web child crash-loops.
#
ACC_INI="/etc/config/acc_firewall.ini"
ACC_CORE_JSON="/tmp/acc/acc_core_conf.json"

acc_layout() {
    if [ -f "$ACC_INI" ]; then
        echo "new"
    else
        echo "legacy"
    fi
}

# Read one `key=value` from acc_firewall.ini (first match)
acc_ini_get() {
    [ -f "$ACC_INI" ] || return 1
    sed -n "s/^$1=//p" "$ACC_INI" 2>/dev/null | head -1
}

# Replace (or append) one `key=value` in acc_firewall.ini
acc_ini_set() {
    local key="$1" val="$2"
    [ -f "$ACC_INI" ] || return 1
    if grep -q "^$key=" "$ACC_INI" 2>/dev/null; then
        sed -i "s|^$key=.*|$key=$val|" "$ACC_INI"
    else
        printf '%s=%s\n' "$key" "$val" >> "$ACC_INI"
    fi
}

# Vendor sentinel value for tproxy_ip, per firewall backend
# (mirrors get_tproxy_ip_by_backend() in the official lib/setup.sh)
acc_default_tproxy_ip() {
    if [ "$1" = "nftables" ]; then
        echo "0.0.0.0"
    else
        echo "10.20.30.40"
    fi
}

acc_backend() {
    local b
    b=$(acc_ini_get backend 2>/dev/null)
    if [ -n "$b" ]; then
        echo "$b"
    elif command -v iptables >/dev/null 2>&1; then
        echo "iptables"
    else
        echo "nftables"
    fi
}

# Is the given TCP port in LISTEN state?
# Uses /proc/net/tcp directly: iStoreOS 25.12 has no `ss`, and netstat may be
# absent too.  /proc/net/tcp prints the port in hex (5588 -> 0x15D4).
port_listening() {
    local hex _f
    hex=$(printf '%04X' "$1" 2>/dev/null) || return 1
    [ -n "$hex" ] || return 1
    for _f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$_f" ] || continue
        if awk -v p=":$hex" '$4 == "0A" && substr($2, length($2) - length(p) + 1) == p { found = 1 } END { exit !found }' "$_f"; then
            return 0
        fi
    done
    return 1
}

restart_acc_service() {
    [ -x /etc/init.d/acc ] || return 0
    echo "[INFO] 重启 acc 服务以应用配置变更..."
    /etc/init.d/acc restart >/dev/null 2>&1
    sleep 5
    if port_listening 5588; then
        echo "[INFO] API 端口 5588 已监听，服务正常"
        return 0
    fi
    echo "[WARN] API 端口 5588 未监听，web 子进程可能仍在重启 (查看 /tmp/acc/log/web_api.log)"
    return 1
}

# The engine forks its web child roughly every 5s when it cannot start;
# acc_daemon.log then repeats "child process exit, ... status:0".
acc_web_crash_loop() {
    local n
    n=$(tail -60 /tmp/acc/log/acc_daemon.log 2>/dev/null | grep -c 'child process exit')
    [ "${n:-0}" -ge 3 ]
}

# Post-install / post-restart health check with actionable hints.
acc_health_check() {
    local i=0
    while [ "$i" -lt 20 ]; do
        if port_listening 5588; then
            echo "[INFO] API 端口 5588 已监听 (TCP, 0.0.0.0)"
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done

    echo "[ERROR] API 端口 5588 未监听 —— 手机 APP 将无法与 acc-gw 通信"
    echo "        进程状态: $(ps ww 2>/dev/null | grep -c '[a]cc-gw') 个 acc-gw 进程"

    if acc_web_crash_loop; then
        echo "[ERROR] 检测到 web 子进程崩溃循环 (acc_daemon.log 持续出现 child process exit)"
    fi

    if grep -q 'start global config manager failed' /tmp/acc/log/web_api.log 2>/dev/null; then
        echo "[ERROR] web 子进程报 'start global config manager failed'"
        echo "        含义: 插件拉取雷神全局配置失败 (resources.leigodtech.com / opapi.xxghh.biz)"
        echo "        常见原因: 双栈网络下 IPv6 不可达且客户端未回落 IPv4 / DNS 异常 / 上游接口故障"
        echo "        现场验证: curl -4 -m5 -o /dev/null -w 'v4=%{http_code}\\n' https://opapi.xxghh.biz/common/comm/dict/getDictItems/LeigodBox_GlobalConfig/"
        echo "                  curl -6 -m5 -o /dev/null -w 'v6=%{http_code}\\n' https://opapi.xxghh.biz/common/comm/dict/getDictItems/LeigodBox_GlobalConfig/"
    else
        echo "        排查: tail -30 /tmp/acc/log/web_api.log"
    fi
    echo "        重试: /etc/init.d/acc restart && sleep 8 && netstat -tlnp | grep 5588"
    return 1
}

# ============================================================
# Fix acceleration config (new layout: INI is authoritative)
# ============================================================
# Repairs only structural damage: missing keys, non-sentinel tproxy_ip,
# and a JSON/INI mismatch.  It never invents a LAN IP for tproxy_ip.
fix_acc_new_layout() {
    local backend mode tproxy_ip want_ip json_ip changed=0

    backend=$(acc_ini_get backend 2>/dev/null)
    mode=$(acc_ini_get mode 2>/dev/null)
    tproxy_ip=$(acc_ini_get tproxy_ip 2>/dev/null)

    if [ -z "$backend" ]; then
        backend=$(acc_backend)
        acc_ini_set backend "$backend"
        echo "[INFO] acc_firewall.ini 缺少 backend，已补为 $backend"
        changed=1
    fi
    if [ -z "$mode" ]; then
        mode="tproxy"
        acc_ini_set mode "$mode"
        echo "[INFO] acc_firewall.ini 缺少 mode，已补为 $mode"
        changed=1
    fi

    want_ip=$(acc_default_tproxy_ip "$backend")
    if [ -z "$tproxy_ip" ]; then
        acc_ini_set tproxy_ip "$want_ip"
        echo "[INFO] acc_firewall.ini 缺少 tproxy_ip，已按 backend=$backend 补为 $want_ip"
        changed=1
    elif [ "$tproxy_ip" != "$want_ip" ]; then
        echo "[WARN] acc_firewall.ini tproxy_ip=$tproxy_ip 不是 $backend 后端标准值"
        echo "[INFO] 已改为官方标准值 $want_ip (该字段是 TPROXY 转发目标，不是 LAN IP)"
        acc_ini_set tproxy_ip "$want_ip"
        changed=1
    fi

    # Align the engine JSON with the INI (never rewrite it to another value)
    if [ -f "$ACC_CORE_JSON" ]; then
        tproxy_ip=$(acc_ini_get tproxy_ip 2>/dev/null)
        json_ip=$(sed -n 's/.*"tproxy_ip":"\([^"]*\)".*/\1/p' "$ACC_CORE_JSON" 2>/dev/null | head -1)
        if [ -n "$tproxy_ip" ] && [ -n "$json_ip" ] && [ "$json_ip" != "$tproxy_ip" ]; then
            sed -i "s|\"tproxy_ip\":\"[^\"]*\"|\"tproxy_ip\":\"$tproxy_ip\"|" "$ACC_CORE_JSON" 2>/dev/null
            echo "[INFO] acc_core_conf.json tproxy_ip 已对齐 INI: $json_ip -> $tproxy_ip"
        fi
    fi

    if [ "$changed" = "1" ]; then
        restart_acc_service
    else
        echo "[INFO] 加速配置正常 (backend=$backend, mode=$mode, tproxy_ip=$(acc_ini_get tproxy_ip 2>/dev/null))"
    fi
    return 0
}

# ============================================================
# Fix acceleration config (legacy layout: JSON is authoritative)
# ============================================================
# acc-gw v1.2.2.13 and earlier: tproxy_ip in acc_core_conf.json must be the
# router LAN IP, and acc_mode must be 2 (TPROXY) — that build does not support
# TUN and crash-loops otherwise.
fix_acc_legacy_layout() {
    local conf="$ACC_CORE_JSON"
    [ ! -f "$conf" ] && return 0

    lan_ip=$(uci get network.lan.ipaddr 2>/dev/null)
    [ -z "$lan_ip" ] && return 0

    # Self-healing: daemon stuck in a stop_acc crash loop
    if pgrep -f "/usr/sbin/leigod/acc-gw" >/dev/null 2>&1; then
        local stops=$(tail -20 /tmp/acc/log/acc_daemon.log 2>/dev/null | grep -c 'stop_acc')
        if [ "$stops" -ge 2 ] 2>/dev/null; then
            echo "[WARN] 检测到 stop_acc 崩溃循环 (近20行含${stops}次stop), 强重启 daemon..."
            /etc/init.d/acc stop >/dev/null 2>&1
            pids=$(pgrep -f "/usr/sbin/leigod/acc-gw" 2>/dev/null)
            [ -n "$pids" ] && kill -9 $pids 2>/dev/null
            sleep 2
            /etc/init.d/acc start >/dev/null 2>&1
            sleep 4
            sed -i "s|\"tproxy_ip\":\"[^\"]*\"|\"tproxy_ip\":\"$lan_ip\"|" "$conf" 2>/dev/null
            echo "[INFO] Daemon 已强重启, JSON 已修复"
        fi
    fi

    current_ip=$(sed -n 's/.*"tproxy_ip":"\([^"]*\)".*/\1/p' "$conf" 2>/dev/null)
    current_mode=$(sed -n 's/.*"acc_mode":\([0-9]*\).*/\1/p' "$conf" 2>/dev/null)
    local fixed=0

    if [ "$current_ip" != "$lan_ip" ]; then
        echo "[WARN] acc_core_conf.json tproxy_ip 不正确: '$current_ip' (应为 LAN IP '$lan_ip')"
        sed -i "s|\"tproxy_ip\":\"[^\"]*\"|\"tproxy_ip\":\"$lan_ip\"|" "$conf"
        fixed=1
        echo "[INFO] acc_core_conf.json tproxy_ip 已修复为 $lan_ip"
    fi

    if [ -f /etc/init.d/acc ] && [ -n "$current_ip" ] && [ "$current_ip" != "$lan_ip" ]; then
        if grep -q -- "-l $current_ip" /etc/init.d/acc 2>/dev/null; then
            echo "[INFO] 同步修复 /etc/init.d/acc 中的 -l 参数..."
            sed -i "s|-l $current_ip|-l $lan_ip|g" /etc/init.d/acc
        fi
    fi

    if [ "$current_mode" != "2" ]; then
        echo "[WARN] acc_core_conf.json acc_mode=$current_mode 不稳定 (已知稳定值为 2)"
        if [ -z "$current_mode" ]; then
            sed -i 's|"acc_mode":[0-9]*|"acc_mode":2|' "$conf"
        else
            sed -i "s|\"acc_mode\":$current_mode|\"acc_mode\":2|" "$conf"
        fi
        fixed=1
        echo "[INFO] acc_core_conf.json acc_mode 已修正为 2"
    fi

    if [ -f /etc/init.d/acc ] && grep -qE -- "-m tun\b" /etc/init.d/acc 2>/dev/null; then
        echo "[INFO] 同步修复 /etc/init.d/acc 模式为 tproxy..."
        sed -i 's|-m tun|-m tproxy|' /etc/init.d/acc
        fixed=1
    fi

    if [ "$fixed" = "1" ] && [ -x /etc/init.d/acc ]; then
        if ! pgrep -f "/usr/sbin/leigod/acc-gw" >/dev/null 2>&1; then
            echo "[INFO] acc-gw 未运行, 启动服务..."
            /etc/init.d/acc start >/dev/null 2>&1
            sleep 4
            if port_listening 5588; then
                echo "[INFO] 端口 5588 已监听, 服务正常"
            else
                echo "[ERR] 端口 5588 未监听! 请手动排查: /etc/init.d/acc restart"
            fi
        else
            echo "[INFO] acc-gw 运行中, JSON 配置已修复 (无需重启以免中断加速)"
        fi
    fi
}

# Unified entry point — keeps the historical name for cron/CLI compatibility
fix_acc_core_conf() {
    case "$(acc_layout)" in
        new)    fix_acc_new_layout ;;
        legacy) fix_acc_legacy_layout ;;
    esac
}

# ============================================================
# Install tproxy_ip watcher cron job
# The acc-gw binary hardcodes a fake tproxy_ip (10.20.30.40)
# and regenerates acc_core_conf.json on each daemon restart,
# overwriting manual fixes. This cron checks every 5 minutes
# and auto-repairs tproxy_ip + acc_mode.
# ============================================================
install_tproxy_watcher() {
    local watcher_cron="*/5 * * * * /usr/sbin/leigod/leigod-fw4.sh fix-tproxy >/dev/null 2>&1"
    local cron_file="/etc/crontabs/root"

    # Ensure self is deployed to the path referenced by the cron job
    if [ ! -f /usr/sbin/leigod/leigod-fw4.sh ] && [ -f "$0" ]; then
        cp "$0" /usr/sbin/leigod/leigod-fw4.sh
        chmod +x /usr/sbin/leigod/leigod-fw4.sh
        echo "[INFO] 已部署脚本到 /usr/sbin/leigod/leigod-fw4.sh"
    fi

    # Skip if already installed
    if grep -q "leigod-fw4.sh fix-tproxy" "$cron_file" 2>/dev/null; then
        return 0
    fi

    echo "$watcher_cron" >> "$cron_file"
    /etc/init.d/cron restart 2>/dev/null
    echo "[INFO] 加速配置守护 cron 已安装 (每5分钟检查 INI/JSON 一致性)"
}

remove_tproxy_watcher() {
    sed -i '/leigod-fw4.sh fix-tproxy/d' /etc/crontabs/root 2>/dev/null
}

switch_mode() {
    if [ ! -f /etc/init.d/acc ]; then
        echo "[ERROR] 雷神服务文件不存在，是不是还没安装捏."
        return
    fi

    echo "当前版本可能不支持切换模式"
    echo

    if [ "$(acc_layout)" = "new" ]; then
        # New layout: mode lives in /etc/config/acc_firewall.ini and the init
        # script builds its args from it (args="-r daemon -m ${mode} -p 5588").
        # Editing the init script directly would corrupt that template.
        local cur new_mode
        cur=$(acc_ini_get mode 2>/dev/null)
        if [ "$cur" = "tun" ]; then
            new_mode="tproxy"
        else
            new_mode="tun"
        fi

        acc_ini_set mode "$new_mode"
        echo "[INFO] acc_firewall.ini mode: ${cur:-未设置} -> $new_mode"

        # Keep tproxy_ip on the vendor sentinel for the active backend
        local backend want_ip cur_ip
        backend=$(acc_backend)
        want_ip=$(acc_default_tproxy_ip "$backend")
        cur_ip=$(acc_ini_get tproxy_ip 2>/dev/null)
        if [ "$cur_ip" != "$want_ip" ]; then
            acc_ini_set tproxy_ip "$want_ip"
            echo "[INFO] tproxy_ip 已按 backend=$backend 校正为 $want_ip"
        fi

        if [ "$new_mode" = "tun" ]; then
            echo "[WARN] 新版引擎以 TPROXY 为主；TUN 模式可能与 fw4 规则/APP 行为不同，请实测"
        fi

        /etc/init.d/acc restart >/dev/null 2>&1
        sleep 5
        if port_listening 5588; then
            echo "[INFO] 已切换并重启，API 端口 5588 正常监听"
        else
            echo "[WARN] 已切换并重启，但 5588 未监听 (查看 /tmp/acc/log/web_api.log)"
        fi
        install_tproxy_watcher
        return 0
    fi

    if pkg_installed "leigod-acc"; then
        # Get tun option from the anonymous system section.
        # The "base" named section stores the neigh interface, not the
        # TUN flag, so accelerator.base.tun would be empty/wrong.
        # accelerator.@system[-1] targets the last system section
        # (the anonymous service-config section).
        current_tun=$(uci -q get accelerator.@system[-1].tun 2>/dev/null)

        if [ "$current_tun" = "1" ]; then
            uci set accelerator.@system[-1].tun='0'
            echo "[INFO] 已切换为 tproxy 模式"
        else
            uci set accelerator.@system[-1].tun='1'
            echo "[INFO] 已切换为 tun 模式"
        fi

        uci commit accelerator
    else
        cp /etc/init.d/acc /etc/init.d/acc.bak 2>/dev/null

        # Normalize legacy GNU long-format mode flags.
        # The acc-gw binary only recognizes the short form (-m tun / -m tproxy).
        # The official installer writes --mode tun which the binary silently
        # ignores, defaulting to TPROXY.
        if grep -q -- "--mode tun" /etc/init.d/acc; then
            sed -i 's|--mode tun|-m tun|' /etc/init.d/acc
            echo "[INFO] 已修正旧格式 --mode tun → -m tun"
        elif grep -q -- "--mode tproxy" /etc/init.d/acc; then
            sed -i 's|--mode tproxy|-m tproxy|' /etc/init.d/acc
            echo "[INFO] 已修正旧格式 --mode tproxy → -m tproxy"
        fi

        if grep -qE -- "-m tun\b" /etc/init.d/acc; then
            # TUN → TPROXY: replace mode flag only, preserve other params
            sed -i 's|-m tun|-m tproxy|' /etc/init.d/acc
            if ! grep -q -- "-p " /etc/init.d/acc; then
                sed -i 's|-m tproxy|-m tproxy -p 5588|' /etc/init.d/acc
                echo "[INFO] 已恢复默认 API 端口 (-p 5588)"
            fi
            echo "[INFO] 已切换为 tproxy 模式"
        else
            # TPROXY → TUN: replace mode flag only, preserve other params
            if grep -qE -- "-m tproxy\b" /etc/init.d/acc; then
                sed -i 's|-m tproxy|-m tun|' /etc/init.d/acc
            else
                # No recognizable mode flag — insert -m tun
                sed -i 's|args="|args="-m tun |' /etc/init.d/acc
            fi
            if ! grep -q -- "-p " /etc/init.d/acc; then
                sed -i 's|-m tun|-m tun -p 5588|' /etc/init.d/acc
                echo "[INFO] 已恢复默认 API 端口 (-p 5588)"
            fi
            echo "[INFO] 已切换为 tun 模式"
        fi
    fi

    if [ "$FW_TYPE" = "fw4" ]; then
        echo "[INFO] fw4/nftables 环境 — 旧版引擎建议保持 TPROXY"
    fi

    /etc/init.d/acc stop
    /etc/init.d/acc start
    echo "[INFO] 已经重启 LeigodAcc 服务"

    # Legacy layout: the daemon may regenerate the JSON on start
    sleep 3
    if [ -f "$ACC_CORE_JSON" ]; then
        fix_acc_core_conf
    fi
    install_tproxy_watcher
}

# ============================================================
# Disable/Enable IPv6
# ============================================================
disabled_ipv6() {
    config_file="/etc/config/dhcp"
    option_dhcpv6=$(uci get dhcp.lan.dhcpv6 2>/dev/null)
    option_ra=$(uci get dhcp.lan.ra 2>/dev/null)

    if [ "$option_dhcpv6" = "disabled" ] && [ "$option_ra" = "disabled" ]; then
        uci set dhcp.lan.ra='server'
        uci set dhcp.lan.dhcpv6='server'
        uci delete dhcp.lan.ra_flags
        uci add_list dhcp.lan.ra_flags='managed-config'
        uci add_list dhcp.lan.ra_flags='other-config'
        echo "[INFO] IPv6 已启用"
        echo "[INFO] 该功能只在 LEDE/QWRT/CatWrt 中测试"
        echo "[INFO] 其他 OpenWrt 版本可能需要在 Luci 界面中启用其他 IPv6 选项以获取正常的 IPv6 网络支持"
    else
        uci delete dhcp.lan.ra_flags
        uci set dhcp.lan.ra='disabled'
        uci set dhcp.lan.dhcpv6='disabled'
        uci add_list dhcp.lan.ra_flags='none'
        echo "[INFO] IPv6 已禁用"
        echo "[INFO] iOS/Android 设备请忘记无线 Wi-Fi 网络再连接，插件内就会自动识别"
    fi

    uci commit dhcp
    /etc/init.d/odhcpd restart
}

# ============================================================
# Install Lean IPKG version
# ============================================================
install_lean_ipkg_version() {
    # OpenWrt 25.12+ / iStoreOS 25.12 switch to apk and only accept .apk
    # packages. The upstream Lean build is only published as .ipk, so this
    # option cannot work there — fail fast with a clear explanation.
    if [ "$PKG_MGR" = "apk" ]; then
        echo ""
        echo "=========================================="
        echo "  [不支持] Lean IPKG 版"
        echo "=========================================="
        echo "  当前系统使用 apk 包管理器 (OpenWrt 25.12+ / iStoreOS 25.12)。"
        echo "  Lean 版插件仅提供 .ipk 格式，apk 无法安装 .ipk 包。"
        echo ""
        echo "  请改用菜单选项 1 (官方安装脚本)，功能一致且已做 fw4 适配。"
        echo "=========================================="
        echo ""
        return 1
    fi

    if pkg_installed "leigod-acc"; then
        echo "[INFO] leigod-acc 已安装"
        return
    else
        echo "[INFO] leigod-acc 未安装"
        if [ -f /var/lock/opkg.lock ]; then
            if pgrep -f "opkg " > /dev/null 2>&1; then
                echo "[WARN] 检测到其他 opkg 进程正在运行，等待完成..."
                sleep 3
            fi
            rm -f /var/lock/opkg.lock
        fi
        if ! check_network; then
            echo "[WARN] 网络不可达，后续依赖安装及下载可能会失败"
            echo -n "是否继续? (y/n): "
            read proceed
            [ "$proceed" != "y" ] && [ "$proceed" != "Y" ] && return
        fi
    fi

    if [ -d /usr/sbin/leigod ]; then
        echo -n "[INFO] 检测到已经安装 LeigodAcc 普通版本，请返回管理器卸载后再继续!"
        return
    fi

    if ! check_disk_space; then
        return 1
    fi

    # Try to detect latest release tag from GitHub API (lightweight, 5s timeout).
    # Falls back to v1.3 on any failure.
    LEIGOD_RELEASE="v1.3"
    echo "[INFO] 正在查询最新版本..."
    _latest=$(curl -sL --connect-timeout 5 \
        "https://api.github.com/repos/miaoermua/openwrt-leigodacc-manager/releases/latest" \
        2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    if [ -n "$_latest" ]; then
        LEIGOD_RELEASE="$_latest"
        echo "[INFO] 检测到最新版本: $LEIGOD_RELEASE"
    else
        echo "[INFO] 无法获取最新版本 (GitHub API 可能限流或网络不可达)，使用默认版本: $LEIGOD_RELEASE"
    fi

    # Use firewall-appropriate package list
    required_packages="$PKG_LIBPCAP $PKG_IPTABLES $PKG_NAT $PKG_TPROXY"
    [ -n "$PKG_IPT_TPROXY_MOD" ] && required_packages="$required_packages $PKG_IPT_TPROXY_MOD"
    [ -n "$PKG_IPSET" ] && required_packages="$required_packages $PKG_IPSET"
    [ -n "$PKG_IPSET_TOOL" ] && required_packages="$required_packages $PKG_IPSET_TOOL"
    required_packages="$required_packages kmod-tun curl $PKG_UPNP tc-full kmod-netem conntrack conntrackd"

    missing_packages=""

    echo "[INFO] 检查在线软件源中是否存在所有依赖包..."
    for package in $required_packages; do
        if ! pkg_available "$package"; then
            echo "[ERROR] 在线软件源中缺少依赖包: $package"
            missing_packages="$missing_packages $package"
        fi
    done

    if [ -n "$missing_packages" ]; then
        echo "[ERROR] 检测到在线软件源中缺少的依赖包，无法继续安装: $missing_packages"
        echo "你的设备暂不支持 Lean 版 IPKG 插件，尝试使用第一方带有依赖的 CatWrt 来安装 IPKG 版本吧，或者使用管理器中的普通安装选项"
        echo "访问以下链接获取 mt7621 & amd64(x86_64) 版本"
        echo
        echo "https://www.miaoer.net/posts/network/catwrt"
        sleep 5
        return 1
    fi

    echo "[INFO] 所有依赖包已在在线软件源中找到，正在安装缺失的依赖包..."

    PKG_FAILED=""
    for package in $required_packages; do
        if ! pkg_installed "$package"; then
            safe_pkg_install "$package"
        fi
    done

    if [ -n "$PKG_FAILED" ]; then
        echo "[ERROR] 以下依赖包安装失败:$PKG_FAILED"
        echo "[ERROR] 请检查网络连接和软件源配置后重试"
        return 1
    fi

    echo "[INFO] 所有依赖包已安装！"

    # fw4: ensure TPROXY kernel support (with fallback) before installing IPK
    if ! ensure_fw4_tproxy; then
        echo "[WARN] TPROXY 不可用。注意: 部分 acc-gw 版本仅支持 TPROXY，此情况下加速将无法工作"
    fi
    setup_fw4_integration
    apply_luci_fw4_patch

    arch=$(pkg_arch)

    if pkg_available "leigod-acc"; then
        echo "[INFO] 软件源中检测到 leigod-acc 插件，正在安装..."
        safe_pkg_install leigod-acc luci-app-leigod-acc luci-i18n-leigod-acc-zh-cn
        echo "[INFO] Lean 版本 leigod-acc 安装成功！"
    else
        echo "[INFO] 在线软件源中没有找到 leigod-acc 包，将从 GitHub Releases 下载"

        case "$arch" in
            "aarch64_cortex-a53"|"aarch64_cortex-a53+crypto")
                url="https://github.com/miaoermua/openwrt-leigodacc-manager/releases/download/${LEIGOD_RELEASE}/leigod-acc_1.3.0.30-1_aarch64_cortex-a53.ipk"
                ;;
            "aarch64_generic"|"aarch64_cortex-a72"|"aarch64_cortex-a76"|"aarch64_cortex-a55"|"aarch64_cortex-a73")
                url="https://github.com/miaoermua/openwrt-leigodacc-manager/releases/download/${LEIGOD_RELEASE}/leigod-acc_1.3.0.30-1_aarch64_generic.ipk"
                ;;
            "mipsel_24kc")
                url="https://github.com/miaoermua/openwrt-leigodacc-manager/releases/download/${LEIGOD_RELEASE}/leigod-acc_1.3.0.30-1_mipsel_24kc.ipk"
                ;;
            "x86_64")
                url="https://github.com/miaoermua/openwrt-leigodacc-manager/releases/download/${LEIGOD_RELEASE}/leigod-acc_1.3.0.30-1_x86_64.ipk"
                ;;
            *)
                echo "[ERROR] 不支持的架构: $arch"
                return 1
                ;;
        esac

        echo "[INFO] 正在下载 leigod-acc 包: $url"
        echo
        mkdir -p /tmp/upload
        wget -P /tmp/upload "$url" || {
            echo "[ERROR] 下载 leigod-acc 失败，请检查网络或访问 GitHub 确认版本"
            return 1
        }
        wget -P /tmp/upload "https://github.com/miaoermua/openwrt-leigodacc-manager/releases/download/${LEIGOD_RELEASE}/luci-app-leigod-acc_1-3_all.ipk" 2>/dev/null || \
            echo "[WARN] luci-app-leigod-acc 下载失败, LuCI 界面将不可用"
        wget -P /tmp/upload "https://github.com/miaoermua/openwrt-leigodacc-manager/releases/download/${LEIGOD_RELEASE}/luci-i18n-leigod-acc-zh-cn_1-3_all.ipk" 2>/dev/null || \
            echo "[WARN] luci-i18n 下载失败, 界面将使用英文"

        safe_opkg_install /tmp/upload/leigod-acc_*.ipk /tmp/upload/luci-app-leigod-acc_*.ipk /tmp/upload/luci-i18n-leigod-acc-zh-cn_*.ipk
        echo

        if [ ! -d /usr/sbin/leigod ]; then
            echo "[ERROR] 检测到 LeigodAcc 未安装，有可能是设备存储空间已满或者雷神服务器挂了!"
            echo "请登录 OpenWrt 路由器后台: 系统-软件包 查看当前可用空间诊断."
            return 1
        else
            echo "[INFO] Lean IPKG 插件版 leigod-acc 已成功安装!"

            # Normalize legacy long-format mode flags to short format
            if grep -q -- "--mode tun" /etc/init.d/acc 2>/dev/null; then
                sed -i 's|--mode tun|-m tun|' /etc/init.d/acc
                echo "[INFO] 已修正加速模式参数格式 (--mode tun → -m tun)"
            elif grep -q -- "--mode tproxy" /etc/init.d/acc 2>/dev/null; then
                sed -i 's|--mode tproxy|-m tproxy|' /etc/init.d/acc
                echo "[INFO] 已修正加速模式参数格式 (--mode tproxy → -m tproxy)"
            fi

            setup_iptables_nft_compat

            # Re-apply fw4 LuCI patches (IPK install may have overwritten them)
            apply_luci_fw4_patch
            echo ""
            echo "=========================================="
            echo "  [注意] LuCI Web 界面说明"
            echo "=========================================="
            echo "  LuCI Web 界面已应用 fw4 适配补丁。"
            echo "  IPK 安装可能覆盖了补丁文件，已自动重新应用。"
            echo ""
            echo "  - 服务状态: LuCI 服务页显示防火墙类型"
            echo "  - 自动暂停: LuCI 已集成自动暂停配置页"
            echo "  - 防火墙集成: 已自动配置 fw4 hotplug"
            echo "=========================================="
            echo ""
        fi
    fi

    if ! pkg_installed "$PKG_LUCI_UPNP"; then
        safe_pkg_install "$PKG_LUCI_UPNP"
    fi

    if [ -f /etc/config/upnpd ]; then
        echo "[INFO] 正在启用 UPnP..."
        uci set upnpd.config.enabled='1'
        uci commit upnpd

        /etc/init.d/miniupnpd start
        /etc/init.d/miniupnpd enable

        echo "[INFO] UPnP 已启用并运行"
        echo "安装成功后可以在雷神加速器 APP 发现并绑定设备"
        echo
    else
        echo "[ERROR] UPnP 配置不存在，安装可能失败，请检查固件是否存在问题!"
        return 1
    fi

    if [ "$FW_TYPE" = "fw4" ]; then
        echo ""
        echo "=========================================="
        echo "  [重要] fw4 防火墙 — 环境适配"
        echo "=========================================="
        echo "  当前系统使用 fw4/nftables 防火墙。"
        echo "  请确保 acc_core_conf.json 中 tproxy_ip"
        echo "  正确设置为路由器 LAN IP。"
        echo ""
        echo "  运行菜单选项 S (诊断) 可自动检测和修复。"
        echo "=========================================="
        echo ""

        # Initialize UCI config for LuCI pages
        ensure_uci_config
        # Fix acc_core_conf.json if needed (covers both fresh and re-installs)
        fix_acc_core_conf
        # Install tproxy_ip watcher cron
        install_tproxy_watcher

        echo -n "是否需要检查服务运行状态? (y/n, 默认 n): "
        read check_status
        case "$check_status" in
            [Yy]|[Yy][Ee][Ss])
                check_service_status
                ;;
            *)
                echo "[INFO] 可稍后通过菜单选项 S 查看"
                ;;
        esac
        echo ""
    fi
}

# ============================================================
# Diagnostic functions
# ============================================================
check_logs() {
    if ! pkg_installed "tc-full"; then
        return 0
    fi

    if grep -q "exec tc command failed" /tmp/acc/acc-gw.log-* 2>/dev/null && grep -q "No such file or directory" /tmp/acc/acc-gw.log-* 2>/dev/null; then
        echo "[ERROR] 检测到插件中的 tc-full 组件出现了 'exec tc command failed' 错误，可能是软件源或者固件提供的 tc-full 组件问题"
        echo "可能导致无法加速的问题，由于实装 tc-full 的用户过少，请自行测试加速问题或手动重装 tc-full 组件"
        echo "# apk 系统: apk fix tc-full 或 apk add --force-overwrite tc-full"
        echo "# opkg 系统: opkg update && opkg remove tc-full && opkg install tc-full"
        echo
        sleep 5
    fi
}

check_acceleration() {
    # Iterate over glob-expanded log files (avoids [ -f glob ] pitfall)
    for log_file in /tmp/acc/acc-gw.log-*.log; do
        [ -f "$log_file" ] || continue

        if ! grep -q "S5 UDP" "$log_file" 2>/dev/null; then
            continue
        fi

        # BusyBox-compatible: use date -r <file> instead of date -d <string>
        log_mtime=$(date -r "$log_file" +%s 2>/dev/null)
        [ -z "$log_mtime" ] && continue

        now=$(date +%s)
        if [ $((now - log_mtime)) -lt 30 ]; then
            echo "[INFO] 检测到 UDP 被成功代理，加速成功"
            return 0
        fi
    done
    return 1
}

check_openclash_mode() {
    pgrep -f "openclash" > /dev/null 2>&1 || return 0

    config_dir="/etc/openclash"
    config_files=""
    for f in "$config_dir"/*.yaml; do
        [ -f "$f" ] || continue
        config_files="$config_files $f"
    done

    if [ -z "$config_files" ]; then
        return 0
    fi

    for config_file in $config_files; do
        mode=$(grep -E "^mode:" "$config_file" | awk '{print $2}')
        enhanced_mode=$(grep -E "^ *enhanced-mode:" "$config_file" | cut -d':' -f2 | xargs)

        if [ -z "$mode" ] || [ -z "$enhanced_mode" ]; then
            continue
        fi

        if [ "$mode" = "rule" ] && [ "$enhanced_mode" = "redir-host" ];then
            if grep -q "^tun:" "$config_file"; then
                echo "[WARN] 运行模式可能存在冲突!"
                echo "========================="
                echo "OpenClash 运行在 Redir-Host 未处于兼容模式(Tproxy)"
                echo "你需要调整 OpenClash 的运行模式为 '兼容'，请移除 TUN 配置以避免 leigod-acc 冲突。"
                echo
                echo "[Tip] 当你 OpenClash 为兼容模式(Tproxy),Leigod 需要切换运行模式以避免冲突。请通过选项 S 诊断确认 tproxy_ip 是否正确。"
            fi
        else
            echo "[WARN] 运行模式冲突!"
            echo "=================="
            echo "检查到 OpenClash 运行在 Fake-IP 未处于 Redir-Host 兼容模式(Tproxy)"
            echo "需要调整 OpenClash 的运行模式为 '兼容'，请移除 Fake-IP 配置以避免 leigod-acc 冲突!"
            echo
            echo "OC > 插件设置 > 模式设置 > 切换页面到 Redir-Host 模式"
            echo
            echo "[Tip] 当你 OpenClash 为兼容模式(Tproxy),Leigod 需要切换运行模式以避免冲突。请通过选项 S 诊断确认 tproxy_ip 是否正确。"
            sleep 5
        fi
    done

    if [ "$FW_TYPE" = "fw4" ]; then
        echo "[INFO] fw4 系统检测：OpenClash 与 LeigodAcc 同时运行时，"
        echo "建议检查 acc_core_conf.json tproxy_ip 是否为正确 LAN IP，以避免 nftables 规则冲突"
    fi
}

check_bypass_gateway() {
    lan_gateway=$(uci get network.lan.gateway 2>/dev/null)
    lan_ipaddr=$(uci get network.lan.ipaddr 2>/dev/null)

    lan_network=$(echo "$lan_ipaddr" | awk -F. '{print $1"."$2"."$3}')
    gateway_network=$(echo "$lan_gateway" | awk -F. '{print $1"."$2"."$3}')

    if [ -n "$lan_gateway" ] && [ "$lan_gateway" != "0.0.0.0" ] && [ "$lan_gateway" != "$lan_ipaddr" ] && [ "$lan_network" = "$gateway_network" ]; then
        echo "[Tip] 检测到旁路网关配置:"
        echo "当前路由器IP: $lan_ipaddr"
        echo "配置的网关: $lan_gateway"
        echo
        echo "注意: 您正在使用旁路网关模式，需要特别注意以下事项:"
        echo "如果是单臂路由(网关不互指):"
        echo "需要在加速设备上配置安装加速器插件的网关&路由器地址"
        echo "如果是双软路由(网关互指):"
        echo "仅需要关闭主路由上的 UPnP 功能"
        echo
        sleep 5
    fi
}

check_service_status() {
    echo
    echo "============================="
    echo "  LeigodAcc 服务状态"
    echo "============================="
    echo "防火墙: $FW_NAME"

    # Installation status
    if [ -f /etc/init.d/acc ] && [ -d /usr/sbin/leigod ]; then
        echo "安装状态: 已安装"
    elif [ -f /etc/init.d/acc ] || [ -d /usr/sbin/leigod ]; then
        echo "安装状态: 部分安装 (状态异常!)"
    else
        echo "安装状态: 未安装"
        echo
        echo "请先使用选项 1 或 8 安装雷神加速器"
        return 0
    fi

    # Service running status
    # The init script's running() may not detect acc-gw on all systems.
    # Fall back to checking the process table directly.
    if /etc/init.d/acc running >/dev/null 2>&1; then
        echo "服务状态: 运行中"
    elif ps | grep -q "[a]cc-gw"; then
        echo "服务状态: 运行中 (init script 检测异常，但进程存在)"
    else
        echo "服务状态: 已停止"
    fi
    if /etc/init.d/acc enabled >/dev/null 2>&1; then
        echo "开机自启: 已启用"
    else
        echo "开机自启: 已禁用"
    fi

    # Current mode
    echo -n "加速模式: "
    if [ -d /usr/sbin/leigod ]; then
        if [ "$(acc_layout)" = "new" ]; then
            echo "$(acc_ini_get mode 2>/dev/null) (acc_firewall.ini)"
        elif grep -qE -- "-m tun\b" /etc/init.d/acc 2>/dev/null; then
            echo "TUN"
        elif grep -qE -- "-m tproxy\b" /etc/init.d/acc 2>/dev/null; then
            echo "TPROXY"
        elif grep -q -- '${mode}' /etc/init.d/acc 2>/dev/null; then
            echo "$(acc_ini_get mode 2>/dev/null) (init 模板 \${mode})"
        else
            echo "未知 (检查 /etc/init.d/acc 或 acc_firewall.ini)"
        fi
    else
        echo "N/A"
    fi

    # Firewall backend / tproxy target from the INI (new layout only)
    if [ "$(acc_layout)" = "new" ]; then
        echo "防火墙后端: $(acc_backend) / tproxy_ip: $(acc_ini_get tproxy_ip 2>/dev/null)"
    fi

    # acc-gw binary status
    if pgrep -f "/usr/sbin/leigod/acc-gw" >/dev/null 2>&1; then
        acc_pid=$(pgrep -f "/usr/sbin/leigod/acc-gw" | head -1)
        echo "acc-gw 进程: 运行中 (PID: $acc_pid)"
        # Check if acc-gw is listening on the API port
        if port_listening 5588; then
            echo "API 端口: TCP 5588 监听中"
        else
            echo "API 端口: TCP 5588 未监听! (手机APP将无法通信)"
            if acc_web_crash_loop; then
                echo "  → 检测到 web 子进程崩溃循环 (acc_daemon.log 反复 child process exit)"
                if grep -q 'start global config manager failed' /tmp/acc/log/web_api.log 2>/dev/null; then
                    echo "  → 原因线索: 拉取雷神全局配置失败 (resources.leigodtech.com / opapi.xxghh.biz)"
                    echo "  → 可尝试: /etc/init.d/acc restart (若为瞬时网络故障)"
                fi
            fi
        fi
    else
        echo "acc-gw 进程: 未运行"
    fi

    # Device acceleration states — check multiple sources:
    #  1. UCI accelerator.*.state (traditional)
    #  2. Running acc-gw child processes (most reliable)
    #  3. acc_core_conf.json acceleration list
    echo
    echo "设备加速状态:"
    # Collect active device types from running acc sub-processes
    local active_devs=""
    acc_procs=$(ps 2>/dev/null | grep "[a]cc-gw.*-r acc" | grep -o "\-t [A-Za-z]*" | awk '{print $2}')
    for dev in Phone PC Game Unknown; do
        local label="无设备"
        # Check UCI first
        dev_state=$(uci get "accelerator.${dev}.state" 2>/dev/null)
        case "$dev_state" in
            1) label="加速中" ;;
            2) label="已停止" ;;
            3) label="已暂停" ;;
        esac

        # Fallback: check running acc processes (more reliable than UCI)
        if [ "$label" = "无设备" ] && echo "$acc_procs" | grep -q "$dev"; then
            label="加速中 (进程检测)"
        fi

        echo "  $dev: $label"
    done

    # If nothing detected via UCI/processes, check JSON
    json_accel=$(sed -n 's/.*"acceleration":\[\([^]]*\)\].*/\1/p' /tmp/acc/acc_core_conf.json 2>/dev/null)
    if [ -n "$json_accel" ]; then
        echo "  JSON中: [$json_accel]"
    fi

    # Auto-pause status
    echo
    if [ -f "$AUTO_PAUSE_CONF" ]; then
        echo "自动暂停: 已配置"
        if grep -q "leigod-auto-pause" "$AUTO_PAUSE_CRON" 2>/dev/null; then
            echo "  cron: 已启用 (每2分钟)"
        else
            echo "  cron: 未启用"
        fi
        if [ -f /tmp/leigod-auto-pause.state ]; then
            local idc lp
            idc=$(grep idle_count /tmp/leigod-auto-pause.state 2>/dev/null | cut -d= -f2)
            lp=$(grep last_pause_epoch /tmp/leigod-auto-pause.state 2>/dev/null | cut -d= -f2)
            echo "  空闲计数: ${idc:-0}"
            if [ -n "$lp" ] && [ "$lp" != "0" ]; then
                echo "  上次暂停: $(date -d @"$lp" '+%m-%d %H:%M:%S' 2>/dev/null || date -r "$lp" '+%m-%d %H:%M:%S' 2>/dev/null || echo "$lp")"
            fi
        fi
    else
        echo "自动暂停: 未配置 (选项 9)"
    fi

    # Recent errors in log
    echo
    echo "最近日志 (异常):"
    if ls /tmp/acc/acc-gw.log-*.log >/dev/null 2>&1; then
        err_count=$(grep -i -E "error|fail|timeout|exec tc" /tmp/acc/acc-gw.log-*.log 2>/dev/null | tail -5 | wc -l)
        if [ "$err_count" -gt 0 ]; then
            grep -i -E "error|fail|timeout|exec tc" /tmp/acc/acc-gw.log-*.log 2>/dev/null | tail -5
        else
            echo "  (无)"
        fi
    else
        echo "  (无日志文件)"
    fi

    # Check acc_core_conf.json for invalid tproxy_ip
    echo
    local acc_conf="/tmp/acc/acc_core_conf.json"
    if [ -f "$acc_conf" ]; then
        local conf_tproxy_ip conf_acc_mode
        conf_tproxy_ip=$(sed -n 's/.*"tproxy_ip":"\([^"]*\)".*/\1/p' "$acc_conf" 2>/dev/null)
        conf_acc_mode=$(sed -n 's/.*"acc_mode":\([0-9]*\).*/\1/p' "$acc_conf" 2>/dev/null)
        lan_ip=$(uci get network.lan.ipaddr 2>/dev/null)

        if [ "$(acc_layout)" = "new" ]; then
            # New layout: tproxy_ip is a backend-specific sentinel, not the LAN IP
            ini_ip=$(acc_ini_get tproxy_ip 2>/dev/null)
            want_ip=$(acc_default_tproxy_ip "$(acc_backend)")
            if [ "$conf_tproxy_ip" != "$ini_ip" ]; then
                echo "⚠ acc_core_conf.json tproxy_ip=$conf_tproxy_ip 与 INI($ini_ip) 不一致"
                echo "  正在对齐..."
                fix_acc_core_conf
            else
                echo "acc_core_conf.json: 正常 (tproxy_ip=$conf_tproxy_ip, acc_mode=$conf_acc_mode)"
                echo "acc_firewall.ini: backend=$(acc_backend), mode=$(acc_ini_get mode 2>/dev/null), tproxy_ip=$ini_ip (标准值 $want_ip)"
            fi
        elif [ "$conf_tproxy_ip" != "$lan_ip" ] && [ -n "$lan_ip" ]; then
            echo "⚠ acc_core_conf.json tproxy_ip 异常: '$conf_tproxy_ip' (应为 LAN IP '$lan_ip')"
            echo "  旧版引擎会导致 Web 子进程崩溃、加速几秒后断开!"
            echo "  正在自动修复..."
            fix_acc_core_conf
        elif [ "$conf_acc_mode" = "1" ]; then
            echo "⚠ acc_core_conf.json acc_mode=1 (TUN) — 旧版二进制仅支持 TPROXY"
            echo "  正在自动修复..."
            fix_acc_core_conf
        else
            echo "acc_core_conf.json: 正常 (tproxy_ip=$conf_tproxy_ip, acc_mode=$conf_acc_mode)"
        fi
    fi

    # fw4 specific note
    if [ "$FW_TYPE" = "fw4" ]; then
        echo
        if [ -f /etc/hotplug.d/firewall/99-leigodacc-restart ]; then
            echo "[INFO] fw4 hotplug 脚本已安装"
        else
            echo "[INFO] fw4 hotplug 脚本未安装，防火墙重载后可能丢失加速规则"
            echo "  运行 '安装' 或 '重装' 将自动配置"
        fi

        # Ensure firewall allows phone → acc-gw API (TCP 5588)
        if ! grep -q "LeigodAcc" /etc/config/firewall 2>/dev/null; then
            echo "[INFO] 防火墙规则缺失，正在添加 LAN→TCP 5588 规则..."
            uci add firewall rule
            uci set firewall.@rule[-1].name='LeigodAcc'
            uci set firewall.@rule[-1].src='lan'
            uci set firewall.@rule[-1].dest_port='5588'
            uci set firewall.@rule[-1].proto='tcp'
            uci set firewall.@rule[-1].target='ACCEPT'
            uci commit firewall
            /etc/init.d/firewall restart >/dev/null 2>&1
            echo "[INFO] 防火墙规则已添加（下次状态检查生效）"
        fi
    fi
    echo "============================="
}

# ============================================================
# Latency fluctuation diagnosis
# ============================================================
# When acceleration works but game latency fluctuates (e.g.
# 50ms → 100ms+ spikes), the most common causes are:
#   1. Bufferbloat — WAN buffer overflow without SQM/QoS
#   2. GAMEACC hijacks ALL traffic, not just game traffic
#   3. conntrack table pressure causing connection drops
#   4. DNS relay latency through the TURN tunnel
diagnose_latency() {
    echo
    echo "============================="
    echo "  延迟波动诊断"
    echo "============================="

    local issues=0
    wan_if=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    [ -z "$wan_if" ] && wan_if=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)

    # --- 1. Bufferbloat: check queue discipline ---
    echo
    echo "[1/5] 队列管理 (QoS)"
    echo "  WAN 接口: ${wan_if:-unknown}"
    local has_fq_codel=0
    local has_cake=0
    local has_sqm=0
    local wan_noqdisc=0
    tc qdisc show 2>/dev/null | grep -q "fq_codel" && has_fq_codel=1
    tc qdisc show 2>/dev/null | grep -q "cake" && has_cake=1
    [ -f /etc/init.d/sqm ] || [ -f /etc/config/sqm ] && has_sqm=1

    # Check if the ACTUAL WAN interface has any qdisc
    if [ -n "$wan_if" ]; then
        wan_qdisc=$(tc qdisc show dev "$wan_if" 2>/dev/null | head -1)
        if echo "$wan_qdisc" | grep -q "noqueue\|qdisc noqueue"; then
            wan_noqdisc=1
        fi
    fi

    # PPPoE-specific: physical NIC may have fq_codel but the PPPoE tunnel does not
    if [ "$wan_noqdisc" = "1" ]; then
        echo "  [FAIL] WAN 接口 $wan_if 无队列管理!"
        if echo "$wan_if" | grep -qE "pppoe|ppp"; then
            echo "  → PPPoE 隧道口无 qdisc。注意: 不要在 pppoe 虚拟接口上加 qdisc"
            echo "  → 物理网卡 (eth0) 的 fq_codel 已覆盖出口流量"
            echo "  → 如延迟仍波动, 安装 SQM 对 PPPoE 做端到端整形:"
            echo "    $(pkg_hint sqm-scripts luci-app-sqm)"
        else
            echo "  → 请安装 SQM 或手动添加队列规则"
            echo -n "  是否立即添加 fq_codel? (y/n): "
            read add_fq
            case "$add_fq" in
                [Yy]|[Yy][Ee][Ss])
                    tc qdisc add dev "$wan_if" root fq_codel 2>/dev/null && \
                        echo "  [INFO] fq_codel 已添加" || \
                        echo "  [WARN] 添加失败"
                    ;;
            esac
        fi
        issues=$((issues + 1))
    elif [ "$has_sqm" = "1" ]; then
        echo "  [OK] SQM QoS 已配置 (最佳防抖动方案)"
    elif [ "$has_cake" = "1" ]; then
        echo "  [OK] cake qdisc 已启用 (优秀的防抖动方案)"
    elif [ "$has_fq_codel" = "1" ]; then
        echo "  [WARN] 仅 fq_codel (基础防抖动, 建议升级到 SQM)"
        echo "  → fq_codel 只控制出站队列, 入站流量无法管理"
        echo "  → 建议: $(pkg_hint sqm-scripts luci-app-sqm)"
        echo "  → 安装后在 LuCI → 网络 → SQM QoS 中配置 $wan_if 接口"
        issues=$((issues + 1))
    else
        echo "  [FAIL] 无队列管理! 延迟波动的主要根因"
        echo "  → 请立即安装: $(pkg_hint sqm-scripts luci-app-sqm)"
        issues=$((issues + 1))
    fi

    # --- 2. Check GAMEACC traffic distribution ---
    echo
    echo "[2/6] GAMEACC 流量分析"

    local tproxy_total_pkts=0
    # Use iptables-nft -x for exact counters (no K/M/G suffix), parse with awk
    # Fallback to plain iptables if iptables-nft is absent (some minimal builds only
    # symlink iptables → iptables-nft without providing a separate iptables-nft binary)
    local tproxy_lines ipt_cmd
    ipt_cmd="iptables-nft"
    [ -x /usr/sbin/iptables-nft ] || ipt_cmd="iptables"
    tproxy_lines=$($ipt_cmd -t mangle -L GAMEACC -n -v -x 2>/dev/null | grep "TPROXY")
    if [ -n "$tproxy_lines" ]; then
        tproxy_total_pkts=$(echo "$tproxy_lines" | awk '{s+=$1} END {print s+0}')
        echo "  TPROXY 总数据包: $tproxy_total_pkts"
        echo "  → 这是所有通过加速通道的流量"

        if [ "$tproxy_total_pkts" -gt 50000 ] 2>/dev/null; then
            echo "  [WARN] TPROXY 流量较大, 可能有非游戏流量被劫持"
            echo "  → 建议加速前关闭大流量下载/视频流"
            issues=$((issues + 1))
        fi
    else
        echo "  [WARN] 未找到 TPROXY 规则 — 加速可能未激活"
        issues=$((issues + 1))
    fi

    # --- 3. conntrack table pressure ---
    echo
    echo "[3/6] 连接追踪 (conntrack)"
    local ct_count ct_max
    ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
    ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)

    if [ -n "$ct_count" ] && [ -n "$ct_max" ] && [ "$ct_max" -gt 0 ]; then
        local ct_pct=$((ct_count * 100 / ct_max))
        echo "  当前: $ct_count / $ct_max ($ct_pct%)"
        if [ "$ct_pct" -gt 80 ]; then
            local new_ct_max=$((ct_max * 2))
            echo "  [WARN] 连接追踪表使用率 > 80%, 可能导致新连接延迟"
            echo "  → 建议扩大: echo $new_ct_max > /proc/sys/net/netfilter/nf_conntrack_max"
            echo -n "  → 是否立即扩大到 ${new_ct_max}? (y/n): "
            read expand_ct
            case "$expand_ct" in
                [Yy]|[Yy][Ee][Ss])
                    echo "$new_ct_max" > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null && \
                        echo "  [OK] conntrack_max 已扩大到 $new_ct_max" || \
                        echo "  [WARN] 写入失败, 请手动: echo $new_ct_max > /proc/sys/net/netfilter/nf_conntrack_max"
                    ;;
            esac
            issues=$((issues + 1))
        else
            echo "  [OK] 连接追踪表压力正常"
        fi
    else
        echo "  [INFO] 无法读取 conntrack 状态 (可能模块未加载)"
    fi

    # --- 4. DNS relay check ---
    echo
    echo "[4/6] DNS 中继延迟"
    dns_rule_pkts=$($ipt_cmd -t mangle -L GAMEACC -n -v 2>/dev/null | grep "dport 53" | awk '{print $1}')
    if [ -n "$dns_rule_pkts" ] && [ "$dns_rule_pkts" != "0" ] 2>/dev/null; then
        echo "  DNS 劫持包数: $dns_rule_pkts"
        echo "  → DNS 通过 TURN 中继解析会增加额外延迟"
        echo "  → 但 DNS 只在连接建立时发生, 不影响游戏中持续延迟"
    else
        echo "  [OK] DNS 未走加速通道或无流量"
    fi

    # --- 5. TURN relay stability & jitter ---
    echo
    echo "[5/6] TURN 中继稳定性"
    # Use the same hostname acc-gw resolves internally; ping lets the system handle DNS
    local turn_host="route-turn.xxghh.biz"
    ping_result=$(ping -c 5 -W 2 "$turn_host" 2>/dev/null | tail -1)
    if echo "$ping_result" | grep -q "0%"; then
        local avg_ms min_ms max_ms mdev_ms
        avg_ms=$(echo "$ping_result" | grep -oE "[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+" | cut -d/ -f2)
        min_ms=$(echo "$ping_result" | grep -oE "[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+" | cut -d/ -f1)
        max_ms=$(echo "$ping_result" | grep -oE "[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+" | cut -d/ -f3)
        mdev_ms=$(echo "$ping_result" | grep -oE "[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+" | cut -d/ -f4)
        echo "  [OK] $turn_host 可达, 平均: ${avg_ms:-N/A} ms"
        [ -n "$min_ms" ] && [ -n "$max_ms" ] && echo "  最小/最大: ${min_ms}/${max_ms} ms, 抖动(mdev): ${mdev_ms:-N/A} ms"
        # High jitter to the TURN relay is a red flag
        if [ -n "$mdev_ms" ] && [ "$(echo "$mdev_ms > 15" | bc 2>/dev/null)" = "1" ] 2>/dev/null; then
            echo "  [WARN] TURN 中继抖动 > 15ms — 中继侧网络可能不稳定"
            issues=$((issues + 1))
        elif [ -n "$mdev_ms" ] && [ "$(echo "$mdev_ms > 50" | bc 2>/dev/null)" = "1" ] 2>/dev/null; then
            echo "  [FAIL] TURN 中继抖动 > 50ms! 这是延迟波动的主要来源"
            echo "  → 中继服务可能过载, 建议联系雷神客服反馈"
            issues=$((issues + 1))
        fi
    elif ping -c 3 -W 2 "$turn_host" >/dev/null 2>&1; then
        echo "  [OK] $turn_host 连通正常"
    else
        echo "  [FAIL] TURN 中继不可达!"
        echo "  → 请手动: ping $turn_host"
        issues=$((issues + 1))
    fi

    # --- 6. PPPoE fragmentation / TCP MSS ---
    echo
    echo "[6/6] PPPoE MTU/分片检查"
    if echo "${wan_if:-}" | grep -qE "pppoe|ppp"; then
        echo "  检测到 PPPoE 接口: $wan_if"
        # Check if TCP MSS clamping is in place
        if iptables -t mangle -L FORWARD -n 2>/dev/null | grep -q "TCPMSS.*clamp-mss-to-pmtu"; then
            echo "  [OK] TCP MSS clamping 已配置 (避免分片)"
        else
            echo "  [WARN] PPPoE 缺少 TCP MSS clamping — 大包可能被分片, 增加延迟"
            echo "  → 分片会显著增加延迟抖动 (额外的重组等待)"
            echo -n "  → 是否立即添加 TCP MSS clamping? (y/n): "
            read add_mss
            case "$add_mss" in
                [Yy]|[Yy][Ee][Ss])
                    iptables -t mangle -A FORWARD -o "$wan_if" -p tcp --tcp-flags SYN,RST SYN \
                        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null && \
                        echo "  [OK] TCP MSS clamping 已添加" || \
                        echo "  [WARN] 添加失败, 请手动添加"
                    ;;
            esac
            issues=$((issues + 1))
        fi
        # Check MTU sanity
        ppp_mtu=$(ip link show "$wan_if" 2>/dev/null | grep -o "mtu [0-9]*" | awk '{print $2}')
        if [ -n "$ppp_mtu" ] && [ "$ppp_mtu" -lt 1492 ] 2>/dev/null; then
            echo "  [WARN] PPPoE MTU 偏低: $ppp_mtu (标准 1492)"
            echo "  → MTU 过小会增加包数和每包开销, 建议设为 1492"
            issues=$((issues + 1))
        elif [ -n "$ppp_mtu" ]; then
            echo "  [OK] PPPoE MTU: $ppp_mtu"
        fi
    else
        echo "  [OK] 非 PPPoE 接口 (${wan_if:-unknown}), 无需 MSS clamping"
    fi

    # --- Summary ---
    echo
    echo "============================="
    if [ "$issues" -eq 0 ]; then
        echo "  诊断结果: 未发现明显问题"
        echo "  延迟波动可能来自:"
        echo "  1. 雷神中继 → 游戏服务器 路径抖动 (无法控制)"
        echo "  2. 游戏服务器自身负载波动"
        echo "  3. ISP 骨干网拥堵"
    else
        echo "  诊断结果: 发现 $issues 个潜在问题 (见上方 [WARN]/[FAIL])"
        echo ""
        echo "  推荐操作顺序:"
        echo "  1. 安装 SQM QoS (解决 bufferbloat — 最可能根因)"
        echo "  2. 加速前暂停大流量下载/视频"
        echo "  3. 扩大 conntrack 表 (如使用率 > 80%)"
        echo "  4. 运行 leigod-fw4.sh tune-network 应用内核优化"
    fi

    # SQM offer
    # Offer SQM if no SQM/cake, OR if WAN interface has no qdisc (e.g. PPPoE)
    if [ "$has_sqm" = "0" ] && [ "$has_cake" = "0" ]; then
        echo
        echo -n "是否立即安装 SQM QoS? (y/n): "
        read install_sqm_choice
        case "$install_sqm_choice" in
            [Yy]|[Yy][Ee][Ss])
                install_sqm
                ;;
        esac
    fi
    echo "============================="
}

# ============================================================
# Install SQM QoS (CAKE qdisc) for bufferbloat prevention
# ============================================================
install_sqm() {
    wan_if=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    [ -z "$wan_if" ] && wan_if=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    [ -z "$wan_if" ] && wan_if="eth0"

    echo "[INFO] 检测到 WAN 接口: $wan_if"

    local is_pppoe=0
    echo "$wan_if" | grep -qE "pppoe|ppp" && is_pppoe=1

    # Remove any previously-added fq_codel on PPPoE from rc.local (bug fix: PPPoE double-queueing)
    if [ "$is_pppoe" = "1" ] && [ -f /etc/rc.local ]; then
        sed -i "/tc qdisc.*$wan_if.*fq_codel/d" /etc/rc.local 2>/dev/null
    fi

    # Try package-based SQM first
    echo "[INFO] 尝试安装 SQM 包..."
    pkg_update
    local pkg_ok=0
    if pkg_install_raw sqm-scripts luci-app-sqm >/dev/null 2>&1; then
        pkg_ok=1
        local linklayer="ethernet"
        local overhead=44
        if [ "$is_pppoe" = "1" ]; then
            linklayer="atm"
            overhead=40  # PPPoE: 8 (PPPoE header) + 32 (ATM/AAL5)
        fi
        uci set sqm.@queue[0].enabled='1'
        uci set sqm.@queue[0].interface="$wan_if"
        uci set sqm.@queue[0].download='0'
        uci set sqm.@queue[0].upload='0'
        uci set sqm.@queue[0].qdisc='cake'
        uci set sqm.@queue[0].script='piece_of_cake.qos'
        uci set sqm.@queue[0].linklayer="$linklayer"
        uci set sqm.@queue[0].overhead="$overhead"
        uci commit sqm
        /etc/init.d/sqm enable 2>/dev/null
        /etc/init.d/sqm start 2>/dev/null
        echo "[INFO] SQM 已安装并启动。请在 LuCI → 网络 → SQM QoS 中设置带宽值"
    else
        echo "[WARN] SQM 包不可用"
    fi

    # For NON-PPPoE interfaces with no qdisc, add fq_codel fallback
    # IMPORTANT: Do NOT add qdisc to PPPoE virtual interfaces — the PPPoE
    # kernel module has its own internal TX queue. Adding fq_codel on top
    # creates double queueing and INCREASES latency.
    if [ "$is_pppoe" = "0" ]; then
        if tc qdisc show dev "$wan_if" 2>/dev/null | head -1 | grep -q "noqueue"; then
            echo "[INFO] $wan_if 无队列管理，正在添加 fq_codel..."
            if tc qdisc add dev "$wan_if" root fq_codel 2>/dev/null; then
                echo "[INFO] fq_codel 已添加到 $wan_if (立即生效)"
                if ! grep -q "tc qdisc.*$wan_if.*fq_codel" /etc/rc.local 2>/dev/null; then
                    [ ! -f /etc/rc.local ] && { echo "#!/bin/sh"; echo "exit 0"; } > /etc/rc.local
                    sed -i "/^exit 0/i tc qdisc add dev $wan_if root fq_codel 2>/dev/null" /etc/rc.local
                    echo "[INFO] 已添加到 /etc/rc.local"
                fi
            fi
        else
            echo "[INFO] $wan_if 已有队列管理"
        fi
    elif [ "$pkg_ok" = "0" ]; then
        # PPPoE without SQM: the physical ethX already has fq_codel via
        # OpenWrt defaults. No additional qdisc needed on pppoe-wan.
        echo "[INFO] PPPoE 接口，物理网卡已有 fq_codel 覆盖 — 无需额外配置"
        echo "[TIP] 如仍有延迟波动，请在 LuCI 中安装 SQM (if available)"
    fi

    # Clamp TCP MSS for PPPoE (avoid fragmentation)
    if [ "$is_pppoe" = "1" ]; then
        if ! iptables -t mangle -C FORWARD -o "$wan_if" -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
            iptables -t mangle -A FORWARD -o "$wan_if" -p tcp --tcp-flags SYN,RST SYN \
                -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null && \
                echo "[INFO] TCP MSS clamping 已添加 (避免 PPPoE 分片)"
        fi
    fi
}

# ============================================================
# Apply kernel network tuning for low-latency gaming
# ============================================================
# Tunes kernel parameters that reduce latency jitter:
#   - Sets default qdisc to fq_codel (fair queuing + AQM)
#   - Enables BBR congestion control (better for lossy links)
#   - Increases socket buffers (reduces drops under burst)
#   - Reduces conntrack timeout for established TCP (frees table slots)
#   - Enables TCP fastopen (reduces connection setup latency)
#
# These changes are applied immediately and also written to
# /etc/sysctl.d/99-leigod-latency.conf for persistence across reboots.
apply_network_tuning() {
    local SYSCTL_CONF="/etc/sysctl.d/99-leigod-latency.conf"
    local applied=0

    echo
    echo "============================="
    echo "  内核网络调优 (低延迟游戏)"
    echo "============================="
    echo "[INFO] 正在应用调优参数..."

    # Back up existing conf if present
    [ -f "$SYSCTL_CONF" ] && cp "$SYSCTL_CONF" "${SYSCTL_CONF}.bak"

    cat > "$SYSCTL_CONF" << 'SYSCTLEOF'
# LeigodAcc low-latency gaming network tuning
# Generated by leigod-fw4.sh apply_network_tuning

# ----- Queuing discipline -----
# fq_codel: fair queuing with controlled delay — prevents bufferbloat
# by dropping packets from flows that are consuming too much bandwidth,
# which signals TCP senders to back off BEFORE the queue fills up.
net.core.default_qdisc = fq_codel

# ----- TCP congestion control -----
# BBR: Bottleneck Bandwidth and Round-trip propagation time.
# Better than cubic for lossy/gaming links — doesn't treat every
# packet loss as congestion, maintains higher throughput under jitter.
net.ipv4.tcp_congestion_control = bbr

# ----- Socket buffer sizes -----
# Larger buffers prevent packet drops during traffic bursts
# (e.g. game data + voice chat arriving simultaneously).
# Values in bytes. Defaults are ~212992; these allow up to 4MB.
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
# Increase the default send/receive buffer for all sockets
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# ----- TCP fast open -----
# TFO allows data in the SYN packet, saving 1 RTT on connection setup.
# 3 = enable for both client and server.
net.ipv4.tcp_fastopen = 3

# ----- Conntrack -----
# Reduce established TCP timeout from default 432000 (5 days) to
# 3600 (1 hour). This frees conntrack table entries faster,
# preventing table pressure that causes connection delays.
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
# Increase max conntrack entries to 65536 (default is often 16384).
# More headroom prevents "table full" drops.
net.netfilter.nf_conntrack_max = 65536

# ----- TCP keepalive -----
# Faster keepalive detection for broken connections (games often use
# long-lived UDP connections that don't benefit from this, but it
# helps with control-plane TCP connections to the TURN relay).
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3

# ----- IPv6 -----
# Disable IPv6 if not needed (reduces DNS lookup latency and
# prevents games from inadvertently using IPv6 paths).
# Leave unset by default; enable via leigod-fw4.sh disable-ipv6
# net.ipv6.conf.all.disable_ipv6 = 1
SYSCTLEOF

    # Apply immediate
    sysctl -p "$SYSCTL_CONF" >/dev/null 2>&1 && applied=1

    echo ""
    echo "  已应用的调优项:"
    echo "  - 默认 qdisc:     fq_codel (防 bufferbloat)"
    echo "  - 拥塞控制:       BBR (更适合有损/抖动链路)"
    echo "  - Socket 缓冲区:  rmem/wmem = 4MB max, 256KB default"
    echo "  - TCP fastopen:   启用 (减少连接建立 1 RTT)"
    echo "  - Conntrack:      max=65536, tcp_timeout=3600s"
    echo "  - TCP keepalive:  120s (快速检测断连)"

    if [ "$applied" = "1" ]; then
        echo ""
        echo "  [OK] 参数已生效并持久化到: $SYSCTL_CONF"
        echo "  → 重启后自动加载, 无需额外配置"
    else
        echo "  [WARN] sysctl 应用可能未完全生效 (某些参数可能需要内核支持)"
        echo "  → BBR 需要内核编译支持: CONFIG_TCP_CONG_BBR=y"
    fi

    # Check if BBR is actually available
    if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
        current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)
        echo "  → 当前拥塞控制: $current_cc"
        if [ "$current_cc" != "bbr" ] && grep -q "bbr" /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
            echo "  → BBR 可用但未激活, 可能被其他配置覆盖"
            echo "  → 手动: echo bbr > /proc/sys/net/ipv4/tcp_congestion_control"
        fi
    fi

    # Check conntrack max
    ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
    [ -n "$ct_max" ] && echo "  → 当前 conntrack_max: $ct_max"

    echo "============================="
}

# ============================================================
# Auto-Pause — 自动暂停时长计费
# ============================================================
AUTO_PAUSE_SCRIPT="/usr/sbin/leigod-auto-pause.sh"
AUTO_PAUSE_CONF="/etc/leigod-auto-pause.conf"
AUTO_PAUSE_CRON="/etc/crontabs/root"

auto_pause_menu() {
    echo
    echo "============================="
    echo " 自动暂停时长管理"
    echo "============================="
    echo " 检测到设备停止加速后，自动调用"
    echo " 雷神 API 暂停时长计费，避免浪费。"
    echo
    echo "1. 安装/配置 自动暂停"
    echo "2. 卸载 自动暂停"
    echo "3. 查看运行状态"
    echo "4. 手动暂停一次 (测试)"
    echo "0. 返回主菜单"
    echo "============================="
    echo -n "选择: "
    read sub_choice
    case $sub_choice in
        1) auto_pause_install ;;
        2) auto_pause_uninstall ;;
        3) auto_pause_status ;;
        4) auto_pause_trigger ;;
        0) return ;;
        *) echo "[ERROR] 无效选项" ;;
    esac
}

auto_pause_install() {
    echo "[INFO] 配置自动暂停..."

    # Check if leigod-acc is installed
    if [ ! -f /etc/init.d/acc ] || [ ! -d /usr/sbin/leigod ]; then
        echo "[ERROR] 尚未安装雷神加速器（缺少 init 脚本或二进制目录），请先安装"
        return 1
    fi

    # Deploy the latest embedded auto-pause script (always overwrite)
    echo "[INFO] 正在部署脚本..."
    cat > "$AUTO_PAUSE_SCRIPT" << 'AUTOSCRIPT'
#!/bin/sh
# ============================================================
# LeigodAcc Auto-Pause — 自动暂停时长计费 (v2.5, inline)
#
# Token: LuCI 书签一键获取 → pause API 调用
#   登录 API 有 CloudWAF 保护，无法自动化登录。
#   使用 LuCI 自动暂停页面的书签获取 token。
#   每 7 天点击一次，5 秒完成。
#
# 空闲检测: cron 定时检查，连续空闲 N 次后触发暂停
#   总空闲时间 = IDLE_CHECK_INTERVAL(分钟) × IDLE_CHECKS_BEFORE_PAUSE(次)
# ============================================================

CONFIG_FILE="/etc/leigod-auto-pause.conf"
STATE_FILE="/tmp/leigod-auto-pause.state"
LOG_TAG="leigod-auto-pause"

load_config() {
    ACCOUNT_TOKEN=""
    IDLE_CHECKS_BEFORE_PAUSE=3
    IDLE_CHECK_INTERVAL=2
    API_TIMEOUT=10
    API_ENDPOINT="https://webapi.leigod.com"
    NOTIFY_ON_PAUSE=1
    MANUAL_DISABLE=0
    if [ -f "$CONFIG_FILE" ]; then . "$CONFIG_FILE"; fi
    [ -z "$IDLE_CHECKS_BEFORE_PAUSE" ] && IDLE_CHECKS_BEFORE_PAUSE=3
    [ -z "$IDLE_CHECK_INTERVAL" ] && IDLE_CHECK_INTERVAL=2
    [ -z "$API_TIMEOUT" ] && API_TIMEOUT=10
    [ -z "$MANUAL_DISABLE" ] && MANUAL_DISABLE=0
}

get_token() {
    if [ -n "$ACCOUNT_TOKEN" ]; then echo "$ACCOUNT_TOKEN"; return 0; fi
    return 1
}

check_all_idle() {
    if [ -f /tmp/acc/acc_core_conf.json ]; then
        if grep -q '"state":1' /tmp/acc/acc_core_conf.json 2>/dev/null; then return 1; fi
    fi
    for dev in Phone PC Game Unknown; do
        local state; state=$(uci get "accelerator.${dev}.state" 2>/dev/null)
        [ "$state" = "1" ] && return 1
    done
    return 0
}

is_idle() {
    if [ -f /etc/config/accelerator ]; then check_all_idle; return $?; fi
    if ! pgrep -f "acc-gw" >/dev/null 2>&1; then return 0; fi
    return 1
}

call_pause_api() {
    local token="$1" resp code
    resp=$(curl -sL --connect-timeout "$API_TIMEOUT" -X POST "${API_ENDPOINT}/api/user/pause" \
        -H 'Content-Type: application/json' -H 'User-Agent: LeigodAcc-AutoPause/2.5' \
        -d "{\"account_token\":\"${token}\",\"lang\":\"zh_CN\"}" 2>/dev/null)
    code=$(echo "$resp" | grep -o '"code": *[-0-9]*' | head -1 | grep -o '[-0-9]*$')
    echo "$code"
}

read_state() {
    local idle_count=0 last_pause_epoch=0
    if [ -f "$STATE_FILE" ]; then
        local key val
        while IFS='=' read -r key val; do
            case "$key" in idle_count) idle_count="$val" ;; last_pause_epoch) last_pause_epoch="$val" ;; esac
        done < "$STATE_FILE"
    fi
    IDLE_COUNT=$idle_count; LAST_PAUSE_EPOCH=$last_pause_epoch
}

write_state() {
    cat > "$STATE_FILE" << STATEOF
idle_count=${IDLE_COUNT}
last_pause_epoch=${LAST_PAUSE_EPOCH}
STATEOF
}

main() {
    load_config

    # Manual disable: skip all idle detection and pause logic
    if [ "$MANUAL_DISABLE" = "1" ]; then
        read_state
        IDLE_COUNT=0
        if [ ! -f /tmp/leigod-away.logged ]; then
            logger -t "$LOG_TAG" "离家模式已启用, 跳过本次自动暂停检测"
            touch /tmp/leigod-away.logged
        fi
        write_state
        return 0
    fi
    # Clean up away-mode marker when normal mode resumes
    rm -f /tmp/leigod-away.logged
    local TOKEN; TOKEN=$(get_token 2>/dev/null)
    if [ -z "$TOKEN" ]; then
        logger -t "$LOG_TAG" "account_token 未配置, 请通过 LuCI 自动暂停页面的书签获取"
        return 1
    fi
    read_state
    local now; now=$(date +%s)
    if [ "$LAST_PAUSE_EPOCH" != "0" ] && [ $((now - LAST_PAUSE_EPOCH)) -lt 600 ]; then return 0; fi
    if is_idle; then
        IDLE_COUNT=$((IDLE_COUNT + 1))
        logger -t "$LOG_TAG" "检测到空闲 (${IDLE_COUNT}/${IDLE_CHECKS_BEFORE_PAUSE})"
        if [ "$IDLE_COUNT" -ge "$IDLE_CHECKS_BEFORE_PAUSE" ]; then
            logger -t "$LOG_TAG" "空闲阈值达到, 正在调用暂停 API..."
            local api_code; api_code=$(call_pause_api "$TOKEN")
            case "$api_code" in
                0) logger -t "$LOG_TAG" "暂停成功!"; LAST_PAUSE_EPOCH=$now; IDLE_COUNT=0 ;;
                400803) logger -t "$LOG_TAG" "已经处于暂停状态"; LAST_PAUSE_EPOCH=$now; IDLE_COUNT=0 ;;
                400006) logger -t "$LOG_TAG" "token 已过期, 请重新通过书签获取"; IDLE_COUNT=$((IDLE_CHECKS_BEFORE_PAUSE - 1)) ;;
                "") logger -t "$LOG_TAG" "API 请求失败 (网络/curl 错误)" ;;
                *) logger -t "$LOG_TAG" "API 返回异常 (code=$api_code)" ;;
            esac
        fi
    else
        [ "$IDLE_COUNT" -gt 0 ] && logger -t "$LOG_TAG" "设备活跃, 重置空闲计数"
        IDLE_COUNT=0
    fi
    write_state
}
main "$@"
AUTOSCRIPT
    chmod +x "$AUTO_PAUSE_SCRIPT"
    echo "[INFO] 已部署内嵌脚本到 $AUTO_PAUSE_SCRIPT"

    # Configure account_token (OPTIONAL — daemon token is auto-used as fallback)
    echo ""
    echo "=========================================="
    echo "  Token 获取:"
    echo "  LuCI → 自动暂停 → 拖书签到浏览器书签栏"
    echo "  打开 leigod.com 登录后 → 点击书签 → 一键获取"
    echo ""
    echo "  或手动: 浏览器 F12 → localStorage → account_token"
    echo "=========================================="
    echo ""

    if [ -f "$AUTO_PAUSE_CONF" ]; then
        echo "[INFO] 配置文件已存在: $AUTO_PAUSE_CONF"
        echo -n "是否重新配置? (y/n/回车=保持现有): "
        read update_choice
        case "$update_choice" in
            [Yy]) ;;
            *)  auto_pause_setup_cron; return ;;
        esac
    fi

    printf '# LeigodAcc Auto-Pause configuration\n' > "$AUTO_PAUSE_CONF"

    # Account token
    echo -n "account_token (回车跳过, 稍后通过书签获取): "
    read -s token
    echo ""
    if [ -n "$token" ]; then
        printf "ACCOUNT_TOKEN='%s'\n" "$token" >> "$AUTO_PAUSE_CONF"
        echo "[INFO] 已配置 token"
    else
        echo "[INFO] 稍后可通过 LuCI 自动暂停页面书签一键获取 token"
    fi
    cat >> "$AUTO_PAUSE_CONF" << 'CONFOF'
IDLE_CHECKS_BEFORE_PAUSE=3
API_TIMEOUT=10
API_ENDPOINT="https://webapi.leigod.com"
NOTIFY_ON_PAUSE=1
MANUAL_DISABLE=0
CONFOF
    chmod 600 "$AUTO_PAUSE_CONF"
    echo "[INFO] 配置已保存: $AUTO_PAUSE_CONF"

    auto_pause_setup_cron
}

auto_pause_setup_cron() {
    # Read custom interval from config, default 2 minutes
    local interval=2
    if [ -f "$AUTO_PAUSE_CONF" ]; then
        cfg_int=$(grep "^IDLE_CHECK_INTERVAL=" "$AUTO_PAUSE_CONF" 2>/dev/null | cut -d= -f2)
        [ -n "$cfg_int" ] && [ "$cfg_int" -ge 1 ] && interval="$cfg_int"
    fi

    # Remove old cron entry, add new one with current interval
    sed -i '/leigod-auto-pause/d' "$AUTO_PAUSE_CRON" 2>/dev/null
    echo "*/${interval} * * * * $AUTO_PAUSE_SCRIPT >> /tmp/leigod-auto-pause.log 2>&1" >> "$AUTO_PAUSE_CRON"
    /etc/init.d/cron restart 2>/dev/null
    echo "[INFO] cron 已配置（每 ${interval} 分钟检查一次）"
    echo "[INFO] 安装完成！设备停止加速后约 $(( interval * 3 )) 分钟内自动暂停计费"
}

auto_pause_uninstall() {
    echo "[INFO] 卸载自动暂停..."

    # Remove cron entry
    if [ -f "$AUTO_PAUSE_CRON" ]; then
        sed -i '/leigod-auto-pause/d' "$AUTO_PAUSE_CRON"
        /etc/init.d/cron restart 2>/dev/null
    fi

    rm -f "$AUTO_PAUSE_SCRIPT"
    rm -f "$AUTO_PAUSE_CONF"
    rm -f /tmp/leigod-auto-pause.state
    rm -f /tmp/leigod-auto-pause.log
    echo "[INFO] 已卸载"
}

auto_pause_status() {
    echo
    if [ -f "$AUTO_PAUSE_CONF" ]; then
        echo "[配置] $AUTO_PAUSE_CONF: 已配置"
        . "$AUTO_PAUSE_CONF"
        if [ -n "$ACCOUNT_TOKEN" ]; then
            local token_len
            token_len=${#ACCOUNT_TOKEN}
            echo "  token: ${ACCOUNT_TOKEN:0:8}...${ACCOUNT_TOKEN:$((token_len - 4))}"
        fi
        # Show manual disable status
        if [ "$MANUAL_DISABLE" = "1" ]; then
            echo "[模式] 离家模式 (自动暂停已禁用)"
        else
            echo "[模式] 自动模式 (正常检测空闲)"
        fi
    else
        echo "[配置] 未配置"
    fi

    if grep -q "leigod-auto-pause" "$AUTO_PAUSE_CRON" 2>/dev/null; then
        echo "[cron] 已启用 (每2分钟)"
    else
        echo "[cron] 未启用"
    fi

    if [ -f /tmp/leigod-auto-pause.state ]; then
        echo "[状态]"
        cat /tmp/leigod-auto-pause.state
    fi

    # Show recent logs
    if [ -f /tmp/leigod-auto-pause.log ]; then
        echo "[最近日志]"
        tail -5 /tmp/leigod-auto-pause.log
    fi

    # Show current UCI accelerator state
    if [ -f /etc/config/accelerator ]; then
        echo "[加速状态]"
        for dev in Phone PC Game Unknown; do
            local state
            state=$(uci get "accelerator.${dev}.state" 2>/dev/null)
            case "$state" in
                1) echo "  $dev: 加速中" ;;
                2) echo "  $dev: 已停止" ;;
                3) echo "  $dev: 已暂停" ;;
                *) echo "  $dev: 无" ;;
            esac
        done
    fi
    echo
}

auto_pause_trigger() {
    if [ ! -f "$AUTO_PAUSE_SCRIPT" ]; then
        echo "[ERROR] 脚本未安装，请先执行选项1"
        return 1
    fi
    echo "[INFO] 手动触发暂停检查..."
    sh "$AUTO_PAUSE_SCRIPT"
    echo "[INFO] 执行完毕，请查看上方输出或 /tmp/leigod-auto-pause.log"
}

# ============================================================
# Help
# ============================================================
help() {
    echo ""
    echo "BLOG: https://www.miaoer.net/posts/blog/openwrt-leigodacc-manager"
    echo "[Tip] LeigodAcc 特指雷神加速器，leigod-acc 特指 Lean 版雷神插件"
    echo ""
    echo "HELP："
    echo "1. 安装：安装 LeigodAcc"
    echo "2. 卸载：卸载 LeigodAcc"
    echo "3. 重装：重装 LeigodAcc"
    echo "4. 禁用/启用：禁用或启用 LeigodAcc 服务"
    echo "5. 切换运行模式：在 TUN 和 Tproxy 模式之间切换"
    echo "6. 安装兼容性依赖：从当前固件软件源补全常见缺失依赖"
    echo "7. 禁用 IPv6: 可以使手机部分手机游戏也能正常加速，会禁用掉 IPv6 网络"
    echo "8. 切换为 Lean IPKG 版：仅 opkg 系统可用，25.12/apk 不支持 .ipk"
    echo "9. 自动暂停时长：检测到游戏结束自动暂停计费，省时长"
    echo "S. 查看服务状态：显示安装、运行、设备、日志等诊断信息"
    echo "L. 延迟波动诊断：检查 bufferbloat/QoS/GAMEACC 流量等延迟波动根因，可安装 SQM"
    echo "T. 内核网络调优：应用 fq_codel/BBR/conntrack 等低延迟优化参数"
    echo "H. 帮助：显示帮助信息"
    echo "0. 退出：退出管理器"
    echo ""
    echo "防火墙适配："
    echo "  当前防火墙: $FW_NAME"
    if [ "$FW_TYPE" = "fw4" ]; then
        echo "  已适配 OpenWrt 24.10+ fw4/nftables"
        echo "  已适配 fw4/nftables。请使用选项 S 诊断检查 tproxy_ip 是否匹配 LAN IP"
    else
        echo "  使用传统 fw3/iptables 模式"
    fi
    echo ""
    echo "包管理器："
    echo "  当前: $(pkg_mgr_name)"
    if [ "$PKG_MGR" = "apk" ]; then
        echo "  安装: apk add <包名>    卸载: apk del <包名>"
        echo "  已装: apk info          刷源: apk update"
        echo "  LuCI 依赖: luci-compat + luci-lua-runtime (缺失则菜单不出现)"
    else
        echo "  安装: opkg install <包名>  卸载: opkg remove <包名>"
    fi
    echo ""
    sleep 3
}

# ============================================================
# CLI: leigod-fw4.sh fix-tproxy
# Called by cron watcher to repair tproxy_ip when daemon
# overwrites acc_core_conf.json with hardcoded fake IP.
# ============================================================
if [ "$1" = "fix-tproxy" ]; then
    detect_pkg_mgr
    detect_firewall
    set_fw_packages
    if [ -f /tmp/acc/acc_core_conf.json ]; then
        fix_acc_core_conf
    fi
    exit 0
fi

# ============================================================
# CLI: leigod-fw4.sh tune-network
# Apply kernel network tuning optimizations for low-latency gaming.
# Safe to run repeatedly — subsequent runs will refresh parameters.
# ============================================================
if [ "$1" = "tune-network" ]; then
    detect_pkg_mgr
    detect_firewall
    set_fw_packages
    apply_network_tuning
    exit 0
fi

# ============================================================
# CLI: leigod-fw4.sh diagnose
# Non-interactive latency diagnosis (no y/n prompts — report only).
# Useful for cron jobs or scripting.
# ============================================================
if [ "$1" = "diagnose" ]; then
    detect_pkg_mgr
    detect_firewall
    set_fw_packages

    echo "============================="
    echo "  LeigodAcc 快速诊断报告"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================="

    # System summary
    echo ""
    echo "--- 系统 ---"
    model=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^[ \t]*//')
    [ -z "$model" ] && model=$(uname -m)
    echo "  设备: $model"
    echo "  固件: $(grep DISTRIB_DESCRIPTION /etc/openwrt_release 2>/dev/null | cut -d"'" -f2)"
    echo "  内核: $(uname -r)"
    echo "  防火墙: $FW_NAME"
    echo "  包管理: $(pkg_mgr_name)"
    if pkg_installed luci-compat && pkg_installed luci-lua-runtime; then
        echo "  LuCI: Lua 兼容层已安装"
    else
        echo "  LuCI: Lua 兼容层缺失! 执行: $(pkg_hint luci-compat luci-lua-runtime)"
    fi

    # acc-gw process check
    echo ""
    echo "--- 进程 ---"
    if ps | grep -q "[a]cc-gw"; then
        pid=$(ps | grep "[a]cc-gw" | head -1 | awk '{print $1}')
        mode=$(ps ww | grep "[a]cc-gw" | head -1 | grep -oE -- "-m (tun|tproxy)" | awk '{print $2}')
        echo "  acc-gw: 运行中 (PID=$pid, mode=${mode:-unknown})"
        if netstat -tlnp 2>/dev/null | grep -q 5588 || ss -tlnp 2>/dev/null | grep -q 5588; then
            echo "  API 端口 5588: 监听中"
        else
            echo "  API 端口 5588: 未监听!"
        fi
    else
        echo "  acc-gw: 未运行"
    fi

    # acc_core_conf.json check
    echo ""
    echo "--- CoreConfig ---"
    conf="/tmp/acc/acc_core_conf.json"
    if [ -f "$conf" ]; then
        cip=$(sed -n 's/.*"tproxy_ip":"\([^"]*\)".*/\1/p' "$conf" 2>/dev/null)
        cmode=$(sed -n 's/.*"acc_mode":\([0-9]*\).*/\1/p' "$conf" 2>/dev/null)
        lan_ip=$(uci get network.lan.ipaddr 2>/dev/null)
        echo "  tproxy_ip: $cip $( [ "$cip" = "$lan_ip" ] && echo '[OK]' || echo '[MISMATCH!]')"
        echo "  acc_mode: $cmode $( [ "$cmode" = "2" ] && echo '[OK]' || echo '[UNSTABLE!]')"
    else
        echo "  文件不存在"
    fi

    # Network: conntrack + qdisc
    echo ""
    echo "--- 网络 ---"
    ct_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
    ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
    if [ -n "$ct_count" ] && [ -n "$ct_max" ] && [ "$ct_max" -gt 0 ]; then
        ct_pct=$((ct_count * 100 / ct_max))
        echo "  conntrack: $ct_count / $ct_max ($ct_pct%)"
    fi
    wan_if=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
    [ -z "$wan_if" ] && wan_if=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    echo "  WAN: ${wan_if:-unknown}"
    if [ -n "$wan_if" ]; then
        qdisc=$(tc qdisc show dev "$wan_if" 2>/dev/null | head -1)
        echo "  qdisc: ${qdisc:-none}"
    fi

    # GAMEACC
    echo ""
    echo "--- GAMEACC ---"
    ipt_cmd="iptables-nft"
    [ -x /usr/sbin/iptables-nft ] || ipt_cmd="iptables"
    gc_count=$($ipt_cmd -t mangle -L GAMEACC -n 2>/dev/null | grep -c "TPROXY\|RETURN")
    echo "  活跃规则数: $gc_count"

    # TURN relay ping
    echo ""
    echo "--- TURN ---"
    ping -c 3 -W 2 route-turn.xxghh.biz >/dev/null 2>&1 && \
        echo "  route-turn.xxghh.biz: 可达" || \
        echo "  route-turn.xxghh.biz: 不可达!"

    echo ""
    echo "============================="
    exit 0
fi

# ============================================================
# CLI: leigod-fw4.sh disable-upgrade / enable-upgrade
# ============================================================
if [ "$1" = "disable-upgrade" ]; then
    acc_upgrade_disable
    exit $?
fi
if [ "$1" = "enable-upgrade" ]; then
    acc_upgrade_enable
    exit $?
fi

# ============================================================
# CLI: leigod-fw4.sh dns-guard
# Called by cron: refresh the pinned hosts entries for the CDN domains.
# ============================================================
if [ "$1" = "dns-guard" ]; then
    dns_guard_apply
    exit 0
fi

# ============================================================
# CLI: leigod-fw4.sh apply-luci
# Redeploy the embedded LuCI files without reinstalling the plugin.
# Handy when only the manager script was updated.
# ============================================================
if [ "$1" = "apply-luci" ]; then
    detect_pkg_mgr
    detect_firewall
    set_fw_packages
    ensure_uci_config
    apply_luci_fw4_patch
    rm -f /tmp/luci-indexcache* 2>/dev/null; rm -rf /tmp/luci-modulecache 2>/dev/null
    /etc/init.d/rpcd restart >/dev/null 2>&1
    /etc/init.d/uhttpd restart >/dev/null 2>&1
    echo "[INFO] LuCI 文件已重新部署，请刷新 Web 后台 (服务 → 雷神加速器)"
    exit 0
fi

# ============================================================
# CLI: leigod-fw4.sh verify-luci
# Verify LuCI installation integrity: 12 files + luci-compat
# + UCI config + auto-pause config.  Auto-repairs if possible.
# ============================================================
if [ "$1" = "verify-luci" ]; then
    detect_pkg_mgr
    detect_firewall
    set_fw_packages
    verify_luci
    exit 0
fi

# ============================================================
# CLI: leigod-fw4.sh env
# Print environment facts used by this script (read-only, no changes).
# ============================================================
if [ "$1" = "env" ]; then
    detect_pkg_mgr
    detect_firewall
    set_fw_packages
    echo "固件:   $(grep DISTRIB_DESCRIPTION /etc/openwrt_release 2>/dev/null | cut -d"'" -f2)"
    echo "内核:   $(uname -r)"
    echo "架构:   $(uname -m) / $(pkg_arch)"
    echo "防火墙: $FW_NAME"
    echo "包管理: $(pkg_mgr_name)"
    echo "LuCI:   lua=$(pkg_installed lua && echo yes || echo no) compat=$(pkg_installed luci-compat && echo yes || echo no) lua-runtime=$(pkg_installed luci-lua-runtime && echo yes || echo no)"
    echo "TPROXY: $(lsmod 2>/dev/null | grep -q nft_tproxy && echo loaded || echo not-loaded)"
    echo "LAN:    $(uci get network.lan.ipaddr 2>/dev/null)"
    exit 0
fi

# ============================================================
# Main - Initialize and start
# ============================================================
detect_pkg_mgr
detect_firewall
set_fw_packages

check_openclash_mode
check_acceleration
check_logs
check_bypass_gateway

# Brief pause so diagnostic messages above are readable before the menu renders
if [ "$FW_TYPE" = "fw4" ] || [ -n "$(pgrep -f openclash 2>/dev/null)" ]; then
    echo ""
    sleep 2
fi

while true; do
    leigod_menu
    read choice
    case $choice in
        1)
            install_leigodacc
            ;;
        2)
            uninstall_leigodacc
            ;;
        3)
            reinstall_leigodacc
            ;;
        4)
            service
            ;;
        5)
            switch_mode
            ;;
        6)
            install_compatibility_dependencies
            ;;
        7)
            disabled_ipv6
            ;;
        8)
            install_lean_ipkg_version
            ;;
        9)
            auto_pause_menu
            ;;
        [sS])
            check_service_status
            ;;
        [lL])
            diagnose_latency
            ;;
        [tT])
            apply_network_tuning
            ;;
        [dD])
            dns_guard_menu
            ;;
        [uU])
            acc_upgrade_menu
            ;;
        [hH])
            help
            ;;
        0)
            exit 0
            ;;
        *)
            echo "[ERROR] 请重新输入对应功能的数字/字母并回车!"
            ;;
    esac
done
