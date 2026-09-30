#!/bin/sh
# ============================================================================
# test-dockerfile-hygiene.sh — Dockerfile 与救援资产的通用卫生门禁
#
# 【本文件的由来】原 test-hmr-off.sh 是「关闭 profile HMR」的专用门禁。2026-09-30
#   本项目决定**不再干预 HMR**（理由见 entrypoint.sh 的「移除：曾在此把 profile 的
#   HMR 关掉」注释：崩溃根因由 NARB/tmpfs 两层修复，且实测该叠加层一直是零效果，
#   反而掩盖了"绑定不可用"这个本该暴露的信号）。专用门禁的主体随之消失，
#   但它里面夹着几条**与 HMR 无关的通用断言** —— 都是过去真机事故换来的，
#   不能跟着一起删。故迁到本文件，并补上反向断言锁住那次决定。
#
# 覆盖：
#   H1 RUN 续行内不得出现注释行（会被 shell 当注释，吞掉其后命令）
#   H2 救援资产必须对非属主可读（否则 uid 1000 的 dsh/rescue 读不到）
#   H3 不得再依赖 0.1.6-alpha.2 已删除的 patchReload 机制
#   H4 不得再出现 HMR 干预（HMR_OFF_PATCH / HMR_OFF_YML / hmr-off.yml）
#
# 需要：sh(dash)。无其他依赖。
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ENTRY="$ROOT/scripts/entrypoint.sh"
SUP="$ROOT/scripts/rescue-supervise.sh"
DFILE="$ROOT/Dockerfile"
LIFEBOAT="$ROOT/scripts/lifeboat.tmpl/package.json"
fail() { echo "FAIL-$1${2:+: $2}"; exit 1; }

for f in "$ENTRY" "$SUP" "$DFILE" "$LIFEBOAT"; do
  [ -f "$f" ] || fail "missing-file-$(basename "$f")"
done

# ---- H1) RUN 续行内不得出现注释行 ----
# 血泪：给救援资产加 chmod a+r 时就踩过 —— 注释写进续行，chmod a+r 与 ln -sf 整段被
# shell 吃掉，镜像静默丢掉 rescue 软链（而"本地单测全绿"）。
if awk '
  inrun && /^[[:space:]]*#/ { print "comment-in-run at line " NR ": " $0; bad = 1 }
  /^RUN /  { inrun = ($0 ~ /\\$/); next }
  inrun    { inrun = ($0 ~ /\\$/) }
  END      { exit bad }
' "$DFILE"; then :; else fail dockerfile-comment-inside-run-continuation; fi

# ---- H2) 救援资产必须对非属主可读 ----
# 真机实测 2026-09-18：COPY 保留源文件权限，而 umask 077 的构建机让资产在镜像内落成
# 0600 root —— 调用方（uid 1000）直接被拒，加固静默失效；而单测全绿，因为 git 只记录
# 644/755、正常 umask 下 checkout 出来恰好可读。故必须显式放开读权限。
grep -q 'chmod a+r /opt/dsh-rescue/' "$DFILE" || fail dockerfile-missing-rescue-assets-readable

# ---- H3) 反向：不得再依赖 alpha.2 已删除的 patchReload 机制 ----
# （存量 profile 里遗留该字段无影响；但 entrypoint/lifeboat 模板不得再靠它关 HMR）
if grep -q 'patchReload' "$ENTRY"; then
  # 允许出现在解释性注释里，但不允许出现在可执行语句/写入的 JSON 模板里
  grep -qE '^[^#]*patchReload' "$ENTRY" && fail entrypoint-relies-on-removed-patchreload
fi
grep -q 'patchReload' "$LIFEBOAT" && fail lifeboat-template-carries-removed-patchreload
# 旧的 sed 改写必须彻底消失（它是"绿着但已失效"的根源）
grep -qE 's/"patchReload"' "$ENTRY" && fail entrypoint-still-rewrites-patchreload

# ---- H4) 反向：不得再出现 HMR 干预（锁住 2026-09-30 的决定）----
# ⚠ 必须排除注释行：本仓库在 entrypoint / supervise 里**保留了解释"当初为何移除"的注释**，
#   那些注释会提到 HMR_OFF_PATCH / HMR_OFF_YML。断言只针对**可执行代码**
#   （用 ^[^#]* 前缀，即该行在 # 之前就出现了该标识符）。
# 为什么值得锁：一旦有人把代码或镜像资产加回来，"半恢复"（改了 entrypoint 却没改
# Dockerfile，或反之）比完全不恢复更危险 —— 它会以"看起来在关 HMR、实际没关"的
# 形式静默漂移，正是当初那次事故的翻版。
for f in "$ENTRY" "$SUP"; do
  if grep -qE '^[^#]*HMR_OFF_PATCH' "$f"; then
    fail "hmr-intervention-returned-$(basename "$f")" "HMR_OFF_PATCH 又出现在可执行路径里"
  fi
  if grep -qE '^[^#]*HMR_OFF_YML' "$f"; then
    fail "hmr-intervention-returned-$(basename "$f")" "HMR_OFF_YML 又出现在可执行路径里"
  fi
done
if grep -qE '^COPY .*hmr-off\.yml' "$DFILE"; then
  fail dockerfile-still-copies-hmr-off "Dockerfile 仍在 COPY hmr-off.yml"
fi
if [ -e "$ROOT/scripts/hmr-off.yml" ]; then
  fail hmr-off-file-still-present "scripts/hmr-off.yml 又出现了"
fi

echo 'ALL-PASS'
