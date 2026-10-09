#!/bin/sh
# vps-geo: give a VPS a SOCKS5 exit IP and a one-word command (e.g. geous)
# to switch to it. Plain POSIX sh so busybox ash on a 64MB Alpine box works.
#
# Run once as root:  sh install.sh
# Afterwards:        geo            (menu)
#                    geous          (switch to the exit you named geous)
#                    geooff         (back to this machine's own IP)

# shellcheck disable=SC1007,SC1091,SC2015,SC2046,SC2154
GEO_VERSION=2.1.1
GLIDER_VERSION=0.16.4
REPO_RAW=${GEO_REPO_RAW:-https://raw.githubusercontent.com/imthnio/vps-geo/main}
# Prefix for GitHub downloads on machines that can't reach GitHub directly,
# e.g. GEO_GH_PROXY=https://ghfast.top/
GH_PROXY=${GEO_GH_PROXY:-}

ETC=/etc/geo
PROFILES=$ETC/profiles
ACTIVE=$ETC/active
GLIDER_CONF=$ETC/glider.conf
BIN=/usr/local/bin
SELF=$BIN/geo
GLIDER=$BIN/geo-glider
PIDFILE=/var/run/geo.pid
WATCH_PIDFILE=/var/run/geo-watch.pid
LOG=/var/log/geo.log
RUN_USER=geo
REDIR_PORT=61080
REDIR6_PORT=61081
CHAIN=GEO_OUT
UCHAIN=GEO_UDP
# glider port that taken-over nodes send their traffic to (compat mode)
COMPAT_PORT=61082
NODE_TAG=geo-out
# port mode picks its local port from this range by itself
AUTO_PORT_MIN=1080
AUTO_PORT_MAX=1199

# ---------------------------------------------------------------- output

if [ -t 1 ]; then
  C_R=$(printf '\033[31m') C_G=$(printf '\033[32m') C_Y=$(printf '\033[33m')
  C_B=$(printf '\033[36m') C_0=$(printf '\033[0m')
else
  C_R= C_G= C_Y= C_B= C_0=
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s[✗]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }
title() { printf '\n%s==== %s ====%s\n' "$C_B" "$*" "$C_0"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ask VAR "prompt" [default]
# Reads from the terminal even when the script itself came through a pipe.
# GEO_ASK_<VAR> in the environment answers the question without a terminal.
ask() {
  _var=$1 _prompt=$2 _def=${3:-}
  eval "_preset=\${GEO_ASK_$_var:-}"
  if [ -n "$_preset" ]; then
    eval "$_var=\$_preset"
    return 0
  fi
  if [ -n "$_def" ]; then
    printf '%s %s[%s]%s: ' "$_prompt" "$C_B" "$_def" "$C_0" >&2
  else
    printf '%s: ' "$_prompt" >&2
  fi
  _ans=
  if ! read -r _ans 2>/dev/null </dev/tty; then
    [ -n "$_def" ] || die "没有可交互的终端，无法提问。请在 SSH 里直接运行。"
    printf '\n' >&2
  fi
  _ans=$(printf '%s' "$_ans" | tr -d '\r')
  [ -n "$_ans" ] || _ans=$_def
  eval "$_var=\$_ans"
}

# confirm "question" [y|n]  -> returns 0 for yes
confirm() {
  _d=${2:-y}
  if [ "$_d" = y ]; then ask _yn "$1 (Y/n)" y; else ask _yn "$1 (y/N)" n; fi
  case $_yn in [Yy]*|是) return 0 ;; *) return 1 ;; esac
}

country_name() {
  case $(printf '%s' "$1" | tr '[:lower:]' '[:upper:]') in
    US) echo 美国 ;; GB|UK) echo 英国 ;; JP) echo 日本 ;; SG) echo 新加坡 ;;
    HK) echo 香港 ;; TW) echo 台湾 ;; KR) echo 韩国 ;; CN) echo 中国 ;;
    DE) echo 德国 ;; FR) echo 法国 ;; NL) echo 荷兰 ;; CA) echo 加拿大 ;;
    AU) echo 澳大利亚 ;; PH) echo 菲律宾 ;; TR) echo 土耳其 ;; RU) echo 俄罗斯 ;;
    IN) echo 印度 ;; VN) echo 越南 ;; TH) echo 泰国 ;; MY) echo 马来西亚 ;;
    ID) echo 印度尼西亚 ;; BR) echo 巴西 ;; IT) echo 意大利 ;; ES) echo 西班牙 ;;
    *) echo "$1" ;;
  esac
}

# ---------------------------------------------------------------- machine detection

# Sets VIRT (none/kvm/xen/vmware/lxc/openvz/docker/...) and ROLE (母鸡/小鸡).
detect_virt() {
  VIRT=
  if have systemd-detect-virt; then
    VIRT=$(systemd-detect-virt 2>/dev/null)
    [ -n "$VIRT" ] || VIRT=none
  fi
  if [ -z "$VIRT" ]; then
    if [ -d /proc/vz ] && [ ! -d /proc/bc ]; then
      VIRT=openvz
    elif [ -f /.dockerenv ]; then
      VIRT=docker
    elif [ -f /run/.containerenv ]; then
      VIRT=podman
    elif tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -q '^container=lxc'; then
      VIRT=lxc
    elif grep -qs 'lxcfs /proc' /proc/self/mounts; then
      VIRT=lxc
    elif grep -qsi microsoft /proc/version; then
      VIRT=wsl
    fi
  fi
  if [ -z "$VIRT" ]; then
    dmi=$(cat /sys/class/dmi/id/product_name /sys/class/dmi/id/sys_vendor \
      /sys/class/dmi/id/board_vendor 2>/dev/null | tr '\n' ' ')
    case $dmi in
      *KVM*|*QEMU*) VIRT=kvm ;;
      *VMware*) VIRT=vmware ;;
      *VirtualBox*|*innotek*) VIRT=oracle ;;
      *Microsoft*) VIRT=microsoft ;;
      *Xen*|*HVM\ domU*) VIRT=xen ;;
      *Amazon\ EC2*) VIRT=amazon ;;
      *Google*) VIRT=google ;;
      *Alibaba*) VIRT=alibaba ;;
      *Bochs*) VIRT=bochs ;;
      *Parallels*) VIRT=parallels ;;
    esac
  fi
  if [ -z "$VIRT" ] && [ -r /sys/hypervisor/type ]; then
    VIRT=$(cat /sys/hypervisor/type)
  fi
  if [ -z "$VIRT" ] && grep -qs '^flags.* hypervisor' /proc/cpuinfo; then
    VIRT=vm
  fi
  [ -n "$VIRT" ] || VIRT=none

  case $VIRT in
    openvz|lxc|lxc-libvirt|docker|podman|systemd-nspawn|wsl|proot|rkt|container-other)
      VIRT_KIND=container ;;
    none) VIRT_KIND=none ;;
    *) VIRT_KIND=vm ;;
  esac

  # Is this box itself hosting guests?
  HOSTING=
  if [ -d /proc/bc ]; then HOSTING="OpenVZ"; fi
  if have pveversion; then HOSTING="${HOSTING:+$HOSTING, }Proxmox VE"; fi
  if have virsh || have libvirtd; then HOSTING="${HOSTING:+$HOSTING, }libvirt/KVM"; fi
  if have incus || have lxd; then HOSTING="${HOSTING:+$HOSTING, }LXD/Incus"; fi

  if [ "$VIRT_KIND" = none ]; then
    ROLE=母鸡
  else
    ROLE=小鸡
  fi
}

detect_system() {
  OS_NAME=$( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$ID}") )
  [ -n "$OS_NAME" ] || OS_NAME=$(uname -s)
  ARCH=$(uname -m)
  KERNEL=$(uname -r)
  CPU_CORES=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
  [ -n "$CPU_CORES" ] && [ "$CPU_CORES" -gt 0 ] || CPU_CORES=1
  CPU_MODEL=$(awk -F: '/^model name|^Hardware|^cpu model/ {sub(/^[ \t]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null)
  MEM_MB=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
  MEM_AVAIL_MB=$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
  SWAP_MB=$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
  : "${MEM_MB:=0}" "${MEM_AVAIL_MB:=$MEM_MB}" "${SWAP_MB:=0}"
  DISK_FREE_MB=$(df -Pk / 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024}')
  DISK_TOTAL_MB=$(df -Pk / 2>/dev/null | awk 'NR==2 {printf "%d", $2/1024}')
  : "${DISK_FREE_MB:=0}" "${DISK_TOTAL_MB:=0}"

  if [ -d /run/systemd/system ] && have systemctl; then
    INIT=systemd
  elif have openrc-run || have rc-service; then
    INIT=openrc
  else
    INIT=none
  fi

  if have apk; then PKG=apk
  elif have apt-get; then PKG=apt
  elif have dnf; then PKG=dnf
  elif have yum; then PKG=yum
  elif have pacman; then PKG=pacman
  elif have zypper; then PKG=zypper
  else PKG=none
  fi

  # Small boxes: keep the Go runtime on a tight leash.
  if [ "$MEM_MB" -gt 0 ] && [ "$MEM_MB" -le 160 ]; then
    LOWMEM=1
  else
    LOWMEM=0
  fi
}

# Find an iptables that can do NAT here. Old kernels (OpenVZ 7 is 3.10)
# have no nf_tables, so the default nft-based iptables fails there while
# iptables-legacy works. Sets IPT and IP6T.
pick_ipt() {
  IPT= IP6T=
  if have modprobe; then
    modprobe -q iptable_nat 2>/dev/null
    modprobe -q xt_REDIRECT 2>/dev/null
  fi
  for c in iptables iptables-legacy iptables-nft; do
    have $c || continue
    $c -t nat -N GEO_TEST >/dev/null 2>&1 || continue
    if $c -t nat -A GEO_TEST -p tcp -j REDIRECT --to-ports 1 >/dev/null 2>&1; then
      $c -t nat -F GEO_TEST >/dev/null 2>&1
      $c -t nat -X GEO_TEST >/dev/null 2>&1
      IPT=$c
      IP6T=ip6${c#ip}
      have "$IP6T" || IP6T=
      return 0
    fi
    $c -t nat -F GEO_TEST >/dev/null 2>&1
    $c -t nat -X GEO_TEST >/dev/null 2>&1
  done
  return 1
}

# The iptables chosen at activation (used again at boot).
load_ipt() {
  IPT=$(cat "$ETC/ipt" 2>/dev/null)
  if [ -n "$IPT" ] && have "$IPT"; then
    IP6T=ip6${IPT#ip}
    have "$IP6T" || IP6T=
    return 0
  fi
  pick_ipt
}

has_v6() {
  # scope 00 = global address
  awk '$4 == "00" && $6 != "lo" {f=1} END {exit !f}' /proc/net/if_inet6 2>/dev/null
}

print_machine() {
  title "本机信息"
  case $VIRT_KIND in
    none) role_txt="${C_G}母鸡${C_0}（独立服务器 / 物理机，没有检测到虚拟化）" ;;
    container) role_txt="${C_G}小鸡${C_0}（容器型：$VIRT）" ;;
    *) role_txt="${C_G}小鸡${C_0}（虚拟机：$VIRT）" ;;
  esac
  say "机器类型 : $role_txt"
  [ -n "$HOSTING" ] && say "虚拟化平台: 本机装有 $HOSTING，下面可能挂着小鸡"
  say "系统     : $OS_NAME（内核 $KERNEL）"
  say "架构     : $ARCH"
  say "CPU      : ${CPU_CORES} 核${CPU_MODEL:+  $CPU_MODEL}"
  say "内存     : ${MEM_MB}MB（可用 ${MEM_AVAIL_MB}MB，Swap ${SWAP_MB}MB）"
  say "硬盘     : 共 ${DISK_TOTAL_MB}MB，剩余 ${DISK_FREE_MB}MB"
  say "服务管理 : $INIT    包管理: $PKG"
  if [ "$LOWMEM" = 1 ]; then
    say "小内存   : 是，已启用省内存模式（代理程序常驻约 10MB）"
  fi
  if has_v6; then say "IPv6     : 有公网 IPv6"; else say "IPv6     : 无"; fi
}

# ---------------------------------------------------------------- packages & downloads

pkg_install() {
  case $PKG in
    apk) apk add --no-cache "$@" ;;
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ||
         { apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; } ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    zypper) zypper -n install "$@" ;;
    *) return 1 ;;
  esac
}

download() { # url out
  if have curl; then
    curl -fL --retry 2 --connect-timeout 15 -sS -o "$2" "$1"
  elif have wget; then
    wget -q -T 30 -O "$2" "$1"
  else
    return 1
  fi
}

ensure_base_deps() {
  missing=
  have curl || missing="$missing curl"
  [ -s /etc/ssl/certs/ca-certificates.crt ] || [ -d /etc/pki/tls ] || missing="$missing ca-certificates"
  have tar || missing="$missing tar"
  have gzip || missing="$missing gzip"
  [ -n "$missing" ] || return 0
  say "安装依赖:$missing"
  # shellcheck disable=SC2086
  pkg_install $missing >/dev/null 2>&1 || true
  have curl || die "装不上 curl，请手动安装后再运行。"
}

ensure_iptables() {
  if ! have iptables && ! have iptables-legacy; then
    say "整机模式需要 iptables，正在安装..."
    pkg_install iptables >/dev/null 2>&1 || true
  fi
  if [ "$PKG" = apt ] || [ "$PKG" = dnf ] || [ "$PKG" = yum ]; then
    have ip6tables || pkg_install ip6tables >/dev/null 2>&1 || true
  fi
  have iptables || have iptables-legacy
}

# Alpine ships the nft flavour by default; old 小鸡 kernels need legacy.
ensure_iptables_legacy() {
  have iptables-legacy && return 1
  case $PKG in
    apk) pkg_install iptables-legacy >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
  have iptables-legacy
}

glider_arch() {
  case $ARCH in
    x86_64|amd64) echo amd64 ;;
    armv7*|armv8l) echo armv7 ;;
    aarch64|arm64|armv8*) echo arm64 ;;
    armv6*|armv5*) echo armv6 ;;
    i?86|x86) echo 386 ;;
    riscv64) echo riscv64 ;;
    mips64el|mips64le) echo mips64le_softfloat ;;
    mips64) echo mips64_softfloat ;;
    mipsel|mipsle) echo mipsle_softfloat ;;
    mips) echo mips_softfloat ;;
    *) return 1 ;;
  esac
}

install_glider() {
  if [ -x "$GLIDER" ] && "$GLIDER" -h 2>&1 | grep -q "glider $GLIDER_VERSION"; then
    return 0
  fi
  ga=$(glider_arch) || die "暂不支持这个 CPU 架构: $ARCH"
  [ "$DISK_FREE_MB" -ge 20 ] || [ "$DISK_FREE_MB" -eq 0 ] ||
    die "硬盘剩余不足 20MB（现在 ${DISK_FREE_MB}MB），请先清理一下。"

  name=glider_${GLIDER_VERSION}_linux_${ga}
  base="${GH_PROXY}https://github.com/nadoo/glider/releases/download/v${GLIDER_VERSION}"
  # Download to disk, not /tmp: /tmp is RAM on many small boxes.
  dl=$ETC/.download
  rm -rf "$dl"
  mkdir -p "$dl"
  say "下载代理核心 glider v$GLIDER_VERSION ($ga)..."
  if ! download "$base/$name.tar.gz" "$dl/g.tgz"; then
    rm -rf "$dl"
    die "下载失败。机器连不上 GitHub 的话，可以这样运行：GEO_GH_PROXY=https://ghfast.top/ sh install.sh"
  fi
  if download "$base/glider_${GLIDER_VERSION}_checksums.txt" "$dl/sums" && have sha256sum; then
    want=$(awk -v f="$name.tar.gz" '$2 == f {print $1}' "$dl/sums")
    got=$(sha256sum "$dl/g.tgz" | awk '{print $1}')
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
      rm -rf "$dl"
      die "glider 校验失败，文件可能被篡改或没下完整，请重试。"
    fi
  fi
  (cd "$dl" && tar -xzf g.tgz "$name/glider") || { rm -rf "$dl"; die "解压失败。"; }
  mv "$dl/$name/glider" "$GLIDER.new" && chmod 755 "$GLIDER.new" && mv "$GLIDER.new" "$GLIDER"
  rm -rf "$dl"
  "$GLIDER" -h >/dev/null 2>&1 || die "glider 无法在这台机器上运行。"
  ok "glider 已安装"
}

ensure_user() {
  id "$RUN_USER" >/dev/null 2>&1 && return 0
  if have useradd; then
    useradd -r -M -s /sbin/nologin "$RUN_USER" >/dev/null 2>&1 ||
      useradd -r -M -s /usr/sbin/nologin "$RUN_USER" >/dev/null 2>&1
  elif have adduser; then
    adduser -S -D -H -s /sbin/nologin "$RUN_USER" >/dev/null 2>&1 ||
      adduser --system --no-create-home "$RUN_USER" >/dev/null 2>&1
  fi
  id "$RUN_USER" >/dev/null 2>&1
}

install_self() {
  mkdir -p "$PROFILES" "$BIN"
  # glider runs as $RUN_USER and must reach glider.conf; profiles stay root-only.
  chmod 711 "$ETC"
  chmod 700 "$PROFILES"
  src=$0
  case $src in */*) ;; *) src=$(command -v "$src" 2>/dev/null || echo "$src") ;; esac
  if [ -f "$src" ] && grep -q 'GEO_VERSION=' "$src" 2>/dev/null; then
    [ "$src" = "$SELF" ] || cp "$src" "$SELF.new"
  else
    download "$REPO_RAW/install.sh" "$SELF.new" || die "下载脚本失败。"
  fi
  if [ -f "$SELF.new" ]; then
    chmod 755 "$SELF.new" && mv "$SELF.new" "$SELF"
  fi
  ln -sf "$SELF" "$BIN/geooff"
  # Re-create shortcut links for existing exits (after an update).
  for f in "$PROFILES"/*.conf; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .conf)
    ln -sf "$SELF" "$BIN/$n"
  done
  migrate_v1
}

# The first version used shell functions in /etc/profile.d and env vars.
migrate_v1() {
  [ -f /etc/profile.d/geo.sh ] || [ -f "$ETC/current.sh" ] || return 0
  rm -f /etc/profile.d/geo.sh "$ETC/current.sh"
  for f in /etc/profile /root/.profile; do
    [ -f "$f" ] && grep -q 'ENV=/etc/profile.d/geo.sh' "$f" &&
      sed -i '/ENV=\/etc\/profile.d\/geo.sh/d' "$f"
  done
  for c in us au ca fr uk sg jp cn de ph tr status; do
    [ -f "$PROFILES/geo$c.conf" ] || rm -f "$BIN/geo$c"
  done
  warn "已清理旧版的环境变量方式。旧账号表 $ETC/proxies.tsv 保留未删，可以对照它用 geo 菜单重新添加。"
}

# ---------------------------------------------------------------- proxy URL handling

urlenc() {
  case $1 in *%*) printf '%s' "$1"; return ;; esac  # already encoded
  _s=$1 _o=
  while [ -n "$_s" ]; do
    _c=${_s%"${_s#?}"}
    _s=${_s#?}
    case $_c in
      [A-Za-z0-9._~-]) _o=$_o$_c ;;
      *) _o=$_o$(printf '%%%02X' "'$_c") ;;
    esac
  done
  printf '%s' "$_o"
}

# parse_proxy STRING -> P_HOST P_PORT P_USER P_PASS, P_URL (socks5://...)
# Accepts socks5://u:p@h:port, socks5h://..., u:p@h:port, h:port, h:port:u:p
parse_proxy() {
  s=$(printf '%s' "$1" | tr -d ' \t\r')
  P_USER= P_PASS= P_HOST= P_PORT=
  case $s in
    socks5://*|socks5h://*|socks://*) s=${s#*://} ;;
    *://*) return 1 ;;
  esac
  s=${s%/}
  case $s in
    *@*)
      cred=${s%@*}
      hp=${s##*@}
      case $cred in
        *:*) P_USER=${cred%%:*} P_PASS=${cred#*:} ;;
        *) P_USER=$cred ;;
      esac
      ;;
    \[*)
      hp=$s ;;
    *)
      _old=$IFS
      IFS=:
      # shellcheck disable=SC2086
      set -- $s
      IFS=$_old
      case $# in
        2) hp=$1:$2 ;;
        4) hp=$1:$2 P_USER=$3 P_PASS=$4 ;;
        *) return 1 ;;
      esac
      ;;
  esac
  P_HOST=${hp%:*}
  P_PORT=${hp##*:}
  [ -n "$P_HOST" ] && [ "$P_HOST" != "$hp" ] || return 1
  case $P_PORT in ''|*[!0-9]*) return 1 ;; esac
  [ "$P_PORT" -ge 1 ] && [ "$P_PORT" -le 65535 ] || return 1
  if [ -n "$P_USER" ]; then
    P_URL="socks5://$(urlenc "$P_USER"):$(urlenc "$P_PASS")@$P_HOST:$P_PORT"
  else
    P_URL="socks5://$P_HOST:$P_PORT"
  fi
  return 0
}

# Mask the password when showing a proxy URL.
mask_url() {
  printf '%s' "$1" | sed 's#^\(socks5://[^:@/]*:\)[^@]*@#\1****@#'
}

proxy_host() {
  _hp=${1##*@}
  _hp=${_hp#socks5://}
  printf '%s' "${_hp%:*}" | tr -d '[]'
}

# All addresses the proxy host resolves to (v4 and v6), one per line.
resolve_host() {
  h=$1
  case $h in
    *[!0-9.]*) ;;
    *) echo "$h"; return ;;
  esac
  case $h in *:*) echo "$h"; return ;; esac
  {
    if have getent; then
      getent ahosts "$h" 2>/dev/null | awk '{print $1}'
      getent hosts "$h" 2>/dev/null | awk '{print $1}'
    fi
    if have nslookup; then
      nslookup "$h" 2>/dev/null | awk '/^Name:/ {f=1; next}
        f && /^Address/ {for (i = 2; i <= NF; i++) if ($i ~ /^[0-9a-fA-F.:]+$/) print $i}'
    fi
  } | grep -E '^[0-9a-fA-F.:]+$' | grep '[.:]' | sort -u
}

# ---------------------------------------------------------------- IP check

json_get() { # json key
  printf '%s' "$1" | tr -d '\n' | sed -n "s/.*\"$2\" *: *\"\([^\"]*\)\".*/\1/p"
}

# check_ip [curl args...] -> sets IP_ADDR IP_CC IP_CITY IP_ORG; 1 on failure
check_ip() {
  IP_ADDR= IP_CC= IP_CITY= IP_ORG=
  body=$(env -u ALL_PROXY -u all_proxy -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    curl -fsS --connect-timeout 10 --max-time 20 "$@" https://ipinfo.io/json 2>/dev/null)
  if [ -n "$body" ]; then
    IP_ADDR=$(json_get "$body" ip)
    IP_CC=$(json_get "$body" country)
    IP_CITY=$(json_get "$body" city)
    IP_ORG=$(json_get "$body" org)
  fi
  if [ -z "$IP_ADDR" ]; then
    body=$(env -u ALL_PROXY -u all_proxy -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
      curl -fsS --connect-timeout 10 --max-time 20 "$@" https://api.ip.sb/geoip 2>/dev/null)
    [ -n "$body" ] || return 1
    IP_ADDR=$(json_get "$body" ip)
    IP_CC=$(json_get "$body" country_code)
    IP_CITY=$(json_get "$body" city)
    IP_ORG=$(json_get "$body" organization)
  fi
  [ -n "$IP_ADDR" ]
}

print_ip() {
  say "  出口 IP : $C_G$IP_ADDR$C_0"
  [ -n "$IP_CC" ] && say "  国家    : $(country_name "$IP_CC") ($IP_CC)"
  [ -n "$IP_CITY" ] && say "  城市    : $IP_CITY"
  [ -n "$IP_ORG" ] && say "  网络    : $IP_ORG"
  return 0
}

# ---------------------------------------------------------------- profiles

valid_name() {
  case $1 in
    geo|geooff|geo-glider|install.sh) return 1 ;;
  esac
  printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9_-]{1,31}$'
}

load_profile() { # name
  [ -f "$PROFILES/$1.conf" ] || return 1
  PROXY= MODE= PORT=
  # shellcheck disable=SC1090
  . "$PROFILES/$1.conf"
  NAME=$1
}

save_profile() { # name proxy mode port
  umask 077
  cat >"$PROFILES/$1.conf" <<EOF
PROXY='$2'
MODE=$3
PORT=$4
EOF
  ln -sf "$SELF" "$BIN/$1"
}

list_profiles() {
  for f in "$PROFILES"/*.conf; do
    [ -f "$f" ] && basename "$f" .conf
  done
}

mode_text() {
  if [ "$1" = all ]; then echo "整机"; else echo "端口 127.0.0.1:$2"; fi
}

active_name() {
  [ -f "$ACTIVE" ] && cat "$ACTIVE"
}

port_in_use() {
  hex=$(printf ':%04X' "$1")
  cat /proc/net/tcp /proc/net/tcp6 2>/dev/null |
    awk -v p="$hex" '$4 == "0A" && substr($2, length($2) - 4) == p {f=1} END {exit !f}'
}

# ---------------------------------------------------------------- state

# off / nat (whole machine via iptables) / compat (whole machine via node
# takeover, for boxes that can't do NAT) / port
cur_state() {
  _cs=$(active_name)
  if [ -z "$_cs" ] || [ ! -f "$PROFILES/$_cs.conf" ]; then
    echo off
  elif [ "$(sed -n 's/^MODE=//p' "$PROFILES/$_cs.conf")" = port ]; then
    echo port
  elif [ "$(cat "$ETC/backend" 2>/dev/null)" = nat ]; then
    echo nat
  else
    echo compat
  fi
}

# ---------------------------------------------------------------- firewall (whole-machine mode)

V4_PRIVATE="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4"
V6_PRIVATE="::1/128 fc00::/7 fe80::/10 ff00::/8"

fw_down() {
  for t in iptables iptables-legacy iptables-nft ip6tables ip6tables-legacy ip6tables-nft; do
    have $t || continue
    while $t -t nat -D OUTPUT -p tcp -j $CHAIN >/dev/null 2>&1; do :; done
    $t -t nat -F $CHAIN >/dev/null 2>&1
    $t -t nat -X $CHAIN >/dev/null 2>&1
    while $t -D OUTPUT -p tcp -j $CHAIN >/dev/null 2>&1; do :; done
    while $t -D OUTPUT -p udp -j $UCHAIN >/dev/null 2>&1; do :; done
    for c in $CHAIN $UCHAIN; do
      $t -F "$c" >/dev/null 2>&1
      $t -X "$c" >/dev/null 2>&1
    done
  done
}

# Refuse new outbound UDP (QUIC and the like) so it can't leave with this
# machine's own IP; programs then fall back to TCP, which is proxied.
# Replies to inbound UDP (hysteria2/tuic nodes) are not new and still pass.
fw_udp() { # iptables-command private-nets...
  _t=$1
  shift
  $_t -N $UCHAIN >/dev/null 2>&1 || return 1
  for n in "$@"; do $_t -A $UCHAIN -d "$n" -j RETURN; done
  $_t -A $UCHAIN -m addrtype --dst-type LOCAL -j RETURN >/dev/null 2>&1
  [ "$owner" = 1 ] && $_t -A $UCHAIN -m owner --uid-owner "$RUN_USER" -j RETURN >/dev/null 2>&1
  for p in 53 67 68 123 546 547; do $_t -A $UCHAIN -p udp --dport $p -j RETURN; done
  if $_t -A $UCHAIN -p udp -m conntrack --ctstate NEW -j REJECT >/dev/null 2>&1 ||
    $_t -A $UCHAIN -p udp -m state --state NEW -j REJECT >/dev/null 2>&1; then
    $_t -A OUTPUT -p udp -j $UCHAIN >/dev/null 2>&1 && return 0
  fi
  $_t -F $UCHAIN >/dev/null 2>&1
  $_t -X $UCHAIN >/dev/null 2>&1
  return 1
}

# Send all locally started TCP connections to glider's redir listener,
# except traffic to private ranges, to this machine, and glider's own
# connections to the upstream proxy (matched by user and by address).
fw_up() {
  [ "$(cur_state)" = nat ] || { fw_down; return 0; }
  load_profile "$(active_name)" || return 1
  load_ipt || return 1
  fw_down
  ips=$(resolve_host "$(proxy_host "$PROXY")")
  owner=0
  $IPT -t nat -N $CHAIN || return 1
  for n in $V4_PRIVATE; do
    $IPT -t nat -A $CHAIN -d "$n" -j RETURN
  done
  $IPT -t nat -A $CHAIN -m addrtype --dst-type LOCAL -j RETURN >/dev/null 2>&1
  for ip in $ips; do
    case $ip in *:*) continue ;; esac
    $IPT -t nat -A $CHAIN -d "$ip" -j RETURN
  done
  if id "$RUN_USER" >/dev/null 2>&1 &&
    $IPT -t nat -A $CHAIN -m owner --uid-owner "$RUN_USER" -j RETURN >/dev/null 2>&1; then
    owner=1
  fi
  if [ "$owner" = 0 ] && [ -z "$ips" ]; then
    fw_down
    err "解析不到代理服务器地址，系统也不支持按用户排除流量，整机模式无法安全开启。"
    return 1
  fi
  $IPT -t nat -A $CHAIN -p tcp -j REDIRECT --to-ports $REDIR_PORT || { fw_down; return 1; }
  $IPT -t nat -A OUTPUT -p tcp -j $CHAIN || { fw_down; return 1; }
  # shellcheck disable=SC2086
  fw_udp "$IPT" $V4_PRIVATE || warn "这台机器没法拦截 UDP，节点的 UDP 流量（如 QUIC）可能用本机 IP 出去。"

  # IPv6: proxy it if the kernel allows, otherwise refuse it so programs
  # fall back to IPv4 instead of leaking the real address.
  if has_v6 && [ -n "$IP6T" ]; then
    if [ "$(cat $ETC/v6 2>/dev/null)" = redir ] && $IP6T -t nat -N $CHAIN >/dev/null 2>&1; then
      t="$IP6T -t nat"
      last="-j REDIRECT --to-ports $REDIR6_PORT"
    elif $IP6T -N $CHAIN >/dev/null 2>&1; then
      t=$IP6T
      last="-j REJECT --reject-with tcp-reset"
    else
      warn "无法接管 IPv6，访问 IPv6 网站时会露出本机 IP。"
      return 0
    fi
    for n in $V6_PRIVATE; do
      $t -A $CHAIN -d "$n" -j RETURN
    done
    $t -A $CHAIN -m addrtype --dst-type LOCAL -j RETURN >/dev/null 2>&1
    for ip in $ips; do
      case $ip in *:*) $t -A $CHAIN -d "$ip" -j RETURN ;; esac
    done
    [ "$owner" = 1 ] && $t -A $CHAIN -m owner --uid-owner "$RUN_USER" -j RETURN >/dev/null 2>&1
    # shellcheck disable=SC2086
    $t -A $CHAIN -p tcp $last >/dev/null 2>&1 && $t -A OUTPUT -p tcp -j $CHAIN >/dev/null 2>&1 ||
      warn "IPv6 规则设置失败，访问 IPv6 网站时会露出本机 IP。"
    # shellcheck disable=SC2086
    fw_udp "$IP6T" $V6_PRIVATE >/dev/null 2>&1
  fi
  return 0
}

# Decide once per activation whether IPv6 gets redirected (needs ip6tables nat).
probe_v6() {
  v6=none
  if has_v6 && [ -n "$IP6T" ] && $IP6T -t nat -N GEO_TEST >/dev/null 2>&1; then
    $IP6T -t nat -X GEO_TEST >/dev/null 2>&1
    v6=redir
  fi
  echo $v6 >$ETC/v6
}

# ---------------------------------------------------------------- node takeover (compat mode)
#
# When the box can't redirect traffic (no NAT in many OpenVZ/LXC guests),
# point the proxy nodes' own outbound at glider instead. glider keeps
# listening on COMPAT_PORT, so switching exits never touches node configs.

# Well-known config locations, used when the node isn't running right now.
NODE_CONFS="/etc/sing-box/config.json /usr/local/etc/sing-box/config.json
/etc/xray/config.json /usr/local/etc/xray/config.json
/etc/v2ray/config.json /usr/local/etc/v2ray/config.json
/etc/hysteria/config.yaml /etc/hysteria/config.yml"
# Configs found from running processes are remembered here ("config|binary").
NODE_LIST=$ETC/nodes

node_is_proxy_bin() {
  case ${1##*/} in
    xray*|v2ray*|sing-box*|singbox*|sb|hysteria*|hy2*) return 0 ;;
  esac
  return 1
}

# The config file a process was started with ("" if it can't be told).
node_proc_conf() { # /proc/PID
  _pc=$(tr '\0' '\n' <"$1/cmdline" 2>/dev/null | awk '
    p {print; exit}
    /^(-c|-config|--config|-C|-confdir|--config-directory)$/ {p = 1; next}
    /^-+(c|config)=/ {sub(/^[^=]*=/, ""); print; exit}')
  [ -n "$_pc" ] || return 1
  case $_pc in
    /*) ;;
    *) _pc=$(readlink "$1/cwd" 2>/dev/null)/$_pc ;;
  esac
  if [ -d "$_pc" ]; then
    _pc=$(grep -l '"outbounds"' "$_pc"/*.json 2>/dev/null | head -n 1)
  fi
  [ -f "$_pc" ] && echo "$_pc"
}

# Nodes running right now, whatever script installed them: "config|binary".
node_discover() {
  for _d in /proc/[0-9]*; do
    _exe=$(readlink "$_d/exe" 2>/dev/null) || continue
    _exe=${_exe% (deleted)}
    node_is_proxy_bin "$_exe" || continue
    _cfg=$(node_proc_conf "$_d") || continue
    echo "$_cfg|$_exe"
  done
}

# Every node config we know about, running ones first.
node_all() {
  {
    node_discover
    cat "$NODE_LIST" 2>/dev/null
    for _c in $NODE_CONFS; do echo "$_c|"; done
  } | awk -F'|' '$1 != "" && !seen[$1]++'
}

node_pid() { # config
  for _d in /proc/[0-9]*; do
    _exe=$(readlink "$_d/exe" 2>/dev/null) || continue
    node_is_proxy_bin "${_exe% (deleted)}" || continue
    [ "$(node_proc_conf "$_d")" = "$1" ] && { echo "${_d#/proc/}"; return 0; }
  done
  return 1
}

# Tell the config dialect from its content, not from where it lives.
node_kind() {
  case $1 in
    *.yaml|*.yml) grep -qs '^listen:' "$1" && echo hysteria; return ;;
  esac
  if grep -qs '"listen_port"\|"server_port"' "$1"; then
    echo sing-box
  elif grep -qs '"protocol"' "$1"; then
    echo xray
  fi
}

ensure_jq() {
  have jq && return 0
  pkg_install jq >/dev/null 2>&1
  have jq
}

node_bin() { # name
  for _b in "$(command -v "$1" 2>/dev/null)" /usr/local/bin/"$1" /usr/bin/"$1" /etc/"$1"/"$1"; do
    [ -n "$_b" ] && [ -x "$_b" ] && { echo "$_b"; return 0; }
  done
  return 1
}

node_test() { # kind file binary
  _b=$3
  [ -n "$_b" ] && [ -x "$_b" ] || _b=$(node_bin "$1") || return 0
  case $1 in
    sing-box) "$_b" check -c "$2" >/dev/null 2>&1 ;;
    xray) "$_b" run -test -c "$2" >/dev/null 2>&1 || "$_b" -test -config "$2" >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

# Restart whatever runs this config: its service if it has one, else the
# process itself.
node_restart() { # config kind
  _pid=$(node_pid "$1")
  if [ -n "$_pid" ] && [ "$INIT" = systemd ]; then
    _u=$(sed -n 's#.*/\([^/]*\.service\)$#\1#p' "/proc/$_pid/cgroup" 2>/dev/null | head -n 1)
    [ -n "$_u" ] && systemctl restart "$_u" >/dev/null 2>&1 && return 0
  fi
  if [ -n "$_pid" ] && [ "$INIT" = openrc ]; then
    _pp=$(awk '/^PPid:/ {print $2}' "/proc/$_pid/status" 2>/dev/null)
    for _pf in /run/*.pid /run/*/*.pid; do
      [ -f "$_pf" ] || continue
      _v=$(cat "$_pf" 2>/dev/null)
      [ "$_v" = "$_pid" ] || [ "$_v" = "$_pp" ] || continue
      _s=$(basename "$_pf" .pid)
      [ -f "/etc/init.d/$_s" ] && rc-service "$_s" restart >/dev/null 2>&1 && return 0
    done
    _s=$(tr '\0' ' ' <"/proc/$_pp/cmdline" 2>/dev/null | sed -n 's/^supervise-daemon \([^ ]*\) .*/\1/p')
    [ -n "$_s" ] && [ -f "/etc/init.d/$_s" ] && rc-service "$_s" restart >/dev/null 2>&1 && return 0
  fi
  case $2 in
    sing-box) _svcs="sing-box sb singbox" ;;
    xray) _svcs="xray v2ray" ;;
    hysteria) _svcs="hysteria-server hysteria hysteria2 hy2" ;;
    *) _svcs= ;;
  esac
  for _s in $_svcs; do
    case $INIT in
      systemd)
        systemctl cat "$_s" >/dev/null 2>&1 || continue
        systemctl restart "$_s" >/dev/null 2>&1 && return 0 ;;
      openrc)
        [ -f "/etc/init.d/$_s" ] || continue
        rc-service "$_s" restart >/dev/null 2>&1 && return 0 ;;
    esac
  done
  # No service owns it: stop the process and start the same command again
  # (unless something respawns it first).
  [ -n "$_pid" ] || return 1
  cp "/proc/$_pid/cmdline" "$ETC/.cmdline" 2>/dev/null || return 1
  _cwd=$(readlink "/proc/$_pid/cwd" 2>/dev/null)
  kill "$_pid" 2>/dev/null
  sleep 3
  if ! node_pid "$1" >/dev/null; then
    (cd "${_cwd:-/}" 2>/dev/null && xargs -0 sh -c 'nohup "$@" >/dev/null 2>&1 &' sh <"$ETC/.cmdline")
    sleep 1
  fi
  rm -f "$ETC/.cmdline"
  node_pid "$1" >/dev/null
}

# Configs that failed once are skipped until their content changes.
node_skipped() { # file
  _sk=$ETC/skip/$(printf '%s' "$1" | tr / _)
  [ -f "$_sk" ] && [ "$(cat "$_sk")" = "$(cksum <"$1")" ]
}

node_skip() { # file reason
  mkdir -p "$ETC/skip"
  cksum <"$1" >"$ETC/skip/$(printf '%s' "$1" | tr / _)"
  warn "没法自动接管 $1：$2"
}

node_inject() { # file [binary]
  _f=$1
  _nb=${2:-}
  grep -q "$NODE_TAG" "$_f" 2>/dev/null && return 0
  node_skipped "$_f" && return 1
  _k=$(node_kind "$_f")
  [ -n "$_k" ] || return 1
  mkdir -p "$ETC/backup"
  cp "$_f" "$ETC/backup/$(printf '%s' "$_f" | tr / _)"
  case $_k in
    hysteria)
      if grep -q '^outbounds:' "$_f"; then
        node_skip "$_f" "配置里已经有 outbounds，请手动添加 socks5 出站 127.0.0.1:$COMPAT_PORT"
        return 1
      fi
      printf '\n# %s: added by vps-geo\noutbounds:\n  - name: %s\n    type: socks5\n    socks5:\n      addr: 127.0.0.1:%s\n' \
        "$NODE_TAG" "$NODE_TAG" "$COMPAT_PORT" >>"$_f"
      ;;
    sing-box|xray)
      ensure_jq || { node_skip "$_f" "装不上 jq"; return 1; }
      if [ "$_k" = sing-box ]; then
        # Remember the original default outbound so uninstall can restore it.
        jq -r '.route.final // empty' "$_f" >"$ETC/backup/$(printf '%s' "$_f" | tr / _).final" 2>/dev/null
        jq --arg t "$NODE_TAG" --argjson p "$COMPAT_PORT" '
          .outbounds = ([{type: "socks", tag: $t, server: "127.0.0.1", server_port: $p, version: "5"}] + (.outbounds // []))
          | if .route.final then .route.final = $t else . end' "$_f" >"$_f.geo" 2>/dev/null
      else
        jq --arg t "$NODE_TAG" --argjson p "$COMPAT_PORT" '
          .outbounds = ([{tag: $t, protocol: "socks", settings: {servers: [{address: "127.0.0.1", port: $p}]}}] + (.outbounds // []))' \
          "$_f" >"$_f.geo" 2>/dev/null
      fi
      _jq=$?
      if [ "$_jq" -ne 0 ] || [ ! -s "$_f.geo" ]; then
        rm -f "$_f.geo"
        node_skip "$_f" "配置文件不是标准 JSON（可能带注释）"
        return 1
      fi
      # Write in place so the file keeps its owner and permissions.
      cat "$_f.geo" >"$_f"
      rm -f "$_f.geo"
      ;;
  esac
  if ! node_test "$_k" "$_f" "$_nb"; then
    cat "$ETC/backup/$(printf '%s' "$_f" | tr / _)" >"$_f"
    node_skip "$_f" "改完后 $_k 自检不通过，已还原"
    return 1
  fi
  grep -qsF "$_f|" "$NODE_LIST" || echo "$_f|$_nb" >>"$NODE_LIST"
  if node_restart "$_f" "$_k"; then
    ok "已接管 $_k 节点（$_f），它的出口会跟着 geo 切换。"
  else
    ok "已接管 $_k 节点（$_f）。没能自动重启它，请手动重启一次节点。"
  fi
  return 0
}

node_release() { # file
  _f=$1
  grep -q "$NODE_TAG" "$_f" 2>/dev/null || return 0
  _k=$(node_kind "$_f")
  case $_k in
    hysteria)
      # Drop our appended block and the blank line in front of it.
      awk -v m="# $NODE_TAG: added by vps-geo" '$0 == m {exit}
        $0 == "" {b = b "\n"; next} {printf "%s", b; b = ""; print}' "$_f" >"$_f.geo" &&
        [ -s "$_f.geo" ] && cat "$_f.geo" >"$_f"
      rm -f "$_f.geo"
      ;;
    *)
      ensure_jq || return 1
      _fin=$(cat "$ETC/backup/$(printf '%s' "$_f" | tr / _).final" 2>/dev/null)
      jq --arg t "$NODE_TAG" --arg fin "$_fin" '(.outbounds |= map(select(.tag != $t)))
        | if .route.final == $t then
            (if $fin == "" then del(.route.final) else .route.final = $fin end)
          else . end' "$_f" >"$_f.geo" 2>/dev/null &&
        [ -s "$_f.geo" ] && cat "$_f.geo" >"$_f"
      rm -f "$_f.geo"
      ;;
  esac
  node_restart "$_f" "$_k"
  say "已把 $_k 节点恢复成直连出站（$_f）。"
}

# Nodes whose config currently points at geo, as "kind(config)" words.
node_taken() {
  node_all >"$ETC/.nodes"
  while IFS='|' read -r _nf _nx; do
    grep -qs "$NODE_TAG" "$_nf" && printf ' %s(%s)' "$(node_kind "$_nf")" "$_nf"
  done <"$ETC/.nodes"
  rm -f "$ETC/.nodes"
}

# Take over every node found; NODES_TAKEN lists the ones now using geo.
node_scan() {
  NODES_TAKEN=
  mkdir "$ETC/.lock" 2>/dev/null || return 0
  node_all >"$ETC/.scan"
  while IFS='|' read -r _nf _nx; do
    [ -f "$_nf" ] || continue
    node_inject "$_nf" "$_nx" </dev/null
  done <"$ETC/.scan"
  rm -f "$ETC/.scan"
  rmdir "$ETC/.lock" 2>/dev/null
  NODES_TAKEN=$(node_taken)
}

node_release_all() {
  node_all >"$ETC/.scan"
  while IFS='|' read -r _nf _nx; do
    [ -f "$_nf" ] && node_release "$_nf" </dev/null
  done <"$ETC/.scan"
  rm -f "$ETC/.scan"
}

# Runs as a service in compat mode, so nodes installed later are taken over too.
node_watch() {
  rmdir "$ETC/.lock" 2>/dev/null
  while :; do
    [ -f "$ETC/compat" ] && node_scan >/dev/null 2>&1
    sleep 20
  done
}

# ---------------------------------------------------------------- service

write_glider_conf() {
  _wa=$(active_name)
  PROXY= MODE= PORT=
  [ -n "$_wa" ] && load_profile "$_wa"
  _st=$(cur_state)
  umask 077
  {
    [ -n "$PROXY" ] && echo "forward=$PROXY"
    echo "check=disable"
    echo "dialtimeout=10"
    if [ "$_st" = nat ]; then
      echo "listen=redir://127.0.0.1:$REDIR_PORT"
      [ "$(cat $ETC/v6 2>/dev/null)" = redir ] && echo "listen=redir6://[::1]:$REDIR6_PORT"
    fi
    [ "$_st" = port ] && echo "listen=mixed://127.0.0.1:$PORT"
    [ -f "$ETC/compat" ] && echo "listen=mixed://127.0.0.1:$COMPAT_PORT"
  } >"$GLIDER_CONF"
  id "$RUN_USER" >/dev/null 2>&1 && chown "$RUN_USER" "$GLIDER_CONF" 2>/dev/null
  chmod 600 "$GLIDER_CONF"
}

go_env() {
  if [ "$LOWMEM" = 1 ]; then
    echo "GOGC=30 GOMEMLIMIT=24MiB GOMAXPROCS=1"
  else
    echo "GOGC=100"
  fi
}

install_service() {
  user_line=
  id "$RUN_USER" >/dev/null 2>&1 && user_line="User=$RUN_USER"
  case $INIT in
    systemd)
      cat >/etc/systemd/system/geo.service <<EOF
[Unit]
Description=vps-geo exit IP switcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
$user_line
Environment=$(go_env)
ExecStart=$GLIDER -config $GLIDER_CONF
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
      cat >/etc/systemd/system/geo-fw.service <<EOF
[Unit]
Description=vps-geo firewall rules for whole-machine mode
After=geo.service network-online.target
Requires=geo.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF fw-up
ExecStop=$SELF fw-down

[Install]
WantedBy=multi-user.target
EOF
      cat >/etc/systemd/system/geo-watch.service <<EOF
[Unit]
Description=vps-geo node takeover
After=network-online.target geo.service

[Service]
Type=simple
ExecStart=$SELF watch
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      ;;
    openrc)
      cu=
      id "$RUN_USER" >/dev/null 2>&1 && cu="command_user=\"$RUN_USER\""
      cat >/etc/init.d/geo <<EOF
#!/sbin/openrc-run
description="vps-geo exit IP switcher"
supervisor=supervise-daemon
command="$GLIDER"
command_args="-config $GLIDER_CONF"
$cu
output_log="$LOG"
error_log="$LOG"
respawn_delay=3

depend() {
  use net
  after firewall
}

start_pre() {
  export $(go_env)
  checkpath -f -m 0644 "$LOG"
  ${cu:+chown $RUN_USER "$LOG"}
}

start_post() {
  $SELF fw-up
}

stop_post() {
  $SELF fw-down
}
EOF
      cat >/etc/init.d/geo-watch <<EOF
#!/sbin/openrc-run
description="vps-geo node takeover"
supervisor=supervise-daemon
command="$SELF"
command_args="watch"
output_log="$LOG"
error_log="$LOG"
respawn_delay=5

depend() {
  use net
  after geo
}
EOF
      chmod 755 /etc/init.d/geo /etc/init.d/geo-watch
      ;;
  esac
}

svc_running() {
  case $INIT in
    systemd) systemctl is-active --quiet geo ;;
    openrc) rc-service geo status >/dev/null 2>&1 ;;
    *) [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null ;;
  esac
}

# systemd/openrc helpers: svc_on NAME / svc_off NAME
svc_on() {
  case $INIT in
    systemd) systemctl enable "$1" >/dev/null 2>&1; systemctl restart "$1" ;;
    openrc) rc-update add "$1" default >/dev/null 2>&1
      rc-service "$1" restart >/dev/null 2>&1 || rc-service "$1" start >/dev/null 2>&1 ;;
  esac
}

svc_off() {
  case $INIT in
    systemd) systemctl stop "$1" >/dev/null 2>&1; systemctl disable "$1" >/dev/null 2>&1 ;;
    openrc) rc-service "$1" stop >/dev/null 2>&1; rc-update del "$1" default >/dev/null 2>&1 ;;
  esac
  return 0
}

svc_stop_all() {
  for s in geo-watch geo-fw geo; do svc_off $s; done
  raw_stop
  fw_down
}

# Make the running services match the active exit (or "off").
apply_state() {
  _st=$(cur_state)
  if [ "$_st" = off ] && [ ! -f "$ETC/compat" ]; then
    svc_stop_all
    return 0
  fi
  fw_down
  write_glider_conf
  install_service
  case $INIT in
    systemd|openrc)
      svc_on geo || return 1
      if [ "$_st" = nat ]; then
        [ "$INIT" = systemd ] && { svc_on geo-fw || return 1; }
      else
        [ "$INIT" = systemd ] && svc_off geo-fw
      fi
      if [ -f "$ETC/compat" ]; then svc_on geo-watch; else svc_off geo-watch; fi
      ;;
    *)
      raw_stop
      raw_start || return 1
      if [ "$_st" = nat ]; then fw_up || return 1; fi
      autostart_none
      ;;
  esac
  case $_st in
    nat) _wp=$REDIR_PORT ;;
    port) _wp=$(sed -n 's/^PORT=//p' "$PROFILES/$(active_name).conf") ;;
    *) _wp=$COMPAT_PORT ;;
  esac
  # Give glider a moment to bind.
  i=0
  while [ $i -lt 10 ]; do
    port_in_use "$_wp" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# No init system (some containers): run glider in the background ourselves.
raw_start() {
  : >"$LOG"
  # shellcheck disable=SC2046
  if id "$RUN_USER" >/dev/null 2>&1 && have su; then
    chown "$RUN_USER" "$LOG" 2>/dev/null
    env $(go_env) su -s /bin/sh "$RUN_USER" -c "exec $GLIDER -config $GLIDER_CONF" \
      </dev/null >>"$LOG" 2>&1 &
  else
    env $(go_env) "$GLIDER" -config "$GLIDER_CONF" </dev/null >>"$LOG" 2>&1 &
  fi
  echo $! >"$PIDFILE"
  if [ -f "$ETC/compat" ]; then
    nohup "$SELF" watch </dev/null >>"$LOG" 2>&1 &
    echo $! >"$WATCH_PIDFILE"
  fi
}

raw_stop() {
  for pf in "$PIDFILE" "$WATCH_PIDFILE"; do
    [ -f "$pf" ] || continue
    kill "$(cat "$pf")" 2>/dev/null
    rm -f "$pf"
  done
  if have pkill; then
    pkill -f "$GLIDER -config" 2>/dev/null
    pkill -f "$SELF watch" 2>/dev/null
  fi
  return 0
}

autostart_none() {
  if have crontab; then
    (crontab -l 2>/dev/null | grep -v "$SELF boot"; echo "@reboot $SELF boot") | crontab - 2>/dev/null
  fi
}

# ---------------------------------------------------------------- actions

need_root() {
  [ "$(id -u)" = 0 ] || die "请用 root 运行（先执行 sudo -i 或 su -）。"
}

# A free port for port mode, picked automatically so it never takes a port
# the user wants for a node. The active exit's own port counts as free.
pick_port() {
  _pa=$(active_name)
  _pc=
  [ -n "$_pa" ] && [ -f "$PROFILES/$_pa.conf" ] && _pc=$(sed -n 's/^PORT=//p' "$PROFILES/$_pa.conf")
  _pp=$AUTO_PORT_MIN
  while [ "$_pp" -le "$AUTO_PORT_MAX" ]; do
    if [ "$_pp" = "$_pc" ] || ! port_in_use "$_pp"; then
      echo "$_pp"
      return 0
    fi
    _pp=$((_pp + 1))
  done
  echo "$AUTO_PORT_MAX"
}

save_real_ip() {
  [ -n "$IP_ADDR" ] && echo "$IP_ADDR" >"$ETC/real_ip"
}

real_ip() {
  cat "$ETC/real_ip" 2>/dev/null
}

# Fix up exits saved by older versions. Sets MIGRATED to an exit that was
# switched to while doing so.
migrate_profiles() {
  MIGRATED=
  # 2.0.0 had no backend file; its whole-machine mode was always NAT.
  if [ ! -f "$ETC/backend" ] && [ "$(cur_state)" = compat ]; then
    echo nat >"$ETC/backend"
  fi
  for _mp in $(list_profiles); do
    load_profile "$_mp" || continue
    [ "$MODE" = port ] || continue
    if [ "$PORT" -ge "$AUTO_PORT_MIN" ] && [ "$PORT" -le "$AUTO_PORT_MAX" ]; then continue; fi
    _old=$PORT
    _proxy=$PROXY
    title "升级提示"
    warn "出口 $_mp 之前占用了端口 $_old，搭节点时这个端口会显示「已被占用」。"
    say "新版不再让你填端口，下面帮你改好。"
    if confirm "你是想让节点（xray / sing-box 等）的出口变成这个 IP 吗？选 Y 改成整机模式（推荐）" y; then
      save_profile "$_mp" "$_proxy" all 0
    else
      _np=$(pick_port)
      save_profile "$_mp" "$_proxy" port "$_np"
      say "已把 $_mp 的本机代理端口改成 $_np。"
    fi
    if [ "$(active_name)" = "$_mp" ]; then
      use_profile "$_mp"
      MIGRATED=$_mp
    fi
    ok "端口 $_old 已经空出来，搭节点时可以用了。"
  done
}

# use_profile NAME
use_profile() {
  load_profile "$1" || die "没有名为 $1 的出口。输入 geo 打开菜单查看。"
  _un=$NAME
  prev=$(active_name)
  # Remember this machine's own IP while its traffic still goes out directly.
  if [ "$(cur_state)" != nat ] && check_ip; then save_real_ip; fi
  load_profile "$_un"

  if [ "$MODE" = all ]; then
    backend=compat
    if ensure_iptables && { pick_ipt || { ensure_iptables_legacy && pick_ipt; }; }; then
      backend=nat
      echo "$IPT" >"$ETC/ipt"
      probe_v6
    elif [ ! -f "$ETC/compat" ]; then
      say "这台小鸡不允许改网络规则（OpenVZ / LXC 常见），已自动改用${C_G}节点接管${C_0}方式："
      say "xray / sing-box / hysteria2 节点的流量会走这个出口。"
      say "节点装在 geo 之后也没关系，装好后 20 秒内会自动接管。"
    fi
    [ "$backend" = compat ] && touch "$ETC/compat"
    echo "$backend" >"$ETC/backend"
  fi

  say "正在切换到 $C_G$NAME$C_0（$(mode_text "$MODE" "$PORT")）..."
  echo "$NAME" >"$ACTIVE"
  if ! apply_state; then
    rm -f "$ACTIVE"
    apply_state
    err "代理程序没有起来。日志: $( [ "$INIT" = systemd ] && echo 'journalctl -u geo' || echo "$LOG" )"
    say "已恢复本机直连。"
    return 1
  fi
  _st=$(cur_state)
  case $_st in
    nat) check_ip ;;
    port) check_ip -x "socks5h://127.0.0.1:$PORT" ;;
    *) check_ip -x "socks5h://127.0.0.1:$COMPAT_PORT" ;;
  esac
  rc=$?
  if [ $rc -ne 0 ]; then
    err "通过这个出口访问外网失败，代理可能不通或账号密码不对。"
    if [ "$_st" = nat ]; then
      rm -f "$ACTIVE"
      apply_state
      say "为了不让整台机器断网，已自动恢复本机直连。"
      [ -n "$prev" ] && [ "$prev" != "$NAME" ] && say "（之前用的是 $prev，需要的话输入 $prev 切回去）"
    fi
    return 1
  fi
  ok "已切换到 $NAME"
  print_ip
  _real=$(real_ip)
  case $_st in
    nat)
      say ""
      say "  这台机器访问外网都会用上面的出口 IP，节点也一样，不用改节点配置。"
      if [ -n "$_real" ]; then
        say "  ${C_Y}搭节点注意${C_0}：节点地址要填本机 IP ${C_G}$_real${C_0}，不是上面的出口 IP。"
        say "  搭节点脚本自动检测到的 IP 如果不是 $_real，请手动改成 $_real。"
      fi
      ;;
    compat)
      node_scan
      say ""
      if [ -n "$NODES_TAKEN" ]; then
        say "  已接管的节点:$NODES_TAKEN。节点的出口就是上面的 IP。"
      else
        say "  还没发现节点。现在去搭节点就行，装好后 20 秒内自动接管，不用再做别的。"
      fi
      say "  支持 xray、sing-box、hysteria2，不管是用哪个脚本装的。"
      [ -n "$_real" ] && say "  节点地址填本机 IP: ${C_G}$_real${C_0}"
      ;;
    port)
      say ""
      say "  已自动开好本机代理端口（SOCKS5 和 HTTP 都可以）:"
      say "    socks5://127.0.0.1:$PORT"
      say "    http://127.0.0.1:$PORT"
      say "  这是给程序用的内部端口，${C_Y}搭节点时不要填它${C_0}。"
      say "  测试: curl -x socks5h://127.0.0.1:$PORT ipinfo.io"
      ;;
  esac
  return 0
}

turn_off() {
  rm -f "$ACTIVE"
  apply_state
  if [ -f "$ETC/compat" ]; then
    ok "已关闭，节点和本机都恢复直连。"
  else
    ok "已关闭，恢复本机直连。"
  fi
  check_ip && print_ip && save_real_ip
  return 0
}

show_status() {
  title "当前状态"
  _real=$(real_ip)
  [ -n "$_real" ] && say "本机 IP（搭节点填这个）: $_real"
  a=$(active_name)
  if [ -z "$a" ] || ! load_profile "$a"; then
    say "当前出口: 直连（没有使用任何出口）"
    check_ip && print_ip || warn "查不到本机出口 IP。"
    return 0
  fi
  _st=$(cur_state)
  case $_st in
    nat) _how="整机" ;;
    compat) _how="整机（节点接管）" ;;
    *) _how="端口 127.0.0.1:$PORT" ;;
  esac
  say "当前出口: $C_G$a$C_0（$_how）"
  if [ "$_st" = compat ]; then
    _nodes=$(node_taken)
    say "已接管节点:${_nodes:- 还没有（装好节点后 20 秒内自动接管）}"
  fi
  if ! svc_running; then
    warn "代理程序没在运行，输入 $a 重新启动它。"
    return 0
  fi
  case $_st in
    nat) check_ip ;;
    port) check_ip -x "socks5h://127.0.0.1:$PORT" ;;
    *) check_ip -x "socks5h://127.0.0.1:$COMPAT_PORT" ;;
  esac && print_ip || warn "通过这个出口查不到 IP，代理可能断了。"
  return 0
}

show_list() {
  a=$(active_name)
  n=0
  for p in $(list_profiles); do
    n=$((n + 1))
    load_profile "$p"
    mark="  "
    [ "$p" = "$a" ] && mark="$C_G* $C_0"
    say "$mark$p    $(mode_text "$MODE" "$PORT")    $(mask_url "$PROXY")"
  done
  [ $n -gt 0 ] || say "还没有添加任何出口。"
}

# Interactive: add (or replace) one exit.
add_profile() {
  title "第 1 步：填写 SOCKS5"
  say "例子: socks5://用户名:密码@isp-nm.jchen.eu.org:50001"
  say "也支持: 用户名:密码@主机:端口  或  主机:端口:用户名:密码"
  while :; do
    ask in_proxy "请粘贴 SOCKS5 地址"
    if ! parse_proxy "$in_proxy"; then
      err "格式不对，请检查后重新粘贴。"
      [ -n "${GEO_ASK_in_proxy:-}" ] && exit 1
      continue
    fi
    say "正在测试代理..."
    if check_ip -x "socks5h://${P_URL#socks5://}"; then
      ok "代理可用"
      print_ip
      break
    fi
    err "通过这个代理连不上外网（地址、端口、账号或密码可能有误，也可能代理暂时不通）。"
    if [ -n "${GEO_ASK_in_proxy:-}" ]; then
      break
    fi
    confirm "仍然保存这个代理吗？选 n 重新填写" n && break
  done
  proxy=$P_URL
  cc=$(printf '%s' "$IP_CC" | tr '[:upper:]' '[:lower:]')

  title "第 2 步：设置快捷命令"
  say "以后在终端输入这个命令，就会切换到这个出口 IP。"
  def=
  if [ -n "$cc" ]; then
    def=geo$cc
    [ "$cc" = gb ] && def=geouk
  fi
  while :; do
    ask in_name "快捷切换命令（小写字母开头，可含数字、- 和 _）" "$def"
    in_name=$(printf '%s' "$in_name" | tr '[:upper:]' '[:lower:]')
    if ! valid_name "$in_name"; then
      err "名字不行：要 2-32 位、小写字母开头，且不能是 geo / geooff。"
      [ -n "${GEO_ASK_in_name:-}" ] && exit 1
      continue
    fi
    existing=$(command -v "$in_name" 2>/dev/null)
    if [ -n "$existing" ] && [ ! -f "$PROFILES/$in_name.conf" ] &&
      ! { [ -L "$existing" ] && [ "$(readlink "$existing")" = "$SELF" ]; }; then
      err "系统里已经有 $existing 这个命令了，换个名字吧。"
      [ -n "${GEO_ASK_in_name:-}" ] && exit 1
      continue
    fi
    if [ -f "$PROFILES/$in_name.conf" ] && [ -z "${GEO_ASK_in_name:-}" ]; then
      confirm "$in_name 已经存在，要覆盖吗？" n || continue
    fi
    break
  done

  title "第 3 步：出口 IP 用在哪里"
  say "  1) 整机（推荐，搭节点就选这个）：节点和这台机器访问外网都用这个出口 IP"
  say "  2) 只开一个本机代理端口：给会自己改配置的人用，其它流量不变"
  if [ "$ROLE" = 母鸡 ]; then
    say "  提示：这是母鸡。整机模式只影响母鸡自己发起的连接，不影响下面的小鸡。"
  fi
  say "  不确定就直接回车。小鸡不支持改网络规则时，脚本会自动换成别的办法，不用你管。"
  while :; do
    ask in_mode "请选择 1 或 2" 1
    case $in_mode in
      1|整机) mode=all; port=0; break ;;
      2|端口) mode=port; port=$(pick_port); break ;;
      *) err "请输入 1 或 2。"; [ -n "${GEO_ASK_in_mode:-}" ] && exit 1 ;;
    esac
  done

  save_profile "$in_name" "$proxy" "$mode" "$port"
  ok "已保存出口 $in_name（$(mode_text "$mode" "$port")）"
  [ "$mode" = port ] && say "本机代理端口已自动选好: $port（这是内部端口，搭节点时不要填它）"
  if confirm "现在就切换到 $in_name 吗？" y; then
    use_profile "$in_name"
  fi
  say ""
  say "以后这样用:"
  say "  $C_G$in_name$C_0     切换到这个出口"
  say "  ${C_G}geooff$C_0    关闭，恢复本机 IP"
  say "  ${C_G}geo$C_0       打开管理菜单（添加/切换/删除/卸载）"
}

pick_profile() { # prompt -> PICKED
  PICKED=
  set -- $(list_profiles)
  [ $# -gt 0 ] || { say "还没有添加任何出口。"; return 1; }
  i=0
  for p in "$@"; do
    i=$((i + 1))
    load_profile "$p"
    say "  $i) $p    $(mode_text "$MODE" "$PORT")"
  done
  ask in_pick "输入序号或名字（直接回车取消）"
  [ -n "$in_pick" ] || return 1
  case $in_pick in
    *[!0-9]*) PICKED=$in_pick ;;
    *) [ "$in_pick" -ge 1 ] && [ "$in_pick" -le $# ] && eval "PICKED=\${$in_pick}" ;;
  esac
  [ -n "$PICKED" ] && [ -f "$PROFILES/$PICKED.conf" ] || { err "没有这个出口。"; return 1; }
}

del_profile() { # name
  [ -f "$PROFILES/$1.conf" ] || { err "没有名为 $1 的出口。"; return 1; }
  [ "$(active_name)" = "$1" ] && turn_off
  rm -f "$PROFILES/$1.conf"
  [ -L "$BIN/$1" ] && rm -f "$BIN/$1"
  ok "已删除 $1"
}

uninstall() {
  node_release_all
  rm -f "$ACTIVE" "$ETC/compat"
  svc_stop_all
  rm -f /etc/systemd/system/geo.service /etc/systemd/system/geo-fw.service \
    /etc/systemd/system/geo-watch.service /etc/init.d/geo /etc/init.d/geo-watch
  [ "$INIT" = systemd ] && systemctl daemon-reload
  if have crontab; then
    crontab -l 2>/dev/null | grep -v "$SELF boot" | crontab - 2>/dev/null
  fi
  for p in $(list_profiles); do rm -f "$BIN/$p"; done
  rm -f "$BIN/geooff" "$GLIDER" "$LOG" "$PIDFILE" "$WATCH_PIDFILE"
  rm -rf "$ETC"
  if id "$RUN_USER" >/dev/null 2>&1; then
    if have userdel; then userdel "$RUN_USER" 2>/dev/null; elif have deluser; then deluser "$RUN_USER" 2>/dev/null; fi
  fi
  rm -f "$SELF"
  ok "已卸载，本机恢复直连。"
}

menu() {
  while :; do
    title "vps-geo 出口管理 v$GEO_VERSION"
    a=$(active_name)
    if [ -n "$a" ] && load_profile "$a"; then
      say "当前: $C_G$a$C_0（$(mode_text "$MODE" "$PORT")）"
    else
      say "当前: 直连"
    fi
    say ""
    say "  1) 添加出口"
    say "  2) 切换出口"
    say "  3) 关闭出口（恢复本机直连）"
    say "  4) 查看状态 / 检测出口 IP"
    say "  5) 查看所有出口"
    say "  6) 删除出口"
    say "  7) 本机信息（小鸡/母鸡、系统、配置）"
    say "  8) 卸载"
    say "  0) 退出"
    ask in_menu "请选择" 0
    case $in_menu in
      1) add_profile ;;
      2) pick_profile && use_profile "$PICKED" ;;
      3) turn_off ;;
      4) show_status ;;
      5) show_list ;;
      6) pick_profile && confirm "确定删除 $PICKED 吗？" n && del_profile "$PICKED" ;;
      7) print_machine ;;
      8) confirm "确定卸载吗？所有出口配置都会删掉" n && { uninstall; exit 0; } ;;
      0|q|exit) exit 0 ;;
      *) err "请输入菜单里的数字。" ;;
    esac
  done
}

first_install() {
  need_root
  say "${C_B}vps-geo v$GEO_VERSION —— 给 VPS 换出口 IP${C_0}"
  detect_virt
  detect_system
  print_machine
  case $VIRT in
    docker|podman) warn "这是 Docker/Podman 容器，重启容器后需要重新运行一次 geo。" ;;
  esac
  if [ "$MEM_MB" -gt 0 ] && [ "$MEM_AVAIL_MB" -lt 16 ]; then
    warn "可用内存只有 ${MEM_AVAIL_MB}MB，代理程序可能起不来。可以先关掉一些程序。"
  fi
  title "准备环境"
  ensure_base_deps
  install_self
  install_glider
  ensure_user || warn "创建 $RUN_USER 用户失败，将以 root 运行代理程序。"
  ok "安装完成，命令 geo 已就绪"
  if [ -z "$(active_name)" ] && check_ip; then save_real_ip; fi
  if [ -n "$(list_profiles)" ]; then
    migrate_profiles
    menu
  else
    add_profile
  fi
}

# ---------------------------------------------------------------- entry

main() {
  me=$(basename "$0")
  case $me in
    geooff)
      need_root; detect_system; turn_off; exit ;;
    geo|geo.sh|sh|bash|ash|dash) ;;
    install.sh|*install*) first_install; exit ;;
    *)
      if [ -f "$PROFILES/$me.conf" ]; then
        need_root; detect_virt; detect_system; migrate_profiles
        [ "$MIGRATED" = "$me" ] || use_profile "$me"
        exit
      fi
      ;;
  esac

  # Running from a pipe (curl ... | sh) or not installed yet.
  if [ "$me" != geo ] || [ ! -x "$SELF" ]; then
    first_install
    exit
  fi

  cmd=${1:-}
  [ $# -gt 0 ] && shift
  case $cmd in
    fw-up) detect_system; fw_up; exit ;;
    fw-down) fw_down; exit 0 ;;
    watch) need_root; detect_system; node_watch; exit ;;
    boot) need_root; detect_system; apply_state; exit ;;
    -h|--help|help)
      cat <<EOF
用法:
  geo              打开菜单
  geo add          添加出口
  geo <名字>       切换到某个出口（也可以直接输入名字，如 geous）
  geo off          关闭出口（同 geooff）
  geo status       查看当前出口 IP
  geo list         列出所有出口
  geo del <名字>   删除出口
  geo info         本机信息（小鸡/母鸡检测）
  geo update       更新脚本
  geo uninstall    卸载
EOF
      exit 0 ;;
  esac

  need_root
  detect_virt
  detect_system
  migrate_profiles
  case $cmd in
    '') menu ;;
    add) add_profile ;;
    off|direct) turn_off ;;
    status) show_status ;;
    list|ls) show_list ;;
    del|rm) [ -n "${1:-}" ] || die "用法: geo del <名字>"; del_profile "$1" ;;
    info) print_machine ;;
    update) download "$REPO_RAW/install.sh" "$SELF.new" && chmod 755 "$SELF.new" &&
              mv "$SELF.new" "$SELF" && ok "已更新到最新版。" ;;
    uninstall) confirm "确定卸载吗？" n && uninstall ;;
    *)
      if [ -f "$PROFILES/$cmd.conf" ]; then
        [ "$MIGRATED" = "$cmd" ] || use_profile "$cmd"
      elif [ -f "$PROFILES/geo$cmd.conf" ]; then
        use_profile "geo$cmd"
      else
        die "没有名为 $cmd 的出口。输入 geo list 查看。"
      fi
      ;;
  esac
}

main "$@"
