#!/usr/bin/env bash
# =============================================================================
#  install_pkg.sh —— Linux 通用软件包安装工具（交互式 / 非交互式）
#
#  支持格式:
#    归档类  tar / tar.gz / tgz / tar.bz2 / tbz2 / tar.xz / txz / tar.zst / zip
#    包管理  deb (dpkg)  rpm (rpm)
#    可执行  AppImage / 二进制 / .sh .run .bin 安装脚本
#
#  功能:
#    * 自动识别包类型（扩展名 + file 命令 + magic bytes），支持手动指定
#    * 安装目录默认 /opt，可自定义；校验存在性与写权限，不存在时询问创建
#    * 桌面快捷方式三种作用范围：所有用户 / 当前用户 / 指定用户（用户名|UID|SID）
#      范围由主机环境自动判定，支持 auto|strict|skip 三种失败回退策略
#    * 服务注册覆盖 11 种管理器与系统级/用户级两种作用域：
#      systemd / upstart / sysv / openrc / runit / s6 / supervisord /
#      launchd / cron / rc.local / none，同样按环境自动判定并处理冲突与降级
#    * root 权限提前检测并提示；任一步骤失败自动回滚已生成文件
#    * 实时日志 + 结束摘要（安装路径、快捷方式、服务名、管理命令）
#    * 完整命令行参数，支持非交互执行
#
#  用法:
#    交互式:   bash install_pkg.sh
#    非交互:   bash install_pkg.sh -i ./app.tar.gz -d /opt -y --desktop --service
#    判定说明: bash install_pkg.sh --explain
#    帮助:     bash install_pkg.sh --help
#
#  退出码:  0 成功  1 常规错误  2 参数错误  3 权限不足  4 不支持的包类型
# =============================================================================

set -uo pipefail
export LC_ALL=C

# ============================================================================
#  第 1 节：常量与全局状态
# ============================================================================
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

# 颜色输出（非终端时自动关闭）
if [ -t 1 ]; then
    C_R='\033[0;31m'; C_G='\033[0;32m'; C_Y='\033[1;33m'
    C_B='\033[0;34m'; C_C='\033[0;36m'; C_N='\033[0m'; C_D='\033[2m'
else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_C=''; C_N=''; C_D=''
fi

# ---- 用户可配置项（由交互或命令行参数填充）----
PKG_PATH=""            # 软件包路径
PKG_TYPE=""            # 包类型（auto 表示自动识别）
PKG_TYPE_REAL=""       # 识别后的真实类型
INSTALL_BASE=""        # 安装基目录，默认 /opt
INSTALL_DIR=""         # 最终安装目录 = INSTALL_BASE/APP_NAME
APP_NAME=""            # 软件名称
APP_EXEC=""            # 可执行文件绝对路径
APP_DESC=""            # 软件/服务描述
INSTALL_MODE="system"  # deb/rpm: system(包管理器) | extract(仅解包)

# 桌面快捷方式
DO_DESKTOP=""          # yes / no / 空(询问)
DESKTOP_NAME=""
DESKTOP_ICON=""
DESKTOP_CATEGORY="Utility"
DESKTOP_TERMINAL="false"
DESKTOP_SCOPE=""          # all | current | user | auto（空=按环境自动判定）
DESKTOP_TARGET_USER=""    # scope=user 的目标用户（用户名 / UID / SID）
DESKTOP_FALLBACK="auto"   # auto(逐级降级) | strict(不降级) | skip(失败即跳过)
DESKTOP_SYNC_EXISTING=0   # all 模式下是否同步到已存在用户的桌面目录
DESKTOP_SCOPE_DECIDED=""  # 自动判定结果
DESKTOP_SCOPE_APPLIED=""  # 实际生效的范围（可能与判定不同，说明发生了回退）
DESKTOP_SCOPE_REASON=""   # 判定依据（可追溯）
DESKTOP_LAST_ERR=""       # 最近一次失败原因
DESKTOP_BASENAME=""       # 规范化后的文件名
DESKTOP_ICON_REAL=""      # 实际使用的图标
DESKTOP_FILES_CREATED=()  # 本次创建的所有 .desktop 路径

# 服务注册
DO_SERVICE=""          # yes / no / 空(询问)
SVC_MANAGER=""         # systemd|upstart|sysv|openrc|runit|s6|supervisord|launchd|cron|rclocal|none|auto
SVC_SCOPE=""           # system | user | auto
SVC_START_MODE=""      # now(自启+启动) | boot(仅自启) | none(仅注册)
SVC_NAME=""
SVC_USER=""
SVC_CMD=""
SVC_WORKDIR=""
SVC_RESTART="on-failure"
SVC_DESC=""
SVC_TYPE="simple"      # systemd/其它管理器共用的进程类型
SVC_AFTER="network.target"
SVC_FORCE=0            # 覆盖非本工具创建的服务定义
SVC_MANAGER_DECIDED="" # 自动判定的管理器
SVC_SCOPE_DECIDED=""   # 自动判定的作用域
SVC_MANAGER_APPLY=""   # 实际生效的管理器
SVC_SCOPE_APPLY=""     # 实际生效的作用域
SVC_MANAGER_REASON=""  # 判定依据
SVC_FILES_CREATED=()

# 用户解析结果（由 resolve_user_ref 填充）
RU_NAME=""; RU_UID=""; RU_GID=""; RU_HOME=""; RU_ERR=""

# 主机环境探测结果（第 9 节填充，模式判定的唯一依据）
ENV_IS_ROOT=0; ENV_CAN_SUDO=0; ENV_SUDO_USER=""
ENV_HAS_GUI=0; ENV_REMOTE=0; ENV_CONTAINER=0
ENV_SESSIONS=0; ENV_HOME_USERS=0; ENV_PID1=""
ENV_MGRS=""; ENV_SYSTEMD_USER=0; ENV_XDG_RUNTIME=0
EXPLAIN_ONLY=0            # --explain：只打印判定报告后退出

# 行为控制
ASSUME_YES=0           # -y 非交互
NO_ROLLBACK=0          # 失败时不回滚
VERBOSE=0

# 运行时状态
NEED_ROOT_REASONS=()   # 需要 root 的原因列表
ROLLBACK_ITEMS=()      # 回滚栈（逆序执行）
IS_ROOT=0
TEMP_DIRS=()           # 临时目录，退出时清理
INSTALLED_PKG_NAME=""  # deb/rpm 安装后的包名，用于卸载与回滚

# ============================================================================
#  第 2 节：日志与输出
# ============================================================================
_ts() { date '+%H:%M:%S'; }

log_info() { printf "${C_G}[%s]${C_N} %s\n" "$(_ts)" "$*"; }
log_step() { printf "${C_C}[%s] ==>${C_N} %s\n" "$(_ts)" "$*"; }
log_warn() { printf "${C_Y}[%s] WARN${C_N} %s\n" "$(_ts)" "$*" >&2; }
log_err()  { printf "${C_R}[%s] ERROR${C_N} %s\n" "$(_ts)" "$*" >&2; }
log_dbg()  { [ "${VERBOSE}" -eq 1 ] && printf "${C_D}[%s]  DBG${C_N} %s\n" "$(_ts)" "$*"; return 0; }
hr()       { printf '%s\n' "---------------------------------------------------------------"; }

# 带默认值提问：直接回车返回默认值
# 用法: ask "提示语" "默认值" 变量名
ask() {
    local prompt="$1" default="$2" __out="$3" ans
    if [ "${ASSUME_YES}" -eq 1 ]; then
        printf -v "${__out}" '%s' "${default}"
        printf '%s %s [%s]\n' "?" "${prompt}" "${default}"
        return 0
    fi
    read -r -p "$(printf '%s %s ${C_C}[%s]${C_N}: ' '?' "${prompt}" "${default}")" ans
    printf -v "${__out}" '%s' "${ans:-${default}}"
}

# 是否确认：y/N 或 Y/n
# 用法: confirm "是否继续?" "n"  -> 返回 0 表示确认
confirm() {
    local prompt="$1" default="${2:-y}" ans
    if [ "${ASSUME_YES}" -eq 1 ]; then
        printf '%s %s [自动确认: %s]\n' "?" "${prompt}" "${default}"
        [ "${default}" = "y" ] && return 0 || return 1
    fi
    local hint="y/N"; [ "${default}" = "y" ] && hint="Y/n"
    read -r -p "$(printf '%s ${C_Y}%s${C_N} (%s): ' '?' "${prompt}" "${hint}")" ans
    ans="${ans:-${default}}"
    case "${ans}" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# 失败终止：打印错误 + 回滚 + 退出
fail() {
    log_err "$*"
    if [ "${NO_ROLLBACK}" -eq 0 ]; then
        do_rollback
    else
        log_warn "--no-rollback 已指定，保留现场不清理"
    fi
    cleanup_temp
    exit 1
}

# ============================================================================
#  第 3 节：回滚与临时文件管理
# ============================================================================
cleanup_temp() {
    local d
    for d in "${TEMP_DIRS[@]:-}"; do
        [ -n "${d}" ] && [ -d "${d}" ] && rm -rf "${d}" 2>/dev/null
    done
}
trap cleanup_temp EXIT

# 登记需要回滚的对象
#   track "file"  <路径>   —— 删除文件
#   track "dir"   <路径>   —— 删除目录
#   track "cmd"   <命令>   —— 执行撤销命令（如 dpkg -r / systemctl disable）
track() {
    local kind="$1" val="$2"
    ROLLBACK_ITEMS+=("${kind}::${val}")
    log_dbg "登记回滚项: ${kind}::${val}"
}

# 逆序执行回滚
do_rollback() {
    [ "${#ROLLBACK_ITEMS[@]}" -eq 0 ] && { log_dbg "无回滚项"; return 0; }
    log_warn "正在回滚已生成的 ${#ROLLBACK_ITEMS[@]} 项内容 ..."
    local i item kind val
    for (( i=${#ROLLBACK_ITEMS[@]}-1; i>=0; i-- )); do
        item="${ROLLBACK_ITEMS[$i]}"
        kind="${item%%::*}"; val="${item#*::}"
        case "${kind}" in
            file) rm -f "${val}" 2>/dev/null && log_info "已删除文件: ${val}" ;;
            dir)  rm -rf "${val}" 2>/dev/null && log_info "已删除目录: ${val}" ;;
            cmd)  log_step "执行撤销: ${val}"; eval "${val}" >/dev/null 2>&1 ;;
        esac
    done
    ROLLBACK_ITEMS=()
}

# ============================================================================
#  第 4 节：权限检测与提权
# ============================================================================
readonly ELEV_MARK="PKG_INSTALL_ELEVATED"

check_root() {
    local uid; uid="$(id -u 2>/dev/null || true)"
    [ -z "${uid}" ] && uid=1000
    IS_ROOT=0
    [ "${uid}" -eq 0 ] && IS_ROOT=1
    return 0
}

# 登记一条需要 root 的原因
require_root_for() { NEED_ROOT_REASONS+=("$1"); }

# 若确实需要 root 而当前不是 root：提示并尝试提权重执行
ensure_privileges() {
    [ "${IS_ROOT}" -eq 1 ] && return 0
    [ "${#NEED_ROOT_REASONS[@]}" -eq 0 ] && return 0

    hr
    log_warn "以下操作需要 root 权限："
    local r
    for r in "${NEED_ROOT_REASONS[@]}"; do printf '   - %s\n' "${r}"; done
    hr

    # 记录当前已确认的选项，通过环境变量透传给提权后的进程
    local sudo_bin pkexec_bin
    sudo_bin="$(command -v sudo 2>/dev/null || true)"
    pkexec_bin="$(command -v pkexec 2>/dev/null || true)"

    if [ -z "${sudo_bin}" ] && [ -z "${pkexec_bin}" ]; then
        log_err "系统未安装 sudo 或 pkexec，无法自动提权。"
        log_err "请改用 root 执行：  su - root -c 'bash ${BASH_SOURCE[0]} $*'"
        exit 3
    fi

    if [ -n "${!ELEV_MARK:-}" ]; then
        log_err "已尝试提权但当前仍非 root，终止执行。"
        exit 3
    fi

    if [ "${ASSUME_YES}" -eq 1 ]; then
        : # 非交互模式直接尝试提权
    elif ! confirm "是否自动使用 sudo 提权继续？" "y"; then
        log_err "权限不足，已取消。可改用 root 运行本脚本。"
        exit 3
    fi

    local self="${BASH_SOURCE[0]}"
    command -v readlink >/dev/null 2>&1 && {
        local rp; rp="$(readlink -f "$self" 2>/dev/null || true)"; [ -n "$rp" ] && self="$rp"
    }

    # 把交互结果通过环境变量传给提权后的进程，避免用户重复输入
    local envs=("${ELEV_MARK}=1" "PKG_PRESET_NAME=${APP_NAME}" "PKG_PRESET_BASE=${INSTALL_BASE}"
                "PKG_PRESET_TYPE=${PKG_TYPE}" "PKG_PRESET_PATH=${PKG_PATH}"
                "PKG_PRESET_DESKTOP=${DO_DESKTOP}" "PKG_PRESET_SERVICE=${DO_SERVICE}"
                "PKG_PRESET_MODE=${INSTALL_MODE}")
    [ "${ASSUME_YES}" -eq 1 ] && envs+=("PKG_PRESET_YES=1")

    log_step "正在提权重新执行 ..."
    if [ -n "${sudo_bin}" ]; then
        local sflag=""
        ${sudo_bin} -n -E true >/dev/null 2>&1 && sflag="-E"
        ${sudo_bin} -v || { log_err "sudo 认证失败，终止。"; exit 3; }
        ${sudo_bin} ${sflag} env "${envs[@]}" bash "${self}" "$@"
        exit $?
    fi
    ${pkexec_bin} env "${envs[@]}" bash "${self}" "$@"
    exit $?
}

# ============================================================================
#  第 5 节：包类型识别
# ============================================================================
# 依据扩展名推断
detect_by_ext() {
    local f="$1" base
    base="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
    case "${base}" in
        *.tar.gz|*.tgz)    echo "tar.gz" ;;
        *.tar.bz2|*.tbz2|*.tbz) echo "tar.bz2" ;;
        *.tar.xz|*.txz)    echo "tar.xz" ;;
        *.tar.zst|*.tzst)  echo "tar.zst" ;;
        *.tar)             echo "tar" ;;
        *.zip)             echo "zip" ;;
        *.deb)             echo "deb" ;;
        *.rpm)             echo "rpm" ;;
        *.appimage|*.AppImage) echo "appimage" ;;
        *.run|*.bin|*.sh)  echo "script" ;;
        *)                 echo "" ;;
    esac
}

# 依据 magic bytes 推断（扩展名不可靠时的兜底）
detect_by_magic() {
    local f="$1" m
    m="$(head -c 8 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ -z "$m" ] && { echo ""; return; }
    case "$m" in
        1f8b*)          echo "tar.gz" ;;      # gzip
        fd377a585a00*)  echo "tar.xz" ;;      # xz
        425a68*)        echo "tar.bz2" ;;     # bzip2
        28b52ffd*)      echo "tar.zst" ;;     # zstd
        504b0304*|504b0506*|504b0708*) echo "zip" ;;
        213c617263683e*) echo "deb" ;;        # !<arch>
        edabeedb*)      echo "rpm" ;;
        7f454c46*)      echo "binary" ;;      # ELF
        *)              echo "" ;;
    esac
}

# 综合识别：扩展名 > file 命令 > magic bytes
detect_pkg_type() {
    local f="$1" t=""
    t="$(detect_by_ext "$f")"
    [ -z "$t" ] && command -v file >/dev/null 2>&1 && {
        local desc; desc="$(file -b "$f" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
        case "${desc}" in
            *gzip*)      t="tar.gz" ;;
            *"xz compressed"*) t="tar.xz" ;;
            *bzip2*)     t="tar.bz2" ;;
            *"zip archive"*) t="zip" ;;
            *"debian binary package"*|*"deb archive"*) t="deb" ;;
            *"rpm "*)    t="rpm" ;;
            *"posix tar archive"*|*"tar archive"*) t="tar" ;;
            *elf*executable*|*elf*shared*) t="binary" ;;
            *"shell script"*|*text\ executable*) t="script" ;;
        esac
    }
    [ -z "$t" ] && t="$(detect_by_magic "$f")"
    printf '%s' "$t"
}

# 包名推导：app-1.2.3-linux-x64.tar.gz -> app
derive_app_name() {
    local base n
    base="$(basename "$1")"
    n="${base}"
    # 逐层剥离已知后缀
    n="${n%.tar.gz}"; n="${n%.tgz}"
    n="${n%.tar.bz2}"; n="${n%.tbz2}"; n="${n%.tbz}"
    n="${n%.tar.xz}"; n="${n%.txz}"
    n="${n%.tar.zst}"; n="${n%.tzst}"
    n="${n%.tar}"; n="${n%.zip}"
    n="${n%.deb}"; n="${n%.rpm}"
    n="${n%.AppImage}"; n="${n%.appimage}"
    n="${n%.run}"; n="${n%.bin}"; n="${n%.sh}"
    # 去掉常见版本号与平台后缀
    n="$(printf '%s' "$n" | sed -E 's/-([0-9]+(\.[0-9]+)*([-_][A-Za-z0-9]+)*)$//')"
    n="$(printf '%s' "$n" | sed -E 's/[-_](linux|amd64|x86_64|x64|i386|i686|aarch64|arm64|gnu|musl|portable|bin|appimage)[-_]?[A-Za-z0-9]*$//I')"
    printf '%s' "${n:-app}"
}

# 校验类型是否被支持及所需工具是否具备
validate_type_tools() {
    local t="$1" missing=""
    case "$t" in
        tar.gz|tar.bz2|tar.xz|tar.zst|tar|tgz)
            command -v tar >/dev/null 2>&1 || missing="tar" ;;
        zip)
            command -v unzip >/dev/null 2>&1 || missing="unzip" ;;
        deb)
            command -v dpkg >/dev/null 2>&1 || missing="dpkg" ;;
        rpm)
            command -v rpm >/dev/null 2>&1 || missing="rpm" ;;
        appimage|binary|script) : ;;
        *)
            log_err "不支持的包类型: ${t}"
            return 4 ;;
    esac
    if [ -n "$missing" ]; then
        log_err "处理 ${t} 需要 ${missing} 命令，但系统中不存在。"
        return 4
    fi
    return 0
}

# ============================================================================
#  第 6 节：安装目录准备
# ============================================================================
# 校验并准备安装基目录；必要时询问创建
prepare_install_base() {
    local base="$1"
    if [ -e "${base}" ]; then
        if [ ! -d "${base}" ]; then
            log_err "路径已存在但不是目录: ${base}"
            return 1
        fi
        if [ ! -w "${base}" ]; then
            log_warn "目录存在但当前用户无写权限: ${base}"
            if [ "${IS_ROOT}" -eq 0 ]; then
                if confirm "是否提权以写入该目录？" "y"; then
                    require_root_for "写入 ${base}"
                    return 2          # 返回 2 表示需要提权
                fi
                return 1
            fi
            return 1
        fi
        return 0
    fi

    # 目录不存在
    log_warn "目录不存在: ${base}"
    if [ "${ASSUME_YES}" -eq 1 ] || confirm "是否创建该目录？" "y"; then
        if [ "${IS_ROOT}" -eq 0 ] && ! mkdir -p "${base}" 2>/dev/null; then
            require_root_for "创建 ${base}"
            return 2
        fi
        if mkdir -p "${base}" 2>/dev/null; then
            log_info "已创建目录: ${base}"
            track dir "${base}"       # 新建的目录纳入回滚（空目录才会被删，非空时 rm -rf 也安全）
            return 0
        fi
        log_err "创建目录失败: ${base}"
        return 1
    fi
    return 1
}

# ============================================================================
#  第 7 节：各类包的安装实现
# ============================================================================

# --- 7.1 归档类（tar 家族 / zip）---
install_archive() {
    local pkg="$1" dest="$2" type="$3"
    local tmp; tmp="$(mktemp -d)"
    TEMP_DIRS+=("${tmp}")

    log_step "解压 ${type} 包到临时目录 ..."
    case "${type}" in
        tar.gz|tgz)    tar -xzf "${pkg}" -C "${tmp}" || { rm -rf "${tmp}"; return 1; } ;;
        tar.bz2|tbz2)  tar -xjf "${pkg}" -C "${tmp}" || { rm -rf "${tmp}"; return 1; } ;;
        tar.xz|txz)    tar -xJf "${pkg}" -C "${tmp}" || { rm -rf "${tmp}"; return 1; } ;;
        tar.zst|tzst)
            if tar --zstd -xf "${pkg}" -C "${tmp}" 2>/dev/null; then :
            elif command -v zstd >/dev/null 2>&1; then
                zstd -dc "${pkg}" | tar -xf - -C "${tmp}" || { rm -rf "${tmp}"; return 1; }
            else
                log_err "解压 tar.zst 需要 tar 支持 --zstd 或安装 zstd"
                rm -rf "${tmp}"; return 1
            fi ;;
        tar)           tar -xf "${pkg}" -C "${tmp}" || { rm -rf "${tmp}"; return 1; } ;;
        zip)           unzip -q "${pkg}" -d "${tmp}" || { rm -rf "${tmp}"; return 1; } ;;
    esac

    # 若压缩包内是单一顶层目录，则提升一层，使 dest 直接是软件根目录
    local entries=() e
    for e in "${tmp}"/* "${tmp}"/.[!.]*; do
        [ -e "${e}" ] && entries+=("${e}")
    done
    if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
        log_dbg "检测到单一顶层目录，提升一层: $(basename "${entries[0]}")"
        mkdir -p "$(dirname "${dest}")" || { rm -rf "${tmp}"; return 1; }
        mv "${entries[0]}" "${dest}" || { rm -rf "${tmp}"; return 1; }
    else
        mkdir -p "$(dirname "${dest}")" || { rm -rf "${tmp}"; return 1; }
        mv "${tmp}" "${dest}" || return 1
    fi
    [ -d "${tmp}" ] && rm -rf "${tmp}" 2>/dev/null
    track dir "${dest}"
    log_info "已解压到: ${dest}"
    return 0
}

# --- 7.2 deb 包 ---
install_deb() {
    local pkg="$1" dest="$2" mode="$3"
    local pkgname
    pkgname="$(dpkg-deb -f "${pkg}" Package 2>/dev/null || basename "${pkg}" .deb)"

    if [ "${mode}" = "extract" ]; then
        log_step "以解包模式安装 deb（仅提取文件，不经包管理器）..."
        mkdir -p "${dest}" || return 1
        dpkg -x "${pkg}" "${dest}" || { log_err "dpkg -x 失败"; return 1; }
        track dir "${dest}"
        # 解包模式下常见结构为 dest/usr/...，可执行文件探测会自动覆盖
        log_info "已解包到: ${dest}"
        return 0
    fi

    log_step "使用 dpkg 安装 deb 包 ..."
    require_root_for "dpkg 安装 ${pkgname}"
    [ "${IS_ROOT}" -eq 1 ] || { log_err "dpkg 安装需要 root"; return 3; }

    if dpkg -i "${pkg}"; then
        INSTALLED_PKG_NAME="${pkgname}"
        track cmd "dpkg -r ${pkgname}"
        log_info "deb 包安装成功: ${pkgname}"
        # 记录实际安装位置，便于后续定位可执行文件
        INSTALL_DIR="${dest}"
        mkdir -p "${dest}" 2>/dev/null
        return 0
    fi

    # 依赖不满足时尝试自动修复
    log_warn "dpkg -i 未成功，尝试修复依赖 ..."
    if command -v apt-get >/dev/null 2>&1 && apt-get -f install -y >/dev/null 2>&1; then
        if dpkg -i "${pkg}"; then
            INSTALLED_PKG_NAME="${pkgname}"
            track cmd "dpkg -r ${pkgname}"
            log_info "依赖修复后安装成功: ${pkgname}"
            INSTALL_DIR="${dest}"
            mkdir -p "${dest}" 2>/dev/null
            return 0
        fi
    fi
    log_err "deb 安装失败，可改用解包模式: -m extract"
    return 1
}

# --- 7.3 rpm 包 ---
install_rpm() {
    local pkg="$1" dest="$2" mode="$3"
    local pkgname
    pkgname="$(rpm -qp --qf '%{NAME}' "${pkg}" 2>/dev/null || basename "${pkg}" .rpm)"

    if [ "${mode}" = "extract" ]; then
        log_step "以解包模式安装 rpm（仅提取文件）..."
        mkdir -p "${dest}" || return 1
        if command -v rpm2cpio >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
            ( cd "${dest}" && rpm2cpio "${pkg}" | cpio -idm ) || { log_err "rpm2cpio 提取失败"; return 1; }
        else
            log_err "解包 rpm 需要 rpm2cpio 与 cpio"
            return 1
        fi
        track dir "${dest}"
        log_info "已解包到: ${dest}"
        return 0
    fi

    log_step "使用 rpm 安装 ..."
    require_root_for "rpm 安装 ${pkgname}"
    [ "${IS_ROOT}" -eq 1 ] || { log_err "rpm 安装需要 root"; return 3; }

    # 优先用 dnf/yum 以便自动解决依赖
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y "${pkg}" && { INSTALLED_PKG_NAME="${pkgname}"; track cmd "rpm -e ${pkgname}"; return 0; }
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${pkg}" && { INSTALLED_PKG_NAME="${pkgname}"; track cmd "rpm -e ${pkgname}"; return 0; }
    fi
    if rpm -ivh "${pkg}"; then
        INSTALLED_PKG_NAME="${pkgname}"
        track cmd "rpm -e ${pkgname}"
        INSTALL_DIR="${dest}"
        mkdir -p "${dest}" 2>/dev/null
        log_info "rpm 包安装成功: ${pkgname}"
        return 0
    fi
    log_err "rpm 安装失败，可改用解包模式: -m extract"
    return 1
}

# --- 7.4 AppImage / 裸二进制 / 安装脚本 ---
install_executable() {
    local pkg="$1" dest="$2" type="$3"
    mkdir -p "${dest}" || return 1
    track dir "${dest}"
    local target="${dest}/$(basename "${pkg}")"

    cp -f "${pkg}" "${target}" || { log_err "复制文件失败"; return 1; }
    chmod 755 "${target}" || { log_err "chmod 失败"; return 1; }
    log_info "已放置: ${target}"
    APP_EXEC="${target}"

    if [ "${type}" = "script" ]; then
        if confirm "这是一个安装脚本，是否立即执行它？" "n"; then
            log_step "执行安装脚本 ..."
            ( cd "${dest}" && bash "${target}" ) || log_warn "安装脚本返回非零退出码"
        fi
    fi
    return 0
}

# ============================================================================
#  第 8 节：可执行文件探测
# ============================================================================
find_executables() {
    local root="$1" depth="${2:-3}"
    [ -d "${root}" ] || return 0
    find "${root}" -maxdepth "${depth}" -type f -perm -u+x \
        ! -name '*.so' ! -name '*.so.*' ! -name '*.py' ! -name '*.sh' \
        ! -name '*.md' ! -name '*.txt' 2>/dev/null | head -20
}

# 交互式选择可执行文件
choose_executable() {
    local root="$1" cands=() c i=1 choice
    [ -n "${APP_EXEC}" ] && { log_info "已指定可执行文件: ${APP_EXEC}"; return 0; }

    mapfile -t cands < <(find_executables "${root}")
    if [ "${#cands[@]}" -eq 0 ]; then
        log_warn "未能自动探测到可执行文件"
        if [ "${ASSUME_YES}" -eq 0 ]; then
            read -r -p "请手动输入可执行文件绝对路径（留空跳过）: " c
            [ -n "$c" ] && APP_EXEC="$c"
        fi
        return 0
    fi

    printf '\n探测到以下候选可执行文件：\n'
    hr
    for c in "${cands[@]}"; do printf '  %2d) %s\n' "$i" "${c}"; i=$((i+1)); done
    printf '   0) 手动输入\n'
    hr

    if [ "${ASSUME_YES}" -eq 1 ]; then
        APP_EXEC="${cands[0]}"
        log_info "非交互模式，自动选择: ${APP_EXEC}"
        return 0
    fi
    read -r -p "选择可执行程序编号 [1]: " choice
    case "${choice:-1}" in
        0) read -r -p "输入可执行文件绝对路径: " c; APP_EXEC="${c}" ;;
        *) if printf '%s' "${choice:-1}" | grep -qE '^[0-9]+$' && [ -n "${cands[$((choice-1))]:-}" ]; then
               APP_EXEC="${cands[$((choice-1))]}"
           else
               APP_EXEC="${cands[0]}"
           fi ;;
    esac
    [ -n "${APP_EXEC}" ] && log_info "选定可执行文件: ${APP_EXEC}"
    return 0
}

# ============================================================================
#  第 9 节：主机环境探测（快捷方式 / 服务注册模式自动判定的唯一依据）
# ============================================================================
#  本节只"采集事实"，不做决策；决策统一在 decide_desktop_scope / decide_service_mode。
#  任何"选哪个模式"的判断都只能读取这里的 ENV_* 变量，杜绝硬编码。
#
#  检测项一览：
#    ENV_IS_ROOT        当前进程是否 root（id -u == 0）
#    ENV_CAN_SUDO       是否具备提权能力（已是 root / 存在 sudo / 存在 pkexec）
#    ENV_SUDO_USER      经 sudo 调用时的原始用户（SUDO_USER）
#    ENV_HAS_GUI        是否存在图形桌面（XDG_CURRENT_DESKTOP / DISPLAY / xsessions）
#    ENV_REMOTE         是否远程 SSH 会话
#    ENV_CONTAINER      是否运行在容器内（/.dockerenv、systemd-detect-virt -c）
#    ENV_SESSIONS       当前活跃会话数（loginctl，回退 who）
#    ENV_HOME_USERS     /home 下的用户家目录数
#    ENV_PID1           1 号进程名
#    ENV_MGRS           本机可用服务管理器列表（按优先级从高到低，空格分隔）
#    ENV_SYSTEMD_USER   systemd --user 是否可用
#    ENV_XDG_RUNTIME    XDG_RUNTIME_DIR 是否就绪（用户级 systemd 依赖）
# ============================================================================

# --- 9.1 服务管理器探测：返回按优先级排序的可用列表 ---
#  系统级优先级：systemd > openrc > upstart > sysv > runit > s6 > supervisord > launchd
#  通用兜底（始终追加在末尾）：cron > rclocal
svc_detect_managers() {
    local m=""
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then m="${m} systemd"; fi
    if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then m="${m} openrc"; fi
    if command -v initctl >/dev/null 2>&1 && [ -d /etc/init ]; then m="${m} upstart"; fi
    if [ -d /etc/init.d ] && { command -v chkconfig >/dev/null 2>&1 \
        || command -v update-rc.d >/dev/null 2>&1 || command -v service >/dev/null 2>&1; }; then
        m="${m} sysv"
    fi
    if command -v sv >/dev/null 2>&1 && { [ -d /etc/sv ] || [ -d /var/service ] || [ -d /etc/service ]; }; then
        m="${m} runit"
    fi
    if command -v s6-svscan >/dev/null 2>&1 || [ -d /etc/s6 ]; then m="${m} s6"; fi
    if command -v supervisorctl >/dev/null 2>&1 || [ -d /etc/supervisor ] || [ -d /etc/supervisord.d ]; then
        m="${m} supervisord"
    fi
    if [ "${ENV_PID1:-}" = "launchd" ] || [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then m="${m} launchd"; fi
    if command -v crontab >/dev/null 2>&1; then m="${m} cron"; fi
    if [ -f /etc/rc.local ] || [ -d /etc/rc.d ]; then m="${m} rclocal"; fi
    printf '%s' "${m# }"
}

# --- 9.2 环境采集 ---
env_probe() {
    # id -u 在极少数环境（损坏的 NSS、精简容器）可能返回空，做兜底
    local uid; uid="$(id -u 2>/dev/null || true)"
    [ -z "${uid}" ] && uid=1000
    ENV_IS_ROOT=0; [ "${uid}" -eq 0 ] && ENV_IS_ROOT=1
    ENV_SUDO_USER="${SUDO_USER:-}"

    ENV_CAN_SUDO=0
    if [ "${ENV_IS_ROOT}" -eq 1 ]; then
        ENV_CAN_SUDO=1
    else
        command -v sudo   >/dev/null 2>&1 && ENV_CAN_SUDO=1
        command -v pkexec >/dev/null 2>&1 && ENV_CAN_SUDO=1
    fi

    ENV_HAS_GUI=0
    if [ -n "${XDG_CURRENT_DESKTOP:-}" ] || [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ] \
       || [ -d /usr/share/xsessions ] || [ -d /usr/share/wayland-sessions ]; then
        ENV_HAS_GUI=1
    fi

    ENV_REMOTE=0
    if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ] || [ -n "${SSH_CLIENT:-}" ]; then
        ENV_REMOTE=1
    fi

    ENV_CONTAINER=0
    if [ -f /.dockerenv ] || [ -f /run/.containerenv ] || [ -f /run/container_type ]; then
        ENV_CONTAINER=1
    elif command -v systemd-detect-virt >/dev/null 2>&1; then
        local vt; vt="$(systemd-detect-virt --container 2>/dev/null || true)"
        if [ -n "${vt}" ] && [ "${vt}" != "none" ]; then ENV_CONTAINER=1; fi
    fi

    ENV_SESSIONS=0
    if command -v loginctl >/dev/null 2>&1; then
        ENV_SESSIONS="$(loginctl list-sessions --no-legend 2>/dev/null | grep -c '[A-Za-z0-9]' || true)"
    fi
    if [ -z "${ENV_SESSIONS}" ] || [ "${ENV_SESSIONS}" = "0" ]; then
        ENV_SESSIONS="$(who 2>/dev/null | grep -c '[A-Za-z0-9]' || true)"
    fi
    [ -z "${ENV_SESSIONS}" ] && ENV_SESSIONS=0

    ENV_HOME_USERS=0
    if [ -d /home ]; then
        ENV_HOME_USERS="$(find /home -maxdepth 1 -mindepth 1 -type d 2>/dev/null | grep -c . || true)"
    fi
    [ -z "${ENV_HOME_USERS}" ] && ENV_HOME_USERS=0

    ENV_PID1="$(cat /proc/1/comm 2>/dev/null || true)"
    [ -z "${ENV_PID1}" ] && ENV_PID1="$(ps -p 1 -o comm= 2>/dev/null || echo unknown)"

    ENV_XDG_RUNTIME=0
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR}" ]; then ENV_XDG_RUNTIME=1; fi

    ENV_MGRS="$(svc_detect_managers)"

    # systemd --user：需要 systemctl，且 root 下可 runuser 切换、普通用户下需 XDG_RUNTIME_DIR
    ENV_SYSTEMD_USER=0
    if command -v systemctl >/dev/null 2>&1; then
        if [ "${ENV_IS_ROOT}" -eq 1 ] || [ "${ENV_XDG_RUNTIME}" -eq 1 ]; then ENV_SYSTEMD_USER=1; fi
    fi

    IS_ROOT="${ENV_IS_ROOT}"
    log_dbg "环境: root=${ENV_IS_ROOT} sudo=${ENV_CAN_SUDO}(${ENV_SUDO_USER:-无}) gui=${ENV_HAS_GUI} "\
"remote=${ENV_REMOTE} container=${ENV_CONTAINER} sessions=${ENV_SESSIONS} homeusers=${ENV_HOME_USERS} "\
"pid1=${ENV_PID1} mgrs=[${ENV_MGRS}] systemd_user=${ENV_SYSTEMD_USER}"
    return 0
}

# --- 9.3 判定报告：--explain 时输出，也用于决策留痕 ---
print_env_report() {
    printf '\n'
    printf "${C_C}=========== 主机环境探测结果 ===========${C_N}\n"
    printf '  %-26s %s\n' "进程权限 (id -u)"        "$([ "${ENV_IS_ROOT}" -eq 1 ] && echo "root" || echo "普通用户 uid=$(id -u)")"
    printf '  %-26s %s\n' "提权能力"                "$([ "${ENV_CAN_SUDO}" -eq 1 ] && echo "可用" || echo "不可用")${ENV_SUDO_USER:+ (SUDO_USER=${ENV_SUDO_USER})}"
    printf '  %-26s %s\n' "图形桌面"                "$([ "${ENV_HAS_GUI}" -eq 1 ] && echo "有" || echo "无")"
    printf '  %-26s %s\n' "远程 SSH 会话"           "$([ "${ENV_REMOTE}" -eq 1 ] && echo "是" || echo "否")"
    printf '  %-26s %s\n' "容器环境"                "$([ "${ENV_CONTAINER}" -eq 1 ] && echo "是" || echo "否")"
    printf '  %-26s %s\n' "活跃会话数 / 家目录数"   "${ENV_SESSIONS} / ${ENV_HOME_USERS}"
    printf '  %-26s %s\n' "1 号进程"                "${ENV_PID1}"
    printf '  %-26s %s\n' "可用服务管理器"          "${ENV_MGRS:-无}"
    printf '  %-26s %s\n' "systemd --user 可用"     "$([ "${ENV_SYSTEMD_USER}" -eq 1 ] && echo "是" || echo "否")"
    printf '  %-26s %s\n' "安装基目录"              "${INSTALL_BASE:-/opt}"
    printf '\n'
    printf '%s\n' "${C_C}----------- 快捷方式范围判定 -----------${C_N}"
    printf '  结果: %s\n  依据: %s\n' "${DESKTOP_SCOPE_DECIDED:-未判定}" "${DESKTOP_SCOPE_REASON:-—}"
    printf '\n'
    printf '%s\n' "${C_C}----------- 服务注册模式判定 -----------${C_N}"
    printf '  结果: 管理器=%s  作用域=%s\n' "${SVC_MANAGER_DECIDED:-未判定}" "${SVC_SCOPE_DECIDED:-未判定}"
    printf '  依据: %s\n' "${SVC_MANAGER_REASON:-—}"
    printf '=======================================\n'
}

# ============================================================================
#  第 10 节：桌面快捷方式（三种范围统一入口）
# ============================================================================
#  范围模式：
#    all      所有用户   —— 系统级应用目录（默认 /usr/share/applications）；
#                           并在公共桌面目录（默认 /etc/skel/Desktop，可被
#                           PUBLIC_DESKTOP_DIR 覆盖）同步一份，使新建用户自动继承；
#                           加 --desktop-sync-existing 时再同步到已存在用户的桌面
#    current  当前用户   —— XDG_DATA_HOME（默认 ~/.local/share/applications）
#    user     指定用户   —— 由用户名 / UID / SID 定位家目录，写入
#                           ~/.local/share/applications 并 chown 为该用户所有
#
#  回退策略（--desktop-fallback）：
#    auto   默认。按 all -> current、user -> current 逐级降级，每级给出明确告警
#    strict 任何失败立即返回错误码，不降级
#    skip   失败时跳过创建（不计为安装失败）
# ============================================================================

readonly DESKTOP_MARK="# MANAGED-BY: install_pkg.sh"

# --- 10.1 用户解析：用户名 / UID / SID ---
# 取 /etc/passwd（或 NSS）中该用户的记录行
user_pw_entry() {
    local u="$1" line=""
    command -v getent >/dev/null 2>&1 && line="$(getent passwd "${u}" 2>/dev/null || true)"
    if [ -z "${line}" ]; then
        line="$(awk -F: -v u="${u}" '$1==u || $3==u {print; exit}' /etc/passwd 2>/dev/null || true)"
    fi
    printf '%s' "${line}"
}

# 解析用户引用，结果写入 RU_NAME / RU_UID / RU_GID / RU_HOME，失败写入 RU_ERR
# 返回: 0 成功  2 目标不存在/无法解析
resolve_user_ref() {
    local ref="$1"
    RU_NAME=""; RU_UID=""; RU_GID=""; RU_HOME=""; RU_ERR=""

    if [ -z "${ref}" ]; then RU_ERR="未指定目标用户"; return 2; fi

    # SID（S-1-...）：Linux 内核无 SID 概念，必须借助 winbind/sssd 提供的映射
    if printf '%s' "${ref}" | grep -qiE '^S-1-[0-9-]+$'; then
        local mapped=""
        if command -v wbinfo >/dev/null 2>&1; then
            mapped="$(wbinfo --sid-to-uid "${ref}" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || true)"
            if [ -z "${mapped}" ]; then
                local nm
                nm="$(wbinfo -s "${ref}" 2>/dev/null | awk '{print $1}' | sed 's#^.*[\\/]##' || true)"
                [ -n "${nm}" ] && mapped="$(id -u "${nm}" 2>/dev/null || true)"
            fi
        fi
        if [ -z "${mapped}" ] && command -v sssctl >/dev/null 2>&1; then
            mapped="$(sssctl user-checks "${ref}" 2>/dev/null | grep -oE 'uid: [0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
        fi
        if [ -z "${mapped}" ]; then
            RU_ERR="无法解析 SID ${ref}：本机缺少 SID→UID 映射能力（需 winbind 的 wbinfo 或 sssd）"\
"，请改用用户名或 UID"
            return 2
        fi
        ref="${mapped}"
    fi

    local line name uid gid home
    line="$(user_pw_entry "${ref}")"
    if [ -z "${line}" ]; then
        # passwd / NSS 查不到，但 id 能识别时（域账号、容器映射用户、非标准环境）
        # 用 id 取 uid/gid，用 ~name 取家目录
        if printf '%s' "${ref}" | grep -qE '^[A-Za-z0-9._-]+$' && id -u "${ref}" >/dev/null 2>&1; then
            name="$(id -un "${ref}" 2>/dev/null || echo "${ref}")"
            uid="$(id -u "${ref}" 2>/dev/null || true)"
            gid="$(id -g "${ref}" 2>/dev/null || echo "${uid}")"
            home="$(eval "echo ~${name}" 2>/dev/null || true)"
            case "${home}" in "~${name}"|"~"|"") home="" ;; esac
            if [ -n "${uid}" ] && [ -n "${home}" ] && [ -d "${home}" ]; then
                RU_NAME="${name}"; RU_UID="${uid}"; RU_GID="${gid}"; RU_HOME="${home}"
                return 0
            fi
        fi
        RU_ERR="目标用户不存在: ${ref}（本地 passwd 与 NSS 中均未找到）"
        return 2
    fi
    name="$(printf '%s' "${line}" | cut -d: -f1)"
    uid="$(printf '%s'  "${line}" | cut -d: -f3)"
    gid="$(printf '%s'  "${line}" | cut -d: -f4)"
    home="$(printf '%s' "${line}" | cut -d: -f6)"

    if [ -z "${home}" ] || [ ! -d "${home}" ]; then
        RU_ERR="用户 ${name} 的家目录不存在或不可访问: ${home:-<空>}"
        return 2
    fi
    RU_NAME="${name}"; RU_UID="${uid}"; RU_GID="${gid}"; RU_HOME="${home}"
    return 0
}

# 定位用户的"桌面"目录（兼容中文桌面的 桌面、Desktop）
find_user_desktop_dir() {
    local h="$1" d=""
    if [ -r "${h}/.config/user-dirs.dirs" ]; then
        d="$(sed -n 's/^[[:space:]]*XDG_DESKTOP_DIR="\${HOME}\/\(.*\)"[[:space:]]*$/\1/p' \
             "${h}/.config/user-dirs.dirs" 2>/dev/null | head -1)"
        [ -n "${d}" ] && d="${h}/${d}"
    fi
    if [ -z "${d}" ] || [ ! -d "${d}" ]; then
        d=""
        for c in Desktop 桌面 desktop; do
            if [ -d "${h}/${c}" ]; then d="${h}/${c}"; break; fi
        done
    fi
    if [ -n "${d}" ] && [ -d "${d}" ]; then printf '%s' "${d}"; return 0; fi
    return 1
}

# 目录是否可写；不存在时逐级向上找最近的存在目录判断
# （.local/share/applications 这类多级不存在的路径不能只查一级父目录）
can_write_dir() {
    local d="$1" p guard=0
    while [ -n "${d}" ] && [ "${d}" != "/" ] && [ "${d}" != "." ] && [ ${guard} -lt 32 ]; do
        if [ -d "${d}" ]; then
            if [ -w "${d}" ]; then return 0; else return 1; fi
        fi
        p="$(dirname "${d}")"
        [ "${p}" = "${d}" ] && break
        d="${p}"; guard=$((guard+1))
    done
    return 1
}

# --- 10.2 范围自动判定（读 ENV_*，不硬编码） ---
#  优先级（自上而下，命中即止）：
#    R0 命令行显式 --desktop-scope
#    R1 已指定 --desktop-user（隐含 user 模式）
#    R2 容器环境 且 无图形会话            -> current
#    R3 安装基目录位于当前用户家目录内     -> current（个人级安装只给个人）
#    R4 多用户环境（会话>1 或 家目录>1）
#         且具备系统目录写入能力           -> all
#    R5 具备系统级写权限 且 安装到系统目录 -> all
#    R6 root 且由 sudo 发起                -> user:$SUDO_USER
#    R7 兜底                               -> current
decide_desktop_scope() {
    # 自愈：若尚未执行过环境探测（如单独调用本函数），先探测一次
    [ -z "${ENV_PID1}" ] && env_probe
    DESKTOP_SCOPE_DECIDED=""; DESKTOP_SCOPE_REASON=""

    if [ -n "${DESKTOP_SCOPE}" ] && [ "${DESKTOP_SCOPE}" != "auto" ]; then
        DESKTOP_SCOPE_DECIDED="${DESKTOP_SCOPE}"
        DESKTOP_SCOPE_REASON="命令行显式指定"
        return 0
    fi
    if [ -n "${DESKTOP_TARGET_USER}" ]; then
        DESKTOP_SCOPE_DECIDED="user"
        DESKTOP_SCOPE_REASON="已指定目标用户 ${DESKTOP_TARGET_USER}"
        return 0
    fi
    if [ "${ENV_CONTAINER}" -eq 1 ] && [ "${ENV_HAS_GUI}" -eq 0 ]; then
        DESKTOP_SCOPE_DECIDED="current"
        DESKTOP_SCOPE_REASON="容器环境且无图形会话，按单用户处理"
        return 0
    fi
    local home="${HOME:-/root}"
    case "${INSTALL_BASE:-/opt}" in
        "${home}"|"${home}"/*)
            DESKTOP_SCOPE_DECIDED="current"
            DESKTOP_SCOPE_REASON="安装目录 ${INSTALL_BASE} 位于当前用户家目录内，属个人级安装"
            return 0 ;;
    esac
    if [ "${ENV_HOME_USERS}" -gt 1 ] || [ "${ENV_SESSIONS}" -gt 1 ]; then
        if [ "${ENV_IS_ROOT}" -eq 1 ] || [ "${ENV_CAN_SUDO}" -eq 1 ]; then
            DESKTOP_SCOPE_DECIDED="all"
            DESKTOP_SCOPE_REASON="多用户环境（家目录 ${ENV_HOME_USERS} 个 / 活跃会话 ${ENV_SESSIONS} 个）且具备系统目录写入能力"
        else
            DESKTOP_SCOPE_DECIDED="current"
            DESKTOP_SCOPE_REASON="多用户环境但无提权能力，降级为仅当前用户可见"
        fi
        return 0
    fi
    if [ "${ENV_IS_ROOT}" -eq 1 ] || [ "${ENV_CAN_SUDO}" -eq 1 ]; then
        case "${INSTALL_BASE:-/opt}" in
            /opt|/opt/*|/usr|/usr/*|/srv|/srv/*|/usr/local|/usr/local/*)
                DESKTOP_SCOPE_DECIDED="all"
                DESKTOP_SCOPE_REASON="具备系统级写权限且安装到系统目录 ${INSTALL_BASE}"
                return 0 ;;
        esac
        if [ "${ENV_IS_ROOT}" -eq 1 ] && [ -n "${ENV_SUDO_USER}" ]; then
            DESKTOP_SCOPE_DECIDED="user"
            DESKTOP_TARGET_USER="${ENV_SUDO_USER}"
            DESKTOP_SCOPE_REASON="root 由 sudo 用户 ${ENV_SUDO_USER} 发起，快捷方式归属该用户"
            return 0
        fi
        DESKTOP_SCOPE_DECIDED="all"
        DESKTOP_SCOPE_REASON="具备系统级写权限，默认对所有用户可见"
        return 0
    fi
    DESKTOP_SCOPE_DECIDED="current"
    DESKTOP_SCOPE_REASON="非 root 且无提权能力，仅当前用户可见"
    return 0
}

# --- 10.3 生成 .desktop 内容并写入指定目录 ---
# 用法: desktop_write <目录> [所有者 uid:gid]
# 返回: 0 成功  1 写入失败  3 权限不足
desktop_write() {
    local dir="$1" owner="${2:-}"
    local file="${dir}/${DESKTOP_BASENAME}.desktop" tmp="${dir}/.${DESKTOP_BASENAME}.desktop.$$"

    if ! can_write_dir "${dir}"; then
        log_err "目录不可写: ${dir}（当前 uid=$(id -u)）"
        return 3
    fi
    mkdir -p "${dir}" 2>/dev/null || { log_err "创建目录失败: ${dir}"; return 1; }

    cat > "${tmp}" <<EOF
${DESKTOP_MARK}
[Desktop Entry]
Version=1.0
Type=Application
Name=${DESKTOP_NAME}
Comment=${APP_DESC:-${DESKTOP_NAME}}
Exec=${APP_EXEC}
Icon=${DESKTOP_ICON_REAL}
Terminal=${DESKTOP_TERMINAL}
Categories=${DESKTOP_CATEGORY};
StartupNotify=true
EOF
    if [ $? -ne 0 ]; then rm -f "${tmp}" 2>/dev/null; log_err "写入失败: ${dir}"; return 1; fi

    chmod 644 "${tmp}" 2>/dev/null
    if [ -n "${owner}" ]; then chown "${owner}" "${tmp}" 2>/dev/null; fi
    if ! mv -f "${tmp}" "${file}" 2>/dev/null; then
        rm -f "${tmp}" 2>/dev/null; log_err "落盘失败: ${file}"; return 1
    fi
    DESKTOP_FILES_CREATED+=("${file}")
    track file "${file}"
    log_info "已写入: ${file}"
    return 0
}

# --- 10.4 单个范围的执行体 ---
# 返回: 0 成功  2 目标用户/参数无效  3 权限不足  1 其他失败
shortcut_try_scope() {
    local scope="$1"
    local dir="" owner="" home="" extra_dir="" rc=0

    case "${scope}" in
        all)
            dir="${DESKTOP_SYSTEM_DIR:-/usr/share/applications}"
            ;;
        current)
            home="${HOME:-/root}"
            dir="${DESKTOP_USER_DIR:-${XDG_DATA_HOME:-${home}/.local}/share/applications}"
            ;;
        user)
            if ! resolve_user_ref "${DESKTOP_TARGET_USER}"; then
                DESKTOP_LAST_ERR="${RU_ERR}"; return 2
            fi
            home="${RU_HOME}"; owner="${RU_UID}:${RU_GID}"
            dir="${home}/.local/share/applications"
            ;;
        *)
            DESKTOP_LAST_ERR="未知范围: ${scope}"; return 2 ;;
    esac

    log_step "写入快捷方式 [范围=${scope}] -> ${dir}"
    # 注意：不能写成 `if ! desktop_write ...; then rc=$?`
    # —— 取反后 $? 会变成 0，失败会被误判成成功
    desktop_write "${dir}" "${owner}"
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        DESKTOP_LAST_ERR="写入 ${dir} 失败（退出码 ${rc}）"
        return "${rc}"
    fi

    # 桌面图标目录：存在才放，避免在没有桌面目录的服务器上报噪音
    case "${scope}" in
        all)
            extra_dir="${PUBLIC_DESKTOP_DIR:-/etc/skel/Desktop}"
            if can_write_dir "${extra_dir}"; then
                desktop_write "${extra_dir}" "" || log_warn "公共桌面目录写入失败: ${extra_dir}"
            else
                log_dbg "公共桌面目录不可用，跳过: ${extra_dir}"
            fi
            # 可选：同步到已存在用户的桌面
            if [ "${DESKTOP_SYNC_EXISTING}" -eq 1 ] && [ -d /home ]; then
                local hd ud
                for hd in /home/*; do
                    [ -d "${hd}" ] || continue
                    ud="$(find_user_desktop_dir "${hd}" || true)"
                    [ -z "${ud}" ] && continue
                    local du; du="$(stat -c '%u:%g' "${hd}" 2>/dev/null || echo '')"
                    desktop_write "${ud}" "${du}" || log_warn "同步到 ${ud} 失败"
                done
            fi
            ;;
        current|user)
            if [ -n "${home}" ]; then
                extra_dir="$(find_user_desktop_dir "${home}" || true)"
                if [ -n "${extra_dir}" ]; then
                    desktop_write "${extra_dir}" "${owner}" || log_warn "桌面目录写入失败: ${extra_dir}"
                fi
            fi
            ;;
    esac

    # 刷新桌面数据库（失败不影响主流程）
    command -v update-desktop-database >/dev/null 2>&1 && \
        update-desktop-database "${dir}" >/dev/null 2>&1
    return 0
}

# --- 10.5 统一入口 ---
# 返回: 0 成功  1 失败（strict/auto 全链路失败）  2 参数无效
shortcut_create() {
    DESKTOP_FILES_CREATED=()
    DESKTOP_LAST_ERR=""
    DESKTOP_SCOPE_APPLIED=""

    # 参数校验
    if [ -z "${APP_EXEC}" ] || [ ! -f "${APP_EXEC}" ]; then
        log_err "无有效可执行文件（APP_EXEC=${APP_EXEC:-空}），无法创建快捷方式"
        return 2
    fi
    [ -n "${DESKTOP_NAME}" ] || DESKTOP_NAME="${APP_NAME}"
    DESKTOP_BASENAME="$(printf '%s' "${DESKTOP_NAME}" | tr ' ' '-' | tr -cd 'A-Za-z0-9._-')"
    if [ -z "${DESKTOP_BASENAME}" ]; then
        log_err "快捷方式名称非法（规范化后为空）: ${DESKTOP_NAME}"
        return 2
    fi

    # 图标：未指定则自动查找
    if [ -n "${DESKTOP_ICON}" ]; then
        DESKTOP_ICON_REAL="${DESKTOP_ICON}"
    else
        DESKTOP_ICON_REAL="$(find "${INSTALL_DIR}" -maxdepth 3 -type f \
            \( -name '*.png' -o -name '*.svg' -o -name '*.xpm' \) 2>/dev/null | head -1)"
        [ -z "${DESKTOP_ICON_REAL}" ] && DESKTOP_ICON_REAL="${DESKTOP_BASENAME}"
    fi
    log_dbg "图标: ${DESKTOP_ICON_REAL}"

    # 范围判定
    decide_desktop_scope
    local scope="${DESKTOP_SCOPE_DECIDED}"
    log_info "快捷方式范围: ${scope}   依据: ${DESKTOP_SCOPE_REASON}"

    # 候选链
    local chain
    case "${scope}" in
        all)     chain="all current" ;;
        user)    chain="user current" ;;
        current) chain="current" ;;
        *)       log_err "无效的范围: ${scope}"; return 2 ;;
    esac
    [ "${DESKTOP_FALLBACK}" = "strict" ] && chain="${scope}"

    local s rc=0
    for s in ${chain}; do
        rc=0
        shortcut_try_scope "${s}" || rc=$?
        if [ "${rc}" -eq 0 ]; then
            DESKTOP_SCOPE_APPLIED="${s}"
            [ "${s}" != "${scope}" ] && log_warn "已回退到范围 ${s}（原计划 ${scope}）"
            return 0
        fi
        # 明确报错后再决定是否继续降级
        case "${rc}" in
            2) log_err "范围 ${s} 目标无效: ${DESKTOP_LAST_ERR}" ;;
            3) log_err "范围 ${s} 权限不足: ${DESKTOP_LAST_ERR}" ;;
            *) log_err "范围 ${s} 写入失败: ${DESKTOP_LAST_ERR:-未知原因}" ;;
        esac
    done

    if [ "${DESKTOP_FALLBACK}" = "skip" ]; then
        log_warn "所有候选范围均失败，按 skip 策略跳过快捷方式创建"
        return 0
    fi
    log_err "快捷方式创建失败（已尝试: ${chain}）"
    return 1
}

# 兼容旧调用名
create_desktop_entry() { shortcut_create "$@"; }

# ============================================================================
#  第 11 节：服务注册（多管理器 + 多作用域）
# ============================================================================
#  支持的服务类型：
#    systemd        /etc/systemd/system/<n>.service            systemctl
#    systemd(user)  ~/.config/systemd/user/<n>.service         systemctl --user
#    upstart        /etc/init/<n>.conf                         initctl / service
#    sysv           /etc/init.d/<n>                            chkconfig | update-rc.d
#    openrc         /etc/init.d/<n> (openrc-run)               rc-update / rc-service
#    runit          /etc/sv/<n>/run                            sv
#    s6             /etc/s6/sv/<n>/run                         s6-svc
#    supervisord    /etc/supervisor/conf.d/<n>.conf            supervisorctl
#    launchd        /Library/LaunchDaemons|LaunchAgents        launchctl
#    cron           /etc/cron.d/<n> 或 用户 crontab @reboot    crontab
#    rclocal        /etc/rc.local                              —
#
#  作用域（--service-scope）：
#    system  系统级，需 root，随主机启动
#    user    用户级，随该用户会话启动（systemd --user / LaunchAgents / 用户 crontab）
#
#  模式自动判定见 decide_service_mode()，同样只依赖 ENV_*。
# ============================================================================

readonly SVC_MARK="# MANAGED-BY: install_pkg.sh"
SVC_SERVICE_PATH=""
SVC_ENABLE_CMD=""; SVC_START_CMD=""; SVC_STOP_CMD=""
SVC_STATUS_CMD=""; SVC_LOG_CMD=""; SVC_UNINSTALL_CMD=""

# --- 11.1 登记生成结果（供摘要、回滚、启停复用） ---
svc_record() {
    SVC_SERVICE_PATH="$1"; SVC_ENABLE_CMD="$2"; SVC_START_CMD="$3"
    SVC_STOP_CMD="$4"; SVC_STATUS_CMD="$5"; SVC_LOG_CMD="$6"
    SVC_FILES_CREATED+=("$1")
    track file "$1"
    log_info "服务定义已生成: $1"
    return 0
}

# 以目标用户身份执行用户级命令的前缀（root 时用 runuser）
svc_as_user_prefix() {
    if [ "${IS_ROOT}" -eq 1 ] && [ -n "${RU_NAME:-}" ]; then
        printf 'runuser -u %s -- env XDG_RUNTIME_DIR=/run/user/%s DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%s/bus ' \
            "${RU_NAME}" "${RU_UID}" "${RU_UID}"
    fi
}

# --- 11.2 冲突检测：已存在 / 被 mask / 非本工具创建 ---
# 返回: 0 可写  5 冲突且未授权覆盖
svc_check_conflict() {
    local path="$1" mgr="$2"
    if [ ! -e "${path}" ]; then return 0; fi

    if grep -q "${SVC_MARK}" "${path}" 2>/dev/null; then
        log_info "已存在本工具创建的服务定义，将覆盖更新: ${path}"
        return 0
    fi

    log_err "服务定义已存在且非本工具创建: ${path}"
    log_err "  原因: 覆盖他人/其他包管理器创建的服务定义可能导致系统行为异常"
    if [ "${SVC_FORCE}" -eq 1 ]; then
        local bak="${path}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "${path}" "${bak}" 2>/dev/null && log_warn "已备份原文件为 ${bak} 并覆盖"
        return 0
    fi
    log_err "  如确认要覆盖，请加 --service-force 参数"
    return 5
}

# systemd 被 mask 时给出可执行的修复建议
svc_check_masked() {
    [ "${SVC_MANAGER_APPLY}" = "systemd" ] || return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    local st
    st="$(systemctl is-enabled "${SVC_NAME}" 2>/dev/null || true)"
    if [ "${st}" = "masked" ]; then
        log_err "服务 ${SVC_NAME} 已被 mask，无法启用/启动"
        log_err "  修复: systemctl unmask ${SVC_NAME}"
        return 5
    fi
    return 0
}

# --- 11.3 各管理器生成器 ---
# 统一约定：设置 SVC_TARGET_DIR / SVC_TARGET_FILE 后调用 svc_record

svc_gen_systemd() {
    local scope="${SVC_SCOPE_APPLY}"
    local dir file
    if [ "${scope}" = "user" ]; then
        # 用户级：~/.config/systemd/user（root 代劳时用 runuser 切换）
        dir="${SYSTEMD_USER_UNIT_DIR:-${RU_HOME:-${HOME:-/root}}/.config/systemd/user}"
    else
        dir="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
    fi
    file="${dir}/${SVC_NAME}.service"

    svc_check_conflict "${file}" systemd || return $?

    if ! can_write_dir "${dir}"; then
        log_err "无写权限: ${dir}"
        return 3
    fi
    mkdir -p "${dir}" || { log_err "创建目录失败: ${dir}"; return 1; }

    # 用户级不能指定 User=，也不存在 network.target
    local user_line="" wanted="multi-user.target" after="${SVC_AFTER}"
    if [ "${scope}" = "user" ]; then
        wanted="default.target"; after="default.target"
        user_line="# 用户级服务的运行身份由 systemd --user 自身决定，不写 User="
    else
        user_line="User=${SVC_USER}"
    fi

    log_step "生成 systemd unit: ${file}"
    cat > "${file}" <<EOF
${SVC_MARK}
[Unit]
Description=${SVC_DESC:-${APP_NAME}}
After=${after}
StartLimitIntervalSec=0

[Service]
Type=${SVC_TYPE}
${user_line}
WorkingDirectory=${SVC_WORKDIR}
ExecStart=${SVC_CMD}
Restart=${SVC_RESTART}
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=${wanted}
EOF
    if [ $? -ne 0 ]; then log_err "写入 unit 失败: ${file}"; return 1; fi
    chmod 644 "${file}"
    if [ "${scope}" = "user" ] && [ -n "${RU_UID:-}" ]; then
        chown "${RU_UID}:${RU_GID}" "${file}" 2>/dev/null
    fi

    # 组装管理命令：system 用 systemctl，user 用 systemctl --user（root 时前置 runuser）
    local ctl="systemctl" jctl="journalctl -u ${SVC_NAME} -f"
    if [ "${scope}" = "user" ]; then
        ctl="$(svc_as_user_prefix)systemctl --user"
        jctl="$(svc_as_user_prefix)journalctl --user -u ${SVC_NAME} -f"
    fi
    local en_cmd="${ctl} enable ${SVC_NAME}"
    [ "${scope}" != "user" ] && en_cmd="${ctl} daemon-reload && ${ctl} enable ${SVC_NAME}"

    svc_record "${file}" "${en_cmd}" "${ctl} start ${SVC_NAME}" "${ctl} stop ${SVC_NAME}" \
        "${ctl} status ${SVC_NAME}" "${jctl}"
    return 0
}

svc_gen_upstart() {
    local dir="${UPSTART_DIR:-/etc/init}"
    local file="${dir}/${SVC_NAME}.conf"
    svc_check_conflict "${file}" upstart || return $?
    if ! can_write_dir "${dir}"; then log_err "无写权限: ${dir}"; return 3; fi
    mkdir -p "${dir}" || return 1

    local respawn="respawn"
    case "${SVC_RESTART}" in no) respawn="" ;; *) respawn="respawn\nrespawn limit 10 5" ;; esac

    log_step "生成 upstart 配置: ${file}"
    cat > "${file}" <<EOF
${SVC_MARK}
description "${SVC_DESC:-${APP_NAME}}"
author "install_pkg.sh"

start on runlevel [2345]
stop on runlevel [016]
$(printf "${respawn}")

setuid ${SVC_USER}
chdir ${SVC_WORKDIR}

exec ${SVC_CMD}
EOF
    [ $? -ne 0 ] && { log_err "写入 upstart 配置失败"; return 1; }
    chmod 644 "${file}"
    svc_record "${file}" \
        "initctl reload-configuration" \
        "service ${SVC_NAME} start" "service ${SVC_NAME} stop" \
        "service ${SVC_NAME} status" "tail -f /var/log/upstart/${SVC_NAME}.log"
    return 0
}

svc_gen_sysv() {
    local dir="${SYSV_INIT_DIR:-/etc/init.d}"
    local init="${dir}/${SVC_NAME}"
    svc_check_conflict "${init}" sysv || return $?
    if ! can_write_dir "${dir}"; then log_err "无写权限: ${dir}"; return 3; fi
    mkdir -p "${dir}" || return 1

    local tool="none"
    command -v chkconfig   >/dev/null 2>&1 && tool="chkconfig"
    command -v update-rc.d >/dev/null 2>&1 && tool="update-rc.d"
    [ "${tool}" = "none" ] && log_warn "未找到 chkconfig / update-rc.d，仅创建脚本，不设置开机自启"

    log_step "生成 SysV init 脚本: ${init}"
    cat > "${init}" <<EOF
#!/bin/bash
${SVC_MARK}
### BEGIN INIT INFO
# Provides:          ${SVC_NAME}
# Required-Start:    \$local_fs \$network \$named \$time
# Required-Stop:     \$local_fs \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ${SVC_DESC:-${APP_NAME}}
# Description:       ${SVC_DESC:-${APP_NAME}}
### END INIT INFO

NAME="${SVC_NAME}"
DESC="${SVC_DESC:-${APP_NAME}}"
USER="${SVC_USER}"
WORKDIR="${SVC_WORKDIR}"
CMD="${SVC_CMD}"
PIDFILE="/var/run/\${NAME}.pid"
LOGFILE="/var/log/\${NAME}.log"

start() {
    [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null && { echo "\$NAME 已在运行"; return 0; }
    echo "启动 \$DESC ..."
    cd "\$WORKDIR" || exit 1
    if [ "\$USER" = "root" ] || [ -z "\$USER" ]; then
        nohup \$CMD >> "\$LOGFILE" 2>&1 &
    else
        nohup su - "\$USER" -c "cd \$WORKDIR && \$CMD" >> "\$LOGFILE" 2>&1 &
    fi
    echo \$! > "\$PIDFILE"
    echo "已启动，PID=\$(cat \$PIDFILE)"
}

stop() {
    [ ! -f "\$PIDFILE" ] && { echo "\$NAME 未运行"; return 0; }
    echo "停止 \$DESC ..."
    kill "\$(cat "\$PIDFILE")" 2>/dev/null
    rm -f "\$PIDFILE"
}

status() {
    [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null \\
        && { echo "\$NAME 运行中 (PID=\$(cat \$PIDFILE))"; return 0; }
    echo "\$NAME 未运行"; return 3
}

case "\$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    *) echo "用法: \$0 {start|stop|restart|status}"; exit 2 ;;
esac
# 保留子命令自身退出码：status 未运行需返回 3（LSB 规范）
exit \$?
EOF
    [ $? -ne 0 ] && { log_err "写入 init 脚本失败"; return 1; }
    chmod 755 "${init}"

    local en_cmd=":"
    case "${tool}" in
        chkconfig)   en_cmd="chkconfig --add ${SVC_NAME} && chkconfig ${SVC_NAME} on" ;;
        update-rc.d) en_cmd="update-rc.d ${SVC_NAME} defaults" ;;
    esac
    svc_record "${init}" "${en_cmd}" "${init} start" "${init} stop" "${init} status" \
        "tail -f /var/log/${SVC_NAME}.log"
    return 0
}

svc_gen_openrc() {
    local dir="${SYSV_INIT_DIR:-/etc/init.d}"
    local init="${dir}/${SVC_NAME}"
    svc_check_conflict "${init}" openrc || return $?
    if ! can_write_dir "${dir}"; then log_err "无写权限: ${dir}"; return 3; fi
    mkdir -p "${dir}" || return 1

    log_step "生成 OpenRC 服务脚本: ${init}"
    cat > "${init}" <<EOF
#!/sbin/openrc-run
${SVC_MARK}
description="${SVC_DESC:-${APP_NAME}}"
command="${SVC_CMD%% *}"
command_args="${SVC_CMD#* }"
command_user="${SVC_USER}"
directory="${SVC_WORKDIR}"
pidfile="/run/\${RC_SVCNAME}.pid"
command_background=true
output_log="/var/log/${SVC_NAME}.log"
error_log="/var/log/${SVC_NAME}.err"

depend() {
    need net
    use logger dns
}

start_pre() {
    checkpath --file --mode 0644 "\$output_log" "\$error_log"
}
EOF
    [ $? -ne 0 ] && { log_err "写入 OpenRC 脚本失败"; return 1; }
    chmod 755 "${init}"
    svc_record "${init}" "rc-update add ${SVC_NAME} default" \
        "rc-service ${SVC_NAME} start" "rc-service ${SVC_NAME} stop" \
        "rc-service ${SVC_NAME} status" "tail -f /var/log/${SVC_NAME}.log"
    return 0
}

svc_gen_runit() {
    local dir="${RUNIT_SVC_DIR:-/etc/sv}/${SVC_NAME}"
    local scan="${RUNIT_SCAN_DIR:-}"
    if [ -z "${scan}" ]; then
        for c in /etc/service /var/service /run/service; do [ -d "${c}" ] && { scan="${c}"; break; }; done
    fi
    [ -z "${scan}" ] && scan="/etc/service"

    svc_check_conflict "${dir}/run" runit || return $?
    if ! can_write_dir "${dir}"; then log_err "无写权限: ${dir}"; return 3; fi
    mkdir -p "${dir}" || return 1

    local drop=""
    if [ "${SVC_USER}" != "root" ] && command -v chpst >/dev/null 2>&1; then
        drop="exec chpst -u ${SVC_USER} "
    elif [ "${SVC_USER}" != "root" ]; then
        drop="exec su -s /bin/sh -c "
    fi

    log_step "生成 runit 服务目录: ${dir}"
    cat > "${dir}/run" <<EOF
#!/bin/sh
${SVC_MARK}
exec 2>&1
cd ${SVC_WORKDIR} || exit 1
${drop}${SVC_CMD}
EOF
    [ $? -ne 0 ] && { log_err "写入 runit run 脚本失败"; return 1; }
    chmod 755 "${dir}/run"

    if command -v svlogd >/dev/null 2>&1; then
        mkdir -p "${dir}/log"
        printf '#!/bin/sh\nexec svlogd -tt /var/log/%s\n' "${SVC_NAME}" > "${dir}/log/run"
        chmod 755 "${dir}/log/run"
        mkdir -p "/var/log/${SVC_NAME}" 2>/dev/null
    fi

    svc_record "${dir}/run" "ln -sfn ${dir} ${scan}/${SVC_NAME}" \
        "sv start ${SVC_NAME}" "sv stop ${SVC_NAME}" "sv status ${SVC_NAME}" \
        "tail -f /var/log/${SVC_NAME}/current"
    return 0
}

svc_gen_s6() {
    local dir="${S6_SVC_DIR:-/etc/s6/sv}/${SVC_NAME}"
    local scan="${S6_SCAN_DIR:-}"
    if [ -z "${scan}" ]; then
        for c in /run/s6/services /service /var/s6/services; do [ -d "${c}" ] && { scan="${c}"; break; }; done
    fi
    [ -z "${scan}" ] && scan="/service"

    svc_check_conflict "${dir}/run" s6 || return $?
    if ! can_write_dir "${dir}"; then log_err "无写权限: ${dir}"; return 3; fi
    mkdir -p "${dir}" || return 1

    local drop=""
    if [ "${SVC_USER}" != "root" ] && command -v s6-setuidgid >/dev/null 2>&1; then
        drop="exec s6-setuidgid ${SVC_USER} "
    fi

    log_step "生成 s6 服务目录: ${dir}"
    cat > "${dir}/run" <<EOF
#!/command/execlineb -P
${SVC_MARK}
cd ${SVC_WORKDIR}
${drop}${SVC_CMD}
EOF
    # execlineb 在部分发行版缺失，降级为 sh
    if ! command -v execlineb >/dev/null 2>&1; then
        cat > "${dir}/run" <<EOF
#!/bin/sh
${SVC_MARK}
exec 2>&1
cd ${SVC_WORKDIR} || exit 1
${drop}${SVC_CMD}
EOF
    fi
    [ $? -ne 0 ] && { log_err "写入 s6 run 脚本失败"; return 1; }
    chmod 755 "${dir}/run"

    svc_record "${dir}/run" "ln -sfn ${dir} ${scan}/${SVC_NAME}" \
        "s6-svc -u ${scan}/${SVC_NAME}" "s6-svc -d ${scan}/${SVC_NAME}" \
        "s6-svstat ${scan}/${SVC_NAME}" "tail -f /var/log/${SVC_NAME}.log"
    return 0
}

svc_gen_supervisord() {
    local dir="${SUPERVISOR_CONF_DIR:-}"
    if [ -z "${dir}" ]; then
        for c in /etc/supervisor/conf.d /etc/supervisord.d; do [ -d "${c}" ] && { dir="${c}"; break; }; done
    fi
    [ -z "${dir}" ] && dir="/etc/supervisor/conf.d"
    local ext="conf"
    case "${dir}" in *supervisord.d) ext="ini" ;; esac
    local file="${dir}/${SVC_NAME}.${ext}"

    svc_check_conflict "${file}" supervisord || return $?
    if ! can_write_dir "${dir}"; then log_err "无写权限: ${dir}"; return 3; fi
    mkdir -p "${dir}" || return 1
    mkdir -p /var/log/supervisor 2>/dev/null

    local autorestart="true"
    case "${SVC_RESTART}" in
        no)          autorestart="false" ;;
        on-failure)  autorestart="unexpected" ;;
        *)           autorestart="true" ;;
    esac

    log_step "生成 supervisord 配置: ${file}"
    cat > "${file}" <<EOF
${SVC_MARK}
[program:${SVC_NAME}]
command=${SVC_CMD}
directory=${SVC_WORKDIR}
user=${SVC_USER}
autostart=true
autorestart=${autorestart}
startsecs=5
stopwaitsecs=10
stdout_logfile=/var/log/supervisor/${SVC_NAME}.log
stderr_logfile=/var/log/supervisor/${SVC_NAME}.err
EOF
    [ $? -ne 0 ] && { log_err "写入 supervisord 配置失败"; return 1; }
    chmod 644 "${file}"
    svc_record "${file}" \
        "supervisorctl reread && supervisorctl update" \
        "supervisorctl start ${SVC_NAME}" "supervisorctl stop ${SVC_NAME}" \
        "supervisorctl status ${SVC_NAME}" "tail -f /var/log/supervisor/${SVC_NAME}.log"
    return 0
}

svc_gen_launchd() {
    local dir file
    if [ "${SVC_SCOPE_APPLY}" = "user" ]; then
        dir="${LAUNCH_AGENTS_DIR:-${RU_HOME:-${HOME}}/Library/LaunchAgents}"
    else
        dir="${LAUNCH_DAEMONS_DIR:-/Library/LaunchDaemons}"
    fi
    file="${dir}/${SVC_NAME}.plist"
    svc_check_conflict "${file}" launchd || return $?
    if ! can_write_dir "${dir}"; then log_err "无写权限: ${dir}"; return 3; fi
    mkdir -p "${dir}" || return 1

    local keepalive="false"
    [ "${SVC_RESTART}" != "no" ] && keepalive="true"

    log_step "生成 launchd plist: ${file}"
    cat > "${file}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${SVC_NAME}</string>
    <key>ProgramArguments</key>
    <array>
$(printf '%s\n' "${SVC_CMD}" | awk '{for(i=1;i<=NF;i++) printf "        <string>%s</string>\n", $i}')
    </array>
    <key>WorkingDirectory</key><string>${SVC_WORKDIR}</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><${keepalive}/>
    <key>UserName</key><string>${SVC_USER}</string>
    <key>StandardOutPath</key><string>/var/log/${SVC_NAME}.log</string>
    <key>StandardErrorPath</key><string>/var/log/${SVC_NAME}.err</string>
</dict>
</plist>
EOF
    [ $? -ne 0 ] && { log_err "写入 plist 失败"; return 1; }
    chmod 644 "${file}"
    svc_record "${file}" "launchctl load -w ${file}" \
        "launchctl start ${SVC_NAME}" "launchctl stop ${SVC_NAME}" \
        "launchctl list | grep ${SVC_NAME}" "tail -f /var/log/${SVC_NAME}.log"
    return 0
}

svc_gen_cron() {
    local scope="${SVC_SCOPE_APPLY}"
    local cmd="cd ${SVC_WORKDIR} && ${SVC_CMD}"
    if [ "${scope}" = "user" ]; then
        # 用户级：写入该用户 crontab 的 @reboot
        local pfx; pfx="$(svc_as_user_prefix)"
        local tmp; tmp="$(mktemp 2>/dev/null || echo /tmp/cron.$$)"
        ${pfx}crontab -l 2>/dev/null | grep -v "${SVC_MARK} ${SVC_NAME}" > "${tmp}" || true
        printf '%s %s\n@reboot %s\n' "${SVC_MARK}" "${SVC_NAME}" "${cmd}" >> "${tmp}"
        if ! ${pfx}crontab "${tmp}" 2>/dev/null; then
            rm -f "${tmp}"; log_err "写入用户 crontab 失败"; return 1
        fi
        rm -f "${tmp}"
        log_step "已注册用户级 @reboot 任务: ${SVC_NAME}"
        SVC_SERVICE_PATH="crontab(${RU_NAME:-当前用户})"
        SVC_ENABLE_CMD=""; SVC_START_CMD="${pfx}bash -c '${cmd}'"
        SVC_STOP_CMD="${pfx}pkill -f '${SVC_CMD}'"
        SVC_STATUS_CMD="${pfx}crontab -l | grep ${SVC_NAME}"
        SVC_LOG_CMD=""
        SVC_UNINSTALL_CMD="${pfx}crontab -l | grep -v '${SVC_NAME}' | ${pfx}crontab -"
        track cmd "${SVC_UNINSTALL_CMD}"
        log_info "服务定义已生成: 用户 crontab @reboot"
        return 0
    fi

    local dir="${CRON_D_DIR:-/etc/cron.d}"
    local file="${dir}/${SVC_NAME}"
    svc_check_conflict "${file}" cron || return $?
    if ! can_write_dir "${dir}"; then log_err "无写权限: ${dir}"; return 3; fi
    mkdir -p "${dir}" || return 1

    log_step "生成 cron @reboot 任务: ${file}"
    cat > "${file}" <<EOF
${SVC_MARK} ${SVC_NAME}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
@reboot ${SVC_USER} bash -c '${cmd}' >> /var/log/${SVC_NAME}.log 2>&1
EOF
    [ $? -ne 0 ] && { log_err "写入 cron.d 失败"; return 1; }
    chmod 644 "${file}"
    svc_record "${file}" "true" "bash -c '${cmd}' &" "pkill -f '${SVC_CMD}'" \
        "cat ${file}" "tail -f /var/log/${SVC_NAME}.log"
    return 0
}

svc_gen_rclocal() {
    local file="${RC_LOCAL:-/etc/rc.local}"
    if [ ! -e "${file}" ]; then
        if ! can_write_dir "${file}"; then log_err "无写权限: ${file}"; return 3; fi
        printf '#!/bin/sh -e\nexit 0\n' > "${file}" && chmod 755 "${file}"
    fi
    if ! can_write_dir "${file}"; then log_err "无写权限: ${file}"; return 3; fi
    if grep -q "${SVC_MARK} ${SVC_NAME}" "${file}" 2>/dev/null; then
        log_info "rc.local 中已存在本服务的启动项，跳过重复添加"
    else
        # 插到 exit 0 之前，否则永远不会执行
        local tmp="${file}.$$"
        awk -v mark="${SVC_MARK} ${SVC_NAME}" -v cmd="cd ${SVC_WORKDIR} && ${SVC_CMD} >> /var/log/${SVC_NAME}.log 2>&1 &" '
            { if ($0 ~ /^[[:space:]]*exit[[:space:]]+0/ && !done) { print mark; print cmd; done=1 } print }
            END { if (!done) { print mark; print cmd } }' "${file}" > "${tmp}" \
            && cat "${tmp}" > "${file}" && rm -f "${tmp}"
        chmod 755 "${file}"
    fi
    log_step "已追加到 ${file}"
    SVC_SERVICE_PATH="${file}"
    SVC_ENABLE_CMD=""; SVC_START_CMD="bash -c 'cd ${SVC_WORKDIR} && ${SVC_CMD}' &"
    SVC_STOP_CMD="pkill -f '${SVC_CMD}'"; SVC_STATUS_CMD="grep ${SVC_NAME} ${file}"
    SVC_LOG_CMD="tail -f /var/log/${SVC_NAME}.log"
    SVC_FILES_CREATED+=("${file}")
    log_info "服务定义已生成: ${file} (rc.local)"
    return 0
}

# --- 11.4 服务参数校验 ---
svc_precheck() {
    # 服务名
    if [ -z "${SVC_NAME}" ]; then SVC_NAME="${APP_NAME}"; fi
    if ! printf '%s' "${SVC_NAME}" | grep -qE '^[A-Za-z0-9._@-]+$'; then
        log_err "服务名非法: ${SVC_NAME}（只允许字母、数字、. _ @ -）"
        return 2
    fi
    # 启动命令：缺省时回退到安装时探测到的可执行文件
    if [ -z "${SVC_CMD}" ] && [ -n "${APP_EXEC}" ]; then
        SVC_CMD="${APP_EXEC}"
        log_dbg "未指定 --service-cmd，使用可执行文件: ${SVC_CMD}"
    fi
    if [ -z "${SVC_CMD}" ]; then
        log_err "未指定启动命令（--service-cmd），且未探测到可执行文件"
        return 2
    fi
    local first; first="${SVC_CMD%% *}"
    if [ ! -x "${first}" ] && ! command -v "${first}" >/dev/null 2>&1; then
        log_warn "启动命令首段不可执行或不在 PATH 中: ${first}"
    fi
    # 运行用户
    if [ -n "${SVC_USER}" ] && ! id "${SVC_USER}" >/dev/null 2>&1; then
        log_err "运行用户不存在: ${SVC_USER}"
        return 2
    fi
    # 工作目录
    if [ -n "${SVC_WORKDIR}" ] && [ ! -d "${SVC_WORKDIR}" ]; then
        log_warn "工作目录不存在，服务启动时可能失败: ${SVC_WORKDIR}"
    fi
    [ -z "${SVC_DESC}" ] && SVC_DESC="${APP_NAME}"
    [ -z "${SVC_WORKDIR}" ] && SVC_WORKDIR="${INSTALL_DIR}"
    return 0
}

# --- 11.5 模式自动判定（读 ENV_*） ---
#  优先级（自上而下，命中即止）：
#    S0 命令行显式 --service-manager / --service-scope
#    S1 作用域未指定时：root 或可提权 -> system；否则 -> user
#    S2 容器/无 init 环境：supervisord > cron > rclocal(仅 root)
#    S3 system 作用域：取 ENV_MGRS 中的第一个可用管理器
#    S4 user  作用域：systemd --user > launchd > 用户 cron
#    S5 选定管理器目录不可写 -> 降级链 systemd(system) -> systemd(user) -> cron
decide_service_mode() {
    # 自愈：若尚未执行过环境探测（如单独调用本函数），先探测一次
    [ -z "${ENV_PID1}" ] && env_probe
    SVC_MANAGER_DECIDED=""; SVC_SCOPE_DECIDED=""; SVC_MANAGER_REASON=""

    # S0 显式
    if [ -n "${SVC_MANAGER}" ] && [ "${SVC_MANAGER}" != "auto" ]; then
        SVC_MANAGER_DECIDED="${SVC_MANAGER}"
        SVC_MANAGER_REASON="命令行显式指定管理器"
    fi

    # S1 作用域
    if [ -n "${SVC_SCOPE}" ] && [ "${SVC_SCOPE}" != "auto" ]; then
        SVC_SCOPE_DECIDED="${SVC_SCOPE}"
    elif [ "${ENV_IS_ROOT}" -eq 1 ] || [ "${ENV_CAN_SUDO}" -eq 1 ]; then
        SVC_SCOPE_DECIDED="system"
    else
        SVC_SCOPE_DECIDED="user"
    fi

    [ -n "${SVC_MANAGER_DECIDED}" ] && return 0

    # S2 容器 / 无传统 init
    if [ "${ENV_CONTAINER}" -eq 1 ] && [ "${ENV_PID1}" != "systemd" ]; then
        if command -v supervisorctl >/dev/null 2>&1 || [ -d /etc/supervisor ]; then
            SVC_MANAGER_DECIDED="supervisord"
            SVC_MANAGER_REASON="容器环境且无 systemd，使用 supervisord 作为进程管理器"
            return 0
        fi
        if command -v crontab >/dev/null 2>&1; then
            SVC_MANAGER_DECIDED="cron"
            SVC_SCOPE_DECIDED="system"
            SVC_MANAGER_REASON="容器环境且无 init，降级为 cron @reboot"
            return 0
        fi
        SVC_MANAGER_DECIDED="rclocal"
        SVC_MANAGER_REASON="容器环境，仅在 rc.local 中登记启动项"
        return 0
    fi

    # S3 / S4 按作用域取
    if [ "${SVC_SCOPE_DECIDED}" = "user" ]; then
        if [ "${ENV_SYSTEMD_USER}" -eq 1 ]; then
            SVC_MANAGER_DECIDED="systemd"
            SVC_MANAGER_REASON="用户级作用域，systemd --user 可用"
        elif [ -n "$(printf '%s' "${ENV_MGRS}" | tr ' ' '\n' | grep -x launchd || true)" ]; then
            SVC_MANAGER_DECIDED="launchd"
            SVC_MANAGER_REASON="用户级作用域，使用 launchd LaunchAgents"
        else
            SVC_MANAGER_DECIDED="cron"
            SVC_MANAGER_REASON="用户级作用域且无 systemd --user，降级为用户 crontab @reboot"
        fi
        return 0
    fi

    local first=""
    first="$(printf '%s' "${ENV_MGRS}" | awk '{print $1}')"
    if [ -n "${first}" ]; then
        SVC_MANAGER_DECIDED="${first}"
        SVC_MANAGER_REASON="系统级作用域，探测到的最高优先级管理器（可用列表: ${ENV_MGRS}）"
    else
        SVC_MANAGER_DECIDED="none"
        SVC_MANAGER_REASON="未探测到任何可用的服务管理器"
    fi
    return 0
}

# --- 11.6 统一注册入口 ---
# 返回: 0 成功  2 参数/校验失败  3 权限不足  5 服务已存在冲突
register_service() {
    SVC_FILES_CREATED=(); SVC_UNINSTALL_CMD=""
    svc_precheck || return $?

    decide_service_mode
    SVC_SCOPE_APPLY="${SVC_SCOPE_DECIDED}"
    SVC_MANAGER_APPLY="${SVC_MANAGER_DECIDED}"

    # user 作用域需要解析目标用户（默认当前用户）
    if [ "${SVC_SCOPE_APPLY}" = "user" ]; then
        # root 或未指定时，回退到真实发起者：SUDO_USER > USER > id -un
        local ref="${SVC_USER}"
        if [ "${SVC_USER}" = "root" ] || [ -z "${SVC_USER}" ]; then
            ref="${ENV_SUDO_USER:-${USER:-$(id -un 2>/dev/null || echo root)}}"
        fi
        if ! resolve_user_ref "${ref}"; then
            log_err "无法定位用户级服务的目标用户: ${RU_ERR}"
            return 2
        fi
    fi

    log_info "服务模式判定: 管理器=${SVC_MANAGER_APPLY} 作用域=${SVC_SCOPE_APPLY}"
    log_info "  依据: ${SVC_MANAGER_REASON}"

    if [ "${SVC_MANAGER_APPLY}" = "none" ]; then
        log_warn "未探测到受支持的服务管理器，跳过注册"
        log_warn "  可手动指定: --service-manager cron|rclocal|sysv|..."
        return 0
    fi

    # systemd 下先检查是否被 mask（mask 后 enable/start 必然失败，早失败早提示）
    if [ "${SVC_MANAGER_APPLY}" = "systemd" ]; then
        svc_check_masked || return $?
    fi

    local rc=0
    svc_dispatch "${SVC_MANAGER_APPLY}" || rc=$?

    # 权限不足时按降级链重试一次（systemd system -> systemd user -> cron）
    if [ "${rc}" -eq 3 ] && [ "${SVC_SCOPE_APPLY}" = "system" ]; then
        log_warn "系统级注册权限不足，尝试降级为用户级 systemd"
        if [ "${ENV_SYSTEMD_USER}" -eq 1 ]; then
            SVC_SCOPE_APPLY="user"; SVC_MANAGER_APPLY="systemd"
            [ "${SVC_USER}" = "root" ] && SVC_USER="${ENV_SUDO_USER:-${USER:-root}}"
            resolve_user_ref "${SVC_USER}" >/dev/null 2>&1
            SVC_MANAGER_REASON="系统级目录不可写，降级为用户级 systemd"
            rc=0; svc_dispatch "systemd" || rc=$?
        fi
        if [ "${rc}" -eq 3 ]; then
            log_warn "用户级 systemd 亦不可用，降级为 cron @reboot"
            SVC_MANAGER_APPLY="cron"
            SVC_MANAGER_REASON="无 systemd --user 写权限，最终降级为 cron @reboot"
            rc=0; svc_dispatch "cron" || rc=$?
        fi
    fi
    [ "${rc}" -ne 0 ] && return "${rc}"

    svc_enable_start
    return $?
}

# 按管理器分发
svc_dispatch() {
    case "$1" in
        systemd)     svc_gen_systemd ;;
        upstart)     svc_gen_upstart ;;
        sysv)        svc_gen_sysv ;;
        openrc)      svc_gen_openrc ;;
        runit)       svc_gen_runit ;;
        s6)          svc_gen_s6 ;;
        supervisord) svc_gen_supervisord ;;
        launchd)     svc_gen_launchd ;;
        cron)        svc_gen_cron ;;
        rclocal)     svc_gen_rclocal ;;
        none)        return 0 ;;
        *)           log_err "不支持的服务管理器: $1"; return 2 ;;
    esac
}

# --- 11.7 开机自启 / 立即启动 ---
# SVC_START_MODE: now(自启+立即启动) / boot(仅自启) / none(仅注册)
svc_enable_start() {
    # 决定启动方式
    if [ -z "${SVC_START_MODE}" ]; then
        if [ "${ASSUME_YES}" -eq 1 ]; then
            SVC_START_MODE="now"
        elif confirm "是否设置开机自启？" "y"; then
            if confirm "是否立即启动服务？" "y"; then SVC_START_MODE="now"; else SVC_START_MODE="boot"; fi
        else
            SVC_START_MODE="none"
        fi
    fi
    log_dbg "启动方式: ${SVC_START_MODE}"

    local rc=0
    case "${SVC_START_MODE}" in
        now|boot)
            if [ -n "${SVC_ENABLE_CMD}" ] && [ "${SVC_ENABLE_CMD}" != "true" ]; then
                log_step "设置开机自启: ${SVC_ENABLE_CMD}"
                if eval "${SVC_ENABLE_CMD}" >/dev/null 2>&1; then
                    SVC_ENABLED="yes"
                    # 登记撤销动作
                    case "${SVC_MANAGER_APPLY}" in
                        systemd)
                            if [ "${SVC_SCOPE_APPLY}" = "user" ]; then
                                track cmd "$(svc_as_user_prefix)systemctl --user disable ${SVC_NAME}"
                            else
                                track cmd "systemctl disable ${SVC_NAME}"
                            fi ;;
                        sysv)   track cmd "chkconfig ${SVC_NAME} off 2>/dev/null || update-rc.d -f ${SVC_NAME} remove" ;;
                        openrc) track cmd "rc-update del ${SVC_NAME} default" ;;
                    esac
                else
                    log_warn "设置开机自启失败: ${SVC_ENABLE_CMD}"
                    rc=1
                fi
            fi
            [ "${SVC_START_MODE}" = "boot" ] && return "${rc}"
            log_step "立即启动: ${SVC_START_CMD}"
            if eval "${SVC_START_CMD}" >/dev/null 2>&1; then
                SVC_STARTED="yes"
                track cmd "${SVC_STOP_CMD}"
                sleep 1
                eval "${SVC_STATUS_CMD}" 2>/dev/null | head -8
            else
                log_warn "启动失败，请检查日志: ${SVC_LOG_CMD}"
                rc=1
            fi
            ;;
        none)
            log_info "仅注册服务定义，未设置自启、未启动"
            ;;
    esac
    return "${rc}"
}


# ============================================================================
#  第 12 节：交互向导
# ============================================================================
wizard_package() {
    local default_path="" p
    # 优先使用提权前透传的环境变量，避免重复输入
    [ -n "${PKG_PRESET_PATH:-}" ] && PKG_PATH="${PKG_PRESET_PATH}"

    if [ -z "${PKG_PATH}" ]; then
        # 扫描当前目录常见包作为候选
        local cands=() f i=1
        for f in *.tar.gz *.tgz *.tar.xz *.tar.bz2 *.tar *.zip *.deb *.rpm *.AppImage *.run *.sh *.bin; do
            [ -e "$f" ] && cands+=("$f")
        done 2>/dev/null
        if [ "${#cands[@]}" -gt 0 ]; then
            printf '\n当前目录发现以下软件包：\n'; hr
            for f in "${cands[@]}"; do printf '  %2d) %s\n' "$i" "$f"; i=$((i+1)); done
            printf '   0) 手动输入路径\n'; hr
            read -r -p "选择编号 [1]: " p
            if [ -z "$p" ] || [ "$p" = "1" ]; then
                PKG_PATH="${cands[0]}"
            elif [ "$p" = "0" ]; then
                read -r -p "输入包路径: " PKG_PATH
            else
                PKG_PATH="${cands[$((p-1))]:-}"
            fi
        else
            read -r -p "请输入软件包路径: " PKG_PATH
        fi
    fi

    [ -z "${PKG_PATH}" ] && fail "未指定软件包路径"
    [ -e "${PKG_PATH}" ] || fail "文件不存在: ${PKG_PATH}"
    [ -f "${PKG_PATH}" ] || fail "不是普通文件: ${PKG_PATH}"
    [ -r "${PKG_PATH}" ] || fail "文件不可读: ${PKG_PATH}"

    # 类型识别
    local detected
    detected="$(detect_pkg_type "${PKG_PATH}")"
    if [ -z "${detected}" ]; then
        log_warn "无法自动识别包类型"
    else
        log_info "自动识别包类型: ${detected}"
    fi

    if [ "${ASSUME_YES}" -eq 1 ] || [ -n "${PKG_TYPE}" ]; then
        PKG_TYPE_REAL="${PKG_TYPE:-${detected}}"
        [ "${PKG_TYPE_REAL}" = "auto" ] && PKG_TYPE_REAL="${detected}"
    else
        printf '\n可指定的类型: tar.gz tar.bz2 tar.xz tar.zst tar zip deb rpm appimage binary script\n'
        ask "包类型（直接回车使用识别结果）" "${detected}" PKG_TYPE_REAL
        [ "${PKG_TYPE_REAL}" = "auto" ] && PKG_TYPE_REAL="${detected}"
    fi

    [ -z "${PKG_TYPE_REAL}" ] && fail "无法确定包类型，请用 -t 手动指定"
    validate_type_tools "${PKG_TYPE_REAL}" || fail "包类型不受支持或缺少必要工具"

    # 软件名
    [ -z "${APP_NAME}" ] && [ -n "${PKG_PRESET_NAME:-}" ] && APP_NAME="${PKG_PRESET_NAME}"
    [ -z "${APP_NAME}" ] && APP_NAME="$(derive_app_name "${PKG_PATH}")"
    ask "软件名称" "${APP_NAME}" APP_NAME
    APP_NAME="$(printf '%s' "${APP_NAME}" | tr -cd 'A-Za-z0-9._-')"
    [ -z "${APP_NAME}" ] && fail "软件名称无效"

    # deb/rpm 安装方式
    case "${PKG_TYPE_REAL}" in
        deb|rpm)
            if [ "${ASSUME_YES}" -eq 0 ] && [ -z "${INSTALL_MODE_FORCED:-}" ]; then
                printf '\n安装方式:\n'
                printf '  1) system  —— 用包管理器安装（需 root，可自动处理依赖）\n'
                printf '  2) extract —— 仅解包到安装目录（绿色版，不影响系统包数据库）\n'
                ask "选择" "system" INSTALL_MODE
            fi
            ;;
    esac
    return 0
}

wizard_directory() {
    [ -z "${INSTALL_BASE}" ] && [ -n "${PKG_PRESET_BASE:-}" ] && INSTALL_BASE="${PKG_PRESET_BASE}"
    [ -z "${INSTALL_BASE}" ] && INSTALL_BASE="/opt"

    while true; do
        ask "安装基目录（软件将安装到 <基目录>/<软件名>）" "${INSTALL_BASE}" INSTALL_BASE
        # 去掉结尾斜杠
        INSTALL_BASE="${INSTALL_BASE%/}"
        [ -n "${INSTALL_BASE}" ] || { log_warn "路径不能为空"; continue; }

        local rc=0
        prepare_install_base "${INSTALL_BASE}" || rc=$?
        case "${rc}" in
            0) break ;;
            2) return 2 ;;   # 需要提权
            *)
                [ "${ASSUME_YES}" -eq 1 ] && fail "安装目录不可用: ${INSTALL_BASE}"
                confirm "是否重新输入目录？" "y" || fail "安装目录不可用: ${INSTALL_BASE}"
                ;;
        esac
    done

    INSTALL_DIR="${INSTALL_BASE}/${APP_NAME}"
    if [ -e "${INSTALL_DIR}" ]; then
        log_warn "目标目录已存在: ${INSTALL_DIR}"
        if [ "${ASSUME_YES}" -eq 1 ]; then
            log_info "非交互模式，覆盖安装"
        elif confirm "是否覆盖（删除后重建）？" "n"; then
            rm -rf "${INSTALL_DIR}" || fail "无法删除: ${INSTALL_DIR}"
            log_info "已清除旧目录"
        else
            ask "改用其他目录名" "${INSTALL_DIR}-new" INSTALL_DIR
        fi
    fi
    return 0
}

wizard_desktop() {
    [ -n "${DO_DESKTOP}" ] && [ -z "${PKG_PRESET_DESKTOP:-}" ] && return 0
    [ -z "${DO_DESKTOP}" ] && [ -n "${PKG_PRESET_DESKTOP:-}" ] && DO_DESKTOP="${PKG_PRESET_DESKTOP}"

    if [ -z "${DO_DESKTOP}" ]; then
        if confirm "是否创建桌面快捷方式（.desktop）？" "y"; then DO_DESKTOP="yes"; else DO_DESKTOP="no"; fi
    fi
    [ "${DO_DESKTOP}" != "yes" ] && return 0

    ask "快捷方式显示名称" "${APP_NAME}" DESKTOP_NAME
    [ -z "${DESKTOP_ICON}" ] && ask "图标路径（留空自动查找）" "" DESKTOP_ICON
    [ -z "${DESKTOP_CATEGORY_FORCED:-}" ] && ask "分类（多个用分号分隔）" "${DESKTOP_CATEGORY}" DESKTOP_CATEGORY
    if [ "${ASSUME_YES}" -eq 0 ]; then
        if confirm "程序是否需要在终端中运行？" "n"; then DESKTOP_TERMINAL="true"; else DESKTOP_TERMINAL="false"; fi
    fi
    [ -z "${APP_DESC}" ] && ask "软件描述（用于 Comment 字段）" "${APP_NAME}" APP_DESC

    # 作用范围：先按环境自动判定并给出建议，用户可覆盖
    local preset_scope="${DESKTOP_SCOPE}" preset_user="${DESKTOP_TARGET_USER}"
    decide_desktop_scope
    local sug="${DESKTOP_SCOPE_DECIDED}" sug_reason="${DESKTOP_SCOPE_REASON}"
    [ -z "${preset_scope}" ] && DESKTOP_SCOPE=""      # 自动填充的判定结果不视为显式指定
    [ -z "${preset_user}"  ] && DESKTOP_TARGET_USER=""

    if [ -n "${preset_scope}" ] || [ -n "${preset_user}" ]; then
        log_info "快捷方式范围: ${DESKTOP_SCOPE:-由目标用户推导}（命令行指定）"
        return 0
    fi

    printf '\n快捷方式作用范围（自动判定: %s —— %s）\n' "${sug}" "${sug_reason}"
    printf '  1) 自动判定（推荐，采用上述结果）\n'
    printf '  2) 所有用户（系统级应用目录 + 公共桌面目录）\n'
    printf '  3) 当前用户（仅 %s 可见）\n' "${HOME:-/root}"
    printf '  4) 指定用户（用户名 / UID / SID）\n'
    local sc; ask "选择范围" "1" sc
    case "${sc}" in
        1) : ;;
        2) DESKTOP_SCOPE="all" ;;
        3) DESKTOP_SCOPE="current" ;;
        4) DESKTOP_SCOPE="user"
           ask "目标用户（用户名 / UID / SID）" "$(id -un 2>/dev/null || echo root)" DESKTOP_TARGET_USER ;;
        *) : ;;
    esac
    return 0
}

wizard_service() {
    # 注意：不能因为 DO_SERVICE 已由命令行指定就直接 return，
    # 否则 SVC_CMD / SVC_NAME 等必需参数拿不到默认值，注册阶段会直接失败
    [ -n "${PKG_PRESET_SERVICE:-}" ] && [ -z "${DO_SERVICE}" ] && DO_SERVICE="${PKG_PRESET_SERVICE}"

    SVC_DETECTED="$(printf '%s' "${ENV_MGRS}" | awk '{print $1}')"
    [ -z "${SVC_DETECTED}" ] && SVC_DETECTED="none"
    log_info "探测到可用服务管理器（按优先级）: ${ENV_MGRS:-无}"

    if [ -z "${DO_SERVICE}" ]; then
        if [ "${SVC_DETECTED}" = "none" ]; then
            log_warn "未探测到受支持的服务管理器"
            if ! confirm "仍要继续注册服务？" "n"; then DO_SERVICE="no"; return 0; fi
            DO_SERVICE="yes"
        elif confirm "是否注册为系统服务？" "n"; then
            DO_SERVICE="yes"
        else
            DO_SERVICE="no"
        fi
    fi
    [ "${DO_SERVICE}" != "yes" ] && return 0

    # 管理器 + 作用域：先按环境自动判定并给出建议，用户可覆盖
    decide_service_mode
    local sug_m="${SVC_MANAGER_DECIDED}" sug_s="${SVC_SCOPE_DECIDED}"
    if [ -z "${SVC_MANAGER}" ] && [ -z "${SVC_SCOPE}" ]; then
        printf '\n服务注册模式（自动判定: 管理器=%s 作用域=%s）\n  依据: %s\n' \
            "${sug_m}" "${sug_s}" "${SVC_MANAGER_REASON}"
        printf '  1) 自动判定（推荐）\n  2) 手动指定管理器与作用域\n'
        local sc; ask "选择" "1" sc
        if [ "${sc}" = "2" ]; then
            printf '  可用管理器: %s\n' "${ENV_MGRS:-cron rclocal}"
            ask "管理器名" "${sug_m}" SVC_MANAGER
            printf '  作用域: 1) system（系统级，需 root）  2) user（用户级）\n'
            local s2; ask "作用域" "$([ "${sug_s}" = "user" ] && echo 2 || echo 1)" s2
            case "${s2}" in 2) SVC_SCOPE="user" ;; *) SVC_SCOPE="system" ;; esac
        fi
    fi

    [ -z "${SVC_NAME}" ]      && ask "服务名称"        "${APP_NAME}" SVC_NAME
    [ -z "${SVC_DESC}" ]      && ask "服务描述"        "${APP_NAME}" SVC_DESC
    [ -z "${SVC_USER}" ]      && ask "运行用户"        "root"        SVC_USER
    [ -z "${SVC_WORKDIR}" ]   && SVC_WORKDIR="${INSTALL_DIR}"
    [ "${ASSUME_YES}" -eq 0 ] && ask "工作目录"        "${SVC_WORKDIR}" SVC_WORKDIR
    [ -z "${SVC_CMD}" ]       && ask "启动命令"        "${APP_EXEC}"    SVC_CMD
    [ "${ASSUME_YES}" -eq 0 ] && ask "重启策略 (no|always|on-failure|on-abnormal)" "${SVC_RESTART}" SVC_RESTART

    # 校验运行用户是否存在：不存在时给出可修正的替代者
    # （与 svc_precheck 的致命校验保持一致，避免这里"保留"、那里又失败）
    if ! id "${SVC_USER}" >/dev/null 2>&1; then
        log_warn "运行用户不存在: ${SVC_USER}"
        local alt="root"
        id root >/dev/null 2>&1 || alt="$(id -un 2>/dev/null || true)"
        if [ -n "${alt}" ] && { [ "${ASSUME_YES}" -eq 1 ] || confirm "是否改用 ${alt}？" "y"; }; then
            SVC_USER="${alt}"
            log_info "运行用户已改为: ${SVC_USER}"
        else
            log_warn "保留用户 ${SVC_USER}，服务可能因用户不存在而启动失败"
        fi
    fi

    # 启动方式
    if [ -z "${SVC_START_MODE}" ] && [ "${ASSUME_YES}" -eq 0 ]; then
        printf '\n启动方式:\n  1) 开机自启并立即启动  2) 仅设置开机自启  3) 仅注册，暂不启动\n'
        local sm; ask "选择" "1" sm
        case "${sm}" in 2) SVC_START_MODE="boot" ;; 3) SVC_START_MODE="none" ;; *) SVC_START_MODE="now" ;; esac
    fi
    return 0
}

# ============================================================================
#  第 13 节：安装编排
# ============================================================================
run_install() {
    local rc=0
    log_step "开始安装 ${APP_NAME}（类型: ${PKG_TYPE_REAL}）"

    case "${PKG_TYPE_REAL}" in
        tar|tar.gz|tgz|tar.bz2|tbz2|tar.xz|txz|tar.zst|tzst|zip)
            install_archive "${PKG_PATH}" "${INSTALL_DIR}" "${PKG_TYPE_REAL}" || rc=$? ;;
        deb)
            install_deb "${PKG_PATH}" "${INSTALL_DIR}" "${INSTALL_MODE}" || rc=$? ;;
        rpm)
            install_rpm "${PKG_PATH}" "${INSTALL_DIR}" "${INSTALL_MODE}" || rc=$? ;;
        appimage|binary|script)
            install_executable "${PKG_PATH}" "${INSTALL_DIR}" "${PKG_TYPE_REAL}" || rc=$? ;;
        *)
            fail "未实现的包类型: ${PKG_TYPE_REAL}" ;;
    esac

    [ "${rc}" -ne 0 ] && {
        case "${rc}" in
            3) log_err "权限不足，需要 root 才能继续" ;;
            *) log_err "安装步骤失败（退出码 ${rc}）" ;;
        esac
        return "${rc}"
    }

    # 归档/解包类需要探测可执行文件
    case "${PKG_TYPE_REAL}" in
        appimage|binary|script) : ;;
        *) choose_executable "${INSTALL_DIR}" ;;
    esac
    return 0
}

# ============================================================================
#  第 14 节：摘要输出
# ============================================================================
print_summary() {
    printf '\n'
    printf "${C_C}===============================================================${C_N}\n"
    printf "${C_C}   安装完成 —— 摘要${C_N}\n"
    printf "${C_C}===============================================================${C_N}\n"
    printf '  软件名称    : %s\n' "${APP_NAME}"
    printf '  包类型      : %s\n' "${PKG_TYPE_REAL}"
    printf '  安装路径    : %s\n' "${INSTALL_DIR}"
    [ -n "${APP_EXEC}" ] && printf '  可执行文件  : %s\n' "${APP_EXEC}"
    [ -n "${INSTALLED_PKG_NAME}" ] && printf '  系统包名    : %s\n' "${INSTALLED_PKG_NAME}"

    if [ "${#DESKTOP_FILES_CREATED[@]}" -gt 0 ]; then
        local df
        printf '  桌面快捷方式: 范围=%s%s\n' "${DESKTOP_SCOPE_APPLIED:-current}" \
            "$([ -n "${DESKTOP_SCOPE_APPLIED}" ] && [ "${DESKTOP_SCOPE_APPLIED}" != "${DESKTOP_SCOPE_DECIDED}" ] && echo ' (已回退)' || echo '')"
        for df in "${DESKTOP_FILES_CREATED[@]}"; do printf '      - %s\n' "${df}"; done
    else
        printf '  桌面快捷方式: 未创建\n'
    fi

    if [ -n "${SVC_SERVICE_PATH:-}" ]; then
        printf '  服务定义    : %s\n' "${SVC_SERVICE_PATH}"
        printf '  服务名称    : %s (%s / %s)\n' "${SVC_NAME}" "${SVC_MANAGER_APPLY}" "${SVC_SCOPE_APPLY}"
        printf '  运行状态    : %s   开机自启: %s\n' "${SVC_STARTED:-未启动}" "${SVC_ENABLED:-否}"
        if [ -n "${SVC_ENABLE_CMD}" ] && [ "${SVC_ENABLE_CMD}" != "true" ]; then
            printf '\n  常用管理命令:\n'
            printf '    开机自启  : %s\n' "${SVC_ENABLE_CMD}"
            printf '    启动      : %s\n' "${SVC_START_CMD}"
            printf '    停止      : %s\n' "${SVC_STOP_CMD}"
            printf '    状态      : %s\n' "${SVC_STATUS_CMD}"
            [ -n "${SVC_LOG_CMD}" ] && printf '    日志      : %s\n' "${SVC_LOG_CMD}"
        fi
    else
        printf '  服务注册    : 未注册\n'
    fi

    printf '\n  卸载方法:\n'
    if [ -n "${INSTALLED_PKG_NAME}" ]; then
        case "${PKG_TYPE_REAL}" in
            deb) printf '    dpkg -r %s\n' "${INSTALLED_PKG_NAME}" ;;
            rpm) printf '    rpm -e %s\n' "${INSTALLED_PKG_NAME}" ;;
        esac
    fi
    [ -d "${INSTALL_DIR}" ] && printf '    rm -rf %s\n' "${INSTALL_DIR}"
    if [ "${#DESKTOP_FILES_CREATED[@]}" -gt 0 ]; then
        local uf
        for uf in "${DESKTOP_FILES_CREATED[@]}"; do printf '    rm -f %s\n' "${uf}"; done
    fi
    if [ "${#SVC_FILES_CREATED[@]}" -gt 0 ]; then
        local sf
        for sf in "${SVC_FILES_CREATED[@]}"; do
            case "${sf}" in */run) printf '    rm -rf %s\n' "$(dirname "${sf}")" ;; *) printf '    rm -f %s\n' "${sf}" ;; esac
        done
        [ -n "${SVC_STOP_CMD}" ] && printf '    %s\n' "${SVC_STOP_CMD}"
        # crontab / rc.local 这类"无独立文件"的注册方式，给出撤销命令
        [ -n "${SVC_UNINSTALL_CMD:-}" ] && printf '    %s\n' "${SVC_UNINSTALL_CMD}"
    fi
    printf '===============================================================\n'
}

# ============================================================================
#  第 15 节：命令行参数与使用说明
# ============================================================================
usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION} —— Linux 通用软件包安装工具

用法:
  ${SCRIPT_NAME} [选项]
  ${SCRIPT_NAME} -i <包路径> -d <安装目录> [选项]        # 非交互

必需（非交互模式）:
  -i, --package <path>         软件包路径

安装选项:
  -d, --dir <path>             安装基目录（默认 /opt，实际安装到 <基目录>/<软件名>）
  -n, --name <name>            软件名称（默认从包名推导）
  -t, --type <type>            包类型，默认 auto
                               可选: tar tar.gz tar.bz2 tar.xz tar.zst zip deb rpm appimage binary script
  -e, --exec <path>            可执行文件绝对路径（跳过自动探测）
  -m, --mode <mode>            deb/rpm 安装方式: system(包管理器) | extract(仅解包)，默认 system

桌面快捷方式（三种作用范围）:
      --desktop                创建 .desktop 快捷方式
      --no-desktop             不创建
      --desktop-name <name>    显示名称
      --icon <path>            图标路径
      --category <cats>        分类，分号分隔（默认 Utility）
      --terminal               程序需在终端中运行
      --desktop-scope <s>      作用范围: all(所有用户) | current(当前用户)
                               | user(指定用户) | auto(按环境自动判定，默认)
      --desktop-user <ref>     指定用户：用户名 / UID / SID（隐含 scope=user）
      --desktop-fallback <f>   失败回退: auto(逐级降级,默认) | strict(报错) | skip(跳过)
      --desktop-sync-existing  all 模式下同步到已存在用户的桌面目录
      --desktop-public-dir <d> 覆盖公共桌面目录（默认 /etc/skel/Desktop）

服务注册（多管理器 + 多作用域）:
      --service                注册为服务
      --no-service             不注册
      --service-manager <m>    systemd | upstart | sysv | openrc | runit | s6
                               | supervisord | launchd | cron | rclocal | none | auto
      --service-scope <s>      system(系统级,需root) | user(用户级) | auto(按环境判定,默认)
      --service-name <name>    服务名（默认软件名）
      --service-user <user>    运行用户（默认 root）
      --service-cmd <cmd>      启动命令（默认可执行文件路径）
      --service-workdir <dir>  工作目录（默认安装目录）
      --service-restart <p>    重启策略: no|always|on-failure|on-abnormal（默认 on-failure）
      --service-desc <text>    服务描述
      --service-type <t>       进程类型: simple|forking|oneshot|notify（默认 simple）
      --service-after <a>      启动依赖目标（默认 network.target）
      --service-start <m>      启动方式: now(自启+启动) | boot(仅自启) | none(仅注册)
      --service-force          覆盖已存在且非本工具创建的服务定义

其他:
  -y, --yes                    非交互执行，所有确认取默认值
      --explain                打印环境探测结果与模式判定依据后退出
      --no-rollback            失败时不清理已生成内容（保留现场排查）
  -v, --verbose                输出调试信息
  -h, --help                   显示本帮助

示例:
  交互式安装:              ${SCRIPT_NAME}
  静默安装归档包:          ${SCRIPT_NAME} -i app.tar.gz -d /opt -y
  安装并注册 systemd 服务:  ${SCRIPT_NAME} -i app.tar.gz -y --desktop \\
                               --service --service-user appuser --service-cmd "/opt/app/bin/app"
  deb 绿色解包:            ${SCRIPT_NAME} -i pkg.deb -m extract -d /opt -y

退出码:  0 成功   1 常规错误   2 参数错误   3 权限不足   4 不支持的包类型
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -i|--package)         PKG_PATH="$2";        shift 2 ;;
            -d|--dir)             INSTALL_BASE="$2";    shift 2 ;;
            -n|--name)            APP_NAME="$2";        shift 2 ;;
            -t|--type)            PKG_TYPE="$2";        shift 2 ;;
            -e|--exec)            APP_EXEC="$2";        shift 2 ;;
            -m|--mode)            INSTALL_MODE="$2"; INSTALL_MODE_FORCED=1; shift 2 ;;
            --desktop)            DO_DESKTOP="yes";     shift ;;
            --no-desktop)         DO_DESKTOP="no";      shift ;;
            --desktop-name)       DESKTOP_NAME="$2";    shift 2 ;;
            --icon)               DESKTOP_ICON="$2";    shift 2 ;;
            --category)           DESKTOP_CATEGORY="$2"; DESKTOP_CATEGORY_FORCED=1; shift 2 ;;
            --terminal)           DESKTOP_TERMINAL="true"; shift ;;
            --desktop-scope)      DESKTOP_SCOPE="$2";   shift 2 ;;
            --desktop-user)       DESKTOP_TARGET_USER="$2"; shift 2 ;;
            --desktop-fallback)   DESKTOP_FALLBACK="$2"; shift 2 ;;
            --desktop-public-dir) PUBLIC_DESKTOP_DIR="$2"; shift 2 ;;
            --desktop-sync-existing) DESKTOP_SYNC_EXISTING=1; shift ;;
            --service)            DO_SERVICE="yes";     shift ;;
            --no-service)         DO_SERVICE="no";      shift ;;
            --service-manager)    SVC_MANAGER="$2";     shift 2 ;;
            --service-scope)      SVC_SCOPE="$2";       shift 2 ;;
            --service-type)       SVC_TYPE="$2";        shift 2 ;;
            --service-after)      SVC_AFTER="$2";       shift 2 ;;
            --service-start)      SVC_START_MODE="$2";  shift 2 ;;
            --service-force)      SVC_FORCE=1;          shift ;;
            --service-name)       SVC_NAME="$2";        shift 2 ;;
            --service-user)       SVC_USER="$2";        shift 2 ;;
            --service-cmd)        SVC_CMD="$2";         shift 2 ;;
            --service-workdir)    SVC_WORKDIR="$2";     shift 2 ;;
            --service-restart)    SVC_RESTART="$2";     shift 2 ;;
            --service-desc)       SVC_DESC="$2";        shift 2 ;;
            -y|--yes)             ASSUME_YES=1;         shift ;;
            --explain)            EXPLAIN_ONLY=1;       shift ;;
            --no-rollback)        NO_ROLLBACK=1;        shift ;;
            -v|--verbose)         VERBOSE=1;            shift ;;
            -h|--help)            usage; exit 0 ;;
            *) log_err "未知参数: $1"; usage; exit 2 ;;
        esac
    done

    # 参数校验
    case "${INSTALL_MODE}" in
        system|extract) : ;;
        *) log_err "-m/--mode 只能是 system 或 extract"; exit 2 ;;
    esac
    case "${DESKTOP_SCOPE}" in
        ""|auto|all|current|user) : ;;
        *) log_err "--desktop-scope 只能是 all | current | user | auto"; exit 2 ;;
    esac
    case "${DESKTOP_FALLBACK}" in
        auto|strict|skip) : ;;
        *) log_err "--desktop-fallback 只能是 auto | strict | skip"; exit 2 ;;
    esac
    case "${SVC_SCOPE}" in
        ""|auto|system|user) : ;;
        *) log_err "--service-scope 只能是 system | user | auto"; exit 2 ;;
    esac
    case "${SVC_START_MODE}" in
        ""|now|boot|none) : ;;
        *) log_err "--service-start 只能是 now | boot | none"; exit 2 ;;
    esac
    if [ -n "${SVC_MANAGER}" ] && [ "${SVC_MANAGER}" != "auto" ]; then
        case "${SVC_MANAGER}" in
            systemd|upstart|sysv|openrc|runit|s6|supervisord|launchd|cron|rclocal|none) : ;;
            *) log_err "--service-manager 不支持: ${SVC_MANAGER}"; exit 2 ;;
        esac
    fi
    [ -n "${DESKTOP_TARGET_USER}" ] && [ -z "${DESKTOP_SCOPE}" ] && DESKTOP_SCOPE="user"
    case "${SVC_RESTART}" in
        no|always|on-success|on-failure|on-abnormal|on-watchdog|on-abort) : ;;
        *) log_warn "重启策略 ${SVC_RESTART} 非 systemd 标准值，将原样写入" ;;
    esac
    if [ "${ASSUME_YES}" -eq 1 ] && [ -z "${PKG_PATH}" ] && [ -z "${PKG_PRESET_PATH:-}" ]; then
        log_err "非交互模式（-y）必须用 -i 指定软件包路径"
        exit 2
    fi
    return 0
}

# ============================================================================
#  第 16 节：主流程
# ============================================================================
main() {
    parse_args "$@"

    # 恢复提权前通过环境变量透传的选择
    [ -n "${PKG_PRESET_YES:-}" ] && ASSUME_YES=1

    printf '\n'
    printf "${C_C}===============================================================${C_N}\n"
    printf "${C_C}   Linux 通用软件包安装工具  v%s${C_N}\n" "${SCRIPT_VERSION}"
    printf "${C_C}===============================================================${C_N}\n"

    check_root
    env_probe                       # 采集环境事实，后续所有模式判定都基于它
    log_dbg "当前 uid=$(id -u)，root=${IS_ROOT}"

    # --explain：只输出探测结果与判定依据，不做任何修改
    if [ "${EXPLAIN_ONLY}" -eq 1 ]; then
        decide_desktop_scope
        decide_service_mode
        print_env_report
        exit 0
    fi

    # --- 步骤 1：选择包与识别类型 ---
    log_step "步骤 1/5  选择软件包"
    wizard_package

    # --- 步骤 2：安装目录 ---
    log_step "步骤 2/5  确定安装目录"
    local rc=0
    wizard_directory || rc=$?
    [ "${rc}" -eq 2 ] && ensure_privileges "$@"

    # --- 步骤 3：权限预判 ---
    log_step "步骤 3/5  权限检查"
    case "${PKG_TYPE_REAL}" in
        deb|rpm)
            [ "${INSTALL_MODE}" = "system" ] && require_root_for "${PKG_TYPE_REAL} 包管理器安装" ;;
    esac
    # 安装到系统目录需要 root（除非当前用户可写）
    case "${INSTALL_BASE}" in
        /opt|/usr/*|/srv|/etc) [ "${IS_ROOT}" -eq 0 ] && [ ! -w "${INSTALL_BASE}" ] && require_root_for "写入 ${INSTALL_BASE}" ;;
    esac
    # 桌面快捷方式：仅"显式指定"的范围才提前登记 root 需求。
    # auto / current 会自行降级到用户级目录，不阻塞安装。
    case "${DESKTOP_SCOPE}" in
        all)
            if [ "${IS_ROOT}" -eq 0 ] && [ ! -w "${DESKTOP_SYSTEM_DIR:-/usr/share/applications}" ]; then
                require_root_for "快捷方式写入所有用户目录 ${DESKTOP_SYSTEM_DIR:-/usr/share/applications}"
            fi ;;
        user)
            if [ "${IS_ROOT}" -eq 0 ]; then
                require_root_for "快捷方式写入指定用户 ${DESKTOP_TARGET_USER} 的家目录"
            fi ;;
    esac
    # 服务注册：按自动判定出的作用域决定是否提前要 root
    if [ "${DO_SERVICE}" = "yes" ] && [ "${IS_ROOT}" -eq 0 ]; then
        decide_service_mode
        if [ "${SVC_SCOPE_DECIDED}" = "system" ]; then
            require_root_for "注册系统级服务（管理器: ${SVC_MANAGER_DECIDED}）"
        else
            log_warn "非 root 环境，服务将以用户级方式注册（作用域: ${SVC_SCOPE_DECIDED}）"
        fi
    fi
    ensure_privileges "$@"

    # --- 步骤 4：安装 ---
    log_step "步骤 4/5  执行安装"
    if [ "${ASSUME_YES}" -eq 0 ]; then
        printf '\n即将执行：\n'
        printf '  软件包    : %s\n' "${PKG_PATH}"
        printf '  类型      : %s\n' "${PKG_TYPE_REAL}"
        printf '  安装目录  : %s\n' "${INSTALL_DIR}"
        hr
        confirm "确认开始安装？" "y" || { log_warn "已取消"; exit 0; }
    fi

    run_install || fail "安装过程中断"

    # --- 步骤 5：可选操作 ---
    log_step "步骤 5/5  安装后配置"
    wizard_desktop
    if [ "${DO_DESKTOP}" = "yes" ]; then
        local drc=0
        shortcut_create || drc=$?
        case "${drc}" in
            0) : ;;
            2) log_warn "快捷方式参数无效，已跳过（不影响主安装结果）" ;;
            *) fail "创建桌面快捷方式失败（退出码 ${drc}）" ;;
        esac
    fi

    wizard_service
    if [ "${DO_SERVICE}" = "yes" ]; then
        register_service || fail "服务注册失败"
    fi

    print_summary
    log_info "全部完成"
    exit 0
}

main "$@"
