# Session Log — LeigodAcc Manager fw4 适配版

> **原始仓库**: [miaoermua/openwrt-leigodacc-manager](https://github.com/miaoermua/openwrt-leigodacc-manager)
> **目标**: 将雷神加速器插件适配到 iStoreOS 25.12（OpenWrt 25.12 / apk）fw4/nftables 防火墙
> **产出目录**: `C:\Users\Administrator\leigod-fw4\`

## 版本时间线

| 版本 | 日期 | 关键变更 |
|------|------|----------|
| v2.0.0 | 05-18 | fw4 适配基础 |
| v2.1.0 | 05-19 | 自动暂停功能 |
| v2.1.1 | 05-20 | 29 项代码审计修复 |
| v2.2.0 | 05-20 | LuCI 补丁 + 诊断页 |
| v2.2.1 | 05-21 | fw4 防火墙误判修复 |
| v2.3.0 | 05-27 | fix_acc_core_conf + 延迟诊断 |
| v2.3.2 | 05-30 | 诊断增强 + 自动暂停重构 + LuCI 全中文化 |
| **v2.4.0** | **05-31** | **单文件部署 + 全部内嵌 + 最终方案** |
| v2.5.2 | 08-15 | device.lua Lua5.1 兼容 + CRLF 修复 |
| **v3.0.0** | **11-05** | **OpenWrt 25.12 / iStoreOS 25.12 适配：apk 双栈 + opkg 垫片 + LuCI Lua 兼容层** |
| **v3.1.0** | **11-05** | **对齐官方 v1.2.2.x 引擎：INI 为准、tproxy_ip 哨兵值、/proc 端口检测、崩溃循环诊断** |

---

## v3.1.0 — 真机调试记录（iStoreOS 25.12.5 / 引擎 1.2.2.71）

### 关键事实（由官方 acc-lib/lib/setup.sh 证实）

- `get_tproxy_ip_by_backend()`：iptables → **`10.20.30.40`**，nftables → **`0.0.0.0`**。
  这是设计值（TPROXY 转发目标 / IP_TRANSPARENT 绑定），**不是** LAN IP。
  旧仓库「强制改成 LAN IP」只适用于 v1.2.2.13。
- 新引擎的权威配置是 `/etc/config/acc_firewall.ini`；init 与 monitor 只读不写。
- `acc_version.ini` 在安装阶段被写入常量 `1.2.1.40`（setup.sh 里的默认值），
  进程启动后才覆盖成真实版本（`1.2.2.71`）。**安装日志里的版本号不可信**。

### 故障与定位过程

| 现象 | 排查 | 结论 |
|---|---|---|
| 5588 不监听，daemon 每 5s fork 一次 web 子进程 | `acc_daemon.log` 反复 `child process exit, status:0`；`web_api.log` 最后一行 `start_web:149 start global config manager failed` | web 子进程因**拉取全局配置失败**主动退出，bind 之前就死 |
| 两个 CDN 域名 2ms 失败，`error=2` | `curl -4` 均 200，`curl -6` 3ms 报错；`nbox.nn.com`（纯 A）正常 | 极可能是双栈下优先 AAAA 且无回落；属环境问题，非管理器所致 |
| 把 INI 的 tproxy_ip 改成 LAN IP 后仍失败，改回 10.20.30.40 后能跑 | 两次实验对照 | **tproxy_ip 与故障无关**，且改 LAN IP 是错的 |
| IP 改回 + 重启后 5588 起来了 | 设备发现日志正常输出 | 故障窗口已过，非确定性；需健康检查 + 明确报错 |

### 本轮改动

双布局识别（`acc_layout()`）、`fix_acc_new_layout()`/`fix_acc_legacy_layout()`、
`port_listening()`（/proc/net/tcp）、`acc_health_check()`、`acc_web_crash_loop()`、
`switch_mode()` 改读写 INI、`ensure_uci_config()` 先建文件、诊断页 6 项增强。

---

## v3.0.0 — OpenWrt 25.12 / iStoreOS 25.12 (apk) 适配要点

### 目标环境实测（iStoreOS 25.12.5）

| 项 | 值 |
|---|---|
| 基线 | OpenWrt 25.12.5，kernel 6.12.94，x86_64 |
| 包管理 | apk-tools 3.0.5，**无 opkg 二进制**；源在 `/etc/apk/repositories.d/*.list` |
| LuCI | 服务端 ucode（`/usr/share/ucode/luci/`），`/usr/lib/lua/luci/` 仍存在 |
| 兼容层 | `lua` / `luci-compat` / `luci-lua-runtime` / `ucode-mod-lua` **已预装**（iStore 依赖） |
| 依赖 | `iptables-nft`、`kmod-nft-{nat,tproxy}`、`kmod-tun`、`libpcap1`、`tc-full`、`conntrack`、`miniupnpd-nftables`、`ipset` 全部已装 |
| TPROXY | `nft_tproxy`、`xt_TPROXY`、`xt_set`、`nft_compat` 均已加载 |

### 关键结论：25.12 仍保留 Lua 兼容通道

`dispatcher.uc` 依旧 glob `/usr/lib/lua/luci/controller/*.lua`：

```
else if (load_luabridge(true))
    data = runtime.call('luci.dispatcher', 'process_lua_controller', file);
else warn(`Lua controller ${file} present but no Lua runtime installed.`)
```

`cbi` / `form` / `template` 三种 action 均桥接到 Lua（`invoke_cbi_action` / `invoke_form_action` / `render_lua_template`），
且 Lua 模板里的 `<%+header%>` 会落到 ucode 的 `header.ut`（`runtime.render_any()` 先找 `.ut` 再回落 Lua）。
**因此 12 个 Lua CBI 文件在 25.12 上无需重写**，前提是 `luci-compat` + `luci-lua-runtime` 在位；缺失时表现为菜单消失 + 404 `No page is registered`。

### 改动范围

1. `pkg_*` 抽象层替换全部 50+ 处 `opkg` 调用（`apk info -e` / `apk search -x` / `apk --print-arch`）
2. `install_opkg_shim()`：官方 `plugin_install.sh` 的 opkg 调用转 apk，PATH 注入，不落盘
3. 包名映射：`libpcap`→`libpcap1`，`miniupnpd`→`miniupnpd-nftables`
4. `verify_luci()` 5 段校验（含 `lua -e require("luci.dispatcher")` 桥接自检）
5. 菜单选项 8（Lean IPK）在 apk 上直接返回"不支持 .ipk"
6. 新增 `leigod-fw4.sh env` 只读自检
7. 新增 `scripts/validate-shell.py` + `scripts/test-pkg-layer.sh`（无路由器环境下的结构与逻辑校验）

---

## v2.3.0-v2.4.0 核心发现

### 1. acc-gw 二进制行为完整分析 (v1.2.2.13 router.arm64)

**acc_mode 实测矩阵**：
| acc_mode | 结果 | 说明 |
|----------|------|------|
| 0 | exit 255 崩溃 | 二进制不识别 |
| 1 | exit 0 崩溃 | TUN 不支持 |
| **2** | **稳定** ✅ | TPROXY，唯一值 |

**关键发现**：
- 二进制硬编码默认 `tproxy_ip: "10.20.30.40"`，每次 daemon 启动重新生成 JSON 覆盖手动修复
- `"unknow acc mode:2"` 是**非致命警告**，仅在规则清理时打印，不影响功能
- 此二进制**仅支持 TPROXY**，不支持 TUN 模式
- GAMEACC 规则由手机 APP 发起加速后**动态注入**（不是预创建的）
- daemon 不写 UCI state，设备加速状态在 `acc_core_conf.json` 中
- `user.token` 是加速会话 token，**不适用于 pause API**（返回 400006）

### 2. CloudWAF 登录封锁（不可逾越）

雷神登录 API `/wap/login/bind/v1` 从**所有网络来源**返回 418：
- ❌ 家庭宽带
- ❌ Cloudflare Worker 边缘节点
- ❌ GitHub Actions 数据中心 IP
- ❌ 本地开发机

Pause API `/api/user/pause` **无此限制**，有有效 token 即可。

**尝试过的自动化方案**（全部失败）：
| 方案 | 失败原因 |
|------|----------|
| curl 直接调用 | 418 CloudWAF |
| Cloudflare Worker 代理 | 418（即使是 CF 边缘 IP） |
| GitHub Actions | 418（即使是数据中心 IP） |
| Playwright + Edge | 极验验证码 + 浏览器自动化检测 |
| daemon token 复用 | 返回 400006（会话 token vs 账号 token） |
| 用户名密码自动登录 | 登录 API 被封锁 |

### 3. BusyBox 兼容性陷阱

| 问题 | 表现 | 修复 |
|------|------|------|
| `ps` 截断命令行 | mode 显示 `tp` 而非 `tproxy` | `ps ww` |
| `ps` 无 RSS 列 | 内存显示 `S KB` (STAT 列) | 用 VSZ ($3) |
| `ss` 不存在 | 端口检测永远 No | netstat fallback |
| `grep -oP` 不支持 | Perl regex 报错 | 基础 grep |
| 中文 `.-` 正则 | 跨嵌套 JSON 不匹配 | `find() + sub()` |

### 4. Lua 注入检测模式失败根因

设备状态从 JSON 读取时，初始正则 `"(Phone|PC)":[^{]-"state":(%d+)` 中的 `[^{]` 被嵌套 JSON 内部的 `{` 截断。改用两段式：
```lua
local pos = raw:find('"PC":')
local st = raw:sub(pos):match('"state":(%d+)')
```

---

## v2.4.0 最终架构

### 文件自包含（单文件部署）

`leigod-fw4.sh` 内嵌了所有组件：

| 内嵌组件 | 数量 | 部署方式 |
|----------|------|----------|
| LuCI 文件 | 12 个 | `apply_luci_fw4_patch()` 内联 heredoc |
| auto-pause.sh v2.5 | 1 个 | `auto_pause_install()` 内联 heredoc |
| hotplug 脚本 | 1 个 | 内联 |

**不再需要 `luci-fw4-patch/` 目录或 `auto-pause.sh` 独立文件。**

### Token 最终方案：浏览器书签

| 环节 | 方式 | 频率 |
|------|------|------|
| 获取 token | 书签一键推送 (bookmarklet) | 每 7 天 5 秒 |
| 空闲检测 | cron + GAMEACC + UCI | 全自动 |
| 暂停 API | curl POST | 全自动 |

**架构**：用户登录 leigod.com → 点书签 → token 自动 POST 到路由器 `save_token` 端点 → 写入配置文件 → cron 自动使用。

### LuCI 页面清单

| 页面 | 中文标签 | 类型 |
|------|----------|------|
| 服务配置 | 服务配置 | CBI Form |
| 设备管理 | 设备管理 | CBI + DHCP/ARP |
| APP下载 | APP下载 | 静态页 |
| 使用须知 | 使用须知 | 静态页 |
| 自动暂停 | 自动暂停 | CBI + JS 轮询 |
| 网络诊断 | 网络诊断 | JS 轮询 |

### 诊断页功能

- 系统/进程/Init/配置/网络/GAMEACC/依赖包/设备/自动暂停 — 12 项
- 延迟诊断：网关/DNS/TURN 三项 ping 对齐表
- 加速节点列表（从 acc_core_conf.json 提取）
- 自动分析（网关 >10ms → 本地；TURN-网关 >50ms → 服务器端）
- 书签一键获取 Token
- 自定义空闲检测间隔（1-30 分钟）

---

## 关键文件索引

| 文件 | 用途 | 行数 |
|------|------|------|
| `leigod-fw4.sh` | **单文件部署** (全部内嵌) | ~5030 |
| `auto-pause.sh` | 自动暂停独立脚本 (cron) | 176 |
| `CHANGELOG.md` | 完整变更日志 | ~690 |
| `UPDATE.md` | 安装与使用指南 | ~220 |
| `SESSION-LOG.md` | 本文件 | — |
| `luci-fw4-patch/luasrc/controller/acc.lua` | LuCI 控制器 | 1213 |
| `luci-fw4-patch/luasrc/view/leigod/debug.htm` | 诊断页模板 | 184 |
| `luci-fw4-patch/luasrc/view/leigod/autopause.htm` | 自动暂停模板 (书签UI) | 151 |
| `luci-fw4-patch/luasrc/model/cbi/leigod/autopause.lua` | 自动暂停配置 | 155 |
| `luci-fw4-patch/luasrc/model/cbi/leigod/debug.lua` | 诊断页 CBI wrapper | 7 |

## 已知限制与风险

| 限制 | 影响 | 缓解 |
|------|------|------|
| token 有效期 ~7 天 | 自动暂停到期失效 | 书签 5 秒手动刷新 |
| 此 acc-gw 仅支持 TPROXY | 不能切 TUN | fix_acc_core_conf 强制 mode=2 |
| daemon 不写 UCI state | 设备状态需从 JSON 读 | 已实现 JSON 解析 |
| 登录 API 完全封锁 | 无法自动化 token 刷新 | 浏览器书签 |
| `fix_acc_core_conf` 强制 mode=2 | 未来二进制支持 TUN 会误杀 | 需更新逻辑 |

## 部署速查

```powershell
scp C:\Users\Administrator\leigod-fw4\leigod-fw4.sh root@192.168.10.1:/root/
```

```bash
chmod +x /root/leigod-fw4.sh
echo "3" | /root/leigod-fw4.sh    # 重装（自动部署全部 LuCI）
# 菜单 9 → 1 → 回车 → 回车（自动部署自动暂停）
/etc/init.d/acc enable
rm -rf /tmp/luci-*
```

## v3.1.3 — 卸载彻底化（真机反馈）

卸载后残留：引擎 INI（accelerator.ini / acc_firewall.ini / acc_version.ini）、xdb、
`/tmp/acc`、crontab 里的 fix-tproxy、自动暂停文件；LuCI 侧边栏仍显示「雷神加速器」但点开 404。

根因：
1. 旧卸载函数写于 v1.x 时代，只认 `/usr/sbin/leigod` + UCI 配置 + 12 个 Lua 文件；
2. v1.2.2.x 引擎的产物（INI/xdb/JSON/日志/锁）完全没覆盖；
3. cron 与自动暂停只在「自动暂停脚本存在」时才清；
4. 菜单 404 = 控制器已删（路由不存在），侧边栏残留是浏览器/主题缓存。

处理：重写 uninstall（14 步），优先调用官方 `leigod_uninstall.sh`，覆盖 INI/JSON/xdb/tmp/
cron/自动暂停/LuCI（含 menu.d、acl.d、JS view 残留）/三表 GAMEACC/ipset/nft 表，
结束时清 indexcache+modulecache 并重启 rpcd/uhttpd（强制重新登录，菜单缓存失效），
最后做残留自检并列出「有意保留」项（upnpd、sysctl 调优）。
另新增 `scripts/test-uninstall-coverage.sh` 静态校验 28 个产物路径不再漏项。
