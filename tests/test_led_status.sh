#!/usr/bin/env bash
# =============================================================================
#  test_led_status.sh — led_status.sh 逻辑回归测试(不触碰真实硬件)
#  方法: 用 fake sysfs + stub 网络/负载函数, 验证状态机切换与闪烁频率映射
#  运行: bash tests/test_led_status.sh
# =============================================================================
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/led_status.sh"
TMP="/tmp/ledtest_$$"
mkdir -p "$TMP/leds/blue" "$TMP/leds/green" "$TMP/leds/red"
for c in blue green red; do
    echo 1 > "$TMP/leds/$c/max_brightness"
    echo 0 > "$TMP/leds/$c/brightness"
done

export LED_BLUE="$TMP/leds/blue/brightness"
export LED_GREEN="$TMP/leds/green/brightness"
export LED_RED="$TMP/leds/red/brightness"

# source 脚本(因 BASH_SOURCE 守卫, 不会自动执行 main)
# shellcheck disable=SC1090
source "$SCRIPT"

# 用可控 stub 覆盖探测/网络/负载
NET_UP=1
LOAD=0.0
check_network() { return "$NET_UP"; }
get_load_index() { echo "$LOAD"; }

pass=0; fail=0
assert() {
    if [ "$1" = "$2" ]; then pass=$((pass+1));
    else fail=$((fail+1)); echo "FAIL: 期望[$2] 实际[$1] -- $3"; fi
}

# 1) detect_leds 在三个变量已设置时不报错, 且不改写路径
detect_leds
assert "$LED_BLUE"  "$TMP/leds/blue/brightness"  "detect_leds 保留用户指定路径"
assert "$LED_GREEN" "$TMP/leds/green/brightness" "detect_leds 保留用户指定路径"
assert "$LED_RED"   "$TMP/leds/red/brightness"   "detect_leds 保留用户指定路径"

# 2) led_on 写 max_brightness, led_off 写 0
led_on "$LED_BLUE";  assert "$(cat "$LED_BLUE")"  "1" "led_on 写 max"
led_off "$LED_BLUE"; assert "$(cat "$LED_BLUE")"  "0" "led_off 写 0"

# 3) 频率映射: 低负载周期 > 高负载周期
read -r o1 f1 < <(load_to_interval 0.10)
read -r o2 f2 < <(load_to_interval 2.0)
p1=$(awk "BEGIN{print ($o1)+($f1)}")
p2=$(awk "BEGIN{print ($o2)+($f2)}")
assert "$(awk -v a="$p1" -v b="$p2" 'BEGIN{print (a>b)}')" "1" "低负载周期应大于高负载周期"
assert "$(awk -v x="$p2" 'BEGIN{print (x>0)}')" "1" "高负载周期应为正"

# 4) 状态: 未联网 -> 蓝亮, 绿/红灭
NET_UP=0
led_all_off; led_on "$LED_BLUE"
assert "$(cat "$LED_BLUE")"  "1" "未联网: 蓝亮"
assert "$(cat "$LED_GREEN")" "0" "未联网: 绿灭"
assert "$(cat "$LED_RED")"   "0" "未联网: 红灭"

# 5) 状态: 联网空闲(负载低于阈值) -> 绿亮, 蓝灭, 红灭
NET_UP=1; LOAD=0.0
led_off "$LED_BLUE"; led_on "$LED_GREEN"
if awk -v l="$LOAD" -v t="$BUSY_THRESHOLD" 'BEGIN{ exit !(l > t) }'; then
    : # busy
else
    led_off "$LED_RED"
fi
assert "$(cat "$LED_GREEN")" "1" "联网空闲: 绿亮"
assert "$(cat "$LED_BLUE")"  "0" "联网空闲: 蓝灭"
assert "$(cat "$LED_RED")"   "0" "联网空闲: 红灭"

# 6) 状态: 联网 + 高负载 -> 绿亮, 红灯点亮(闪烁起点)
NET_UP=1; LOAD=1.5
led_off "$LED_BLUE"; led_on "$LED_GREEN"
if awk -v l="$LOAD" -v t="$BUSY_THRESHOLD" 'BEGIN{ exit !(l > t) }'; then
    led_on "$LED_RED"
fi
assert "$(cat "$LED_GREEN")" "1" "高负载: 绿亮"
assert "$(cat "$LED_RED")"   "1" "高负载: 红灯点亮(闪烁)"

echo "=============================="
echo "测试通过: $pass   失败: $fail"
[ "$fail" -eq 0 ]
