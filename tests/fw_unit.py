#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
setup_firewall.sh 单元 / 行为验证（全 mock，不触碰真实系统）

做法：
  1. 复制一份 setup_firewall.sh 到临时目录，把 CONF_DIR 指到临时路径
     （只改这一行，其余逻辑与原文件逐字节一致），并去掉尾部的 main "$@"
     以便直接调用内部函数；
  2. mock 命令写成可执行文件放进临时 bin，前置到 PATH，
     这样 `command -v xxx` 的语义与真实环境一致；
  3. 断言全部在 Python 侧完成，读的是 mock 记录下来的调用日志。

用法： python tests/fw_unit.py
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "setup_firewall.sh"

PASS = []
FAIL = []
INFO = []


def section(t):
    print("\n" + "=" * 66)
    print(" " + t)
    print("=" * 66)


def check(cond, name, detail=""):
    if cond:
        PASS.append(name)
        print("  [PASS] " + name)
    else:
        FAIL.append((name, detail))
        print("  [FAIL] " + name)
        if detail:
            d = detail if isinstance(detail, str) else str(detail)
            for line in d.strip().splitlines()[-12:]:
                print("         | " + line[:160])


def note(t):
    INFO.append(t)
    print("  [NOTE] " + t)


def posix(p):
    s = Path(p).as_posix()
    m = re.match(r"^([A-Za-z]):/(.*)$", s)
    return "/%s/%s" % (m.group(1).lower(), m.group(2)) if m else s


# --------------------------------------------------------------------------
# mock 命令（写成可执行脚本）
# --------------------------------------------------------------------------
MOCKS = {}

MOCKS["id"] = r"""#!/bin/bash
case "${1:-}" in
    -u) echo 0 ;;
    *)  echo "uid=0(root) gid=0(root) groups=0(root)" ;;
esac
exit 0
"""

MOCKS["_rec"] = r"""#!/bin/bash
# 记录调用；$FWCALL_LOG 由外层注入
printf '%s\n' "$0 $*" >> "${FWCALL_LOG:-/dev/null}"
"""

MOCKS["iptables"] = r"""#!/bin/bash
# 带状态的 iptables mock：-C 查询真实反映 -A/-I 记录，避免 ipt_detach 空转
BIN="$(basename "$0")"
LOG="${FWCALL_LOG:-/dev/null}"; ST="${MOCK_STATE:-/dev/null}"
printf '%s %s\n' "$BIN" "$*" >> "$LOG"
[ "${MOCK_MISSING:-}" = "$BIN" ] && exit 127
for a in "$@"; do
    case "$a" in
        --version) echo "$BIN v1.8.7 (${MOCK_IPT_VARIANT:-legacy})"; exit 0 ;;
    esac
done
[ "$BIN" = "ip6tables" ] && [ "${MOCK_V6:-0}" != "1" ] && exit 1
[ "${1:-}" = "-m" ] && exit 0                      # iptables -m conntrack -h

tbl="filter"; args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -t) tbl="${2:-filter}"; shift 2 ;;
        *)  args+=("$1"); shift ;;
    esac
done
op="${args[0]:-}"

pol() {
    case "$1" in
        INPUT)   echo "${MOCK_POL_INPUT:-DROP}" ;;
        FORWARD) echo "${MOCK_POL_FORWARD:-ACCEPT}" ;;
        *)       echo ACCEPT ;;
    esac
}
builtin_chain() {
    case "$1" in
        INPUT|OUTPUT|FORWARD) return 0 ;;
        DOCKER-USER|DOCKER)   [ "${MOCK_DOCKER:-0}" = "1" ] && return 0; return 1 ;;
    esac
    grep -qxF "CHAIN|$tbl|$1" "$ST" 2>/dev/null
}

case "$op" in
    -S)
        if [ -z "${args[1]:-}" ]; then
            printf -- '-P INPUT %s\n-P FORWARD %s\n-P OUTPUT ACCEPT\n' "$(pol INPUT)" "$(pol FORWARD)"
            [ -n "${MOCK_EXTRA_RULES:-}" ] && printf '%s\n' "$MOCK_EXTRA_RULES"
            exit 0
        fi
        printf -- '-P %s %s\n' "${args[1]}" "$(pol "${args[1]}")"
        exit 0 ;;
    -L|-nL|-n|-v)
        ch="${args[1]:-}"
        case "$ch" in ''|-*) exit 0 ;; esac        # 未指定链 = 列出全部, 必定成功
        builtin_chain "$ch" && exit 0
        exit 1 ;;
    -N) echo "CHAIN|$tbl|${args[1]:-}" >> "$ST"; exit 0 ;;
    -F) awk -v p="R|$tbl|${args[1]:-}|" 'index($0,p)!=1' "$ST" > "${ST}.t" 2>/dev/null
        mv "${ST}.t" "$ST" 2>/dev/null; exit 0 ;;
    -X) awk -F'|' -v k="CHAIN|$tbl|${args[1]:-}" '$0!=k' "$ST" > "${ST}.t" 2>/dev/null
        mv "${ST}.t" "$ST" 2>/dev/null; exit 0 ;;
    -Z) exit 0 ;;
    -P) echo "POL|$tbl|${args[1]:-}|${args[2]:-}" >> "$ST"; exit 0 ;;
    -C|-A|-I|-D)
        chain="${args[1]:-}"; rest=()
        for a in "${args[@]:2}"; do
            case "$a" in ''|*[!0-9]*) rest+=("$a") ;; esac     # 丢掉 -I 的位置序号
        done
        key="$tbl|$chain|${rest[*]}"
        case "$op" in
            -C) grep -qxF "R|$key" "$ST" 2>/dev/null && exit 0; exit 1 ;;
            -A|-I) echo "R|$key" >> "$ST"; exit 0 ;;
            -D) grep -vxF "R|$key" "$ST" > "${ST}.t" 2>/dev/null
                mv "${ST}.t" "$ST" 2>/dev/null; exit 0 ;;
        esac ;;
esac
exit 0
"""

MOCKS["ip6tables"] = "@same@"

MOCKS["iptables-save"] = r"""#!/bin/bash
printf 'iptables-save %s\n' "$*" >> "${FWCALL_LOG:-/dev/null}"
echo "# MOCK iptables-save  (family=v4)"
echo "*filter"
echo "-P INPUT ${MOCK_POL_INPUT:-DROP}"
echo "COMMIT"
"""

MOCKS["ip6tables-save"] = r"""#!/bin/bash
printf 'ip6tables-save %s\n' "$*" >> "${FWCALL_LOG:-/dev/null}"
echo "# MOCK ip6tables-save  (family=v6)"
echo "*filter"
echo "-P INPUT DROP"
echo "COMMIT"
"""

MOCKS["iptables-restore"] = r"""#!/bin/bash
printf 'iptables-restore %s\n' "$*" >> "${FWCALL_LOG:-/dev/null}"
c="$(cat)"
printf '%s' "$c" >> "${FWCALL_LOG}.v4in"
[ -n "$c" ] || exit 1
case "$c" in *MOCK\ ip6tables-save*) echo "iptables-restore: 无法解析 IPv6 规则集" >&2; exit 1 ;; esac
echo "iptables-restore ok"
"""

MOCKS["ip6tables-restore"] = r"""#!/bin/bash
printf 'ip6tables-restore %s\n' "$*" >> "${FWCALL_LOG:-/dev/null}"
c="$(cat)"
printf '%s' "$c" >> "${FWCALL_LOG}.v6in"
case "$c" in
    *MOCK\ ip6tables-save*) echo "ip6tables-restore ok"; exit 0 ;;
    "") exit 1 ;;
esac
echo "ip6tables-restore: 输入不是 IPv6 规则集，拒绝加载" >&2
exit 1
"""

MOCKS["nft"] = r"""#!/bin/bash
printf 'nft %s\n' "$*" >> "${FWCALL_LOG:-/dev/null}"
[ "${MOCK_MISSING:-}" = "nft" ] && exit 127
case "${1:-}" in
    list)
        case "${2:-}" in
            ruleset) [ "${MOCK_NFT_ACTIVE:-0}" = "1" ] && printf 'table inet filter {\n}\n'
                     exit 0 ;;
            table)   [ "${MOCK_NFT_TABLE:-0}" = "1" ] && { printf 'table inet fw_setup {\n}\n'; exit 0; }
                     echo "No such file or directory" >&2; exit 1 ;;
        esac ;;
    delete) exit 0 ;;
    -f)
        if [ -r "${2:-}" ]; then
            cp "${2}" "${FWCALL_LOG}.ruleset"
            [ "${MOCK_NFT_LOAD_RC:-0}" = "0" ] && exit 0
            echo "Error: syntax error, unexpected newline" >&2; exit 1
        fi
        exit 1 ;;
esac
exit 0
"""

MOCKS["ufw"] = r"""#!/bin/bash
printf 'ufw %s\n' "$*" >> "${FWCALL_LOG:-/dev/null}"
[ "${MOCK_MISSING:-}" = "ufw" ] && exit 127
case "${1:-}" in
    --help) echo "usage: ufw [--dry-run] [delete] [insert NUM] allow|deny|reject|limit [in|out] [comment COMMENT]"; exit 0 ;;
    status) printf 'Status: %s\n' "${MOCK_UFW_STATE:-inactive}"
            [ "${MOCK_UFW_STATE:-inactive}" = "active" ] && printf 'Default: deny (incoming), allow (outgoing)\n'
            exit 0 ;;
esac
[ "${MOCK_UFW_FAIL:-}" = "1" ] && case "$*" in *allow*|*deny*|*reject*) exit 1 ;; esac
exit 0
"""

MOCKS["firewall-cmd"] = r"""#!/bin/bash
printf 'firewall-cmd %s\n' "$*" >> "${FWCALL_LOG:-/dev/null}"
[ "${MOCK_MISSING:-}" = "firewall-cmd" ] && exit 127
for a in "$@"; do
    case "$a" in
        --state) [ "${MOCK_FWD_STATE:-not-running}" = "RUNNING" ] && { echo running; exit 0; }
                 echo "not running" >&2; exit 1 ;;
        --get-default-zone) echo public; exit 0 ;;
        --get-target)       echo "${MOCK_FWD_TARGET:-default}"; exit 0 ;;
        --list-all|--list-all-zones) echo "public"; exit 0 ;;
        --query-rich-rule=*) exit "${MOCK_FWD_QUERY_RC:-1}" ;;
    esac
done
case "$*" in
    *--reload*) exit "${MOCK_FWD_RELOAD_RC:-0}" ;;
    *--query-port=*|*--query-service=*|*--query-source=*)
        exit "${MOCK_FWD_QUERY_RC:-1}" ;;
esac
exit 0
"""

MOCKS["systemctl"] = r"""#!/bin/bash
printf 'systemctl %s\n' "$*" >> "${FWCALL_LOG:-/dev/null}"
case "$*" in
    *list-unit-files*)
        [ "${MOCK_HAVE_IPT_SVC:-0}" = "1" ] && echo "iptables.service    enabled enabled"
        [ "${MOCK_HAVE_UFW_SVC:-0}" = "1" ] && echo "ufw.service         enabled enabled"
        exit 0 ;;
esac
exit 0
"""

MOCKS["service"] = r"""#!/bin/bash
printf 'service %s\n' "$*" >> "${FWCALL_LOG:-/dev/null}"
exit 0
"""

MOCKS["netfilter-persistent"] = r"""#!/bin/bash
printf 'netfilter-persistent %s\n' "$*" >> "${FWCALL_LOG:-/dev/null}"
exit 0
"""

MOCKS["docker"] = r"""#!/bin/bash
exit 0
"""


class Env(object):
    """一次性沙箱：临时目录 + mock bin + 改写后的脚本副本"""

    def __init__(self, missing=(), extra_present=()):
        self.root = Path(tempfile.mkdtemp(prefix="fwunit_"))
        self.bin = self.root / "bin"
        self.bin.mkdir(parents=True)
        self.log = self.root / "calls.log"
        self.state = self.root / "state"
        self.conf = self.root / "etc" / "fw-setup"

        # 写入 mock（-: 表示默认可用，missing 表示该场景下不可用）
        for name, body in MOCKS.items():
            if name == "_rec":
                continue
            if body == "@same@":
                continue                     # ip6tables 与 iptables 共用同一份脚本
            if name == "netfilter-persistent" and "netfilter-persistent" not in extra_present:
                if "netfilter-persistent" not in missing:
                    continue          # 默认不提供，模拟 Debian 常见情况
            if name == "docker" and "docker" not in extra_present:
                continue
            if name in missing:
                continue              # 命令不存在
            p = self.bin / name
            p.write_text(body, encoding="utf-8", newline="\n")
            try:
                os.chmod(p, 0o755)
            except OSError:
                pass
        # ip6tables 复用 iptables 的脚本（内部按 $0 区分）
        if "ip6tables" not in missing and "iptables" not in missing:
            p = self.bin / "ip6tables"
            p.write_text(MOCKS["iptables"], encoding="utf-8", newline="\n")
            try:
                os.chmod(p, 0o755)
            except OSError:
                pass

        src = SRC.read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
        # 1) CONF_DIR 指向临时目录
        src = src.replace('readonly CONF_DIR="/etc/fw-setup"',
                          'readonly CONF_DIR="%s"' % posix(self.conf))
        # 2) 去掉尾部入口，便于直接调函数
        self.lib = self.root / "fw_lib.sh"
        lines = [l for l in src.splitlines()
                 if l.strip() not in ('main "$@"', 'ensure_root "$@"')]
        self.lib.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
        # 3) 保留入口的完整副本（用于菜单行为验证）
        self.full = self.root / "fw_full.sh"
        self.full.write_text(src, encoding="utf-8", newline="\n")

    # ---- 运行一段测试体 ----
    def run(self, body, env=None, stdin="", timeout=240, lib=True):
        e = dict(os.environ)
        e["PATH"] = posix(self.bin) + ":/usr/bin:/bin"
        e["FWCALL_LOG"] = posix(self.log)
        e["MOCK_STATE"] = posix(self.state)
        e["BASH_ENV"] = ""
        e.pop("ENV", None)
        if env:
            e.update({k: str(v) for k, v in env.items()})
        try:
            self.state.write_text("", encoding="utf-8")
        except OSError:
            pass
        # 每轮都从干净的配置目录开始（否则上一轮的 rules.dsl 会影响下一轮判定）
        shutil.rmtree(self.conf.parent, ignore_errors=True)
        # 清空上一轮记录（保留本轮产生的 *.v4in / .ruleset 供断言读取）
        self.log.write_text("", encoding="utf-8")
        for p in self.root.glob("calls.log.*"):
            try:
                p.unlink()
            except OSError:
                pass
        target = self.lib if lib else self.full
        prog = 'set -o pipefail\nexport FWCALL_LOG=%s\nsource "%s"\n%s\n' % (
            q(posix(self.log)), posix(target), body)
        try:
            r = subprocess.run(["bash", "-c", prog], env=e, cwd=str(self.root),
                               input=stdin.encode(), capture_output=True, timeout=timeout)
            return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")
        except subprocess.TimeoutExpired:
            return None, "", "TIMEOUT"

    def calls(self):
        try:
            return self.log.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    def cleanup_log(self):
        for p in self.root.glob("calls.log*"):
            if p.name != "calls.log":
                try:
                    p.unlink()
                except OSError:
                    pass
        try:
            self.log.write_text("", encoding="utf-8")
        except OSError:
            pass

    def rules(self):
        try:
            return (self.conf / "rules.dsl").read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


def q(s):
    return "'" + str(s).replace("'", "'\\''") + "'"


def call_lines(log, *needles):
    out = []
    for l in log.splitlines():
        if all(n in l for n in needles):
            out.append(l)
    return out


# ==========================================================================
section("1. 静态检查")
# ==========================================================================
src = SRC.read_text(encoding="utf-8", errors="replace")

r = subprocess.run(["bash", "-n", str(SRC)], capture_output=True)
check(r.returncode == 0, "bash -n 语法检查通过", r.stderr.decode("utf-8", "replace"))
check(src.startswith("#!/usr/bin/env bash"), "shebang 为 /usr/bin/env bash")
check("set -uo pipefail" in src and "\nset -e" not in src,
      "使用 set -uo pipefail（不带 -e，靠 die 收口）")

for be in ("iptables", "nftables", "firewalld", "ufw"):
    miss = [h for h in ("precheck", "apply", "persist", "status", "reset")
            if ("be_%s_%s()" % (be, h)) not in src]
    check(not miss, "后端 %s 的五个钩子齐备" % be, "缺: %s" % miss)

# 绝不 flush 内建链
builtin_flush = re.findall(r'-F\s+(INPUT|OUTPUT|FORWARD)\b', src)
check(not builtin_flush, "源码中不存在对内建链的 -F（保护 Docker / 既有规则）",
      str(builtin_flush))
check("-P FORWARD" in src and "FWD_POLICY" in src, "FORWARD 默认策略可控且默认 ACCEPT")
check("DOCKER-USER" in src, "对 Docker 场景有 DOCKER-USER 处理")

# ==========================================================================
section("2. DSL 存储层")
# ==========================================================================
env = Env(extra_present=("docker",))
rc, out, err = env.run('init_conf; echo "CONF=$CONF_DIR"; ls "$CONF_DIR"')
check(rc == 0 and "rules.dsl" in out and "policy.conf" in out and "sshguard.conf" in out,
      "init_conf 生成 rules.dsl / policy.conf / sshguard.conf", out + err)
check("IN_POLICY=DROP" in env.run('init_conf; echo "IN_POLICY=$IN_POLICY OUT_POLICY=$OUT_POLICY"')[1],
      "默认策略为 INPUT DROP / OUTPUT ACCEPT")

rc, out, err = env.run(
    'init_conf; dsl_add "in accept tcp 22 - -" >/dev/null; '
    'dsl_add "in accept tcp 22 - -"; echo "RC=$?"; grep -c . "$F_RULES"')
check("已存在" in out and "跳过" in out, "dsl_add 幂等：重复规则被跳过并告警", out + err)
check(out.count("in accept tcp 22 - -") >= 0 and env.rules().count("in accept tcp 22 - -") == 1,
      "dsl_add 幂等：文件里只出现一次", env.rules())

rc, out, err = env.run('init_conf; dsl_add "in accept tcp 22; rm -rf /" ; echo "RC=$?"')
check("RC=1" in out and "非法字符" in (out + err), "dsl_add 拒绝 shell 元字符注入", out + err)

rc, out, err = env.run('init_conf; dsl_add ""; echo "RC=$?"; dsl_add "   "; echo "RC2=$?"; '
                       'echo "LINES=$(grep -c "^in " "$F_RULES" || true)"')
check("RC=1" in out and "RC2=1" in out and "规则为空" in (out + err) and "LINES=0" in out,
      "dsl_add 拒绝空行/纯空白（且不往规则文件里写空行）", out + err)

rc, out, err = env.run(
    'init_conf; dsl_add "in accept tcp 22 - -" >/dev/null; '
    'dsl_add "in accept tcp 80 - -" >/dev/null; echo "N=$(count_rules "$F_RULES")"')
check("N=2" in out, "count_rules 不计注释与空行", out)

# --- dsl_list / dsl_delete 编号一致性（含缩进注释）---
body = r'''
init_conf
dsl_add "in accept tcp 22 - -" >/dev/null
dsl_add "in accept tcp 80 - -" >/dev/null
printf '   # 手工加的缩进注释\n' >> "$F_RULES"
dsl_add "in accept tcp 443 - -" >/dev/null
echo "=====LIST====="
dsl_list
'''
rc, out, err = env.run(body)
lst = out.split("=====LIST=====")[-1]
rows = [l.split() for l in lst.splitlines()
        if re.match(r"^\s+\d+\s+(in|out)\s", l)]
check(len(rows) == 3, "dsl_list 列出 3 条规则", lst)
check(bool(rows) and rows[-1][:5] == ["3", "in", "accept", "tcp", "443"],
      "dsl_list 第 3 行是 443（缩进注释不参与编号）", lst)

# 删除第 2 条（应为 80）
rc, out, err = env.run(
    'init_conf; dsl_add "in accept tcp 22 - -" >/dev/null; '
    'dsl_add "in accept tcp 80 - -" >/dev/null; '
    'dsl_add "in accept tcp 443 - -" >/dev/null; '
    'printf "2\\ny\\n" | dsl_delete; echo "----"; grep -E "^in " "$F_RULES"')
left = [l for l in out.splitlines() if l.startswith("in ")]
check(left == ["in accept tcp 22 - -", "in accept tcp 443 - -"],
      "dsl_delete 按编号删中间一条，删的是正确那条", out + err)

# 删除唯一一条（会暴露 grep -v 返回 1 导致 mv 不执行）
rc, out, err = env.run(
    'init_conf; dsl_add "in accept tcp 22 - -" >/dev/null; '
    'printf "1\\ny\\n" | dsl_delete; echo "----"; grep -cE "^in " "$F_RULES"')
check(re.search(r"----\s*\n0\b", out) or "0" == (out.split("----")[-1].strip()),
      "dsl_delete 删除最后一条规则后文件确实为空", out + err)

# 更严的形状: rules.dsl 里**只有**规则行（没有注释/空行兜底）时, grep -v 会返回 1,
# 老写法 `grep ... > tmp && mv` 会因为短路而删不掉
rc, out, err = env.run(
    'init_conf; printf "in accept tcp 22 - -\\n" > "$F_RULES"; '
    'printf "1\\ny\\n" | dsl_delete; echo "----"; wc -l < "$F_RULES"')
check(out.split("----")[-1].strip() == "0",
      "dsl_delete 在文件只剩规则行时也能删干净 (grep 返回 1 不吞掉删除)", out + err)

# ==========================================================================
section("3. 后端探测优先级")
# ==========================================================================

def detect(envkw, mocks=None):
    e = Env(**envkw)
    rc, out, err = e.run('detect_env; detect_backend; echo "BACKEND=$FW_BACKEND"; echo "REASON=$FW_BACKEND_REASON"',
                         env=mocks or {})
    be = ""
    m = re.search(r"BACKEND=(\S+)", out)
    if m:
        be = m.group(1)
    e.close()
    return be, out + err, rc


be, o, rc = detect(dict(), {})
check(be == "iptables", "仅 legacy iptables（无自定义规则）-> iptables", o)

be, o, rc = detect({}, {"MOCK_IPT_VARIANT": "nf_tables"})
check(be == "nftables", "iptables 为 nf_tables 变体 -> nftables", o)

be, o, rc = detect(dict(extra_present=("docker",)), {"MOCK_IPT_VARIANT": "nf_tables"})
check(be == "nftables", "nft 变体优先于普通 iptables（Docker 环境同样）", o)

be, o, rc = detect({}, {"MOCK_FWD_STATE": "RUNNING"})
check(be == "firewalld", "firewalld running 优先级最高", o)

be, o, rc = detect({}, {"MOCK_UFW_STATE": "active"})
check(be == "ufw", "ufw active 优先于 iptables", o)

be, o, rc = detect({}, {"MOCK_POL_INPUT": "DROP", "MOCK_EXTRA_RULES": "-A INPUT -s 1.2.3.4 -j DROP"})
check(be == "iptables", "legacy iptables 有自定义规则 -> iptables", o)

be, o, rc = detect({}, {"MOCK_NFT_ACTIVE": "1", "MOCK_IPT_VARIANT": "nf_tables"})
check(be == "nftables", "nftables 有活跃规则集时可被选中", o)

# 只有 nft（无 iptables）
be, o, rc = detect(dict(missing=("iptables", "ip6tables")), {"MOCK_NFT_ACTIVE": "1"})
check(be == "nftables", "仅有 nftables（无 iptables）-> nftables", o)

# 无任何受支持后端
env2 = Env(missing=("iptables", "ip6tables", "nft", "firewall-cmd", "ufw"))
rc, out, err = env2.run('detect_env; detect_backend; echo "BACKEND=$FW_BACKEND"')
check(rc != 0 and "BACKEND=" not in out and "未检测到任何受支持的防火墙方案" in (out + err),
      "无任何受支持后端时报错退出（不是静默继续）", out + err)
env2.close()

# firewalld 装了没跑 -> 告警
env3 = Env()
rc, out, err = env3.run('detect_env; detect_backend; echo "B=$FW_BACKEND"',
                        env={"MOCK_FWD_STATE": "not-running"})
check("已安装但未运行" in out, "firewalld 已安装未运行时给出覆盖风险告警", out)
env3.close()

# ==========================================================================
section("4. 规则翻译（DSL -> 各后端原生语法）")
# ==========================================================================
env = Env()
rc, out, err = env.run(r'''
echo "A1=[$(ipt_args tcp 22 - -)]"
echo "A2=[$(ipt_args tcp 80,443 - -)]"
echo "A3=[$(ipt_args tcp 8000:9000 - -)]"
echo "A4=[$(ipt_args any - 10.0.0.0/8 -)]"
echo "A5=[$(ipt_args tcp - - 1.2.3.4)]"
echo "N1=[$(nft_port_expr 80,443)]"
echo "N2=[$(nft_port_expr 8000:9000)]"
echo "N3=[$(nft_port_expr 22)]"
echo "R1=[$(_nft_rule_lines input no in drop any - - -)]"
echo "R2=[$(_nft_rule_lines input no in reject tcp 22 - -)]"
echo "R3=[$(_nft_rule_lines input yes in accept tcp 22 10.0.0.0/8 -)]"
echo "U1=[$(ufw_args in accept tcp 22 - -)]"
echo "U2=[$(ufw_args in accept tcp 22 10.0.0.0/8 -)]"
echo "U3=[$(ufw_args out drop tcp 25 - 1.2.3.4)]"
echo "U4=[$(ufw_args in accept any - - -)]"
''')
g = dict(re.findall(r"(\w+)=\[(.*?)\]", out))

check(g.get("A1") == "-p tcp -m tcp --dport 22", "ipt_args 单端口 -> -m tcp --dport", out)
check(g.get("A2") == "-p tcp -m multiport --dports 80,443", "ipt_args 多端口 -> multiport", out)
check(g.get("A3") == "-p tcp -m multiport --dports 8000:9000", "ipt_args 范围 -> multiport", out)
check(g.get("A4") == "-s 10.0.0.0/8", "ipt_args any 协议只带源地址", out)
check(g.get("A5") == "-d 1.2.3.4 -p tcp", "ipt_args 目的地址", out)
check(g.get("N1") == "{ 80, 443 }", "nft_port_expr 多端口 -> 集合字面量", out)
check(g.get("N2") == "8000-9000", "nft_port_expr 范围 -> 连字符", out)
check(g.get("N3") == "22", "nft_port_expr 单端口原样", out)
check("drop" in g.get("R1", "") and "l4proto" in g.get("R1", ""),
      "_nft_rule_lines 空条件时补 meta l4proto 全集（避免误伤）", out)
check(g.get("R2") == "tcp dport 22 reject with icmpx type admin-prohibited",
      "_nft_rule_lines reject 用 icmpx（inet 表可用）", out)
check(g.get("R3") == "ip saddr 10.0.0.0/8 tcp dport 22 accept",
      "_nft_rule_lines 源+端口组合正确", out)
check(g.get("U1") == "allow 22/tcp", "ufw_args 纯单端口用简写", out)
check(g.get("U2") == "allow proto tcp from 10.0.0.0/8 to any port 22",
      "ufw_args 带来源用完整语法", out)
check(g.get("U3") == "deny out proto tcp to 1.2.3.4 port 25",
      "ufw_args 出站拒绝", out)
check(g.get("U4") == "allow", "ufw_args 全放行", out)
env.close()

# ==========================================================================
section("5. iptables 后端应用行为")
# ==========================================================================
env = Env(extra_present=("docker",))


def run_apply(e, body, mocks=None):
    return e.run('detect_env; detect_backend; init_conf; ' + body, env=mocks)


rc, out, err = run_apply(env, 'be_iptables_apply; echo "RC=$?"; '
                              'echo "DIAG v6=$HAS_V6 need=$NEED_V6 backend=$FW_BACKEND"',
                         {"MOCK_DOCKER": "1", "MOCK_V6": "1"})
log = env.calls()
check("RC=0" in out, "iptables 全量应用返回 0", out + err)
check(not any(re.search(r"-F\s+(INPUT|OUTPUT|FORWARD)\b", l) for l in log.splitlines()),
      "应用过程未 flush 内建链 INPUT/OUTPUT/FORWARD", "\n".join(
          [l for l in log.splitlines() if re.search(r"-F\s+(INPUT|OUTPUT|FORWARD)", l)]))
check(bool(call_lines(log, "-P INPUT DROP")), "INPUT 默认策略按 policy.conf 下发", log[-500:])
check(bool(call_lines(log, "-P FORWARD ACCEPT")), "FORWARD 默认策略保持 ACCEPT（Docker 安全）", log[-500:])
check(bool(call_lines(log, "-I DOCKER-USER 1 -j FW-IN-BLOCK")),
      "Docker 场景在 DOCKER-USER 挂载规则", log[-800:])
check(bool(call_lines(log, "-N FW-IN-ALLOW")) and bool(call_lines(log, "-N FW-IN-BLOCK")),
      "四个自定义链按需创建", log[:800])

# BLOCK 必须在 ALLOW 之前挂到 INPUT（-I ... 1 后插入的位于链首）
ins = [l for l in log.splitlines() if "-I INPUT 1" in l]
bybin = {}
for l in ins:
    bybin.setdefault(l.split()[0], []).append(l)
check(bool(bybin) and all(v[-1].endswith("-j FW-IN-BLOCK") for v in bybin.values()),
      "-I INPUT 1 顺序：先 ALLOW 后 BLOCK -> BLOCK 位于链首（封禁优先）", "\n".join(ins))
ins_out = [l for l in log.splitlines() if "-I OUTPUT 1" in l]
bybin2 = {}
for l in ins_out:
    bybin2.setdefault(l.split()[0], []).append(l)
check(bool(bybin2) and all(v[-1].endswith("-j FW-OUT-BLOCK") for v in bybin2.values()),
      "-I OUTPUT 1 顺序同样保证 BLOCK 在前", "\n".join(ins_out))
check(bool(call_lines(log, "ip6tables", "-P INPUT DROP")), "开启 IPv6 时同时下发 ip6tables 规则",
      out + err)
check(bool(call_lines(log, "FW-IN-ALLOW", "-i lo -j ACCEPT")), "loopback 放行")
check(any("ipv6-icmp" in l for l in log.splitlines()), "IPv6 下放行 ICMPv6（邻居发现依赖）",
      "\n".join(l for l in log.splitlines() if "icmp" in l))

# 用户规则落到自定义链
rc, out, err = run_apply(env, 'init_conf; dsl_add "in accept tcp 8080 - -" >/dev/null; '
                              'dsl_add "in drop any - 203.0.113.7 -" >/dev/null; be_iptables_apply >/dev/null; echo OK',
                         {"MOCK_V6": "0"})
log = env.calls()
check(bool(call_lines(log, "FW-IN-ALLOW", "--dport 8080")),
      "DSL accept 规则落到 FW-IN-ALLOW 链", "\n".join(call_lines(log, "8080")))
check(bool(call_lines(log, "FW-IN-BLOCK", "-s 203.0.113.7", "-j DROP")),
      "DSL drop 规则落到 FW-IN-BLOCK 链", "\n".join(call_lines(log, "203.0.113")))
check(not any("recent" in l for l in log.splitlines())
      and not call_lines(log, "-A FW-IN-ALLOW", "-j FW-SSHGUARD"),
      "未启用 sshguard 时不生成 recent 规则、也不挂 sshguard 链",
      "\n".join(call_lines(log, "FW-SSHGUARD")))

# SSH 防暴破
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; sed -i "s/^ENABLED=0/ENABLED=1/" "$F_SSHGUARD"; '
    '. "$F_SSHGUARD"; be_iptables_apply >/dev/null; echo OK', env={"MOCK_V6": "0"})
log = env.calls()
check(any("--hitcount 5" in l for l in log.splitlines()),
      "启用 sshguard 时写入 recent --hitcount 规则", "\n".join(call_lines(log, "recent")))
check(bool(call_lines(log, "-A FW-IN-ALLOW", "-j FW-SSHGUARD")),
      "FW-SSHGUARD 链挂入 FW-IN-ALLOW", "\n".join(call_lines(log, "FW-SSHGUARD")))

# 出站严格模式
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; sed -i "s/^OUT_POLICY=ACCEPT/OUT_POLICY=DROP/" "$F_POLICY"; '
    '. "$F_POLICY"; be_iptables_apply >/dev/null; echo OK', env={"MOCK_V6": "0"})
log = env.calls()
check(bool(call_lines(log, "-P OUTPUT DROP")) and bool(call_lines(log, "FW-OUT-ALLOW", "--dport 53")),
      "OUT_POLICY=DROP 时下发 -P OUTPUT DROP 并保留 DNS 白名单", log[-600:])

# 反复应用是否堆叠（幂等）
env4 = Env()
rc, out, err = env4.run(
    'detect_env; detect_backend; init_conf; dsl_add "in accept tcp 22 - -" >/dev/null; '
    'be_iptables_apply >/dev/null; be_iptables_apply >/dev/null; echo OK',
    env={"MOCK_V6": "0"})
st = env4.state.read_text(encoding="utf-8", errors="replace")
for chain, desc in (("FW-IN-ALLOW", "入站放行链"), ("FW-IN-BLOCK", "入站封禁链")):
    n = st.count("R|filter|%s|-i lo -j ACCEPT" % chain) if chain == "FW-IN-ALLOW" else 0
check("OK" in out, "连续两次应用均可完成", out + err)
check(st.count("R|filter|INPUT|-j FW-IN-ALLOW") == 1,
      "连续两次应用后 INPUT 挂载点只有 1 条（先 -C 探测再删，不堆叠）",
      "\n".join(l for l in st.splitlines() if "INPUT|" in l))
check(st.count("R|filter|INPUT|-j FW-IN-BLOCK") == 1,
      "连续两次应用后 FW-IN-BLOCK 挂载点只有 1 条", "\n".join(l for l in st.splitlines() if "FW-IN-BLOCK" in l))
check(st.count("R|filter|FW-IN-ALLOW|-i lo -j ACCEPT") == 1,
      "链内规则同样不重复（detach 后重建）",
      "计数=%d\n%s" % (st.count("R|filter|FW-IN-ALLOW|-i lo -j ACCEPT"),
                       "\n".join(l for l in st.splitlines() if "-i lo -j ACCEPT" in l)))
env4.close()
env.close()

# ==========================================================================
section("6. nftables 后端应用行为")
# ==========================================================================
env = Env()
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; '
    'dsl_add "in accept tcp 22 - -" >/dev/null; '
    'dsl_add "in drop any - 203.0.113.7 -" >/dev/null; '
    'dsl_add "out drop tcp 25 - 1.2.3.4" >/dev/null; '
    'be_nftables_apply; echo "RC=$?"',
    env={"MOCK_IPT_VARIANT": "nf_tables", "MOCK_MISSING": "iptables"})
rs = ""
try:
    rs = (env.root / "calls.log.ruleset").read_text(encoding="utf-8", errors="replace")
except OSError:
    rs = ""
check("RC=0" in out, "nftables 应用返回 0", out + err)
check("table inet fw_setup" in rs, "生成 inet fw_setup 表", rs[:400])
check(rs.count("type filter hook input") == 2, "入站两条链（block + allow）", rs)
check(re.search(r"chain in_block[\s\S]*?priority -20", rs) is not None,
      "in_block 优先级 -20 先于 in_allow(-10)", rs)
check("iifname \"lo\" accept" in rs and "ct state established,related accept" in rs,
      "loopback 与已建立连接放行", rs)
check("icmpv6 type {" in rs, "放行 ICMPv6（否则 IPv6 直接断网）", rs)
check("ip saddr 203.0.113.7 drop" in rs, "nft 封禁规则翻译正确", rs)
check("ip daddr 1.2.3.4 tcp dport 25 drop" in rs, "nft 出站封禁翻译正确", rs)
check("tcp dport 22 accept" in rs, "nft 放行规则翻译正确", rs)

# 加载失败要打印规则集并以非零返回
env2 = Env()
rc, out, err = env2.run('detect_env; detect_backend; init_conf; be_nftables_apply; echo "RC=$?"',
                        env={"MOCK_IPT_VARIANT": "nf_tables", "MOCK_NFT_LOAD_RC": "1",
                             "MOCK_MISSING": "iptables"})
check("RC=1" in out and "table inet fw_setup" in (out + err),
      "nft 加载失败时回显规则集并返回非零", out + err)
env2.close()

# OUT_POLICY=DROP
env3 = Env()
rc, out, err = env3.run(
    'detect_env; detect_backend; init_conf; sed -i "s/^OUT_POLICY=ACCEPT/OUT_POLICY=DROP/" "$F_POLICY"; '
    '. "$F_POLICY"; be_nftables_apply; echo "RC=$?"',
    env={"MOCK_IPT_VARIANT": "nf_tables", "MOCK_MISSING": "iptables"})
try:
    rs3 = (env3.root / "calls.log.ruleset").read_text(encoding="utf-8", errors="replace")
except OSError:
    rs3 = ""
check("udp dport 53 accept" in rs3 and re.search(r"chain out_allow[\s\S]*\n\s*drop\n", rs3),
      "nft 出站严格模式保留 DNS 并末尾 drop", rs3)
env3.close()
env.close()

# ==========================================================================
section("7. firewalld 后端应用行为")
# ==========================================================================
env = Env()
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; '
    'dsl_add "in accept tcp 80 - -" >/dev/null; '
    'dsl_add "in accept tcp 8080,8443 - -" >/dev/null; '
    'dsl_add "in accept any - 10.0.0.0/8 -" >/dev/null; '
    'dsl_add "in drop tcp 3306 - -" >/dev/null; '
    'dsl_add "out drop tcp 25 - 1.2.3.4" >/dev/null; '
    'be_firewalld_apply; echo "RC=$?"', env={"MOCK_FWD_STATE": "RUNNING"})
log = env.calls()
check("RC=0" in out, "firewalld 应用返回 0", out + err)
check(bool(call_lines(log, "--add-port=80/tcp")) and bool(call_lines(log, "--add-port=8080/tcp")),
      "纯端口规则走 --add-port（可读性最好）", "\n".join(call_lines(log, "--add-port")))
check(bool(call_lines(log, "--add-rich-rule=rule family=\"ipv4\" source address=\"10.0.0.0/8\" accept")),
      "来源放行用 rich rule 显式 accept（而非 --add-source）", "\n".join(call_lines(log, "rich-rule")))
check('--add-rich-rule=rule family="ipv4" port port="3306" protocol="tcp" drop' in log,
      "封禁端口用 rich rule drop", "\n".join(call_lines(log, "3306")))
check("不原生支持出站过滤" in out and bool(call_lines(log, "--direct --add-rule ipv4 filter OUTPUT 0")),
      "出站规则降级为 --direct 并明确告警", out + "\n" + "\n".join(call_lines(log, "--direct")))
check(bool(call_lines(log, "--set-target=DROP")) or "不支持 --get-target" in out,
      "zone target 按 IN_POLICY 设置", "\n".join(call_lines(log, "target")))
check(bool(call_lines(log, "--reload")), "应用结束后 reload", log[-400:])
env.close()

env = Env()
rc, out, err = env.run('detect_env; detect_backend; init_conf; be_firewalld_apply; echo "RC=$?"',
                       env={"MOCK_FWD_STATE": "RUNNING", "MOCK_FWD_RELOAD_RC": "1"})
check(rc != 0 and "reload 失败" in (out + err),
      "reload 失败时 die 中止（不假装成功）", out + err)
env.close()

# 未运行时预检失败
env = Env()
rc, out, err = env.run('detect_env; detect_backend; init_conf; be_firewalld_precheck; echo "RC=$?"',
                       env={"MOCK_FWD_STATE": "not-running"})
check("RC=1" in out and "systemctl start firewalld" in (out + err),
      "firewalld 未运行时预检失败并给出启动指引", out + err)
env.close()

# ==========================================================================
section("8. ufw 后端应用行为")
# ==========================================================================
env = Env()
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; be_ufw_precheck; '
    'dsl_add "in accept tcp 22 - -" >/dev/null; '
    'be_ufw_apply; echo "RC=$?"', env={"MOCK_UFW_STATE": "active"})
log = env.calls()
check("RC=0" in out, "ufw 应用返回 0", out + err)
check(bool(call_lines(log, "ufw default deny incoming")), "入站默认 deny", log)
check(bool(call_lines(log, "ufw default allow outgoing")), "出站默认 allow（不误断出网）", log)
check(bool(call_lines(log, "ufw allow 22/tcp comment")), "规则带 comment 便于精确删除", log)
env.close()

# 未启用：默认不 enable
env = Env()
rc, out, err = env.run('detect_env; detect_backend; init_conf; printf "\\n" | be_ufw_apply; echo "RC=$?"',
                       env={"MOCK_UFW_STATE": "inactive"})
log = env.calls()
check("尚未生效" in out and not call_lines(log, "ufw --force enable"),
      "ufw 未启用时提示，且直接回车不会擅自 enable（安全默认）", out + "\n" + log[-300:])
env.close()

env = Env()
rc, out, err = env.run('detect_env; detect_backend; init_conf; printf "y\\n" | be_ufw_apply; echo "RC=$?"',
                       env={"MOCK_UFW_STATE": "inactive"})
check(bool(call_lines(env.calls(), "ufw --force enable")), "回答 y 时才执行 ufw enable")
env.close()

# 规则失败要打印原始 DSL 行
env = Env()
rc, out, err = env.run('detect_env; detect_backend; init_conf; dsl_add "in accept tcp 9999 - -" >/dev/null; '
                       'be_ufw_apply; echo "RC=$?"',
                       env={"MOCK_UFW_STATE": "active", "MOCK_UFW_FAIL": "1"})
check("原始规则" in (out + err), "单条规则失败时回显原始 DSL 行便于定位", (out + err)[-500:])
env.close()

# ==========================================================================
section("9. 防 SSH 锁死")
# ==========================================================================
env = Env()
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; dsl_add "in accept tcp 22 - -" >/dev/null; '
    'ensure_ssh_allowed; echo "RC=$?"', env={"MOCK_EXTRA_RULES": ""})
check("RC=0" in out and "是否立即放行" not in out,
      "已放行 SSH 端口时不打扰用户，直接通过", out + err)

# 注意: bash 的 `read -p` 提示语只在 stdin 是 tty 时才打印, 管道/DEVNULL 下
# 一律不显示。所以这里断言"发出提示 + 默认放行生效"这两个可观测行为, 不去
# 断言提示语文本 —— 否则在非 tty 的自动化环境里必然假失败。
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; dsl_add "in accept tcp 80 - -" >/dev/null; '
    'printf "\\n" | ensure_ssh_allowed; echo "RC=$?";'
    'echo "----"; grep -E "^in " "$F_RULES"')
check("RC=0" in out and "没有放行 SSH 端口" in (out + err)
      and "in accept tcp 22 - -" in out,
      "未放行 SSH 时提示并（回车默认）放行 SSH 端口，写入规则", out + err)

rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; printf "n\\n" | ensure_ssh_allowed; echo "RC=$?"')
check("RC=1" in out, "回答 n 时返回 1（由调用方中止）", out + err)

rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; dsl_add "in accept tcp 8080 - -" >/dev/null; '
    'SSH_PORT=22; printf "\\n" | ensure_ssh_allowed; echo "RC=$?"', env={"MOCK_V6": "0"})
check("RC=0" in out, "自定义端口场景同样能放行", out + err)

# 仅"整段来源放行"时是否也算已放行 —— 会掩盖跨网段锁死风险。
# 用显式 SSH_CONNECTION 固定"我是从 192.168.1.50 连进来的"，分两种来源判定。
SSHCONN = "192.168.1.50 51234 192.168.1.101 22"

rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; dsl_add "in accept any - 10.0.0.0/8 -" >/dev/null; '
    'ensure_ssh_allowed; echo "RC=$?"', env={"SSH_CONNECTION": SSHCONN})
check("但来源范围不包含当前连接来源" in (out + err)
      and "当前连接来源: 192.168.1.50" in (out + err),
      "SSH 来源被限在别的网段时必须告警（否则应用后跨网段锁死）", out + err)

# 反向: 来源确实覆盖当前连接 -> 应当静默通过, 不再打扰
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; dsl_add "in accept any - 192.168.1.0/24 -" >/dev/null; '
    'ensure_ssh_allowed; echo "RC=$?"', env={"SSH_CONNECTION": SSHCONN})
check("RC=0" in out and "来源范围不包含" not in (out + err)
      and "没有放行 SSH 端口" not in (out + err),
      "来源网段覆盖当前连接时静默通过（不误报）", out + err)

# 边界: /32 精确命中
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; dsl_add "in accept tcp 22 - 192.168.1.50/32 -" >/dev/null; '
    'ensure_ssh_allowed; echo "RC=$?"', env={"SSH_CONNECTION": SSHCONN})
check("RC=0" in out and "来源范围不包含" not in (out + err),
      "来源 /32 精确命中也算已放行", out + err)
env.close()

# ==========================================================================
section("10. 应用编排与试运行回滚")
# ==========================================================================
env = Env()
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; printf "n\\n" | apply_with_confirm; echo "RC=$?"',
    env={"MOCK_V6": "0"})
log = env.calls()
check("RC=1" in out and "已中止" in (out + err), "无 SSH 放行且拒绝 -> 中止（不应用规则）", out + err)
check(not call_lines(log, "-P INPUT DROP"), "中止时确实没有下发任何防火墙规则", log[-400:])
env.close()

env = Env()
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; dsl_add "in accept tcp 22 - -" >/dev/null; '
    'printf "y\\n" | apply_with_confirm; echo "RC=$?"', env={"MOCK_V6": "0"})
check("已自动备份到" in out and "RC=0" in out, "应用前自动备份且应用成功", out[-400:])
check("非交互环境，跳过确认" in out and "规则已保留" in out,
      "非交互（管道）下不等待确认，避免卡死（是有意的降级分支）", out[-300:])
check("read -r -t" in src and "CONFIRM_TIMEOUT=20" in src,
      "交互环境下有 20 秒确认超时 + 自动回滚")
env.close()

# ==========================================================================
section("11. 持久化与开机自启")
# ==========================================================================
env = Env()
rc, out, err = env.run('detect_persist_mode; echo "MODE=$PERSIST_MODE"',
                       env={"MOCK_HAVE_IPT_SVC": "1"})
check("MODE=iptables-services" in out, "检测到 iptables.service -> iptables-services", out)
env.close()

env = Env(extra_present=("netfilter-persistent",))
rc, out, err = env.run('detect_persist_mode; echo "MODE=$PERSIST_MODE"')
check("MODE=netfilter-persistent" in out, "检测到 netfilter-persistent -> netfilter-persistent", out)
env.close()

env = Env()
rc, out, err = env.run('detect_persist_mode; echo "MODE=$PERSIST_MODE"')
check("MODE=manual-rules" in out or "MODE=systemd-unit" in out,
      "无专用服务但有 systemd -> 不会退化成 rc-local", out)
check("install_boot_service" in src and "iptables-custom.service" in src,
      "systemd-unit 分支安装 iptables-custom.service")
env.close()

env = Env()
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; detect_persist_mode; persist_iptables; echo "RC=$?"; '
    'echo "DIAG v6=$HAS_V6 need=$NEED_V6 mode=$PERSIST_MODE"',
    env={"MOCK_V6": "1"})
log = env.calls()
check("RC=0" in out, "persist_iptables 在 systemd-unit 模式下成功", out + err)
check(bool(call_lines(log, "iptables-save")) and bool(call_lines(log, "ip6tables-save")),
      "持久化时 v4/v6 分别 save", out + err + "\n" + log)
env.close()

# ==========================================================================
section("12. 快照 / 回滚")
# ==========================================================================
env = Env()
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; echo "$FW_BACKEND"; '
    'snapshot_current "$CONF_DIR/snap.txt"; echo "RC=$?"; cat "$CONF_DIR/snap.txt"',
    env={"MOCK_IPT_VARIANT": "nf_tables", "MOCK_MISSING": "iptables",
         "MOCK_NFT_ACTIVE": "1"})
backend = ""
for ln in out.splitlines():
    if ln.strip() in ("iptables", "nftables", "firewalld", "ufw"):
        backend = ln.strip()
content = out.split("RC=")[-1]
check(backend == "nftables", "nf_tables 内核上探测到 nftables 后端", out[:300])
check("table inet filter" in content and "iptables-save" not in content,
      "nftables 前端的快照内容是 nft ruleset（而非 iptables-save 文本）", content[:300])
env.close()

env = Env()
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; dsl_add "in accept tcp 22 - -" >/dev/null; '
    'd="$(backup_rules pre-apply)"; echo "DIR=$d"; ls "$d"', env={"MOCK_V6": "1"})
check("rules.dsl" in out and "policy.conf" in out and "snapshot.txt" in out,
      "backup_rules 同时保存 DSL / 策略 / 运行时快照", out + err)
env.close()

env = Env()
rc, out, err = env.run(
    'detect_env; detect_backend; init_conf; detect_persist_mode; '
    'snapshot_current "$CONF_DIR/snap.txt"; restore_snapshot "$CONF_DIR/snap.txt"; echo "RC=$?"',
    env={"MOCK_V6": "1"})
v6in = ""
try:
    v6in = (env.root / "calls.log.v6in").read_text(encoding="utf-8", errors="replace")
except OSError:
    pass
check("MOCK ip6tables-save" in v6in,
      "iptables 回滚时喂给 ip6tables-restore 的是 IPv6 规则集", "v6 收到的内容:\n" + v6in[:300])
env.close()

# ==========================================================================
section("13. 状态显示")
# ==========================================================================
env = Env()
rc, out, err = env.run('detect_env; detect_backend; init_conf; be_iptables_status',
                       env={"MOCK_POL_INPUT": "DROP", "MOCK_POL_FORWARD": "ACCEPT", "MOCK_V6": "0"})
line = [l for l in out.splitlines() if l.strip().startswith("INPUT")]
check(bool(line) and "DROP" in line[0],
      "be_iptables_status 能正确显示 INPUT 默认策略", out[:400])
env.close()

# ==========================================================================
section("14. 交互菜单在输入耗尽时的行为")
# ==========================================================================
env = Env()
rc, out, err = env.run("", stdin="", timeout=10, lib=False)
check(rc is not None, "stdin 为 EOF 时脚本能自行退出（不会忙等）",
      "10 秒超时仍未退出 = 死循环；输出尾部:\n" + out[-300:])
env.close()

env = Env()
rc, out, err = env.run("", stdin="0\n", timeout=10, lib=False)
check(rc == 0, "正常输入 0 可退出", (out + err)[-300:])
env.close()

# ==========================================================================
print("\n" + "=" * 66)
print(" 结果: PASS=%d  FAIL=%d  NOTE=%d" % (len(PASS), len(FAIL), len(INFO)))
print("=" * 66)
if FAIL:
    print("\n未通过的检查（按顺序）:")
    for i, (n, d) in enumerate(FAIL, 1):
        print("  %2d) %s" % (i, n))
print()
sys.exit(1 if FAIL else 0)
