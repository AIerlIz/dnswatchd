# dnswatchd

> 一个会**检查答案对不对**的 DNS 上游看门狗。

![license](https://img.shields.io/badge/license-MIT-blue)

---

## 它解决什么问题

很多人的网络是这样搭的：

```
客户端 → 主路由 dnsmasq → 旁路由（clash / fake-ip 透明代理）→ 上游 DNS
```

旁路由一旦挂掉（VM 关机、clash 进程崩溃、PVE 重启），主路由 dnsmasq 就把上游发到一个死地址，**全家断网**。

直觉的修法是"配两个上游"。**但这条路是坏的**：

> dnsmasq 默认对多个上游**并发查询，用最先返回的那个**。
>
> 代理型上游返回 `198.18.x.x`（fake-ip），直连型上游返回真实 IP。
> 谁快用谁 → 每次查询结果随机 → 代理时通时不通，而且极难排查。

`dnswatchd` 的做法不同：

1. **探测时校验答案内容**，不只看"有没有响应"
2. **切换时只写一个 server 行**，绝不并列

---

## 为什么需要"校验内容"

旁路由有两种故障，症状完全不同：

| 故障 | dnsmasq 的视角 | 只判超时的看门狗 |
|---|---|---|
| VM 关机 / 网络断 | 查询超时 | ✅ 能发现 |
| **clash 进程崩了，但 dnsmasq 还在** | **立即返回错误答案，不超时** | ❌ **完全发现不了** |

第二种才是真正的陷阱：端口还开着，`nslookup` 退出码是 0，但它给的是**直连答案**（真实 IP），代理静默失效。

`dnswatchd` 的判据是：

```
代理型上游：探 www.google.com → 答案必须落在 198.18.0.0/16（fake-ip 段）
直连型上游：探 www.baidu.com  → 答案必须不在 198.18.0.0/16 内
```

答案不对 = 上游不健康，即使它"还活着"。

---

## 安装

### 从 feed 安装（推荐）

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

产物在 `bin/packages/<arch>/dnswatchd/` 下。因为 `PKGARCH:=all`，任何架构通用。

---

## 首次配置

安装脚本会自动做这几件事（`/etc/uci-defaults/90-dnswatchd`）：

1. 备份你现有的 `dhcp.@dnsmasq[0].server` 到 `/etc/dnswatchd.servers.bak`
2. 用其中第一个地址初始化 `/tmp/dnsmasq.servers`
3. 清空 UCI 的 `server` 列表，改由 `--servers-file` 接管
4. 把第一个地址填进 `dnswatchd.primary.address`

**注意：默认 `enabled '0'`，装完不会立即生效。** 先跑 dry-run 看一天：

```sh
uci set dnswatchd.main.dry_run='1'
uci set dnswatchd.main.enabled='1'
uci set dnswatchd.main.interval='30'
uci commit dnswatchd
/etc/init.d/dnswatchd restart

# 观察日志，不实际切换
logread -f -e dnswatchd
```

确认探测判定正常后，关掉 dry-run：

```sh
uci set dnswatchd.main.dry_run='0'
uci commit dnswatchd
/etc/init.d/dnswatchd restart
```

---

## 配置项

### `/etc/config/dnswatchd`

```uci
config dnswatchd 'main'
	option enabled '1'                 # 总开关
	option interval '30'               # 探测间隔（秒，最小 5）
	option timeout '1'                 # 单次探测超时（秒）
	option fail_threshold '2'          # 连续失败几次判定 DOWN
	option recover_threshold '2'       # 连续成功几次判定 UP（回切）
	option servers_file '/tmp/dnsmasq.servers'
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

`upstream` 段可以加任意多个，按 `priority` 升序尝试，第一个健康的会被写入 servers-file。

### 必须先满足的两件事

```sh
# ① dnsmasq 必须启用 servers-file（安装脚本会做，升级后检查一次）
uci get dhcp.@dnsmasq[0].serversfile
# 应输出 /tmp/dnsmasq.servers

# ② UCI 的 server 列表必须为空（否则会和 servers-file 并发）
uci get dhcp.@dnsmasq[0].server
# 应报错或为空
```

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

  ┌─ 按 priority 排序遍历 upstream
  │
  ├─ probe(addr, domain, cidr, mode)
  │    nslookup -timeout=T -retry=1 <domain> <addr>
  │    取最后一个 Address 行 → 校验是否落在 cidr 内/外
  │
  ├─ 带滞回的状态机
  │    ok   → oks++,  fails=0；oks  ≥ recover_threshold → status=up
  │    fail → fails++, oks=0；fails ≥ fail_threshold   → status=down
  │
  ├─ 第一个 status=up 的 upstream 胜出
  │
  └─ 与上次激活的不一致时：
       echo "server=<addr>" > /tmp/dnsmasq.servers
       kill -HUP $(pidof dnsmasq)
       echo "<section>" > /var/run/dnswatchd/active
```

**为什么用 `--servers-file` 而不是改 UCI**：

- `uci set` + `reload` 会重启整个 dnsmasq，DNS 断 1–2 秒
- `--servers-file` + `SIGHUP` 是 dnsmasq 为动态上游专门设计的机制，**平滑重载**
- 而且不碰 `/etc/config/dhcp`，不会和用户手动改的配置打架

**为什么只写一个 server 行**：

因为 dnsmasq 会把 `--server` 和 `--servers-file` 里的条目合并查。写两个就等于回到"并发查询破坏 fake-ip"的老路上。

---

## 与其它方案的对比

| | dnswatchd | felipecrs/dns-watchdog | watchcat | dnsdist | smartdns |
|---|---|---|---|---|---|
| 校验应答内容 | ✅ | ❌ 只判超时 | ❌ 只判 ICMP | ⚠️ 仅 `mustResolve` | ❌ |
| 单点切换（不并列） | ✅ | ✅ | — | ✅ | ❌ 并发查询 |
| 零中断切换 | ✅ SIGHUP | ❌ `service network reload` | — | ✅ | ✅ |
| LuCI 界面 | ✅ | ❌ | ✅ | ❌ | ✅ |
| 是标准 opkg 包 | ✅ | ❌ 安装脚本 | ✅ | ✅ | ✅ |
| 体积 | ~20 KB | ~5 KB | ~30 KB | 2.4 MB | 4 MB |

---

## 故障排查

**日志里一直是 `no healthy upstream`**

```sh
# 手工跑一次探测看输出
/usr/sbin/dnswatchd probe 192.168.10.2 www.google.com 198.18.0.0/16 in

# 看 dnsmasq 实际收到什么
nslookup www.google.com 192.168.10.2
```

如果手工 `nslookup` 返回真实 IP 而不是 `198.18.x.x`，说明 clash 的 fake-ip 没生效或规则把该域名走了 DIRECT——改 `probe_domain`。

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
