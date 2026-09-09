#!/usr/bin/env bash
# =============================================================================
#  set_mirror.sh - Linux 软件源（镜像源）管理工具
# =============================================================================
#
#  功能:
#    1. 自动识别发行版与版本，自动选择对应包管理器与源配置文件路径/格式
#       - Debian / Ubuntu / Deepin / UOS / Kali / Raspbian ...   -> apt
#       - CentOS / RHEL / Rocky / AlmaLinux / Fedora / openEuler  -> yum|dnf
#       - Alpine                                                 -> apk
#       - openSUSE Leap / Tumbleweed / SLES                      -> zypper
#    2. 交互式菜单 + 命令行参数双模式；列出候选源 / 手动指定 URL / 一键恢复默认
#    3. 修改前自动备份，支持 --rollback 回滚；重复执行幂等；失败安全退出
#    4. 内置连通性(HTTP 状态码)与速度(延迟/下载速率)检测，按结果排序自动选最优
#    5. 自动处理 GPG 密钥：识别 NO_PUBKEY / 签名无效 / 公钥过期，下载导入并复检
#    6. --dry-run 预演；全程操作日志；修改后自动执行索引更新验证
#
#  运行方式（均需 root 权限，脚本非 root 时会自动尝试 sudo / pkexec 提权）:
#     Debian/Ubuntu : sudo bash set_mirror.sh
#     CentOS/RHEL   : sudo bash set_mirror.sh
#     Alpine        : sudo sh -c 'apk add bash curl && bash set_mirror.sh'
#     openSUSE      : sudo bash set_mirror.sh
#
#  依赖: bash >= 4.0, curl（必需）, gpg（修复密钥时建议有）, ca-certificates
#        缺失时脚本会明确提示对应发行版的安装命令，不会静默失败。
#
#  常用命令:
#     交互菜单        sudo bash set_mirror.sh
#     列出候选源      bash set_mirror.sh --list
#     测速并选最优    sudo bash set_mirror.sh --auto
#     指定镜像        sudo bash set_mirror.sh --set aliyun
#     自定义 URL      sudo bash set_mirror.sh --set https://mirrors.example.com/debian
#     预演            sudo bash set_mirror.sh --set aliyun --dry-run
#     恢复默认源      sudo bash set_mirror.sh --restore
#     回滚上一次修改  sudo bash set_mirror.sh --rollback
#
# =============================================================================

set -uo pipefail

# =============================================================================
#  第 1 节  全局变量、日志与基础工具
# =============================================================================

SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# ---- 颜色（非 tty 或 NO_COLOR 时自动关闭）----
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'
    C_B=$'\033[34m'; C_C=$'\033[36m'; C_M=$'\033[35m'; C_N=$'\033[0m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_C=''; C_M=''; C_N=''
fi

# ---- 运行期选项 ----
DRY_RUN="${DRY_RUN:-0}"             # 预演：不落盘、不执行变更类命令
ASSUME_YES="${ASSUME_YES:-0}"          # 非交互
VERBOSE="${VERBOSE:-0}"             # 调试输出
NO_UPDATE="${NO_UPDATE:-0}"           # 修改后不执行索引更新
NO_GPG_FIX="${NO_GPG_FIX:-0}"          # 不自动修复 GPG
INSECURE="${INSECURE:-0}"            # curl -k
NET_TIMEOUT="${NET_TIMEOUT:-8}"     # 单次探测超时(秒)
MAX_PARALLEL="${MAX_PARALLEL:-6}"   # 测速并发度
SPEED_URL="${SPEED_URL:-}"          # 自定义测速大文件 URL
ACTION=""             # list / set / add / restore / rollback / backup-list / test / status / fixgpg / update
TARGET_SPEC=""        # --set/--add 的值
MANUAL_DISTRO="${MANUAL_DISTRO:-}"      # --distro
MANUAL_VERSION="${MANUAL_VERSION:-}"     # --version
FORCE_EOL="${FORCE_EOL:-0}"           # 强制按 EOL(归档源)处理
WITH_EPEL="${WITH_EPEL:-1}"           # RHEL 系是否附带 EPEL
WITH_SRC="${WITH_SRC:-0}"            # apt 是否附带 deb-src

# ---- 路径（可用环境变量覆盖，便于测试与非标准系统）----
STATE_DIR="${STATE_DIR:-/var/lib/set-mirror}"
BACKUP_DIR="${BACKUP_DIR:-${STATE_DIR}/backups}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/state.env}"
LOCK_DIR="${LOCK_DIR:-/var/lock/set-mirror.lock}"
ORIG_SNAPSHOT="${BACKUP_DIR}/orig"

OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
LSB_RELEASE_FILE="${LSB_RELEASE_FILE:-/etc/lsb-release}"
DEBIAN_VERSION_FILE="${DEBIAN_VERSION_FILE:-/etc/debian_version}"
REDHAT_RELEASE_FILE="${REDHAT_RELEASE_FILE:-/etc/redhat-release}"
ALPINE_RELEASE_FILE="${ALPINE_RELEASE_FILE:-/etc/alpine-release}"
SUSE_RELEASE_FILE="${SUSE_RELEASE_FILE:-/etc/SuSE-release}"

APT_SOURCES_LIST="${APT_SOURCES_LIST:-/etc/apt/sources.list}"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
APT_MANAGED_FILE="${APT_MANAGED_FILE:-${APT_SOURCES_DIR}/zz-set-mirror.list}"
APT_TRUSTED_DIR="${APT_TRUSTED_DIR:-/etc/apt/trusted.gpg.d}"
APT_KEYRING_DIR="${APT_KEYRING_DIR:-/etc/apt/keyrings}"

YUM_REPO_DIR="${YUM_REPO_DIR:-/etc/yum.repos.d}"
YUM_MANAGED_FILE="${YUM_MANAGED_FILE:-${YUM_REPO_DIR}/zz-set-mirror.repo}"
RPM_GPG_DIR="${RPM_GPG_DIR:-/etc/pki/rpm-gpg}"

APK_REPOS_FILE="${APK_REPOS_FILE:-/etc/apk/repositories}"
APK_KEYS_DIR="${APK_KEYS_DIR:-/etc/apk/keys}"

ZYPP_REPO_DIR="${ZYPP_REPO_DIR:-/etc/zypp/repos.d}"
ZYPP_MANAGED_FILE="${ZYPP_MANAGED_FILE:-${ZYPP_REPO_DIR}/zz-set-mirror.repo}"

# ---- 检出结果（由 detect_os 填充）----
OS_ID=""; OS_NAME=""; OS_VER=""; OS_MAJOR=""; OS_CODENAME=""
OS_FAMILY=""        # debian | rhel | alpine | suse
PM=""               # apt | dnf | yum | apk | zypper
ARCH=""
OS_EOL=0            # 1 表示该系统已 EOL，应使用归档源
DETECT_NOTES=""

# ---- 镜像选择结果 ----
MIRROR_ID=""; MIRROR_NAME=""; MIRROR_URL=""; MIRROR_SEC_URL=""
DESIRED_CONTENT=""

# ---- 快照（备份/回滚）----
SNAP_DIR=""; SNAP_MAP=""
TMP_DIR=""

# =============================================================================
#  第 2 节  日志输出
# =============================================================================

_ts() { date '+%H:%M:%S'; }

log_info() { printf "${C_B}[INFO]${C_N}  %s\n" "$*"; }
log_ok()   { printf "${C_G}[ OK ]${C_N}  %s\n" "$*"; }
log_warn() { printf "${C_Y}[WARN]${C_N}  %s\n" "$*" >&2; }
log_err()  { printf "${C_R}[ERROR]${C_N} %s\n" "$*" >&2; }
log_step() { printf "\n${C_C}==>${C_N} ${C_B}%s${C_N}\n" "$*"; }
log_dbg()  { [ "${VERBOSE}" -eq 1 ] && printf "${C_M}[DBG]${C_N}   %s\n" "$*" >&2; return 0; }
log_dry()  { printf "${C_M}[DRY]${C_N}   %s\n" "$*"; }

hr() { printf '%s\n' "---------------------------------------------------------------"; }
sec() { printf "\n%s\n" "${C_C}=========== $* ===========${C_N}"; }

# 统一失败出口：打印错误并退出
die() {
    printf "${C_R}[FATAL]${C_N} %s\n" "$*" >&2
    exit 1
}

# =============================================================================
#  第 3 节  权限检测与提权
# =============================================================================

IS_ROOT=0
can_elevate=0

check_root() {
    local uid
    uid="$(id -u 2>/dev/null)"
    case "${uid}" in ''|*[!0-9]*) uid=1000 ;; esac
    IS_ROOT=0
    [ "${uid}" -eq 0 ] && IS_ROOT=1
    return 0
}

# 非 root 时自动提权重执行本脚本；参数与环境变量均保留
ensure_root() {
    check_root
    [ "${IS_ROOT}" -eq 1 ] && return 0

    local self="${BASH_SOURCE[0]}"
    command -v readlink >/dev/null 2>&1 && {
        local rp; rp="$(readlink -f "${self}" 2>/dev/null)"
        [ -n "${rp}" ] && self="${rp}"
    }

    log_warn "当前非 root 用户（uid=$(id -u 2>/dev/null)），软件源配置需要管理员权限"

    if [ -n "${SET_MIRROR_ELEVATED:-}" ]; then
        log_err "已尝试提权但仍未获得 root 权限，终止执行以避免产生不一致的配置"
        exit 1
    fi

    if command -v sudo >/dev/null 2>&1; then
        log_info "检测到 sudo，正在请求提权: sudo bash ${self} $*"
        exec sudo --preserve-env=NET_TIMEOUT,MAX_PARALLEL,SPEED_URL,NO_COLOR \
             env SET_MIRROR_ELEVATED=1 bash "${self}" "$@"
    fi

    if command -v pkexec >/dev/null 2>&1; then
        log_info "检测到 pkexec，正在请求提权"
        exec pkexec env SET_MIRROR_ELEVATED=1 bash "${self}" "$@"
    fi

    log_err "未找到可用的提权工具（sudo / pkexec），无法修改软件源"
    log_err "请以 root 身份重新执行，例如："
    log_err "    su - root -c 'bash ${self} $*'"
    exit 1
}

# 变更类操作前统一要求 root；读操作不需要
require_root() {
    check_root
    if [ "${IS_ROOT}" -ne 1 ]; then
        if [ "${DRY_RUN}" -eq 1 ]; then
            log_warn "非 root 用户：预演模式仅展示操作，不会实际写入"
            return 0
        fi
        ensure_root "$@"
    fi
    return 0
}

# =============================================================================
#  第 4 节  通用工具：命令执行、文件写入、依赖检查
# =============================================================================

# 执行命令并校验退出码；失败时输出可定位信息（命令 / 退出码 / 输出尾部）
# 用法: run <描述> <命令> [参数...]
run() {
    local desc="$1"; shift
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dry "将执行: $*"
        return 0
    fi
    log_dbg "执行: $*"
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [ -n "${out}" ]; then
        printf '%s\n' "${out}" | sed 's/^/        | /'
    fi
    if [ "${rc}" -ne 0 ]; then
        log_err "${desc} 失败（退出码 ${rc}）"
        log_err "  命令: $*"
        return "${rc}"
    fi
    return 0
}

# 执行命令并捕获输出（用于解析，如 apt update 的 NO_PUBKEY）
# 用法: out="$(run_capture <命令> [参数...])"
run_capture() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dry "将执行(捕获输出): $*"
        return 0
    fi
    "$@" 2>&1
}

# 原子写文件；dry-run 时打印预览
# 用法: fs_write <路径> <内容> [权限]
fs_write() {
    local path="$1" content="$2" mode="${3:-0644}"
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dry "写入文件: ${path} (权限 ${mode})"
        printf '%s\n' "${content}" | sed 's/^/        > /'
        return 0
    fi
    local d; d="$(dirname "${path}")"
    mkdir -p "${d}" 2>/dev/null || { log_err "创建目录失败: ${d}"; return 1; }
    local tmp="${path}.tmp.$$"
    printf '%s\n' "${content}" > "${tmp}" || { log_err "写入临时文件失败: ${tmp}"; return 1; }
    chmod "${mode}" "${tmp}" 2>/dev/null
    mv -f "${tmp}" "${path}" || { rm -f "${tmp}"; log_err "替换文件失败: ${path}"; return 1; }
    return 0
}

# 备份单文件并原子替换（内部用：先 snapshot 再 fs_write）
fs_replace() {
    local path="$1" content="$2" mode="${3:-0644}"
    snapshot_file "${path}" || return 1
    fs_write "${path}" "${content}" "${mode}"
}

# 依赖检查：curl 必需，gpg 建议
check_deps() {
    local missing=0
    if ! command -v curl >/dev/null 2>&1; then
        log_err "缺少必需依赖: curl（用于源可用性与速度检测）"
        missing=1
    fi
    if [ "${NO_GPG_FIX}" -eq 0 ] && ! command -v gpg >/dev/null 2>&1; then
        log_warn "未检测到 gpg：GPG 密钥自动修复将降级为直接下载 key 文件方式"
    fi
    if [ "${missing}" -eq 1 ]; then
        case "${OS_FAMILY}" in
            debian) log_err "安装: apt-get install -y curl ca-certificates" ;;
            rhel)   log_err "安装: dnf install -y curl ca-certificates  或  yum install -y curl ca-certificates" ;;
            alpine) log_err "安装: apk add curl ca-certificates" ;;
            suse)   log_err "安装: zypper install -y curl ca-certificates" ;;
            *)      log_err "请先安装 curl" ;;
        esac
        return 1
    fi
    return 0
}

# =============================================================================
#  第 5 节  备份快照与回滚
# =============================================================================

# 打开一个快照目录
snapshot_open() {
    local dir="$1"
    SNAP_DIR="${dir}"
    SNAP_MAP="${dir}/map.txt"
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dry "创建快照目录: ${dir}"
        return 0
    fi
    mkdir -p "${dir}" || { log_err "创建备份目录失败: ${dir}"; return 1; }
    : > "${SNAP_MAP}" || return 1
    mkdir -p "${dir}/files" || return 1
    return 0
}

# 记录一个文件到快照（存在则复制，不存在则记 ABSENT）
snapshot_file() {
    local path="$1"
    [ -n "${SNAP_DIR}" ] || return 0
    if [ "${DRY_RUN}" -eq 1 ]; then
        [ -e "${path}" ] && log_dry "备份: ${path}" || log_dry "记录新建文件(回滚时删除): ${path}"
        return 0
    fi
    if [ -e "${path}" ]; then
        local idx; idx="$(printf '%03d' "$(( $(wc -l < "${SNAP_MAP}" 2>/dev/null || echo 0) + 1 ))")"
        cp -a "${path}" "${SNAP_DIR}/files/${idx}" 2>/dev/null || {
            log_err "备份文件失败: ${path}"; return 1; }
        printf 'COPY|%s|%s\n' "${path}" "files/${idx}" >> "${SNAP_MAP}"
    else
        printf 'ABSENT|%s|-\n' "${path}" >> "${SNAP_MAP}"
    fi
    return 0
}

# 记录一次重命名（用于禁用原有发行版源）
snapshot_rename() {
    local from="$1" to="$2"
    [ -n "${SNAP_DIR}" ] || return 0
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dry "重命名: ${from} -> ${to}"
        return 0
    fi
    printf 'RENAME|%s|%s\n' "${from}" "${to}" >> "${SNAP_MAP}"
    return 0
}

# 执行重命名（禁用原有源）：先记录再移动
disable_file_by_rename() {
    local path="$1" suffix="${2:-.set-mirror-disabled}"
    [ -e "${path}" ] || return 0
    local new="${path}${suffix}"
    snapshot_rename "${path}" "${new}" || return 1
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dry "禁用原有源配置: ${path} -> $(basename "${new}")"
        return 0
    fi
    rm -f "${new}" 2>/dev/null
    mv -f "${path}" "${new}" 2>/dev/null || { log_err "禁用文件失败: ${path}"; return 1; }
    log_info "已禁用原有源配置: $(basename "${path}") -> $(basename "${new}")"
    return 0
}

# 按快照恢复（逆序执行）
snapshot_restore() {
    local dir="$1"
    local map="${dir}/map.txt"
    [ -f "${map}" ] || { log_err "备份无效（缺少 map.txt）: ${dir}"; return 1; }

    log_step "从备份恢复: ${dir}"
    local line op a b
    # 逆序读取
    while IFS= read -r line; do
        [ -n "${line}" ] || continue
        op="${line%%|*}"; a="${line#*|}"; b="${a#*|}"; a="${a%%|*}"
        case "${op}" in
            COPY)
                if [ "${DRY_RUN}" -eq 1 ]; then
                    log_dry "恢复文件: ${a}"
                else
                    mkdir -p "$(dirname "${a}")" 2>/dev/null
                    cp -a "${dir}/${b}" "${a}" 2>/dev/null && log_ok "已恢复 ${a}" \
                        || log_err "恢复失败: ${a}"
                fi
                ;;
            ABSENT)
                if [ "${DRY_RUN}" -eq 1 ]; then
                    log_dry "删除新增文件: ${a}"
                else
                    rm -f "${a}" && log_ok "已删除 ${a}" || log_err "删除失败: ${a}"
                fi
                ;;
            RENAME)
                if [ "${DRY_RUN}" -eq 1 ]; then
                    log_dry "还原重命名: ${b} -> ${a}"
                else
                    if [ -e "${b}" ]; then
                        mv -f "${b}" "${a}" 2>/dev/null && log_ok "已还原 $(basename "${a}")" \
                            || log_err "还原失败: ${b}"
                    fi
                fi
                ;;
        esac
    done < <(tac "${map}" 2>/dev/null || sed '1!G;h;$!d' "${map}")
    return 0
}

# 列出所有备份
snapshot_list() {
    [ -d "${BACKUP_DIR}" ] || { log_info "暂无备份"; return 0; }
    local d
    printf '%-24s %s\n' "备份标识" "创建时间"
    hr
    for d in $(ls -1 "${BACKUP_DIR}" 2>/dev/null | sort -r); do
        [ -d "${BACKUP_DIR}/${d}" ] || continue
        local t; t="$(date -r "${BACKUP_DIR}/${d}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
        [ "${d}" = "orig" ] && t="${t}  (首次修改前的原始配置)"
        printf '%-24s %s\n' "${d}" "${t:-未知}"
    done
}

# 最新时间戳备份（排除 orig）
snapshot_latest() {
    [ -d "${BACKUP_DIR}" ] || return 1
    local d
    for d in $(ls -1 "${BACKUP_DIR}" 2>/dev/null | sort -r); do
        [ "${d}" = "orig" ] && continue
        [ -d "${BACKUP_DIR}/${d}" ] && { printf '%s\n' "${BACKUP_DIR}/${d}"; return 0; }
    done
    return 1
}

# 保存 / 读取当前生效的源状态（幂等判定用）
state_save() {
    [ "${DRY_RUN}" -eq 1 ] && { log_dry "记录状态: ${MIRROR_ID} ${MIRROR_URL}"; return 0; }
    mkdir -p "${STATE_DIR}" 2>/dev/null || return 0
    cat > "${STATE_FILE}" <<EOF
# 由 set_mirror.sh 维护，请勿手工编辑
MIRROR_ID=${MIRROR_ID}
MIRROR_NAME=${MIRROR_NAME}
MIRROR_URL=${MIRROR_URL}
MIRROR_SEC_URL=${MIRROR_SEC_URL:-}
OS_ID=${OS_ID}
OS_VER=${OS_VER}
PM=${PM}
APPLIED_AT=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    return 0
}

state_load() {
    [ -r "${STATE_FILE}" ] || return 1
    # shellcheck disable=SC1090
    . "${STATE_FILE}"
    return 0
}

# =============================================================================
#  第 6 节  发行版与包管理器探测
# =============================================================================

# 读取 /etc/os-release 中的字段
os_release_field() {
    local key="$1" f="${OS_RELEASE_FILE}"
    [ -r "${f}" ] || return 1
    local line
    line="$(grep -E "^${key}=" "${f}" 2>/dev/null | head -1)"
    [ -n "${line}" ] || return 1
    line="${line#*=}"
    line="${line%\"}"; line="${line#\"}"
    printf '%s' "${line}"
}

detect_os() {
    OS_ID=""; OS_NAME=""; OS_VER=""; OS_MAJOR=""; OS_CODENAME=""
    OS_FAMILY=""; PM=""; OS_EOL=0; DETECT_NOTES=""

    ARCH="$(uname -m 2>/dev/null)"

    # ---- 1) /etc/os-release（主流发行版均有）----
    if [ -r "${OS_RELEASE_FILE}" ]; then
        OS_ID="$(os_release_field ID | tr 'A-Z' 'a-z')"
        OS_NAME="$(os_release_field NAME)"
        OS_VER="$(os_release_field VERSION_ID)"
        local like; like="$(os_release_field ID_LIKE | tr 'A-Z' 'a-z')"
        OS_CODENAME="$(os_release_field UBUNTU_CODENAME)"
        [ -z "${OS_CODENAME}" ] && OS_CODENAME="$(os_release_field VERSION_CODENAME)"
        OS_LIKE="${like}"
        log_dbg "os-release: ID=${OS_ID} VER=${OS_VER} LIKE=${like}"
    fi

    # ---- 2) 手工指定优先覆盖 ----
    [ -n "${MANUAL_DISTRO}" ] && { OS_ID="${MANUAL_DISTRO}"; DETECT_NOTES="手动指定发行版=${OS_ID}"; }
    [ -n "${MANUAL_VERSION}" ] && OS_VER="${MANUAL_VERSION}"

    # ---- 3) 无 os-release 的老系统兜底 ----
    if [ -z "${OS_ID}" ]; then
        if [ -r "${ALPINE_RELEASE_FILE}" ]; then
            OS_ID=alpine; OS_VER="$(cat "${ALPINE_RELEASE_FILE}")"
        elif [ -r "${REDHAT_RELEASE_FILE}" ]; then
            local rr; rr="$(cat "${REDHAT_RELEASE_FILE}")"
            case "${rr}" in
                *CentOS*) OS_ID=centos ;;
                *"Red Hat"*) OS_ID=rhel ;;
                *Fedora*) OS_ID=fedora ;;
                *) OS_ID=centos ;;
            esac
            OS_VER="$(printf '%s' "${rr}" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)"
        elif [ -r "${DEBIAN_VERSION_FILE}" ]; then
            OS_ID=debian; OS_VER="$(cat "${DEBIAN_VERSION_FILE}" | grep -oE '[0-9]+' | head -1)"
        elif [ -r "${SUSE_RELEASE_FILE}" ]; then
            OS_ID=opensuse; OS_LIKE="suse opensuse"
        fi
        [ -n "${OS_ID}" ] && DETECT_NOTES="${DETECT_NOTES} 缺少 /etc/os-release，按 release 文件推断;"
    fi

    OS_MAJOR="$(printf '%s' "${OS_VER}" | grep -oE '^[0-9]+' | head -1)"
    [ -z "${OS_MAJOR}" ] && OS_MAJOR="${OS_VER}"

    # ---- 4) 归一化发行版标识与家族 ----
    local like2="${OS_LIKE:-}"
    case "${OS_ID}" in
        debian|ubuntu|deepin|uos|kali|raspbian|linuxmint|kylin-desktop|trisquel|devuan)
            OS_FAMILY=debian ;;
        alpine)
            OS_FAMILY=alpine ;;
        opensuse*|sles|suse|"opensuse-leap"|"opensuse-tumbleweed")
            OS_FAMILY=suse ;;
        centos|rhel|rocky|almalinux|fedora|openeuler|kylin|anolis|opencloudos|tencentos)
            OS_FAMILY=rhel ;;
        *)
            # 用 ID_LIKE 兜底
            case "${like2}" in
                *debian*|*ubuntu*) OS_FAMILY=debian ;;
                *alpine*)          OS_FAMILY=alpine ;;
                *suse*)            OS_FAMILY=suse ;;
                *rhel*|*fedora*|*centos*) OS_FAMILY=rhel ;;
                *) OS_FAMILY="" ;;
            esac
            ;;
    esac

    # ---- 5) 包管理器 ----
    case "${OS_FAMILY}" in
        debian)
            PM=apt
            # 无 codename 时按常见版本表推断
            if [ -z "${OS_CODENAME}" ]; then
                OS_CODENAME="$(debian_codename "${OS_ID}" "${OS_MAJOR}")"
            fi
            ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then PM=dnf
            elif command -v yum >/dev/null 2>&1; then PM=yum
            else PM=dnf; DETECT_NOTES="${DETECT_NOTES} 未检测到 dnf/yum;" ; fi
            ;;
        alpine)
            PM=apk ;;
        suse)
            PM=zypper ;;
        *)
            # 家族未知时按可用命令兜底
            if command -v apt-get >/dev/null 2>&1; then OS_FAMILY=debian; PM=apt
            elif command -v dnf >/dev/null 2>&1; then OS_FAMILY=rhel; PM=dnf
            elif command -v yum >/dev/null 2>&1; then OS_FAMILY=rhel; PM=yum
            elif command -v apk >/dev/null 2>&1; then OS_FAMILY=alpine; PM=apk
            elif command -v zypper >/dev/null 2>&1; then OS_FAMILY=suse; PM=zypper
            else PM="" ; fi
            [ -n "${PM}" ] && DETECT_NOTES="${DETECT_NOTES} 发行版未精确识别，按可用包管理器推断;"
            ;;
    esac

    # ---- 6) EOL 判定（影响是否使用归档源）----
    detect_eol

    if [ -z "${OS_FAMILY}" ] || [ -z "${PM}" ]; then
        log_err "无法识别当前系统的发行版或包管理器"
        log_err "  请通过 --distro <id> --version <ver> 手动指定，或使用 --set <完整URL> 自定义源地址"
        return 1
    fi
    return 0
}

# 已知发行版的版本代号表（系统未提供 VERSION_CODENAME 时使用）
debian_codename() {
    local id="$1" major="$2"
    case "${id}" in
        debian)
            case "${major}" in
                9) echo stretch ;; 10) echo buster ;; 11) echo bullseye ;;
                12) echo bookworm ;; 13) echo trixie ;; 14) echo forky ;;
                *) echo stable ;;
            esac ;;
        ubuntu)
            case "${major}" in
                16) echo xenial ;; 18) echo bionic ;; 20) echo focal ;;
                22) echo jammy ;; 24) echo noble ;; 26) echo resolute ;;
                *) echo "${major}" ;;
            esac ;;
        deepin)
            case "${major}" in
                15) echo unstable ;; 20) echo apricot ;; 23) echo beige ;;
                *) echo apricot ;;
            esac ;;
        *) echo "${major}" ;;
    esac
}

# EOL（生命周期结束）判定：EOL 系统需使用归档源，否则 404
detect_eol() {
    OS_EOL=0
    local eol_note=""
    case "${OS_ID}" in
        centos)
            case "${OS_MAJOR}" in
                6|7) OS_EOL=1; eol_note="CentOS ${OS_MAJOR} 已 EOL，将使用归档源(vault)" ;;
                8)   OS_EOL=1; eol_note="CentOS 8 已 EOL，将使用归档源(vault)" ;;
            esac ;;
        debian)
            case "${OS_MAJOR}" in
                8|9|10) OS_EOL=1; eol_note="Debian ${OS_MAJOR} 已 EOL，需使用 archive.debian.org" ;;
            esac ;;
        ubuntu)
            # 非 LTS 版本支持 9 个月；这里仅对明确 EOL 的 LTS/旧版给提示
            case "${OS_MAJOR}" in
                16|18) OS_EOL=1; eol_note="Ubuntu ${OS_MAJOR} 已过标准支持期，建议使用 old-releases 源" ;;
            esac ;;
        fedora)
            OS_EOL=1; eol_note="Fedora 生命周期较短，${OS_VER} 可能已归档，建议确认 archive.fedoraproject.org" ;;
    esac
    [ "${FORCE_EOL}" -eq 1 ] && { OS_EOL=1; eol_note="已通过 --eol 强制使用归档源"; }
    [ -n "${eol_note}" ] && DETECT_NOTES="${DETECT_NOTES} ${eol_note};"
    return 0
}

detect_summary() {
    sec "主机环境"
    printf '  发行版      : %s %s (%s)\n' "${OS_NAME:-${OS_ID}}" "${OS_VER}" "${OS_ID}"
    [ -n "${OS_CODENAME}" ] && printf '  版本代号    : %s\n' "${OS_CODENAME}"
    printf '  架构        : %s\n' "${ARCH}"
    printf '  家族        : %s\n' "${OS_FAMILY}"
    printf '  包管理器    : %s\n' "${PM}"
    printf '  EOL 归档    : %s\n' "$([ "${OS_EOL}" -eq 1 ] && echo '是（使用归档源）' || echo '否')"
    printf '  源文件路径  : %s\n' "$(managed_file_path)"
    if state_load 2>/dev/null; then
        printf '  当前已应用  : %s (%s)  @ %s\n' "${MIRROR_NAME:-?}" "${MIRROR_URL:-?}" "${APPLIED_AT:-?}"
    else
        printf '  当前已应用  : 无（尚未通过本工具配置）\n'
    fi
    [ -n "${DETECT_NOTES}" ] && printf '  备注        :%s\n' "${DETECT_NOTES}"
}

# =============================================================================
#  第 7 节  镜像源目录（内置预设）
# =============================================================================
#
#  每行格式:  id|显示名称|基础URL|安全更新URL(可选，空则用基础URL)
#  EOL 系统自动切换到归档路径（见 mirror_apply_eol）
# =============================================================================

mirror_catalog() {
    case "${1}" in
        debian)
            if [ "${OS_EOL}" -eq 1 ]; then
                cat <<'EOF'
official|官方归档 (archive.debian.org)|http://archive.debian.org/debian|http://archive.debian.org/debian-security
aliyun|阿里云归档|https://mirrors.aliyun.com/debian-archive|https://mirrors.aliyun.com/debian-archive
tuna|清华 TUNA 归档|https://mirrors.tuna.tsinghua.edu.cn/debian-archive|https://mirrors.tuna.tsinghua.edu.cn/debian-archive
ustc|中科大归档|https://mirrors.ustc.edu.cn/debian-archive|https://mirrors.ustc.edu.cn/debian-archive
EOF
            else
                cat <<'EOF'
official|官方源 (deb.debian.org)|http://deb.debian.org/debian|http://security.debian.org/debian-security
aliyun|阿里云|https://mirrors.aliyun.com/debian|https://mirrors.aliyun.com/debian-security
tencent|腾讯云|https://mirrors.tencent.com/debian|https://mirrors.tencent.com/debian-security
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/debian|https://mirrors.tuna.tsinghua.edu.cn/debian-security
ustc|中科大|https://mirrors.ustc.edu.cn/debian|https://mirrors.ustc.edu.cn/debian-security
huawei|华为云|https://mirrors.huaweicloud.com/debian|https://mirrors.huaweicloud.com/debian-security
163|网易|https://mirrors.163.com/debian|https://mirrors.163.com/debian-security
EOF
            fi
            ;;
        ubuntu)
            if [ "${OS_EOL}" -eq 1 ]; then
                cat <<'EOF'
official|官方归档 (old-releases)|http://old-releases.ubuntu.com/ubuntu|http://old-releases.ubuntu.com/ubuntu
aliyun|阿里云归档|https://mirrors.aliyun.com/ubuntu-old-releases|https://mirrors.aliyun.com/ubuntu-old-releases
tuna|清华 TUNA 归档|https://mirrors.tuna.tsinghua.edu.cn/ubuntu-old-releases|https://mirrors.tuna.tsinghua.edu.cn/ubuntu-old-releases
ustc|中科大归档|https://mirrors.ustc.edu.cn/ubuntu-old-releases|https://mirrors.ustc.edu.cn/ubuntu-old-releases
EOF
            else
                cat <<'EOF'
official|官方源 (archive.ubuntu.com)|http://archive.ubuntu.com/ubuntu|http://security.ubuntu.com/ubuntu
aliyun|阿里云|https://mirrors.aliyun.com/ubuntu|https://mirrors.aliyun.com/ubuntu
tencent|腾讯云|https://mirrors.tencent.com/ubuntu|https://mirrors.tencent.com/ubuntu
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu
ustc|中科大|https://mirrors.ustc.edu.cn/ubuntu|https://mirrors.ustc.edu.cn/ubuntu
huawei|华为云|https://mirrors.huaweicloud.com/ubuntu|https://mirrors.huaweicloud.com/ubuntu
163|网易|https://mirrors.163.com/ubuntu|https://mirrors.163.com/ubuntu
EOF
            fi
            ;;
        deepin|uos)
            cat <<'EOF'
official|官方源|https://community-packages.deepin.com/deepin|
aliyun|阿里云|https://mirrors.aliyun.com/deepin|
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/deepin|
ustc|中科大|https://mirrors.ustc.edu.cn/deepin|
huawei|华为云|https://mirrors.huaweicloud.com/deepin|
EOF
            ;;
        kali)
            cat <<'EOF'
official|官方源|http://http.kali.org/kali|
aliyun|阿里云|https://mirrors.aliyun.com/kali|
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/kali|
ustc|中科大|https://mirrors.ustc.edu.cn/kali|
EOF
            ;;
        centos)
            if [ "${OS_EOL}" -eq 1 ]; then
                cat <<'EOF'
official|官方归档 (vault.centos.org)|https://vault.centos.org|
aliyun|阿里云归档|https://mirrors.aliyun.com/centos-vault|
tuna|清华 TUNA 归档|https://mirrors.tuna.tsinghua.edu.cn/centos-vault|
ustc|中科大归档|https://mirrors.ustc.edu.cn/centos-vault|
huawei|华为云归档|https://mirrors.huaweicloud.com/centos-vault|
EOF
            else
                cat <<'EOF'
official|官方源 (mirror.centos.org)|https://mirror.centos.org/centos|
aliyun|阿里云|https://mirrors.aliyun.com/centos|
tencent|腾讯云|https://mirrors.tencent.com/centos|
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/centos|
ustc|中科大|https://mirrors.ustc.edu.cn/centos|
huawei|华为云|https://mirrors.huaweicloud.com/centos|
163|网易|https://mirrors.163.com/centos|
EOF
            fi
            ;;
        rocky)
            cat <<'EOF'
official|官方源|https://dl.rockylinux.org/pub/rocky|
aliyun|阿里云|https://mirrors.aliyun.com/rocky|
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/rocky|
ustc|中科大|https://mirrors.ustc.edu.cn/rocky|
huawei|华为云|https://mirrors.huaweicloud.com/rocky|
EOF
            ;;
        almalinux)
            cat <<'EOF'
official|官方源|https://repo.almalinux.org/almalinux|
aliyun|阿里云|https://mirrors.aliyun.com/almalinux|
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/almalinux|
ustc|中科大|https://mirrors.ustc.edu.cn/almalinux|
huawei|华为云|https://mirrors.huaweicloud.com/almalinux|
EOF
            ;;
        fedora)
            cat <<'EOF'
official|官方源|https://download.example/pub/fedora/linux|
aliyun|阿里云|https://mirrors.aliyun.com/fedora|
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/fedora|
ustc|中科大|https://mirrors.ustc.edu.cn/fedora|
huawei|华为云|https://mirrors.huaweicloud.com/fedora|
EOF
            ;;
        openeuler)
            cat <<'EOF'
official|官方源 (repo.openeuler.org)|https://repo.openeuler.org|
huawei|华为云|https://mirrors.huaweicloud.com/openeuler|
aliyun|阿里云|https://mirrors.aliyun.com/openeuler|
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/openeuler|
ustc|中科大|https://mirrors.ustc.edu.cn/openeuler|
EOF
            ;;
        kylin|anolis|opencloudos|tencentos|rhel)
            cat <<'EOF'
official|官方源|$(OFFICIAL)|
aliyun|阿里云|https://mirrors.aliyun.com|
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn|
ustc|中科大|https://mirrors.ustc.edu.cn|
huawei|华为云|https://mirrors.huaweicloud.com|
EOF
            ;;
        alpine)
            cat <<'EOF'
official|官方源 (dl-cdn.alpinelinux.org)|https://dl-cdn.alpinelinux.org/alpine|
aliyun|阿里云|https://mirrors.aliyun.com/alpine|
tencent|腾讯云|https://mirrors.tencent.com/alpine|
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/alpine|
ustc|中科大|https://mirrors.ustc.edu.cn/alpine|
huawei|华为云|https://mirrors.huaweicloud.com/alpine|
EOF
            ;;
        opensuse*|sles|suse)
            cat <<'EOF'
official|官方源 (download.opensuse.org)|https://download.opensuse.org|
aliyun|阿里云|https://mirrors.aliyun.com/opensuse|
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/opensuse|
ustc|中科大|https://mirrors.ustc.edu.cn/opensuse|
huawei|华为云|https://mirrors.huaweicloud.com/opensuse|
163|网易|https://mirrors.163.com/opensuse|
EOF
            ;;
        *)
            # 未知发行版：给出通用镜像站，由用户确认路径
            cat <<'EOF'
aliyun|阿里云|https://mirrors.aliyun.com|
tencent|腾讯云|https://mirrors.tencent.com|
tuna|清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn|
ustc|中科大|https://mirrors.ustc.edu.cn|
huawei|华为云|https://mirrors.huaweicloud.com|
EOF
            ;;
    esac
}

# 特殊发行版的官方源地址（麒麟等无公网通用镜像时给出提示）
official_url_for() {
    case "${OS_ID}" in
        kylin)   echo "https://update.cs2c.com.cn/NS/V10" ;;
        rhel)    echo "https://cdn.redhat.com/content/dist/rhel${OS_MAJOR}" ;;
        anolis)  echo "https://mirrors.openanolis.cn/anolis" ;;
        tencentos) echo "https://mirrors.tencent.com/tlinux" ;;
        *) echo "" ;;
    esac
}

# 解析一个规格（镜像 id 或 URL）到 MIRROR_ID/NAME/URL/SEC_URL
resolve_spec() {
    local spec="$1" line id name url sec
    # 情形一：完整 URL
    case "${spec}" in
        http://*|https://*|ftp://*)
            MIRROR_ID="custom"
            MIRROR_NAME="自定义源"
            MIRROR_URL="${spec%/}"
            MIRROR_SEC_URL="${MIRROR_URL}"
            return 0
            ;;
    esac
    # 情形二：内置镜像 id
    while IFS='|' read -r id name url sec; do
        [ -z "${id}" ] && continue
        [ "${id}" = "${spec}" ] || continue
        MIRROR_ID="${id}"; MIRROR_NAME="${name}"; MIRROR_URL="${url%/}"; MIRROR_SEC_URL="${sec:-${url}}"
        MIRROR_SEC_URL="${MIRROR_SEC_URL%/}"
        [ "${MIRROR_URL}" = '$(OFFICIAL)' ] && MIRROR_URL="$(official_url_for)"
        [ "${MIRROR_SEC_URL}" = '$(OFFICIAL)' ] && MIRROR_SEC_URL="${MIRROR_URL}"
        if [ -z "${MIRROR_URL}" ]; then
            log_err "镜像 ${id} 在当前发行版(${OS_ID})上无默认地址，请使用完整 URL 指定"
            return 1
        fi
        return 0
    done < <(mirror_catalog "${OS_ID}")
    log_err "未找到镜像: ${spec}"
    log_err "可用镜像: $(mirror_catalog "${OS_ID}" | cut -d'|' -f1 | tr '\n' ' ')"
    return 1
}

# 列出候选源
mirror_list() {
    printf '\n%-8s %-22s %s\n' "ID" "名称" "地址"
    hr
    local id name url sec
    while IFS='|' read -r id name url sec; do
        [ -z "${id}" ] && continue
        local u="${url}"
        [ "${u}" = '$(OFFICIAL)' ] && u="$(official_url_for)"
        printf '%-8s %-22s %s\n' "${id}" "${name}" "${u}"
    done < <(mirror_catalog "${OS_ID}")
}

# =============================================================================
#  第 8 节  源配置内容生成（按包管理器分流）
# =============================================================================

managed_file_path() {
    case "${PM}" in
        apt)    printf '%s' "${APT_MANAGED_FILE}" ;;
        dnf|yum) printf '%s' "${YUM_MANAGED_FILE}" ;;
        apk)    printf '%s' "${APK_REPOS_FILE}" ;;
        zypper) printf '%s' "${ZYPP_MANAGED_FILE}" ;;
        *) printf '%s' "未知" ;;
    esac
}

config_header() {
    cat <<EOF
# ${MANAGED_MARK}
# 镜像: ${MIRROR_NAME} <${MIRROR_URL}>
# 系统: ${OS_ID} ${OS_VER} (${ARCH})
# 本文件由 set_mirror.sh 生成并管理，手工修改可能在下次执行时被覆盖。
# 回滚: bash ${SCRIPT_NAME} --rollback
EOF
}
MANAGED_MARK="MANAGED-BY: set_mirror.sh"

# ---- 8.1 apt ----
gen_apt_content() {
    local codename="${OS_CODENAME}" comps
    [ -z "${codename}" ] && { log_err "无法获取版本代号，请通过 --version 或检查 /etc/os-release"; return 1; }

    # 组件列表：Debian 12+ 引入 non-free-firmware
    case "${OS_ID}" in
        debian)
            if [ "${OS_MAJOR}" -ge 12 ] 2>/dev/null; then
                comps="main contrib non-free non-free-firmware"
            else
                comps="main contrib non-free"
            fi ;;
        ubuntu|kali) comps="main restricted universe multiverse" ;;
        deepin|uos)  comps="main contrib non-free" ;;
        *)           comps="main" ;;
    esac

    local base="${MIRROR_URL}" sec="${MIRROR_SEC_URL:-${MIRROR_URL}}"

    config_header
    printf '\n'
    printf 'deb  %s %s %s\n'  "${base}" "${codename}" "${comps}"
    [ "${WITH_SRC}" -eq 1 ] && printf 'deb-src %s %s %s\n' "${base}" "${codename}" "${comps}"
    printf 'deb  %s %s-updates %s\n' "${base}" "${codename}" "${comps}"
    [ "${WITH_SRC}" -eq 1 ] && printf 'deb-src %s %s-updates %s\n' "${base}" "${codename}" "${comps}"
    printf 'deb  %s %s-backports %s\n' "${base}" "${codename}" "${comps}"
    printf 'deb  %s %s-security %s\n'  "${sec}"  "${codename}" "${comps}"
    [ "${WITH_SRC}" -eq 1 ] && printf 'deb-src %s %s-security %s\n' "${sec}" "${codename}" "${comps}"

    # EOL 系统需要允许过期 Release
    if [ "${OS_EOL}" -eq 1 ]; then
        log_warn "EOL 系统的 Release 文件已过期，需额外配置 Acquire::Check-Valid-Until=false"
        printf '\n# EOL 系统：跳过 Release 有效期校验\n'
    fi
    return 0
}

# apt 的 EOL 附加配置（单独文件）
gen_apt_eol_content() {
    cat <<EOF
# ${MANAGED_MARK}
Acquire::Check-Valid-Until "false";
EOF
}
APT_EOL_FILE="${APT_EOL_FILE:-${APT_SOURCES_DIR}/../apt.conf.d/99-set-mirror-no-check-valid}"

# ---- 8.2 yum / dnf ----
gen_yum_content() {
    local base="${MIRROR_URL}" ver="${OS_MAJOR}" stream="" prefix
    config_header
    printf '\n'

    # 路径前缀（EOL 时加归档版本目录）
    case "${OS_ID}" in
        centos)
            if [ "${OS_EOL}" -eq 1 ]; then
                # vault 目录形如 7.9.2009 / 8.5.2111；未知名时用主版本
                prefix="${base}/${OS_VER}"
                [ "${OS_MAJOR}" = "8" ] && prefix="${base}/8.5.2111"
                [ "${OS_MAJOR}" = "7" ] && prefix="${base}/7.9.2009"
                [ "${OS_MAJOR}" = "6" ] && prefix="${base}/6.10"
            else
                # CentOS Stream: $releasever-stream
                if grep -qi 'stream' "${REDHAT_RELEASE_FILE}" 2>/dev/null; then
                    prefix="${base}/\$releasever-stream"
                    stream=1
                else
                    prefix="${base}/\$releasever"
                fi
            fi
            yum_stanza base     "CentOS-\$releasever - Base"     "${prefix}/os/\$basearch/"
            yum_stanza updates  "CentOS-\$releasever - Updates"  "${prefix}/updates/\$basearch/"
            yum_stanza extras   "CentOS-\$releasever - Extras"   "${prefix}/extras/\$basearch/"
            yum_stanza centosplus "CentOS-\$releasever - Plus"   "${prefix}/centosplus/\$basearch/"
            ;;
        rocky)
            prefix="${base}/\$releasever"
            yum_stanza baseos    "Rocky-\$releasever - BaseOS"    "${prefix}/BaseOS/\$basearch/os/"
            yum_stanza appstream "Rocky-\$releasever - AppStream" "${prefix}/AppStream/\$basearch/os/"
            yum_stanza extras    "Rocky-\$releasever - Extras"    "${prefix}/extras/\$basearch/os/"
            ;;
        almalinux)
            prefix="${base}/\$releasever"
            yum_stanza baseos    "AlmaLinux-\$releasever - BaseOS"    "${prefix}/BaseOS/\$basearch/os/"
            yum_stanza appstream "AlmaLinux-\$releasever - AppStream" "${prefix}/AppStream/\$basearch/os/"
            yum_stanza extras    "AlmaLinux-\$releasever - Extras"    "${prefix}/extras/\$basearch/os/"
            ;;
        fedora)
            prefix="${base}/releases/\$releasever/Everything/\$basearch/os"
            yum_stanza fedora   "Fedora \$releasever - \$basearch"            "${prefix}"
            yum_stanza updates  "Fedora \$releasever - \$basearch - Updates"  "${base}/updates/\$releasever/Everything/\$basearch/"
            ;;
        openeuler)
            prefix="${base}/openEuler-\$releasever"
            yum_stanza os      "openEuler-\$releasever - OS"      "${prefix}/OS/\$basearch/"
            yum_stanza update  "openEuler-\$releasever - update"  "${prefix}/update/\$basearch/"
            yum_stanza everything "openEuler-\$releasever - everything" "${prefix}/everything/\$basearch/"
            yum_stanza EPOL    "openEuler-\$releasever - EPOL"    "${prefix}/EPOL/\$basearch/"
            ;;
        rhel)
            prefix="${base}/\$releasever"
            yum_stanza baseos    "RHEL-\$releasever - BaseOS"    "${prefix}/BaseOS/\$basearch/os/"
            yum_stanza appstream "RHEL-\$releasever - AppStream" "${prefix}/AppStream/\$basearch/os/"
            log_warn "RHEL 官方源需要订阅授权；未注册系统会报 401/403，建议改用 rebuild 发行版或内部源"
            ;;
        *)
            # 麒麟 / Anolis / TLinux 等：通用 rhel 布局，路径需用户确认
            prefix="${base}/${OS_ID}/\$releasever"
            yum_stanza baseos    "${OS_ID}-\$releasever - BaseOS"    "${prefix}/BaseOS/\$basearch/os/"
            yum_stanza appstream "${OS_ID}-\$releasever - AppStream" "${prefix}/AppStream/\$basearch/os/"
            log_warn "发行版 ${OS_ID} 的仓库路径未内置，已按 RHEL 通用布局生成，请核对 baseurl 是否可达"
            ;;
    esac

    # EPEL（独立于发行版主仓库，位于镜像站根目录 /epel）
    if [ "${WITH_EPEL}" -eq 1 ] && [ "${OS_EOL}" -eq 0 ]; then
        local epel
        case "${MIRROR_ID}" in
            official)
                epel="https://dl.fedoraproject.org/pub/epel"
                ;;
            *)
                # 提取镜像站根（scheme://host[:port]），去掉发行版子路径
                epel="$(printf '%s' "${MIRROR_URL}" | sed -E 's#^(https?://[^/]+).*#\1#')/epel"
                ;;
        esac
        printf '\n'
        yum_stanza epel "Extra Packages for Enterprise Linux \$releasever - \$basearch" \
            "${epel}/\$releasever/Everything/\$basearch/" 1 \
            "https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-\$releasever"
    fi
    return 0
}

# 提取镜像站根（scheme://host[:port]）
mirror_root() {
    printf '%s' "${MIRROR_URL}" | sed -E 's#^(https?://[^/]+).*#\1#'
}

# 输出一个 yum repo 段
# yum_stanza <id> <name> <baseurl> [enabled=1/0] [gpgkey]
yum_stanza() {
    local id="$1" name="$2" url="$3" enabled="${4:-1}" gpgkey="${5:-}"
    printf '[%s]\n' "${id}"
    printf 'name=%s\n' "${name}"
    printf 'baseurl=%s\n' "${url}"
    printf 'enabled=%s\n' "${enabled}"
    printf 'gpgcheck=1\n'
    if [ -n "${gpgkey}" ]; then
        printf 'gpgkey=%s\n' "${gpgkey}"
    else
        local k; k="$(yum_default_gpgkey)"
        [ -n "${k}" ] && printf 'gpgkey=%s\n' "${k}"
    fi
    printf 'skip_if_unavailable=True\n'
    printf '\n'
}

# 本机已有的 RPM GPG 公钥文件；本地缺失时按发行版回退到官方 key URL
yum_default_gpgkey() {
    local f=""
    for f in "${RPM_GPG_DIR}"/RPM-GPG-KEY-*; do
        [ -e "${f}" ] || continue
        case "$(basename "${f}")" in
            *CentOS-${OS_MAJOR}*|*Rocky-${OS_MAJOR}*|*AlmaLinux*|*openEuler*|*epel*|*EPEL*)
                printf 'file://%s' "${f}"; return 0 ;;
        esac
    done
    for f in "${RPM_GPG_DIR}"/RPM-GPG-KEY-*; do
        [ -e "${f}" ] || continue
        printf 'file://%s' "${f}"; return 0
    done
    # 本地无 key 时提供官方公钥 URL（dnf/yum 会在需要时自动下载导入）
    case "${OS_ID}" in
        centos)
            if [ "${OS_EOL}" -eq 1 ]; then
                printf 'https://vault.centos.org/RPM-GPG-KEY-CentOS-%s' "${OS_MAJOR}"
            else
                printf 'https://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-%s' "${OS_MAJOR}"
            fi ;;
        rocky)     printf 'https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-%s' "${OS_MAJOR}" ;;
        almalinux) printf 'https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux' ;;
        fedora)    printf 'https://fedoraproject.org/fedora.gpg' ;;
        *)         printf '' ;;
    esac
}

# ---- 8.3 apk ----
gen_apk_content() {
    local ver="${OS_VER}" base="${MIRROR_URL}"
    # alpine 仓库按 v<主.次> 组织，如 v3.20
    case "${ver}" in
        v*) : ;;
        *) ver="v${ver}" ;;
    esac
    local major_minor; major_minor="$(printf '%s' "${OS_VER}" | grep -oE '^[0-9]+\.[0-9]+')"
    [ -n "${major_minor}" ] && ver="v${major_minor}"
    config_header
    printf '\n'
    printf '%s/%s/main\n' "${base}" "${ver}"
    printf '%s/%s/community\n' "${base}" "${ver}"
    if [ "${WITH_TESTING:-0}" -eq 1 ]; then
        printf '%s/%s/testing\n' "${base}" "${ver}"
    else
        printf '# %s/%s/testing\n' "${base}" "${ver}"
    fi
    return 0
}

# ---- 8.4 zypper ----
gen_zypper_content() {
    local base="${MIRROR_URL}" ver="${OS_VER}"
    config_header
    printf '\n'
    case "${OS_ID}" in
        *tumbleweed*)
            yum_stanza set-mirror-oss     "openSUSE Tumbleweed - OSS"     "${base}/tumbleweed/repo/oss/"
            yum_stanza set-mirror-non-oss "openSUSE Tumbleweed - Non-OSS" "${base}/tumbleweed/repo/non-oss/"
            ;;
        *)
            yum_stanza set-mirror-oss      "openSUSE Leap ${ver} - OSS"      "${base}/distribution/leap/${ver}/repo/oss/"
            yum_stanza set-mirror-non-oss  "openSUSE Leap ${ver} - Non-OSS"  "${base}/distribution/leap/${ver}/repo/non-oss/"
            yum_stanza set-mirror-update   "openSUSE Leap ${ver} - Update"   "${base}/update/leap/${ver}/oss/"
            yum_stanza set-mirror-update-nonoss "openSUSE Leap ${ver} - Update Non-OSS" "${base}/update/leap/${ver}/non-oss/"
            ;;
    esac
    return 0
}

# 统一入口：生成目标配置内容
gen_content() {
    case "${PM}" in
        apt)    gen_apt_content ;;
        dnf|yum) gen_yum_content ;;
        apk)    gen_apk_content ;;
        zypper) gen_zypper_content ;;
        *) log_err "不支持的包管理器: ${PM}"; return 1 ;;
    esac
}

# =============================================================================
#  第 9 节  应用配置（含禁用原发行版源、幂等判定）
# =============================================================================

# 需要禁用的原发行版源文件名模式
is_distro_repo_file() {
    local b; b="$(basename "$1")"
    case "${PM}" in
        apt)
            case "${b}" in
                debian.sources|ubuntu.sources|debian.list|ubuntu.list|uos.sources|deepin.sources|kali.sources|official-package-repositories.list|*.distUpgrade*) return 0 ;;
                *) return 1 ;;
            esac ;;
        dnf|yum)
            case "${b}" in
                CentOS-*.repo|Rocky-*.repo|almalinux*.repo|fedora*.repo|fedora-updates*.repo|openEuler*.repo|kylin*.repo|rhel*.repo|anolis*.repo|tlinux*.repo) return 0 ;;
                *) return 1 ;;
            esac ;;
        zypper)
            case "${b}" in
                repo-*.repo|opensuse*.repo|sles*.repo) return 0 ;;
                *) return 1 ;;
            esac ;;
        *) return 1 ;;
    esac
}

# 禁用原有发行版源（第三方源如 docker/epel/kubernetes 保持不动）
disable_distro_repos() {
    log_step "处理原有发行版源配置"
    local f found=0

    case "${PM}" in
        apt)
            # 1) /etc/apt/sources.list：注释掉有效行
            if [ -s "${APT_SOURCES_LIST}" ] && grep -qE '^\s*(deb|deb-src)' "${APT_SOURCES_LIST}" 2>/dev/null; then
                found=1
                snapshot_file "${APT_SOURCES_LIST}" || return 1
                if [ "${DRY_RUN}" -eq 1 ]; then
                    log_dry "注释 ${APT_SOURCES_LIST} 中的有效源行"
                else
                    sed -i -E 's@^([[:space:]]*)(deb|deb-src)@\1# DISABLED-BY-SET-MIRROR \2@' "${APT_SOURCES_LIST}" \
                        && log_info "已注释 ${APT_SOURCES_LIST} 中的原发行版源" \
                        || { log_err "修改 ${APT_SOURCES_LIST} 失败"; return 1; }
                fi
            fi
            # 2) sources.list.d 下的发行版源（.list / .sources）
            for f in "${APT_SOURCES_DIR}"/*.list "${APT_SOURCES_DIR}"/*.sources; do
                [ -e "${f}" ] || continue
                is_distro_repo_file "${f}" || continue
                found=1
                disable_file_by_rename "${f}" || return 1
            done
            ;;
        dnf|yum)
            for f in "${YUM_REPO_DIR}"/*.repo; do
                [ -e "${f}" ] || continue
                [ "${f}" = "${YUM_MANAGED_FILE}" ] && continue
                is_distro_repo_file "${f}" || continue
                found=1
                disable_file_by_rename "${f}" || return 1
            done
            ;;
        zypper)
            for f in "${ZYPP_REPO_DIR}"/*.repo; do
                [ -e "${f}" ] || continue
                [ "${f}" = "${ZYPP_MANAGED_FILE}" ] && continue
                is_distro_repo_file "${f}" || continue
                found=1
                disable_file_by_rename "${f}" || return 1
            done
            ;;
        apk)
            # apk 只有单个文件，写入时整体备份，无需额外禁用
            : ;;
    esac

    [ "${found}" -eq 0 ] && log_info "未发现需要禁用的原发行版源配置"
    return 0
}

# 幂等判定：目标文件内容与现有一致则跳过
# 判断目标文件内容是否已与期望一致（幂等判定）
content_matches() {
    local path="$1" content="$2" cur
    [ -f "${path}" ] || return 1
    cur="$(cat "${path}" 2>/dev/null)"
    [ "$(printf '%s' "${cur}" | tr -d '[:space:]')" = "$(printf '%s' "${content}" | tr -d '[:space:]')" ]
}

apply_config() {
    local path content="$1"
    path="$(managed_file_path)"

    disable_distro_repos || return 1

    log_step "写入源配置: ${path}"
    fs_replace "${path}" "${content}" 0644 || return 1
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dry "已写入(预演): ${path}"
    else
        log_ok "已写入: ${path}"
    fi

    # apt 的 EOL 附加配置
    if [ "${PM}" = "apt" ] && [ "${OS_EOL}" -eq 1 ]; then
        local eol_path="${APT_SOURCES_DIR}/../apt.conf.d/99-set-mirror-no-check-valid"
        fs_replace "${eol_path}" "$(gen_apt_eol_content)" 0644 \
            && log_ok "已写入 EOL 附加配置: ${eol_path}"
    fi

    state_save
    return 0
}

# =============================================================================
#  第 10 节  可用性与速度检测
# =============================================================================

# 生成候选探测 URL（按包管理器与发行版）
probe_urls_for() {
    local base="$1"
    case "${PM}" in
        apt)
            printf '%s/dists/%s/InRelease\n' "${base}" "${OS_CODENAME}"
            printf '%s/dists/%s/Release\n' "${base}" "${OS_CODENAME}"
            ;;
        dnf|yum)
            case "${OS_ID}" in
                centos)
                    if [ "${OS_EOL}" -eq 1 ]; then
                        local vp="${OS_VER}"; [ "${OS_MAJOR}" = "8" ] && vp="8.5.2111"; [ "${OS_MAJOR}" = "7" ] && vp="7.9.2009"
                        printf '%s/%s/os/%s/repodata/repomd.xml\n' "${base}" "${vp}" "${ARCH}"
                    else
                        printf '%s/%s/os/%s/repodata/repomd.xml\n' "${base}" "${OS_MAJOR}" "${ARCH}"
                        printf '%s/%s-stream/os/%s/repodata/repomd.xml\n' "${base}" "${OS_MAJOR}" "${ARCH}"
                    fi ;;
                rocky)
                    printf '%s/%s/BaseOS/%s/os/repodata/repomd.xml\n' "${base}" "${OS_MAJOR}" "${ARCH}" ;;
                almalinux)
                    printf '%s/%s/BaseOS/%s/os/repodata/repomd.xml\n' "${base}" "${OS_MAJOR}" "${ARCH}" ;;
                openeuler)
                    printf '%s/openEuler-%s/OS/%s/repodata/repomd.xml\n' "${base}" "${OS_VER}" "${ARCH}" ;;
                fedora)
                    printf '%s/releases/%s/Everything/%s/os/repodata/repomd.xml\n' "${base}" "${OS_VER}" "${ARCH}" ;;
                *)
                    printf '%s/%s/BaseOS/%s/os/repodata/repomd.xml\n' "${base}" "${OS_MAJOR}" "${ARCH}"
                    printf '%s/%s/os/%s/repodata/repomd.xml\n' "${base}" "${OS_MAJOR}" "${ARCH}" ;;
            esac ;;
        apk)
            local v; v="$(printf '%s' "${OS_VER}" | grep -oE '^[0-9]+\.[0-9]+')"
            [ -z "${v}" ] && v="${OS_VER}"
            printf '%s/v%s/main/%s/APKINDEX.tar.gz\n' "${base}" "${v}" "${ARCH}" ;;
        zypper)
            case "${OS_ID}" in
                *tumbleweed*) printf '%s/tumbleweed/repo/oss/repodata/repomd.xml\n' "${base}" ;;
                *) printf '%s/distribution/leap/%s/repo/oss/repodata/repomd.xml\n' "${base}" "${OS_VER}" ;;
            esac ;;
        *)
            printf '%s\n' "${base}" ;;
    esac
}

# 单次 HTTP 探测：输出 "code time_starttransfer speed size"
http_probe() {
    local url="$1"
    local fmt='%{http_code} %{time_starttransfer} %{speed_download} %{size_download}'
    local args=(-sSL -o /dev/null --max-time "${NET_TIMEOUT}" -w "${fmt}")
    [ "${INSECURE}" -eq 1 ] && args+=(-k)
    local r; r="$(curl "${args[@]}" "${url}" 2>/dev/null)"
    case "${r}" in
        ''|*[!0-9.\ ]*) r="000 0 0 0" ;;
    esac
    # shellcheck disable=SC2086
    set -- ${r}
    printf '%s %s %s %s\n' "${1:-000}" "${2:-0}" "${3:-0}" "${4:-0}"
}

# 测速：先探测首个返回 200 的候选路径，再按需做速率抽样
# 输出: "id|name|url|ok|code|latency_ms|speed_kbps|size_kb"
mirror_speedtest_one() {
    local id="$1" name="$2" url="$3"
    local probe found=0 code=0 lat=0 spd=0 size=0
    while IFS= read -r probe; do
        [ -n "${probe}" ] || continue
        read -r code lat spd size <<<"$(http_probe "${probe}")"
        if [ "${code}" = "200" ] || [ "${code}" = "403" ]; then
            found=1; break
        fi
    done < <(probe_urls_for "${url}")

    local ok=0
    [ "${found}" -eq 1 ] && [ "${code}" = "200" ] && ok=1

    # 速率抽样：若探测文件过小，速率仅供参考；可用 SPEED_URL 指定大文件
    if [ "${ok}" -eq 1 ] && [ -n "${SPEED_URL}" ]; then
        read -r _ _ spd size <<<"$(http_probe "${SPEED_URL}")"
    fi

    local lat_ms; lat_ms="$(awk -v t="${lat}" 'BEGIN{printf "%.0f", t*1000}')"
    local spd_kb; spd_kb="$(awk -v s="${spd}" 'BEGIN{printf "%.0f", s/1024}')"
    local size_kb; size_kb="$(awk -v s="${size}" 'BEGIN{printf "%.0f", s/1024}')"

    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "${id}" "${name}" "${url}" "${ok}" "${code}" "${lat_ms}" "${spd_kb}" "${size_kb}"
}

# 对全部候选源测速，结果写入全局数组 SPEED_RESULT
SPEED_RESULT=()
mirror_speedtest_all() {
    SPEED_RESULT=()
    local tmp="/tmp/set-mirror-test.$$.${RANDOM:-0}"
    mkdir -p "${tmp}" 2>/dev/null
    local id name url sec n=0
    local pids=""

    sec "镜像源测速（超时 ${NET_TIMEOUT}s）"
    printf '%-8s %-22s %s\n' "ID" "名称" "进度"
    hr

    while IFS='|' read -r id name url sec; do
        [ -z "${id}" ] && continue
        url="${url%/}"
        # 占位地址（无公网镜像的发行版官方源）在探测前解析，解析不到则跳过
        if [ "${url}" = '$(OFFICIAL)' ]; then
            url="$(official_url_for)"
            if [ -z "${url}" ]; then
                printf '%s|%s|%s|0|000|0|0|0\n' "${id}" "${name}" "-"
                continue
            fi
        fi
        n=$((n+1))
        # 并发探测
        (
            mirror_speedtest_one "${id}" "${name}" "${url}" > "${tmp}/r.${id}" 2>/dev/null
        ) &
        pids="${pids} $!"
        # 控制并发度
        while [ "$(jobs -rp 2>/dev/null | wc -l)" -ge "${MAX_PARALLEL}" ]; do
            sleep 0.2
        done
    done < <(mirror_catalog "${OS_ID}")

    wait 2>/dev/null

    local f
    for f in "${tmp}"/r.*; do
        [ -s "${f}" ] || continue
        SPEED_RESULT+=("$(cat "${f}")")
    done
    rm -rf "${tmp}" 2>/dev/null

    # 排序：可用优先，再按延迟升序
    if [ "${#SPEED_RESULT[@]}" -gt 0 ]; then
        local sorted
        sorted="$(printf '%s\n' "${SPEED_RESULT[@]}" | sort -t'|' -k4,4r -k6,6n)"
        SPEED_RESULT=()
        while IFS= read -r line; do
            [ -n "${line}" ] && SPEED_RESULT+=("${line}")
        done <<< "${sorted}"
    fi
    return 0
}

# 打印测速表格
print_speed_table() {
    printf '\n%-4s %-8s %-20s %-6s %-6s %-10s %-12s %s\n' \
        "序号" "ID" "名称" "状态" "HTTP" "延迟(ms)" "速率(KB/s)" "地址"
    hr
    local i=1 line id name url ok code lat spd size
    local mark
    for line in "${SPEED_RESULT[@]:-}"; do
        [ -n "${line}" ] || continue
        IFS='|' read -r id name url ok code lat spd size <<< "${line}"
        if [ "${ok}" = "1" ]; then
            mark="${C_G}可用${C_N}"
        else
            mark="${C_R}不可用${C_N}"
        fi
        local rate="${spd}"
        if [ "${ok}" = "1" ] && [ "${size}" -lt 64 ] 2>/dev/null; then
            rate="${spd}*"
        fi
        printf '%-4s %-8s %-20s %-14s %-6s %-10s %-12s %s\n' \
            "${i}" "${id}" "${name}" "${mark}" "${code}" "${lat}" "${rate}" "${url}"
        i=$((i+1))
    done
    hr
    printf '  说明: 延迟 = 首字节时间(TTFB)，越小越好；带 * 的速率因样本文件过小仅供参考\n'
    printf '        可用 --speed-url <大文件URL> 指定抽样文件以获得更准确的速率\n'
    return 0
}

# 从测速结果里取最优（第一个可用的）
best_mirror_from_result() {
    local line id name url ok
    for line in "${SPEED_RESULT[@]:-}"; do
        [ -n "${line}" ] || continue
        IFS='|' read -r id name url ok _ _ _ _ <<< "${line}"
        [ "${ok}" = "1" ] && { printf '%s' "${id}"; return 0; }
    done
    return 1
}

# =============================================================================
#  第 11 节  GPG 密钥处理
# =============================================================================

# 从 apt update 输出里提取缺失/失效的公钥 ID
extract_missing_keys() {
    local text="$1"
    {
        printf '%s\n' "${text}" | grep -oE 'NO_PUBKEY [0-9A-Fa-f]{8,}' | awk '{print $2}'
        printf '%s\n' "${text}" | grep -oE '(EXPKEYSIG|REVKEYSIG|BADSIG|ERRSIG) [0-9A-Fa-f]{8,}' | awk '{print $2}'
    } | sort -u
}

# 从 yum/dnf 输出里提取缺失的密钥提示
extract_rpm_key_errors() {
    printf '%s\n' "$1" | grep -iE 'public key|NOKEY|GPG key retrieval|failed to download .*key' | head -5
}

# 下载并导入一个 apt 公钥
apt_import_key() {
    local kid="$1" dest="${APT_TRUSTED_DIR}/set-mirror-fix-${kid}.gpg"
    local short="${kid: -8}"; short="$(printf '%s' "${short}" | tr 'A-Z' 'a-z')"
    dest="${APT_TRUSTED_DIR}/set-mirror-fix-${short}.gpg"

    log_step "导入缺失公钥 ${kid}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dry "将下载公钥 ${kid} 并写入 ${dest}"
        return 0
    fi

    local tmp; tmp="${TMP_DIR}/key-${kid}"
    mkdir -p "${tmp}" 2>/dev/null

    local got=0
    # 方式一：通过 keyserver HTTP 接口下载（对防火墙最友好）
    local ks
    for ks in "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${kid}" \
              "https://keys.openpgp.org/vks/v1/by-fingerprint/${kid}" \
              "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${kid}&options=mr"; do
        if curl -fsSL --max-time "${NET_TIMEOUT}" ${INSECURE:+-k} "${ks}" -o "${tmp}/key.asc" 2>/dev/null \
           && [ -s "${tmp}/key.asc" ] && grep -q 'BEGIN PGP PUBLIC KEY' "${tmp}/key.asc" 2>/dev/null; then
            got=1; log_dbg "已从 ${ks%%\?*} 获取密钥"; break
        fi
    done

    # 方式二：gpg --recv-keys
    if [ "${got}" -eq 0 ] && command -v gpg >/dev/null 2>&1; then
        local srv
        for srv in "hkps://keyserver.ubuntu.com" "hkps://keys.openpgp.org" "hkps://pgp.mit.edu"; do
            if gpg --homedir "${tmp}/gnupg" --batch --no-tty --quiet \
                   --keyserver "${srv}" --keyserver-options timeout=10 \
                   --recv-keys "${kid}" >/dev/null 2>&1; then
                gpg --homedir "${tmp}/gnupg" --batch --yes --export --output "${tmp}/key.bin" "${kid}" >/dev/null 2>&1 \
                    && { got=2; log_dbg "已通过 ${srv} 接收密钥"; break; }
            fi
        done
    fi

    mkdir -p "${APT_TRUSTED_DIR}" 2>/dev/null || { log_err "创建目录失败: ${APT_TRUSTED_DIR}"; return 1; }

    if [ "${got}" -eq 1 ]; then
        if command -v gpg >/dev/null 2>&1; then
            gpg --batch --yes --dearmor --output "${dest}" "${tmp}/key.asc" 2>/dev/null
        else
            cp -f "${tmp}/key.asc" "${dest}"
        fi
    elif [ "${got}" -eq 2 ]; then
        cp -f "${tmp}/key.bin" "${dest}"
    else
        log_err "无法获取公钥 ${kid}（keyserver 均不可达且本机无该密钥）"
        log_err "  可手工处理: gpg --keyserver keyserver.ubuntu.com --recv-keys ${kid}"
        log_err "           或访问 https://keyserver.ubuntu.com 搜索 0x${kid}"
        return 1
    fi

    chmod 644 "${dest}" 2>/dev/null
    log_ok "已导入公钥: ${dest}"
    return 0
}

# zypper / rpm 导入
rpm_import_key_url() {
    local url="$1"
    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dry "将导入 RPM 公钥: ${url}"; return 0
    fi
    local tmp="${TMP_DIR}/rpmkey.asc"
    if curl -fsSL --max-time "${NET_TIMEOUT}" ${INSECURE:+-k} "${url}" -o "${tmp}" 2>/dev/null && [ -s "${tmp}" ]; then
        rpm --import "${tmp}" 2>/dev/null && { log_ok "已导入 RPM 公钥: ${url}"; return 0; }
    fi
    log_warn "导入 RPM 公钥失败: ${url}"
    return 1
}

# 统一 GPG 修复入口：与索引更新联动，最多修复 2 轮
gpg_fix_loop() {
    [ "${NO_GPG_FIX}" -eq 1 ] && { log_info "已指定 --no-gpg-fix，跳过密钥修复"; return 0; }

    local round=1 out keys kid
    while [ "${round}" -le 2 ]; do
        case "${PM}" in
            apt)
                keys="$(extract_missing_keys "${LAST_UPDATE_OUTPUT:-}")"
                ;;
            dnf|yum)
                keys=""
                if printf '%s' "${LAST_UPDATE_OUTPUT:-}" | grep -qiE 'NOKEY|public key .* not installed|GPG key retrieval failed'; then
                    keys="RPM"
                fi
                ;;
            apk)
                if printf '%s' "${LAST_UPDATE_OUTPUT:-}" | grep -qi 'UNTRUSTED signature'; then
                    keys="APK"
                else
                    keys=""
                fi
                ;;
            zypper)
                keys=""
                ;;
            *) keys="" ;;
        esac

        [ -z "${keys}" ] && { [ "${round}" -eq 1 ] && log_ok "未检测到 GPG 密钥问题"; return 0; }

        log_step "检测到 GPG 密钥问题，第 ${round} 轮修复"

        if [ "${keys}" = "RPM" ]; then
            local f imported=0
            for f in "${RPM_GPG_DIR}"/RPM-GPG-KEY-*; do
                [ -e "${f}" ] || continue
                rpm --import "${f}" >/dev/null 2>&1 && imported=1
            done
            # 再尝试从当前镜像下载标准 key 文件
            local kurl
            for kurl in "${MIRROR_URL}/RPM-GPG-KEY-${OS_ID}-${OS_MAJOR}" \
                        "${MIRROR_URL}/RPM-GPG-KEY-${OS_ID}" \
                        "${MIRROR_URL}/RPM-GPG-KEY-CentOS-${OS_MAJOR}"; do
                rpm_import_key_url "${kurl}" && imported=1 && break
            done
            [ "${imported}" -eq 1 ] && log_ok "已导入本机已有的 RPM 公钥" \
                || log_warn "未找到可导入的 RPM 公钥，请检查 ${RPM_GPG_DIR}"
        elif [ "${keys}" = "APK" ]; then
            apk_fix_keys
        else
            # apt：逐个导入
            local any=0
            while IFS= read -r kid; do
                [ -n "${kid}" ] || continue
                apt_import_key "${kid}" && any=1
            done <<< "${keys}"
            [ "${any}" -eq 0 ] && { log_err "密钥修复未成功，停止后续尝试"; return 1; }
        fi

        # 修复后重新执行索引更新验证
        log_info "重新执行索引更新以验证修复结果"
        update_index || return 1
        round=$((round+1))
    done

    log_warn "已完成 ${round} 轮修复，如仍有密钥错误请手工处理"
    return 0
}

# Alpine 密钥修复
apk_fix_keys() {
    log_step "修复 Alpine APK 签名密钥"
    mkdir -p "${APK_KEYS_DIR}" 2>/dev/null || { log_err "创建目录失败: ${APK_KEYS_DIR}"; return 1; }
    local v; v="$(printf '%s' "${OS_VER}" | grep -oE '^[0-9]+\.[0-9]+')"
    [ -z "${v}" ] && v="${OS_VER}"
    local base="https://alpinelinux.org/keys"
    local f ok=0
    # mirror 优先，官方兜底
    for base in "${MIRROR_URL}/keys" "https://alpinelinux.org/keys" "https://keys.alpinelinux.org"; do
        for f in "alpine-devel%40lists.alpinelinux.org-4a6a0840.rsa.pub" \
                 "alpine-devel%40lists.alpinelinux.org-5243ef4b.rsa.pub" \
                 "alpine-devel%40lists.alpinelinux.org-5261cecb.rsa.pub" \
                 "alpine-devel%40lists.alpinelinux.org-6165ee59.rsa.pub" \
                 "alpine-devel%40lists.alpinelinux.org-61666e3f.rsa.pub"; do
            if [ "${DRY_RUN}" -eq 1 ]; then
                log_dry "将下载密钥: ${base}/${f}"; ok=1; continue
            fi
            if curl -fsSL --max-time "${NET_TIMEOUT}" ${INSECURE:+-k} "${base}/${f}" \
                 -o "${APK_KEYS_DIR}/${f//%40/@}" 2>/dev/null; then
                ok=1
            fi
        done
        [ "${ok}" -eq 1 ] && break
    done
    [ "${ok}" -eq 1 ] && log_ok "Alpine 密钥已更新于 ${APK_KEYS_DIR}" \
        || log_warn "未能自动获取 Alpine 密钥，请检查网络或手动放置到 ${APK_KEYS_DIR}"
    return 0
}

# =============================================================================
#  第 12 节  索引更新与结果验证
# =============================================================================

LAST_UPDATE_OUTPUT=""

update_index() {
    local rc=0
    log_step "更新软件包索引以验证源可用性"

    case "${PM}" in
        apt)
            local cmd="apt-get"
            command -v apt >/dev/null 2>&1 && cmd="apt"
            if [ "${OS_EOL}" -eq 1 ]; then
                LAST_UPDATE_OUTPUT="$(run_capture "${cmd}" -o Acquire::Check-Valid-Until=false update)"; rc=$?
            else
                LAST_UPDATE_OUTPUT="$(run_capture "${cmd}" update)"; rc=$?
            fi
            ;;
        dnf)
            LAST_UPDATE_OUTPUT="$(run_capture dnf -q makecache --refresh)"; rc=$?
            [ "${rc}" -ne 0 ] && LAST_UPDATE_OUTPUT="$(run_capture dnf -y makecache)"; rc=$?
            ;;
        yum)
            LAST_UPDATE_OUTPUT="$(run_capture yum -q makecache)"; rc=$?
            ;;
        apk)
            LAST_UPDATE_OUTPUT="$(run_capture apk update)"; rc=$?
            ;;
        zypper)
            LAST_UPDATE_OUTPUT="$(run_capture zypper --non-interactive --gpg-auto-import-keys refresh)"; rc=$?
            ;;
        *)
            log_err "未知包管理器，无法更新索引"; return 1 ;;
    esac

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dry "将执行索引更新: ${PM} update/makecache/refresh"
        return 0
    fi

    printf '%s\n' "${LAST_UPDATE_OUTPUT}" | tail -20 | sed 's/^/        | /'

    if [ "${rc}" -ne 0 ]; then
        log_warn "索引更新返回非零状态（${rc}），可能由密钥或网络问题引起"
        return "${rc}"
    fi
    log_ok "索引更新成功"
    return 0
}

# =============================================================================
#  第 13 节  主动作：切换 / 添加 / 恢复 / 回滚
# =============================================================================

prepare_snapshot() {
    local ts; ts="$(date '+%Y%m%d-%H%M%S')"
    local dir="${BACKUP_DIR}/${ts}"
    snapshot_open "${dir}" || return 1
    log_info "备份目录: ${dir}"
    return 0
}

# 切换（替换）软件源
action_set() {
    local spec="$1"
    require_root || return 1
    detect_os || return 1
    resolve_spec "${spec}" || return 1

    log_step "目标镜像: ${MIRROR_NAME} <${MIRROR_URL}>"

    # 生成内容
    DESIRED_CONTENT="$(gen_content)" || return 1

    # 幂等预判：目标文件已一致则跳过（不创建快照、不改动文件）
    local managed; managed="$(managed_file_path)"
    if [ "${DRY_RUN}" -eq 0 ] && content_matches "${managed}" "${DESIRED_CONTENT}"; then
        log_ok "源配置已是目标状态，无需重复修改（幂等跳过）"
        state_save
        [ "${NO_UPDATE}" -eq 0 ] && update_index || true
        print_summary
        return 0
    fi

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_dry "预演模式：以下内容将写入 $(managed_file_path)"
        printf '%s\n' "${DESIRED_CONTENT}"
    fi

    prepare_snapshot || return 1
    apply_config "${DESIRED_CONTENT}" || return 1

    # 首次修改前保存原始快照
    if [ "${DRY_RUN}" -eq 0 ] && [ ! -d "${ORIG_SNAPSHOT}" ]; then
        cp -a "${SNAP_DIR}" "${ORIG_SNAPSHOT}" 2>/dev/null \
            && log_info "已保存原始配置快照: ${ORIG_SNAPSHOT}（--restore 可恢复）"
    fi

    # 索引更新 + GPG 修复
    if [ "${NO_UPDATE}" -eq 1 ]; then
        log_info "已指定 --no-update，跳过索引更新"
    else
        if ! update_index; then
            gpg_fix_loop || {
                log_err "源配置后索引更新仍失败"
                if [ "${ASSUME_YES}" -eq 1 ]; then
                    log_warn "非交互模式，自动回滚到修改前状态"
                    snapshot_restore "${SNAP_DIR}"
                    return 1
                fi
                if confirm "是否回滚到修改前状态？" "y"; then
                    snapshot_restore "${SNAP_DIR}"
                    return 1
                fi
                log_warn "已保留新配置，请手工排查（可稍后执行 ${SCRIPT_NAME} --rollback）"
            }
        else
            gpg_check_after_update
        fi
    fi

    print_summary
    return 0
}

# 添加（不替换现有源）
action_add() {
    local spec="$1"
    require_root || return 1
    detect_os || return 1
    resolve_spec "${spec}" || return 1

    log_step "追加源: ${MIRROR_NAME} <${MIRROR_URL}>（保留现有源）"
    local content; content="$(gen_content)" || return 1
    # 去掉 header 中的"本文件由...管理"以免误导，追加模式写入独立文件
    local addfile
    case "${PM}" in
        apt)    addfile="${APT_SOURCES_DIR}/set-mirror-add-${MIRROR_ID}.list" ;;
        dnf|yum) addfile="${YUM_REPO_DIR}/set-mirror-add-${MIRROR_ID}.repo" ;;
        apk)    addfile="${APK_REPOS_FILE}.add-${MIRROR_ID}" ;;
        zypper) addfile="${ZYPP_REPO_DIR}/set-mirror-add-${MIRROR_ID}.repo" ;;
    esac

    prepare_snapshot || return 1
    if [ "${PM}" = "apk" ]; then
        log_warn "apk 使用单一 repositories 文件，追加模式将把内容合并进 ${APK_REPOS_FILE}"
        snapshot_file "${APK_REPOS_FILE}" || return 1
        if [ "${DRY_RUN}" -eq 0 ]; then
            printf '%s\n' "${content}" | grep -E '^[a-z]+:' >> "${APK_REPOS_FILE}" 2>/dev/null
            printf '%s\n' "${content}" | grep -E '^https?://' >> "${APK_REPOS_FILE}" 2>/dev/null
        else
            log_dry "将追加到 ${APK_REPOS_FILE}: $(printf '%s' "${content}" | grep -E '^https?://' | tr '\n' ' ')"
        fi
    else
        fs_replace "${addfile}" "${content}" 0644 || return 1
    fi
    log_ok "已追加: ${addfile}"

    if [ "${NO_UPDATE}" -eq 0 ]; then
        update_index || {
            gpg_fix_loop || log_warn "追加源后索引更新仍失败，可回滚: ${SCRIPT_NAME} --rollback"
        }
    fi
    print_summary
    return 0
}

# 恢复默认源：优先用原始快照，否则应用官方镜像
action_restore() {
    detect_os || return 1
    require_root

    if [ -d "${ORIG_SNAPSHOT}" ]; then
        log_step "恢复首次修改前的原始配置"
        if [ "${ASSUME_YES}" -eq 0 ]; then
            confirm "确认恢复原始配置（将覆盖当前源配置）？" "y" || { log_info "已取消"; return 0; }
        fi
        prepare_snapshot || return 1
        # 先删除本工具生成的文件
        remove_managed_files
        snapshot_restore "${ORIG_SNAPSHOT}"
        if [ "${NO_UPDATE}" -eq 0 ]; then
            update_index || log_warn "恢复后索引更新失败，请人工检查网络"
        fi
        [ "${DRY_RUN}" -eq 0 ] && rm -f "${STATE_FILE}" 2>/dev/null
        log_ok "已恢复原始配置"
        return 0
    fi

    log_info "未找到原始快照（本机尚未通过本工具修改过源）"
    log_info "将直接应用官方源配置"
    ACTION="set"
    WITH_EPEL=1
    action_set official
}

# 回滚最近一次修改
action_rollback() {
    local dir="${1:-}"
    require_root
    if [ -z "${dir}" ]; then
        dir="$(snapshot_latest)" || { log_err "没有可回滚的备份"; snapshot_list; return 1; }
    fi
    [ -d "${dir}" ] || { log_err "备份不存在: ${dir}"; return 1; }

    if [ "${ASSUME_YES}" -eq 0 ]; then
        log_warn "即将回滚到备份: ${dir}"
        confirm "确认回滚？" "y" || { log_info "已取消"; return 0; }
    fi
    snapshot_restore "${dir}"
    if [ "${NO_UPDATE}" -eq 0 ]; then
        update_index || log_warn "回滚后索引更新失败，请人工检查"
    fi
    log_ok "回滚完成: ${dir}"
    return 0
}

# 删除本工具生成的文件
remove_managed_files() {
    local f
    for f in "${APT_MANAGED_FILE}" "${YUM_MANAGED_FILE}" "${ZYPP_MANAGED_FILE}" \
             "${APT_SOURCES_DIR}"/set-mirror-add-*.list \
             "${YUM_REPO_DIR}"/set-mirror-add-*.repo \
             "${ZYPP_REPO_DIR}"/set-mirror-add-*.repo; do
        [ -e "${f}" ] || continue
        if [ "${DRY_RUN}" -eq 1 ]; then
            log_dry "将删除: ${f}"
        else
            rm -f "${f}" && log_info "已删除: ${f}"
        fi
    done
    # 恢复被禁用的发行版源
    local d
    for d in "${APT_SOURCES_DIR}" "${YUM_REPO_DIR}" "${ZYPP_REPO_DIR}"; do
        for f in "${d}"/*.set-mirror-disabled; do
            [ -e "${f}" ] || continue
            if [ "${DRY_RUN}" -eq 1 ]; then
                log_dry "将还原: ${f}"
            else
                mv -f "${f}" "${f%.set-mirror-disabled}" 2>/dev/null \
                    && log_info "已还原: $(basename "${f%.set-mirror-disabled}")"
            fi
        done
    done
    return 0
}

# 索引更新后检查是否仍有密钥错误
gpg_check_after_update() {
    [ "${NO_GPG_FIX}" -eq 1 ] && return 0
    local keys
    keys="$(extract_missing_keys "${LAST_UPDATE_OUTPUT:-}")"
    if [ -n "${keys}" ]; then
        gpg_fix_loop
        return $?
    fi
    return 0
}

# =============================================================================
#  第 14 节  摘要输出
# =============================================================================

print_summary() {
    sec "执行摘要"
    printf '  镜像源      : %s\n' "${MIRROR_NAME}"
    printf '  源地址      : %s\n' "${MIRROR_URL}"
    printf '  配置文件    : %s\n' "$(managed_file_path)"
    printf '  包管理器    : %s\n' "${PM}"
    printf '  备份位置    : %s\n' "${SNAP_DIR:-（未创建）}"
    printf '\n  常用命令:\n'
    case "${PM}" in
        apt)
            printf '    apt update && apt upgrade\n'
            printf '    apt install <包名>\n' ;;
        dnf) printf '    dnf makecache && dnf update\n    dnf install <包名>\n' ;;
        yum) printf '    yum makecache && yum update\n    yum install <包名>\n' ;;
        apk) printf '    apk update && apk upgrade\n    apk add <包名>\n' ;;
        zypper) printf '    zypper refresh && zypper update\n    zypper install <包名>\n' ;;
    esac
    printf '\n  撤销本次修改: %s --rollback\n' "${SCRIPT_NAME}"
    printf '  恢复默认源  : %s --restore\n' "${SCRIPT_NAME}"
    printf '  查看当前配置: %s --status\n' "${SCRIPT_NAME}"
}

# 显示当前生效配置
action_status() {
    detect_os || return 1
    detect_summary
    local p; p="$(managed_file_path)"
    printf '\n'
    sec "当前源配置文件内容"
    if [ -f "${p}" ]; then
        cat "${p}" | sed 's/^/  /'
    else
        printf '  （%s 不存在，当前使用系统自带源配置）\n' "${p}"
    fi
    # 列出实际生效的源
    printf '\n'
    sec "系统实际生效的源"
    case "${PM}" in
        apt)
            if [ -f "${APT_SOURCES_LIST}" ]; then
                grep -E '^\s*deb' "${APT_SOURCES_LIST}" 2>/dev/null | sed 's/^/  /'
            fi
            local f
            for f in "${APT_SOURCES_DIR}"/*.list "${APT_SOURCES_DIR}"/*.sources; do
                [ -e "${f}" ] || continue
                grep -hE '^\s*(deb|URIs:)' "${f}" 2>/dev/null | sed "s|^|  [$(basename "${f}")] |"
            done
            ;;
        dnf|yum)
            grep -hE '^baseurl=|^\[' "${YUM_REPO_DIR}"/*.repo 2>/dev/null | sed 's/^/  /'
            ;;
        apk)
            [ -f "${APK_REPOS_FILE}" ] && cat "${APK_REPOS_FILE}" | sed 's/^/  /'
            ;;
        zypper)
            command -v zypper >/dev/null 2>&1 && zypper lr -u 2>/dev/null | sed 's/^/  /'
            ;;
    esac
    return 0
}

# =============================================================================
#  第 15 节  交互式菜单
# =============================================================================

confirm() {
    local prompt="$1" default="${2:-y}" ans
    if [ "${ASSUME_YES}" -eq 1 ]; then
        log_dbg "非交互模式，确认项取默认值: ${default}"
        [ "${default}" = "y" ] && return 0 || return 1
    fi
    local hint="[Y/n]"; [ "${default}" = "n" ] && hint="[y/N]"
    read -r -p "  ${prompt} ${hint}: " ans
    [ -z "${ans}" ] && ans="${default}"
    case "${ans}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

ask() {
    local prompt="$1" default="$2" __var="$3" val
    if [ "${ASSUME_YES}" -eq 1 ]; then
        printf -v "${__var}" '%s' "${default}"
        log_dbg "非交互模式，输入项取默认值: ${default}"
        return 0
    fi
    read -r -p "  ${prompt} [${default}]: " val
    [ -z "${val}" ] && val="${default}"
    printf -v "${__var}" '%s' "${val}"
    return 0
}

interactive_menu() {
    detect_os || return 1
    while :; do
        clear_screen
        printf '\n%s\n' "${C_C}================ 软件源管理工具 v${SCRIPT_VERSION} ================${C_N}"
        printf '  系统: %s %s (%s)   包管理器: %s   %s\n' \
            "${OS_NAME:-${OS_ID}}" "${OS_VER}" "${OS_ID}" "${PM}" \
            "$([ "${IS_ROOT}" -eq 1 ] && echo "${C_G}root${C_N}" || echo "${C_Y}非root${C_N}")"
        hr
        printf '  1) 查看当前源配置\n'
        printf '  2) 列出所有候选镜像源\n'
        printf '  3) 测速并排序（自动选最优）\n'
        printf '  4) 切换到指定镜像源\n'
        printf '  5) 手动输入源地址（自定义 URL）\n'
        printf '  6) 追加一个源（不替换现有）\n'
        printf '  7) 仅更新软件包索引\n'
        printf '  8) 修复 GPG 密钥问题\n'
        printf '  9) 恢复默认源\n'
        printf ' 10) 回滚到上一次修改\n'
        printf ' 11) 查看备份列表\n'
        printf '  0) 退出\n'
        hr
        local choice
        read -r -p "  请选择 [0-11]: " choice
        case "${choice}" in
            1) action_status; pause ;;
            2) mirror_list; pause ;;
            3) interactive_speedtest ;;
            4) interactive_choose_mirror ;;
            5) interactive_custom_url ;;
            6) interactive_add ;;
            7) update_index; pause ;;
            8) NO_GPG_FIX=0; gpg_fix_loop; pause ;;
            9) action_restore; pause ;;
            10) action_rollback; pause ;;
            11) snapshot_list; pause ;;
            0) log_info "已退出"; return 0 ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

clear_screen() { command -v clear >/dev/null 2>&1 && clear 2>/dev/null; return 0; }
pause() { printf '\n'; read -r -p "  按回车继续..." _; return 0; }

interactive_speedtest() {
    mirror_speedtest_all
    print_speed_table
    local best; best="$(best_mirror_from_result)" || {
        log_err "所有候选源均不可用，请检查网络或手动指定源地址"; pause; return 1; }
    local idx; idx="$(printf '%s\n' "${SPEED_RESULT[@]}" | grep -n "^${best}|" | head -1 | cut -d: -f1)"
    log_ok "最优源: ${best}"
    if confirm "是否切换到该源？" "y"; then
        ACTION="set"; TARGET_SPEC="${best}"; action_set "${best}"; pause
    else
        pause
    fi
    return 0
}

interactive_choose_mirror() {
    mirror_list
    local spec
    ask "请输入镜像 ID（或输入 a 先测速）" "aliyun" spec
    if [ "${spec}" = "a" ]; then interactive_speedtest; return 0; fi
    ACTION="set"; action_set "${spec}"; pause
    return 0
}

interactive_custom_url() {
    local url
    ask "请输入完整的源地址（如 https://mirrors.example.com/debian）" "" url
    [ -z "${url}" ] && { log_err "地址不能为空"; pause; return 1; }
    if [ "${ASSUME_YES}" -eq 0 ] && ! confirm "目标地址: ${url}，确认切换？" "y"; then
        pause; return 0
    fi
    ACTION="set"; action_set "${url}"; pause
    return 0
}

interactive_add() {
    local url
    ask "请输入要追加的源地址（完整 URL 或镜像 ID）" "" url
    [ -z "${url}" ] && { log_err "地址不能为空"; pause; return 1; }
    ACTION="add"; action_add "${url}"; pause
    return 0
}

# =============================================================================
#  第 16 节  参数解析
# =============================================================================

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} - Linux 软件源（镜像源）管理工具

用法:
  ${SCRIPT_NAME} [选项]

模式:
  -l, --list                  列出当前发行版可用的镜像源
  -s, --set <id|URL>          切换到指定镜像（内置 ID 或完整 URL）
  -a, --add <id|URL>          追加一个源，不替换现有配置
      --auto                  自动测速并选择最优源
  -t, --test                  仅测速并输出排序结果，不修改配置
      --restore               恢复默认源（优先还原首次修改前的原始配置）
      --rollback [备份ID]     回滚到指定备份，默认最近一次
      --backup-list           列出所有备份
      --status                显示当前生效的源配置
      --fix-gpg               仅修复 GPG 密钥问题
      --update                仅更新软件包索引

选项:
  -y, --yes                   非交互执行，所有确认取默认值
  -n, --dry-run               预演模式，只输出将要执行的操作，不落盘
      --no-update             修改后不执行索引更新
      --no-gpg-fix            不自动修复 GPG 密钥问题
      --distro <id>           手动指定发行版 ID（debian/ubuntu/centos/alpine...）
      --version <ver>         手动指定发行版版本号
      --eol                   强制按 EOL（归档源）处理
      --no-epel               RHEL 系不生成 EPEL 源
      --with-src              apt 同时生成 deb-src 源
      --timeout <秒>          单次网络探测超时（默认 ${NET_TIMEOUT}）
      --speed-url <URL>       指定测速抽样用的大文件 URL
      --parallel <n>          测速并发度（默认 ${MAX_PARALLEL}）
  -k, --insecure              curl 跳过 TLS 证书校验
  -v, --verbose              输出调试信息
  -h, --help                 显示本帮助

示例:
  sudo ${SCRIPT_NAME}                            # 交互式菜单
  ${SCRIPT_NAME} --list                          # 查看候选源（无需 root）
  sudo ${SCRIPT_NAME} --auto                     # 自动测速并切换到最优源
  sudo ${SCRIPT_NAME} --set aliyun               # 切换到阿里云
  sudo ${SCRIPT_NAME} --set https://mirrors.tencent.com/debian
  sudo ${SCRIPT_NAME} --set aliyun --dry-run     # 预演，不实际修改
  sudo ${SCRIPT_NAME} --restore                  # 恢复默认源
  sudo ${SCRIPT_NAME} --rollback                 # 回滚上一次修改

权限说明:
  修改 /etc 下的源配置文件需要 root。脚本非 root 运行时会自动尝试
  sudo / pkexec 提权；两者都不可用时会给出明确提示并以退出码 1 结束。
  只读操作（--list / --test / --status / --backup-list）无需 root。
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)      usage; exit 0 ;;
            -l|--list)      ACTION="list"; shift ;;
            -s|--set)       [ $# -lt 2 ] && { log_err "选项 $1 需要一个值（镜像 ID 或 URL）"; exit 2; }
                            ACTION="set";   TARGET_SPEC="$2"; shift 2 ;;
            -a|--add)       [ $# -lt 2 ] && { log_err "选项 $1 需要一个值（镜像 ID 或 URL）"; exit 2; }
                            ACTION="add";   TARGET_SPEC="$2"; shift 2 ;;
            --auto)         ACTION="auto";  shift ;;
            -t|--test)      ACTION="test";  shift ;;
            --restore)      ACTION="restore"; shift ;;
            --rollback)     ACTION="rollback"
                            if [ $# -ge 2 ] && [ "${2#-}" = "${2}" ]; then
                                TARGET_SPEC="$2"; shift 2
                            else
                                shift
                            fi ;;
            --backup-list)  ACTION="backup-list"; shift ;;
            --status)       ACTION="status"; shift ;;
            --fix-gpg)      ACTION="fixgpg"; shift ;;
            --update)       ACTION="update"; shift ;;
            -y|--yes)       ASSUME_YES=1; shift ;;
            -n|--dry-run)   DRY_RUN=1; shift ;;
            --no-update)    NO_UPDATE=1; shift ;;
            --no-gpg-fix)   NO_GPG_FIX=1; shift ;;
            --distro)       [ $# -lt 2 ] && { log_err "选项 $1 需要一个值（发行版 ID）"; exit 2; }
                            MANUAL_DISTRO="$2"; shift 2 ;;
            --version)      [ $# -lt 2 ] && { log_err "选项 $1 需要一个值（版本号）"; exit 2; }
                            MANUAL_VERSION="$2"; shift 2 ;;
            --eol)          FORCE_EOL=1; shift ;;
            --no-epel)      WITH_EPEL=0; shift ;;
            --with-src)     WITH_SRC=1; shift ;;
            --timeout)      [ $# -lt 2 ] && { log_err "选项 $1 需要一个值（秒）"; exit 2; }
                            NET_TIMEOUT="$2"; shift 2 ;;
            --speed-url)    [ $# -lt 2 ] && { log_err "选项 $1 需要一个值（URL）"; exit 2; }
                            SPEED_URL="$2"; shift 2 ;;
            --parallel)     [ $# -lt 2 ] && { log_err "选项 $1 需要一个值（并发数）"; exit 2; }
                            MAX_PARALLEL="$2"; shift 2 ;;
            -k|--insecure)  INSECURE=1; shift ;;
            -v|--verbose)   VERBOSE=1; shift ;;
            --)             shift; break ;;
            -*)             log_err "未知参数: $1"; usage; exit 2 ;;
            *)              log_err "多余的位置参数: $1"; usage; exit 2 ;;
        esac
    done

    # 参数校验
    case "${ACTION}" in
        set|add)
            [ -z "${TARGET_SPEC}" ] && { log_err "错误: --set/--add 需要指定镜像 ID 或 URL"; exit 2; }
            ;;
    esac
    case "${NET_TIMEOUT}" in
        ''|*[!0-9]*) log_err "错误: --timeout 必须是正整数"; exit 2 ;;
    esac
    case "${MAX_PARALLEL}" in
        ''|*[!0-9]*) log_err "错误: --parallel 必须是正整数"; exit 2 ;;
    esac
    return 0
}

# =============================================================================
#  第 17 节  主流程
# =============================================================================

main() {
    parse_args "$@"

    # 临时目录（强制 POSIX 路径，规避个别平台 TMPDIR 含反斜杠导致 rm 失败）
    if [ -n "${TMPDIR:-}" ] && [ -d "${TMPDIR}" ] && ! printf '%s' "${TMPDIR}" | grep -q '\\'; then
        TMP_DIR="${TMPDIR}/set-mirror.$$.${RANDOM:-0}"
    else
        TMP_DIR="/tmp/set-mirror.$$.${RANDOM:-0}"
    fi
    mkdir -p "${TMP_DIR}" 2>/dev/null || TMP_DIR="/tmp/set-mirror.$$"
    # shellcheck disable=SC2064
    trap 'if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then rm -rf "${TMP_DIR}" 2>/dev/null; fi' EXIT INT TERM

    # 只读动作无需 root
    case "${ACTION}" in
        list|test|backup-list|status|"")
            check_root
            ;;
        *)
            require_root
            ;;
    esac

    check_root
    detect_os || exit 1
    check_deps || exit 1

    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '\n%s\n' "${C_M}>>> 预演模式：以下操作不会真正执行，不会修改任何文件 <<<${C_N}"
    fi

    case "${ACTION}" in
        list)
            detect_summary
            mirror_list
            ;;
        status)
            action_status
            ;;
        test)
            detect_summary
            mirror_speedtest_all
            print_speed_table
            ;;
        auto)
            mirror_speedtest_all
            print_speed_table
            local best; best="$(best_mirror_from_result)" \
                || { log_err "所有候选源均不可用，请检查网络或手动指定: --set <URL>"; exit 1; }
            log_ok "自动选择最优源: ${best}"
            action_set "${best}" || exit 1
            ;;
        set)
            action_set "${TARGET_SPEC}" || exit 1
            ;;
        add)
            action_add "${TARGET_SPEC}" || exit 1
            ;;
        restore)
            action_restore || exit 1
            ;;
        rollback)
            if [ -n "${TARGET_SPEC}" ]; then
                action_rollback "${BACKUP_DIR}/${TARGET_SPEC}" || exit 1
            else
                action_rollback || exit 1
            fi
            ;;
        backup-list)
            snapshot_list
            ;;
        fixgpg)
            NO_UPDATE=0
            update_index || true
            gpg_fix_loop || exit 1
            ;;
        update)
            update_index || exit 1
            ;;
        "")
            interactive_menu
            ;;
        *)
            log_err "未知动作: ${ACTION}"; exit 2 ;;
    esac

    return 0
}

main "$@"
