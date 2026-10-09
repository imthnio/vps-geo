# VPS 出口国家切换

在终端里输入 `geouk`、`geode`、`geoph` 这种命令，当前会话以及之后的登录会改走对应国家的 SOCKS5。`geooff` 恢复这台机器自己的出口。

这台机器如果没有改路由的权限，脚本不会动 iptables。它设置 `ALL_PROXY`、`http_proxy`、`https_proxy`，`curl`、`wget` 以及认这些变量的程序会跟着换出口。

## 安装（用 root 运行，一行）

```sh
sh -c 'command -v curl >/dev/null 2>&1 || { echo "需要 curl"; exit 1; }; curl -fsSL -o /tmp/vps-geo-install.sh https://raw.githubusercontent.com/imthnio/vps-geo/main/install.sh && sh /tmp/vps-geo-install.sh'
```

## 账号表

`/etc/geo/proxies.tsv` 每行四个字段，用 Tab 分开：国家代码、端口、用户名、密码。主机名写在脚本里，默认是 `isp-nm.jchen.eu.org`。示例见 `proxies.example.tsv`。已经有这张表时，安装不会覆盖。

## 命令

| 命令 | 作用 |
| --- | --- |
| `geous` | 美国 |
| `geoau` | 澳大利亚 |
| `geoca` | 加拿大 |
| `geofr` | 法国 |
| `geouk` | 英国 |
| `geosg` | 新加坡 |
| `geojp` | 日本 |
| `geocn` | 中国 |
| `geode` | 德国 |
| `geoph` | 菲律宾 |
| `geotr` | 土耳其 |
| `geooff` | 关闭，恢复直连 |
| `geo` | 查看当前状态 |

已经打开的终端要先重新登录，或执行 `. /etc/profile.d/geo.sh`，函数才会进当前 shell。

## Contributors

whatcanisay
