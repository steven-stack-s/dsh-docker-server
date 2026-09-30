#!/bin/sh
# ============================================================================
# test-lifeboat-marker.sh — 进救生舱时，"原因"必须如实来自标记文件
#
# 背景（真机 2026-09-30）：entrypoint 读一次性标记进救生舱时，把 reason **写死**成
# "auto fallback: self-heal exhausted"。而标记文件里其实记着真实来源
# （manual / self-heal exhausted）与写入时刻。后果是排查被整个带偏：
# 用户手动请求、或上一次启动留下的陈旧标记，日志也报"自愈耗尽" ——
# 而那一轮启动的监督主循环压根没跑过（日志里没有任何 attempt / 自愈输出）。
#
# 契约（跨文件，两边必须一致）：
#   librescue.sh 的 rescue_lifeboat_request 写入
#       {"requested":"<iso8601>","reason":"<manual|self-heal exhausted>"}
#   entrypoint.sh 读标记时**必须解析**这两个字段，并都反映到 boot_lifeboat 的入参
#   （= 容器日志与 rescue.log 的内容）。
#
# 本测试**执行 entrypoint 里的真实代码段**（从文件里 awk 提取，不是手抄副本），
# 故代码一改就会被这里盯住 —— 只做 grep 的静态断言无法证明"读出来了没有"。
# ============================================================================
set -eu
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
EP="$ROOT/scripts/entrypoint.sh"
LIB="$ROOT/scripts/librescue.sh"
fail() { echo "FAIL-$1${2:+: $2}"; exit 1; }

[ -f "$EP" ] || fail entrypoint-missing
[ -f "$LIB" ] || fail librescue-missing

# ---- ① 静态：不得再硬编码那句文案 ----
if grep -qF 'boot_lifeboat "auto fallback: self-heal exhausted"' "$EP"; then
  fail hardcoded-reason "entrypoint 又把 lifeboat 的 reason 写死了（这正是被误导的根源）"
fi

# ---- ② 从 entrypoint 提取真实处理段 ----
# 范围：从 `_lb_state=` 到行首的 `fi`（内层 if 的 fi 有缩进，不会提前截断）。
BLOCK=$(awk '/^_lb_state=/,/^fi$/' "$EP")
[ -n "$BLOCK" ] || fail block-not-extracted
printf '%s\n' "$BLOCK" | grep -q '_lb_reason=' || fail block-missing-reason-read
printf '%s\n' "$BLOCK" | grep -q '_lb_when=' || fail block-missing-time-read
# 必须先读后清：rescue_lifeboat_clear 会删掉标记文件，顺序反了就什么也读不到。
# ⚠ 必须排除注释行：本段代码的注释里就写着 "rescue_lifeboat_clear"，
#   不排除会被当成一次调用，行号比较整个失真（本测试初版正是栽在这里）。
strip_comments() { grep -vE '^[0-9]+:[[:space:]]*#'; }
clear_ln=$(printf '%s\n' "$BLOCK" | grep -n 'rescue_lifeboat_clear' | strip_comments | head -n1 | cut -d: -f1)
when_ln=$(printf '%s\n' "$BLOCK" | grep -n '_lb_when=' | strip_comments | head -n1 | cut -d: -f1)
[ -n "$clear_ln" ] || fail block-missing-clear
[ -n "$when_ln" ] || fail block-missing-when
[ "$when_ln" -lt "$clear_ln" ] || fail clear-before-read
printf '%s\n' "$BLOCK" > "$T/block.sh"

# ---- ③ 执行真实代码段：librescue 写标记 → entrypoint 的块读它 ----
run_block() {
  _rb_home="$1"
  DSH_HOME="$_rb_home" sh -c '
    . "$1" || exit 1
    boot_lifeboat() { printf "BOOTED:%s\n" "$1"; }
    . "$2" || exit 1
  ' sh "$LIB" "$T/block.sh"
}

# 写标记：librescue 的真实实现（顺带验证它写的格式与 entrypoint 读的 sed 对得上）
# $1 = DSH_HOME；$2 = reason
write_marker() {
  DSH_HOME="$1" sh -c '. "$1"; rescue_lifeboat_request "$2"' sh "$LIB" "$2"
}

mkhome() { mkdir -p "$1/.rescue/state"; }

# --- manual：必须如实报 manual，且带上写入时刻；不得出现 self-heal 字样 ---
H1="$T/h1"; mkhome "$H1"
write_marker "$H1" manual
grep -q '"reason":"manual"' "$H1/.rescue/state/lifeboat-requested" || fail librescue-format-changed
out1=$(run_block "$H1" 2>&1)
printf '%s' "$out1" | grep -q 'BOOTED:auto fallback: manual' || fail manual-not-reported "$out1"
if printf '%s' "$out1" | grep -qi 'self-heal exhausted'; then
  fail manual-reported-as-selfheal "manual 标记被报成了自愈耗尽：$out1"
fi
printf '%s' "$out1" | grep -q 'marker written' || fail missing-marker-time "$out1"
# 一次性：读完后标记必须被消费掉
[ ! -f "$H1/.rescue/state/lifeboat-requested" ] || fail marker-not-cleared

# --- self-heal exhausted：如实报出（不能因为"不硬编码"就丢了正常路径）---
H2="$T/h2"; mkhome "$H2"
write_marker "$H2" "self-heal exhausted"
out2=$(run_block "$H2" 2>&1)
printf '%s' "$out2" | grep -q 'BOOTED:auto fallback: self-heal exhausted' || fail selfheal-not-reported "$out2"

# --- 标记损坏（有 requested 但无 reason）：兜底文案必须自曝是兜底，
#     不能伪装成一个"已确认的原因"（那又回到了说谎的老路）---
H3="$T/h3"; mkhome "$H3"
printf '{"requested":"2020-01-01T00:00:00+0800"}' > "$H3/.rescue/state/lifeboat-requested"
out3=$(run_block "$H3" 2>&1)
printf '%s' "$out3" | grep -q 'BOOTED:' || fail corrupt-block-failed "$out3"
printf '%s' "$out3" | grep -q 'unreadable marker' || fail corrupt-no-fallback-label "$out3"

# --- 标记完全损坏（非 JSON）：仍不得崩，且要标出兜底 ---
H4="$T/h4"; mkhome "$H4"
printf 'not json at all\n' > "$H4/.rescue/state/lifeboat-requested"
out4=$(run_block "$H4" 2>&1)
printf '%s' "$out4" | grep -q 'BOOTED:' || fail garbage-block-failed "$out4"
printf '%s' "$out4" | grep -q 'unreadable marker' || fail garbage-no-fallback-label "$out4"

# --- 时刻字段存在时，必须真的打印出来（否则"陈旧标记"无法一眼辨认）---
printf '%s' "$out2" | grep -qE 'BOOTED:.*\[marker written [0-9]{4}-[0-9]{2}-[0-9]{2}T' \
  || fail marker-time-not-formatted "$out2"

echo ALL-PASS
