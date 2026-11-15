# Changelog — LeigodAcc Manager fw4 适配版

基于 [openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager) 修改，适配 iStoreOS 25.12（OpenWrt 25.12 / apk）+ fw4/nftables 防火墙。

## v3.2.0 (2026-11-06) — DNS 兜底 + 数据面诊断（解决「隧道空转、游戏不加速」）

### 故障现象与根因

真机上出现：APP 显示加速中、`GAMEACC` 规则计数在涨、隧道心跳正常（`42.240.152.197:1905`、
`14.17.92.181:27438`），但**游戏完全没被代理**（`S5 UDP` 计数 0、隧道字节只有心跳量、
`direct_Game` 集合为空），查 IP 站点显示本地地址。

逐层定位后确认根因：**路由器本机解析不到引擎的 CDN 域名**。

```
nslookup dfs01.nn.com            → 只返回 CNAME，没有 A 记录（dnsmasq / :53）
nslookup dfs01.nn.com 127.0.0.1:5335 → A 记录齐全（MosDNS）
nslookup dfs01.nn.com 223.5.5.5      → A 记录齐全（公共 DNS）
web_api.log → Failed to download file(.../mac.json) HTTP Status: 0
```

引擎的路由数据全部来自 `dfs01.nn.com`：

| 文件 | 作用 | 条数 |
|---|---|---|
| `mac.json` | 设备类型（MAC OUI）库 | 309 |
| `cidrs.txt` | **该走隧道的游戏网段** | 6624 |
| `cidrs_direct.txt` | 该直连的网段（填 `direct_Game`） | 9 |

三份都拿不到 → 引擎没有分流表 → 一切按直连处理 → 隧道只剩心跳。

### 1. 新增「DNS 兜底」（菜单 D / CLI `dns-guard`）

- 依次检测 `dfs01.nn.com`、`opapi.xxghh.biz`、`opapi1.xxghh.biz`、`nbox.nn.com`
  的本机解析；本机失败而公共 DNS（默认 223.5.5.5）可解析时，把 IPv4 固定进 `/etc/hosts`
- 写入内容用 `# >>> leigod-fw4 dns guard >>>` / `# === leigod-fw4 dns guard end ===`
  包裹，重复执行只保留一个块，可一键移除
- 本机解析正常的域名不做固定，避免 CDN IP 过期影响
- 菜单 D 提供「写入/移除/查看」三个动作，并可选立即重启服务
- `dns-guard` cron 每 6 小时刷新一次（CDN IP 会变）
- 安装完成后若检测到 `dfs01.nn.com` 本机解析失败，会直接给出倒 WARN 指引

### 2. 诊断页新增四项「假加速」检查

| 检查 | 判据 |
|---|---|
| 引擎 CDN 域名本机可解析 | `nslookup dfs01.nn.com` 必须拿到 A 记录 |
| 分流表已加载 | `ipset list direct_Game` 非空 |
| 加速隧道心跳 | `acc_Game.log` 的 `TunnelHeartBeat`（含服务器与延迟） |
| TPROXY 策略路由 | `ip rule` 有 `fwmark 0x99` 且 `table 99` 有 `local default dev lo` |

外加「加速规则注入成功」（扫引擎日志 `add ip routes failed` 等）。

### 3. 测试

新增 `scripts/test-dns-guard.sh`：用桩 `nslookup` 模拟「本地只回 CNAME、公共 DNS 正常」，
验证固定、幂等、跳过健康域名、移除还原，共 11 项断言。

### 4. 顺带修复

- 卸载：`rm -f /tmp/acc_install_lib`（目录，无效）改为 `rm -rf`；补清引擎的 `.lock` 文件；
  iptables 符号链接从「删除」改为恢复为 `xtables-nft-multi`
- `validate-shell.py` 支持跨行单引号（多行 awk 程序），消除误报

## v3.1.3 (2026-11-06) — 卸载彻底化

真机测试卸载后发现：**引擎 INI 配置、crontab、自动暂停文件、LuCI 菜单缓存**都还有残留，
LuCI 侧边栏仍显示「雷神加速器」，点进去 404。原因是 v1.x 时代的卸载只覆盖了老布局。

### 1. 卸载覆盖全部新布局产物

| 类别 | 新增清理项 |
|---|---|
| 引擎配置 | `/etc/config/accelerator.ini`、`acc_firewall.ini`、`acc_version.ini`、`acc_core_conf.json`、`ipdatacloud_country.xdb`、`upgrade_data.json`、旧 `/etc/config/leigod` |
| 运行时 | `/tmp/acc`（锁/日志/JSON/socket）、`/tmp/acc_install_lib`、`acc-lib.tar.gz`、`acc-bundle-*.tar.gz`、`acc_domain_config_*.json`、`leigod_acc_*.log` |
| cron | **无条件**删除 `leigod-auto-pause`、`leigod-fw4.sh fix-tproxy` 及含 `leigod` 的行（原先只在自动暂停脚本存在时才删） |
| 自动暂停 | 脚本/配置/状态/日志/离家模式标记，全部**无条件**清理 |
| LuCI | 12 个 Lua 文件 + i18n lmo + `menu.d`/`acl.d`/`view` 的 JS 时代残留 |
| 防火墙 | UCI 规则（循环删除所有 `LeigodAcc`）、hotplug、**mangle/filter/nat 三表 GAMEACC**、`ipset` 的 `direct_*/target_*/proxy_*`、`nft table inet tproxy_table` |
| 其他 | opkg 垫片、`iptables-nft` 符号链接、LuCI indexcache |

### 2. 优先调用官方卸载脚本

安装包自带 `/usr/sbin/leigod/leigod_uninstall.sh`（官方 web 接口卸载也用它）。
现在先执行它，再做手动兜底清理，避免漏掉官方后续新增的文件。

### 3. 卸载判定放宽

原来只要 `/usr/sbin/leigod` 不存在就报「未安装」，导致**半残留状态无法再次卸载**。
新增 `leigod_installed()`：二进制目录 / init 脚本 / UCI / INI / LuCI 控制器 / 包名，
任一存在即可卸载。

### 4. LuCI 菜单 404 的成因与处理

菜单条目来自 `/usr/lib/lua/luci/controller/acc.lua`（已删除，所以路由 404）。
侧边栏仍显示是**浏览器/主题侧缓存**。现在卸载结束会：

- `rm -f /tmp/luci-indexcache*`
- 重启 `rpcd`（使所有 LuCI 会话失效，需要重新登录）
- 重启 `uhttpd`

并提示用户重新登录后台或 `Ctrl+Shift+R` 强制刷新。

### 5. 卸载后自检

新增残留扫描：逐项检查配置/init/LuCI/cron/运行目录，输出
`[OK] 卸载完成，未发现残留` 或列出未清理项；同时说明**有意保留**的两项
（`/etc/config/upnpd` 的 UPnP 设置、`/etc/sysctl.d/99-leigod-latency.conf` 内核调优）。

### 6. 新增测试

`scripts/test-uninstall-coverage.sh`：静态校验卸载函数仍引用全部 28 个已知产物路径，
防止后续改动漏项。

## v3.1.2 (2026-11-05) — 桥自检改为「页面探测」+ 两处噪声修正

### 1. `verify_luci` 的桥自检彻底换掉

v3.1.1 用 `ucode` 独立进程 `require("luci.ucodebridge")` 仍不可靠——`luci.ucodebridge`
依赖 CGI/uhttpd 环境（`luci.http`、`luci.template` 在独立进程里初始化失败），
在真机上必然误报 FAIL。

改为**探测效果而非机制**：

```
curl -sk http://127.0.0.1:<uhttpd端口>/cgi-bin/luci/admin/services/acc/service
```

| 返回码 | 判定 |
|---|---|
| **404** | Lua 控制器未被加载 → FAIL，并给出修复命令 |
| 401 / 403 / 200 / 301 / 302 | 路由已注册（未登录返回鉴权码属正常）→ OK |
| 000 | 本机访问不到 LuCI → WARN（跳过） |

端口从 `uhttpd.main.listen_http` / `listen_https` 解析，默认 80。

### 2. 模板模式被误判为「模式不一致」

诊断页出现 `Mode mismatch: init script specifies ${mode} but process is running as tproxy`。
原因：`model` 一致性检查把 `${mode}` 当成字面模式值。已改为
`and not resp.init_script.template_mode` 时跳过该比较。

### 3. 错误日志仍显示小时前的旧记录

v3.1.1 只做了白名单过滤，但 `tail -5` 取的是**整个文件**最后 5 条匹配行，
几小时前那次网络故障的记录仍会被翻出来。改为先 `tail -n 200` 再看，
并把可选功能的噪声（`log report switch failed` / `router_log_report_config`）加入白名单。

## v3.1.1 (2026-11-05) — 修正 v3.1.0 引入的三处判断错误

真机回归时发现 v3.1.0 有三个自身 bug（都与"判断条件写错"有关，不影响插件功能）：

### 1. Lua 桥自检永远 FAIL（误报）

`require("luci.dispatcher")` 在裸 `lua -e` 里**不可能成功**——`dispatcher.lua` 第一行就是
`local http = _G.L.http`，而 `_G.L` 只存在于 ucode→Lua 桥里。同理 `require("luci.cbi")`
也会连带 require dispatcher 而失败。

改为**按真实调度路径自检**：用 ucode 创建 Lua VM 并 `require("luci.ucodebridge")`
（与 `dispatcher.uc` 的 `L.invoke('require','luci.ucodebridge')` 完全一致），
再检查 `ucodebridge.lua` / `cbi.lua` 文件存在。

### 2. `-m ${mode}` 模板识别失效

`args_line:find("%-m ${mode}", 1, true)` —— plain 模式下 `%-m` 是字面量（反斜杠不会转义），
永远匹配不到。改为 `args_line:find("-m ${mode}", 1, true)`。
症状：诊断页仍显示「模式标志 MISSING → UNKNOWN / 短格式 No」，并因此产生 1 个假的 error 计数。

### 3. `acc_firewall.ini` 解析漏掉下划线键

`line:match("^(%w+)=(.*)$")` 中 `%w` 不含 `_`，导致 `tproxy_ip` 解析为 nil，
诊断页出现「acc_firewall.ini tproxy_ip=nil」。改为 `^([%w_]+)=`。

### 4. 附带改进

- 错误日志扫描过滤引擎的**无害噪音**：`acc_objs is empty`、
  `delete iptables rule failed`（清理不存在的规则）、`unknow acc mode`、`acceleration is empty`
- JSON 诊断的依赖表补上 `luci-lua-runtime`
- `verify_luci` 的「设备条目数」不再因 `grep -c` 退出码而打印两行 `0`
- 新增 `scripts/check-luci-sync.py`：校验内嵌 Lua 与 `luci-fw4-patch/` 副本一致性

## v3.1.0 (2026-11-05) — 对齐官方 v1.2.2.x 引擎的 INI 配置模型

真机验证发现：官方安装器 **v1.2.2.x** 已把加速参数从 UCI/JSON 迁到 **INI**，且 `tproxy_ip`
是**按后端固定的哨兵值**（不是 LAN IP）。旧版管理器的「强制改成 LAN IP」逻辑会把配置改坏。
本版按官方 `lib/setup.sh` 的实现对齐。

### 1. 双布局识别（new / legacy）

| 布局 | 判定 | 权威来源 | tproxy_ip 语义 |
|---|---|---|---|
| `new` | 存在 `/etc/config/acc_firewall.ini` | `[firewall] backend/mode/tproxy_ip` | iptables→`10.20.30.40`，nftables→`0.0.0.0`（官方 `get_tproxy_ip_by_backend()`） |
| `legacy` | 无 INI（v1.2.2.13 及更早） | `/tmp/acc/acc_core_conf.json` | 必须是 LAN IP，`acc_mode` 必须为 2 |

- `fix_acc_core_conf()` 改为分发器，新增 `fix_acc_new_layout()` / `fix_acc_legacy_layout()`
- **new 布局下不再改写 tproxy_ip 为 LAN IP**；只补齐缺失键、把非哨兵值校正回哨兵值、
  并把 JSON 的 `tproxy_ip` 对齐到 INI（不再自造数值）
- 配置真的发生变化时才重启服务（新增 `restart_acc_service()`），避免每次 cron 都打断加速

### 2. 端口检测改用 `/proc/net/tcp`

iStoreOS 25.12 **没有 `ss`**（`apk add iproute2-ss` 报无此包），netstat 也可能缺失。
新增 `port_listening()`：直接解析 `/proc/net/tcp`、`/proc/net/tcp6`，按十六进制端口
（5588 → `15D4`）与 `st == 0A`（LISTEN）判断。Shell 侧与 Lua 诊断页同步改造。

### 3. 安装后健康检查 `acc_health_check()`

安装/重启后最多等待 20 秒确认 5588 是否 LISTEN；未就绪时明确报错，并给出可执行线索：

- 检测 `acc_daemon.log` 中 `child process exit` 的重复次数 → 判定「web 子进程崩溃循环」
- 若 `web_api.log` 出现 `start global config manager failed`，提示这是「拉取雷神全局配置失败」
  （双栈网络下 IPv6 不可达且客户端不回落 IPv4 / DNS 异常 / 上游接口故障），并给出
  `curl -4` / `curl -6` 对照命令

### 4. 诊断页增强（Lua，内嵌 + 独立副本同步）

- ✅ **新增「web 子进程崩溃循环」error 级检查**（本次真实故障此前被淹没）
- ✅ 新增 `acc_firewall.ini` 解析与哨兵值校验（`backend`/`mode`/`tproxy_ip`）
- ✅ `tproxy_ip` 校验改为布局感知：new 布局比 INI，legacy 比 LAN IP
- ✅ init 脚本参数识别 `-m ${mode}` 模板（不再误报 `MISSING`）
- ✅ 开机自启改用 `os.execute` 退出码（procd `enabled` 不打印文字，此前恒报 No）
- ✅ 错误日志扫描只取 `ERROR|WARN|FATAL` 行（`child process exit ... INFO` 不再算错误）
- ✅ 文本报告同步：端口用 `/proc/net/tcp`、tproxy_ip 对比 INI、模板模式识别

### 5. 其他修复

- `switch_mode()`（菜单 5）：new 布局下改为读写 `acc_firewall.ini` 的 `mode=` 并重启，
  不再用 sed 改 init 脚本（会把 `args="-m ${mode}"` 模板改坏）；legacy 逻辑保留
- `ensure_uci_config()`：先创建 `/etc/config/accelerator` 再 `uci set`
  （25.12 的 uci 对不存在的配置直接报 `Entry not found`），并静默 stderr
- `verify_luci()` 的 Lua 桥自检去掉 `require("luci.http")`（25.12 无此 Lua 模块，
  http 由 `_G.L.http` 注入），此前误报 FAIL
- `luci-fw4-patch/` 全部文件统一为 LF（原先为 CRLF）
- 服务配置页文案更正：说明 v1.2.2.x 的实际参数在 INI、设备由 APP 下发
- 新增 `scripts/validate-lua.py`（无 Lua 解释器环境下的块/括号结构校验）

### 修改文件

| 文件 | 变更 |
|------|------|
| `leigod-fw4.sh` | 双布局配置修复、/proc 端口检测、健康检查、诊断增强、switch_mode 改造 |
| `luci-fw4-patch/luasrc/controller/acc.lua` | 崩溃循环检测、INI 校验、模板模式识别、开机自启、日志过滤、端口检测 |
| `luci-fw4-patch/luasrc/model/cbi/leigod/service.lua` | 文案更正（INI 为准 / APP 下发设备） |
| `scripts/validate-lua.py` | 新增 |

## v3.0.0 (2026-11-05) — OpenWrt 25.12 / iStoreOS 25.12 (apk) 适配

目标环境：iStoreOS 25.12.5（OpenWrt 25.12.5 / kernel 6.12 / x86_64 / apk-tools 3.0.5，**无 opkg 二进制**）。

### 1. 新增 apk/opkg 双栈包管理抽象层

全文 50+ 处 `opkg` 调用改为统一封装，按 `command -v apk` 自动选择后端：

| 封装函数 | apk | opkg |
|---|---|---|
| `pkg_installed` | `apk info -e` → 回落 `apk info \| grep -x` | `opkg list-installed \| grep` |
| `pkg_available` | `apk search -x` → 回落 `apk search` | `opkg list \| grep` |
| `pkg_update` | `apk update` | `opkg update` |
| `pkg_install_raw` | `apk add` | `opkg install` |
| `pkg_remove_raw` | `apk del` | `opkg remove` |
| `pkg_arch` | `apk --print-arch` | `opkg print-architecture` |
| `pkg_hint` | `apk update && apk add …` | `opkg update && opkg install …` |
| `pkg_show_feeds` | `/etc/apk/repositories.d/*.list` | `/etc/opkg/distfeeds.conf` |

旧名 `safe_opkg_install()` 保留为 `safe_pkg_install()` 的别名。

### 2. 官方安装器 opkg 垫片

雷神官方 `plugin_install.sh` 内部仍调用 `opkg`，在 apk 系统上会全部报 `command not found`。新增 `install_opkg_shim()`：在 `/tmp/leigod-pkgshim/opkg` 生成 opkg→apk 转换垫片（`update/install/remove/list/list-installed/files/print-architecture`），**仅在那一次官方脚本调用时通过 PATH 注入**，不写入 `/usr/sbin`。卸载时自动清理。

### 3. 包名差异修正

| 用途 | opkg (≤24.10) | apk (≥25.12) |
|---|---|---|
| pcap 运行库 | `libpcap` | **`libpcap1`** |
| UPnP 服务 | `miniupnpd` | **`miniupnpd-nftables`** |

- `set_fw_packages()` 按包管理器设置 `PKG_LIBPCAP` / `PKG_UPNP`
- 新增 `ensure_upnpd()`：UPnP 缺失时尝试安装，并**不再因 `/etc/config/upnpd` 缺失而中断整个安装**
- 诊断页/诊断报告的包检查对 `libpcap`↔`libpcap1` 双向探测

### 4. LuCI：沿用 Lua CBI + 显式要求兼容层

OpenWrt 25.12 的 LuCI 调度器已改为 ucode，但官方保留 Lua 兼容通道：`dispatcher.uc` 仍会 glob `/usr/lib/lua/luci/controller/*.lua`，在 `luci-lua-runtime` 存在时通过 `runtime.call('luci.dispatcher','process_lua_controller', …)` 加载。

- `luci-compat`、`luci-lua-runtime` 提升为**硬依赖**，安装时检测并补装
- `verify_luci()` 重写为 5 段：兼容层包 → **Lua 调度桥自检**（`lua -e 'require("luci.dispatcher")'`）→ 12 个文件 → UCI → 自动暂停
- 缓存清理从 `rm -rf /tmp/luci-*` 改为 `rm -f /tmp/luci-indexcache*` + 重启 `rpcd`
- 使用须知页补充依赖与兼容层说明

### 5. 移除 .ipk 分发路径

- 菜单选项 8（Lean IPKG 版）在 apk 系统上**直接返回并提示"25.12 不支持 .ipk"**，不再尝试下载安装
- `install_compatibility_dependencies()` 删除 23.05.3 的 .ipk 直链下载逻辑（仅保留给 opkg 系统），改为按软件源可用性安装
- 架构检测改 `pkg_arch`

### 6. 其他

- 新增 CLI `leigod-fw4.sh env`：打印固件/内核/架构/防火墙/包管理/LuCI 兼容层状态（只读）
- 主菜单与帮助显示当前包管理器；安装前打印 APK 软件源
- 安装完成后提示 Docker 网桥（`172.17.0.0/16`）不在 acc-gw 默认直连列表，便于排查容器流量异常
- 新增 `scripts/validate-shell.py`：无 POSIX shell 环境下的结构自检（heredoc/块/大括号/CRLF）

### 修改文件

| 文件 | 变更 |
|------|------|
| `leigod-fw4.sh` | 包管理抽象层 + 垫片 + UPnP + LuCI 兼容层 + 诊断/帮助/CLI 全面 apk 化 |
| `luci-fw4-patch/luasrc/controller/acc.lua` | 包检查双栈探测（`apk info -e` + `opkg list-installed`） |
| `luci-fw4-patch/luasrc/view/leigod/notice.htm` | 依赖清单按 apk/opkg 分列 + LuCI 兼容层说明 |
| `scripts/validate-shell.py` | 新增结构校验器 |

## v2.5.2 (2026-08-15) — LuCI 兼容性修复 + 部署修复

### 设备管理页 Runtime error 修复

`/usr/lib/lua/luci/model/cbi/leigod/device.lua` 使用了 Lua 5.2+ 的 `goto`/`continue` 语法，LuCI 运行环境为 Lua 5.1，导致整页编译失败：

```
/usr/lib/lua/luci/model/cbi/leigod/device.lua:52: '=' expected near 'continue'
```

- `goto continue` / `goto continue_arp` 改写为 Lua 5.1 兼容的 `if not (...)` 嵌套（2 处）
- `leigod-fw4.sh` 内嵌 heredoc 与 `luci-fw4-patch/` 独立副本同步修复
- 块配平校验通过（if 链 13 + do 4 + function 1 = end 18）

### 部署失败修复（CRLF 行尾）

Windows 检出文件为 CRLF 行尾时，shebang 变为 `#!/bin/sh\r`，内核找不到解释器，报 `not found`：

- 新增 `.gitattributes`（`*.sh text eol=lf`），强制 sh 脚本 LF 行尾，防止 git 检出再转 CRLF

### Release 产物：压缩版

- 新增 `leigod-fw4.min.sh`（heredoc 感知压缩：删注释行/空行，保留 shebang 与全部内嵌文件内容，209KB → 193KB）
- 压缩器 `scripts/minify-leigod.py` 可复现产物
- 等价性已验证：heredoc 内容逐字节一致、代码行零丢失、运行时输出一致

## v2.4.0 (2026-05-31) — 单文件部署 + 诊断增强 + 自动暂停内嵌

### leigod-fw4.sh 完全自包含

所有 LuCI 补丁和 auto-pause.sh 已内嵌到 `leigod-fw4.sh`：

| 内嵌组件 | 数量 | 说明 |
|----------|------|------|
| LuCI 文件 | 12 个 | controller + model/cbi (6) + view (5) |
| auto-pause.sh | v2.5 | 自动暂停脚本 (cron 调用) |
| hotplug 脚本 | 1 个 | fw4 防火墙重载守护 |

**不再需要 `luci-fw4-patch/` 目录或 `auto-pause.sh` 独立文件。** 单文件 SCP → 菜单选 3 重装 → 菜单选 9→1 部署自动暂停，全部完成。

### 诊断页面增强

- **延迟诊断**：三项 ping 测试（网关/DNS/TURN 中继），Min/Avg/Max 表格对齐，丢包率
- **加速节点列表**：从 `acc_core_conf.json` 提取雷神分配的节点 IP 和测速延迟
- **自动分析**：网关 >10ms → WiFi/LAN 问题；TURN-网关 >50ms → 服务器端延迟
- **排版重写**：中文感知对齐（汉字占 2 字符宽度），标签列固定 14 字符
- **误报修复**：
  - GAMEACC 链检测改用 `os.execute()` exit code（不再误报 NOT found）
  - TPROXY 模式不再无谓报警（此二进制仅支持 TPROXY）
  - 开机自启从 warning 降为 info + 修复建议

### 设备加速状态修复

daemon 不写 UCI，状态在 `acc_core_conf.json` 中。改为从 JSON 实时读取：
- `find('"PC":')` 定位分类键 + `match('"state":(%d+)')` 提取状态
- device_type 映射为分类名（PC→电脑, Phone→手机, Game→游戏主机）

### 书签一键获取 Token（物理最优方案）

- **`save_token` LuCI 端点**：接受书签 GET/手动 POST，写入配置文件
- **autopause.htm 书签 UI**：可拖拽按钮 + 手动粘贴框
- **CloudWAF 最终结论**：登录 API 从所有网络来源（家庭宽带/CF/GitHub Actions/本地）均返回 418，全自动化不可行。书签 5 秒/7 天是物理极限

### 修改文件

| 文件 | 变更 |
|------|------|
| `leigod-fw4.sh` | **全部 13 个文件内嵌** (+500 行)；`fix_acc_core_conf()` 强制 mode=2；`auto_pause_install()` 内联脚本回退 |
| `luci-fw4-patch/luasrc/controller/acc.lua` | 延迟诊断 + GAMEACC exit code + 设备状态从 JSON 读取 + save_token + 中文化 |
| `luci-fw4-patch/luasrc/view/leigod/debug.htm` | 重写：对齐排版 + 延迟表格 + 原生 XMLHttpRequest |
| `luci-fw4-patch/luasrc/view/leigod/autopause.htm` | 书签 UI + save_token 按钮 |
| `luci-fw4-patch/luasrc/model/cbi/leigod/autopause.lua` | 移除用户名/密码字段，新增 IDLE_CHECK_INTERVAL |
| `auto-pause.sh` | v2.5 精简版 (176 行) — 仅书签 token + 自定义空闲间隔 |

---

## v2.4.1 (2026-06-10) — 离家模式 Bug 修复 (8 项)

### 严重修复：Debug 页面离家模式状态始终显示"自动模式"

**现象：** LuCI Debug 页面和自动暂停状态页面的"离家模式"行始终显示"自动模式"，即使 `/etc/leigod-auto-pause.conf` 中 `MANUAL_DISABLE=1`。

**根因：** `get_debug_status()` 中的 `break` 语句——当找到 `ACCOUNT_TOKEN` 行后立即退出 for 循环，而 `MANUAL_DISABLE` 行位于配置文件末尾，永远无法被解析到。

**修复：** 移除 `break`，让循环完整遍历所有配置行。涉及 `leigod-fw4.sh` 内嵌 Lua（`luci-fw4-patch/luasrc/controller/acc.lua` 此前已正确）。

### 修复：离家模式切换后过早自动暂停

**现象：** 开启离家模式前设备已累积空闲计数（如 2/3），关闭离家模式后首次检测即触发暂停（本应等待 6 分钟）。

**根因：** `main()` 在离家模式下直接 `return`，跳过 `read_state`/`write_state`。状态文件中的 `idle_count` 未被重置，存活到离家模式关闭之后。

**修复：** 在离家模式分支中先 `read_state`，若 `IDLE_COUNT ≠ 0` 则重置为 0 并 `write_state`，确保退出离家模式后从零开始计数。

### 修复：`save_token()` 默认配置缺少 `MANUAL_DISABLE`

**现象：** 通过书签保存 token 到空白/新建配置文件时，生成的默认配置缺失 `MANUAL_DISABLE` 行。

**修复：** `save_token()` 默认模板追加 `MANUAL_DISABLE=0`。涉及 `leigod-fw4.sh` 和 `luci-fw4-patch/luasrc/controller/acc.lua`。

### 修复：`trigger_autopause()` 绕过离家模式守卫

**现象：** LuCI "立即暂停"按钮直接调用 pause API，不检查离家模式状态。用户在离家模式下仍可手动暂停（与"禁止自动暂停"的设计意图冲突）。

**修复：** `trigger_autopause()` 新增离家模式检查——`MANUAL_DISABLE=1` 时返回错误 `"离家模式已启用, 手动暂停被禁止"`。

### 修复：离家模式日志泛滥

**现象：** 离家模式下 cron 每 2 分钟运行一次，每次都写 `logger`（720 条/天），造成不必要的 syslog 膨胀。

**修复：** 使用 `/tmp/leigod-away.logged` 标记文件——仅在首次进入离家模式时写日志，后续 cron 触发静默跳过。退出离家模式时自动清理标记。

### 修复：Shell `cut -d= -f2` 解析脆弱性

**现象：** `verify_luci()` 和 `auto_pause_status()` 使用 `grep | cut -d= -f2` 提取 `MANUAL_DISABLE` 值。若配置值意外含 `=`，解析结果错误。

**修复：** 替换为 `sed 's/^MANUAL_DISABLE=//'`，精确削去前缀。

### 修复：`get_debug_report()` token 覆盖

**现象：** v2.4.0 中移除 `break` 后，若配置文件异常含多条 `ACCOUNT_TOKEN` 行，后续行会覆盖之前的解析结果（从 first-match 变为 last-match 语义）。

**修复：** 添加 `and not token_ok` 守卫，保留首次匹配语义。

### 修改文件

| 文件 | 变更 |
|------|------|
| `leigod-fw4.sh` | `get_debug_status()` 移除 break；`main()` 离家模式重置 IDLE_COUNT + 日志节流；`save_token()` 默认模板追加 MANUAL_DISABLE；`trigger_autopause()` 新增离家模式检查；`verify_luci()`/`auto_pause_status()` 替换 cut→sed；`get_debug_report()` 添加 token 守卫 |
| `auto-pause.sh` | `main()` 离家模式重置 IDLE_COUNT + 日志节流 |
| `luci-fw4-patch/luasrc/controller/acc.lua` | `save_token()` 默认模板追加 MANUAL_DISABLE；`trigger_autopause()` 新增离家模式检查；`get_debug_report()` 添加 token 守卫 |

---

## v2.3.3 (2026-05-31) — 延迟抖动根因修复 + 内核网络调优 + 重装配置保护

### 严重修复：reinstall_leigodacc() 配置丢失

**现象：** 运行选项 3（重装/更新）后，OpenWrt LuCI 界面中所有配置选项全部丢失（设备绑定、加速状态、自动暂停配置等）。

**根因：** `uninstall_leigodacc()` 执行 `rm -f /etc/config/accelerator` 和 `rm -f /etc/leigod-auto-pause.conf`。重装流程 `uninstall → install` 无条件删除用户配置，官方安装器重建的配置为空。

**修复：** `reinstall_leigodacc()` 重写：
- **重装前备份**：`/etc/config/accelerator` → `/tmp/accelerator.bak.$$`、`/etc/leigod-auto-pause.conf`、LuCI 文件目录（model+view+controller，三层完整备份）
- **重装后恢复**：UCI 配置、自动暂停配置、LuCI 文件（仅当安装后缺失时从备份恢复，不影响官方安装器写入的文件）
- **LuCI 文件完整性验证**：`install_leigodacc()` 安装后检查 5 个关键 LuCI 文件是否存在，缺失时输出具体路径和修复建议

### 新增功能：LuCI 完整性验证 (verify_luci)

`verify_luci()` 函数 + CLI `leigod-fw4.sh verify-luci` — 4 段全面检查：

| 检查段 | 内容 | 自动修复 |
|--------|------|----------|
| [1/4] luci-compat 包 | 是否安装（缺失→ LuCI 页面无法渲染） | ✅ opkg install |
| [2/4] 12 个文件完整性 | controller×1 + model×6 + view×5 | ✅ 触发内联补丁写入 |
| [3/4] UCI 配置 | base/device/@system[0] 三个必要 section | ✅ ensure_uci_config |
| [4/4] 自动暂停配置 | token 是否已配置 | 提示 |

**集成点：**
- `install_leigodacc()` 安装完成后自动运行
- `reinstall_leigodacc()` 备份恢复后自动运行
- CLI `leigod-fw4.sh verify-luci` 随时手动运行

### 严重修复：auto_pause_install() 语法错误

`auto_pause_install()` 中残留了 6 行来自 v2.3.2 清理不彻底的垃圾代码（多余的 `fi`、未定义的 `$username` 变量、额外的 echo），导致函数在 token 未配置时执行失败。修复：完整清理残留代码。

### 延迟诊断增强 (diagnose_latency)

**6→6 步骤诊断**（原来是 5 步），全部增强：

| 步骤 | 增强内容 |
|------|----------|
| [1/6] QoS | 无变化（已完善） |
| [2/6] GAMEACC | **iptables-nft/iptables 自动回退** — 无独立 `iptables-nft` 二进制时使用 `iptables` |
| [3/6] conntrack | **一键自动扩大** — 使用率 > 80% 时主动询问 `是否立即扩大到 2×?`，而非仅打印建议 |
| [4/6] DNS | **iptables 回退** — 同步骤 2 |
| [5/6] TURN | **抖动测量 (mdev)** — 从 ping 提取 min/max/mdev；mdev > 15ms 警告，> 50ms 标记为失败 |
| **[6/6] PPPoE** | **全新步骤** — 检查 TCP MSS clamping 是否就位、MTU 合理性（< 1492 警告）、一键添加缺失的 MSS clamping |

**推荐摘要更新**：新增第 4 步 `运行 leigod-fw4.sh tune-network`。

### 新增功能：内核网络调优 (apply_network_tuning)

全新的 `apply_network_tuning()` 函数 + 菜单 `T` 选项 + CLI `leigod-fw4.sh tune-network` 命令。

**写入 sysctl 持久化配置** `/etc/sysctl.d/99-leigod-latency.conf` 并**立即生效**：

| 参数 | 值 | 作用 |
|------|-----|------|
| `net.core.default_qdisc` | `fq_codel` | 防 bufferbloat（公平队列 + AQM） |
| `net.ipv4.tcp_congestion_control` | `bbr` | 更适合有损/抖动链路的拥塞控制 |
| `net.core.rmem_max/wmem_max` | `4194304` (4MB) | 防止突发流量丢包 |
| `net.core.rmem_default/wmem_default` | `262144` (256KB) | 增大默认 socket 缓冲区 |
| `net.ipv4.tcp_fastopen` | `3` | 减少连接建立 1 RTT |
| `net.netfilter.nf_conntrack_max` | `65536` | 防止 conntrack 表满 |
| `net.netfilter.nf_conntrack_tcp_timeout_established` | `3600` (1h) | 更快释放过期连接 |
| `net.ipv4.tcp_keepalive_time` | `120` (2min) | 快速检测断连 |

**安全检查**：应用后自动验证 BBR 是否实际激活（检查 `/proc/sys/net/ipv4/tcp_available_congestion_control`），不激活时输出提示。

### 新增功能：非交互式诊断 CLI

`leigod-fw4.sh diagnose` — 纯文本报告模式（无 y/n 交互），适合 cron 作业或脚本化监控。

**6 段报告**：
- **系统**：设备型号、固件版本、内核、防火墙类型
- **进程**：acc-gw PID/模式/端口 5588 监听状态
- **CoreConfig**：tproxy_ip 正确性、acc_mode 稳定性
- **网络**：conntrack 使用率、WAN 接口 qdisc
- **GAMEACC**：活跃规则数
- **TURN**：中继可达性

### 菜单更新

| 变更 | 说明 |
|------|------|
| 新增 `T` 选项 | 主菜单 + case 分支 + 帮助文本 |
| iptables fallback | `diagnose_latency()` 和 `diagnose` CLI 均支持 |

### 修改文件

| 文件 | 变更 |
|------|------|
| `leigod-fw4.sh` | 修复 auto_pause_install 语法错误；增强 diagnose_latency（6 步骤 + auto-conntrack + PPPoE MSS + TURN mdev + iptables fallback）；新增 apply_network_tuning 函数；新增 CLI diagnose/tune-network 入口；菜单 T 选项 |
| `CHANGELOG.md` | v2.3.3 条目 |
| `UPDATE.md` | 版本号 + 菜单 + CLI 命令 + 新增章节 |

---

## v2.3.2 (2026-05-30) — 自动暂停重构 + LuCI 全中文化 + 一键获取 Token

### 自动暂停：精简为书签方案（放弃自动化登录尝试）

经过多轮测试，雷神登录 API (`/wap/login/bind/v1`) 已被 CloudWAF(418) 从**所有网络来源**封锁：
- ❌ 家庭宽带 (路由器 → 418)
- ❌ Cloudflare Worker (边缘节点 → 418)
- ❌ GitHub Actions (数据中心 IP → 418)
- ❌ 本地开发机 (企业宽带 → 418)

暂停 API (`/api/user/pause`) **不受影响**，有有效 token 即可正常调用。

**最终方案（物理极限）**：
| 环节 | 方式 | 操作频率 |
|------|------|----------|
| 获取 token | LuCI 书签一键获取 (bookmarklet) | 每 7 天 5 秒 |
| 空闲检测 | cron 定时检查 GAMEACC 规则 + UCI 状态 | 全自动 |
| 调用暂停 | curl POST `/api/user/pause` | 全自动 |

**清理的代码**（已删除）：
- `login_and_get_token()` — 签名登录函数 (CloudWAF 拦截)
- `extract_daemon_token()` — daemon token 提取 (返回 400006, 不适用)
- `USERNAME`/`PASSWORD`/`PASSWORD_MD5` 配置项及 MD5 自动转换逻辑
- `CF_WORKER_URL` Cloudflare Worker 方案
- `TOKEN_GIST_URL` GitHub Actions + Gist 方案
- `cf-worker/` 和 `github-actions/` 目录

**新增**：
- `save_token` LuCI API 端点 — 接受书签/手动 POST 写入 token
- 自动暂停页面 "一键获取 Token" 区域 — 书签拖拽 + 手动粘贴两种方式
- `IDLE_CHECK_INTERVAL` 配置 — 自定义检测间隔 (1~30 分钟)
- cron 自动按间隔更新 — LuCI 修改间隔后无需手动改 crontab
- 空闲检测优化 — UCI state + GAMEACC iptables 规则双重判断

### LuCI 界面全中文化

移除所有 `translate()` 调用（无 .po 翻译文件导致英文原样输出），全部改为中文硬编码：

| 页面/标签 | 原英文 | 中文 |
|-----------|--------|------|
| 顶级菜单 | Leigod Acc | 雷神加速器 |
| 服务配置 | Leigod Service | 服务配置 |
| 设备管理 | Leigod Device | 设备管理 |
| APP下载 | Leigod App | APP下载 |
| 自动暂停 | Auto Pause | 自动暂停 |
| 使用须知 | Leigod Notice | 使用须知 |
| 诊断页面 | Diagnostics | 网络诊断 |
| 服务状态 | Acc Service Disabled/Enabled | 已停止/已启用 |
| 设备状态 | Acc Catalog Started/Stopped/Paused | 加速中/已停止/已暂停 |
| 状态空值 | None | 无 |

**修改文件**：`controller/acc.lua`、`model/cbi/leigod/service.lua`、`device.lua`、`notice.lua`、`autopause.lua`、`view/leigod/debug.htm`、`view/leigod/autopause.htm`、`.sh` 内联补丁同步。

---

## v2.3.1 (2026-05-30) — 诊断增强 + 自动暂停重构 + 二进制逆向分析

### 自动暂停：四层 Token 策略（解决 token 7 天过期）

**Token 来源优先级**（`auto-pause.sh` v2.4）：
```
P1: USERNAME+PASSWORD 自动登录 → 获取新 token
    ⚠ 登录接口 (/wap/login/bind/v1) 有 CloudWAF 保护, 家庭 IP 可能被拦(418)
       可通过 GitHub Actions (数据中心IP) 绕过:
       Fork https://github.com/luanche/leigod-auto-pause → 设置 Secrets
P2: ACCOUNT_TOKEN 手动配置 (浏览器 F12 → ~7天有效)
P3: daemon user.token 自动提取 (无效, 返回 400006, 已降至最低)
P4: 全部不可用 → 跳过并记录日志
```

**登录 API 逆向发现**（参考 `luanche/leigod-auto-pause`）：
- 登录端点：`POST /wap/login/bind/v1`（非 `/api/user/login`）
- 签名算法：`MD5(sorted_keys_query_string + &key=5C5A639C20665313622F51E93E3F2783)`
- 密码需 MD5 哈希后发送
- daemon 的 `user.token` 是**加速会话 token**，不适用于用户 pause API（返回 400006）

**新增函数**：
- `login_and_get_token()`：带签名认证的用户名密码登录
- `extract_daemon_token()`：python3 / grep+sed 双方法提取 daemon token
- `get_token()`：四层 fallback 统一入口
- `call_pause_api()`：接受 token 参数（不再硬编码全局 ACCOUNT_TOKEN）

**安装流程更新**：
- `auto_pause_install()`：新增用户名/密码输入（可选），token 输入改为可选
- 配置文件新增 `USERNAME`/`PASSWORD` 字段

### acc-gw 二进制行为完整分析 (v1.2.2.13 router.arm64)

**acc_mode 实测矩阵**：
| acc_mode 值 | 结果 | 说明 |
|-------------|------|------|
| 0 | exit 255 崩溃循环 | 二进制不识别此值 |
| 1 | exit 0 崩溃循环 | TUN 模式不被支持 |
| **2** | **稳定运行** ✅ | TPROXY，唯一工作值 |

**关键发现**：
- `"unknow acc mode:2"` 是**非致命冗余警告**，仅在规则清理时出现，不影响功能
- acc_mode 由 JSON 控制，命令行 `-m` 标志仅影响 daemon 启动，不决定子进程行为
- 二进制硬编码默认 `tproxy_ip: "10.20.30.40"`，每次 daemon 重启覆盖 JSON
- mode=2 + 正确 tproxy_ip → web 稳定 → 端口 5588 监听 → GAMEACC 动态注入可用

**修复后的稳定状态验证流程**：
1. 停止 daemon → kill 残留进程
2. 修复 `tproxy_ip` 为 LAN IP + `acc_mode` 为 2
3. 同步 init 脚本 `-m tproxy`
4. 启动 → 等 5 秒 → 验证端口 5588 监听

### 严重修复：三层 tproxy_ip/acc_mode 守护

1. `fix_acc_core_conf()` 重写：
   - tproxy_ip 修复后二次检测（daemon 可能覆盖）
   - **强制 acc_mode=2**（检测到非 2 值自动修正）
   - init 脚本同步 `-m tun` → `-m tproxy`
   - kill 残留进程确保干净状态

2. `install_tproxy_watcher()`：cron 每 2 分钟 `leigod-fw4.sh fix-tproxy`

3. CLI `fix-tproxy` 入口：静默修复，无交互

### 新增功能：诊断页面重写（LuCI 系统日志风格）

- **移除所有自定义 CSS**，完全依赖 Argon 主题
- **CBI 嵌入**：创建 `model/cbi/leigod/debug.lua`，路由 `template()` → `cbi()`
- **单一日志块**：`<pre>` 格式，8 项分类诊断（系统/进程/Init/CoreConfig/网络/GAMEACC/设备/自动暂停）
- **问题列表**：彩色背景条（红/黄/蓝），按严重程度排序
- **一键复制**：客户端 JS 生成纯文本报告，clipboard API + textarea fallback
- **自动刷新**：15 秒轮询，原生 XMLHttpRequest（不依赖 xhr.js）
- **新增字段**：LAN IP/掩码、PID、VSZ 内存、tproxy_ip 验证、acc_mode 验证、TURN 中继、API 端点、GAMEACC 链、daemon token 状态

### Bug 修复

| Bug | 根因 | 修复 |
|-----|------|------|
| debug.htm `XHR is not defined` | 独立模板页不含 LuCI xhr.js | 原生 `XMLHttpRequest` |
| `tonumber()` base out of range | Lua `%s` 不匹配 `\n` | `:match("%d+")` |
| 诊断页脱离 LuCI 白底 | `template()` 独立渲染 | `cbi()` + CBI Model |
| 模式显示 `tprox27236` | `ps` 多行拼接 | `:match("[^\n]+")` 取首行 |
| 模式显示 `tp` | BusyBox `ps` 截断 | `ps ww` 无限宽度 |
| 内存显示 `S KB` | BusyBox `ps` 无 RSS 列，$4=STAT | $3=VSZ 虚拟内存 |
| 端口永远显示 No | `ss` 不存在 | netstat fallback |

### 修改文件

| 文件 | 变更 |
|------|------|
| `auto-pause.sh` | v2.4：四层 token 策略；`login_and_get_token()` 签名登录；`extract_daemon_token()` python3/grep；400006 回退；USERNAME/PASSWORD 配置 |
| `leigod-fw4.sh` | `fix_acc_core_conf()` 重写 (强制 mode=2 + kill 残留 + init 同步 + 二次检测)；`install_tproxy_watcher()`；CLI `fix-tproxy`；auto-pause 安装流程更新；内联 LuCI 补丁同步 |
| `luci-fw4-patch/luasrc/controller/acc.lua` | `get_debug_status()` 8 项增强；`get_debug_report()` 文本报告；port netstat fallback；`ps ww`+VSZ；daemon_token_ok |
| `luci-fw4-patch/luasrc/view/leigod/debug.htm` | 完全重写：LuCI 日志风格 `<pre>`，CBI 嵌入，客户端报告生成+复制，原生 XHR |
| `luci-fw4-patch/luasrc/model/cbi/leigod/debug.lua` | **新文件**：CBI Model wrapper (SimpleSection + template) |
| `CHANGELOG.md` | v2.3.1 完整记录（二进制分析 + 登录API逆向 + 全部修复） |

---

## v2.3.0 (2026-05-27)

### 新增功能

- **`diagnose_latency()` 延迟波动诊断**
  5 步综合诊断：队列管理 (QoS) / GAMEACC 流量分析 / conntrack 压力 / DNS 中继 / TURN 中继稳定性。诊断完成后自动询问是否安装 SQM。

- **`install_sqm()` 一键 SQM QoS 安装**
  双路径：尝试 SQM 包 → 非 PPPoE 接口添加 fq_codel 回退。PPPoE 接口不再添加 qdisc（验证发现叠加 fq_codel 到 PPPoE 虚拟接口会加剧延迟）。

- **菜单选项 `L. 延迟波动诊断`**
  新增主菜单入口 + 帮助文本。

- **`check_service_status()` 设备检测增强**
  原有 UCI 检测改为三级 fallback：UCI state → 运行中 acc 子进程 → `acc_core_conf.json` acceleration 列表。解决 acc-gw 二进制不写 UCI state 导致诊断误报"无设备"的问题。

- **`fix_acc_core_conf()` 函数**
  自动检测并修复 `/tmp/acc/acc_core_conf.json` 中错误的 `tproxy_ip`（如伪造值 `10.20.30.40`）和 `acc_mode`。init 脚本 args 同步修复。在 `switch_mode()` 和安装后自动调用。

### 严重修复：第二轮全面审计 (2026-05-27)

以下问题由三轮并行审计（安装/卸载流程、LuCI/Lua 代码质量、auto-pause 系统）发现，全部已修复。

#### 安装流程

- **`exit 1` 在函数内导致整个管理器脚本终止** (2 处)
  `install_leigodacc()` 和 `install_lean_ipkg_version()` 中 UPnP 检查失败时使用 `exit 1`，会使主菜单循环退出。修复：改为 `return 1`。

- **ARM fallback 包下载错误架构的 IPK**
  `install_compatibility_dependencies()` 中 `arm_cortex-a7/a15/a17` 和 `arm_mpcore/xscale` (ARMv5) 全部下载 `arm_cortex-a9` (ARMv7) 的预编译包，二进制不兼容。修复：a7/a15/a17 改为仅 opkg 安装不手动下载；ARMv5 直接跳过不兼容的预编译包。

- **多行 arch 导致 case 匹配失败** (2 处)
  `opkg print-architecture | grep arch` 可能返回多行（多架构系统），`case "$arch"` 匹配不到任何模式落入 `*)` 不支持分支。修复：加 `| head -1`。

- **官方安装脚本 curl 无错误检查**
  `curl | sh` 管道模式下 curl 失败时 `sh -c ""` 返回成功，脚本继续执行后安装修复步骤（应中止）。修复：先下载到变量检查非空再 `| sh`，加 `--connect-timeout` 和 `--max-time`。

- **Lean IPK 安装：luci-app/luci-i18n 下载无错误处理**
  次要包的 `wget` 失败静默跳过，后续 `safe_opkg_install` 对 glob 可能匹配到空/残缺文件。修复：加 `|| echo "[WARN]"` 降级处理。

- **Lean IPK 安装：安装失败后继续执行 UPnP/fw4 配置**
  `[ ! -d /usr/sbin/leigod ]` 检测失败后缺少 `return`，继续执行后续无意义的配置步骤。修复：加 `return 1`。

- **GitHub API curl 缺少传输总超时**
  仅有 `--connect-timeout 5` 无 `--max-time`，响应缓慢时可能挂起数分钟。修复：加 `--max-time 30`。

- **`kmod-netem` 在内核内置时仍被标记为必需**
  `install_lean_ipkg_version()` 的 `required_packages` 始终包含 `kmod-netem`，kernel 6.x 上包不存在时产生虚假"缺失依赖"警告。修复：调用 `has_netem()` 判断。

#### 卸载流程

- **卸载不清理 auto-pause 文件**
  cron 条目、脚本、配置、状态、日志文件均残留，cron 持续运行引用已删除的二进制。修复：增加完整 auto-pause 清理。

- **卸载不清理 iptables GAMEACC 链**
  acc-gw 运行时注入的 mangle 表 GAMEACC 链残留，可能干扰后续网络规则。修复：增加 `iptables -F/-X GAMEACC` 及 PREROUTING jump 删除。

- **卸载不清理防火墙 UCI 规则 (TCP 5588)**
  `setup_fw4_integration()` 添加的 `LeigodAcc` 防火墙规则残留。修复：增加 UCI 规则查找删除。

- **卸载不清理 iptables-nft 符号链接**
  `setup_iptables_nft_compat()` 创建的 symlink 残留。修复：检测并删除。

- **`rm` 无 `-f` 导致文件不存在时报错** (非 opkg 路径)
  修复：全部改为 `rm -f`。

- **opkg 路径与非 opkg 路径清理不一致**
  opkg 路径不删除 `/etc/config/accelerator` 和 i18n 文件。修复：统一清理逻辑。

#### opkg 锁安全

- **opkg 锁等待 3 秒后无条件删除** (2 处)
  TOCTOU 竞态：检查 opkg 进程 → 等 3 秒 → 直接 `rm -f`，另一个 opkg 可能在这期间获取锁。修复：30 秒轮询等待 + 删除前二次确认无进程。`pgrep -f "opkg "` 改为 `pgrep -x "opkg"` 精确匹配。

#### Shell 安全

- **`auto-pause.sh` `read_state()` 源码级 RCE** (高)
  通过 `. "$STATE_FILE"` source 状态文件，`/tmp` 为 world-writable，任意进程可注入 shell 命令并 root 执行。修复：改为逐行 `read` 解析，只接受已知 key。

- **Lua `trigger_autopause()` token shell 单引号未转义** (高，standalone + inline)
  `gsub('"', '\\"')` 只处理 JSON 双引号，缺少 `gsub("'", "'\\''")` 导致 token 含单引号时可逃逸 shell 命令。修复：加 shell 单引号转义。

- **`auto-pause.sh` curl 缺少 `--max-time`**
  仅 `--connect-timeout`，服务端挂起时 cron 可能永久阻塞，与后续每 2 分钟的新 cron 实例重叠。修复：加 `--max-time`。

- **Config 文件 token 写入：单引号会破坏 shell source**
  `printf "ACCOUNT_TOKEN='%s'"` 若 token 含 `'` 会破坏配置语法。已记录为约束，当前 Leigod token 不含单引号。

- **Token 安装输入无空白字符过滤**
  `read -s token` 后直接写入配置，未去除首尾空白/换行。已记录，建议加 `tr -d '[:space:]'`。

#### LuCI/Lua

- **`autopause.lua` on_commit masked token 误检测** (高)
  掩码格式为 `前8字符+星号+后4字符`（不以 `*` 开头），但检测用 `not token_val:match("^%*")` 期望以 `*` 开头 → 掩码被当作真实 token 写入配置，导致 token 损坏。修复：改为检测 6+ 连续 `*`（`%*%*%*%*%*%*`）。

- **`schedule_pause()` nil 值注入 crontab**
  `pause_time:match("(%d+):(%d+)")` 失败时 `hour/minute` 为 nil → `string.format` 产生 `"nil nil * * *"` 污染 crontab。已记录需加强输入校验。

- **`get_debug_status()` 包检查：nil 被当作 pass**
  `resp.packages[key] ~= false` 在值为 nil 时也是 true，导致从未检查的包被标记为"已安装"。已记录。

- **`device.lua` DHCP 星号检查无效**
  `dhcp_map[key] ~= "*"` 比较 table 和 string 恒为 true，未知主机名仍被使用。已记录。

#### JavaScript/HTML

- **`autopause.htm` JSON.parse 无 try-catch** (standalone + inline)
  服务端返回非 JSON 时 `JSON.parse` 抛出异常，`ap_poll()` (setInterval) 崩溃后轮询停止。修复：加 try-catch。

- **`debug.htm` innerHTML XSS** (standalone + inline)
  ps cmdline 直接通过 `innerHTML` 渲染，含 `<` 等 HTML 字符时会注入。修复：`.replace(/</g, '&lt;')`。

#### 延迟诊断

- **`diagnose_latency()` PPPoE 错误建议**
  初始版本建议在 `pppoe-wan` 虚拟接口上加 `fq_codel`，实测验证会因 PPPoE 内核内部 TX 队列导致双重排队、加剧延迟。修复：PPPoE 接口不添加 qdisc，改为推荐 SQM。

- **TPROXY 流量统计 `iptables -L -n -v` 解析脆弱**
  不同 iptables 版本输出格式差异可能导致解析失败。修复：加 `-x` 精确计数 + `awk '{s+=$1} END {print s+0}'`。

- **`nslookup` BusyBox 不兼容**
  `-A1` 旗标和 `Name:/Address:` 匹配在 BusyBox nslookup 中格式不同。修复：改为直接 `ping` 域名让系统 DNS 解析。

- **`check_network()` 中国镜像站全球误报**
  仅 `mirrors.pku.edu.cn` 导致境外用户误报网络不可达。修复：优先 `httpbin.org`，备选 `mirrors.pku.edu.cn` + `cloudflare.com`。

#### 内联 LuCI 补丁 i18n 对齐

- **内联 autopause.htm/debug.htm/notice.lua 缺少 i18n 标签**
  内联版本使用硬编码英文 (如 "OK Installed")，独立文件使用 `<%:Key%>` i18n 标签。修复：内联版本全部对齐独立文件的 i18n 语法。

- **`acc_mode` 硬编码覆盖为 TPROXY**
  `fix_acc_core_conf()` 无条件将 `acc_mode:1` 改为 `acc_mode:2`，未来新二进制支持 TUN 时会误杀。修复：仅在 daemon 日志中检测到 `unknow acc mode:1` 时才覆盖。

---

## v2.2.1 (2026-05-21)

### 严重修复：fw4 防火墙误判 (ImmortalWrt 24.10)

- **`detect_firewall()` 仅检查 `/usr/sbin/fw4` 导致 nftables 系统误判为 fw3**  
  ImmortalWrt 24.10 等衍生固件底层使用 nftables 但未安装 `firewall4` 包，`[ -x /usr/sbin/fw4 ]` 检测失败后回退 fw3 路径，导致：安装错误的 iptables 包（而非 iptables-nft）、跳过 fw4 hotplug 集成、跳过 iptables-nft 兼容层配置、加速规则不被 nftables 处理。修复：增加 `[ -x /usr/sbin/nft ]` 作为备选检测条件。同步修复所有 LuCI 文件中的 `fs.access("/usr/sbin/fw4")` 检测（5 处：controller/acc.lua ×2、service.lua ×1、notice.lua ×1、内联 service.lua ×1）。

- **`kmod-netem` 在 kernel 6.x 上不存在导致安装报错**  
  较新内核（6.x）将 `CONFIG_NET_SCH_NETEM` 编译进内核而非作为独立模块，`kmod-netem` 包不存在。修复：新增 `has_netem()` 函数（检查 `lsmod sch_netem` 和 `/proc/config.gz`），仅在 netem 未内置时才将 kmod-netem 列入安装清单。

- **官方安装脚本清除 LuCI 文件后未恢复 fw4 补丁**  
  雷神官方 `plugin_install.sh` 的 `uninstall openwrt luasrc` 步骤会删除所有已安装的 LuCI 文件。修复：安装成功后重新调用 `apply_luci_fw4_patch()` 恢复 fw4 适配文件。

- **安装后 LuCI 可用性不明确**  
  选项 1（官方安装）不包含 LuCI 网页界面，用户安装后找不到 Web 管理页面。修复：安装完成后明确显示 LuCI 状态（已就绪 / 未安装），未安装时提示使用选项 8。

- **自动安装 `luci-compat`**  
  OpenWrt 24.10 的 LuCI Lua CBI 需要 `luci-compat` 包才能渲染页面。修复：检测到 LuCI 控制器目录存在时自动安装该包。

- **fw4 安装后主动推荐切换 TUN 模式**  
  此前仅显示静态提示，用户容易忽略。修复：安装后直接询问是否立即切换 TUN 模式，默认确认即执行。

- **`/etc/hotplug.d/firewall/` 目录不存在导致 hotplug 脚本创建失败**  
  ImmortalWrt 24.10 未预创建 `/etc/hotplug.d/firewall/` 目录，`cat >` 直接写入报 `nonexistent directory`。修复：写入前添加 `mkdir -p /etc/hotplug.d/firewall`。

- **`has_netem()` 仅检查内核，未检查包是否存在**  
  即使内核未内置 netem，`kmod-netem` 包也可能在软件源中不存在（kernel 6.x 某些构建），导致安装时仍报错。修复：增加 `opkg list kmod-netem` 检查，包不存在时直接跳过。

- **官方安装脚本删除 LuCI 文件后内联补丁未完整恢复**  
  雷神官方 `plugin_install.sh` 的 `uninstall openwrt luasrc` 会删除全部 10 个 LuCI 文件，但内联 `apply_luci_fw4_patch` 仅恢复 5 个 fw4 修改过的文件，导致 `device.lua`、`app.lua`、`notice.lua`、`app.htm`、`notice.htm` 缺失，LuCI 报 `Model 'leigod/device' not found!` 运行时错误。修复：内联补丁新增完整恢复全部 10 个文件。

- **`switch_mode()` 非 IPK 版切换 TPROXY→TUN 丢失所有启动参数**  
  原代码 `sed 's|${args}|--mode tun|'` 将 init 脚本中的 `${args}` 替换为仅 `--mode tun`，丢弃了 `-p 5588`（API 端口）和 `-l`（监听地址）等关键参数。导致 acc-gw 不在正确端口监听，手机 APP 点击加速无反应。修复：仅替换模式标志（`-m tproxy`↔`--mode tun`），保留其他参数；并增加自动恢复逻辑（检测到参数缺失时自动补全 `-p 5588`）。

- **`autopause.lua` 第 30 行 `existing_token:sub()` nil 错误**  
  `if existing_token ~= ""` 在 Lua 中 `nil ~= ""` 为 **true**，导致 token 未配置时仍进入分支对 nil 调用 `:sub()` 方法。修复：改为 `if existing_token and existing_token ~= ""`（内联+独立两处）。

- **`check_service_status()` 服务状态检测依赖不可靠的 init 脚本**  
  `/etc/init.d/acc running` 在部分系统无法正确检测 acc-gw 进程，服务状态显示"已停止"但进程实际运行中。修复：增加 `ps | grep "[a]cc-gw"` 作为备选检测，并在 hotplug 脚本中同步修复。

- **fw4 防火墙默认阻止手机 APP → acc-gw API 通信 (TCP 5588)**  
  手机能通过 UPnP 发现路由器，但点击加速后卡住无反应——因为 fw4 默认规则丢弃了 LAN 到非标准端口的入站流量。修复：`setup_fw4_integration()` 自动添加 UCI 防火墙规则开放 TCP 5588；`check_service_status()` 自动检测并补全缺失规则，同时新增端口监听状态检查（`ss -tlnp`）。

- **`--mode tun` (GNU 长格式) 被 acc-gw 二进制文件静默忽略，导致始终运行在 TPROXY 模式**  
  雷神官方安装脚本写入 `args="--mode tun ..."`，但 `acc-gw` 二进制仅识别短格式 `-m tun`/`-m tproxy`。`--mode tun` 被静默忽略后二进制退回默认 TPROXY 模式。在 fw4/nftables 下 TPROXY 规则无法被正确处理，导致加速完全无效——这是加速不生效的**根本原因**。修复：(1) 官方安装和 IPK 安装后自动将 `--mode tun`/`--mode tproxy` 标准化为 `-m tun`/`-m tproxy`；(2) `switch_mode()` 先标准化旧格式再检测切换，使用 `-m tun`/`-m tproxy` 短格式；(3) `check_service_status()` 主检测改用短格式，旧格式标注"(可能未生效)"警告；(4) 安装后 TUN 模式推荐提示改为检查当前模式，已为 TUN 则不再重复切换。

- **新增 LuCI 诊断调试页面 (Diagnostics)**  
  通过 Web 后台 → 服务 → Leigod Acc → Diagnostics 即可一键获取完整诊断报告。自动检测 15+ 项检查并标记 pass/fail/warning，覆盖：系统信息（固件/内核/防火墙）、进程状态（acc-gw 是否运行/实际模式/端口监听）、init 脚本模式标志格式分析（自动检测 `--mode tun` 长格式 bug）、网络（TUN 接口/防火墙规则/hotplug）、依赖包完整性、设备加速状态、自动暂停状态、最近日志。问题按严重程度（error/warning/info）排序，可直接用于代码审查和问题归因。实现：新增 `controller/acc.lua` 的 `get_debug_status()` Lua API + `view/leigod/debug.htm` JS 轮询模板。

### Bug 修复

- **内联 controller 缺失 auto-pause 路由 (`apply_luci_fw4_patch` 内联分支)**  
  内联 `controller/acc.lua` 缺少 `autopause`、`ap_status`、`ap_save`、`ap_trigger`、`ap_toggle` 路由及对应的 4 个 handler 函数。当 luci-fw4-patch 目录不可用、回退到内联代码时，LuCI 自动暂停页面 JS 轮询的 API 端点全部 404。现已补全与独立文件一致的完整路由和函数。

- **`autopause.htm` 独立文件 `ap_toggle_cron()` 逻辑错误**  
  `document.getElementById("ap_cron_enabled")` 元素不存在，条件恒为 falsy，导致 cron 只能启用无法禁用。改为通过按钮文字判断当前状态（与内联版本逻辑统一）。

- **命令注入：`schedule_pause()` username/password 未转义**  
  `controller/acc.lua`（内联和独立两处）中 username/password 来自 UCI，直接拼接到 `util.exec("echo '...' >> /etc/crontabs/root")` 内部。如果 UCI 值包含单引号可逃逸并执行任意命令。修复：拼接前对值做 `gsub("'", "'\\''")` 转义。

- **`notice.lua` 重复 SimpleSection**  
  fw4 检测分支内已设置 `m:section(SimpleSection)`，分支结束后又无条件创建了一份，导致 fw4 下 notice 模板渲染两次。修复：移除 if 块内的重复 section，仅保留 fw4 描述文本拼接。

- **Lean IPKG 安装后 LuCI 提示与实际情况不一致**  
  提示称"LuCI Web 界面为上游原始版本 (未做 fw4 适配)"，但 `apply_luci_fw4_patch` 已在 IPK 安装前调用。修复：IPK 安装后重新调用 `apply_luci_fw4_patch` 覆盖被 IPK 还原的文件，并更正提示文案。

- **`install_compatibility_dependencies` 未调用 TPROXY fallback 检查**  
  选项 6 安装兼容性依赖时缺少 `ensure_fw4_tproxy()`。如果用户通过选项 6 单独安装依赖，不会得到 TPROXY 可用性反馈。修复：在 fw4 依赖安装块末尾添加调用。

- **`switch_mode()` UCI 路径错误（IPKG 版）**  
  IPKG 版模式切换读取 `uci get accelerator.base.tun`，但 `tun` 选项位于匿名 system section 而非 named section `base`（`base` 存储的是 neigh 网卡接口）。导致永远切到 TUN 模式，TUN→TPROXY 切换无效。修复：改用 `accelerator.@system[-1].tun` 定位正确的 section。

- **命令注入：`trigger_autopause()` token 拼入 shell 命令**  
  `controller/acc.lua`（内联和独立两处）的 `trigger_autopause()` 将 account_token 直接拼入 `util.exec("curl ... -d '...'")` 内部，token 中的双引号可逃逸 JSON/Shell。修复：拼接前对 token 做 `gsub("\\", "\\\\"):gsub('"', '\\"')` 转义。

- **`install_leigodacc()` 忽略 `check_network()` 返回值**  
  网络预检失败后仍继续执行 `opkg update`，浪费时间并产生无意义错误。修复：检测失败时询问用户是否继续。

- **`install_lean_ipkg_version()` 忽略 `check_network()` 返回值**  
  与 `install_leigodacc()` 中的 Bug 9 模式一致：网络预检被调用但返回值未被检查，导致 `opkg update` 在网络不可达时仍然执行。修复：添加相同的 y/n 询问逻辑。

- **注释与代码不一致 (`install_compatibility_dependencies`)**  
  fw3 回退块的注释写为 "fw4 returns above"，但 fw4 并未真正 return，而是通过下方的 `if [ "$FW_TYPE" != "fw4" ]` 守卫跳过。修复：注释改为 "fw4 guarded below"。

- **`check_service_status()` 使用 `-x` 而非 `-d` 检查目录**  
  `if [ -x /usr/sbin/leigod ]` 测试目录的可搜索权限，语义上应为 `-d` 检查目录是否存在。虽然目录几乎总是 +x 无实际影响，但修正为正确语义的写法。

### 新增功能：服务状态查看 (诊断)

- **`check_service_status()` 函数** — 菜单新增 `S. 查看服务状态 (诊断)`，无需 LuCI 即可全面了解插件运行状态：
  - 安装状态（已安装/部分安装/未安装）
  - 服务运行状态 + 开机自启状态
  - 当前加速模式 (TUN/TPROXY)
  - acc-gw 进程 PID
  - 各设备类型加速状态 (从 UCI accelerator.*.state 读取)
  - 自动暂停配置状态（token、cron、空闲计数、上次暂停时间）
  - 最近日志错误摘要
  - fw4 hotplug 脚本状态

- **Lean IPKG 安装后 LuCI 提示** — 选项 8 安装完成后醒目提示：
  - LuCI Web 界面为上游原始版本（未做 fw4 适配）
  - 建议通过 SSH 菜单管理服务状态和自动暂停
  - 防火墙已自动配置 fw4 hotplug，无需额外操作

### LuCI fw4 适配补丁

- **`apply_luci_fw4_patch()` 函数** — 自动检测 fw4 环境并修补上游 LuCI 界面：
  - `controller/acc.lua` — `get_acc_status()` 增加防火墙类型 (fw3/fw4) 和 hotplug 状态检测；新增 4 个自动暂停 API 端点 (`ap_status`, `ap_save`, `ap_trigger`, `ap_toggle`)
  - `model/cbi/leigod/service.lua` — 服务配置页增加防火墙类型只读显示；fw4 下 TUN 模式标注"强烈推荐"
  - `model/cbi/leigod/autopause.lua` — **新建**自动暂停配置页：token 设置、空闲阈值、API 超时、通知开关、cron 启停按钮、手动暂停按钮
  - `view/leigod/service.htm` — 状态表格增加防火墙信息行
  - `view/leigod/autopause.htm` — **新建**自动暂停实时状态面板（10 秒轮询，显示脚本/token/cron/空闲计数/上次暂停/冷却状态）
  - 安装时自动触发（选项 1 和 选项 8）
  - 应用后自动清除 LuCI 缓存 (`rm -rf /tmp/luci-*`)

- **LuCI 自动暂停页面结构：**
  - 配置表单：account_token（密码字段）、空闲检测次数 (1-10)、API 超时 (5-30s)、通知开关
  - 按钮：启用/禁用 cron、立即暂停（测试）
  - 状态面板：JavaScript 轮询 `/admin/services/acc/ap_status`，实时刷新
  - API 端点：`ap_save`（保存配置）、`ap_trigger`（手动暂停）、`ap_toggle`（切换 cron）

- **luci-fw4-patch/ 目录** — 完整的 fw4 适配 Lua/HTML 文件（10 个文件）

- **菜单和帮助更新** — 新增 S 选项入口，帮助文档同步更新

### 新增函数

| 函数 | 用途 |
|------|------|
| `check_service_status()` | 综合诊断面板，汇总安装/服务/设备/日志/自动暂停状态 |
| `apply_luci_fw4_patch()` | 自动修补上游 LuCI 界面：防火墙显示 + 自动暂停页面 |

### LuCI2 (JavaScript) 迁移可行性评估

- **评估结论：暂不迁移。** 当前 LuCI1 Lua CBI + `luci-compat` 方案稳定可行，迁移投入产出比低。
- **当前技术栈**：LuCI1 Lua (`/usr/lib/lua/luci/`) + `luci-compat` + JavaScript XHR 轮询（自动暂停状态页）
- **目标技术栈**：Modern LuCI JS (`/www/luci-static/resources/view/`) + ucode RPC (`/usr/share/rpcd/ucode/`) + JSON ACL
- **迁移工作量**：10 个文件，~800 行代码，估计 3-5 天。controller/acc.lua（高难度）、autopause.lua（中）、其余（低）
- **暂缓理由**：
  1. `luci-compat` 在 OpenWrt 24.10 上稳定可用，无兼容性风险
  2. ucode 学习成本高，且上游雷神 LuCI 尚未迁移
  3. SSH 菜单是主管理方式，LuCI 为辅助可视化
  4. 迁移对终端用户体验改善有限
- **预 adaptation**：自动暂停页面已采用 JS 轮询（与 LuCI2 `XHR.poll()` 一致），届时仅需替换路径和包引用
- **建议迁移时机**：OpenWrt 移除 `luci-compat` / 上游发布 JS 版 / 需深度集成 LuCI2 生态时

## v2.1.1 (2026-05-20)

### 安全问题修复 (Security)

- **HTTP → HTTPS 优先下载** (`install_leigodacc`, 小米/华硕检测)  
  雷神官方安装脚本 URL 改为优先 HTTPS，失败时 fallback 到 HTTP。缓解 MITM 攻击风险。

- **account_token 回显屏蔽** (`auto_pause_install`)  
  `read token` 改为 `read -s token`，防止 token 明文显示在 SSH 终端。

- **account_token 配置文件防注入** (`auto_pause_install`)  
  token 改用单引号写入配置文件，防止 source 时的 shell 注入。同时修复 `auto_pause_status` 中的 token 读取 (`cut -d"'"`)。

- **opkg list-installed 子命令修正** (全局 10 处)  
  `opkg list_installed` (下划线，无效子命令) 全部改为 `opkg list-installed` (连字符)。修复后包检测不再静默失败。

### Bug 修复

- **`[[ ]]` bashism → POSIX `[ ]`** (小米路由器检测)  
  `#!/bin/sh` 脚本中使用 `[[ ]]` 改为 `[ ]`，避免严格 POSIX shell 上的语法错误。

- **`grep -v "all\|noarch"` → `grep -vE "all|noarch"`** (架构检测)  
  BusyBox grep 不支持 `\|` 基础正则模式，改为 `-E` 扩展模式。

- **OpenClash 检测逻辑反转** (`check_openclash_mode`)  
  `if ! pgrep` 修正为 `pgrep`，提示仅在 OpenClash 确实运行时显示。同时用 glob 循环替换 `ls` 解析。

- **部分安装检查 `&&` → `||`** (`auto_pause_install`)  
  允许任一组件缺失时都报错，而非要求两者都缺失。

- **卸载顺序修正** (非 opkg 卸载路径)  
  先 disable/stop 服务再删除 `/etc/config/accelerator`。

- **`${token: -4}` BusyBox 兼容** (`auto_pause_status`)  
  负偏移子串改为 `$((len - 4))` 正偏移，避免 BusyBox ash 解析为默认值语法导致完整 token 泄露。

### 防火墙集成改进

- **hotplug 脚本防抖** (`99-leigodacc-restart`)  
  30 秒内重复 fw4 reload 不再触发多次 restart。注释修正为描述实际行为。

- **iptables-nft 软链接验证** (`setup_iptables_nft_compat`)  
  创建链接前检查源文件存在，不存在时输出警告。

- **TPROXY fallback 返回值检查** (两处调用)  
  `ensure_fw4_tproxy` 返回值被检查，失败时追加提醒。

### 代码质量与健壮性

- **`opkg` 锁文件安全删除** (两处)  
  强制删除前检查是否有 opkg 进程运行，等待 3 秒。

- **网络连通性预检** (`check_network`)  
  新增 `check_network()` 函数，`opkg update` 前检测网络可达性。

- **架构检测统一** (`install_lean_ipkg_version`)  
  反引号 ` `` ` 改为 `$()`，架构过滤逻辑与 `install_compatibility_dependencies` 一致。

- **ARM mpcore/xscale 警告** (兼容性依赖安装)  
  为 ARMv5 架构添加包兼容性警告。

- **uci 配置读取错误抑制** (`disabled_ipv6`)  
  `uci get dhcp.lan.*` 添加 `2>/dev/null`。

- **sed -i 备份** (`switch_mode`)  
  修改 `/etc/init.d/acc` 前创建 `.bak` 备份。

- **GitHub API 错误消息细化** (Lean IPKG 版本查询)  
  明确提示可能为限流或网络不可达。

- **CatWrt 私有 IP 检查简化**  
  移除无实际作用的 IP 条件，直接检查软件源配置。

- **文件存在性检查** (诊断输出)  
  `customfeeds.conf` / `distfeeds.conf` 存在性检查后输出，避免无意义的 cat 错误。

### auto-pause.sh 修复

- **`ls` 解析替换** (`check_accgw_recent`)  
  用 glob 循环 + `[ "$f" -nt "$newest" ]` 替换 `ls -t | head -1`。
- **curl stderr 分离** (`call_pause_api`)  
  `2>&1` 改为 `2>/dev/null`，避免错误输出污染 API 响应解析。
- **空 api_code 处理** (`main`)  
  curl 失败导致空 code 时输出明确日志而非 "code="。

---

## v2.1.0 (2026-05-19)

### 新增功能：自动暂停时长计费

- **auto-pause.sh 独立脚本**  
  通过 cron 定时轮询 UCI 加速器状态，检测到所有设备停止加速后自动调用雷神 API 暂停时长计费。
  - 检测机制：UCI `accelerator.*.state`（Phone/PC/Game/Unknown）优先，fallback 到 acc-gw 日志文件 mtime 检测
  - 连续 3 次检测到空闲（约 6 分钟）后触发暂停
  - 状态持久化到 `/tmp/leigod-auto-pause.state`
  - 暂停后 10 分钟内不重复调用 API（雷神 API 防抖）
  - 所有操作通过 `logger -t leigod-auto-pause` 记录到系统日志

- **主菜单集成**  
  新增菜单选项 `9. 自动暂停时长 (省时长)`，原帮助移至 `H`。子菜单支持：
  - 安装/配置（自动部署脚本 + 配置 account_token + 添加 crontab）
  - 卸载（清理 cron、脚本、配置文件、状态文件）
  - 查看运行状态（token 脱敏、cron 状态、UCI 设备状态、最近日志）
  - 手动触发一次暂停（用于测试 API 连接）

- **account_token 获取指引**  
  安装时自动显示浏览器 F12 获取 token 的详细步骤。

### 新增文件

- `auto-pause.sh` — 自动暂停监控脚本（适合 cron 调用）
- 主脚本新增函数：`auto_pause_menu`、`auto_pause_install`、`auto_pause_uninstall`、`auto_pause_status`、`auto_pause_trigger`、`auto_pause_setup_cron`

## v2.0.0 (2026-05-18)

### 严重修复

- **防火墙集成改用 hotplug 脚本** (`setup_fw4_integration`)  
  移除空的 nftables include 文件（`chain-post` 目录缺失会导致写入失败），改为创建 `/etc/hotplug.d/firewall/99-leigodacc-restart`。fw4 重载防火墙时自动重启 LeigodAcc 服务，恢复被刷掉的动态 iptables-nft 规则。

- **TPROXY 内核模块 4 级 fallback 检测** (`ensure_fw4_tproxy`)  
  `kmod-nft-tproxy` 在某些 OpenWrt 24.10 构建中可能不存在（已编译进内核）。新增 4 级递进检测：lsmod → modprobe → opkg install → /proc/config.gz 编译进内核检查。全部失败时给出明确警告并推荐 TUN 模式。

### 高优先级修复

- **修复 `local` 在函数外使用** (POSIX sh 违规)  
  顶层代码中 `local name=$(uci get ...)` 在严格 POSIX shell 下会报错，改为普通变量赋值。

- **重写 `check_acceleration()` 函数**  
  修复两个 bug：glob 模式 (`/tmp/acc/acc-gw.log-*.log`) 传给 `[ -f ]` 在多个文件时行为异常；`date -d` (BusyBox 不支持) 改为 `date -r <file> +%s` 获取文件 mtime。

### 中优先级改进

- **新增磁盘空间预检查** (`check_disk_space`)  
  安装前检查 `/` 分区可用空间，< 10MB 时拒绝安装并提示清理。

- **新增 opkg 错误处理** (`safe_opkg_install`)  
  包装 `opkg install`，捕获每个包的安装返回值，失败包累积到 `$OPKG_FAILED`，调用方可据此决定是否中断。

- **新增 7 个 CPU 架构支持**  
  `aarch64_cortex-a72/a76/a55/a73`、`arm_cortex-a7/a9/a15/a17`、`arm_mpcore/xscale` 在兼容性依赖安装中不再报"不支持"。

- **fw4 跳过 immortalwrt 23.05.3 回退 URL**  
  fw4 用户仅通过官方源安装兼容依赖，避免旧版 libc ABI 的 .ipk 导致运行时崩溃。

- **Lean IPK 版本动态查询**  
  通过 GitHub API (`releases/latest`) 自动获取最新版本号，获取失败 fallback 到 `v1.3`。同时移除 `gh-proxy.com` 代理依赖，改用 GitHub 直链。

### 低优先级优化

- **提取 iptables symlink 重复代码** (`setup_iptables_nft_compat`)  
  消除 `install_leigodacc()` 和 `install_lean_ipkg_version()` 中两处完全相同的 9 行代码块。

- **fw4 安装后醒目 TUN 模式推荐**  
  安装完成时显示醒目的提示框，强烈建议 fw4 用户切换 TUN 模式。

- **菜单前暂停保留诊断信息**  
  检测到 fw4 或 OpenClash 时，启动诊断输出后暂停 2 秒再渲染菜单，避免重要警告被立即覆盖。

### 包依赖映射

| 功能 | fw3 (iptables) | fw4 (nftables) |
|------|---------------|----------------|
| iptables 命令 | `iptables` | `iptables-nft` |
| NAT 内核模块 | `kmod-ipt-nat` | `kmod-nft-nat` |
| TPROXY 内核模块 | `kmod-ipt-tproxy` | `kmod-nft-tproxy` (fallback 检测) |
| TPROXY 用户态 | `iptables-mod-tproxy` | nftables 内置 |
| IP 集合 | `kmod-ipt-ipset` + `ipset` | nftables 内置 |

### 新增函数一览

| 函数 | 用途 |
|------|------|
| `detect_firewall()` | 检测 fw3/fw4 |
| `set_fw_packages()` | 按防火墙类型设置包名变量 |
| `ensure_fw4_tproxy()` | fw4 TPROXY 4 级 fallback |
| `setup_fw4_integration()` | 安装 hotplug 脚本 |
| `setup_iptables_nft_compat()` | iptables→iptables-nft symlink |
| `check_disk_space()` | 安装前磁盘空间检查 |
| `safe_opkg_install()` | opkg 安装 + 错误捕获 |
| `get_essential_packages()` | 必备包列表(按防火墙) |
| `get_optional_packages()` | 增强包列表(按防火墙) |
| `get_check_packages()` | 安装后检查清单(按防火墙) |

## v3.2.1 (2026-11-06) — 禁用官方自动升级 + 隧道数据面定性

### 1. 菜单 U / CLI `disable-upgrade`

官方 1.2.2.78 只发布了 arm64 包（`acc_version.json` 里 `name=acc-gw.router.arm64`，
`md5_list` 只有 arm64）。amd64 上升级会：下载 3.2MB 包 → 解包 → exec `acc-setup.arm64` 失败，
但在此之前已经**杀掉 daemon**，导致加速每隔几分钟被中断。

本次实测：给 `nbox.nn.com` 钉 hosts **无效**（tarball 两分钟就回来，下载地址来自别处）。
有效做法是从 `/etc/init.d/acc` 移除 `acc_upgrade_monitor` 那个 procd 实例（备份
`/etc/init.d/acc.leigod_bak`，可一键还原）。

### 2. 隧道数据面定性（给官方的证据）

在 iptables 规则、策略路由、端口监听、隧道心跳全部正常的前提下：

```
22:53  隧道流 201 包 / 9849 字节
22:58  隧道流 244 包 / 11956 字节     ← 增量 = 5 分钟心跳量（60×35B）
```

同一时段 `GAMEACC` 的 TCP/UDP TPROXY 计数增长上千包——**引擎收下了流量，但没有送进隧道**。
`direct_Game` 始终为空（`cidrs_direct.txt` 的 9 条从未进集合），`S5 UDP` 计数为 0。

### 3. 其他

- 状态检查（S）自动重建缺失的 fw4 hotplug 守护脚本
- `validate-shell.py` 修正跨行单引号/`"'"`/`$()` 的误报；关键字平衡检查改为由 `bash -n` 负责
