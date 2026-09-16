#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""只跑 fw_unit.py 的指定章节（Windows 上每跑一节要几十秒，全量太慢）。

用法: python tests/_fwsec.py 9 12      # 只跑第 9、12 节
      python tests/_fwsec.py           # 跑全部
"""
import re
import sys
from pathlib import Path

P = Path(__file__).resolve().parent / "fw_unit.py"
lines = P.read_text(encoding="utf-8").splitlines()
# 去掉结尾的汇总块（里面有 sys.exit，会把本 runner 一起终止）
for i in range(len(lines) - 1, 0, -1):
    if lines[i].strip() == 'print("\\n" + "=" * 66)':
        lines = lines[:i]
        break

idx = [i for i, l in enumerate(lines) if l.startswith('section("')]
preamble = "\n".join(lines[:idx[0]])
ns = {"__name__": "__main__", "__file__": str(P)}
exec(compile(preamble, "<preamble>", "exec"), ns)

want = set(sys.argv[1:])
for k, i in enumerate(idx):
    end = idx[k + 1] if k + 1 < len(idx) else len(lines)
    body = "\n".join(lines[i:end])
    title = re.search(r'^section\("([^"]+)"\)', body, re.M).group(1)
    no = title.split(".")[0].strip()
    if want and no not in want:
        continue
    exec(compile(body, "<sec%s>" % no, "exec"), ns)

print("\n==== PASS=%d FAIL=%d ====" % (len(ns["PASS"]), len(ns["FAIL"])))
for n in ns["PASS"]:
    print("  [PASS]", n)
for n, d in ns["FAIL"]:
    print("  [FAIL]", n)
    if d:
        for ln in str(d).strip().splitlines()[-8:]:
            print("         | " + ln[:160])
