#!/bin/sh
# Non-destructive Snell binary test for Alpine Linux.
# It uses a temporary directory and loopback-only test listener.

set -u

VERSION=${1:-v5.0.1}
TEST_PORT=${TEST_PORT:-39127}
TMP_DIR=$(mktemp -d) || exit 1
BIN="$TMP_DIR/snell-server"
ZIP="$TMP_DIR/snell.zip"
CONF="$TMP_DIR/snell.conf"
LOG="$TMP_DIR/snell.log"
PID=""

cleanup() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT HUP INT TERM

section() { printf '\n===== %s =====\n' "$1"; }

case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64; EXPECT_MACHINE=3e00 ;;
    aarch64|arm64) ARCH=aarch64; EXPECT_MACHINE=b700 ;;
    *) printf '不支持的架构: %s\n' "$(uname -m)"; exit 1 ;;
esac
case "$VERSION" in
    v4*) CHANNEL=v4 ;;
    v5*) CHANNEL=v5 ;;
    v6*) CHANNEL=v6 ;;
    *) printf '版本必须以 v4、v5 或 v6 开头，当前为: %s\n' "$VERSION"; exit 1 ;;
esac

for cmd in curl unzip od awk grep sed; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf '缺少命令 %s。请先执行: apk add --no-cache curl unzip\n' "$cmd"
        exit 1
    }
done

section "系统"
printf 'uname: '; uname -a
printf 'Alpine: '; cat /etc/alpine-release 2>/dev/null || echo '不是 Alpine'
printf '架构: %s -> 下载 %s\n' "$(uname -m)" "$ARCH"
printf '可用空间: '; df -h /tmp 2>/dev/null | tail -n 1
printf '/tmp 挂载: '; mount 2>/dev/null | grep ' /tmp ' || echo '未单独挂载'

URL="https://dl.nssurge.com/snell/snell-server-${VERSION}-linux-${ARCH}.zip"
section "下载"
printf 'URL: %s\n' "$URL"
curl -fL --retry 2 "$URL" -o "$ZIP" || exit 1
unzip -oq "$ZIP" -d "$TMP_DIR" || exit 1
[ -f "$BIN" ] || { echo '压缩包中没有 snell-server'; exit 1; }
chmod 755 "$BIN"

section "文件与架构"
ls -l "$BIN"
command -v sha256sum >/dev/null 2>&1 && sha256sum "$BIN" || true
MAGIC=$(od -An -tx1 -N4 "$BIN" | tr -d ' \n')
MACHINE=$(od -An -tx1 -j18 -N2 "$BIN" | tr -d ' \n')
printf 'ELF magic: %s（应为 7f454c46）\n' "$MAGIC"
printf 'ELF machine: %s（当前架构应为 %s）\n' "$MACHINE" "$EXPECT_MACHINE"
[ "$MAGIC" = 7f454c46 ] || { echo '结论：不是 ELF 二进制'; exit 1; }
[ "$MACHINE" = "$EXPECT_MACHINE" ] || { echo '结论：CPU 架构不匹配'; exit 1; }
command -v file >/dev/null 2>&1 && file "$BIN" || echo '可选：apk add --no-cache file'
command -v scanelf >/dev/null 2>&1 && scanelf -i -n "$BIN" || echo '可选：apk add --no-cache pax-utils'

run_option_test() {
    option=$1
    section "直接执行: $option"
    OUTPUT=$(timeout 5 "$BIN" "$option" 2>&1)
    RC=$?
    printf '%s\n' "$OUTPUT"
    printf '退出码: %s\n' "$RC"
}

# These are diagnostics only. Their exit codes are not used as compatibility verdicts.
run_option_test --v
run_option_test -v
run_option_test --help

section "真实启动测试"
if command -v ss >/dev/null 2>&1 && ss -H -lnt 2>/dev/null | grep -Eq "[:.]${TEST_PORT}([[:space:]]|$)"; then
    echo "测试端口 $TEST_PORT 已占用，请这样换一个端口重试："
    echo "TEST_PORT=39128 sh $0 $VERSION"
    exit 1
fi

cat > "$CONF" <<EOF
#version-choice = $CHANNEL
[snell-server]
listen = 127.0.0.1:${TEST_PORT}
psk = AlpineBinaryTest1234
EOF
if [ "$CHANNEL" = v6 ]; then
    printf '%s\n' 'mode = default' 'dns-ip-preference = ipv4-only' >> "$CONF"
else
    printf '%s\n' 'ipv6 = false' >> "$CONF"
fi
printf '%s\n' 'dns = 1.1.1.1' >> "$CONF"

"$BIN" -c "$CONF" >"$LOG" 2>&1 &
PID=$!
sleep 2

PROCESS_OK=false
PORT_OK=unknown
kill -0 "$PID" 2>/dev/null && PROCESS_OK=true
if command -v ss >/dev/null 2>&1; then
    PORT_OK=false
    ss -H -lnt 2>/dev/null | grep -Eq "[:.]${TEST_PORT}([[:space:]]|$)" && PORT_OK=true
elif command -v netstat >/dev/null 2>&1; then
    PORT_OK=false
    netstat -lnt 2>/dev/null | grep -Eq "[:.]${TEST_PORT}([[:space:]]|$)" && PORT_OK=true
fi

printf '测试 PID: %s\n' "$PID"
printf '进程存活: %s\n' "$PROCESS_OK"
printf 'TCP %s 监听: %s\n' "$TEST_PORT" "$PORT_OK"
printf '%s\n' '--- snell 输出 ---'
cat "$LOG"
printf '%s\n' '--- 输出结束 ---'

if $PROCESS_OK && { [ "$PORT_OK" = true ] || [ "$PORT_OK" = unknown ]; }; then
    echo '结论：Snell 二进制能够在本机实际启动。'
    [ "$PORT_OK" = unknown ] && echo '未安装 ss/netstat，建议 apk add --no-cache iproute2 后再确认监听端口。'
    exit 0
fi

echo '结论：Snell 二进制未能在本机实际启动。'
if command -v strace >/dev/null 2>&1; then
    echo '正在生成 /tmp/snell.strace（其中只使用测试配置）...'
    timeout 5 strace -f -o /tmp/snell.strace "$BIN" -c "$CONF" >/dev/null 2>&1 || true
    echo '请保留并检查 /tmp/snell.strace。'
else
    echo '可选深度诊断：apk add --no-cache strace，然后重新运行本脚本。'
fi
exit 1
