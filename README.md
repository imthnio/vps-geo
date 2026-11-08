# VPS 出口 IP 一键切换 + 节点出口分流

输入 `geo` 打开主菜单，三大功能：

| 菜单 | 功能 |
| --- | --- |
| **1) 整机出口切换** | 粘贴一条 SOCKS5，起一个命令名（比如 `geous`），以后输入 `geous` 整台机器就换到这个出口 IP，`geooff` 恢复本机 IP |
| **2) 节点出口分流** | 自动检测本机所有节点（xray / sing-box / hysteria2 的每个入站），**给每个节点单独填出口 IP** |
| **3) 节点管理 / 出口管理** | 查看节点和出口、检测出口是否可用、添加 / 修改 / 删除出口、去掉节点出口、手动添加节点配置 |

- 自动检测：**小鸡还是母鸡**（KVM / Xen / VMware / OpenVZ / LXC / Docker / 物理机），以及系统、架构、CPU、内存、硬盘、IPv6
- 兼容 Alpine、Debian、Ubuntu、CentOS / Rocky / Alma、Arch，x86_64 / ARM 都可以
- **64MB 内存的 Alpine 小鸡也能用**：纯 sh 脚本，不需要 Python；代理核心是一个静态程序，常驻内存约 10MB，小内存机器会自动开启省内存模式
- 支持两种作用范围：**整机**（推荐，搭节点选这个）或 **本机代理端口**
- OpenVZ / LXC / Podman / Docker 小鸡不允许改网络规则也没关系：脚本会自动接管 xray / sing-box / hysteria2 节点，让节点走这个出口

## 安装（root 运行）

```sh
wget -qO install.sh https://raw.githubusercontent.com/imthnio/vps-geo/main/install.sh || curl -fsSLo install.sh https://raw.githubusercontent.com/imthnio/vps-geo/main/install.sh; sh install.sh
```

机器连不上 GitHub 时，在前面加一个下载加速前缀：

```sh
GEO_GH_PROXY=https://ghfast.top/ sh install.sh
```

## 菜单 1 添加整机出口时会问三件事

```
第 1 步：填写 SOCKS5
请粘贴 SOCKS5 地址: socks5://用户名:密码@isp-nm.jchen.eu.org:50001
[✓] 代理可用
  出口 IP : 203.0.113.8
  国家    : 美国 (US)

第 2 步：设置快捷命令
快捷切换命令 [geous]: geous

第 3 步：出口 IP 用在哪里
  1) 整机（推荐，搭节点就选这个）：节点和这台机器访问外网都用这个出口 IP
  2) 只开一个本机代理端口：给会自己改配置的人用，其它流量不变
请选择 1 或 2 [1]:
```

SOCKS5 的写法这几种都认：

- `socks5://用户名:密码@主机:端口`
- `socks5h://用户名:密码@主机:端口`
- `用户名:密码@主机:端口`
- `主机:端口:用户名:密码`
- `主机:端口`（没有账号密码）

快捷命令会按代理的国家自动给一个默认名（美国就是 `geous`），直接回车就行。

## 2) 节点出口分流

一台机器上搭了很多节点，想让 **每个节点从不同的出口 IP 出去**，就用这个。出口这样写，`#` 后面是出口的名字：

```
socks5://user-nl:globe-server-nl@10.91.0.1:8080#user-nl
socks5://user-de:globe-server-de@10.91.0.1:8080#user-de
```

```
==== 节点出口分流：给每个节点填出口 IP ====
  [xray]  /usr/local/etc/xray/config.json  [运行中]
    1) vless        端口 443    标签 vless-in    出口: 默认出站
    2) vmess        端口 8443   标签 vmess-in    出口: → user-nl  socks5://user-nl:****@10.91.0.1:8080
  [sing-box]  /etc/sing-box/config.json  [运行中]
    3) hysteria2    端口 2054   标签 hy2-in      出口: 默认出站

选节点: 输入序号，多个用空格隔开（如 1 3 或 2-5），a = 全部
选择节点: 1 3
填出口: 输入已有出口的序号或名字，或者直接粘贴新的出口
出口: socks5://user-de:globe-server-de@10.91.0.1:8080#user-de
```

- 节点找法和整机模式的「节点接管」一样：直接找正在运行的 xray / v2ray / sing-box / hysteria 进程读出配置文件，也会看常见位置；都找不到时可以在菜单 3 里手动填配置路径
- xray / sing-box 按 **入站** 分：一个配置文件里有多个入站，每个都可以填不同的出口；hysteria2（官方版）一个配置就是一个节点
- 脚本在节点配置里加一个 socks 出站 `geo-x-<名字>` 和一条路由规则（这些入站 → 这个出口），规则放在原有的广告 / 内网屏蔽规则后面、其它规则前面。没有标签的入站会自动补一个 `geo-in-<端口>` 标签
- 改完先用节点程序自检，不通过就自动还原；通过就重启节点。第一次修改前的原配置备份在 `/etc/geo/backup-x/`
- 修改出口地址后，用到它的节点自动更新；删除出口或卸载 geo 时，节点自动恢复原来的出站
- 和菜单 1 可以同时用：设置了出口的节点走自己的出口，其余节点和本机走菜单 1 的整机出口
- x-ui / 3x-ui 等面板会自己重写配置，这里不改，请在面板里添加 socks 出站和路由规则

## 1) 整机出口：两种模式怎么选

不懂就选 **1 整机**，剩下的脚本自己判断。

| | 整机 | 端口 |
| --- | --- | --- |
| 效果 | 节点和本机访问外网都换成出口 IP | 本机多一个代理端口（SOCKS5 + HTTP 同一个端口） |
| 适合 | 搭节点、让整台机器看起来在别的国家 | 会自己改程序配置的人 |
| 要不要填端口 | 不用 | 不用，脚本自动选（1080 起），不会占用你搭节点要用的端口 |

整机模式会自动选最合适的办法：

1. **改网络规则（iptables）**：KVM、独服、大多数 LXC 都行。脚本会依次试 `iptables`、`iptables-legacy`、`iptables-nft`，老内核的 OpenVZ 小鸡也常常能用 legacy 版成功。
2. **节点接管**：上面都不行时自动改用这个。脚本会在 xray / sing-box / hysteria2 的配置里加一个出站，让节点的流量走出口 IP。之后再搭节点也没关系，装好后 20 秒内自动接管。卸载 geo 时会把节点配置改回原样。
   - 不管节点是用哪个脚本装的、配置放在哪里都行：脚本直接找正在运行的 xray / v2ray / sing-box / hysteria 进程，读出它用的配置文件，改完后通过它自己的服务重启
   - x-ui / 3x-ui 这类面板会自己重写配置，接管不了，请在面板里加一个 SOCKS 出站 `127.0.0.1:61082`
   - 节点接管模式下，节点以外的程序（比如 curl）还是走本机 IP

几点说明：

- **搭节点时，节点地址要填本机 IP，不是出口 IP。** 整机模式下，搭节点脚本自动检测到的“服务器 IP”可能变成出口 IP，遇到这种情况手动改成本机 IP。`geo status` 第一行会显示本机 IP。
- 母鸡上开整机模式只影响母鸡自己发起的连接，下面的小鸡不受影响。
- 整机模式下 DNS 查询仍然直连；新发起的 UDP 连接（比如 QUIC）会被拦下，程序会自动改用 TCP 走代理，免得用本机 IP 出去。有 IPv6 的机器，能接管就让 IPv6 也走代理，接管不了就拦截 IPv6 的 TCP 连接。
- 整机模式切换后如果发现代理不通，会自动恢复直连，不会让机器断网。

端口模式的用法举例：

```sh
curl -x socks5h://127.0.0.1:1080 ipinfo.io
```

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `geous`（你自己起的名字） | 切换到这个出口 |
| `geooff` | 关闭，恢复本机 IP |
| `geo` | 打开主菜单 |
| `geo status` | 查看当前出口 IP |
| `geo list` | 列出所有出口 |
| `geo add` | 再添加一个出口（比如 `geojp`） |
| `geo del geous` | 删除一个出口 |
| `geo node` | 节点出口分流（菜单 2） |
| `geo manage` | 节点管理 / 出口管理（菜单 3） |
| `geo nodes` | 列出本机节点和它们的出口 |
| `geo exits` | 列出节点出口 |
| `geo exit-add 'socks5://用户:密码@主机:端口#名字'` | 添加节点出口（可一次给多个） |
| `geo exit-test` | 检测全部节点出口的 IP / 国家 / 是否可用 |
| `geo info` | 本机信息（小鸡 / 母鸡检测） |
| `geo update` | 更新脚本 |
| `geo uninstall` | 卸载 |

可以添加多个出口，每个出口有自己的命令和模式，同一时间只有一个生效，开机后自动恢复上次的选择。

## 文件位置

| 路径 | 内容 |
| --- | --- |
| `/usr/local/bin/geo` | 脚本本体 |
| `/usr/local/bin/geo-glider` | 代理核心 [glider](https://github.com/nadoo/glider) |
| `/etc/geo/profiles/*.conf` | 每个出口的配置（只有 root 能读） |
| `/etc/geo/glider.conf` | 当前生效的代理配置 |
| `/etc/geo/exits` | 节点出口列表（只有 root 能读） |
| `/etc/geo/binds` | 哪个节点用哪个出口 |
| `/etc/geo/backup-x/` | 节点配置第一次被修改前的备份 |

代理程序以单独的 `geo` 用户运行。整机模式用 iptables 的 `GEO_OUT` 链，`geooff` 或卸载时会全部删掉。

## 从旧版升级

从 2.0.0 升级：运行 `geo update`，再输入一次你的快捷命令（比如 `geous`）。如果以前在端口模式里填过端口（比如填成了节点要用的端口），脚本会问你要不要改成整机模式，并把那个端口空出来。

更早的版本用环境变量和 `/etc/geo/proxies.tsv`。重新运行一次 `install.sh`，它会清掉旧的 `/etc/profile.d/geo.sh` 和环境变量设置，`proxies.tsv` 保留不动，可以对照它用 `geo add` 重新添加。

## Contributors

imthnio

## 赞赏支持
如果这个脚本帮到了你，欢迎请我喝杯咖啡 ☕  
微信扫一扫下方赞赏码即可：

![赞赏码](./appreciate.png)

