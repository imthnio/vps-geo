#!/bin/sh
# Install geouk / geode / geooff on a VPS.
set -eu

need() {
  command -v "$1" >/dev/null 2>&1
}

if ! need curl || ! need python3 || ! need awk; then
  if need apk; then
    apk add --no-cache curl python3 ca-certificates
  elif need apt-get; then
    apt-get update -y
    apt-get install -y curl python3 ca-certificates
  elif need dnf; then
    dnf install -y curl python3 ca-certificates
  elif need yum; then
    yum install -y curl python3 ca-certificates
  else
    echo "缺少 curl 或 python3，请先装好再运行。" >&2
    exit 1
  fi
fi

BASE="https://raw.githubusercontent.com/imthnio/vps-geo/main"
TMP=${TMPDIR:-/tmp}/vps-geo-install
mkdir -p "$TMP" /etc/geo /usr/local/bin /etc/profile.d
umask 077

fetch() {
  url=$1
  out=$2
  curl -fsSL --max-time 30 -o "$out" "$url"
}

if [ -f ./geo ] && [ -f ./profile.sh ]; then
  cp ./geo "$TMP/geo"
  cp ./profile.sh "$TMP/profile.sh"
  [ -f ./proxies.example.tsv ] && cp ./proxies.example.tsv "$TMP/proxies.example.tsv"
else
  fetch "$BASE/geo" "$TMP/geo"
  fetch "$BASE/profile.sh" "$TMP/profile.sh"
  fetch "$BASE/proxies.example.tsv" "$TMP/proxies.example.tsv" || true
fi

install -m 755 "$TMP/geo" /usr/local/bin/geo
install -m 644 "$TMP/profile.sh" /etc/profile.d/geo.sh

for code in us au ca fr uk sg jp cn de ph tr off status; do
  ln -sfn /usr/local/bin/geo "/usr/local/bin/geo${code}"
done

if [ ! -f /etc/geo/proxies.tsv ]; then
  if [ -f "$TMP/proxies.example.tsv" ]; then
    install -m 600 "$TMP/proxies.example.tsv" /etc/geo/proxies.tsv
  fi
  echo "已放好空的账号表 /etc/geo/proxies.tsv，填上端口、用户名、密码后再用 geouk。"
fi

if ! grep -q '/etc/profile.d/geo.sh' /etc/profile 2>/dev/null; then
  printf '\nexport ENV=/etc/profile.d/geo.sh\n' >> /etc/profile
fi
if [ -f /root/.profile ] || [ "$(id -u)" -eq 0 ]; then
  touch /root/.profile
  if ! grep -q '/etc/profile.d/geo.sh' /root/.profile 2>/dev/null; then
    printf '\nexport ENV=/etc/profile.d/geo.sh\n' >> /root/.profile
  fi
fi

rm -rf "$TMP"
echo "安装完成。重新登录后可直接输入 geouk、geode、geooff。"
