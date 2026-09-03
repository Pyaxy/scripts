#!/bin/sh
# Alpine low-space native Snell + ShadowTLS installer
# Derived from the interaction/configuration semantics of jinqians/snell.sh.
# Docker and systemd are intentionally not required.

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; RESET='\033[0m'
VERSION="1.3.2"

INSTALL_DIR="/usr/local/bin"
STATE_DIR="/etc/snell-alpine-lowspace"
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
STLS_CONF_DIR="/etc/shadowtls"
GLIBC_DIR="/usr/local/lib/snell-glibc"
SNELL_V4_FALLBACK="v4.1.1"
SNELL_V5_FALLBACK="v5.0.1"
SNELL_V6_FALLBACK="v6.0.0rc2"
SHADOWTLS_FALLBACK_VERSION="v0.2.25"

say() { printf '%b\n' "$*"; }
die() { say "${RED}错误: $*${RESET}" >&2; exit 1; }
pause() { printf '%b' "\n${CYAN}按回车键返回主菜单...${RESET}"; read -r _pause || true; }

check_environment() {
    [ "$(id -u)" -eq 0 ] || die "请以 root 权限运行此脚本。"
    [ -f /etc/alpine-release ] || die "此脚本仅适用于 Alpine Linux。"
    command -v apk >/dev/null 2>&1 || die "未找到 apk。"
    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64) ;;
        *) die "当前仅支持 x86_64/amd64/aarch64/arm64；Snell v6 也不提供 armv7。" ;;
    esac
}

ensure_base_packages() {
    missing=""
    for item in curl:curl unzip:unzip openssl:openssl rc-service:openrc gzip:gzip ss:iproute2 pgrep:procps; do
        cmd=${item%%:*}; pkg=${item#*:}
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $pkg"
    done
    if [ -n "$missing" ]; then
        say "${CYAN}安装最小依赖:${missing}${RESET}"
        # shellcheck disable=SC2086
        apk add --no-cache $missing || die "依赖安装失败。"
    fi
}

openrc_service_enabled() {
    local openrc_service=$1
    [ -x "/etc/init.d/$openrc_service" ] && \
      [ -L "/etc/runlevels/default/$openrc_service" ] && \
      [ -e "/etc/runlevels/default/$openrc_service" ]
}

enable_openrc_service() {
    local openrc_service=$1
    if ! rc-update add "$openrc_service" default; then
      say "${RED}无法将 $openrc_service 加入 OpenRC default runlevel。${RESET}" >&2
      return 1
    fi
    # 强制刷新依赖树，避免新建的服务链接存在但本次/下次启动未被调度。
    if ! rc-update -u >/dev/null 2>&1; then
      say "${RED}OpenRC 依赖树刷新失败，详细输出如下：${RESET}" >&2
      rc-update -u || true
      return 1
    fi
    if ! openrc_service_enabled "$openrc_service"; then
      say "${RED}$openrc_service 的 default runlevel 链接无效。${RESET}" >&2
      return 1
    fi
    say "${GREEN}✓ $openrc_service 已加入 OpenRC default 并刷新依赖树。${RESET}"
}

refresh_managed_openrc_services() {
    local openrc_init openrc_service openrc_failed=false
    if [ -x /etc/init.d/snell ]; then
      enable_openrc_service snell || openrc_failed=true
    fi
    for openrc_init in /etc/init.d/shadowtls-snell-*; do
      [ -x "$openrc_init" ] || continue
      openrc_service=${openrc_init##*/}
      enable_openrc_service "$openrc_service" || openrc_failed=true
    done
    $openrc_failed && say "${RED}存在未能注册的托管服务，请检查上方 OpenRC 错误。${RESET}"
    return 0
}
random_port() {
    # 10000..65535, only BusyBox tools are needed.
    n=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' ')
    [ -n "$n" ] || n=$$
    echo $((10000 + n % 55536))
}

port_in_use() {
    p=$1
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntu 2>/dev/null | grep -Eq "[:.]${p}([[:space:]]|$)"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntu 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$p$"
    else
        return 1
    fi
}

port_listening() {
    p=$1; proto=$2
    case "$proto" in
      tcp) ss -H -lnt 2>/dev/null | grep -Eq "[:.]${p}([[:space:]]|$)" ;;
      udp) ss -H -lnu 2>/dev/null | grep -Eq "[:.]${p}([[:space:]]|$)" ;;
      *) return 1 ;;
    esac
}

process_running() {
    local pidfile=$1 pattern=$2 pid
    if [ -s "$pidfile" ]; then
      pid=$(cat "$pidfile" 2>/dev/null || true)
      case "$pid" in ''|*[!0-9]*) pid="" ;; esac
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        if [ -r "/proc/$pid/cmdline" ]; then
          tr '\000' ' ' < "/proc/$pid/cmdline" | grep -Fq -- "$pattern" && return 0
        else
          return 0
        fi
      fi
    fi
    pgrep -f -- "$pattern" >/dev/null 2>&1
}

snell_running() {
    # The OpenRC command starts a wrapper, which execs the versioned payload.
    # v4/v5 cmdline contains snell-server-vX.bin; v6 loader cmdline also contains it.
    process_running /run/snell.pid "snell-server-v"
}

shadowtls_running() {
    local backend=$1 listen_port=${2:-} pid cmdline
    if [ -s "/run/shadowtls-snell-$backend.pid" ]; then
      pid=$(cat "/run/shadowtls-snell-$backend.pid" 2>/dev/null || true)
      case "$pid" in ''|*[!0-9]*) pid="" ;; esac
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -r "/proc/$pid/cmdline" ]; then
        cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline")
        case "$cmdline" in
          *shadow-tls*"--server 127.0.0.1:$backend"*)
            if [ -z "$listen_port" ]; then return 0; fi
            case "$cmdline" in *"--listen ::0:$listen_port"*|*"--listen [::]:$listen_port"*|*"--listen 0.0.0.0:$listen_port"*) return 0 ;; esac
            ;;
        esac
      fi
    fi
    for pid in $(pgrep -f -- "$INSTALL_DIR/shadow-tls" 2>/dev/null || true); do
      [ -r "/proc/$pid/cmdline" ] || continue
      cmdline=$(tr '\000' ' ' < "/proc/$pid/cmdline")
      case "$cmdline" in
        *shadow-tls*"--server 127.0.0.1:$backend"*)
          if [ -z "$listen_port" ]; then return 0; fi
          case "$cmdline" in *"--listen ::0:$listen_port"*|*"--listen [::]:$listen_port"*|*"--listen 0.0.0.0:$listen_port"*) return 0 ;; esac
          ;;
      esac
    done
    return 1
}

wait_until_ready() {
    kind=$1; backend=$2; port=$3; proto=$4; attempt=0
    while [ "$attempt" -lt 8 ]; do
      if [ "$kind" = snell ]; then
        running=false; snell_running && running=true
      else
        running=false; shadowtls_running "$backend" "$port" && running=true
      fi
      if $running && port_listening "$port" "$proto"; then return 0; fi
      sleep 1; attempt=$((attempt + 1))
    done
    return 1
}

verify_elf_arch() {
    binary=$1; label=$2
    magic=$(od -An -tx1 -N4 "$binary" 2>/dev/null | tr -d ' \n')
    [ "$magic" = 7f454c46 ] || { say "${RED}${label} 不是有效的 ELF 文件。${RESET}" >&2; return 1; }
    machine=$(od -An -tx1 -j18 -N2 "$binary" 2>/dev/null | tr -d ' \n')
    case "$(uname -m):$machine" in
      x86_64:3e00|amd64:3e00|aarch64:b700|arm64:b700) return 0 ;;
      *) say "${RED}${label} 的 ELF 架构与当前机器不一致（machine=$machine）。${RESET}" >&2; return 1 ;;
    esac
}

probe_executable() {
    local binary=$1 label=$2 output rc
    output=$("$binary" --v 2>&1); rc=$?
    if printf '%s' "$output" | grep -Eqi 'not found|no such file|exec format|permission denied|error loading shared librar|segmentation fault|illegal instruction'; then
        say "${RED}${label} 无法被当前系统正常加载（退出码 $rc）。${RESET}" >&2
        printf '%s\n' "$output" >&2
        return 1
    fi
    case "$rc" in
      126|132|134|135|136|137|138|139)
        say "${RED}${label} 无法被当前内核正常加载（退出码 $rc）。${RESET}" >&2
        [ -n "$output" ] && printf '%s\n' "$output" >&2
        return 1
        ;;
    esac
    # Snell 某些版本会用 127 等非零状态响应 --v；这不等同于 shell 无法加载。
    if [ -n "$output" ]; then
      say "${GREEN}${label} 已执行（--v 退出码 $rc）: $(printf '%s' "$output" | head -n 1)${RESET}"
    else
      say "${YELLOW}${label} 已执行，--v 退出码为 $rc 且无输出；最终以服务进程和监听端口验证为准。${RESET}"
    fi
    return 0
}

ask_port_required() {
    while :; do
        printf '请输入要使用的端口号 (1-65535): '
        read -r PORT || return 1
        case "$PORT" in ''|*[!0-9]*) PORT=0 ;; esac
        if [ "$PORT" -ge 1 ] 2>/dev/null && [ "$PORT" -le 65535 ] 2>/dev/null; then
            say "${GREEN}已选择端口: $PORT${RESET}"; return 0
        fi
        say "${RED}无效端口号，请输入 1 到 65535 之间的数字。${RESET}"
    done
}

ask_available_port() {
    local stls_prompt=$1 stls_chosen
    while :; do
        printf '%s' "$stls_prompt"
        read -r stls_chosen || return 1
        [ -n "$stls_chosen" ] || stls_chosen=$(random_port)
        case "$stls_chosen" in ''|*[!0-9]*) stls_chosen=0 ;; esac
        if [ "$stls_chosen" -lt 1 ] 2>/dev/null || [ "$stls_chosen" -gt 65535 ] 2>/dev/null; then
            say "${RED}无效端口号。${RESET}"; continue
        fi
        if port_in_use "$stls_chosen"; then
            say "${RED}端口 ${stls_chosen} 已被占用。${RESET}"; continue
        fi
        AVAILABLE_PORT=$stls_chosen
        return 0
    done
}

snell_version_sort_key() {
    echo "${1#v}" | awk '{
      v=$0; s=""; if(match(v,/[a-zA-Z]+[0-9]*$/)){s=tolower(substr(v,RSTART));v=substr(v,1,RSTART-1)}
      split(v,p,"."); stage=3; seq=0
      if(s!=""){stage=(s~/^rc/)?2:1; d=s;gsub(/[^0-9]/,"",d);if(d!="")seq=d+0}
      printf "%03d.%03d.%03d.%d.%04d",p[1],p[2],p[3],stage,seq
    }'
}

latest_snell_version() {
    major=${1#v}; fallback=$2
    notes=$(curl -fsSL --connect-timeout 8 --max-time 20 \
      https://kb.nssurge.com/surge-knowledge-base/release-notes/snell 2>/dev/null || true)
    ver=$(printf '%s' "$notes" | grep -oE "snell-server-v${major}\.[0-9]+\.[0-9]+[a-zA-Z0-9]*" \
      | sed 's/^snell-server-v//' | sort -u | while read -r v; do
          printf '%s %s\n' "$(snell_version_sort_key "$v")" "$v"
        done | sort | tail -n 1 | awk '{print $2}')
    if [ -n "$ver" ]; then
      say "${GREEN}从 Surge 发布历史解析到 v${major} 最新版本: v${ver}${RESET}" >&2
      echo "v$ver"
    else
      say "${YELLOW}未能从 Surge 发布历史解析 v${major}，使用内置回退版本: ${fallback}${RESET}" >&2
      echo "$fallback"
    fi
}

installed_snell_channels() {
    channels=""
    for channel in v4 v5 v6; do
      [ -x "$INSTALL_DIR/snell-server-$channel" ] && channels="$channels $channel"
    done
    echo "${channels# }"
}

snell_download_url() {
    ver=$1
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=aarch64 ;;
    esac
    echo "https://dl.nssurge.com/snell/snell-server-${ver}-linux-${arch}.zip"
}

debian_arch() {
    case "$(uname -m)" in x86_64|amd64) echo amd64 ;; aarch64|arm64) echo arm64 ;; esac
}

debian_triplet() {
    case "$(uname -m)" in x86_64|amd64) echo x86_64-linux-gnu ;; aarch64|arm64) echo aarch64-linux-gnu ;; esac
}

install_isolated_glibc() {
    if [ -x "${GLIBC_DIR}/ld-linux-x86-64.so.2" ] || [ -x "${GLIBC_DIR}/ld-linux-aarch64.so.1" ]; then
        return 0
    fi
    say "${CYAN}正在安装隔离的最小 glibc 运行库（不会替换 Alpine musl）...${RESET}"
    had_dpkg=false
    command -v dpkg-deb >/dev/null 2>&1 && had_dpkg=true
    $had_dpkg || apk add --no-cache dpkg >/dev/null || die "无法安装临时解包工具 dpkg。"

    glibc_tmp=$(mktemp -d) || die "无法创建临时目录。"
    trap 'rm -rf "${glibc_tmp:-}"' EXIT HUP INT TERM
    arch=$(debian_arch); triplet=$(debian_triplet)
    index_url="https://deb.debian.org/debian/dists/bookworm/main/binary-${arch}/Packages.gz"
    curl -fsSL --retry 2 "$index_url" -o "$glibc_tmp/Packages.gz" || die "下载 Debian 包索引失败。"
    gzip -dc "$glibc_tmp/Packages.gz" > "$glibc_tmp/Packages" || die "解压包索引失败。"

    mkdir -p "$glibc_tmp/root" "$GLIBC_DIR"
    for pkg in libc6 libgcc-s1 libstdc++6; do
        filename=$(awk -v want="$pkg" '
          $1=="Package:" {ok=($2==want)} ok && $1=="Filename:" {print $2; exit}
        ' "$glibc_tmp/Packages")
        [ -n "$filename" ] || die "索引中未找到 $pkg。"
        curl -fsSL --retry 2 "https://deb.debian.org/debian/$filename" -o "$glibc_tmp/$pkg.deb" || die "下载 $pkg 失败。"
        dpkg-deb -x "$glibc_tmp/$pkg.deb" "$glibc_tmp/root" || die "解包 $pkg 失败。"
    done

    # Flatten only runtime libraries; avoid locale, docs and package metadata.
    find "$glibc_tmp/root/lib/$triplet" "$glibc_tmp/root/usr/lib/$triplet" -maxdepth 1 \
      \( -type f -o -type l \) -exec cp -aL '{}' "$GLIBC_DIR/" ';' 2>/dev/null || true
    case "$arch" in
      amd64) loader=$(find "$glibc_tmp/root" -type f -name 'ld-linux-x86-64.so.2' | head -n 1); lname=ld-linux-x86-64.so.2 ;;
      arm64) loader=$(find "$glibc_tmp/root" -type f -name 'ld-linux-aarch64.so.1' | head -n 1); lname=ld-linux-aarch64.so.1 ;;
    esac
    [ -n "$loader" ] || die "glibc 动态加载器未找到。"
    cp "$loader" "$GLIBC_DIR/$lname"; chmod 755 "$GLIBC_DIR/$lname"
    rm -rf "$glibc_tmp"; glibc_tmp=""; trap - EXIT HUP INT TERM
    $had_dpkg || apk del dpkg >/dev/null 2>&1 || true
    say "${GREEN}✓ glibc 运行库已安装到 ${GLIBC_DIR}${RESET}"
}

snell_loader() {
    case "$(uname -m)" in
      x86_64|amd64) echo "$GLIBC_DIR/ld-linux-x86-64.so.2" ;;
      aarch64|arm64) echo "$GLIBC_DIR/ld-linux-aarch64.so.1" ;;
    esac
}

ensure_system_loader_link() {
    loader=$(snell_loader)
    case "$(uname -m)" in
      x86_64|amd64) system_loader=/lib64/ld-linux-x86-64.so.2 ;;
      aarch64|arm64) system_loader=/lib/ld-linux-aarch64.so.1 ;;
    esac
    mkdir -p "${system_loader%/*}"
    if [ -e "$system_loader" ] || [ -L "$system_loader" ]; then
      say "${YELLOW}保留已存在的 GNU loader: $system_loader${RESET}"
      return 0
    fi
    ln -s "$loader" "$system_loader" || return 1
    say "${GREEN}✓ 已创建 Snell 所需 loader 软链接: $system_loader -> $loader${RESET}"
}

remove_owned_loader_link() {
    case "$(uname -m)" in
      x86_64|amd64) system_loader=/lib64/ld-linux-x86-64.so.2 ;;
      aarch64|arm64) system_loader=/lib/ld-linux-aarch64.so.1 ;;
    esac
    if [ -L "$system_loader" ] && [ "$(readlink "$system_loader" 2>/dev/null)" = "$(snell_loader)" ]; then
      rm -f "$system_loader"
    fi
}

install_snell_binary() {
    channel=$1
    case "$channel" in
      v4) resolved=$(latest_snell_version v4 "$SNELL_V4_FALLBACK") ;;
      v5) resolved=$(latest_snell_version v5 "$SNELL_V5_FALLBACK") ;;
      v6) resolved=$(latest_snell_version v6 "$SNELL_V6_FALLBACK") ;;
      *) return 1 ;;
    esac
    url=$(snell_download_url "$resolved")
    snell_tmp=$(mktemp -d) || return 1
    say "${CYAN}正在下载 Snell ${channel} (${resolved})...${RESET}"
    curl -fL --retry 2 "$url" -o "$snell_tmp/snell.zip" || { rm -rf "$snell_tmp"; return 1; }
    unzip -oq "$snell_tmp/snell.zip" -d "$snell_tmp" || { rm -rf "$snell_tmp"; return 1; }
    [ -f "$snell_tmp/snell-server" ] || { rm -rf "$snell_tmp"; return 1; }
    verify_elf_arch "$snell_tmp/snell-server" "Snell ${channel}" || { rm -rf "$snell_tmp"; return 1; }
    mkdir -p "$STATE_DIR"
    # v4/v5 are packed executables: the outer ELF looks static, but the unpacked
    # payload opens the conventional GNU loader path. v6 is directly dynamic.
    # Keep every channel as a separate payload/wrapper so they can coexist.
    install_isolated_glibc
    ensure_system_loader_link || die "无法创建 Snell 所需的 GNU loader 软链接。"
    if ! cp "$snell_tmp/snell-server" "$STATE_DIR/snell-server-${channel}.bin"; then
      rm -rf "$snell_tmp"
      die "写入 Snell ${channel} 实体二进制失败。"
    fi
    chmod 755 "$STATE_DIR/snell-server-${channel}.bin" || die "设置 Snell ${channel} 权限失败。"
    if [ "$channel" = "v6" ]; then
      loader=$(snell_loader)
      cat > "$INSTALL_DIR/snell-server-${channel}" <<EOF
#!/bin/sh
exec "$loader" --library-path "$GLIBC_DIR" "$STATE_DIR/snell-server-${channel}.bin" "\$@"
EOF
    else
      cat > "$INSTALL_DIR/snell-server-${channel}" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH="$GLIBC_DIR"
exec "$STATE_DIR/snell-server-${channel}.bin" "\$@"
EOF
    fi
    chmod 755 "$INSTALL_DIR/snell-server-${channel}"
    ln -sfn "$INSTALL_DIR/snell-server-${channel}" "$INSTALL_DIR/snell-server"
    rm -rf "$snell_tmp"; snell_tmp=""
    probe_executable "$INSTALL_DIR/snell-server-${channel}" "Snell ${channel}" || die "Snell 二进制兼容性测试失败。"
    printf '%s\n' "$resolved" > "$STATE_DIR/version-${channel}"
    say "${GREEN}✓ Snell ${channel} 已就位。${RESET}"
}

select_snell_version() {
    say "${CYAN}请选择要安装的 Snell 版本：${RESET}"
    say "${GREEN}1.${RESET} Snell v4"
    say "${GREEN}2.${RESET} Snell v5"
    say "${GREEN}3.${RESET} Snell v6 (RC)"
    while :; do
        printf '请输入选项 [1-3]: '; read -r c || return 1
        case "$c" in
          1) SNELL_VERSION_CHOICE=v4; say "${GREEN}已选择 Snell v4${RESET}"; return ;;
          2) SNELL_VERSION_CHOICE=v5; say "${GREEN}已选择 Snell v5${RESET}"; return ;;
          3) SNELL_VERSION_CHOICE=v6; say "${GREEN}已选择 Snell v6 (RC)${RESET}"; say "${YELLOW}注意：v6 仍为预发布版本，且已移除 QUIC 与 obfs。${RESET}"; return ;;
          *) say "${RED}请输入正确的选项 [1-3]${RESET}" ;;
        esac
    done
}

select_v6_options() {
    say "\n${CYAN}=== Snell v6 加密模式 (mode) ===${RESET}"
    say "1. default     流量混淆 + AES 加密"
    say "2. unshaped    关闭混淆，仅 AES 加密"
    say "3. unsafe-raw  明文转发，不加密不混淆"
    while :; do
      printf '请选择加密模式 [1-3]（回车使用 1）: '; read -r c || return 1; [ -n "$c" ] || c=1
      case "$c" in 1) SNELL_MODE=default; break ;; 2) SNELL_MODE=unshaped; break ;;
        3) printf '确认使用 unsafe-raw? [y/N]: '; read -r x; case "$x" in y|Y|yes|YES) SNELL_MODE=unsafe-raw; break ;; esac ;;
        *) say "${RED}请输入正确选项。${RESET}" ;; esac
    done
    say "\n${CYAN}=== Snell v6 DNS 解析偏好 (dns-ip-preference) ===${RESET}"
    say "1. default  2. prefer-ipv4  3. prefer-ipv6  4. ipv4-only  5. ipv6-only"
    while :; do
      printf '请选择 DNS 解析偏好 [1-5]（回车使用 1）: '; read -r c || return 1; [ -n "$c" ] || c=1
      case "$c" in 1) SNELL_DNS_PREF=default; break ;; 2) SNELL_DNS_PREF=prefer-ipv4; break ;;
        3) SNELL_DNS_PREF=prefer-ipv6; break ;; 4) SNELL_DNS_PREF=ipv4-only; break ;;
        5) SNELL_DNS_PREF=ipv6-only; break ;; *) say "${RED}请输入正确选项。${RESET}" ;; esac
    done
}

write_snell_openrc() {
    mkdir -p /var/log
    cat > /etc/init.d/snell <<EOF
#!/sbin/openrc-run
name="Snell Proxy Service"
command="$INSTALL_DIR/snell-server"
command_args="-c $SNELL_CONF_FILE"
command_background=true
pidfile="/run/snell.pid"
output_log="/var/log/snell.log"
error_log="/var/log/snell.log"
depend() { need net; after firewall; }
EOF
    chmod 755 /etc/init.d/snell
    enable_openrc_service snell || die "Snell 自启动注册失败。"
}

open_port() {
    p=$1; proto=$2
    if command -v iptables >/dev/null 2>&1; then
      iptables -C INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1 || \
        iptables -I INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
    fi
}

close_port() {
    p=$1; proto=$2
    command -v iptables >/dev/null 2>&1 && iptables -D INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
}

enable_tcp_fastopen() {
    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-tcp-fastopen.conf <<'EOF'
# Managed by snell-alpine-lowspace.sh
net.ipv4.tcp_fastopen = 3
EOF
    if ! sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1; then
      say "${YELLOW}无法在当前环境修改 net.ipv4.tcp_fastopen；若这是受限容器，请在宿主机设置为 3。${RESET}"
    fi
}

install_snell() {
    if [ -f "$SNELL_CONF_FILE" ]; then
      printf '检测到已有 Snell 配置，重新安装会生成新的端口和 PSK。继续? [y/N]: '
      read -r reinstall || return
      case "$reinstall" in y|Y|yes|YES) ;; *) say "${YELLOW}已取消。${RESET}"; return ;; esac
      for f in "$STLS_CONF_DIR"/snell-*.conf; do
        if [ -f "$f" ]; then
          say "${YELLOW}检测到 ShadowTLS；为避免旧后端残留，将先卸载 ShadowTLS。${RESET}"
          uninstall_shadowtls
          break
        fi
      done
    fi
    select_snell_version || return
    install_snell_binary "$SNELL_VERSION_CHOICE" || die "Snell 下载或安装失败。"
    ask_port_required || return
    printf '请输入 DNS 服务器地址 (直接回车使用系统DNS): '; read -r custom_dns || return
    if [ -z "$custom_dns" ]; then
      DNS=$(awk '/^nameserver/{a=a (a?",":"") $2} END{print a}' /etc/resolv.conf)
      [ -n "$DNS" ] || DNS="1.1.1.1,8.8.8.8"
      say "${GREEN}使用系统 DNS 服务器: $DNS${RESET}"
    else DNS=$custom_dns; say "${GREEN}使用自定义 DNS 服务器: $DNS${RESET}"; fi
    IPV6_ENABLE=true; LISTEN_ADDR=::0
    printf '是否启用 IPv6? [Y/n]: '; read -r ipv6_choice || return
    case "$ipv6_choice" in n|N|no|NO) IPV6_ENABLE=false; LISTEN_ADDR=0.0.0.0; say "${GREEN}已关闭 IPv6，仅监听 IPv4${RESET}" ;; *) say "${GREEN}已启用 IPv6${RESET}" ;; esac
    SNELL_MODE=default; SNELL_DNS_PREF=""
    [ "$SNELL_VERSION_CHOICE" = v6 ] && select_v6_options
    PSK=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
    mkdir -p "$SNELL_CONF_DIR/users"
    {
      echo "#version-choice = $SNELL_VERSION_CHOICE"
      echo "[snell-server]"
      echo "listen = $LISTEN_ADDR:$PORT"
      echo "psk = $PSK"
      if [ "$SNELL_VERSION_CHOICE" = v6 ]; then
        echo "mode = $SNELL_MODE"
        [ -n "$SNELL_DNS_PREF" ] && echo "dns-ip-preference = $SNELL_DNS_PREF" || echo "dns-ip-preference = default"
      else echo "ipv6 = $IPV6_ENABLE"; fi
      echo "dns = $DNS"
    } > "$SNELL_CONF_FILE"
    chmod 644 "$SNELL_CONF_FILE"
    write_snell_openrc
    rc-service snell restart >/dev/null 2>&1 || rc-service snell start || die "Snell 服务启动失败，请查看 /var/log/snell.log。"
    if ! wait_snell_backend "$SNELL_CONF_FILE" "$PORT" snell; then
      if snell_backend_running "$SNELL_CONF_FILE" "$PORT" snell; then
        say "${GREEN}Snell 进程检查：存在。${RESET}" >&2
      else
        say "${RED}Snell 进程检查：不存在。${RESET}" >&2
      fi
      if port_listening "$PORT" tcp; then
        say "${GREEN}Snell TCP 监听检查：$PORT 正在监听。${RESET}" >&2
      else
        say "${RED}Snell TCP 监听检查：$PORT 未监听。${RESET}" >&2
      fi
      rc-service snell status 2>&1 || true
      ss -H -lntup 2>/dev/null | grep -F ":$PORT" || true
      tail -n 30 /var/log/snell.log 2>/dev/null || true
      die "Snell 启动验证失败。"
    fi
    open_port "$PORT" tcp; open_port "$PORT" udp
    say "\n${GREEN}安装完成！以下是您的配置信息：${RESET}"
    say "${YELLOW}监听端口: $PORT${RESET}\n${YELLOW}PSK 密钥: $PSK${RESET}\n${YELLOW}IPv6: $IPV6_ENABLE${RESET}\n${YELLOW}DNS 服务器: $DNS${RESET}"
}

conf_value() { awk -F= -v k="$1" '$1~"^[[:space:]]*"k"[[:space:]]*$"{v=$2;sub(/^[[:space:]]*/,"",v);print v;exit}' "$2"; }
conf_channel() { sed -n 's/^#[[:space:]]*version-choice[[:space:]]*=[[:space:]]*//p' "$1" | head -n 1; }
conf_port() { sed -n 's/^[[:space:]]*listen[[:space:]]*=.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$1" | head -n 1; }

public_ip() {
    ip=$(curl -fsS4 --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)
    [ -n "$ip" ] || ip=$(curl -fsS6 --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null || true)
    echo "${ip:-服务器IP}"
}

print_snell_line() {
    ip=$1; port=$2; psk=$3; channel=$4; mode=${5:-default}
    case "$channel" in
      v6) say "${GREEN}Unknown = snell, $ip, $port, psk = $psk, version = 6, mode = $mode, reuse = true, tfo = true${RESET}" ;;
      v5) say "${GREEN}Unknown = snell, $ip, $port, psk = $psk, version = 4, reuse = true, tfo = true${RESET}"; say "${GREEN}Unknown = snell, $ip, $port, psk = $psk, version = 5, reuse = true, tfo = true${RESET}" ;;
      *) say "${GREEN}Unknown = snell, $ip, $port, psk = $psk, version = 4, reuse = true, tfo = true${RESET}" ;;
    esac
}

view_snell_config() {
    [ -f "$SNELL_CONF_FILE" ] || { say "${RED}Snell 未安装。${RESET}"; return; }
    p=$(conf_port "$SNELL_CONF_FILE"); psk=$(conf_value psk "$SNELL_CONF_FILE"); ch=$(conf_channel "$SNELL_CONF_FILE")
    mode=$(conf_value mode "$SNELL_CONF_FILE"); [ -n "$mode" ] || mode=default
    ip=$(public_ip)
    say "${GREEN}Snell 配置信息:${RESET}\n${CYAN}================================${RESET}"
    say "${YELLOW}端口: $p${RESET}\n${YELLOW}版本: Snell $ch${RESET}\n${YELLOW}PSK: $psk${RESET}"
    say "\n${GREEN}Surge 配置格式：${RESET}"; print_snell_line "$ip" "$p" "$psk" "$ch" "$mode"
    say "\n${YELLOW}配置文件: $SNELL_CONF_FILE${RESET}"
}

latest_shadowtls_version() {
    local stls_latest
    stls_latest=$(curl -fsSL --connect-timeout 8 --max-time 15 https://api.github.com/repos/ihciah/shadow-tls/releases/latest 2>/dev/null \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    echo "${stls_latest:-$SHADOWTLS_FALLBACK_VERSION}"
}

probe_shadowtls_executable() {
    local stls_binary=$1 stls_output stls_rc
    stls_output=$("$stls_binary" --help 2>&1); stls_rc=$?
    if [ "$stls_rc" -ne 0 ] || printf '%s' "$stls_output" | grep -Eqi 'not found|no such file|exec format|permission denied|error loading shared librar|segmentation fault|illegal instruction'; then
      say "${RED}ShadowTLS 无法被当前系统正常执行（--help 退出码 $stls_rc）。${RESET}" >&2
      [ -n "$stls_output" ] && printf '%s\n' "$stls_output" >&2
      return 1
    fi
    if ! printf '%s' "$stls_output" | grep -Eqi '(^|[[:space:]])server([[:space:]]|$)|usage:'; then
      say "${RED}ShadowTLS --help 输出不符合预期，拒绝安装未知文件。${RESET}" >&2
      printf '%s\n' "$stls_output" | head -n 8 >&2
      return 1
    fi
    say "${GREEN}✓ ShadowTLS 二进制执行测试通过（使用 --help，不再误用 --v）。${RESET}"
}

install_shadowtls_binary() {
    local stls_arch stls_version stls_url stls_tmp
    case "$(uname -m)" in
      x86_64|amd64) stls_arch=x86_64-unknown-linux-musl ;;
      aarch64|arm64) stls_arch=aarch64-unknown-linux-musl ;;
    esac
    stls_version=$(latest_shadowtls_version)
    stls_url="https://github.com/ihciah/shadow-tls/releases/download/$stls_version/shadow-tls-$stls_arch"
    stls_tmp=$(mktemp -d) || return 1
    say "${CYAN}正在下载 ShadowTLS $stls_version ($stls_arch)...${RESET}"
    say "${YELLOW}下载地址: $stls_url${RESET}"
    if ! curl -fL --retry 2 --connect-timeout 15 "$stls_url" -o "$stls_tmp/shadow-tls"; then
      rm -rf "$stls_tmp"
      return 1
    fi
    [ -s "$stls_tmp/shadow-tls" ] || { rm -rf "$stls_tmp"; return 1; }
    verify_elf_arch "$stls_tmp/shadow-tls" "ShadowTLS" || { rm -rf "$stls_tmp"; return 1; }
    chmod 755 "$stls_tmp/shadow-tls"
    probe_shadowtls_executable "$stls_tmp/shadow-tls" || { rm -rf "$stls_tmp"; return 1; }
    mkdir -p "$INSTALL_DIR"
    mv "$stls_tmp/shadow-tls" "$INSTALL_DIR/shadow-tls" || { rm -rf "$stls_tmp"; return 1; }
    rm -rf "$stls_tmp"
}

stls_meta_file() { echo "$STLS_CONF_DIR/snell-$1.conf"; }

snell_service_for_conf() {
    local stls_conf=$1 stls_port=$2 stls_name
    if [ "$stls_conf" = "$SNELL_CONF_FILE" ]; then
      echo snell
      return 0
    fi
    stls_name=${stls_conf##*/}; stls_name=${stls_name%.conf}
    case "$stls_name" in snell-[0-9]*) echo "$stls_name" ;; *) echo "snell-$stls_port" ;; esac
}

snell_backend_running() {
    local stls_conf=$1 stls_port=$2 stls_service=$3 stls_pid stls_cmdline
    [ -x "/etc/init.d/$stls_service" ] || return 1
    if [ -s "/run/$stls_service.pid" ]; then
      stls_pid=$(cat "/run/$stls_service.pid" 2>/dev/null || true)
      case "$stls_pid" in ''|*[!0-9]*) stls_pid="" ;; esac
      if [ -n "$stls_pid" ] && kill -0 "$stls_pid" 2>/dev/null && [ -r "/proc/$stls_pid/cmdline" ]; then
        stls_cmdline=$(tr '\000' ' ' < "/proc/$stls_pid/cmdline")
        case "$stls_cmdline" in *snell-server*"$stls_conf"*) port_listening "$stls_port" tcp && return 0 ;; esac
      fi
    fi
    for stls_pid in $(pgrep -f -- 'snell-server' 2>/dev/null || true); do
      [ -r "/proc/$stls_pid/cmdline" ] || continue
      stls_cmdline=$(tr '\000' ' ' < "/proc/$stls_pid/cmdline")
      case "$stls_cmdline" in *snell-server*"$stls_conf"*) port_listening "$stls_port" tcp && return 0 ;; esac
    done
    return 1
}

wait_snell_backend() {
    local stls_conf=$1 stls_port=$2 stls_service=$3 stls_attempt=0
    while [ "$stls_attempt" -lt 8 ]; do
      snell_backend_running "$stls_conf" "$stls_port" "$stls_service" && return 0
      sleep 1
      stls_attempt=$((stls_attempt + 1))
    done
    return 1
}

get_all_snell_users() {
    local stls_conf stls_port stls_psk stls_service stls_channel stls_mode stls_seen_main=false
    [ -d "$SNELL_CONF_DIR/users" ] || return 1
    for stls_conf in "$SNELL_CONF_FILE" "$SNELL_CONF_DIR"/users/snell-*.conf; do
      [ -f "$stls_conf" ] || continue
      if [ "${stls_conf##*/}" = snell-main.conf ]; then
        $stls_seen_main && continue
        stls_seen_main=true
      fi
      stls_port=$(conf_port "$stls_conf"); stls_psk=$(conf_value psk "$stls_conf")
      [ -n "$stls_port" ] && [ -n "$stls_psk" ] || continue
      stls_service=$(snell_service_for_conf "$stls_conf" "$stls_port")
      stls_channel=$(conf_channel "$stls_conf"); [ -n "$stls_channel" ] || stls_channel=v4
      stls_mode=$(conf_value mode "$stls_conf"); [ -n "$stls_mode" ] || stls_mode=default
      printf '%s|%s|%s|%s|%s|%s\n' "$stls_port" "$stls_psk" "$stls_conf" "$stls_service" "$stls_channel" "$stls_mode"
    done
}

build_snell_selection_file() {
    local stls_out=$1 stls_only_new=$2 stls_line stls_port
    : > "$stls_out"
    get_all_snell_users | while IFS= read -r stls_line; do
      stls_port=${stls_line%%|*}
      if [ "$stls_only_new" = true ] && { [ -f "$(stls_meta_file "$stls_port")" ] || [ -x "/etc/init.d/shadowtls-snell-$stls_port" ]; }; then
        continue
      fi
      printf '%s\n' "$stls_line"
    done > "$stls_out"
    [ -s "$stls_out" ]
}

any_snell_backend_running() {
    local stls_line stls_port stls_rest stls_psk stls_conf stls_service
    while IFS= read -r stls_line; do
      stls_port=${stls_line%%|*}; stls_rest=${stls_line#*|}; stls_psk=${stls_rest%%|*}; stls_rest=${stls_rest#*|}
      stls_conf=${stls_rest%%|*}; stls_rest=${stls_rest#*|}; stls_service=${stls_rest%%|*}
      snell_backend_running "$stls_conf" "$stls_port" "$stls_service" && return 0
    done
    return 1
}

write_shadowtls_openrc() {
    local stls_backend=$1 stls_listen=$2 stls_tls=$3 stls_password=$4 stls_wildcard=$5 stls_svc stls_args
    enable_tcp_fastopen
    stls_svc="shadowtls-snell-$stls_backend"
    stls_args="--fastopen --v3 server --listen ::0:$stls_listen --server 127.0.0.1:$stls_backend --tls $stls_tls --password $stls_password"
    [ "$stls_wildcard" = authed ] && stls_args="$stls_args --wildcard-sni authed"
    cat > "/etc/init.d/$stls_svc" <<EOF
#!/sbin/openrc-run
name="Shadow-TLS Server Service for Snell (Port: $stls_backend)"
command="$INSTALL_DIR/shadow-tls"
command_args="$stls_args"
command_background=true
pidfile="/run/$stls_svc.pid"
output_log="/var/log/$stls_svc.log"
error_log="/var/log/$stls_svc.log"
export RUST_BACKTRACE=1 RUST_LOG=info MONOIO_FORCE_LEGACY_DRIVER=1
depend() { need net; after firewall; }
EOF
    touch "/var/log/$stls_svc.log"; chmod 640 "/var/log/$stls_svc.log"
    chmod 755 "/etc/init.d/$stls_svc"
    enable_openrc_service "$stls_svc"
}

prompt_shadowtls_credentials() {
    local stls_wc
    STLS_PASSWORD=$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
    printf '请输入 TLS 伪装域名 (直接回车默认为 www.microsoft.com): '
    read -r STLS_TLS_DOMAIN || return 1
    [ -n "$STLS_TLS_DOMAIN" ] || STLS_TLS_DOMAIN=www.microsoft.com
    STLS_WILDCARD=off
    say "${YELLOW}是否开启 wildcard-sni=authed？${RESET}\n开启后已通过密码验证的客户端可使用与服务端不一致的伪装域名（SNI）"
    printf '开启 wildcard-sni=authed? [y/N]: '; read -r stls_wc || return 1
    case "$stls_wc" in y|Y|yes|YES) STLS_WILDCARD=authed; say "${GREEN}已开启 wildcard-sni=authed${RESET}" ;; *) say "${GREEN}保持默认（关闭 wildcard-sni）${RESET}" ;; esac
}

restore_snell_backup() {
    local stls_backup=$1 stls_conf=$2 stls_service=$3
    [ -n "$stls_backup" ] && [ -f "$stls_backup" ] || return 0
    cp -a "$stls_backup" "$stls_conf" || return 1
    rc-service "$stls_service" restart >/dev/null 2>&1 || rc-service "$stls_service" start >/dev/null 2>&1 || true
}

restrict_snell_to_loopback() {
    local stls_port=$1 stls_conf=$2 stls_service=$3
    RESTRICT_SNELL_BACKUP=""
    [ -f "$stls_conf" ] || { say "${RED}未找到 Snell 端口 $stls_port 对应的配置文件。${RESET}"; return 1; }
    [ -x "/etc/init.d/$stls_service" ] || { say "${RED}未找到 Snell 端口 $stls_port 对应的 OpenRC 服务 $stls_service。${RESET}"; return 1; }
    if ! grep -Eq "^[[:space:]]*listen[[:space:]]*=[[:space:]]*127\\.0\\.0\\.1:$stls_port[[:space:]]*$" "$stls_conf"; then
      mkdir -p "$STATE_DIR/backups"
      RESTRICT_SNELL_BACKUP="$STATE_DIR/backups/$(basename "$stls_conf").$(date +%Y%m%d%H%M%S).$$"
      cp -a "$stls_conf" "$RESTRICT_SNELL_BACKUP" || return 1
      sed -i "s|^[[:space:]]*listen[[:space:]]*=.*:$stls_port[[:space:]]*$|listen = 127.0.0.1:$stls_port|" "$stls_conf"
      if ! grep -Eq "^[[:space:]]*listen[[:space:]]*=[[:space:]]*127\\.0\\.0\\.1:$stls_port[[:space:]]*$" "$stls_conf"; then
        restore_snell_backup "$RESTRICT_SNELL_BACKUP" "$stls_conf" "$stls_service"
        say "${RED}修改 Snell 监听地址失败: $stls_conf${RESET}"
        return 1
      fi
    else
      say "${GREEN}Snell 端口 $stls_port 已仅监听 127.0.0.1${RESET}"
    fi
    if ! rc-service "$stls_service" restart >/dev/null 2>&1 && ! rc-service "$stls_service" start >/dev/null 2>&1; then
      restore_snell_backup "$RESTRICT_SNELL_BACKUP" "$stls_conf" "$stls_service"
      say "${RED}Snell 服务 $stls_service 重启失败。${RESET}"
      return 1
    fi
    if ! wait_snell_backend "$stls_conf" "$stls_port" "$stls_service"; then
      restore_snell_backup "$RESTRICT_SNELL_BACKUP" "$stls_conf" "$stls_service"
      say "${RED}Snell 改为回环监听后未通过真实进程/TCP 端口检查，已恢复原配置。${RESET}"
      return 1
    fi
    say "${GREEN}✓ Snell $stls_service 真实进程存在，TCP $stls_port 正在监听。${RESET}"
}

configure_shadowtls_backend() {
    local stls_port=$1 stls_psk=$2 stls_conf=$3 stls_service=$4 stls_channel=$5 stls_mode=$6
    local stls_tls=$7 stls_password=$8 stls_wildcard=$9 stls_listen stls_svc stls_meta
    say "\n${YELLOW}为 Snell 端口 $stls_port 配置 ShadowTLS${RESET}"
    ask_available_port '请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): ' || return 1
    stls_listen=$AVAILABLE_PORT
    say "${GREEN}将使用端口: $stls_listen${RESET}"
    snell_backend_running "$stls_conf" "$stls_port" "$stls_service" || {
      say "${RED}Snell 端口 $stls_port 的真实进程或 TCP 监听不存在，拒绝创建 ShadowTLS。${RESET}"
      return 1
    }
    restrict_snell_to_loopback "$stls_port" "$stls_conf" "$stls_service" || return 1
    stls_svc="shadowtls-snell-$stls_port"; stls_meta=$(stls_meta_file "$stls_port")
    if ! write_shadowtls_openrc "$stls_port" "$stls_listen" "$stls_tls" "$stls_password" "$stls_wildcard"; then
      rc-update del "$stls_svc" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/$stls_svc"
      restore_snell_backup "$RESTRICT_SNELL_BACKUP" "$stls_conf" "$stls_service"
      say "${RED}ShadowTLS 自启动注册失败，已恢复 Snell 原配置。${RESET}"
      return 1
    fi
    if ! rc-service "$stls_svc" restart >/dev/null 2>&1 && ! rc-service "$stls_svc" start >/dev/null 2>&1; then
      rc-update del "$stls_svc" default >/dev/null 2>&1 || true; rm -f "/etc/init.d/$stls_svc"
      restore_snell_backup "$RESTRICT_SNELL_BACKUP" "$stls_conf" "$stls_service"
      say "${RED}ShadowTLS 服务启动失败，已恢复 Snell 原配置。${RESET}"
      tail -n 30 "/var/log/$stls_svc.log" 2>/dev/null || true
      return 1
    fi
    if ! wait_until_ready shadowtls "$stls_port" "$stls_listen" tcp; then
      say "${RED}ShadowTLS 未通过真实运行检查：进程或 TCP 监听端口 $stls_listen 不存在。${RESET}"
      rc-service "$stls_svc" status 2>&1 || true; tail -n 30 "/var/log/$stls_svc.log" 2>/dev/null || true
      rc-service "$stls_svc" stop >/dev/null 2>&1 || true; rc-update del "$stls_svc" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/$stls_svc" "$stls_meta"
      restore_snell_backup "$RESTRICT_SNELL_BACKUP" "$stls_conf" "$stls_service"
      say "${YELLOW}已删除失败的 ShadowTLS 服务并恢复 Snell 原配置。${RESET}"
      return 1
    fi
    mkdir -p "$STLS_CONF_DIR"
    {
      echo "backend_port=$stls_port"; echo "listen_port=$stls_listen"; echo "tls_domain=$stls_tls"
      echo "password=$stls_password"; echo "wildcard_sni=$stls_wildcard"; echo "snell_conf=$stls_conf"
      echo "snell_service=$stls_service"; echo "snell_channel=$stls_channel"; echo "snell_mode=$stls_mode"
    } > "$stls_meta"
    chmod 600 "$stls_meta"
    close_port "$stls_port" tcp; close_port "$stls_port" udp; open_port "$stls_listen" tcp
    say "${GREEN}✓ ShadowTLS 真实进程存在，TCP $stls_listen 正在监听。${RESET}"
}

configure_selected_snell_ports() {
    local stls_list_file=$1 stls_selection_kind=${2:-all} stls_count stls_choice stls_line stls_index=0
    local stls_port stls_rest stls_psk stls_conf stls_service stls_channel stls_mode
    stls_count=$(wc -l < "$stls_list_file" | tr -d ' ')
    if [ "$stls_selection_kind" = new ]; then
      say "\n${YELLOW}未配置 ShadowTLS 的 Snell 端口列表：${RESET}"
    else
      say "\n${YELLOW}当前的 Snell 端口列表：${RESET}"
    fi
    awk -F'|' -v main="$SNELL_CONF_FILE" '{printf "\033[0;32m%d. %s%s\033[0m\n", NR, $1, ($3==main ? " (主用户)" : "")}' "$stls_list_file"
    if [ "$stls_selection_kind" = new ]; then
      say "\n${YELLOW}请选择要配置的端口：${RESET}\n1-${stls_count}. 选择单个端口\n0. 为所有未配置端口配置 ShadowTLS"
    else
      say "\n${YELLOW}请选择要配置的端口：${RESET}\n1-${stls_count}. 选择单个端口\n0. 为所有端口配置 ShadowTLS"
    fi
    printf '请选择: '; read -r stls_choice || return 1
    case "$stls_choice" in ''|*[!0-9]*) say "${RED}无效的选择${RESET}"; return 1 ;; esac
    if [ "$stls_choice" -eq 0 ]; then
      stls_choice=all
    elif [ "$stls_choice" -lt 1 ] || [ "$stls_choice" -gt "$stls_count" ]; then
      say "${RED}无效的选择${RESET}"; return 1
    fi
    # 端口列表固定从 fd 3 读取，保留标准输入给循环内部的交互提示。
    # 若把整个 while 的 stdin 重定向到列表文件，ShadowTLS 端口的 read
    # 会继承该文件并在 EOF 时直接返回上级菜单。
    while IFS= read -r stls_line <&3; do
      stls_index=$((stls_index + 1))
      [ "$stls_choice" = all ] || [ "$stls_index" -eq "$stls_choice" ] || continue
      stls_port=${stls_line%%|*}; stls_rest=${stls_line#*|}; stls_psk=${stls_rest%%|*}; stls_rest=${stls_rest#*|}
      stls_conf=${stls_rest%%|*}; stls_rest=${stls_rest#*|}; stls_service=${stls_rest%%|*}; stls_rest=${stls_rest#*|}
      stls_channel=${stls_rest%%|*}; stls_mode=${stls_rest#*|}
      configure_shadowtls_backend "$stls_port" "$stls_psk" "$stls_conf" "$stls_service" "$stls_channel" "$stls_mode" "$STLS_TLS_DOMAIN" "$STLS_PASSWORD" "$STLS_WILDCARD" || return 1
      [ "$stls_choice" = all ] || break
    done 3< "$stls_list_file"
}

install_shadowtls() {
    local stls_users stls_protocol
    say "${CYAN}正在安装 ShadowTLS...${RESET}"
    stls_users=$(mktemp) || return 1
    build_snell_selection_file "$stls_users" false || { rm -f "$stls_users"; say "${RED}未检测到有效的 Snell 配置，请先安装 Snell。${RESET}"; return 1; }
    if ! any_snell_backend_running < "$stls_users"; then
      rm -f "$stls_users"
      say "${RED}检测到 Snell 配置，但没有任何 Snell 真实进程及 TCP 监听，请先修复 Snell。${RESET}"
      return 1
    fi
    say "${GREEN}检测到已安装且正在运行的 Snell${RESET}"
    install_shadowtls_binary || { rm -f "$stls_users"; say "${RED}ShadowTLS 下载或执行测试失败。${RESET}"; return 1; }
    prompt_shadowtls_credentials || { rm -f "$stls_users"; return 1; }
    while :; do
      say "\n${YELLOW}请选择要配置的协议：${RESET}\n1. 为 Shadowsocks 配置 ShadowTLS\n2. 为 Snell 配置 ShadowTLS\n3. 为两者都配置 ShadowTLS\n0. 退出"
      printf '请选择 [0-3]: '; read -r stls_protocol || { rm -f "$stls_users"; return 1; }
      case "$stls_protocol" in
        0) rm -f "$stls_users"; return 0 ;;
        1) say "${RED}未安装 Shadowsocks${RESET}" ;;
        2) break ;;
        3) say "${RED}需要同时安装 Shadowsocks 和 Snell；本低空间脚本只管理 Snell。${RESET}" ;;
        *) say "${RED}无效的选择${RESET}" ;;
      esac
    done
    say "\n${YELLOW}配置 Snell 的 ShadowTLS...${RESET}"
    configure_selected_snell_ports "$stls_users" all || { rm -f "$stls_users"; return 1; }
    rm -f "$stls_users"
    say "\n${GREEN}=== ShadowTLS 安装成功 ===${RESET}"
    show_shadowtls_config
    say "\n${GREEN}服务已启动并设置为开机自启${RESET}"
}

load_stls_meta() {
    local stls_file=$1 stls_main_port
    STLS_META_BACKEND=$(sed -n 's/^backend_port=//p' "$stls_file")
    STLS_META_LISTEN=$(sed -n 's/^listen_port=//p' "$stls_file")
    STLS_META_TLS=$(sed -n 's/^tls_domain=//p' "$stls_file")
    STLS_META_PASSWORD=$(sed -n 's/^password=//p' "$stls_file")
    STLS_META_CONF=$(sed -n 's/^snell_conf=//p' "$stls_file")
    STLS_META_SERVICE=$(sed -n 's/^snell_service=//p' "$stls_file")
    STLS_META_CHANNEL=$(sed -n 's/^snell_channel=//p' "$stls_file")
    STLS_META_MODE=$(sed -n 's/^snell_mode=//p' "$stls_file")
    if [ -z "$STLS_META_CONF" ]; then
      stls_main_port=$(conf_port "$SNELL_CONF_FILE" 2>/dev/null || true)
      if [ "$STLS_META_BACKEND" = "$stls_main_port" ]; then STLS_META_CONF=$SNELL_CONF_FILE; else STLS_META_CONF="$SNELL_CONF_DIR/users/snell-$STLS_META_BACKEND.conf"; fi
    fi
    [ -n "$STLS_META_SERVICE" ] || STLS_META_SERVICE=$(snell_service_for_conf "$STLS_META_CONF" "$STLS_META_BACKEND")
}

show_shadowtls_config() {
    local stls_found=false stls_ip stls_file stls_psk stls_channel stls_mode stls_suffix
    stls_ip=$(public_ip)
    for stls_file in "$STLS_CONF_DIR"/snell-*.conf; do
      [ -f "$stls_file" ] || continue; stls_found=true; load_stls_meta "$stls_file"
      [ -f "$STLS_META_CONF" ] || { say "${RED}Snell 配置不存在: $STLS_META_CONF${RESET}"; continue; }
      stls_psk=$(conf_value psk "$STLS_META_CONF")
      stls_channel=$(conf_channel "$STLS_META_CONF"); [ -n "$stls_channel" ] || stls_channel=${STLS_META_CHANNEL:-v4}
      stls_mode=$(conf_value mode "$STLS_META_CONF"); [ -n "$stls_mode" ] || stls_mode=${STLS_META_MODE:-default}
      say "\n${YELLOW}=== 服务器配置 ===${RESET}\n服务器IP：$stls_ip\n\nSnell 配置：\n  - 端口：$STLS_META_BACKEND\n  - PSK：$stls_psk\n  - 版本：${stls_channel#v}"
      say "\nShadowTLS 配置：\n  - 端口：$STLS_META_LISTEN\n  - 密码：$STLS_META_PASSWORD\n  - SNI：$STLS_META_TLS\n  - 版本：3\n\n${YELLOW}=== Surge 配置 ===${RESET}"
      stls_suffix="reuse = true, tfo = true, shadow-tls-password = $STLS_META_PASSWORD, shadow-tls-sni = $STLS_META_TLS, shadow-tls-version = 3"
      case "$stls_channel" in
        v6) say "Snell + ShadowTLS (v6) = snell, $stls_ip, $STLS_META_LISTEN, psk = $stls_psk, version = 6, mode = $stls_mode, $stls_suffix" ;;
        v5) say "Snell + ShadowTLS (v4) = snell, $stls_ip, $STLS_META_LISTEN, psk = $stls_psk, version = 4, $stls_suffix"; say "Snell + ShadowTLS (v5) = snell, $stls_ip, $STLS_META_LISTEN, psk = $stls_psk, version = 5, $stls_suffix" ;;
        *) say "Snell + ShadowTLS (v4) = snell, $stls_ip, $STLS_META_LISTEN, psk = $stls_psk, version = 4, $stls_suffix" ;;
      esac
    done
    $stls_found || say "${RED}ShadowTLS 未安装。${RESET}"
}

add_shadowtls_config() {
    local stls_users stls_choice
    say "${CYAN}新增 ShadowTLS 配置...${RESET}"
    [ -x "$INSTALL_DIR/shadow-tls" ] || { say "${RED}ShadowTLS 尚未安装，请先选择“安装 ShadowTLS”。${RESET}"; return 1; }
    probe_shadowtls_executable "$INSTALL_DIR/shadow-tls" || return 1
    stls_users=$(mktemp) || return 1
    build_snell_selection_file "$stls_users" true || { rm -f "$stls_users"; say "${YELLOW}所有 Snell 端口都已配置 ShadowTLS${RESET}"; return 0; }
    say "${GREEN}检测到已安装 Snell${RESET}"
    while :; do
      say "\n${YELLOW}请选择要新增配置的协议：${RESET}\n2. 为 Snell 新增 ShadowTLS 配置\n0. 返回"
      printf '请选择: '; read -r stls_choice || { rm -f "$stls_users"; return 1; }
      case "$stls_choice" in 0) rm -f "$stls_users"; return 0 ;; 2) break ;; *) say "${RED}无效的选择${RESET}" ;; esac
    done
    prompt_shadowtls_credentials || { rm -f "$stls_users"; return 1; }
    configure_selected_snell_ports "$stls_users" new || { rm -f "$stls_users"; return 1; }
    rm -f "$stls_users"
    show_shadowtls_config
    say "\n${GREEN}新增配置完成${RESET}"
}

uninstall_shadowtls() {
    local stls_file stls_svc
    for stls_file in "$STLS_CONF_DIR"/snell-*.conf; do
      [ -f "$stls_file" ] || continue; load_stls_meta "$stls_file"; stls_svc="shadowtls-snell-$STLS_META_BACKEND"
      rc-service "$stls_svc" stop >/dev/null 2>&1 || true; rc-update del "$stls_svc" default >/dev/null 2>&1 || true
      rm -f "/etc/init.d/$stls_svc" "$stls_file"; close_port "$STLS_META_LISTEN" tcp
    done
    rm -f "$INSTALL_DIR/shadow-tls"
    say "${GREEN}ShadowTLS 已成功卸载。${RESET}"
    say "${YELLOW}为保持与上游脚本一致，Snell 仍保留 127.0.0.1 监听；若要恢复直连，请重新安装 Snell。${RESET}"
}

restart_all() {
    local stls_file stls_svc p
    if [ -x /etc/init.d/snell ]; then
      rc-service snell restart >/dev/null 2>&1 || rc-service snell start >/dev/null 2>&1 || true
      p=$(conf_port "$SNELL_CONF_FILE" 2>/dev/null)
      if [ -n "$p" ] && wait_snell_backend "$SNELL_CONF_FILE" "$p" snell; then
        open_port "$p" tcp; open_port "$p" udp
        say "${GREEN}✓ Snell 进程和 TCP 端口 $p 均在运行。${RESET}"
      else
        say "${RED}✗ Snell 重启后未检测到真实进程或监听端口。${RESET}"
      fi
    fi
    for stls_file in "$STLS_CONF_DIR"/snell-*.conf; do
      [ -f "$stls_file" ] || continue
      load_stls_meta "$stls_file"; stls_svc="shadowtls-snell-$STLS_META_BACKEND"
      rc-service "$stls_svc" restart >/dev/null 2>&1 || rc-service "$stls_svc" start >/dev/null 2>&1 || true
      if wait_until_ready shadowtls "$STLS_META_BACKEND" "$STLS_META_LISTEN" tcp; then
        open_port "$STLS_META_LISTEN" tcp
        say "${GREEN}✓ $stls_svc 进程和 TCP 端口 $STLS_META_LISTEN 均在运行。${RESET}"
      else
        say "${RED}✗ $stls_svc 重启后未检测到真实进程或监听端口。${RESET}"
      fi
    done
}

status_all() {
    local stls_file stls_found=false p channels
    say "${CYAN}=============== 服务状态检查 ===============${RESET}"
    channels=$(installed_snell_channels)
    [ -n "$channels" ] && say "${GREEN}已安装 Snell 通道: $channels${RESET}" || true
    if [ -x /etc/init.d/snell ] && [ -f "$SNELL_CONF_FILE" ]; then
      p=$(conf_port "$SNELL_CONF_FILE")
      if openrc_service_enabled snell; then say "${GREEN}Snell：已注册 OpenRC default 自启动。${RESET}"; else say "${RED}Snell：未正确注册 OpenRC default 自启动。${RESET}"; fi
      if snell_backend_running "$SNELL_CONF_FILE" "$p" snell; then
        say "${GREEN}Snell：运行中；进程存在；TCP $p 正在监听。${RESET}"
        port_listening "$p" udp && say "${GREEN}Snell：UDP $p 正在监听。${RESET}" || say "${YELLOW}Snell：未检测到 UDP $p 监听。${RESET}"
      else
        say "${RED}Snell：已安装，但真实进程或 TCP $p 监听不存在。${RESET}"
      fi
      rc-service snell status 2>&1 || true
    else
      say "${YELLOW}Snell 未安装${RESET}"
    fi
    for stls_file in "$STLS_CONF_DIR"/snell-*.conf; do
      [ -f "$stls_file" ] || continue; stls_found=true; load_stls_meta "$stls_file"
      if openrc_service_enabled "shadowtls-snell-$STLS_META_BACKEND"; then
        say "${GREEN}ShadowTLS：后端 $STLS_META_BACKEND 已注册 OpenRC default 自启动。${RESET}"
      else
        say "${RED}ShadowTLS：后端 $STLS_META_BACKEND 未正确注册 OpenRC default 自启动。${RESET}"
      fi
      if shadowtls_running "$STLS_META_BACKEND" "$STLS_META_LISTEN" && port_listening "$STLS_META_LISTEN" tcp; then
        say "${GREEN}ShadowTLS：端口 $STLS_META_LISTEN 运行中，后端 Snell $STLS_META_BACKEND。${RESET}"
      else
        say "${RED}ShadowTLS：配置存在，但进程或 TCP $STLS_META_LISTEN 监听不存在。${RESET}"
      fi
      rc-service "shadowtls-snell-$STLS_META_BACKEND" status 2>&1 || true
    done
    $stls_found || say "${YELLOW}ShadowTLS 未安装${RESET}"
    bbr_status
    du -sh "$GLIBC_DIR" "$STATE_DIR" 2>/dev/null || true
}

bbr_status() {
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unavailable)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unavailable)
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo unavailable)
    if [ "$qdisc" = fq ] && [ "$cc" = bbr ]; then
      say "${GREEN}BBR：已生效（tcp_congestion_control=bbr，default_qdisc=fq）。${RESET}"
    else
      say "${YELLOW}BBR：未完全生效（tcp_congestion_control=$cc，default_qdisc=$qdisc）。${RESET}"
    fi
    say "${YELLOW}内核可用拥塞控制: $available${RESET}"
}

enable_bbr_fq() {
    mkdir -p /etc/sysctl.d "$STATE_DIR"
    if command -v modprobe >/dev/null 2>&1; then
      modprobe tcp_bbr >/dev/null 2>&1 || true
      modprobe sch_fq >/dev/null 2>&1 || true
    fi
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    case " $available " in
      *' bbr '*) ;;
      *)
        say "${RED}当前内核没有提供 BBR。若这是受限容器，必须在宿主机设置；若是 VPS，请确认内核 >= 4.9 且包含 tcp_bbr。${RESET}"
        bbr_status
        return 1
        ;;
    esac
    cat > /etc/sysctl.d/99-bbr-fq.conf <<'EOF'
# Managed by snell-alpine-lowspace.sh
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    touch /etc/modules
    grep -qxF tcp_bbr /etc/modules 2>/dev/null || printf '%s\n' tcp_bbr >> /etc/modules
    rc-update add modules boot >/dev/null 2>&1 || true
    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [ "$qdisc" = fq ] && [ "$cc" = bbr ]; then
      say "${GREEN}✓ 标准 BBR + fq 已写入持久配置并在当前内核生效。${RESET}"
      return 0
    fi
    say "${RED}配置文件已写入，但当前内核拒绝应用 BBR + fq。容器环境通常需要在宿主机设置。${RESET}"
    bbr_status
    return 1
}

bbr_menu() {
    while :; do
      say "\n${CYAN}BBR 管理菜单${RESET}\n${GREEN}1.${RESET} 启用/修复标准 BBR + fq\n${GREEN}2.${RESET} 查看当前状态\n${GREEN}3.${RESET} 返回上级菜单"
      printf '请选择操作 [1-3]: '; read -r c || return
      case "$c" in 1) enable_bbr_fq ;; 2) bbr_status ;; 3) return ;; *) say "${RED}无效的选择${RESET}" ;; esac
    done
}

uninstall_snell() {
    printf '卸载 Snell 也会卸载对应的 ShadowTLS，确认继续? [y/N]: '; read -r c || return
    case "$c" in y|Y|yes|YES) ;; *) say "${YELLOW}已取消。${RESET}"; return ;; esac
    uninstall_shadowtls
    p=""; [ -f "$SNELL_CONF_FILE" ] && p=$(conf_port "$SNELL_CONF_FILE")
    rc-service snell stop >/dev/null 2>&1 || true; rc-update del snell default >/dev/null 2>&1 || true
    rm -f /etc/init.d/snell "$INSTALL_DIR/snell-server" "$INSTALL_DIR"/snell-server-v4 "$INSTALL_DIR"/snell-server-v5 "$INSTALL_DIR"/snell-server-v6
    remove_owned_loader_link
    rm -rf "$SNELL_CONF_DIR" "$STATE_DIR" "$GLIBC_DIR"
    [ -n "$p" ] && { close_port "$p" tcp; close_port "$p" udp; }
    say "${GREEN}Snell 已成功卸载。${RESET}"
}

shadowtls_menu() {
    while :; do
      say "\n${CYAN}ShadowTLS 管理菜单${RESET}\n${YELLOW}1. 安装 ShadowTLS${RESET}\n${YELLOW}2. 卸载 ShadowTLS${RESET}\n${YELLOW}3. 查看配置${RESET}\n${YELLOW}4. 新增配置${RESET}\n${YELLOW}5. 重启服务${RESET}\n${YELLOW}6. 返回上级菜单${RESET}\n${YELLOW}0. 退出${RESET}"
      printf '请选择操作 [0-6]: '; read -r c || return
      case "$c" in 1) install_shadowtls ;; 2) uninstall_shadowtls ;; 3) show_shadowtls_config ;;
        4) add_shadowtls_config ;; 5) restart_all ;; 6) return ;; 0) exit 0 ;; *) say "${RED}无效的选择${RESET}" ;; esac
    done
}

show_menu() {
    command -v clear >/dev/null 2>&1 && clear || true
    say "${CYAN}============================================${RESET}"
    say "${CYAN} Snell + ShadowTLS Alpine 低空间脚本 v$VERSION${RESET}"
    say "${CYAN}============================================${RESET}"
    if [ -x /etc/init.d/snell ] && [ -f "$SNELL_CONF_FILE" ]; then
      p=$(conf_port "$SNELL_CONF_FILE")
      if snell_backend_running "$SNELL_CONF_FILE" "$p" snell; then
        say "${GREEN}Snell 已安装：真实进程运行中，TCP $p 正在监听${RESET}"
      else
        say "${RED}Snell 已安装：进程或 TCP $p 监听异常${RESET}"
      fi
    else
      say "${YELLOW}Snell 未安装${RESET}"
    fi
    channels=$(installed_snell_channels)
    [ -n "$channels" ] && say "${GREEN}已落盘 Snell 通道: $channels${RESET}" || true
    stls_total=0; stls_running=0
    for f in "$STLS_CONF_DIR"/snell-*.conf; do
      [ -f "$f" ] || continue; stls_total=$((stls_total + 1)); load_stls_meta "$f"
      if shadowtls_running "$STLS_META_BACKEND" "$STLS_META_LISTEN" && port_listening "$STLS_META_LISTEN" tcp; then stls_running=$((stls_running + 1)); fi
    done
    if [ "$stls_total" -gt 0 ]; then
      if [ "$stls_running" -eq "$stls_total" ]; then
        say "${GREEN}ShadowTLS 已安装：运行中 $stls_running/$stls_total${RESET}"
      else
        say "${RED}ShadowTLS 已安装：运行中 $stls_running/$stls_total，存在异常${RESET}"
      fi
    else
      say "${YELLOW}ShadowTLS 未安装${RESET}"
    fi
    say "\n${YELLOW}=== 基础功能 ===${RESET}\n${GREEN}1.${RESET} 安装 Snell\n${GREEN}2.${RESET} 卸载 Snell\n${GREEN}3.${RESET} 查看配置\n${GREEN}4.${RESET} 重启服务"
    say "\n${YELLOW}=== 增强功能 ===${RESET}\n${GREEN}5.${RESET} ShadowTLS 管理\n${GREEN}6.${RESET} BBR + fq 管理"
    say "\n${YELLOW}=== 系统功能 ===${RESET}\n${GREEN}8.${RESET} 更新当前 Snell 通道\n${GREEN}10.${RESET} 查看服务状态\n${GREEN}0.${RESET} 退出脚本"
    say "${CYAN}============================================${RESET}"
    printf '请输入选项 [0-10]: '; read -r num || exit 0
}

main() {
    check_environment; ensure_base_packages; refresh_managed_openrc_services
    while :; do
      show_menu
      case "$num" in
        1) install_snell ;; 2) uninstall_snell ;; 3) view_snell_config ;; 4) restart_all ;;
        5) shadowtls_menu ;; 6) bbr_menu ;;
        8) [ -f "$SNELL_CONF_FILE" ] && install_snell_binary "$(conf_channel "$SNELL_CONF_FILE")" && restart_all || say "${RED}Snell 未安装或更新失败。${RESET}" ;;
        10) status_all ;; 0) say "${GREEN}感谢使用，再见！${RESET}"; exit 0 ;;
        *) say "${RED}请输入菜单中存在的选项。${RESET}" ;;
      esac
      pause
    done
}

if [ "${SNELL_LOWSPACE_LIB_ONLY:-0}" != "1" ]; then
    main "$@"
fi
