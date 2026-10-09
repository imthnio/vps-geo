# VPS 出口 IP 一键切换

粘贴一条 SOCKS5，起一个自己喜欢的命令名（比如 `geous`），以后在终端输入 `geous` 就换到这个出口 IP，输入 `geooff` 恢复本机 IP。

- 自动检测：**小鸡还是母鸡**（KVM / Xen / VMware / OpenVZ / LXC / Docker / 物理机），以及系统、架构、CPU、内存、硬盘、IPv6
- 兼容 Alpine、Debian、Ubuntu、CentOS / Rocky / Alma、Arch，x86_64 / ARM 都可以
- **64MB 内存的 Alpine 小鸡也能用**：纯 sh 脚本，不需要 Python；代理核心是一个静态程序，常驻内存约 10MB，小内存机器会自动开启省内存模式
- 支持两种作用范围：**整机** 或 **本机代理端口**

## 安装（root 运行）

```sh
wget -qO install.sh https://raw.githubusercontent.com/imthnio/vps-geo/main/install.sh || curl -fsSLo install.sh https://raw.githubusercontent.com/imthnio/vps-geo/main/install.sh; sh install.sh
```

机器连不上 GitHub 时，在前面加一个下载加速前缀：

```sh
GEO_GH_PROXY=https://ghfast.top/ sh install.sh
```

## 运行后会问三件事

```
第 1 步：填写 SOCKS5
请粘贴 SOCKS5 地址: socks5://用户名:密码@isp-nm.jchen.eu.org:50001
[✓] 代理可用
  出口 IP : 203.0.113.8
  国家    : 美国 (US)

第 2 步：设置快捷命令
快捷切换命令 [geous]: geous

第 3 步：出口 IP 作用范围
  1) 整机：这台机器发出去的所有 TCP 连接都走这个出口
  2) 端口：在本机开一个代理端口，只有指向这个端口的程序/节点才走这个出口，其它流量不变
请选择 1 或 2 [1]:
```

SOCKS5 的写法这几种都认：

- `socks5://用户名:密码@主机:端口`
- `socks5h://用户名:密码@主机:端口`
- `用户名:密码@主机:端口`
- `主机:端口:用户名:密码`
- `主机:端口`（没有账号密码）

快捷命令会按代理的国家自动给一个默认名（美国就是 `geous`），直接回车就行。

## 两种模式怎么选

| | 整机 | 端口 |
| --- | --- | --- |
| 效果 | 本机所有出站 TCP 都换 IP | 本机多一个 `127.0.0.1:1080`（SOCKS5 + HTTP 同一个端口） |
| 适合 | 让整台机器看起来在别的国家 | 给 xray / sing-box 等节点当出站，或者给某个程序单独用 |
| 要求 | 需要改 iptables 的权限 | 任何机器都能用 |

- OpenVZ / LXC 小鸡经常不允许改 NAT 规则，选整机时脚本会自动检测，不行就自动改成端口模式。
- 母鸡上开整机模式只影响母鸡自己发起的连接，下面的小鸡不受影响。
- 整机模式下 DNS 查询仍然直连。有 IPv6 的机器，能接管就让 IPv6 也走代理；接管不了就拦截 IPv6 的 TCP 连接，让程序退回 IPv4，不让真实 IP 漏出去。
- 整机模式切换后如果发现代理不通，会自动恢复直连，不会让机器断网。

端口模式的用法举例：

```sh
curl -x socks5h://127.0.0.1:1080 ipinfo.io
```

xray 出站：

```json
{ "protocol": "socks", "settings": { "servers": [{ "address": "127.0.0.1", "port": 1080 }] } }
```

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `geous`（你自己起的名字） | 切换到这个出口 |
| `geooff` | 关闭，恢复本机 IP |
| `geo` | 打开菜单：添加 / 切换 / 删除 / 查看 / 卸载 |
| `geo status` | 查看当前出口 IP |
| `geo list` | 列出所有出口 |
| `geo add` | 再添加一个出口（比如 `geojp`） |
| `geo del geous` | 删除一个出口 |
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

代理程序以单独的 `geo` 用户运行。整机模式用 iptables 的 `GEO_OUT` 链，`geooff` 或卸载时会全部删掉。

## 从旧版升级

旧版用环境变量和 `/etc/geo/proxies.tsv`。重新运行一次 `install.sh`，它会清掉旧的 `/etc/profile.d/geo.sh` 和环境变量设置，`proxies.tsv` 保留不动，可以对照它用 `geo add` 重新添加。

## Contributors

whatcanisay
