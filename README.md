# dnswatchd

OpenWrt 上的 DNS 上游看门狗。探测 dnsmasq 的上游，检查应答落在哪个网段，不对就切换。

## 起因

家里是这样的结构：

```
客户端 → 主路由 dnsmasq → 旁路由（clash，fake-ip）→ 上游
```

旁路由是台 VM。更新内核重启它，dnsmasq 就一直往那个地址发查询，全网的 DNS 挂了，
得自己发现、自己上去修。

想配两个上游省事，结果更糟。dnsmasq 会把查询同时发给所有上游、用最先回的那个。
一个上游返 fake-ip，另一个返真实 IP，谁先到就决定这次查询走不走代理。一半时候能用，
看起来像网络不稳，翻日志也看不出所以然。

后来写了个脚本盯着，反复改了几轮，做成包。

## 关键约束

dnsmasq 的 `--server` 和 `--servers-file` 里的条目会**合并生效**。所以：

- `--servers-file` 里永远只写一行 `server=`
- UCI 里的 `server` 列表必须清空

只要同时存在两条，就回到并发查询、fake-ip 被冲掉的状态。安装脚本会自动处理这两件事，
升级后建议自己再确认一遍。

## 检查什么

旁路由出问题有两种，表现完全不一样：

- **VM 关机 / 链路断** —— 查询超时，任何看门狗都能发现。
- **clash 崩了，dnsmasq 还活着** —— 立刻返回错答案，端口开着，`nslookup` 退出码 0，
  返回的是真实 IP。代理已经悄悄不工作了，但表面上一切正常。

第二种是写这个项目的真正原因。所以探针看内容：

```
代理型上游：查 www.google.com → 答案必须在 198.18.0.0/16 内
直连型上游：查 www.baidu.com  → 答案必须在 198.18.0.0/16 外
```

落在错的段就不健康，端口通不通不算数。

## 安装

```sh
wget -O /etc/opkg/dnswatchd.conf https://AIerlIz.github.io/dnswatchd/dnswatchd.conf
opkg update
opkg install dnswatchd
opkg install luci-app-dnswatchd   # 想要 Web 界面就装这个
```

自己编：

```sh
cd openwrt-sdk
echo "src-git dnswatchd https://github.com/AIerlIz/dnswatchd.git" >> feeds.conf.default
./scripts/feeds update dnswatchd
./scripts/feeds install -a -p dnswatchd
make package/dnswatchd/compile V=s
```

产物是 `PKGARCH:=all`，任何架构通用。

安装脚本（`/etc/uci-defaults/90-dnswatchd`）会做这几件事，跑一次就完：

1. 把现有的 `dhcp.@dnsmasq[0].server` 存一份到 `/etc/dnswatchd.servers.bak`
2. 用第一条初始化 `/tmp/dnsmasq.servers`，保证迁移瞬间 DNS 不断
3. 清空 UCI 的 `server` 列表
4. 打开 `dhcp.@dnsmasq[0].serversfile`
5. 把那个地址填进 `dnswatchd.primary.address`
6. 重启 dnsmasq
7. 写 `/etc/dnswatchd.migrated` 标记，以后不再跑

如果原来的上游是 `127.0.0.1` 这类本地地址，不会迁移过去（那是别的软件的事），
servers-file 会先填 `223.5.5.5` 兜底。

**装完默认不启用**（`enabled '0'`）。

## 先跑 dry-run

```sh
uci set dnswatchd.main.enabled='1'
uci set dnswatchd.main.dry_run='1'
uci commit dnswatchd
/etc/init.d/dnswatchd restart

logread -f -e dnswatchd
```

只看日志不动手。确认判定符合预期了再关掉：

```sh
uci set dnswatchd.main.dry_run='0'
uci commit dnswatchd
/etc/init.d/dnswatchd restart
```

## 配置

`/etc/config/dnswatchd`，完整的一份：

```uci
config dnswatchd 'main'
	option enabled '0'                 # 总开关，装完默认关
	option interval '30'               # 探测间隔（秒），最小 5
	option timeout '1'                 # 单次 nslookup 超时（秒）
	option fail_threshold '2'          # 连续失败几次算 DOWN
	option recover_threshold '2'       # 连续成功几次算 UP
	option servers_file '/tmp/dnsmasq.servers'

	option selection 'priority'        # priority 或 latency

	# 只在 selection='latency' 时有用
	option latency_samples '3'         # ping 采几次
	option latency_margin '20'         # 比现在快多少百分点才考虑切
	option latency_switch_after '2'    # 还要连续赢几轮

	option dry_run '0'
	option syslog '1'
	option verbose '0'                 # 1 = 「稳定在某上游」也写日志

config upstream 'primary'
	option enabled '1'
	option type 'proxy'                # proxy | direct，只作标记
	option address '192.168.10.2'
	option port '53'
	option probe_domain 'www.google.com'
	option expect_cidr '198.18.0.0/16'
	option expect_mode 'in'            # in | not-in
	option priority '10'               # 数字小的先用

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

`upstream` 段想加几个加几个。`expect_cidr` 留空就只要求能解析出 A 记录，不校验内容。

LuCI 里在**服务 → DNS Watchdog**，界面顶部有 13 个常用公共 DNS 的预设，
选一个点「添加到上游列表」会自动建好一条，优先级取当前最大值 +10。
不想用预设在下面的表格里手填也行。

## 两种选法

`priority`：按数字从小到大试，第一个健康的就用。全都不健康就不动 servers-file。

```
proxy(10) 通了       → 用 proxy
proxy(10) 挂了       → 试 fallback(20)
两个都挂             → 什么都不做，保持原样
```

`latency`：全部探一遍，留健康的，一个个 ping，取最快的。

```
proxy(10) 49ms, fallback(20) 28ms, third(30) 0.6ms
→ 选 third，虽然它 priority 最大
```

不是稍微快一点就切。新候选要比现在快 `latency_margin` 个百分点，再连续赢
`latency_switch_after` 轮才算数。当前上游已经不健康时这两条都不管，直接切。

`latency` 有两个前提：

- 上游要回 ICMP。`1.1.1.1`、`223.5.5.5`、`119.29.29.29` 都回，部分企业 DNS 不回。
  不回的不排除，只是记一个 `99999` 排在最后。
- 探针要能直接到上游。跑在劫持了 UDP/53 的环境里，能不能解析和 RTT 都不可信。

至于为什么用 ping 而不是直接测 DNS 响应时间：busybox 的 `date +%s%N` 在 OpenWrt
上只到秒（实测 `1793954264`），shell 里测不了几十毫秒。ping 的 RTT 是网络那一段往返，
服务端处理再加几毫秒。

## 命令行

```sh
/usr/sbin/dnswatchd once
/usr/sbin/dnswatchd status
/usr/sbin/dnswatchd probe 192.168.10.2 www.google.com 198.18.0.0/16 in
```

`status` 长这样：

```
active: primary
servers-file: /tmp/dnsmasq.servers
  # managed by dnswatchd - do not edit
  server=192.168.10.2
--- primary ---
  fails:  0
  oks:    7
  status: up
--- fallback ---
  fails:  6
  oks:    0
  status: down
```

状态文件在 `/var/run/dnswatchd/`，重启清空，计数从零开始。

## 内部

```
每 interval 秒：

  按 priority 顺序（或全部）遍历 upstream

  probe(addr, port, domain, cidr, mode)
    nslookup -type=A -timeout=T -retry=1 <domain> <addr>
    取最后一个 Address 行，跟 cidr 比

  带滞回
    ok   → oks++,  fails=0；oks  >= recover_threshold → up
    fail → fails++, oks=0；fails >= fail_threshold   → down

  第一个 up 的胜出

  跟当前激活的不一样才动手：
    echo "server=<addr>" > /tmp/dnsmasq.servers
    kill -HUP $(pidof dnsmasq)
    echo "<section>" > /var/run/dnswatchd/active
```

用 `--servers-file` 而不是 `uci set` + reload，是因为后者要重启 dnsmasq，DNS 断一两秒。
`SIGHUP` 是 dnsmasq 给动态上游留的口子，而且不碰 `/etc/config/dhcp`，不会跟手改的配置打架。

## 已知问题

- **必须有 dnsmasq 2.86 以上**（`--servers-file` 从那个版本开始）。
- **只能跑在能直达上游的那台机器上**。放在旁路由自己去探外网，结果没意义。
- `latency` 模式下不响应 ICMP 的上游会排最后，哪怕它实际解析很快。
- 纯 shell，没有 Lua 也没有 ucode 依赖，但也就没有并发，上游多的时候一轮会慢一点
  （6 个上游 × 3 次 ping 大约 5 秒）。
- `interval` 最小 5 秒，再小没意义（一轮探测本身就要几秒）。

## 许可

MIT
