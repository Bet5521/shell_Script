#!/usr/bin/env bash
#
# =============================================================================
#  led_status.sh — 玩客云(OneCloud WS1608) 板载 LED 运行状态指示灯守护脚本
# =============================================================================
#  用途:
#    通过控制板载 LED(优先 RGB 三通道, 单色 LED 自动降级)实时反映设备运行状态,
#    作为后台守护进程持续运行, 无需人工干预:
#      · 通电启动        -> 第一种颜色(默认 蓝)常亮, 表示已上电
#      · 成功联网        -> 第二种颜色(默认 绿)常亮, 表示网络已连接
#      · 有工作负载      -> 在第二种颜色常亮基础上, 第三种颜色(默认 红)闪烁,
#                          闪烁频率随系统负载升高而加快(负载越高闪得越快)
#
#  支持范围:
#    · 架构: ARMv7 (RK3328 / 玩客云 WS1608) 及任意提供 /sys/class/leds 的 Linux
#    · 发行版: 自动探测 systemd(写 service 开机自启), 无 systemd 时退化为 nohup 后台
#    · LED: 自动探测 /sys/class/leds 下 red/green/blue 设备; 单 LED 板自动降级
#
#  功能要点:
#    · 自动探测 通电/联网/负载, 状态机自动切换, 无需人工干预
#    · 负载 = 1 分钟 loadavg / CPU 核数, 归一化后映射到闪烁周期(0.15s~1.2s)
#    · root 权限自动提权(sudo); 改写 systemd unit 前自动备份
#    · 支持 start/stop/restart/status/run/install/uninstall/list-leds
#    · 退出(SIGTERM/SIGINT/正常)清理 LED 状态, 避免常亮卡死
#    · 幂等: PID 文件防止重复启动; 重复 install 安全
#
#  用法示例:
#    sudo ./led_status.sh run            # 前台运行(调试用, Ctrl-C 退出)
#    sudo ./led_status.sh start          # 后台守护进程
#    sudo ./led_status.sh status         # 查看运行状态
#    sudo ./led_status.sh stop           # 停止
#    sudo ./led_status.sh restart        # 重启
#    sudo ./led_status.sh install        # 安装为 systemd 服务并开机自启
#    sudo ./led_status.sh uninstall      # 卸载 systemd 服务
#    sudo ./led_status.sh list-leds      # 列出本机可用 LED 设备
#    # 自定义 LED 设备路径(单色/非标准命名时):
#    sudo LED_BLUE=/sys/class/leds/a/brightness \
#         LED_GREEN=/sys/class/leds/b/brightness \
#         LED_RED=/sys/class/leds/c/brightness ./led_status.sh run
#
#  退出码:
#    0  正常退出
#    1  通用错误
#    2  缺少 root 权限且无法提权
#    3  未找到任何可写 LED 设备
#    4  参数错误
#    5  已在运行(start 时发现已有 PID)
# =============================================================================

# 允许通过环境变量覆盖配置, 否则使用内部默认值
: "${PROG:=led-status}"
: "${PIDFILE:=/run/${PROG}.pid}"
: "${LOGFILE:=/var/log/${PROG}.log}"

# 三种"颜色"对应的 LED sysfs brightness 节点(为空则自动探测)
: "${LED_BLUE:=}"   # 颜色1: 通电常亮(默认蓝)
: "${LED_GREEN:=}"  # 颜色2: 联网常亮(默认绿)
: "${LED_RED:=}"    # 颜色3: 负载闪烁(默认红)

# 轮询/阈值参数(秒)
POLL_NET=3        # 未联网时每 3s 重试检测
POLL_IDLE=2       # 联网空闲时每 2s 复查负载
BUSY_THRESHOLD=0.10   # 归一化负载超过该值视为"有工作负载", 开始闪烁

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# -----------------------------------------------------------------------------
# 日志(彩色, 非 TTY 时自动关闭颜色)
# -----------------------------------------------------------------------------
c_log() {
    local level="$1"; shift
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local color="" reset=""
    if [ -t 2 ]; then
        case "$level" in
            info)  color="\033[0;32m" ;;
            warn)  color="\033[0;33m" ;;
            error) color="\033[0;31m" ;;
        esac
        reset="\033[0m"
    fi
    printf "${color}[%s] %s: %s${reset}\n" "$ts" "$level" "$*" >&2
}

die() {
    c_log error "$1"
    exit "${2:-1}"
}

# -----------------------------------------------------------------------------
# 权限自洽: 非 root 时尝试 sudo 提权(保留参数)
# -----------------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            c_log info "非 root, 自动 sudo 提权..."
            exec sudo "$SCRIPT_PATH" "$@"
        else
            die "需要 root 权限, 且本机无 sudo" 2
        fi
    fi
}

# -----------------------------------------------------------------------------
# LED 底层操作
# -----------------------------------------------------------------------------
led_max() {
    # 读取某 brightness 节点对应的最大亮度(通常为 1 或 255)
    local f="$1"; local d="${f%/*}"
    local m=1
    [ -r "$d/max_brightness" ] && m="$(cat "$d/max_brightness" 2>/dev/null || echo 1)"
    echo "${m:-1}"
}

led_on() {
    local f="$1"; local m; m="$(led_max "$f")"
    echo "$m" > "$f" 2>/dev/null || true
}

led_off() {
    echo 0 > "$1" 2>/dev/null || true
}

led_all_off() {
    led_off "$LED_BLUE"; led_off "$LED_GREEN"; led_off "$LED_RED"
}

# -----------------------------------------------------------------------------
# 自动探测 LED 设备
# -----------------------------------------------------------------------------
detect_leds() {
    if [ -n "$LED_BLUE" ] && [ -n "$LED_GREEN" ] && [ -n "$LED_RED" ]; then
        : # 用户已显式指定, 跳过自动探测
    else
        local blue="" green="" red="" first=""
        for d in /sys/class/leds/*; do
            [ -e "$d/brightness" ] || continue
            first="${first:-$d}"
            local n; n="$(basename "$d" | tr '[:upper:]' '[:lower:]')"
            case "$n" in
                *blue*)  blue="${blue:-$d/brightness}" ;;
                *green*) green="${green:-$d/brightness}" ;;
                *red*)   red="${red:-$d/brightness}" ;;
            esac
        done
        LED_BLUE="${LED_BLUE:-${blue:-$first/brightness}}"
        LED_GREEN="${LED_GREEN:-${green:-$first/brightness}}"
        LED_RED="${LED_RED:-${red:-$first/brightness}}"
    fi

    # 校验可写
    for v in "$LED_BLUE" "$LED_GREEN" "$LED_RED"; do
        if [ ! -w "$v" ]; then
            die "LED 设备不可写: $v (请用 root 运行, 或用 LED_BLUE/GREEN/RED 指定正确路径)" 3
        fi
    done

    # 单色 LED 降级提示
    if [ "$LED_BLUE" = "$LED_GREEN" ] && [ "$LED_GREEN" = "$LED_RED" ]; then
        c_log warn "仅检测到单色 LED, 三种状态将共用同一设备: 通电/联网=常亮, 负载=闪烁 (无法显示真实三色)"
    fi
    c_log info "LED 映射: 通电=${LED_BLUE}  联网=${LED_GREEN}  负载=${LED_RED}"
}

# -----------------------------------------------------------------------------
# 状态探测
# -----------------------------------------------------------------------------
check_network() {
    # 优先 ping 默认网关, 失败则回退到公网 DNS
    local gw
    gw="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
    if [ -n "$gw" ] && ping -c1 -W2 "$gw" >/dev/null 2>&1; then
        return 0
    fi
    ping -c1 -W2 223.5.5.5 >/dev/null 2>&1 && return 0   # 阿里 DNS
    ping -c1 -W2 8.8.8.8   >/dev/null 2>&1 && return 0   # Google DNS
    return 1
}

get_load_index() {
    # 1 分钟 loadavg / CPU 核数 -> 归一化负载(0=空闲, 1=满载, >1=过载)
    local l1 cpu
    l1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
    cpu="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
    [ -z "$cpu" ] || [ "$cpu" -lt 1 ] && cpu=1
    awk -v l="$l1" -v c="$cpu" 'BEGIN{ if (c<1) c=1; printf "%.3f", l/c }'
}

# 负载索引 -> 闪烁 on/off 时长(秒)。负载越高周期越短(闪得越快)
load_to_interval() {
    local load="$1"
    awk -v l="$load" 'BEGIN{
        if (l < 0.10) l = 0.10;
        if (l > 2.0)  l = 2.0;
        n = (l - 0.10) / (2.0 - 0.10);      # 归一化到 0..1
        period = 1.2 - n * (1.2 - 0.15);     # 满周期 1.2s -> 0.15s
        on  = period * 0.5;
        off = period * 0.5;
        printf "%.3f %.3f", on, off;
    }'
}

# -----------------------------------------------------------------------------
# 主监控循环(状态机)
# -----------------------------------------------------------------------------
monitor_loop() {
    c_log info "主监控循环启动 (run 模式可用 Ctrl-C 退出)"
    local state="" load on off
    while true; do
        if ! check_network; then
            if [ "$state" != "powered" ]; then
                led_all_off
                led_on "$LED_BLUE"
                c_log info "[状态] 已上电 · 未联网 -> 蓝灯常亮"
                state="powered"
            fi
            sleep "$POLL_NET"
            continue
        fi

        # 已联网: 绿灯常亮, 关闭蓝灯
        led_off "$LED_BLUE"
        led_on "$LED_GREEN"
        load="$(get_load_index)"

        if awk -v l="$load" -v t="$BUSY_THRESHOLD" 'BEGIN{ exit !(l > t) }'; then
            if [ "$state" != "busy" ]; then
                c_log info "[状态] 联网 · 负载 ${load} -> 绿灯常亮 + 红灯闪烁"
                state="busy"
            fi
            read -r on off < <(load_to_interval "$load")
            led_on "$LED_RED";  sleep "$on"
            led_off "$LED_RED"; sleep "$off"
        else
            if [ "$state" != "net" ]; then
                led_off "$LED_RED"
                c_log info "[状态] 联网 · 空闲(负载 ${load}) -> 绿灯常亮"
                state="net"
            fi
            sleep "$POLL_IDLE"
        fi
    done
}

# -----------------------------------------------------------------------------
# 命令实现
# -----------------------------------------------------------------------------
cmd_run() {
    require_root "$@"
    detect_leds
    echo "$$" > "$PIDFILE" 2>/dev/null || true
    # 仅 run 模式注册清理陷阱(避免 list-leds/install 等短命令误关 LED)
    trap 'led_all_off 2>/dev/null; rm -f "$PIDFILE" 2>/dev/null; c_log info "退出清理完成"; exit 0' INT TERM EXIT
    monitor_loop
}

cmd_start() {
    require_root "$@"
    detect_leds
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        c_log warn "已在运行 (PID $(cat "$PIDFILE"))"
        return 5
    fi
    c_log info "后台启动 $PROG ..."
    nohup "$SCRIPT_PATH" run >"$LOGFILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PIDFILE"
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        c_log info "已启动 PID $pid, 日志: $LOGFILE"
    else
        c_log error "启动失败, 请查看日志: $LOGFILE"
        rm -f "$PIDFILE"
        return 1
    fi
}

cmd_stop() {
    if [ -f "$PIDFILE" ]; then
        local pid; pid="$(cat "$PIDFILE")"
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            local i=0
            while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 5 ]; do
                sleep 1; i=$((i+1))
            done
            kill -9 "$pid" 2>/dev/null || true
            c_log info "已停止 PID $pid"
        fi
        rm -f "$PIDFILE"
    else
        c_log warn "未发现 PID 文件($PIDFILE), 可能未运行"
    fi
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start "$@"
}

cmd_status() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "$PROG 运行中 (PID $(cat "$PIDFILE"))"
        exit 0
    else
        echo "$PROG 未运行"
        exit 1
    fi
}

cmd_install() {
    require_root "$@"
    detect_leds
    if ! command -v systemctl >/dev/null 2>&1; then
        c_log warn "未检测到 systemd, 跳过service安装; 可用 'sudo $SCRIPT_PATH start' 手动后台运行"
        return 0
    fi
    local unit="/etc/systemd/system/${PROG}.service"
    if [ -f "$unit" ]; then
        cp -p "$unit" "${unit}.bak.$(date +%s)" && c_log info "已备份旧 unit -> ${unit}.bak.*"
    fi
    cat > "$unit" <<EOF
[Unit]
Description=OneCloud LED status indicator
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$SCRIPT_PATH run
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$PROG.service"
    c_log info "已安装并启用 $PROG.service (开机自启 + 立即启动)"
}

cmd_uninstall() {
    require_root "$@"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "$PROG.service" 2>/dev/null || true
    fi
    local unit="/etc/systemd/system/${PROG}.service"
    if [ -f "$unit" ]; then
        rm -f "$unit"
        systemctl daemon-reload 2>/dev/null || true
        c_log info "已卸载 $PROG.service"
    fi
    cmd_stop
}

cmd_list_leds() {
    echo "本机可用 LED 设备 (/sys/class/leds):"
    local found=0
    for d in /sys/class/leds/*; do
        [ -e "$d/brightness" ] || continue
        found=1
        local max=0; [ -r "$d/max_brightness" ] && max="$(cat "$d/max_brightness" 2>/dev/null || echo '?')"
        printf "  %-40s max_brightness=%s\n" "$(basename "$d")" "$max"
    done
    [ "$found" -eq 0 ] && echo "  (无, 该设备未暴露 /sys/class/leds)"
}

usage() {
    cat <<EOF
用法: $PROG <命令> [选项]

命令:
  run            前台运行(调试, Ctrl-C 退出)
  start          后台守护进程
  stop           停止
  restart        重启
  status         查看运行状态
  install        安装为 systemd 服务并开机自启
  uninstall      卸载 systemd 服务
  list-leds      列出本机可用 LED 设备
  -h, --help     显示本帮助

环境变量(可选, 用于自定义 LED 路径):
  LED_BLUE / LED_GREEN / LED_RED   对应 通电/联网/负载 三种状态的 brightness 节点
  POLL_NET / POLL_IDLE / BUSY_THRESHOLD   轮询与负载阈值调优
EOF
}

# -----------------------------------------------------------------------------
# 入口
# -----------------------------------------------------------------------------
main() {
    local cmd="${1:-run}"
    case "$cmd" in
        run)            cmd_run "$@" ;;
        start)          cmd_start "$@" ;;
        stop)           cmd_stop ;;
        restart)        cmd_restart "$@" ;;
        status)         cmd_status ;;
        install)        cmd_install "$@" ;;
        uninstall)      cmd_uninstall "$@" ;;
        list-leds)      cmd_list_leds ;;
        -h|--help|help) usage; exit 0 ;;
        *)              c_log error "未知命令: $cmd"; usage; exit 4 ;;
    esac
}

# 仅在作为脚本直接执行时进入 main(被 source 用于测试时不自动运行)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
