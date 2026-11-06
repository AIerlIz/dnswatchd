# dnswatchd

OpenWrt 的上游 DNS 看门狗。

它持续探测 dnsmasq 使用的上游解析器，校验应答是否落在预期网段内——代理型上游
应该落在 Clash 的 fake-ip 池里，直连型应该落在池外。首选上游不再给出正确应答时，
它把 dnsmasq 的 `servers-file` 改写成下一个候选并重载；首选上游恢复后再切回来。

**装包本身不会改变你的 DNS 行为**。把 dnsmasq 交出去是一个单独的、显式的、可回滚
的动作。

## 为什么需要它

fake-ip 代理和运营商 DNS 同时在 dnsmasq 的候选池里，你就失去了「谁在应答」的控制权。
代理只需要慢一拍，真实 IP 就会漏进本该是 fake-ip 的域名里——建立在那些地址上的
路由规则、防火墙标记随之全部失效。

dnsmasq 没有「这个上游在骗我」的概念。dnswatchd 补上这个概念，并且始终只保留一条
上游，让选择结果没有歧义。

## 要求

- OpenWrt 23.05 或 24.10，`dnsmasq` 或 `dnsmasq-full`
- feed 支持的架构（见下），或者自己编译

25.12 的包管理器换成了 `apk`，而这个 feed 发布的是给 `opkg` 用的 `ipk`。
源码在 25.12 上原样可编（见「源码编译」），但那里不走 `opkg install`，
目前也还没有发布 `apk` feed。

## 安装

```sh
opkg print-architecture

wget -O /etc/opkg/dnswatchd.conf \
  https://AIerlIz.github.io/dnswatchd/dnswatchd-aarch64_cortex-a53.conf

opkg update
opkg install dnswatchd
opkg install luci-app-dnswatchd      # Web 界面，可选
opkg install luci-i18n-dnswatchd-zh-cn   # 中文界面，可选
```

目前发布 `x86_64`、`aarch64_generic`、`aarch64_cortex-a53`、
`arm_cortex-a7_neon-vfpv4`、`mipsel_24kc`、`mips_24kc` 六种架构。
其它架构见「源码编译」。

## 首次使用

装完什么都不会发生，dnsmasq 保持原样。

**Web 界面**——*服务 → DNS Watchdog*。状态面板会显示 dnsmasq 当前用的是什么；
点「接管 DNS」执行迁移。弹窗会逐条列出将要改动的内容，请先看完。
「交还 DNS」可以撤销。

**命令行**，效果相同：

```sh
dnswatchd takeover     # 备份、让 dnsmasq 指向我们、关掉 resolv.conf
dnswatchd status       # 看当前状态
dnswatchd rollback     # 全部还原
```

如果 `dhcp.@dnsmasq[0].serversfile` 已经被别的软件占用，`takeover` 会拒绝执行，
不会覆盖别人的配置。

### takeover 到底改了什么

1. 把 dnsmasq 的 UCI 配置和即将改动的精确原值存进
   `/etc/dnswatchd/backup/<时间戳>/`
2. 用 dnsmasq 原有的第一条上游初始化 servers-file
3. 清空 `dhcp.@dnsmasq[0].server`
4. 把 `serversfile` 设为 `/etc/dnswatchd/servers`
5. 把 `noresolv` 设为 `1`
6. 新增一条 `isp` 上游（`source=resolv`），让运营商 DNS 作为一条真实的、
   最低优先级的候选留在列表里
7. 重载 dnsmasq 并启用服务

第 5 步是关键，也是最容易漏的一步：`noresolv=0` 时 dnsmasq 一直把
`/tmp/resolv.conf.d/resolv.conf.auto` 留在候选池里，运营商 DNS 不管你配没配，
都是第二条上游。

## 配置

`/etc/config/dnswatchd`，Web 界面里都能改。

```uci
config dnswatchd 'main'
	option enabled '0'              # 总开关，takeover 会打开
	option interval '30'            # 每轮间隔（秒），最小 5
	option probe_deadline '2000'    # 单次 DNS 查询毫秒上限，硬截止
	option fail_threshold '2'       # 连续失败几次判定 DOWN
	option recover_threshold '2'    # 连续成功几次判定 UP
	option servers_file '/etc/dnswatchd/servers'
	option selection 'priority'     # priority | latency
	option latency_margin '20'      # 百分比，仅 latency
	option latency_switch_after '2' # 连续胜出轮数，仅 latency
	option round_budget '80'        # 一轮最多花掉间隔的百分比
	option dry_run '0'              # 只记日志，不改文件
	option syslog '1'
	option verbose '0'
```

每条上游：

```uci
config upstream 'primary'
	option enabled '1'
	option source 'static'          # static | resolv
	option address '192.168.10.2'
	option port '53'
	option probe_domain 'www.google.com'
	option expect_cidr '198.18.0.0/16'
	option expect_mode 'in'         # in | not-in | any
	option priority '10'
```

`source='resolv'` 会忽略 `address`，改为展开
`/tmp/resolv.conf.d/resolv.conf.auto` 里的 IPv4 nameserver，最多两条，
命名为 `<section>_1`、`<section>_2`。

### 一轮怎么判定

每轮探测**所有**启用的上游（不会探到第一个健康的就停——那样状态页会骗人）。然后：

- `selection='priority'`：priority 数字最小的、可用的胜出
- `selection='latency'`：实测 DNS 往返最小的胜出，但必须比当前快出
  `latency_margin` 百分比，且连续赢 `latency_switch_after` 轮

一轮耗时超过 `round_budget`（间隔的百分比）就停止探测，用手上的结果做决定。

## 命令

```
dnswatchd                        运行主循环（procd 启动的就是这个）
dnswatchd once [--json]          只跑一轮
dnswatchd status [--json]        查看状态
dnswatchd probe <addr> <domain> [cidr] [mode] [port]
dnswatchd switch <section>       强制使用某条上游，跳过选择策略
dnswatchd takeover               接管 dnsmasq
dnswatchd rollback               交还
dnswatchd apply                  提交暂存的 UCI 并重启（LuCI 用）
```

`status --json` 是给机器看的：当前上游、每条上游的计数与最近一次往返延迟、
以及 dnsmasq 自身的配置。

## 限制

- 只处理 IPv4，不看也不校验 `AAAA`。
- 只支持 dnsmasq；smartdns、mosdns 之类自己管上游的软件不在范围内。
- 同一时刻只有一条上游，这是设计而非缺陷。想让多个同时应答，这个工具不合适。
- 探针是静态链接的编译产物，所以包是架构相关的。

## 源码编译

```sh
echo "src-git dnswatchd https://github.com/AIerlIz/dnswatchd.git" >> feeds.conf.default
./scripts/feeds update dnswatchd
./scripts/feeds install -a -p dnswatchd
make package/dnswatchd/compile V=s
make package/luci-app-dnswatchd/compile V=s
```

## 测试

不需要 OpenWrt：

```sh
gcc -O2 -o /tmp/dnswatch-probe dnswatchd/files/dnswatch-probe.c
sh tests/probe/run.sh /tmp/dnswatch-probe
sh tests/core/run.sh
sh tests/core/takeover.sh
```

## 更多

- [docs/DESIGN.md](docs/DESIGN.md) —— 不变量与它们的来历
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) —— 出问题时看这里

## 许可

MIT
