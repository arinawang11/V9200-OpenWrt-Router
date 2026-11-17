#!/bin/sh
# watchdog.sh —— 幂等守护：保证 NAT 与网络通道在容器重建后自动恢复
#
# 设计: 每轮都对目标状态做"收敛"，而不是"检查失败才修"。所有子脚本本身幂等，
#       所以直接重放不会产生副作用。容器重建、netns 失效、进程被杀都能自愈。
#
# 用法: watchdog.sh [--once]
#       默认 daemon 模式，每 $WATCHDOG_INTERVAL 秒一轮

DIR=$(dirname "$0")
INTERVAL=${WATCHDOG_INTERVAL:-15}
LOG=${WATCHDOG_LOG:-$DATA/logs/watchdog.log}

mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"
}

round() {
    # 1. 通道重建（幂等）
    if ! sh "$DIR/setup-host.sh" >/dev/null 2>&1; then
        log "setup-host 失败"
    fi

    # 2. NAT 拉起（幂等：已运行直接返回）
    OUT=$(sh "$DIR/nat-up.sh" 2>&1)
    case "$OUT" in
        *"已启动"*|"") : ;;
        *) log "nat-up: $OUT" ;;
    esac

    # 3. dnsmasq（幂等）
    if [ -x "$DIR/dnsmasq-up.sh" ]; then
        sh "$DIR/dnsmasq-up.sh" >/dev/null 2>&1 || log "dnsmasq-up 失败"
    fi
}

if [ "$1" = "--once" ]; then
    round
    exit 0
fi

log "watchdog 启动, 间隔 ${INTERVAL}s"
while :; do
    round
    sleep "$INTERVAL"
done
