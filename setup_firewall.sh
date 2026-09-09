#!/usr/bin/env bash
# =============================================================================
#  setup_firewall.sh —— 交互式防火墙配置脚本（多后端统一接口）
#
#  设计模型：入站白名单(INPUT DROP) + 出站放行(OUTPUT ACCEPT，可切严格)
#
#  支持后端（自动探测，按优先级选定）:
#    firewalld  >  ufw  >  nftables  >  iptables
#
#  特性:
#    * 权限自检 + sudo/pkexec/su 自动提权，参数与环境变量不丢失
#    * 防火墙方案自动探测，多方案并存时按明确优先级判定
#    * 统一规则接口：放行 / 封禁 / 删除 / 持久化 在各后端下语义一致且幂等
#    * IPv4 + IPv6 双栈（iptables 双栈、nft 用 inet 表合一、ufw 双栈、
#      firewalld 按 family 下发）
#    * Docker 兼容：不破坏 nat 表 / FORWARD 默认策略 / DOCKER* 链
#    * SSH 防暴力破解（各后端原生实现）
#    * 常用服务预设模板（含 Oracle DB 1521）
#    * 规则文件化 + 备份回滚 + 试运行超时自动回滚
#
#  用法:  bash setup_firewall.sh        （非 root 时自动提权）
#  注意:  远程服务器操作前先确认已放行当前 SSH 连接端口
# =============================================================================

set -uo pipefail
export LC_ALL=C

# ============================================================================
#  第 0 节：权限检测与提权
#  —— 必须放在最前，任何需要 root 的操作之前完成
# ============================================================================

# 提权标记：防止 sudo 后重复提权造成死循环
readonly ELEV_MARK="FW_SETUP_ELEVATED"

root_error_hint() {
    printf '\033[0;31m[ERROR]\033[0m %s\n' "$1" >&2
}

# 检测并提权；非 root 时用 sudo / pkexec / su 重新执行本脚本
ensure_root() {
    [ "$(id -u)" -eq 0 ] && return 0

    # 已经提过一次但仍非 root —— 说明提权链有问题，直接报错退出
    if [ -n "${!ELEV_MARK:-}" ]; then
        root_error_hint "已尝试提权但当前仍非 root（提权未生效），脚本终止。"
        exit 1
    fi

    # 解析脚本真实绝对路径（保证 sudo 后仍能定位到自身）
    local self="${BASH_SOURCE[0]}"
    if command -v readlink >/dev/null 2>&1; then
        local resolved
        resolved="$(readlink -f "$self" 2>/dev/null || true)"
        [ -n "$resolved" ] && self="$resolved"
    fi

    local sudo_bin="" sudo_env=""
    command -v sudo   >/dev/null 2>&1 && sudo_bin="$(command -v sudo)"
    local pkexec_bin=""
    command -v pkexec >/dev/null 2>&1 && pkexec_bin="$(command -v pkexec)"

    if [ -z "$sudo_bin" ] && [ -z "$pkexec_bin" ]; then
        root_error_hint "本脚本需要 root 权限，但系统未安装 sudo 或 pkexec，无法自动提权。"
        root_error_hint "请切换到 root 后重试：  su - root -c 'bash $self'"
        exit 1
    fi

    printf '\033[1;33m[WARN]\033[0m 当前非 root 用户（uid=%s），正在请求提权...\n' "$(id -u)"

    if [ -n "$sudo_bin" ]; then
        # 先做一次认证（需要时会提示输入密码），避免 exec 后错误难以定位
        if ! $sudo_bin -v; then
            root_error_hint "sudo 认证失败或无 sudo 权限，脚本终止。"
            root_error_hint "请改用 root 执行：  su - root -c 'bash $self'"
            exit 1
        fi
        # 探测 sudoers 是否允许保留环境变量（SETENV），不允许则退化但保证不因 -E 直接失败
        if $sudo_bin -n -E true >/dev/null 2>&1; then
            sudo_env="-E"
        fi
        # 用 sudo 内部 env 设置标记：比外部赋值更可靠（不受 env_reset 影响）
        # "$@" 原样透传参数；-E 保留 HTTP_PROXY / SSH_CONNECTION 等环境变量
        $sudo_bin $sudo_env env "${ELEV_MARK}=1" bash "$self" "$@"
        exit $?
    fi

    # pkexec 兜底：不保留环境，但至少能拿到 root
    printf '\033[1;33m[WARN]\033[0m 未找到 sudo，改用 pkexec（可能无法保留全部环境变量）\n'
    $pkexec_bin env "${ELEV_MARK}=1" bash "$self" "$@"
    exit $?
}

ensure_root "$@"

# ============================================================================
#  第 1 节：全局配置与常量
# ============================================================================
readonly SCRIPT_VERSION="2.0.0"
readonly CONF_DIR="/etc/fw-setup"
readonly LEGACY_CONF_DIR="/etc/iptables-setup"
readonly BACKUP_DIR="${CONF_DIR}/backups"
readonly CONFIRM_TIMEOUT=20

# 规则 DSL 文件（统一语义存储，与后端解耦）
readonly F_RULES="${CONF_DIR}/rules.dsl"
readonly F_POLICY="${CONF_DIR}/policy.conf"
readonly F_SSHGUARD="${CONF_DIR}/sshguard.conf"
readonly F_ENV="${CONF_DIR}/env.conf"

# iptables 后端自定义链（统一前缀，避免与 firewalld / Docker 冲突）
readonly C_IN_ALLOW="FW-IN-ALLOW"
readonly C_IN_BLOCK="FW-IN-BLOCK"
readonly C_OUT_ALLOW="FW-OUT-ALLOW"
readonly C_OUT_BLOCK="FW-OUT-BLOCK"
readonly C_SSHGUARD="FW-SSHGUARD"
readonly ALL_IPT_CHAINS=("${C_IN_ALLOW}" "${C_IN_BLOCK}" "${C_OUT_ALLOW}" "${C_OUT_BLOCK}" "${C_SSHGUARD}")

# nftables 后端表/链
readonly NFT_TABLE="fw_setup"
readonly NFT_FAMILY="inet"      # inet 表同时覆盖 IPv4 + IPv6

# 颜色
if [ -t 1 ]; then
    C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'
    C_B='\033[0;34m'; C_C='\033[0;36m'; C_N='\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_C=''; C_N=''
fi

# ============================================================================
#  第 2 节：日志与错误处理
# ============================================================================
log_info() { printf "${C_G}[INFO]${C_N} %s\n" "$*"; }
log_warn() { printf "${C_Y}[WARN]${C_N} %s\n" "$*"; }
log_err()  { printf "${C_R}[ERROR]${C_N} %s\n" "$*" >&2; }
log_step() { printf "${C_C}==>${C_N} %s\n" "$*"; }
hr()       { printf '%s\n' "---------------------------------------------------------------"; }

# 终止执行并输出可定位信息
die() {
    log_err "$*"
    log_err "  后端=${FW_BACKEND:-未探测}  脚本=${BASH_SOURCE[0]}:${BASH_LINENO[0]}"
    exit 1
}

# 执行关键命令并校验结果；失败时输出 后端/退出码/命令/输出，便于定位
run_chk() {
    local desc="$1"; shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ "${rc}" -ne 0 ]; then
        log_err "${desc} 失败"
        log_err "  后端    : ${FW_BACKEND:-未探测}"
        log_err "  退出码  : ${rc}"
        log_err "  命令    : $*"
        [ -n "${out}" ] && log_err "  输出    : ${out}"
        return "${rc}"
    fi
    return 0
}

# 探测型命令：只取真假，不输出错误
quiet() { "$@" >/dev/null 2>&1; }

# ============================================================================
#  第 3 节：防火墙方案探测
#
#  优先级规则（多种方案并存时，序号小者优先）:
#    1) firewalld 处于 running  —— 它是"管理者"，直接改 nft/iptables 会被其
#       reload 覆盖，必须走 firewall-cmd
#    2) ufw 处于 active         —— 同上，走 ufw 命令
#    3) iptables 是 nft 变体    —— 底层即 nftables，改 iptables 等于改 nft
#    4) legacy iptables 已有自定义规则 —— 尊重用户当前实际操作对象
#    5) nftables 存在活跃规则集
#    6) 仅有 nftables 可用（无 iptables）
#    7) 其余回落 iptables，再次回落 nftables
#
#  额外：管理者已安装但未运行时，给出警告（一旦被启用会覆盖本脚本规则）
# ============================================================================
FW_BACKEND=""            # iptables | nftables | firewalld | ufw
FW_BACKEND_REASON=""     # 选定原因（展示给用户）
HAS_DOCKER=0
HAS_V6=0
NEED_V6=1
CT_MODULE=""
DISTRO_ID=""; DISTRO_NAME=""; DISTRO_VER=""
SSH_PORT=""; SSH_CLIENT_IP=""
FWD_ZONE=""

# 判断 iptables 是否运行在 nft 后端（iptables-nft）
iptables_is_nft_variant() {
    iptables --version 2>/dev/null | grep -q 'nf_tables'
}

# legacy iptables 是否已存在自定义规则（说明用户实际在用 iptables 而非 nft）
iptables_legacy_has_rules() {
    command -v iptables >/dev/null 2>&1 || return 1
    iptables_is_nft_variant && return 1
    iptables -S 2>/dev/null | grep -vE '^-P |^-N ' | grep -q .
}

detect_backend() {
    local fw_running=0 ufw_active=0 nft_active=0
    local have_iptables=0 have_nft=0 have_fwd=0 have_ufw=0

    command -v iptables   >/dev/null 2>&1 && have_iptables=1
    command -v nft        >/dev/null 2>&1 && have_nft=1
    command -v firewall-cmd >/dev/null 2>&1 && have_fwd=1
    command -v ufw        >/dev/null 2>&1 && have_ufw=1

    # --- firewalld 是否运行 ---
    if [ "${have_fwd}" -eq 1 ]; then
        if firewall-cmd --state >/dev/null 2>&1; then
            fw_running=1
        fi
    fi

    # --- ufw 是否激活 ---
    if [ "${have_ufw}" -eq 1 ]; then
        if ufw status 2>/dev/null | grep -qiE '^Status: active'; then
            ufw_active=1
        fi
    fi

    # --- nftables 是否有活跃规则集 ---
    if [ "${have_nft}" -eq 1 ]; then
        if nft list ruleset 2>/dev/null | grep -qE 'table '; then
            nft_active=1
        fi
    fi

    # --- 按优先级判定 ---
    if [ "${fw_running}" -eq 1 ]; then
        FW_BACKEND="firewalld"
        FW_BACKEND_REASON="firewalld 正在运行，为规则管理者（直接改 nft/iptables 会被其 reload 覆盖）"
    elif [ "${ufw_active}" -eq 1 ]; then
        FW_BACKEND="ufw"
        FW_BACKEND_REASON="ufw 处于 active 状态，为规则管理者"
    elif [ "${have_iptables}" -eq 1 ] && iptables_is_nft_variant; then
        FW_BACKEND="nftables"
        FW_BACKEND_REASON="iptables 为 nf_tables 变体，底层即 nftables"
    elif [ "${have_iptables}" -eq 1 ] && iptables_legacy_has_rules; then
        FW_BACKEND="iptables"
        FW_BACKEND_REASON="legacy iptables 已有自定义规则，沿用用户当前实际操作对象"
    elif [ "${nft_active}" -eq 1 ] && [ "${have_nft}" -eq 1 ]; then
        FW_BACKEND="nftables"
        FW_BACKEND_REASON="nftables 存在活跃规则集"
    elif [ "${have_nft}" -eq 1 ] && [ "${have_iptables}" -eq 0 ]; then
        FW_BACKEND="nftables"
        FW_BACKEND_REASON="系统仅有 nftables，无 iptables"
    elif [ "${have_iptables}" -eq 1 ]; then
        FW_BACKEND="iptables"
        FW_BACKEND_REASON="iptables 可用且为 legacy 后端"
    elif [ "${have_nft}" -eq 1 ]; then
        FW_BACKEND="nftables"
        FW_BACKEND_REASON="仅有 nftables 可用"
    else
        die "未检测到任何受支持的防火墙方案（iptables / nftables / firewalld / ufw）。
             请先安装其中之一，例如：
               RHEL/CentOS/麒麟 : yum install iptables-services   或  yum install firewalld
               Debian/Ubuntu    : apt install iptables            或  apt install ufw"
    fi

    # --- 并存警告 ---
    if [ "${have_fwd}" -eq 1 ] && [ "${fw_running}" -eq 0 ] && [ "${FW_BACKEND}" != "firewalld" ]; then
        log_warn "检测到 firewalld 已安装但未运行；一旦启用 firewalld，本脚本写入的规则将被覆盖"
    fi
    if [ "${have_ufw}" -eq 1 ] && [ "${ufw_active}" -eq 0 ] && [ "${FW_BACKEND}" != "ufw" ]; then
        log_warn "检测到 ufw 已安装但未启用；一旦执行 ufw enable，本脚本写入的规则将被覆盖"
    fi
}

detect_env() {
    # 发行版
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"; DISTRO_NAME="${NAME:-unknown}"; DISTRO_VER="${VERSION_ID:-}"
    elif [ -r /etc/redhat-release ]; then
        DISTRO_ID="rhel"; DISTRO_NAME="$(cat /etc/redhat-release)"
    else
        DISTRO_ID="unknown"; DISTRO_NAME="unknown"
    fi

    # conntrack / state 模块（iptables 后端用）
    if command -v iptables >/dev/null 2>&1; then
        if iptables -m conntrack -h >/dev/null 2>&1; then
            CT_MODULE="-m conntrack --ctstate"
        elif iptables -m state -h >/dev/null 2>&1; then
            CT_MODULE="-m state --state"
        fi
    fi

    # IPv6 支持
    if command -v ip6tables >/dev/null 2>&1 && ip6tables -L -n >/dev/null 2>&1; then
        HAS_V6=1
    else
        HAS_V6=0; NEED_V6=0
    fi

    # Docker
    if command -v docker >/dev/null 2>&1 || iptables -t nat -nL DOCKER >/dev/null 2>&1; then
        HAS_DOCKER=1
    fi

    # 当前 SSH 连接（SSH_CONNECTION: 客户端IP 客户端端口 服务端IP 服务端端口）
    if [ -n "${SSH_CONNECTION:-}" ]; then
        # shellcheck disable=SC2086
        set -- ${SSH_CONNECTION}
        SSH_CLIENT_IP="${1:-}"; SSH_PORT="${4:-}"
    fi
    if [ -z "${SSH_PORT}" ]; then
        SSH_PORT="$(grep -iE '^[[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)"
    fi
    [ -z "${SSH_PORT}" ] && SSH_PORT="22"
}

# ============================================================================
#  第 4 节：规则 DSL 存储层
#
#  统一语义格式（6 列，空格分隔，"-" 表示不限）:
#      <方向> <动作> <协议> <端口> <源> <目的>
#      in     accept tcp    22       -           -
#      in     accept tcp    80,443   -           -
#      in     accept any    -        10.0.0.0/8  -
#      in     drop   any    -        1.2.3.4     -
#      out    drop   tcp    25       -           1.2.3.4
#
#  与后端解耦：各后端负责把 DSL 翻译成自己的原生语法
# ============================================================================

init_conf() {
    mkdir -p "${CONF_DIR}" "${BACKUP_DIR}" 2>/dev/null
    chmod 700 "${CONF_DIR}"

    # 从旧版目录迁移（v1.x 使用 /etc/iptables-setup）
    if [ -d "${LEGACY_CONF_DIR}" ] && [ ! -f "${F_RULES}" ]; then
        log_warn "发现旧版配置目录 ${LEGACY_CONF_DIR}，正在迁移到 ${CONF_DIR}"
        cp -a "${LEGACY_CONF_DIR}"/. "${CONF_DIR}/" 2>/dev/null
        # 旧格式（iptables 原生参数）无法直接当 DSL 用，打标记由用户确认
        if [ -f "${CONF_DIR}/in-allow.rules" ] && grep -q -- '-j ' "${CONF_DIR}/in-allow.rules" 2>/dev/null; then
            log_warn "检测到 v1.x 原生 iptables 规则文件，已备份为 *.v1.bak，请按新格式重新录入"
            for f in in-allow in-block out-allow out-block; do
                [ -f "${CONF_DIR}/${f}.rules" ] && mv "${CONF_DIR}/${f}.rules" "${CONF_DIR}/${f}.rules.v1.bak"
            done
        fi
    fi

    [ -f "${F_RULES}" ] || cat > "${F_RULES}" <<'EOF'
# 规则 DSL：<方向> <动作> <协议> <端口> <源> <目的>
#   方向: in | out        动作: accept | drop | reject
#   协议: tcp | udp | any 端口: 22 | 80,443 | 8000:9000
#   源/目的: IP 或 CIDR，不限填 -
EOF

    if [ ! -f "${F_POLICY}" ]; then
        cat > "${F_POLICY}" <<'EOF'
# 默认策略
IN_POLICY=DROP      # INPUT  默认策略: DROP | ACCEPT
OUT_POLICY=ACCEPT   # OUTPUT 默认策略: ACCEPT | DROP
FWD_POLICY=ACCEPT   # FORWARD 默认策略（Docker 场景保持 ACCEPT）
EOF
    fi
    if [ ! -f "${F_SSHGUARD}" ]; then
        cat > "${F_SSHGUARD}" <<'EOF'
# SSH 防暴力破解
ENABLED=0
PORT=22
WINDOW=60
HITCOUNT=5
EOF
    fi
    # shellcheck disable=SC1090
    . "${F_POLICY}"
    # shellcheck disable=SC1090
    . "${F_SSHGUARD}"

    if [ -r "${F_ENV}" ]; then
        # shellcheck disable=SC1090
        . "${F_ENV}"
        [ "${HAS_V6}" -eq 0 ] && NEED_V6=0
        [ -n "${SAVED_ZONE:-}" ] && FWD_ZONE="${SAVED_ZONE}"
    fi
}

save_env() {
    cat > "${F_ENV}" <<EOF
# 由 setup_firewall.sh 自动维护
NEED_V6=${NEED_V6}
SSH_PORT=${SSH_PORT}
SAVED_ZONE=${FWD_ZONE}
EOF
    chmod 600 "${F_ENV}"
}

# 追加一条 DSL 规则（幂等：完全相同的行不会重复写入）
dsl_add() {
    local line="$*"
    # 校验：仅允许安全字符，阻断 shell 元字符
    if printf '%s' "${line}" | grep -qE '[;&|`$><(){}"'"'"'\]' ; then
        log_err "规则包含非法字符，已拒绝: ${line}"
        return 1
    fi
    if [ -n "${line##*[!$' \t\n']*}" ] 2>/dev/null; then
        log_err "规则为空，已拒绝"
        return 1
    fi
    if grep -qxF -- "${line}" "${F_RULES}" 2>/dev/null; then
        log_warn "规则已存在，跳过（幂等）: ${line}"
        return 1
    fi
    printf '%s\n' "${line}" >> "${F_RULES}"
    log_info "已添加: ${line}"
    return 0
}

count_rules() {
    local n
    n="$(grep -cve '^[[:space:]]*$' -e '^[[:space:]]*#' "$1" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}

# 列出有效规则（带编号）
dsl_list() {
    local i=1 line
    hr
    printf '  %-4s %-9s %-6s %-6s %-16s %-16s %s\n' "编号" "方向" "动作" "协议" "端口" "源" "目的"
    hr
    local found=0
    while IFS= read -r line || [ -n "${line}" ]; do
        [ -z "${line}" ] && continue
        case "${line}" in \#*) continue ;; esac
        # shellcheck disable=SC2086
        set -- ${line}
        printf '  %-4s %-9s %-6s %-6s %-16s %-16s %s\n' \
            "$i" "${1:--}" "${2:--}" "${3:--}" "${4:--}" "${5:--}" "${6:--}"
        i=$((i+1)); found=1
    done < "${F_RULES}"
    [ "${found}" -eq 0 ] && printf '  (暂无规则)\n'
    hr
}

dsl_delete() {
    local num line
    dsl_list
    [ "$(count_rules "${F_RULES}")" -eq 0 ] && { log_warn "无规则可删除"; return; }
    read -r -p "输入要删除的编号 (0 取消): " num
    [ -z "${num}" ] && return
    printf '%s' "${num}" | grep -qE '^[0-9]+$' || { log_err "无效编号"; return; }
    [ "${num}" -eq 0 ] && return
    line="$(grep -ve '^[[:space:]]*$' -e '^[[:space:]]*#' "${F_RULES}" | sed -n "${num}p")"
    [ -z "${line}" ] && { log_err "编号不存在"; return; }
    printf '将删除: %s\n' "${line}"
    read -r -p "确认删除? [y/N]: " ans
    [ "${ans:-N}" = "y" ] || return
    local tmp; tmp="$(mktemp)"
    grep -vxF -- "${line}" "${F_RULES}" > "${tmp}" && mv "${tmp}" "${F_RULES}"
    log_info "已删除（需重新应用后生效）"
    rm -f "${tmp}" 2>/dev/null
}

# ============================================================================
#  第 5 节：后端抽象层
#
#  每个后端实现 4 个函数，由统一入口分发：
#      be_<x>_precheck  检查依赖是否可用
#      be_<x>_apply     全量重建规则（幂等）
#      be_<x>_persist   持久化
#      be_<x>_status    输出后端特有状态
#      be_<x>_reset     恢复到全放行
# ============================================================================

undo_file() { printf '%s/.undo.%s.sh' "${CONF_DIR}" "${FW_BACKEND}"; }

# ---------- 5.1 iptables 后端 ----------
be_iptables_precheck() {
    command -v iptables >/dev/null 2>&1 || { log_err "iptables 命令不存在"; return 1; }
    [ -n "${CT_MODULE}" ] || { log_err "iptables 缺少 conntrack/state 模块"; return 1; }
    return 0
}

# 摘除内建链上对自定义链的引用（绝不 flush 整条内建链，保护 Docker / firewalld）
ipt_detach() {
    local bin="$1" spec parent ch guard
    for spec in "INPUT:${C_IN_ALLOW}" "INPUT:${C_IN_BLOCK}" \
                "OUTPUT:${C_OUT_ALLOW}" "OUTPUT:${C_OUT_BLOCK}" \
                "DOCKER-USER:${C_IN_ALLOW}" "DOCKER-USER:${C_IN_BLOCK}"; do
        parent="${spec%%:*}"; ch="${spec##*:}"
        ${bin} -nL "${parent}" >/dev/null 2>&1 || continue
        guard=0
        while ${bin} -C "${parent}" -j "${ch}" >/dev/null 2>&1; do
            ${bin} -D "${parent}" -j "${ch}" >/dev/null 2>&1 || break
            guard=$((guard+1)); [ "${guard}" -gt 20 ] && break
        done
    done
}

ipt_destroy() {
    local bin="$1" ch
    for ch in "${ALL_IPT_CHAINS[@]}"; do
        ${bin} -nL "${ch}" >/dev/null 2>&1 || continue
        ${bin} -F "${ch}" 2>/dev/null; ${bin} -X "${ch}" 2>/dev/null
    done
}

# 把一条 DSL 规则翻译成 iptables 参数（不含 -j）
ipt_args() {
    local proto="$1" ports="$2" src="$3" dst="$4"
    local a=""
    [ "${src}" != "-" ] && a="${a} -s ${src}"
    [ "${dst}" != "-" ] && a="${a} -d ${dst}"
    if [ "${proto}" != "any" ] && [ "${proto}" != "-" ]; then
        a="${a} -p ${proto}"
        if [ "${ports}" != "-" ]; then
            if printf '%s' "${ports}" | grep -qE '^[0-9]+$'; then
                a="${a} -m ${proto} --dport ${ports}"
            else
                # 多端口或范围统一交给 multiport
                a="${a} -m multiport --dports ${ports}"
            fi
        fi
    fi
    printf '%s' "${a# }"
}

be_iptables_apply() {
    local bins=("iptables")
    [ "${NEED_V6}" -eq 1 ] && [ "${HAS_V6}" -eq 1 ] && bins+=("ip6tables")

    local bin ch
    for bin in "${bins[@]}"; do
        log_step "重建 ${bin} 规则 ..."
        ipt_detach "${bin}"; ipt_destroy "${bin}"
        for ch in "${ALL_IPT_CHAINS[@]}"; do
            ${bin} -nL "${ch}" >/dev/null 2>&1 || ${bin} -N "${ch}" >/dev/null 2>&1 ||
                log_err "无法创建链 ${ch}（${bin}）"
        done

        local icmp="icmp"; [ "${bin}" = "ip6tables" ] && icmp="ipv6-icmp"

        # --- 入站放行链 ---
        run_chk "${bin}: 放行 loopback" ${bin} -A "${C_IN_ALLOW}" -i lo -j ACCEPT
        run_chk "${bin}: 放行已建立连接" ${bin} -A "${C_IN_ALLOW}" ${CT_MODULE} ESTABLISHED,RELATED -j ACCEPT
        ${bin} -A "${C_IN_ALLOW}" ${CT_MODULE} INVALID -j DROP 2>/dev/null
        if [ "${icmp}" = "ipv6-icmp" ]; then
            # IPv6 依赖 ICMPv6（邻居发现 / PMTUD），必须全放行，限速会导致断网
            ${bin} -A "${C_IN_ALLOW}" -p ipv6-icmp -j ACCEPT 2>/dev/null
        else
            ${bin} -A "${C_IN_ALLOW}" -p icmp -m icmp --icmp-type 8 -m limit --limit 5/second --limit-burst 10 -j ACCEPT 2>/dev/null
            ${bin} -A "${C_IN_ALLOW}" -p icmp -m icmp --icmp-type 0  -j ACCEPT 2>/dev/null
            ${bin} -A "${C_IN_ALLOW}" -p icmp -m icmp --icmp-type 3  -j ACCEPT 2>/dev/null
            ${bin} -A "${C_IN_ALLOW}" -p icmp -m icmp --icmp-type 11 -j ACCEPT 2>/dev/null
        fi

        # --- SSH 防暴力破解（recent 模块）---
        if [ "${ENABLED:-0}" -eq 1 ]; then
            local sp="${PORT:-22}"
            if ${bin} -A "${C_SSHGUARD}" -p tcp --dport "${sp}" ${CT_MODULE} NEW -m recent --set --name FWSSH 2>/dev/null; then
                ${bin} -A "${C_SSHGUARD}" -p tcp --dport "${sp}" ${CT_MODULE} NEW \
                    -m recent --update --seconds "${WINDOW:-60}" --hitcount "${HITCOUNT:-5}" \
                    --name FWSSH -j DROP 2>/dev/null
                ${bin} -A "${C_IN_ALLOW}" -p tcp --dport "${sp}" -j "${C_SSHGUARD}" 2>/dev/null
            else
                log_warn "${bin} 不支持 recent 模块，SSH 防暴破已跳过"
            fi
        fi

        # --- 用户规则（DSL）---
        _ipt_load_user "${bin}"

        ${bin} -A "${C_IN_BLOCK}" -j RETURN 2>/dev/null
        ${bin} -A "${C_OUT_BLOCK}" -j RETURN 2>/dev/null
        if [ "${OUT_POLICY:-ACCEPT}" = "DROP" ]; then
            ${bin} -A "${C_OUT_ALLOW}" -p udp --dport 53 -j ACCEPT 2>/dev/null
            ${bin} -A "${C_OUT_ALLOW}" -p tcp --dport 53 -j ACCEPT 2>/dev/null
            ${bin} -A "${C_OUT_ALLOW}" -j DROP 2>/dev/null
        else
            ${bin} -A "${C_OUT_ALLOW}" -j RETURN 2>/dev/null
        fi

        # --- 挂载到内建链（BLOCK 在前，保证封禁优先）---
        ${bin} -I OUTPUT 1 -j "${C_OUT_ALLOW}" 2>/dev/null
        ${bin} -I OUTPUT 1 -j "${C_OUT_BLOCK}" 2>/dev/null
        ${bin} -I INPUT  1 -j "${C_IN_ALLOW}"  2>/dev/null
        ${bin} -I INPUT  1 -j "${C_IN_BLOCK}"  2>/dev/null

        # --- Docker：让容器端口同样受本脚本规则约束 ---
        if [ "${HAS_DOCKER}" -eq 1 ] && ${bin} -nL DOCKER-USER >/dev/null 2>&1; then
            ${bin} -I DOCKER-USER 1 -j "${C_IN_ALLOW}" 2>/dev/null
            ${bin} -I DOCKER-USER 1 -j "${C_IN_BLOCK}" 2>/dev/null
            log_info "已在 DOCKER-USER 链挂载规则（容器端口同样受控）"
        fi

        run_chk "${bin}: 设置 INPUT 默认策略" ${bin} -P INPUT   "${IN_POLICY:-DROP}"
        run_chk "${bin}: 设置 OUTPUT 默认策略" ${bin} -P OUTPUT  "${OUT_POLICY:-ACCEPT}"
        # FORWARD 保持用户配置，Docker / 桥接 / 容器依赖它
        ${bin} -P FORWARD "${FWD_POLICY:-ACCEPT}" 2>/dev/null
    done
}

_ipt_load_user() {
    local bin="$1" dir act proto ports src dst chain args line
    while IFS= read -r line || [ -n "${line}" ]; do
        [ -z "${line}" ] && continue
        case "${line}" in \#*) continue ;; esac
        # shellcheck disable=SC2086
        set -- ${line}
        dir="${1:-in}"; act="${2:-accept}"; proto="${3:-any}"; ports="${4:--}"; src="${5:--}"; dst="${6:--}"
        case "${act}" in
            accept) : ;;
            drop)   : ;;
            reject) : ;;
            *) log_warn "未知动作，跳过: ${line}"; continue ;;
        esac
        local t="ACCEPT"; [ "${act}" = "drop" ] && t="DROP"; [ "${act}" = "reject" ] && t="REJECT"
        case "${dir}" in
            in)  chain="${C_IN_ALLOW}"; [ "${act}" != "accept" ] && chain="${C_IN_BLOCK}" ;;
            out) chain="${C_OUT_ALLOW}"; [ "${act}" != "accept" ] && chain="${C_OUT_BLOCK}" ;;
            *) log_warn "未知方向，跳过: ${line}"; continue ;;
        esac
        args="$(ipt_args "${proto}" "${ports}" "${src}" "${dst}")"
        # shellcheck disable=SC2086
        if ! eval "${bin} -A ${chain} ${args} -j ${t}" 2>/dev/null; then
            log_err "规则应用失败 [后端=iptables]: ${bin} -A ${chain} ${args} -j ${t}"
        fi
    done < "${F_RULES}"
}

be_iptables_persist() { persist_iptables; }

be_iptables_status() {
    for chain in INPUT FORWARD OUTPUT; do
        printf '  %-8s : %s\n' "${chain}" "$(iptables -S "${chain}" 2>/dev/null | awk '$2=="-P"{print $3}')"
    done
    [ "${HAS_V6}" -eq 1 ] && {
        printf '  -- IPv6 --\n'
        for chain in INPUT FORWARD OUTPUT; do
            printf '  %-8s : %s\n' "${chain}" "$(ip6tables -S "${chain}" 2>/dev/null | awk '$2=="-P"{print $3}')"
        done
    }
    printf '\n'
    printf "${C_B}========= INPUT 链 (IPv4) =========${C_N}\n"
    iptables -L INPUT -n -v --line-numbers 2>/dev/null | sed 's/^/  /'
}

be_iptables_reset() {
    local bins=("iptables"); [ "${HAS_V6}" -eq 1 ] && bins+=("ip6tables")
    local bin
    for bin in "${bins[@]}"; do
        ipt_detach "${bin}"; ipt_destroy "${bin}"
        ${bin} -P INPUT ACCEPT 2>/dev/null
        ${bin} -P OUTPUT ACCEPT 2>/dev/null
        ${bin} -P FORWARD ACCEPT 2>/dev/null
    done
    rm -f /etc/sysconfig/iptables /etc/sysconfig/ip6tables 2>/dev/null
}

# ---------- 5.2 nftables 后端 ----------
be_nftables_precheck() {
    command -v nft >/dev/null 2>&1 || { log_err "nft 命令不存在"; return 1; }
    quiet nft list ruleset || { log_err "nft 无法访问内核规则集（权限不足或内核不支持）"; return 1; }
    return 0
}

# 把 DSL 端口写法转成 nft 端口表达式：22 / 80,443 -> { 80, 443 } / 8000:9000 -> 8000-9000
nft_port_expr() {
    local p
    p="$(printf '%s' "$1" | tr ':' '-' | tr -d ' ')"
    if printf '%s' "${p}" | grep -q ','; then
        # 多端口转成集合字面量，逗号后补空格符合 nft 惯例
        printf '{ %s }' "$(printf '%s' "${p}" | sed 's/,/, /g')"
    else
        printf '%s' "${p}"
    fi
}

# 依据地址字面量判断协议族
nft_is_v6() { printf '%s' "$1" | grep -q ':'; }

_nft_rule_lines() {
    local hook="$1" want_accept="$2" dir="$3" act="$4" proto="$5" ports="$6" src="$7" dst="$8"
    local t="accept"
    [ "${act}" = "drop" ]   && t="drop"
    [ "${act}" = "reject" ] && t="reject with icmpx type admin-prohibited"

    local exprs="" e
    if [ "${src}" != "-" ]; then
        if nft_is_v6 "${src}"; then e="ip6 saddr ${src}"; else e="ip saddr ${src}"; fi
        exprs="${exprs}${exprs:+ }${e}"
    fi
    if [ "${dst}" != "-" ]; then
        if nft_is_v6 "${dst}"; then e="ip6 daddr ${dst}"; else e="ip daddr ${dst}"; fi
        exprs="${exprs}${exprs:+ }${e}"
    fi
    if [ "${proto}" != "any" ] && [ "${proto}" != "-" ]; then
        if [ "${ports}" != "-" ]; then
            e="${proto} dport $(nft_port_expr "${ports}")"
        else
            e="meta l4proto ${proto}"
        fi
        exprs="${exprs}${exprs:+ }${e}"
    fi
    [ -z "${exprs}" ] && exprs="meta l4proto { tcp, udp, icmp, icmpv6 }"
    printf '%s %s\n' "${exprs}" "${t}"
}

be_nftables_apply() {
    local ruleset
    ruleset="$(mktemp)"
    local dir act proto ports src dst

    {
        printf 'table %s %s {\n' "${NFT_FAMILY}" "${NFT_TABLE}"

        # ---- 入站封禁链（优先级最高）----
        printf '    chain in_block {\n'
        printf '        type filter hook input priority -20; policy accept;\n'
        while IFS= read -r line || [ -n "${line}" ]; do
            [ -z "${line}" ] && continue
            case "${line}" in \#*) continue ;; esac
            # shellcheck disable=SC2086
            set -- ${line}
            dir="${1:-in}"; act="${2:-accept}"; proto="${3:-any}"; ports="${4:--}"; src="${5:--}"; dst="${6:--}"
            [ "${dir}" = "in" ] && [ "${act}" != "accept" ] &&
                printf '        %s\n' "$(_nft_rule_lines input no in "${act}" "${proto}" "${ports}" "${src}" "${dst}")"
        done < "${F_RULES}"
        printf '    }\n'

        # ---- 入站放行链 ----
        printf '    chain in_allow {\n'
        printf '        type filter hook input priority -10; policy accept;\n'
        printf '        iifname "lo" accept\n'
        printf '        ct state established,related accept\n'
        printf '        ct state invalid drop\n'
        printf '        icmp type echo-request limit rate 5/second burst 10 packets accept\n'
        printf '        icmp type { destination-unreachable, time-exceeded, source-quench, redirect } accept\n'
        # IPv6 必须放行 ICMPv6，否则邻居发现 / PMTUD 失效导致断网
        printf '        icmpv6 type { echo-request, echo-reply, destination-unreachable, packet-too-big, time-exceeded, parameter-problem, nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept\n'
        # SSH 防暴力破解：nft meter 按源 IP 限流
        if [ "${ENABLED:-0}" -eq 1 ]; then
            local sp="${PORT:-22}" rate
            rate=$(( HITCOUNT * 60 / (WINDOW == 0 ? 60 : WINDOW) ))
            [ "${rate}" -lt 1 ] && rate=1
            printf '        tcp dport %s ct state new meter fwssh_v4 { ip saddr limit rate over %s/minute } drop\n' "${sp}" "${rate}"
            printf '        tcp dport %s ct state new meter fwssh_v6 { ip6 saddr limit rate over %s/minute } drop\n' "${sp}" "${rate}"
        fi
        while IFS= read -r line || [ -n "${line}" ]; do
            [ -z "${line}" ] && continue
            case "${line}" in \#*) continue ;; esac
            # shellcheck disable=SC2086
            set -- ${line}
            dir="${1:-in}"; act="${2:-accept}"; proto="${3:-any}"; ports="${4:--}"; src="${5:--}"; dst="${6:--}"
            [ "${dir}" = "in" ] && [ "${act}" = "accept" ] &&
                printf '        %s\n' "$(_nft_rule_lines input yes in "${act}" "${proto}" "${ports}" "${src}" "${dst}")"
        done < "${F_RULES}"
        printf '    }\n'

        # ---- 出站封禁链 ----
        printf '    chain out_block {\n'
        printf '        type filter hook output priority -20; policy accept;\n'
        while IFS= read -r line || [ -n "${line}" ]; do
            [ -z "${line}" ] && continue
            case "${line}" in \#*) continue ;; esac
            # shellcheck disable=SC2086
            set -- ${line}
            dir="${1:-in}"; act="${2:-accept}"; proto="${3:-any}"; ports="${4:--}"; src="${5:--}"; dst="${6:--}"
            [ "${dir}" = "out" ] && [ "${act}" != "accept" ] &&
                printf '        %s\n' "$(_nft_rule_lines output no out "${act}" "${proto}" "${ports}" "${src}" "${dst}")"
        done < "${F_RULES}"
        printf '    }\n'

        # ---- 出站放行链 ----
        printf '    chain out_allow {\n'
        printf '        type filter hook output priority -10; policy accept;\n'
        printf '        oifname "lo" accept\n'
        printf '        ct state established,related accept\n'
        while IFS= read -r line || [ -n "${line}" ]; do
            [ -z "${line}" ] && continue
            case "${line}" in \#*) continue ;; esac
            # shellcheck disable=SC2086
            set -- ${line}
            dir="${1:-in}"; act="${2:-accept}"; proto="${3:-any}"; ports="${4:--}"; src="${5:--}"; dst="${6:--}"
            [ "${dir}" = "out" ] && [ "${act}" = "accept" ] &&
                printf '        %s\n' "$(_nft_rule_lines output yes out "${act}" "${proto}" "${ports}" "${src}" "${dst}")"
        done < "${F_RULES}"
        if [ "${OUT_POLICY:-ACCEPT}" = "DROP" ]; then
            printf '        udp dport 53 accept\n'
            printf '        tcp dport 53 accept\n'
            printf '        drop\n'
        fi
        printf '    }\n'
        printf '}\n'
    } > "${ruleset}"

    # 幂等：先删除整表再重建
    nft delete table "${NFT_FAMILY}" "${NFT_TABLE}" >/dev/null 2>&1
    if ! run_chk "nftables: 加载规则集" nft -f "${ruleset}"; then
        log_err "规则集加载失败，内容如下（可据此定位语法错误）:"
        sed 's/^/    /' "${ruleset}" >&2
        rm -f "${ruleset}"
        return 1
    fi
    rm -f "${ruleset}"
    log_info "nftables 规则已重建（table ${NFT_FAMILY} ${NFT_TABLE}）"
}

be_nftables_persist() {
    local conf="/etc/nftables.conf"
    [ -d /etc/sysconfig ] && conf="/etc/sysconfig/nftables.conf"
    nft list ruleset > "${conf}" 2>/dev/null ||
        { log_err "导出 nftables 规则集失败: ${conf}"; return 1; }
    log_info "已写入 ${conf}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable nftables >/dev/null 2>&1 && log_info "已启用 nftables.service 开机自启"
    fi
}

be_nftables_status() {
    nft list table "${NFT_FAMILY}" "${NFT_TABLE}" 2>/dev/null | sed 's/^/  /' ||
        printf '  (尚未创建 %s %s 表)\n' "${NFT_FAMILY}" "${NFT_TABLE}"
}

be_nftables_reset() {
    nft delete table "${NFT_FAMILY}" "${NFT_TABLE}" 2>/dev/null ||
        log_warn "表 ${NFT_TABLE} 不存在，无需删除"
    log_info "nftables 自定义表已删除（系统默认策略保持不变）"
}

# ---------- 5.3 firewalld 后端 ----------
be_firewalld_precheck() {
    command -v firewall-cmd >/dev/null 2>&1 || { log_err "firewall-cmd 命令不存在"; return 1; }
    firewall-cmd --state >/dev/null 2>&1 || { log_err "firewalld 未运行，请先 systemctl start firewalld"; return 1; }
    # 确定操作 zone：优先 env 记录，其次默认 zone
    if [ -z "${FWD_ZONE}" ]; then
        FWD_ZONE="$(firewall-cmd --get-default-zone 2>/dev/null || echo public)"
        [ -z "${FWD_ZONE}" ] && FWD_ZONE="public"
    fi
    firewall-cmd --zone="${FWD_ZONE}" --list-all >/dev/null 2>&1 ||
        { log_err "zone ${FWD_ZONE} 不存在"; return 1; }
    return 0
}

# firewalld 幂等辅助：查询通过则跳过
fwd_has() {
    local kind="$1" val="$2"
    case "${kind}" in
        port)    firewall-cmd --permanent --zone="${FWD_ZONE}" --query-port="${val}"    >/dev/null 2>&1 ;;
        service) firewall-cmd --permanent --zone="${FWD_ZONE}" --query-service="${val}" >/dev/null 2>&1 ;;
        source)  firewall-cmd --permanent --zone="${FWD_ZONE}" --query-source="${val}"  >/dev/null 2>&1 ;;
        rich)    firewall-cmd --permanent --zone="${FWD_ZONE}" --query-rich-rule="${val}" >/dev/null 2>&1 ;;
    esac
}

fwd_add() {
    local kind="$1" val="$2" cmd
    fwd_has "${kind}" "${val}" && { log_info "已存在，跳过: ${kind}=${val}"; return 0; }
    cmd=(firewall-cmd --permanent --zone="${FWD_ZONE}")
    case "${kind}" in
        port)    cmd+=(--add-port="${val}") ;;
        service) cmd+=(--add-service="${val}") ;;
        source)  cmd+=(--add-source="${val}") ;;
        rich)    cmd+=(--add-rich-rule="${val}") ;;
    esac
    if run_chk "firewalld: 添加 ${kind}=${val}" "${cmd[@]}"; then
        # 记录撤销命令，供下次全量重建前回滚（rich rule 含空格与引号，必须加引号）
        local undo; undo="$(undo_file)"
        case "${kind}" in
            port)    printf "firewall-cmd --permanent --zone=%s --remove-port=%s\n"   "${FWD_ZONE}" "${val}" >> "${undo}" ;;
            service) printf "firewall-cmd --permanent --zone=%s --remove-service=%s\n" "${FWD_ZONE}" "${val}" >> "${undo}" ;;
            source)  printf "firewall-cmd --permanent --zone=%s --remove-source=%s\n"  "${FWD_ZONE}" "${val}" >> "${undo}" ;;
            rich)    printf "firewall-cmd --permanent --zone=%s --remove-rich-rule='%s'\n" "${FWD_ZONE}" "${val}" >> "${undo}" ;;
        esac
        return 0
    fi
    return 1
}

be_firewalld_apply() {
    local undo; undo="$(undo_file)"

    # 幂等：先撤销上一次由本脚本添加的全部条目
    if [ -s "${undo}" ]; then
        log_step "撤销上次应用的 firewalld 条目 ..."
        local line
        while IFS= read -r line; do
            [ -n "${line}" ] && eval "${line}" >/dev/null 2>&1
        done < "${undo}"
    fi
    : > "${undo}"

    # 默认策略：firewalld 用 target 表达（default=REJECT/DROP，ACCEPT）
    local target="DROP"
    [ "${IN_POLICY:-DROP}" = "ACCEPT" ] && target="ACCEPT"
    if ! firewall-cmd --permanent --zone="${FWD_ZONE}" --get-target >/dev/null 2>&1; then
        log_warn "当前 firewalld 版本不支持 --get-target，跳过 target 设置"
    else
        local cur; cur="$(firewall-cmd --permanent --zone="${FWD_ZONE}" --get-target 2>/dev/null)"
        if [ "${cur}" != "${target}" ]; then
            run_chk "firewalld: 设置 zone target=${target}" \
                firewall-cmd --permanent --zone="${FWD_ZONE}" --set-target="${target}" ||
                log_warn "target 设置失败，zone=${FWD_ZONE}"
        fi
    fi

    # SSH 防暴力破解：firewalld 原生 limit（每分钟 N 次）
    if [ "${ENABLED:-0}" -eq 1 ]; then
        local sp="${PORT:-22}" rate
        rate=$(( HITCOUNT * 60 / (WINDOW == 0 ? 60 : WINDOW) ))
        [ "${rate}" -lt 1 ] && rate=1
        fwd_add rich "rule family=\"ipv4\" port port=\"${sp}\" protocol=\"tcp\" limit value=\"${rate}/m\" accept" ||
            log_warn "SSH 防暴破规则添加失败"
    fi

    # 用户规则
    local dir act proto ports src dst
    while IFS= read -r line || [ -n "${line}" ]; do
        [ -z "${line}" ] && continue
        case "${line}" in \#*) continue ;; esac
        # shellcheck disable=SC2086
        set -- ${line}
        dir="${1:-in}"; act="${2:-accept}"; proto="${3:-any}"; ports="${4:--}"; src="${5:--}"; dst="${6:--}"

        if [ "${dir}" = "out" ]; then
            # firewalld rich rule 不覆盖 OUTPUT：出站管控降级为 direct 规则并明确告知
            log_warn "firewalld 不原生支持出站过滤，规则 [${line}] 将使用 --direct 写入 OUTPUT 链"
            local ipt_args_str
            ipt_args_str="$(ipt_args "${proto}" "${ports}" "${src}" "${dst}")"
            local t="ACCEPT"; [ "${act}" = "drop" ] && t="DROP"; [ "${act}" = "reject" ] && t="REJECT"
            # shellcheck disable=SC2086
            run_chk "firewalld: 出站 direct 规则" \
                firewall-cmd --permanent --direct --add-rule ipv4 filter OUTPUT 0 ${ipt_args_str} -j "${t}" ||
                log_err "出站规则应用失败: ${line}"
            printf 'firewall-cmd --permanent --direct --remove-rule ipv4 filter OUTPUT 0 %s -j %s\n' \
                "${ipt_args_str}" "${t}" >> "${undo}"
            continue
        fi

        # 入站
        local fam="ipv4"
        [ "${src}" != "-" ] && nft_is_v6 "${src}" && fam="ipv6"
        [ "${dst}" != "-" ] && nft_is_v6 "${dst}" && fam="ipv6"

        if [ "${act}" = "accept" ] && [ "${src}" = "-" ] && [ "${dst}" = "-" ] && [ "${proto}" != "any" ] && [ "${ports}" != "-" ]; then
            # 纯端口放行 —— 用 --add-port 最直观
            local plist; plist="$(printf '%s' "${ports}" | tr ',' '\n')"
            local p
            for p in ${plist}; do
                fwd_add port "${p}/${proto}" || log_err "端口放行失败: ${p}/${proto}"
            done
        elif [ "${act}" = "accept" ] && [ "${src}" != "-" ] && [ "${ports}" = "-" ] && [ "${dst}" = "-" ]; then
            # 注意：不能用 --add-source（那只是把来源绑定到 zone，仍会被 zone target 丢弃），
            # 必须用 rich rule 显式 accept 才能实现"该来源全端口通行"
            fwd_add rich "rule family=\"${fam}\" source address=\"${src}\" accept" ||
                log_err "来源放行失败: ${src}"
        else
            # 其余组合统一走 rich rule（支持 源/目的/端口/动作 任意组合）
            local rrule="rule family=\"${fam}\""
            [ "${src}" != "-" ] && rrule="${rrule} source address=\"${src}\""
            [ "${dst}" != "-" ] && rrule="${rrule} destination address=\"${dst}\""
            if [ "${proto}" != "any" ] && [ "${proto}" != "-" ] && [ "${ports}" != "-" ]; then
                rrule="${rrule} port port=\"${ports}\" protocol=\"${proto}\""
            elif [ "${proto}" != "any" ] && [ "${proto}" != "-" ]; then
                rrule="${rrule} protocol value=\"${proto}\""
            fi
            case "${act}" in
                accept) rrule="${rrule} accept" ;;
                drop)   rrule="${rrule} drop" ;;
                reject) rrule="${rrule} reject" ;;
            esac
            fwd_add rich "${rrule}" || log_err "规则应用失败: ${line}"
        fi
    done < "${F_RULES}"

    run_chk "firewalld: 重载使规则生效" firewall-cmd --reload ||
        die "firewalld --reload 失败，规则可能未生效。请执行 systemctl status firewalld 排查"
    log_info "firewalld 规则已应用（zone=${FWD_ZONE}）"
}

be_firewalld_persist() {
    # firewalld 使用 --permanent 写入，天然持久化
    run_chk "firewalld: 写入永久配置" firewall-cmd --runtime-to-permanent || true
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable firewalld >/dev/null 2>&1 && log_info "已启用 firewalld 开机自启"
    fi
    log_info "firewalld 规则已持久化（--permanent）"
}

be_firewalld_status() {
    printf '  操作 zone : %s\n' "${FWD_ZONE}"
    printf '  zone target: %s\n' "$(firewall-cmd --permanent --zone="${FWD_ZONE}" --get-target 2>/dev/null || echo unknown)"
    printf '\n'
    firewall-cmd --zone="${FWD_ZONE}" --list-all 2>/dev/null | sed 's/^/  /'
}

be_firewalld_reset() {
    local undo; undo="$(undo_file)"
    if [ -s "${undo}" ]; then
        local line
        while IFS= read -r line; do
            [ -n "${line}" ] && eval "${line}" >/dev/null 2>&1
        done < "${undo}"
        : > "${undo}"
    fi
    firewall-cmd --permanent --zone="${FWD_ZONE}" --set-target=default >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    log_info "firewalld 已恢复（target=default 并移除本脚本条目）"
}

# ---------- 5.4 ufw 后端 ----------
UFW_COMMENT_OK=0

be_ufw_precheck() {
    command -v ufw >/dev/null 2>&1 || { log_err "ufw 命令不存在"; return 1; }
    # 检测 comment 支持（用于标记本脚本规则，便于精确删除）
    if ufw --help 2>&1 | grep -qi 'comment'; then
        UFW_COMMENT_OK=1
    else
        log_warn "当前 ufw 版本不支持 comment，规则删除将依赖精确规则串匹配"
    fi
    return 0
}

# 把 DSL 翻译成 ufw 参数
#   ufw 语法: [in|out] ACTION [proto P] [from ADDR] [to ADDR [port PORT]] [comment]
#   单端口且无源/目的限制时改用最通用的 PORT/PROTO 简写
ufw_args() {
    local dir="$1" act="$2" proto="$3" ports="$4" src="$5" dst="$6"
    local a actw="allow"
    [ "${act}" = "drop" ]   && actw="deny"
    [ "${act}" = "reject" ] && actw="reject"

    a="${actw}"
    [ "${dir}" = "out" ] && a="${a} out"
    [ "${proto}" != "any" ] && [ "${proto}" != "-" ] && a="${a} proto ${proto}"
    [ "${src}" != "-" ] && a="${a} from ${src}"
    if [ "${dst}" != "-" ] || [ "${ports}" != "-" ]; then
        if [ "${dst}" != "-" ]; then a="${a} to ${dst}"; else a="${a} to any"; fi
        [ "${ports}" != "-" ] && a="${a} port ${ports}"
    fi

    # 纯单端口放行 -> 简写 "allow 22/tcp"，兼容性最好
    if [ "${src}" = "-" ] && [ "${dst}" = "-" ] && [ "${proto}" != "any" ] && [ "${proto}" != "-" ] \
       && printf '%s' "${ports}" | grep -qE '^[0-9]+$'; then
        a="${actw}"
        [ "${dir}" = "out" ] && a="${a} out"
        a="${a} ${ports}/${proto}"
    fi
    printf '%s' "${a# }"
}

ufw_is_active() { ufw status 2>/dev/null | grep -qiE '^Status: active'; }

be_ufw_apply() {
    local undo; undo="$(undo_file)"
    # 幂等：撤销上次由本脚本添加的规则
    if [ -s "${undo}" ]; then
        log_step "撤销上次应用的 ufw 规则 ..."
        local line
        while IFS= read -r line; do
            [ -n "${line}" ] && eval "${line}" >/dev/null 2>&1
        done < "${undo}"
    fi
    : > "${undo}"

    # 默认策略
    local in_p="deny"; [ "${IN_POLICY:-DROP}"  = "ACCEPT" ] && in_p="allow"
    local out_p="allow"; [ "${OUT_POLICY:-ACCEPT}" = "DROP" ] && out_p="deny"
    ufw default "${in_p}"  incoming >/dev/null 2>&1 || log_warn "设置入站默认策略失败"
    ufw default "${out_p}" outgoing >/dev/null 2>&1 || log_warn "设置出站默认策略失败"

    # SSH 防暴力破解 —— ufw 原生 limit
    if [ "${ENABLED:-0}" -eq 1 ]; then
        local sp="${PORT:-22}"
        if [ "${UFW_COMMENT_OK}" -eq 1 ]; then
            run_chk "ufw: SSH 限流" ufw limit "${sp}/tcp" comment 'fw-setup sshguard' &&
                printf 'ufw --force delete limit %s/tcp\n' "${sp}" >> "${undo}"
        else
            run_chk "ufw: SSH 限流" ufw limit "${sp}/tcp" &&
                printf 'ufw --force delete limit %s/tcp\n' "${sp}" >> "${undo}"
        fi
    fi

    local dir act proto ports src dst
    while IFS= read -r line || [ -n "${line}" ]; do
        [ -z "${line}" ] && continue
        case "${line}" in \#*) continue ;; esac
        # shellcheck disable=SC2086
        set -- ${line}
        dir="${1:-in}"; act="${2:-accept}"; proto="${3:-any}"; ports="${4:--}"; src="${5:--}"; dst="${6:--}"

        local args; args="$(ufw_args "${dir}" "${act}" "${proto}" "${ports}" "${src}" "${dst}")"
        local full="${args}"
        [ "${UFW_COMMENT_OK}" -eq 1 ] && full="${args} comment 'fw-setup'"
        # shellcheck disable=SC2086
        if eval "ufw ${full}" >/dev/null 2>&1; then
            # 记录反向删除命令（ufw delete + 原规则不含 comment）
            printf 'ufw --force delete %s\n' "${args}" >> "${undo}"
        else
            log_err "规则应用失败 [后端=ufw]: ufw ${full}  （原始规则: ${line}）"
        fi
    done < "${F_RULES}"

    if ! ufw_is_active; then
        log_warn "ufw 当前未启用，规则已写入但尚未生效"
        read -r -p "是否立即执行 ufw enable? [y/N]: " a
        [ "${a:-N}" = "y" ] && run_chk "ufw: 启用" ufw --force enable
    fi
    run_chk "ufw: 重载规则" ufw reload || log_warn "ufw reload 失败"
    log_info "ufw 规则已应用"
}

be_ufw_persist() {
    # ufw 规则自动写入 /etc/ufw/user.rules，随 ufw 服务自启
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable ufw >/dev/null 2>&1 && log_info "已启用 ufw 开机自启"
    fi
    log_info "ufw 规则已持久化（/etc/ufw/user.rules）"
}

be_ufw_status() {
    ufw status verbose 2>/dev/null | sed 's/^/  /'
}

be_ufw_reset() {
    local undo; undo="$(undo_file)"
    if [ -s "${undo}" ]; then
        local line
        while IFS= read -r line; do
            [ -n "${line}" ] && eval "${line}" >/dev/null 2>&1
        done < "${undo}"
        : > "${undo}"
    fi
    ufw default allow incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    log_info "ufw 已恢复默认放行"
}

# ---------- 5.5 统一分发入口 ----------
fw_precheck()  { "be_${FW_BACKEND}_precheck"; }
fw_apply()     { "be_${FW_BACKEND}_apply"; }
fw_persist()   { "be_${FW_BACKEND}_persist"; }
fw_status_be() { "be_${FW_BACKEND}_status"; }
fw_reset_be()  { "be_${FW_BACKEND}_reset"; }

# 各后端默认策略能力说明（不支持的能力要明确提示，不得静默失败）
fw_capability_note() {
    case "${FW_BACKEND}" in
        iptables)
            [ "${HAS_V6}" -eq 0 ] && log_warn "当前系统无 IPv6 支持，IPv6 规则已自动跳过"
            ;;
        nftables)
            log_info "nftables 使用 inet 表，IPv4/IPv6 规则在同一表中统一生效"
            [ "${HAS_V6}" -eq 0 ] && log_warn "内核可能未启用 IPv6，inet 表中的 ip6 规则不会命中"
            ;;
        firewalld)
            log_warn "firewalld 出站过滤需借助 --direct 直写 OUTPUT 链，优先级低于 rich rule"
            ;;
        ufw)
            log_info "ufw 默认策略通过 ufw default 设置，与 DSL 中的 IN/OUT_POLICY 对应"
            ;;
    esac
}

# ============================================================================
#  第 6 节：持久化（iptables / nftables 需要显式保存）
# ============================================================================
PERSIST_MODE=""

detect_persist_mode() {
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^iptables.service'; then
        PERSIST_MODE="iptables-services"
    elif command -v netfilter-persistent >/dev/null 2>&1; then
        PERSIST_MODE="netfilter-persistent"
    elif [ -d /etc/iptables ]; then
        PERSIST_MODE="manual-rules"
    elif command -v systemctl >/dev/null 2>&1; then
        PERSIST_MODE="systemd-unit"
    else
        PERSIST_MODE="rc-local"
    fi
}

persist_iptables() {
    log_step "持久化方式: ${PERSIST_MODE}"
    case "${PERSIST_MODE}" in
        iptables-services)
            if command -v service >/dev/null 2>&1; then
                service iptables save >/dev/null 2>&1 && log_info "已写入 /etc/sysconfig/iptables"
                if [ "${NEED_V6}" -eq 1 ] && [ "${HAS_V6}" -eq 1 ]; then
                    service ip6tables save >/dev/null 2>&1 && log_info "已写入 /etc/sysconfig/ip6tables"
                fi
            else
                iptables-save > /etc/sysconfig/iptables 2>/dev/null
                [ "${NEED_V6}" -eq 1 ] && [ "${HAS_V6}" -eq 1 ] && ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null
            fi
            systemctl enable iptables >/dev/null 2>&1
            [ "${NEED_V6}" -eq 1 ] && [ "${HAS_V6}" -eq 1 ] && systemctl enable ip6tables >/dev/null 2>&1
            log_info "已设置开机自启 (iptables / ip6tables)"
            ;;
        netfilter-persistent)
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            [ "${NEED_V6}" -eq 1 ] && [ "${HAS_V6}" -eq 1 ] && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
            netfilter-persistent save >/dev/null 2>&1
            systemctl enable netfilter-persistent >/dev/null 2>&1
            log_info "已通过 netfilter-persistent 保存并启用开机自启"
            ;;
        *)
            mkdir -p /etc/iptables
            local v4f="/etc/iptables/rules.v4" v6f="/etc/iptables/rules.v6"
            iptables-save > "${v4f}" 2>/dev/null
            [ "${NEED_V6}" -eq 1 ] && [ "${HAS_V6}" -eq 1 ] && ip6tables-save > "${v6f}" 2>/dev/null
            log_info "规则已写入 ${v4f} / ${v6f}"
            install_boot_service "${v4f}" "${v6f}"
            ;;
    esac
    if [ "${HAS_DOCKER}" -eq 1 ]; then
        log_warn "检测到 Docker：规则快照包含 Docker 链，重启 iptables 后建议 systemctl restart docker 重建容器网络规则"
    fi
}

install_boot_service() {
    local v4f="$1" v6f="$2"
    if command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/iptables-custom.service <<EOF
[Unit]
Description=Restore custom iptables rules (setup_firewall.sh)
Before=network-pre.target
Wants=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore ${v4f}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        if [ "${NEED_V6}" -eq 1 ] && [ "${HAS_V6}" -eq 1 ]; then
            sed -i "s#^RemainAfterExit=yes#ExecStart=/sbin/ip6tables-restore ${v6f}\nRemainAfterExit=yes#" \
                /etc/systemd/system/iptables-custom.service
        fi
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable iptables-custom >/dev/null 2>&1
        log_info "已安装并启用 systemd 服务: iptables-custom.service"
        return 0
    fi
    if [ -f /etc/rc.local ]; then
        grep -q 'iptables-restore' /etc/rc.local || cat >> /etc/rc.local <<EOF
[ -f ${v4f} ] && /sbin/iptables-restore < ${v4f}
[ -f ${v6f} ] && /sbin/ip6tables-restore < ${v6f}
EOF
        chmod +x /etc/rc.local
        log_info "已写入 /etc/rc.local"
    else
        log_warn "无法自动设置开机自启，请手工配置 iptables-restore"
    fi
}

# ============================================================================
#  第 7 节：备份 / 回滚
# ============================================================================
snapshot_current() {
    # 生成当前运行时规则的"还原脚本"，跨后端可用
    local f="$1"
    : > "${f}"
    case "${FW_BACKEND}" in
        iptables|nftables)
            command -v iptables-save >/dev/null 2>&1 && iptables-save >> "${f}" 2>/dev/null
            ;;
        nftables)
            command -v nft >/dev/null 2>&1 && nft list ruleset >> "${f}" 2>/dev/null
            ;;
        firewalld)
            firewall-cmd --list-all-zones >> "${f}" 2>/dev/null
            ;;
        ufw)
            ufw status verbose >> "${f}" 2>/dev/null
            ;;
    esac
}

backup_rules() {
    local tag="${1:-manual}" ts d
    ts="$(date +%Y%m%d-%H%M%S)"
    d="${BACKUP_DIR}/${ts}-${tag}"
    mkdir -p "${d}"
    snapshot_current "${d}/snapshot.txt"
    cp -a "${CONF_DIR}"/rules.dsl "${CONF_DIR}"/policy.conf "${CONF_DIR}"/sshguard.conf "${d}/" 2>/dev/null
    cp -a "${CONF_DIR}"/.undo.*.sh "${d}/" 2>/dev/null
    echo "${d}"
}

restore_snapshot() {
    # 尽力而为的还原：iptables/nft 可精确还原，firewalld/ufw 仅提供快照供人工比对
    local f="$1"
    case "${FW_BACKEND}" in
        iptables)
            iptables-restore < "${f}" && log_info "IPv4 规则已还原"
            [ "${HAS_V6}" -eq 1 ] && ip6tables-restore < "${f}" 2>/dev/null
            ;;
        nftables)
            nft -f "${f}" && log_info "nftables 规则集已还原"
            ;;
        *)
            log_warn "firewalld / ufw 后端无法直接还原快照，请用下列命令撤销："
            local undo; undo="$(undo_file)"
            [ -s "${undo}" ] && bash "${undo}"
            ;;
    esac
}

list_backups() { find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r; }

rollback_menu() {
    local dirs d i=1 choice selected
    dirs="$(list_backups)"
    [ -z "${dirs}" ] && { log_warn "没有可用备份"; return; }
    printf '\n可用备份:\n'; hr
    while IFS= read -r d; do printf '  %2d) %s\n' "$i" "$(basename "$d")"; i=$((i+1)); done <<< "${dirs}"
    hr
    read -r -p "选择要恢复的备份编号 (0 取消): " choice
    [ -z "${choice}" ] || [ "${choice}" -eq 0 ] 2>/dev/null && return
    selected="$(sed -n "${choice}p" <<< "${dirs}")"
    [ -z "${selected}" ] && { log_err "编号不存在"; return; }
    read -r -p "确认从 $(basename "${selected}") 恢复? [y/N]: " ans
    [ "${ans:-N}" = "y" ] || return
    restore_snapshot "${selected}/snapshot.txt"
    for f in rules.dsl policy.conf sshguard.conf; do
        [ -f "${selected}/${f}" ] && cp -f "${selected}/${f}" "${CONF_DIR}/${f}"
    done
    # shellcheck disable=SC1090
    . "${F_POLICY}"
    # shellcheck disable=SC1090
    . "${F_SSHGUARD}"
    log_info "回滚完成"
}

# ============================================================================
#  第 8 节：应用（含防锁死保护）
# ============================================================================
ensure_ssh_allowed() {
    local p="${SSH_PORT}" found=0
    while IFS= read -r line || [ -n "${line}" ]; do
        [ -z "${line}" ] && continue
        case "${line}" in \#*) continue ;; esac
        # shellcheck disable=SC2086
        set -- ${line}
        # 入站 accept 且端口列命中 SSH 端口
        if [ "${1:-}" = "in" ] && [ "${2:-}" = "accept" ] && [ "${4:--}" != "-" ]; then
            printf '%s' "${4}" | tr ',' '\n' | grep -qx -- "${p}" && found=1
        fi
        # 整段来源放行也视为放行
        if [ "${1:-}" = "in" ] && [ "${2:-}" = "accept" ] && [ "${5:--}" != "-" ]; then found=1; fi
    done < "${F_RULES}"
    [ "${found}" -eq 1 ] && return 0

    printf "${C_Y}检测到入站将设为严格模式，但规则列表中没有放行 SSH 端口 %s${C_N}\n" "${p}"
    read -r -p "是否立即放行 SSH ${p}/tcp ? [Y/n]: " ans
    [ "${ans:-Y}" = "n" ] && return 1
    dsl_add "in accept tcp ${p} - -"
    return 0
}

apply_with_confirm() {
    local d
    fw_precheck || die "后端 ${FW_BACKEND} 预检未通过，已中止"

    d="$(backup_rules pre-apply)"
    log_info "已自动备份到: ${d}"

    if [ "${IN_POLICY:-DROP}" = "DROP" ]; then
        ensure_ssh_allowed || die "为避免 SSH 锁死已中止；请先放行 SSH（当前端口 ${SSH_PORT}）"
    fi

    fw_capability_note

    if ! fw_apply; then
        die "规则应用失败，已保留改动前的备份: ${d}"
    fi
    log_info "规则已应用到运行时"

    # 非交互环境（如 cron / 管道）无法确认，直接保留
    [ ! -t 0 ] && { log_warn "非交互环境，跳过确认，规则已保留"; return 0; }

    printf '\n'; hr
    printf "${C_Y}若此时 SSH 断开且未确认，%s 秒后将自动回滚。${C_N}\n" "${CONFIRM_TIMEOUT}"
    hr
    local ans
    read -r -t "${CONFIRM_TIMEOUT}" -p "确认保留请输入 y [y/N]: " ans
    if [ "${ans:-N}" = "y" ] || [ "${ans:-N}" = "Y" ]; then
        log_info "已确认，规则保留"
        return 0
    fi
    echo
    log_warn "未收到确认或超时，正在回滚 ..."
    fw_reset_be
    [ -f "${d}/snapshot.txt" ] && restore_snapshot "${d}/snapshot.txt"
    log_info "已回滚到应用前状态"
}

# ============================================================================
#  第 9 节：服务预设模板
# ============================================================================
declare -A SVC_PRESETS=(
    ["ssh"]="in accept tcp 22 - -"
    ["http"]="in accept tcp 80 - -"
    ["https"]="in accept tcp 443 - -"
    ["dns"]="in accept udp 53 - -"
    ["ntp"]="in accept udp 123 - -"
    ["mysql"]="in accept tcp 3306 - -"
    ["oracle"]="in accept tcp 1521 - -"
    ["oracle-em"]="in accept tcp 5500 - -"
    ["postgres"]="in accept tcp 5432 - -"
    ["redis"]="in accept tcp 6379 - -"
    ["nfs"]="in accept tcp 111,2049,20048 - -"
    ["samba"]="in accept tcp 139,445 - -"
    ["ftp"]="in accept tcp 20,21 - -"
    ["smtp"]="in accept tcp 25,465,587 - -"
    ["imap"]="in accept tcp 143,993 - -"
    ["dhcp"]="in accept udp 67,68 - -"
    ["zabbix"]="in accept tcp 10050 - -"
    ["k8s-api"]="in accept tcp 6443 - -"
)

service_preset_menu() {
    local keys=(ssh http https dns ntp mysql oracle oracle-em postgres redis
                nfs samba ftp smtp imap dhcp zabbix k8s-api)
    local i=1 k
    printf '\n%s\n' "常用服务预设模板（入站放行）"
    hr
    for k in "${keys[@]}"; do printf '  %2d) %-12s %s\n' "$i" "${k}" "${SVC_PRESETS[${k}]}"; i=$((i+1)); done
    printf '   0) 返回\n'
    hr
    read -r -p "选择服务编号 (支持逗号分隔多选, 0 返回): " sel
    [ -z "${sel}" ] || [ "${sel}" = "0" ] && return
    local part idx
    IFS=',' read -ra part <<< "${sel}"
    for p in "${part[@]:-}"; do
        p="$(printf '%s' "${p}" | tr -d ' ')"
        printf '%s' "${p}" | grep -qE '^[0-9]+$' || continue
        idx=$((p))
        [ "${idx}" -ge 1 ] && [ "${idx}" -le "${#keys[@]}" ] || continue
        k="${keys[$((idx-1))]}"
        dsl_add "${SVC_PRESETS[${k}]}"
        [ "${k}" = "samba" ] && dsl_add "in accept udp 137,138 - -"
        [ "${k}" = "dns" ]   && dsl_add "in accept tcp 53 - -"
    done
}

# ============================================================================
#  第 10 节：菜单
# ============================================================================
ask_port_rule() {
    local proto="$1" ports src
    read -r -p "端口号（支持 80,443 或 8000:9000 范围）: " ports
    [ -z "${ports}" ] && { log_err "端口不能为空"; return; }
    read -r -p "限定来源 IP/网段（留空=不限）: " src
    dsl_add "in accept ${proto} ${ports} ${src:--} -"
}

inbound_menu() {
    while true; do
        printf '\n'
        printf "${C_B}========= 入站规则管理 (%s 后端) =========${C_N}\n" "${FW_BACKEND}"
        printf '  1) 放行端口 (TCP)\n'
        printf '  2) 放行端口 (UDP)\n'
        printf '  3) 放行服务（预设模板）\n'
        printf '  4) 放行来源 IP（该来源全端口通行）\n'
        printf '  5) 封禁来源 IP / 网段\n'
        printf '  6) 查看当前规则\n'
        printf '  7) 删除规则\n'
        printf '  0) 返回主菜单\n'
        hr
        read -r -p "请选择: " c
        case "${c}" in
            1) ask_port_rule tcp ;;
            2) ask_port_rule udp ;;
            3) service_preset_menu ;;
            4) read -r -p "来源 IP/网段: " src;  [ -n "${src}" ] && dsl_add "in accept any - ${src} -" ;;
            5)
                read -r -p "要封禁的 IP/网段: " src
                [ -z "${src}" ] && continue
                read -r -p "动作 1) DROP 2) REJECT [1]: " act
                local a="drop"; [ "${act:-1}" = "2" ] && a="reject"
                read -r -p "仅封禁指定端口？（留空=全部）: " p
                local pr="any"
                if [ -n "${p}" ]; then
                    read -r -p "协议 tcp/udp [tcp]: " x; pr="${x:-tcp}"
                    dsl_add "in ${a} ${pr} ${p} ${src} -"
                else
                    dsl_add "in ${a} any - ${src} -"
                fi
                ;;
            6) dsl_list; read -r -p "按回车继续..." ;;
            7) dsl_delete ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

outbound_menu() {
    while true; do
        printf '\n'
        printf "${C_B}========= 出站规则管理 (%s 后端) =========${C_N}\n" "${FW_BACKEND}"
        printf '  当前出站默认策略: %s\n' "${OUT_POLICY:-ACCEPT}"
        printf '  1) 放行到目标 IP/端口\n'
        printf '  2) 拒绝到目标 IP/端口\n'
        printf '  3) 查看规则\n'
        printf '  4) 删除规则\n'
        printf '  5) 切换出站默认策略 (ACCEPT <-> DROP)\n'
        printf '  0) 返回主菜单\n'
        hr
        read -r -p "请选择: " c
        case "${c}" in
            1) out_add_rule accept ;;
            2) out_add_rule drop ;;
            3) dsl_list; read -r -p "按回车继续..." ;;
            4) dsl_delete ;;
            5)
                if [ "${OUT_POLICY:-ACCEPT}" = "ACCEPT" ]; then
                    printf "${C_Y}切换为 DROP 后，未显式放行的出站流量都会被拒绝，"
                    printf "可能导致 yum/apt、DNS、NTP 失效。${C_N}\n"
                    read -r -p "确认切换为严格出站? [y/N]: " a
                    [ "${a:-N}" = "y" ] && set_policy OUT_POLICY DROP
                else
                    set_policy OUT_POLICY ACCEPT
                fi
                ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

out_add_rule() {
    local act="$1" dst proto ports
    read -r -p "目标 IP/网段（留空=任意）: " dst
    read -r -p "协议 tcp/udp（留空=不限）: " proto
    read -r -p "目标端口（留空=不限）: " ports
    dsl_add "out ${act} ${proto:-any} ${ports:--} - ${dst:--}"
}

set_policy() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" "${F_POLICY}" 2>/dev/null; then
        sed -i "s#^${key}=.*#${key}=${val}#" "${F_POLICY}"
    else
        printf '%s=%s\n' "${key}" "${val}" >> "${F_POLICY}"
    fi
    # shellcheck disable=SC1090
    . "${F_POLICY}"
    log_info "已设置 ${key}=${val}（需重新应用后生效）"
}

policy_menu() {
    while true; do
        printf '\n'
        printf "${C_B}========= 默认策略 (%s 后端) =========${C_N}\n" "${FW_BACKEND}"
        printf '  1) INPUT  当前: %-7s -> 切换为 %s\n' \
            "${IN_POLICY:-DROP}" "$([ "${IN_POLICY:-DROP}" = "DROP" ] && echo ACCEPT || echo DROP)"
        printf '  2) OUTPUT 当前: %-7s -> 切换为 %s\n' \
            "${OUT_POLICY:-ACCEPT}" "$([ "${OUT_POLICY:-ACCEPT}" = "DROP" ] && echo ACCEPT || echo DROP)"
        printf '  3) FORWARD 当前: %-7s -> 切换为 %s\n' \
            "${FWD_POLICY:-ACCEPT}" "$([ "${FWD_POLICY:-ACCEPT}" = "DROP" ] && echo ACCEPT || echo DROP)"
        printf '  0) 返回主菜单\n'
        hr
        case "${FW_BACKEND}" in
            firewalld) log_warn "firewalld 后端下 FORWARD 由 firewalld 自身管理，建议不要在此修改" ;;
            ufw)       log_warn "ufw 后端下 FORWARD 由 ufw 管理，建议不要在此修改" ;;
        esac
        read -r -p "请选择: " c
        case "${c}" in
            1) set_policy IN_POLICY  "$([ "${IN_POLICY:-DROP}" = "DROP" ] && echo ACCEPT || echo DROP)" ;;
            2) set_policy OUT_POLICY "$([ "${OUT_POLICY:-ACCEPT}" = "DROP" ] && echo ACCEPT || echo DROP)" ;;
            3) set_policy FWD_POLICY "$([ "${FWD_POLICY:-ACCEPT}" = "DROP" ] && echo ACCEPT || echo DROP)" ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

set_sshguard() {
    local key="$1" val="$2"
    if grep -qE "^${key}=" "${F_SSHGUARD}" 2>/dev/null; then
        sed -i "s#^${key}=.*#${key}=${val}#" "${F_SSHGUARD}"
    else
        printf '%s=%s\n' "${key}" "${val}" >> "${F_SSHGUARD}"
    fi
    # shellcheck disable=SC1090
    . "${F_SSHGUARD}"
    log_info "已设置 ${key}=${val}（需重新应用后生效）"
}

sshguard_menu() {
    while true; do
        printf '\n'
        printf "${C_B}========= SSH 防暴力破解 (%s 后端) =========${C_N}\n" "${FW_BACKEND}"
        printf '  状态    : %s\n' "$([ "${ENABLED:-0}" -eq 1 ] && echo '已启用' || echo '未启用')"
        printf '  端口    : %s\n' "${PORT:-22}"
        printf '  时间窗  : %s 秒\n' "${WINDOW:-60}"
        printf '  触发次数: %s\n' "${HITCOUNT:-5}"
        hr
        case "${FW_BACKEND}" in
            iptables)  printf '  实现方式: recent 模块（--update --hitcount）\n' ;;
            nftables)  printf '  实现方式: nft meter（按源 IP 限流）\n' ;;
            firewalld) printf '  实现方式: rich rule limit value=N/m\n' ;;
            ufw)       printf '  实现方式: ufw limit（内置限速）\n' ;;
        esac
        hr
        printf '  1) 启用 / 禁用\n  2) 设置 SSH 端口\n  3) 设置时间窗（秒）\n  4) 设置触发次数\n  0) 返回主菜单\n'
        hr
        read -r -p "请选择: " c
        case "${c}" in
            1) set_sshguard ENABLED "$([ "${ENABLED:-0}" -eq 1 ] && echo 0 || echo 1)" ;;
            2) read -r -p "SSH 端口: " v; set_sshguard PORT "${v}" ;;
            3) read -r -p "时间窗（秒）: " v; set_sshguard WINDOW "${v}" ;;
            4) read -r -p "触发次数: " v; set_sshguard HITCOUNT "${v}" ;;
            0) return ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

show_status() {
    printf '\n'
    printf "${C_B}========= 系统与环境 =========${C_N}\n"
    printf '  发行版      : %s %s (%s)\n' "${DISTRO_NAME}" "${DISTRO_VER}" "${DISTRO_ID}"
    printf '  防火墙后端  : %s\n' "${FW_BACKEND}"
    printf '  选定原因    : %s\n' "${FW_BACKEND_REASON}"
    printf '  持久化方式  : %s\n' "${PERSIST_MODE}"
    printf '  IPv6        : 支持=%s 本次配置=%s\n' \
        "$([ "${HAS_V6}" -eq 1 ] && echo yes || echo no)" \
        "$([ "${NEED_V6}" -eq 1 ] && echo yes || echo no)"
    printf '  Docker      : %s\n' "$([ "${HAS_DOCKER}" -eq 1 ] && echo '检测到' || echo '未检测到')"
    printf '  当前 SSH 端口: %s\n' "${SSH_PORT}"
    printf '  规则条数    : %s\n' "$(count_rules "${F_RULES}")"
    printf '  配置目录    : %s\n' "${CONF_DIR}"
    printf '\n'
    printf "${C_B}========= 后端运行状态 =========${C_N}\n"
    fw_status_be
    read -r -p "按回车继续..."
}

toggle_v6() {
    if [ "${HAS_V6}" -eq 0 ]; then
        log_warn "当前系统不支持 IPv6，无法开启"
        return
    fi
    case "${FW_BACKEND}" in
        nftables) log_warn "nftables 使用 inet 表，IPv4/IPv6 始终同时生效，此开关不产生作用" ;;
        firewalld|ufw) log_warn "${FW_BACKEND} 后端下 IPv6 由后端统一管理，此开关仅影响是否写入 ip6 规则" ;;
    esac
    NEED_V6=$((1 - NEED_V6))
    save_env
    log_info "IPv6 配置已切换为: $([ "${NEED_V6}" -eq 1 ] && echo 开启 || echo 关闭)"
}

reset_all() {
    printf "${C_R}这将清空本脚本管理的所有规则，并恢复为全放行。${C_N}\n"
    read -r -p "确认重置? [y/N]: " a
    [ "${a:-N}" = "y" ] || return
    backup_rules pre-reset >/dev/null
    cat > "${F_RULES}" <<'EOF'
# 规则 DSL：<方向> <动作> <协议> <端口> <源> <目的>
#   方向: in | out        动作: accept | drop | reject
#   协议: tcp | udp | any 端口: 22 | 80,443 | 8000:9000
#   源/目的: IP 或 CIDR，不限填 -
EOF
    set_policy IN_POLICY ACCEPT
    set_policy OUT_POLICY ACCEPT
    set_policy FWD_POLICY ACCEPT
    set_sshguard ENABLED 0
    fw_reset_be
    log_info "已重置为全放行状态"
}

main_menu() {
    while true; do
        printf '\n'
        printf "${C_C}===============================================================${C_N}\n"
        printf "${C_C}   交互式防火墙配置  v%s    后端: %s${C_N}\n" "${SCRIPT_VERSION}" "${FW_BACKEND}"
        printf "${C_C}===============================================================${C_N}\n"
        printf '  1) 查看当前状态\n'
        printf '  2) 入站规则管理   (放行/封禁/服务模板)\n'
        printf '  3) 出站规则管理   (放行/拒绝)\n'
        printf '  4) 默认策略设置\n'
        printf '  5) SSH 防暴力破解\n'
        printf '  6) IPv6 配置开关  当前: %s\n' "$([ "${NEED_V6}" -eq 1 ] && echo 开启 || echo 关闭)"
        printf '  --\n'
        printf '  7) 应用规则到运行时（试运行，需确认）\n'
        printf '  8) 保存并持久化（开机自启）\n'
        printf '  9) 备份与回滚\n'
        printf ' 10) 重置为全放行\n'
        printf '  0) 退出\n'
        hr
        read -r -p "请选择: " c
        case "${c}" in
            1) show_status ;;
            2) inbound_menu ;;
            3) outbound_menu ;;
            4) policy_menu ;;
            5) sshguard_menu ;;
            6) toggle_v6 ;;
            7) apply_with_confirm ;;
            8) fw_precheck && { fw_apply; fw_persist; } ;;
            9)
                printf '  1) 立即备份\n  2) 查看/恢复备份\n'
                read -r -p "选择: " b
                case "${b}" in
                    1) log_info "备份已保存: $(backup_rules manual)" ;;
                    2) rollback_menu ;;
                esac
                ;;
            10) reset_all ;;
            0) save_env; log_info "已退出"; exit 0 ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

# ============================================================================
#  第 11 节：入口
# ============================================================================
main() {
    # 二次确认（提权后理论上必为 root；此处兜底防止直接 sudo env 绕过的异常场景）
    [ "$(id -u)" -eq 0 ] || die "权限不足：请以 root 运行或允许 sudo 提权"

    detect_env
    detect_backend
    detect_persist_mode
    init_conf

    printf '\n'
    log_info "环境: ${DISTRO_NAME} ${DISTRO_VER} (${DISTRO_ID})"
    log_info "防火墙后端: ${FW_BACKEND}  ——  ${FW_BACKEND_REASON}"
    [ "${HAS_DOCKER}" -eq 1 ] && log_warn "Docker 环境：不会触碰 nat 表与 FORWARD 默认策略，容器网络不受影响"

    fw_precheck || die "后端 ${FW_BACKEND} 预检失败，无法继续。请检查对应服务是否可用"
    fw_capability_note
    main_menu
}

main "$@"
