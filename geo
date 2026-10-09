#!/bin/sh
# Switch this machine's command-line exit country.
# Without permission to change kernel routing, this sets the proxy used by
# curl, wget and other programs that honor proxy environment variables.
set -eu

PROXIES=/etc/geo/proxies.tsv
CURRENT=/etc/geo/current.sh
HOST=isp-nm.jchen.eu.org

usage() {
  cat << 'EOF'
用法:
  geouk     出口切到英国
  geous     美国
  geoau     澳大利亚
  geoca     加拿大
  geofr     法国
  geosg     新加坡
  geojp     日本
  geocn     中国
  geode     德国
  geoph     菲律宾
  geotr     土耳其
  geooff    关闭代理，恢复这台机器自己的出口
  geo       查看当前状态

在已经打开的终端里，直接输入上面的命令即可。
新开的登录也会保持上一次的选择。
代理账号写在 /etc/geo/proxies.tsv，每行: 代码、端口、用户名、密码，用 Tab 分开。
EOF
}

show_json() {
  px=${1:-}
  if [ -n "$px" ]; then
    body=$(curl -4 -fsS --max-time 25 -x "$px" https://ipinfo.io/json) || return 1
  else
    body=$(env -u ALL_PROXY -u all_proxy -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
      curl -4 -fsS --max-time 20 https://ipinfo.io/json) || return 1
  fi
  [ -n "$body" ] || return 1
  printf '%s' "$body" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("出口 IP: %s" % (d.get("ip") or ""))
print("国家: %s" % (d.get("country") or ""))
if d.get("city"):
    print("城市: %s" % d["city"])
if d.get("org"):
    print("网络: %s" % d["org"])
'
}

lookup() {
  code=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  line=$(awk -F '\t' -v c="$code" 'tolower($1)==c {print; exit}' "$PROXIES")
  if [ -z "$line" ]; then
    echo "不认识的国家代码: $1" >&2
    usage >&2
    exit 2
  fi
  port=$(printf '%s' "$line" | awk -F '\t' '{print $2}')
  user=$(printf '%s' "$line" | awk -F '\t' '{print $3}')
  pass=$(printf '%s' "$line" | awk -F '\t' '{print $4}')
  proxy="socks5h://${user}:${pass}@${HOST}:${port}"
}

write_current() {
  umask 077
  cat > "$CURRENT" << EOF
export ALL_PROXY='$proxy'
export all_proxy='$proxy'
export http_proxy='$proxy'
export https_proxy='$proxy'
export HTTP_PROXY='$proxy'
export HTTPS_PROXY='$proxy'
export GEO_CODE='$code'
export no_proxy='localhost,127.0.0.1,::1'
export NO_PROXY='localhost,127.0.0.1,::1'
EOF
  chmod 600 "$CURRENT"
}

turn_on() {
  lookup "$1"
  write_current
  echo "已切换到 $(printf '%s' "$code" | tr '[:lower:]' '[:upper:]')"
  show_json "$proxy" || {
    rm -f "$CURRENT"
    echo "代理不通，没有改出口。" >&2
    exit 1
  }
}

turn_off() {
  rm -f "$CURRENT"
  echo "已关闭国家代理，恢复本机直连。"
  show_json "" || echo "暂时查不到直连出口 IP。"
}

status() {
  if [ -f "$CURRENT" ]; then
    # shellcheck disable=SC1090
    . "$CURRENT"
    echo "当前国家代码: $(printf '%s' "${GEO_CODE:-}" | tr '[:lower:]' '[:upper:]')"
    show_json "${ALL_PROXY:-}" || true
  else
    echo "当前: 直连（未套国家代理）"
    show_json "" || true
  fi
}

name=$(basename "$0")
if [ "$name" = "geo" ]; then
  arg=${1:-status}
else
  arg=$(printf '%s' "$name" | sed 's/^geo//')
fi

case "$arg" in
  ""|help|-h|--help) usage ;;
  status) status ;;
  off|direct|clear) turn_off ;;
  *) turn_on "$arg" ;;
esac
