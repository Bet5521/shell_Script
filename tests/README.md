# setup_firewall.sh 验证套件

给 `setup_firewall.sh`（多后端统一防火墙脚本）做**全 mock 行为验证**：
不起真防火墙、不改本机任何规则、不需要 root，可在 Windows / Git Bash / Linux 上跑。

## 用法

```bash
python tests/fw_unit.py            # 全量（14 章节，~130 项断言）
python tests/fw_unit.py 2>&1 | tail -30
```

单节调试（全量在 Windows 上要十几分钟，改一处只想跑相关章节时用）：

```bash
python tests/_fwsec.py 9 12        # 只跑第 9、12 节
python tests/_fwsec.py             # 等价于全量
```

> `_fwsec.py` 会把 `fw_unit.py` 按 `section("...")` 切开，只 exec 指定章节。
> 新增章节后不用改它。

## 做法（为什么可信）

1. **不改被测文件逻辑**：把 `setup_firewall.sh` 复制到临时目录，
   仅替换 `CONF_DIR=/etc/fw-setup` 这一行，并去掉尾部 `main "$@"`，
   以便直接调用内部函数。
2. **mock 命令做成可执行文件**放进临时 `bin`，前置到 `PATH` ——
   这样 `command -v nft` / `has_cmd iptables` 的语义与真实环境一致
   （用 shell 函数 mock 会在跨层 `bash -c` 时丢掉，且 `set -u` 下易崩）。
3. **`iptables` mock 是有状态的**：`-A/-I/-N/-P` 记录进状态文件，
   `-C` 去查状态文件 → 才能真实反映"重复执行是否堆叠规则"。
   （早期版本让 `-C` 恒返回 0，结果 `ipt_detach` 的 `while -C; do -D` 空转，
   整轮测试直接 TIMEOUT。）
4. 断言全部在 Python 侧读 mock 的调用日志（`FWCALL_LOG`）与状态文件完成。

## 章节

| # | 章节 | 关注点 |
|---|------|--------|
| 1 | 静态检查 | 语法、`set -euo pipefail` 使用、危险写法 |
| 2 | DSL 存储层 | 增删查、去重、空行/注释判定、注入字符拦截 |
| 3 | 后端探测优先级 | firewalld > ufw > nftables > iptables，未运行的不算 |
| 4 | 规则翻译 | DSL 6 列 → 各后端原生语法 |
| 5 | iptables 应用 | 链/策略/规则下发、IPv6 分支 |
| 6 | nftables 应用 | `table inet fw_setup`、链优先级、失败回显 |
| 7 | firewalld 应用 | zone / rich rule / 持久化 |
| 8 | ufw 应用 | 默认 deny、comment、不擅自 enable |
| 9 | 防 SSH 锁死 | 端口命中、来源网段包含性、告警与默认放行 |
| 10 | 应用编排与回滚 | 备份、试运行、20 秒确认超时自动回滚 |
| 11 | 持久化 | iptables-services / netfilter-persistent / systemd-unit |
| 12 | 快照 / 回滚 | 后端各自的快照内容、IPv4/IPv6 分离 |
| 13 | 状态显示 | 默认策略读取 |
| 14 | 菜单 EOF 行为 | stdin 耗尽时能自行退出（不忙等） |

## 本次验证发现并修复的缺陷

验证是"脚本先跑、断言后置"。以下 8 处都是**脚本真实缺陷**（不是测试写错）：

| # | 现象 | 根因 | 修复 |
|---|------|------|------|
| 1 | 空串被当成一条规则写进 `rules.dsl` | 判空写成 `${line##*[!$' \t\n']*}`，空串匹配不上该模式，`-n` 为假 → 不报错 | 改为 `[ -z "${line//[[:space:]]/}" ]` |
| 2 | `dsl_list` 看到的编号 ≠ 输入编号删掉的那条 | 缩进注释（`   # xxx`）在 list 里被跳过、在 delete 里被当成规则 | 抽出 `_dsl_skip()`，`dsl_list`/`dsl_delete`/`ensure_ssh_allowed` 共用同一判据 |
| 3 | 提示"已删除"，但最后一条规则还在 | `grep -vxF ... > tmp && mv`，grep 无保留行时返回 1 → `mv` 被短路 | `\|\| true` 后无条件 `mv` |
| 4 | 规则是 `in accept any - 10.0.0.0/8 -` 而你在 192.168.1.x 时**不告警**，应用后把自己关在门外 | 旧逻辑把"任意带来源的 accept"直接当成已放行 | 新增纯 bash `ip_in_cidr()`（不依赖 ipcalc/python），来源不含当前 `SSH_CLIENT_IP` 时明确告警 |
| 5 | nftables 后端回滚时 `nft -f` 静默失败 | `snapshot_current` 的分支写成 `iptables|nftables)`，nft 分支永远进不去，快照存的是 `iptables-save` 文本 | nft 分支前置；`iptables` 分支单独写 `<f>.v6` |
| 6 | iptables 回滚时 IPv6 静默丢失 | `ip6tables-restore < <iptables-save 文本>` | 优先读 `<f>.v6`，缺失时告警而不是假装成功 |
| 7 | 状态页默认策略列**恒为空** | `iptables -S INPUT` 字段是 `$1="-P" $2=链名 $3=策略`，判据写成 `$2=="-P"` | 改为 `$1=="-P"` |
| 8 | 菜单在 stdin 耗尽时**空转卡死**（无任何输出，Ctrl-C 才能停） | `while true` + `read` 失败留空值，分支不匹配也不退出 | 新增 `read_menu_choice`：read 失败即告警、`save_env` 后 `exit 0`；5 处菜单统一替换 |

另外两处是**验证器自身**的问题，一并记下来免得下次踩：

- firewalld mock 默认状态写成 RUNNING，导致所有"非 firewalld"探测被吃掉
  → 默认改为 `not-running`（要 firewalld 的场景显式给）。
- 第 9 节原来断言 `read -p` 的提示语文本。**bash 的 `read -p` 只在 stdin 是 tty
  时才打印提示**，管道/`/dev/null` 下一律不显示 → 非 tty 环境必然假失败。
  改为断言可观测行为（告警文本 + 规则是否落盘 + 返回值）。

## 已知限制（这些没被覆盖）

- **只有 mock**：真实 `firewalld`/`ufw` 的运行时语义（zone 优先级、rich rule 求值）、
  内核转发是否真的生效、`sshguard` 实际拦截效果，都未验证。
- IPv6 只验证"v4/v6 分开存、喂给正确的 restore 命令"，没验证 IPv6 规则语义。
- 第 14 节的超时是 10 秒。机器负载高时（例如同时在跑其它测试）会假失败，
  单独重跑即可确认：`python tests/_fwsec.py 14`。
- 真机首次使用仍建议先备份再应用：脚本自带快照/回滚与 20 秒确认超时，
  但那是"应用后能救回来"，不是"提前知道会怎样"。
