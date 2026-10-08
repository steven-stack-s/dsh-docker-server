#!/bin/sh
# ============================================================================
# test-public-url-guard.sh — --public-url 的版本能力守卫
#
# 背景（安全关键）：dsh 0.2.0-rc.2 及更早**不认识** --public-url，未知选项会以退出码 1
# 启动失败（真机实测：`error: unknown option '--public-url'`）。而本项目里「启动失败」会
# 连锁消耗 RESCUE_START_TIMEOUT 与自愈预算，最坏把用同一份 seed dsh 的救生舱一起拖崩
# —— 用户就彻底失去 GUI。故必须按 dsh 版本决定是否追加该参数。
#
# 【归因更正 2026-10-08】报错**不是**「dsh-cmdline 未开 allowUnknownOption」：
#   dsh-cmdline 根本不声明选项（只做 exitOverride + configureOutput）；启动器
#   dsh/lib/bin.js 反而明确开了 .allowUnknownOption().passThroughOptions()，未知选项被
#   **透传**给 app；真正报错的是 **web-app 的 startup program**。结论不变（守卫必要），
#   但别再按"启动器拦的"这个错误模型去删守卫。
#
# 契约：rescue_supports_public_url <版本> 返回 0=支持 / 1=不支持。
#   起点由 DSH_PUBLIC_URL_MIN_VERSION 决定（默认 0.2.1-alpha.1）。
#   版本为空/读不到/ver_gt 缺失时，一律**保守返回不支持**（绝不因信息缺失而放行）。
# ============================================================================
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME"
. "$HERE/../vercmp.sh"
. "$HERE/../librescue.sh"
fail() { echo "FAIL-$1"; exit 1; }

command -v rescue_supports_public_url >/dev/null 2>&1 || fail helper-missing
command -v ver_gt >/dev/null 2>&1 || fail vercmp-missing

# 1) 起点及更新的版本必须判为支持（边界：与起点相等不算"更小"）
for v in 0.2.1-alpha.1 0.2.1-alpha.2 0.2.1-alpha.10 0.2.1-rc.1 0.2.1 0.2.2 0.3.0 1.0.0; do
  rescue_supports_public_url "$v" || { echo "FAIL-expected-support: $v"; exit 1; }
done

# 2) 早于起点的版本必须不支持 —— 第一个就是项目当前锁定的 0.2.0-rc.2（会崩的那个）
for v in 0.2.0-rc.2 0.2.0-rc.1 0.2.0 0.1.7-rc.2 0.1.0 0.0.1; do
  rescue_supports_public_url "$v" && { echo "FAIL-expected-reject: $v"; exit 1; }
done

# 3) 空/垃圾版本必须保守判为不支持（读不到版本时绝不能放行）
for v in '' 'unknown' 'garbage' 'v0.2.1'; do
  rescue_supports_public_url "$v" && { echo "FAIL-expected-reject-unknown: [$v]"; exit 1; }
done

# 4) 起点可被 DSH_PUBLIC_URL_MIN_VERSION 覆盖
DSH_PUBLIC_URL_MIN_VERSION=0.3.0
if rescue_supports_public_url 0.2.1-alpha.1; then fail custom-min-not-honored; fi
rescue_supports_public_url 0.3.0 || fail custom-min-equal
rescue_supports_public_url 0.3.1 || fail custom-min-newer
unset DSH_PUBLIC_URL_MIN_VERSION

# 5) ver_gt 不可用时必须保守返回"不支持"（不 source vercmp.sh 的子 shell 即模拟该场景）
if sh -c '. "'"$HERE"'/../librescue.sh"; rescue_supports_public_url 9.9.9' 2>/dev/null; then
  fail vercmp-missing-must-reject
fi

echo ALL-PASS