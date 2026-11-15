# LeigodAcc Manager fw4 适配版 — 安装与使用指南

基于 [openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager) 修改，适配 iStoreOS 25.12（OpenWrt 25.12 / apk）+ fw4/nftables 防火墙。

**当前版本**: v3.0.0 (2026-11-05) — OpenWrt 25.12 / iStoreOS 25.12 (apk) 适配

## 前置条件

- OpenWrt / ImmortalWrt 路由器（fw3 或 fw4/nftables）
- **OpenWrt 25.12+ / iStoreOS 25.12+**：使用 apk 包管理器，需确认 `luci-compat` + `luci-lua-runtime` 已安装
- 已联网，能访问 `webapi.leigod.com`
- 雷神加速器账号

## OpenWrt 25.12 / iStoreOS 25.12 说明

| 项 | 25.12 现状 | 本脚本处理 |
|---|---|---|
| 包管理器 | apk-tools 3.x，**没有 opkg 命令** | 自动检测，全部改用 `apk add/del/info` |
| 软件源 | `/etc/apk/repositories.d/*.list` | 安装前打印 |
| LuCI 调度器 | ucode（`/usr/share/ucode/luci/`） | 依赖 `luci-compat` + `luci-lua-runtime` 桥接 Lua CBI |
| 包名 | `libpcap1`、`miniupnpd-nftables` | 自动映射 |
| `.ipk` 安装 | 不支持 | 菜单选项 8 直接提示"25.12 不支持" |
| 官方安装脚本 | 内部仍调用 `opkg` | 自动注入 `/tmp/leigod-pkgshim/opkg` 垫片 |
| 防火墙 | fw4/nftables + `iptables-nft` | 与其它 fw4 设备行为一致 |

> **LuCI 页面不出现 / 404 "No page is registered"**：说明 Lua 兼容层缺失。执行：
> ```bash
> apk add luci-compat luci-lua-runtime
> rm -f /tmp/luci-indexcache*
> /etc/init.d/rpcd restart && /etc/init.d/uhttpd restart
> ```

### 快速自检

```bash
/root/leigod-fw4.sh env      # 只读：打印固件/内核/架构/防火墙/包管理/LuCI 兼容层
/root/leigod-fw4.sh verify-luci
```

## 加速配置：新旧两种布局

官方引擎 v1.2.2.x 起把加速参数放进了 INI，管理器会自动识别并分别处理：

| 布局 | 判定 | 权威文件 | `tproxy_ip` 含义 |
|---|---|---|---|
| **new** | 存在 `/etc/config/acc_firewall.ini` | `[firewall] backend` / `mode` / `tproxy_ip` | 按后端固定的**哨兵值**：iptables→`10.20.30.40`，nftables→`0.0.0.0`（**不是** LAN IP） |
| legacy | 无 INI（v1.2.2.13 及更早） | `/tmp/acc/acc_core_conf.json` | **必须**是 LAN IP，`acc_mode` 必须为 2 |

> 不要手动把 `tproxy_ip` 改成 LAN IP：它是 TPROXY 的转发目标，官方设计就是这么写的。
> `fix-tproxy`（cron 每 5 分钟）只会补齐缺失字段、把非标准值校正回哨兵值，并把 JSON 对齐到 INI。

### 5588 端口未监听（手机 APP 连不上）

管理器安装完成后会自动等待并检查 5588；若失败会打印原因。手动排查：

```bash
ps ww | grep '[a]cc-gw'                       # daemon / web 子进程
awk '$4=="0A" && substr($2,length($2)-4)==":15D4"' /proc/net/tcp   # 5588 是否 LISTEN（十六进制）
tail -40 /tmp/acc/log/web_api.log             # web 子进程报错
tail -40 /tmp/acc/log/acc_daemon.log          # 是否反复 child process exit
```

常见原因：

1. **web 子进程反复退出（`child process exit, status:0`）+ `start global config manager failed`**
   → 插件拉取 `opapi.xxghh.biz` / `resources.leigodtech.com` 失败。双栈网络下 IPv6 不可达、
   而引擎的 HTTP 客户端不回落 IPv4 时会这样。先确认：
   ```bash
   curl -4 -m5 -o /dev/null -w 'v4=%{http_code}\n' https://opapi.xxghh.biz/common/comm/dict/getDictItems/LeigodBox_GlobalConfig/
   curl -6 -m5 -o /dev/null -w 'v6=%{http_code}\n' https://opapi.xxghh.biz/common/comm/dict/getDictItems/LeigodBox_GlobalConfig/
   ```
   v4 通、v6 不通 → 属于网络环境问题；可先 `/etc/init.d/acc restart` 重试，或按需处理 IPv6。
2. **`tproxy_ip` 被手动改成了 LAN IP** → 执行 `/root/leigod-fw4.sh fix-tproxy` 校正。
3. **INI 缺行**（升级/重装后）→ 同样执行 `fix-tproxy`，会按 backend 补齐。

## 加速不生效？先查 DNS（最常见原因）

引擎的路由数据全部来自 `dfs01.nn.com`：`mac.json`（设备类型）、`cidrs.txt`（该走隧道的
6624 个游戏网段）、`cidrs_direct.txt`（该直连的 9 个网段）。**只要路由器本机解析不到这个域名，
引擎就下载不到分流表，隧道会空转——APP 显示加速中、隧道心跳正常，但游戏完全没被代理。**

典型症状（iStoreOS + MosDNS/dnsmasq 组合）：

```bash
nslookup dfs01.nn.com                 # 只返回 CNAME，没有 A 记录
nslookup dfs01.nn.com 223.5.5.5       # A 记录齐全
grep 'Failed to download' /tmp/acc/log/web_api.log | tail -3   # HTTP Status: 0
ipset list direct_Game                # 空的
```

处理：管理器菜单 **D（DNS 兜底）** → 1 写入固定记录 → 重启服务。它会：

- 只固定「本机解析失败、公共 DNS 可解析」的域名，写入 `/etc/hosts` 的标记块内
- 安装 `dns-guard` cron（每 6 小时刷新，应对 CDN 换 IP）
- 也可以随时用菜单 D → 2 移除

命令行等价操作：

```bash
/root/leigod-fw4.sh dns-guard      # 立即刷新固定记录
/etc/init.d/acc restart            # 让引擎重新解析
ipset list direct_Game | head      # 应出现 0.0.0.0/8 10.0.0.0/8 ... 等 9 条
```

## 怎么判断“加速是否真的生效”

手机 APP 显示「加速中」并不等于流量真的被代理。在**加速中**的状态下按顺序核对：

| # | 命令 | 期望 |
|---|---|---|
| 1 | `ipset list target_Game` | 含正在加速的设备 IP |
| 2 | `ip rule show` | 有 `99: from all fwmark 0x99 lookup 99` |
| 3 | `ip route show table 99` | 有 `local default dev lo` |
| 4 | `iptables -t mangle -L GAMEACC -n -v` | 末尾三条 TPROXY 规则，**计数器在增长** |
| 5 | `netstat -tlnp \| grep 10.20.30.40` | 代理进程在 TPROXY 端口（如 47843）监听 |

四项中 1–4 都满足、但设备出口 IP 仍为本地时，重点排查两类原因：

1. **IPv6 绕过**：GAMEACC 是 IPv4 规则，设备若走 IPv6 则完全不进链。用 `https://ipinfo.io/json`
   看返回的 `ip` 是 v4 还是 v6；必要时关闭 LAN IPv6（菜单 7）。
2. **目标命中直连集合**：`direct_Game` 收录了国内/常用地址，访问国内查 IP 站点会走直连。
   用境外站点（`ipinfo.io` / `ifconfig.me`）复测，并可用 `ipset test direct_Game <IP>` 验证。

最可靠的判定法：先用 `iptables -v` 记一次计数，然后在设备上**只访问一次**境外站点，再看计数
哪一条在涨——涨在 TPROXY 说明被代理，涨在 `direct_` 说明直连，都不涨说明根本没进链。

## 卸载说明（菜单 2）

卸载会清理以下内容，并优先调用官方 `/usr/sbin/leigod/leigod_uninstall.sh`：

| 类别 | 清理项 |
|---|---|
| 服务 | 停止/禁用 `/etc/init.d/acc`，杀掉 `acc-gw`、`acc_upgrade_monitor`、`monitor.sh` |
| 引擎配置 | `/etc/config/accelerator`、`accelerator.ini`、`acc_firewall.ini`、`acc_version.ini`、`acc_core_conf.json`、`ipdatacloud_country.xdb`、`upgrade_data.json` |
| 运行时 | `/tmp/acc`（锁/日志/JSON/socket）、`/tmp/acc*` 下载与缓存、安装日志 |
| 自动暂停 | 脚本、`/etc/leigod-auto-pause.conf`、状态、日志、离家模式标记 |
| cron | `leigod-auto-pause`、`leigod-fw4.sh fix-tproxy` 等所有雷神相关行 |
| 防火墙 | `LeigodAcc` UCI 规则、hotplug 脚本、mangle/filter/nat 三表 `GAMEACC`、`ipset` 集合、`nft table inet tproxy_table` |
| LuCI | 12 个 Lua 文件、i18n lmo、indexcache |
| 其他 | opkg→apk 垫片、`iptables-nft` 符号链接 |

**会保留**（如需彻底清除请手动处理）：

- `/etc/config/upnpd` —— 安装时启用的 UPnP 设置（系统级服务，可能还有其他用途）
- `/etc/sysctl.d/99-leigod-latency.conf` —— 执行过「T. 内核网络调优」时写入的 BBR/fq_codel 参数

### 卸载后侧边栏仍有「雷神加速器」？

控制器文件已删除（路由返回 404），侧边栏残留是**浏览器/主题侧缓存**。管理器在卸载结束时会
清理 `/tmp/luci-indexcache*` 并重启 `rpcd`（所有 LuCI 会话失效）。请**重新登录**后台；
若仍显示，用 `Ctrl+Shift+R` 强制刷新或清除该站点数据。

## 快速安装（单文件）

### 1. 上传

```powershell
scp leigod-fw4.sh root@192.168.10.1:/root/
```

### 2. 安装

```bash
ssh root@192.168.10.1
chmod +x /root/leigod-fw4.sh
/root/leigod-fw4.sh
# 选 1 安装加速器
# 选 9→1 安装自动暂停（直接回车使用书签方案）
```

> **不再需要 `luci-fw4-patch/` 目录或 `auto-pause.sh`。** 全部内嵌在 `leigod-fw4.sh` 中。

### 3. 菜单操作流程

| 步骤 | 选项 | 说明 |
|------|------|------|
| 安装 | **1** | 自动安装雷神加速器（检测防火墙类型、安装依赖、部署服务） |
| 诊断 | **S** | 查看服务状态，确认所有检查通过 |
| LuCI | 浏览器 | `http://192.168.10.1/cgi-bin/luci/admin/services/acc/service` |

## 菜单说明

```
=============================
OpenWrt LeigodAcc Manager
防火墙: nftables (fw4)
包管理: apk (OpenWrt 25.12+)

1. 安装                    # 官方安装脚本
2. 卸载                    # 完整卸载（含 auto-pause）
3. 重装/更新               # 卸载 + 重装
4. 禁用/启用 雷神服务      # 开关服务（保留配置）
5. 切换运行模式             # TUN ↔ TPROXY
6. 安装兼容性依赖           # 从固件软件源补全依赖
7. 禁用/启用 IPv6           # 手机游戏优化
8. 安装 Lean IPKG 版        # 仅 opkg 可用，25.12 提示不支持
9. 自动暂停时长             # 空闲检测 + API 暂停
S. 查看服务状态             # 综合诊断
L. 延迟波动诊断             # Bufferbloat / QoS / PPPoE MSS / TURN 抖动
T. 内核网络调优             # fq_codel + BBR + conntrack 优化
H. 反馈/帮助
0. 退出
=============================
```

## 自动暂停（省时长）

### 安装

菜单选项 **9** → **1**（安装），直接回车跳过 token 配置。

### Token 获取

**方式一（推荐）— 书签一键获取**：

1. LuCI → 自动暂停页面 → 拖 `🔑 获取雷神Token` 按钮到浏览器书签栏
2. 打开 `https://www.leigod.com` → 登录
3. 点击书签 → 弹出 "Token 已保存到路由器!"
4. 每 7 天点击一次

**方式二（备选）— 浏览器 F12**：

1. 打开 `https://vip.leigod.com` → 登录
2. F12 → Console → `JSON.parse(localStorage.getItem('account_token')).account_token`
3. 复制 token → 粘贴到 LuCI 自动暂停页面的输入框 → 点"保存"

### 自定义空闲时间

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| 检测间隔 | 2 分钟 | cron 运行频率 |
| 空闲检测次数 | 3 次 | 连续空闲次数后触发 |
| **总空闲时间** | **6 分钟** | 间隔 × 次数 |

修改后保存，cron 自动更新。

### 离家模式（禁止自动暂停）

**用途：** 异地使用 PC 客户端加速时，防止路由器误判无设备而自动暂停时长计费。

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| MANUAL_DISABLE | 0 | `0`=正常自动暂停 / `1`=离家模式（禁止自动暂停） |

**操作方式：**
- **LuCI CBI 页面**：自动暂停配置页 → 勾选 "离家模式 (禁止自动暂停)" → 保存
- **手动编辑**：`echo "MANUAL_DISABLE=1" >> /etc/leigod-auto-pause.conf`
- **CLI 查看状态**：`/root/leigod-fw4.sh` → 选 `9` → 选 `3`（查看状态）→ 显示 `[模式] 离家模式` 或 `[模式] 自动模式`

**行为说明：**
- 离家模式下 cron 持续运行但不执行空闲检测，不调用暂停 API
- 首次进入离家模式写一条 syslog，后续静默（不重复刷日志）
- 空闲计数在进入离家模式时自动清零，退出后从零重新累计
- LuCI "立即暂停" 按钮在离家模式下被禁止，返回错误提示
- Debug 页面 / 自动暂停状态页面实时显示离家模式状态

**典型场景：**
1. 出门前开启离家模式 → PC 客户端异地加速不受影响
2. 回家后关闭离家模式 → 路由器恢复正常的空闲检测 + 自动暂停
3. 休假/长期外出期间开启离家模式 → 避免误暂停

### 技术说明

雷神登录 API 被 CloudWAF(418) 封锁，无法自动化登录。pause API 不受此限制，有有效 token 即可。书签方案是经过验证的物理最优方案。

### Token 策略 (v2.5)

```
单一来源: ACCOUNT_TOKEN (浏览器书签获取)
有效期 ~7 天, 过期后重新点击书签 (5秒)
配置 chmod 600, HTTPS 传输
```

## 诊断页面

浏览器访问：`http://192.168.10.1/cgi-bin/luci/admin/services/acc/debug`

**8 项分类诊断**：
- 系统信息（固件/内核/防火墙/LAN IP）
- 进程状态（PID/内存/模式/端口监听）
- Init 脚本（模式标志格式验证）
- 运行时配置（tproxy_ip + acc_mode 验证）
- 网络与防火墙（TUN/TURN/API/GAMEACC）
- 依赖包完整性
- 设备加速状态
- 自动暂停状态

**操作**：
- 点击"刷新"更新数据
- 点击"复制报告"获取纯文本诊断报告（可直接粘贴提交 bug 分析）

## 已知问题与解决方案

### 端口 5588 未监听 / web 进程崩溃

```
症状: 诊断页显示"端口 5588: No"，手机 APP 无法通信
根因: acc_core_conf.json 中 tproxy_ip 不正确 (可能为 10.20.30.40)
修复: /root/leigod-fw4.sh fix-tproxy
```

### GAMEACC 规则缺失

```
症状: 诊断页显示"GAMEACC 链: No"
说明: 正常现象。GAMEACC 规则由手机 APP 发起加速后动态注入
验证: 手机 APP 点击加速 → iptables -L GAMEACC -n
```

### acc_mode 报 "unknow acc mode:2"

```
症状: daemon 日志中出现 unknow acc mode:2
说明: 非致命冗余警告，仅在规则清理时打印，不影响加速功能
处理: 无需修复
```

### 自动暂停 token 过期

```
症状: 日志 "token 已过期 (code=400006)"
方案A: 浏览器 F12 获取新 token → 填入 LuCI
方案B: 使用 GitHub Actions (luanche/leigod-auto-pause)
```

## 内核网络调优（T 选项）

菜单选项 **T** 或 CLI `leigod-fw4.sh tune-network` 一键应用低延迟内核参数：

### 应用的参数

| 参数 | 值 | 作用 |
|------|-----|------|
| `default_qdisc` | `fq_codel` | 公平队列 + 主动队列管理，防止 WAN 口缓冲区膨胀 |
| `tcp_congestion_control` | `bbr` | Google BBR 拥塞控制，更适合有损/抖动链路 |
| `rmem_max / wmem_max` | 4MB | 防止突发流量丢包 |
| `tcp_fastopen` | 3 | 减少 TCP 连接建立 1 次往返 |
| `nf_conntrack_max` | 65536 | 扩大连接追踪表，防止"表满"丢连接 |
| `nf_conntrack_tcp_timeout_established` | 3600s | 更快释放空闲连接 |
| `tcp_keepalive_time` | 120s | 快速检测断连 |

### 持久化

配置写入 `/etc/sysctl.d/99-leigod-latency.conf`，路由器重启后自动加载，无需额外配置。

### BBR 检查

调优完成后自动验证 BBR 是否实际激活。如果内核未编译 `CONFIG_TCP_CONG_BBR=y`，会提示手动操作。

## 延迟诊断增强（L 选项 — v2.3.3 重写）

菜单选项 **L** 或打开"延迟波动诊断"，现已升级为 6 步完整诊断：

| 步骤 | 检查项 | 增强 (v2.3.3) |
|------|--------|---------------|
| 1/6 | QoS 队列管理 | 无变化 |
| 2/6 | GAMEACC 流量分析 | **iptables-nft/iptables 自动回退** |
| 3/6 | conntrack 压力 | **一键自动扩大**（使用率 > 80% 时询问） |
| 4/6 | DNS 中继延迟 | iptables 回退 |
| 5/6 | TURN 中继稳定性 | **抖动测量 (mdev)** — min/max/mdev，> 15ms 警告 |
| **6/6** | **PPPoE MTU/分片** | **全新** — TCP MSS clamping 检查 + MTU 合理性 + 一键修复 |

## 非交互式诊断（CLI）

```bash
/root/leigod-fw4.sh diagnose
```

输出纯文本报告（无 y/n 交互），适合：
- 定时 cron 监控：`0 * * * * /root/leigod-fw4.sh diagnose >> /tmp/leigod-diag.log`
- 远程排查：输出可直接粘贴提交 bug 分析

## 文件结构

```
leigod-fw4/                          (18 个文件)
├── leigod-fw4.sh                    # ★ 单文件部署 — 所有组件已内嵌
├── auto-pause.sh                    # 自动暂停脚本 v2.5 (源码参考)
├── CHANGELOG.md                     # 完整变更日志
├── UPDATE.md                        # 本文件 — 安装与使用指南
├── SESSION-LOG.md                   # 会话上下文 (新对话必读)
├── leigod-accelerator-tech-reference.md  # 技术参考
├── old/leigod-fw4-install-guide.md  # 旧安装指南 (已废弃)
└── luci-fw4-patch/                  # LuCI 源码 (参考, .sh 已内嵌)
    └── luasrc/
        ├── controller/acc.lua       (1213 行)
        ├── model/cbi/leigod/        (6 文件)
        │   ├── service.lua          — 服务配置
        │   ├── device.lua           — 设备管理
        │   ├── autopause.lua        — 自动暂停配置
        │   ├── notice.lua           — 使用须知
        │   ├── app.lua              — APP下载
        │   └── debug.lua            — 诊断页 CBI 包装器
        └── view/leigod/             (5 文件)
            ├── service.htm          — 加速状态
            ├── autopause.htm        — 自动暂停状态 + 书签UI
            ├── debug.htm            — 网络诊断报告
            ├── app.htm              — APP 信息
            └── notice.htm           — 公告内容
```

## CLI 命令

```bash
# 静默校正加速配置（INI/JSON 对齐，cron 每 5 分钟自动运行）
/root/leigod-fw4.sh fix-tproxy

# 只更新 LuCI 文件（升级管理器后不必重装插件）
/root/leigod-fw4.sh apply-luci

# 内核网络调优 — 应用 fq_codel/BBR/conntrack 等低延迟优化参数
/root/leigod-fw4.sh tune-network

# 非交互式诊断报告 — 6 段纯文本，适合 cron 作业或脚本化监控
/root/leigod-fw4.sh diagnose

# LuCI 完整性验证 — 检查 12 个文件 + luci-compat + UCI 配置，自动修复
/root/leigod-fw4.sh verify-luci

# 环境自检（只读）
/root/leigod-fw4.sh env

# 手动测试自动暂停（调试用）
/usr/sbin/leigod-auto-pause.sh 2>&1
```

## 版本

- **当前**: v2.4.1 (2026-06-10)
- **兼容**: OpenWrt 21.02+ / ImmortalWrt 23.05+ / fw3 (iptables) + fw4 (nftables)
- **acc-gw**: v1.2.2.13 (router.arm64) — 仅支持 TPROXY (acc_mode=2)
- **LuCI**: 全中文界面（7 个标签页均已翻译）+ 离家模式开关
- **安全**: Token 仅存储在路由器 (chmod 600), API 全程 HTTPS
- **新增**: 离家模式 — 异地加速时禁止自动暂停，防止误判
