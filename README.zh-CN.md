# dnswatchd

**简体中文** | [English](README.md)

一个探测 dnsmasq 上游、校验应答内容、失联即切换的守护进程。

![license](https://img.shields.io/badge/license-MIT-blue)

---

## 问题

典型组网：

```
客户端 → 主路由 dnsmasq → 旁路由（clash / fake-ip 透明代理）→ 上游 DNS
```

旁路由挂掉（VM 关机、clash 进程崩溃、PVE 重启）后，主路由 dnsmasq 仍然把查询发往那个地址，全家断网。

配两个上游看起来是解法，实际不行：

> dnsmasq 对多个上游**并发查询，采用最先返回的那个**。
>
> 代理型上游返回 `198.18.x.x`（fake-ip），直连型上游返回真实 IP。
> 谁快用谁 → 每次查询结果随机 → 代理时通时不通，而且极难排查。

---

## 做法

两个设计选择：

1. **探测时校验应答内容**，不只看有没有响应
2. **切换时只写一个 `server=` 行**，不并列

`--servers-file` 里永远只有一行。这是 dnsmasq 为动态上游提供的机制，配合 `SIGHUP` 平滑重载，不重启进程。

---

## 为什么必须校验内容

旁路由有两种故障，表现不一样：

| 故障 | dnsmasq 的视角 | 只判超时的看门狗 |
|---|---|---|
| VM 关机 / 网络断 | 查询超时 | 能发现 |
| **clash 进程崩溃，dnsmasq 还在** | **立即返回错误答案，不超时** | **发现不了** |

第二种故障端口还开着，`nslookup` 退出码是 0，返回的却是直连答案（真实 IP），代理静默失效。

`dnswatchd` 的判据：

```
代理型上游：探 www.google.com → 答案必须落在 198.18.0.0/16（fake-ip 段）
直连型上游：探 www.baidu.com  → 答案必须不在 198.18.0.0/16 内
```

答案不对即判为不健康，不论端口是否可达。

---

## 安装

### 从 feed 安装

```sh
wget -O /etc/opkg/dnswatchd.conf https://AIerlIz.github.io/dnswatchd/dnswatchd.conf
opkg update
opkg install dnswatchd
opkg install luci-app-dnswatchd   # 可选：Web 界面
```

### 从源码编译

```sh
# 在你的 OpenWrt SDK 里
echo "src-git dnswatchd https://github.com/AIerlIz/dnswatchd.git" >> feeds.conf.default
./scripts/feeds update dnswatchd
./scripts/feeds install -a -p dnswatchd
make package/dnswatchd/compile V=s
```

产物在 `bin/packages/<arch>/dnswatchd/`。`PKGARCH:=all`，任何架构通用。

---

## 前置检查

开始配置前确认这两项，否则切换不会生效或会与 UCI 打架：

```sh
# ① dnsmasq 必须启用 servers-file（安装脚本会设置，升级后复查一次）
uci get dhcp.@dnsmasq[0].serversfile
# 应输出 /tmp/dnsmasq.servers

# ② UCI 的 server 列表必须为空（否则与 servers-file 并发查询）
uci get dhcp.@dnsmasq[0].server
# 应报错或为空
```

---

## 快速开始

安装脚本（`/etc/uci-defaults/90-dnswatchd`）会做四件事：

1. 备份现有的 `dhcp.@dnsmasq[0].server` 到 `/etc/dnswatchd.servers.bak`
2. 用其中第一个地址初始化 `/tmp/dnsmasq.servers`
3. 清空 UCI 的 `server` 列表，改由 `--servers-file` 接管
4. 把第一个地址填进 `dnswatchd.primary.address`

**默认 `enabled '0'`，装完不生效。** 先用 dry-run 观察一天：

```sh
uci set dnswatchd.main.dry_run='1'
uci set dnswatchd.main.enabled='1'
uci set dnswatchd.main.interval='30'
uci commit dnswatchd
/etc/init.d/dnswatchd restart

# 观察日志，不实际切换
logread -f -e dnswatchd
```

判定正常后关闭 dry-run：

```sh
uci set dnswatchd.main.dry_run='0'
uci commit dnswatchd
/etc/init.d/dnswatchd restart
```

---

## 配置

`/etc/config/dnswatchd`：

```uci
config dnswatchd 'main'
	option enabled '1'                 # 总开关
	option interval '30'               # 探测间隔（秒，最小 5）
	option timeout '1'                 # 单次探测超时（秒）
	option fail_threshold '2'          # 连续失败几次判定 DOWN
	option recover_threshold '2'       # 连续成功几次判定 UP（回切）
	option servers_file '/tmp/dnsmasq.servers'
	option selection 'priority'        # priority | latency
	option latency_samples '3'         # 仅 latency：ping 采样次数
	option latency_margin '20'         # 仅 latency：新候选要快多少 % 才切
	option latency_switch_after '2'    # 仅 latency：连续赢几轮才切
	option dry_run '0'                 # 只记录不切换
	option syslog '1'
	option verbose '0'

config upstream 'primary'
	option enabled '1'
	option type 'proxy'                # proxy | direct（仅作标记）
	option address '192.168.10.2'
	option port '53'
	option probe_domain 'www.google.com'
	option expect_cidr '198.18.0.0/16'
	option expect_mode 'in'            # in | not-in
	option priority '10'               # 数字小的优先

config upstream 'fallback'
	option enabled '1'
	option type 'direct'
	option address '223.5.5.5'
	option port '53'
	option probe_domain 'www.baidu.com'
	option expect_cidr '198.18.0.0/16'
	option expect_mode 'not-in'
	option priority '20'
```

`upstream` 段可以加任意多个。

---

## 选择策略

### `priority`（默认）

按 `priority` 升序逐个探测，第一个健康的胜出：

```
proxy(10) 健康      → 用它
proxy(10) 挂了      → 试 aliyun(20) → 通就用
aliyun(20) 也挂了   → 试 tencent(30) → 通就用
全都不通            → servers-file 保持不动（不清空）
```

### `latency`

先探测所有 upstream，保留健康的，再对它们逐个测 ping RTT，选最快的：

```
healthy:  proxy(10) 49ms, aliyun(20) 28ms, tencent(30) 0.6ms
选中:     tencent（priority 最大，但 RTT 最快）
```

三条防抖规则，都在配置里可调：

| 参数 | 默认 | 作用 |
|---|---|---|
| `latency_margin` | 20 | 新候选要比当前快 20% 以上才考虑切换，防止 1ms 波动来回跳 |
| `latency_switch_after` | 2 | 新候选要连续赢 2 轮才真的切 |
| `latency_samples` | 3 | ping 采几次取 avg |

当前上游变得不健康时，前两条不生效，立即切换。

### `latency` 的两个前提

1. **上游必须响应 ICMP**。`1.1.1.1` / `223.5.5.5` / `119.29.29.29` 都响应；某些企业 DNS 或防火墙后不响应。不响应的上游不会被排除（它确实能解析 DNS），只是 RTT 记为 `99999` 排在最后。
2. **探测点必须能直达上游**。跑在劫持了所有 UDP/53 的透明代理环境里（比如旁路由自己），能不能解析的判定会失真，RTT 也是假的。

### 为什么用 ping 而不是直接测 DNS 响应时间

busybox 的 `date +%s%N` 只给秒（实测 `date +%s%N` → `1793954264`），shell 里拿不到亚秒精度，测不了几十毫秒级的 DNS 往返。

`ping` 的 RTT 是当前唯一可用的延迟指标，反映网络路径往返时间，与 DNS 响应时间高度相关（差异主要在服务端处理，通常几毫秒）。

### 场景选择

| 场景 | 建议 |
|---|---|
| 旁路由 + 一两个兜底 DNS | `priority`：旁路由优先，挂了才降级 |
| 多个公共 DNS 想用最快的 | `latency`：阿里/腾讯/CF 三选一自动挑 |
| 网络延迟不稳定、经常抖动 | `priority`：避免频繁切换 |

---

## 命令行

```sh
# 单次检查（调试）
/usr/sbin/dnswatchd once

# 当前状态
/usr/sbin/dnswatchd status
# active: primary
# servers-file: /tmp/dnsmasq.servers
#   # managed by dnswatchd - do not edit
#   server=192.168.10.2
# --- primary ---
#   fails=0
#   oks=7
#   status=up
# --- fallback ---
#   fails=6
#   oks=0
#   status=down

# 手工探测某个上游
/usr/sbin/dnswatchd probe 192.168.10.2 www.google.com 198.18.0.0/16 in
# OK
```

---

## 工作原理

```
每 interval 秒：

  按 priority 排序遍历 upstream

  probe(addr, domain, cidr, mode)
    nslookup -type=A -timeout=T -retry=1 <domain> <addr>
    取最后一个 Address 行 → 校验是否落在 cidr 内/外

  带滞回的状态机
    ok   → oks++,  fails=0；oks  ≥ recover_threshold → status=up
    fail → fails++, oks=0；fails ≥ fail_threshold   → status=down

  第一个 status=up 的 upstream 胜出

  与上次激活的不一致时：
    echo "server=<addr>" > /tmp/dnsmasq.servers
    kill -HUP $(pidof dnsmasq)
    echo "<section>" > /var/run/dnswatchd/active
```

**用 `--servers-file` 而不是改 UCI**：`uci set` + `reload` 会重启整个 dnsmasq，DNS 断 1–2 秒；`--servers-file` + `SIGHUP` 是 dnsmasq 为动态上游专门设计的机制，平滑重载，且不碰 `/etc/config/dhcp`。

**只写一个 server 行**：dnsmasq 会把 `--server` 和 `--servers-file` 里的条目合并查询。写两个就回到并发查询破坏 fake-ip 的老路上。

---

## 与其它方案的对比

| | dnswatchd | felipecrs/dns-watchdog | watchcat | dnsdist | smartdns |
|---|---|---|---|---|---|
| 校验应答内容 | 是 | 否，只判超时 | 否，只判 ICMP | 仅 `mustResolve` | 否 |
| 单点切换（不并列） | 是 | 是 | — | 是 | 否，并发查询 |
| 零中断切换 | 是，SIGHUP | 否，`service network reload` | — | 是 | 是 |
| LuCI 界面 | 是 | 否 | 是 | 否 | 是 |
| 是标准 opkg 包 | 是 | 否，安装脚本 | 是 | 是 | 是 |
| 体积 | ~20 KB | ~5 KB | ~30 KB | 2.4 MB | 4 MB |

---

## 排障

**日志一直是 `no healthy upstream`**

```sh
# 手工跑一次探测看输出
/usr/sbin/dnswatchd probe 192.168.10.2 www.google.com 198.18.0.0/16 in

# 看 dnsmasq 实际收到什么
nslookup www.google.com 192.168.10.2
```

如果手工 `nslookup` 返回真实 IP 而不是 `198.18.x.x`，说明 clash 的 fake-ip 没生效，或者规则把该域名走了 DIRECT。改 `probe_domain`。

**切换了但 DNS 还是不通**

```sh
# 确认 dnsmasq 真的用了 servers-file
ps w | grep [d]nsmasq
# 启动参数里应该有 --servers-file=/tmp/dnsmasq.servers

# 确认 UCI 的 server 列表是空的
uci show dhcp.@dnsmasq[0].server
```

**频繁抖动（来回切）**

调高 `fail_threshold` 和 `recover_threshold`，或者缩短 `interval` 让判定更平滑。

---

## 许可证

MIT
