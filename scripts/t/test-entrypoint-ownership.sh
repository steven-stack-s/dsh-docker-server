#!/bin/sh
# ============================================================================
# test-entrypoint-ownership.sh — 首启"写者 vs 对齐者"时序门禁
#
# 背景（真机故障 2026-10-10）：entrypoint 的 root 首启块里，⑤b 以 root 写出
#   /data/dsh/profiles/web/cordis.patch.yml（该文件刻意 chmod 600），⑥ 随即降权到 uid 1000。
# 两者之间**没有任何属主对齐**，于是降权后的 dsh 读不了它：
#   Error: dsh: failed to read overlay /data/dsh/profiles/web/cordis.patch.yml: EACCES
# → profile 加载失败 → 自愈 4 次耗尽 → 置 lifeboat 标记 → 容器按 restart policy 重启后
# **停在 lifeboat**（healthy 但不是 web profile），用户必须手动 `docker restart` 一次才恢复。
# 这与 docs/zh-CN/01-快速开始.md 承诺的"首次启动秒级就绪"直接矛盾。
#
# 原设计的假设是错的：⑤b 上方注释写"写出的文件随后由**下一轮**的 ③ 属主对齐收尾"，
# 但首次启动在"下一轮"到来前就已自愈耗尽并落盘 lifeboat 标记，第二次启动被该标记接管去
# 启动救生舱 —— ③ 永远追不上 ⑤b 的写入。故 entrypoint 新增 ⑤c 就地兜底。
#
# 本门禁守护该时序，避免修复被无声回退（这正是本仓库反复吃过的"门禁恒绿而边界已失"）。
#
# 契约（缺一即红灯）：
#   P1 存在兜底：root 块内存在对 /data/dsh/profiles 的属主对齐（⑤c 的 find 形态）；
#   P2 顺序正确：remote_setup 调用 < ⑤c < 降权（exec setpriv）——
#      "对齐者晚于写者、且早于降权"三者缺一，故障即复现；
#   P3 幂等形态：⑤c 用"只改不符条目"的 find 表达，而非无差别 `chown -R`
#      （后者会让 NAS 上的大目录树每次启动都产生全量写）。
#
# 【为什么断言行号而不是行为】与 test-entrypoint-order.sh 同源：这类缺陷的本质就是
# "两个正确步骤的相对顺序错了"，单测各函数都过、集成才炸。行号是唯一能在无 docker 的
# CI 上静态判定顺序的手段。真机 e2e（首启一次即进 web）另行在验证机跑，见 CHANGELOG。
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
EP="$ROOT/scripts/entrypoint.sh"
[ -f "$EP" ] || { echo "FAIL-entrypoint-missing"; exit 1; }

fail() { echo "FAIL-$1: $2"; exit 1; }

# 只取非注释行（注释以 # 开头）—— 本文件与 entrypoint 里都大量引用这些路径与命令名，
# 若不过滤，删掉真代码后注释里的字样仍会撞绿。
code_lines() { grep -nE '^[[:space:]]*[^#[:space:]]' "$EP"; }

# --- P2 三个锚点的行号 -------------------------------------------------------
rs_line=$(code_lines | grep -E 'remote_setup' | head -n1 | cut -d: -f1 || true)
[ -n "$rs_line" ] || fail "remote-setup-call-not-found" "entrypoint no longer calls remote_setup (cannot locate ⑤b)"

drop_line=$(code_lines | grep -E 'exec setpriv' | head -n1 | cut -d: -f1 || true)
[ -n "$drop_line" ] || fail "drop-point-not-found" "entrypoint no longer drops privileges via 'exec setpriv' (cannot locate ⑥)"

# --- P1 兜底对齐必须存在，且形态正确（find + 只改不符条目）---------------------
c_line=$(code_lines | grep -E 'find /data/dsh/profiles' | head -n1 | cut -d: -f1 || true)
[ -n "$c_line" ] \
  || fail "no-post-setup-ownership-alignment" \
          "entrypoint has no ownership alignment for /data/dsh/profiles AFTER remote_setup and BEFORE the privilege drop — the 2026-10-10 EACCES/lifeboat first-boot defect is back"

c_clause=$(code_lines | grep -E 'find /data/dsh/profiles' | head -n1)
printf '%s' "$c_clause" | grep -q -- '-not -user' \
  || fail "alignment-not-differential" \
          "the post-setup alignment does not use the 'only entries that differ' form (-not -user); a blanket chown would rewrite the whole tree on every boot"

# --- P1b 权限位归一必须同时存在 ----------------------------------------------
# 【为什么单独断言】光有 chown 不够：chown 只改属主、**不改权限位**，历史遗留的 0000
# （或无 u+r）文件即使归了运行用户，属主自己也读不了 —— ③b 的注释记录了 2026-09-17 的
# 同类真机故障（/data/dsh 下 104 个此类文件）。⑤c 面对的是 ⑤b 刚写的 600 文件，
# 少了这一条，cordis.patch.yml 仍可能以"属主对了但读不了"的形态漏过去。
code_lines | grep -qE 'find /data/dsh/profiles -not -perm -u\+r' \
  || fail "no-permission-normalization" \
          "the post-setup alignment has no owner-readable-bit normalization (find /data/dsh/profiles -not -perm -u+r); chown alone does not fix mode-0000 files"

# 兜底对齐段落里不得出现 chown -R（③ 处允许，因为那里刚 mkdir 出全新目录；
# ⑤c 面对的是已存在的 profile 树，无差别写是性能倒退）。
c_tail=$(code_lines | awk -F: -v s="$c_line" '$1+0 >= s+0 && $1+0 <= s+8' || true)
printf '%s\n' "$c_tail" | grep -qE 'chown[[:space:]]+-R' \
  && fail "alignment-uses-recursive-chown" \
          "the post-setup alignment uses 'chown -R'; use the differential find form instead"

# --- P2 时序断言 -------------------------------------------------------------
[ "$rs_line" -lt "$c_line" ] \
  || fail "alignment-precedes-writer" \
          "ownership alignment is at line $c_line but remote_setup (the writer) is at line $rs_line — alignment must come AFTER the writer"

[ "$c_line" -lt "$drop_line" ] \
  || fail "alignment-after-privilege-drop" \
          "ownership alignment is at line $c_line but privileges are dropped at line $drop_line — alignment must come BEFORE the drop, or the files stay root-owned while dsh runs as uid ${USER_UID:-1000}"

echo 'ALL-PASS'
