# dnswatchd

OpenWrt 包。探测 dnsmasq 的上游，校验应答落在哪个网段，不对就切换。

## 约束

dnsmasq 的 `--server` 和 `--servers-file` 里的条目会合并生效。所以：

- `--servers-file` 里只写一行 `server=`
- UCI 里的 `server` 列表必须为空

同时存在两条就会并发查询。

## 安装

```sh
wget -O /etc/opkg/dnswatchd.conf https://AIerlIz.github.io/dnswatchd/dnswatchd.conf
opkg update
opkg install dnswatchd
opkg install luci-app-dnswatchd   # Web 界面，可选
```

源码编译：

```sh
echo "src-git dnswatchd https://github.com/AIerlIz/dnswatchd.git" >> feeds.conf.default
./scripts/feeds update dnswatchd
./scripts/feeds install -a -p dnswatchd
make package/dnswatchd/compile V=s
```

`PKGARCH:=all`。

### 安装脚本

`/etc/uci-defaults/90-dnswatchd` 装完跑一次，靠 `/etc/dnswatchd.migrated` 标记保证幂等：

1. 把 `dhcp.@dnsmasq[0].server` 写到 `/etc/dnswatchd.servers.bak`
2. 用第一条初始化 `servers_file`，写一行 `server=<地址>`
3. 逐条删除 UCI 的 `server`
4. `dhcp.@dnsmasq[0].serversfile` 设为同一路径
5. 把该地址填进 `dnswatchd.primary.address`（原地址带 `#端口` 则同时填 `port`）
6. 重启 dnsmasq
7. 写标记文件

首条地址是 `127.*` 或 `::1` 时跳过迁移，`servers_file` 填 `223.5.5.5`。

`enabled` 默认 `0`。

## 配置

`/etc/config/dnswatchd`：

```uci
config dnswatchd 'main'
	option enabled '0'                 # 总开关
	option interval '30'               # 探测间隔（秒），最小 5
	option timeout '1'                 # 单次 nslookup 超时（秒）
	option fail_threshold '2'          # 连续失败几次算 DOWN
	option recover_threshold '2'       # 连续成功几次算 UP
	option servers_file '/tmp/dnsmasq.servers'

	option selection 'priority'        # priority | latency

	# 以下三项仅 selection='latency'
	option latency_samples '3'         # ping 采样次数，1-10
	option latency_margin '20'         # 比当前快多少百分点才考虑切换，0-90
	option latency_switch_after '2'    # 连续赢几轮才切

	option dry_run '0'                 # 只写日志，不改 servers-file
	option syslog '1'
	option verbose '0'                 # 1 时「稳定在某上游」也记日志

config upstream 'primary'
	option enabled '1'
	option type 'proxy'                # proxy | direct，只作标记
	option address '192.168.10.2'
	option port '53'
	option probe_domain 'www.google.com'
	option expect_cidr '198.18.0.0/16'
	option expect_mode 'in'            # in | not-in
	option priority '10'

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

`upstream` 段数量不限。

`expect_cidr` 留空时只要求能解析出 A 记录，不校验内容。

`probe_domain` 默认 `www.baidu.com`，`expect_mode` 默认 `in`，`priority` 默认 `10`，`port` 默认 `53`。

### LuCI

菜单在 `服务 → DNS Watchdog`（`/admin/services/dnswatchd`）。

「常规设置」里有 13 个公共 DNS 的预设，选中后点「添加到上游列表」会新建一条
`upstream`，`priority` 取当前最大值 +10。地址已存在时不添加。下面的表格可以手填任意条目。

## 探测

每次探测：

```
nslookup -type=A -timeout=<timeout> -retry=1 <probe_domain> <address>[#port]
```

取输出中最后一个 `Address:` 行的 IPv4，与 `expect_cidr` 比对：

- `expect_mode='in'`：必须落在 `expect_cidr` 内
- `expect_mode='not-in'`：必须落在 `expect_cidr` 外
- `expect_cidr` 为空：解析出 IPv4 即通过

每个上游的状态存在 `/var/run/dnswatchd/<section>.state`，内容为 `ST_FAILS`、`ST_OKS`、
`ST_STATUS` 三项：

```
探测成功 → oks++,  fails=0；oks  >= recover_threshold → up
探测失败 → fails++, oks=0；fails >= fail_threshold   → down
```

当前激活的上游存在 `/var/run/dnswatchd/active`。

## 选法

`priority`：按 `priority` 升序逐个探测，第一个 `up` 的胜出。全都不 `up` 时不改 servers-file。

`latency`：探测全部上游，保留 `up` 的，逐个 `ping -c <latency_samples> -W 2 -q` 取 avg RTT，
按 `(RTT, priority)` 升序取第一个。

切换到新候选需要同时满足：

- 新候选 RTT < 当前 RTT × (100 - `latency_margin`) / 100
- 连续赢 `latency_switch_after` 轮

当前上游不在 `up` 列表里时两条都跳过。

`ping` 失败（ICMP 不通）的上游 RTT 记为 `99999`，排最后但不排除。

## 应用切换

```sh
printf '# managed by dnswatchd - do not edit\nserver=%s\n' <address> > /tmp/dnsmasq.servers.tmp.$$
mv /tmp/dnsmasq.servers.tmp.$$ /tmp/dnsmasq.servers
kill -HUP $(pidof dnsmasq)
```

`dry_run='1'` 时只写日志，不落盘不 HUP。

## 命令

```sh
/usr/sbin/dnswatchd once
/usr/sbin/dnswatchd status
/usr/sbin/dnswatchd probe <address> <domain> [cidr] [mode]
```

`once` 跑一轮。`status` 输出：

```
active: primary
servers-file: /tmp/dnsmasq.servers
  # managed by dnswatchd - do not edit
  server=192.168.10.2
--- primary ---
  fails:  0
  oks:    7
  status: up
```

`probe` 输出 `OK` 或 `FAIL`，退出码对应 0/1。

`status` 和 `probe` 会先加载配置；配置加载失败时用内置默认值继续。

## 主循环

```sh
load_config || exit 0
mkdir -p /var/run/dnswatchd
trap 'exit 0' TERM INT

while true; do
	run_once
	sleep "$interval" &
	wait $!
done
```

procd 拉起，`respawn 3600 5 5`，`START=95`。

收到 `reload` 时 `stop` + `start`。

## 代码里的边界处理

- `interval` 小于 5 时钳到 5；非数字回落到 30
- `timeout`、`fail_threshold`、`recover_threshold`、`latency_switch_after` 小于 1 时钳到 1
- `latency_samples` 限制在 1-10，`latency_margin` 上限 90
- `selection` 不是 `priority`/`latency` 时回落到 `priority` 并记一条日志
- `apply_upstream` 写临时文件后 `mv`，失败时删临时文件并返回 1
- `dnsmasq` 未运行时写文件但不发 HUP，记一条 WARN

## 许可

MIT
