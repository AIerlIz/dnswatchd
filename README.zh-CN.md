# dnswatchd

**简体中文** | [English](README.md)

盯着 dnsmasq 的上游，答案不对就切换。

![license](https://img.shields.io/badge/license-MIT-blue)

## 为什么做这个

很多人的组网是这样：

```
客户端 -> 主路由 dnsmasq -> 一台跑 clash 的 VM（fake-ip 模式）-> 上游
```

那台 VM 更新内核重启一次，dnsmasq 就还在往一个已经不响的地址发查询，全网的
DNS 挂了，得手动发现再手动修。

想靠配两个上游解决，反而更糟。dnsmasq 会同时发给所有上游、用最先回的那个。
一个上游返回 fake-ip 地址，另一个返回真实地址，谁先到就决定了这次查询走不走
代理。结果是一半时候能用，看起来像网络不稳定。

## 做了什么

探测的时候检查答案落在哪个网段，不只看有没有回应。切换的时候，往 dnsmasq 的
servers-file 里写且只写一行 `server=`。

dnsmasq 收到 `SIGHUP` 会重新读这个文件。不重启进程，DNS 不断。

## 检查什么

旁路由出问题有两种情况，表现完全不同：

| 故障 | dnsmasq 看到的 | 只看超时的看门狗 |
|---|---|---|
| VM 关机，或者链路断了 | 没有回应，查询超时 | 能发现 |
| clash 崩了，dnsmasq 还活着 | 立刻返回一个错答案 | 发现不了 |

第二种才麻烦。端口开着，`nslookup` 退出码是 0，返回的是真实 IP，因为代理已经
悄悄不工作了，但表面上看不出问题。

所以探针检查内容：

```
代理型上游：查 www.google.com -> 答案必须落在 198.18.0.0/16 内
直连型上游：查 www.baidu.com  -> 答案必须落在 198.18.0.0/16 外
```

落在错的网段就算不健康，端口通不通都不算数。

## 安装

从 feed：

```sh
wget -O /etc/opkg/dnswatchd.conf https://AIerlIz.github.io/dnswatchd/dnswatchd.conf
opkg update
opkg install dnswatchd
opkg install luci-app-dnswatchd   # 可选，Web 界面
```

从源码，在你的 SDK 目录里：

```sh
echo "src-git dnswatchd https://github.com/AIerlIz/dnswatchd.git" >> feeds.conf.default
./scripts/feeds update dnswatchd
./scripts/feeds install -a -p dnswatchd
make package/dnswatchd/compile V=s
```

ipk 在 `bin/packages/<arch>/dnswatchd/`。`PKGARCH:=all`，跟架构无关。

## 配置前先确认

这两条不满足的话，切换要么不起作用，要么跟 UCI 打架：

```sh
uci get dhcp.@dnsmasq[0].serversfile
# 要是 /tmp/dnsmasq.servers

uci get dhcp.@dnsmasq[0].server
# 要是空或者报错
```

安装脚本会处理好。升级后记得再看一遍。

然后开着 dry-run 观察一天：

```sh
uci set dnswatchd.main.dry_run='1'
uci set dnswatchd.main.enabled='1'
uci set dnswatchd.main.interval='30'
uci commit dnswatchd
/etc/init.d/dnswatchd restart

logread -f -e dnswatchd
```

`enabled` 默认是 `0`，不设它什么都不会跑。

脚本会把你原来的 `dhcp.@dnsmasq[0].server` 备份到
`/etc/dnswatchd.servers.bak`，取第一条初始化 `/tmp/dnsmasq.servers`，清空 UCI
里的列表，再把那个地址填进 `dnswatchd.primary.address`。

确认判定没问题之后：

```sh
uci set dnswatchd.main.dry_run='0'
uci commit dnswatchd
/etc/init.d/dnswatchd restart
```

## 配置

`/etc/config/dnswatchd`：

```uci
config dnswatchd 'main'
	option enabled '1'                 # 总开关
	option interval '30'               # 秒，最小 5
	option timeout '1'                 # 单次探测超时
	option fail_threshold '2'          # 连续失败几次算 DOWN
	option recover_threshold '2'       # 连续成功几次算 UP
	option servers_file '/tmp/dnsmasq.servers'
	option selection 'priority'        # priority | latency
	option latency_samples '3'         # latency：ping 几次
	option latency_margin '20'         # latency：要快多少百分点才切
	option latency_switch_after '2'    # latency：连续赢几轮才切
	option dry_run '0'
	option syslog '1'
	option verbose '0'

config upstream 'primary'
	option enabled '1'
	option type 'proxy'                # proxy | direct，只是个标签
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

`upstream` 段想加几个加几个。

## 怎么选上游

`priority` 按数字从小到大试，第一个健康的就用。

```
proxy(10) 健康      -> 用它
proxy(10) 挂了      -> aliyun(20) 健康？用
aliyun(20) 也挂     -> tencent(30) 健康？用
全都不健康          -> servers-file 不动
```

`latency` 全探一遍，留健康的，逐个 ping，取最快的。

```
healthy:  proxy(10) 49ms, aliyun(20) 28ms, tencent(30) 0.6ms
选中:     tencent
```

不是稍微快一点就切。两个限制：

| 选项 | 默认 | 含义 |
|---|---|---|
| `latency_margin` | 20 | 新候选要比现在快这么多百分点才考虑 |
| `latency_switch_after` | 2 | 然后还要连续赢这么多轮 |

当前上游已经不健康时这两条都不管，因为没有需要保护的东西。

`latency` 模式要求上游回 ICMP。`1.1.1.1`、`223.5.5.5`、`119.29.29.29` 都回。
有些企业 DNS 不回，这种不会被排除，只是记一个假的 `99999` 排在最后。

还要求探针能直接到上游。跑在劫持了 UDP/53 的环境里，能不能解析和 RTT 都是假的。

### 为什么用 ping

busybox 的 `date +%s%N` 在 OpenWrt 上只给到秒（实测 `1793954264`），shell 里
测不了几十毫秒。

只剩 ping 的 RTT 可用。它测的是网络那一段往返，服务端处理再加几毫秒。

### 用哪个

- 旁路由加一两个兜底：`priority`。你要的就是旁路由，别的只是保险。
- 几个公共 DNS，无所谓用哪个：`latency`。
- 延迟一直跳：`priority`。少切几次。

## 命令行

```sh
/usr/sbin/dnswatchd once      # 跑一轮
/usr/sbin/dnswatchd status    # 它现在认为在哪
/usr/sbin/dnswatchd probe 192.168.10.2 www.google.com 198.18.0.0/16 in
```

`status` 的输出：

```
active: primary
servers-file: /tmp/dnsmasq.servers
  # managed by dnswatchd - do not edit
  server=192.168.10.2
--- primary ---
  fails=0
  oks=7
  status=up
--- fallback ---
  fails=6
  oks=0
  status=down
```

## 内部怎么跑的

```
每 interval 秒：

  按 priority 顺序走一遍 upstream

  probe(addr, domain, cidr, mode)
    nslookup -type=A -timeout=T -retry=1 <domain> <addr>
    取最后一个 Address 行，跟 cidr 比

  带滞回
    ok   -> oks++,  fails=0；oks  >= recover_threshold -> up
    fail -> fails++, oks=0；fails >= fail_threshold   -> down

  第一个标记为 up 的胜出

  跟当前激活的不一样才动手：
    echo "server=<addr>" > /tmp/dnsmasq.servers
    kill -HUP $(pidof dnsmasq)
    echo "<section>" > /var/run/dnswatchd/active
```

用 `--servers-file` 不用 `uci set`，是因为服务 reload 会重启 dnsmasq，DNS 断
一两秒。`SIGHUP` 是 dnsmasq 专门给动态上游留的口子，而且不碰 `/etc/config/dhcp`。

只写一行，是因为 dnsmasq 会把 `--server` 和 `--servers-file` 合并。两条就又回到
并发查询、fake-ip 被冲掉那条路上。

## 跟别的比

| | dnswatchd | felipecrs/dns-watchdog | watchcat | dnsdist | smartdns |
|---|---|---|---|---|---|
| 检查答案内容 | 是 | 否，只看超时 | 否，只看 ICMP | 只有 `mustResolve` | 否 |
| 只切到一个上游 | 是 | 是 | - | 是 | 否，并发查 |
| 切换不断 DNS | 是，SIGHUP | 否，`service network reload` | - | 是 | 是 |
| LuCI | 有 | 无 | 有 | 无 | 有 |
| opkg 包 | 是 | 否，安装脚本 | 是 | 是 | 是 |
| 体积 | ~20 KB | ~5 KB | ~30 KB | 2.4 MB | 4 MB |

## 出问题的时候

**日志一直是 `no healthy upstream`**

```sh
/usr/sbin/dnswatchd probe 192.168.10.2 www.google.com 198.18.0.0/16 in
nslookup www.google.com 192.168.10.2
```

手工查出来是真 IP 不是 `198.18.x.x`，说明 fake-ip 没开，或者有规则把这个域名
放 DIRECT 了。改 `probe_domain`。

**切了但 DNS 还是不通**

```sh
ps w | grep [d]nsmasq     # 应该能看到 --servers-file=/tmp/dnsmasq.servers
uci show dhcp.@dnsmasq[0].server   # 应该是空的
```

**来回切**

把 `fail_threshold` 和 `recover_threshold` 调高。缩短 `interval` 也有用，但有
下限。

## 许可

MIT
