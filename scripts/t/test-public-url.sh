#!/bin/sh
# ============================================================================
# test-public-url.sh — DSH_PUBLIC_URL 解析（--public-url 参数构造）
#
# 背景：dsh 0.2.1-alpha.1 起支持 --public-url，用于公告对外访问根（修「日志与模型把
# GUI 地址说成容器内 127.0.0.1:3081」）。但 0.2.0-rc.2 及更早**不认识**该选项，
# 未知选项会以退出码 1 启动失败（真机实测：`error: unknown option '--public-url'`）
# —— 在本项目里这会连锁消耗自愈预算，甚至把用同一份 seed dsh 的救生舱一起拖崩。
#
# 【归因更正 2026-10-08】报错**不是**「dsh-cmdline 未开 allowUnknownOption」：
#   dsh-cmdline 根本不声明选项（只做 exitOverride + configureOutput）；启动器
#   dsh/lib/bin.js 反而明确开了 .allowUnknownOption().passThroughOptions()，未知选项被
#   **透传**给 app；真正报错的是 **web-app 的 startup program**。结论不变（守卫必要），
#   但别再按"启动器拦的"这个错误模型去删守卫。
#
# 契约：接受单个绝对 http(s) URL；拒绝非 http(s)、含凭据(@)、含查询/片段(?/#)、
#       含空白或非法字符（含通配符/命令替换字符）的输入；非法项丢弃并记审计日志。
#       输出 " --public-url <url>"（空输入 -> 空输出）。尾斜杠不在此处理，
#       由 dsh 侧 parsePublicUrl 归一化。
# ============================================================================
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME"
. "$HERE/../librescue.sh"
fail() { echo "FAIL-$1"; exit 1; }

command -v rescue_public_url_args >/dev/null 2>&1 || fail helper-missing

# 1) 正常值（IP + 端口）原样透传，带前导空格以便直接拼进命令行
out=$(rescue_public_url_args 'http://192.168.1.50:3080/')
[ "$out" = " --public-url http://192.168.1.50:3080/" ] || fail normal-ip

# 2) 域名 + https
out=$(rescue_public_url_args 'https://app.example.com/')
[ "$out" = " --public-url https://app.example.com/" ] || fail normal-domain

# 3) 带路径前缀必须原样保留（dsh 侧负责归一化尾斜杠，容器侧不擅自改写）
out=$(rescue_public_url_args 'https://app.example.com/dsh/')
[ "$out" = " --public-url https://app.example.com/dsh/" ] || fail prefix-kept

# 4) 无尾斜杠的带前缀值也必须原样透传（不补、不删）
out=$(rescue_public_url_args 'https://app.example.com/dsh')
[ "$out" = " --public-url https://app.example.com/dsh" ] || fail prefix-no-slash

# 5) 空输入 -> 空输出
out=$(rescue_public_url_args '')
[ -z "$out" ] || { echo "FAIL-empty: [$out]"; exit 1; }

# 6) 非 http(s) scheme 必须丢弃（dsh 只接受 http/https）
for bad in 'ftp://x/' 'file:///etc/passwd' '192.168.1.50:3080' 'javascript:alert(1)'; do
  out=$(rescue_public_url_args "$bad")
  [ -z "$out" ] || { echo "FAIL-scheme: [$bad] -> [$out]"; exit 1; }
done

# 7) 含凭据(@)必须丢弃 —— dsh 的 parsePublicUrl 明确拒绝 userinfo
for bad in 'http://u@192.168.1.50:3080/' 'http://user:pw@host/' 'http://@host/'; do
  out=$(rescue_public_url_args "$bad")
  [ -z "$out" ] || { echo "FAIL-userinfo: [$bad] -> [$out]"; exit 1; }
done

# 8) 含查询/片段必须丢弃 —— dsh 明确拒绝 ? 与 #
for bad in 'http://host/?a=1' 'http://host/#frag' 'http://host/p?x=1'; do
  out=$(rescue_public_url_args "$bad")
  [ -z "$out" ] || { echo "FAIL-query-fragment: [$bad] -> [$out]"; exit 1; }
done

# 9) 危险字符必须丢弃：空白、命令替换、通配符、引号、反斜杠、换行
#    这些一旦进了命令行，要么把参数拆成多个、要么被 glob 展开成文件名。
out=$(rescue_public_url_args 'http://host/a b')
[ -z "$out" ] || { echo "FAIL-space: [$out]"; exit 1; }
out=$(rescue_public_url_args 'http://host/$(rm -rf /)')
[ -z "$out" ] || { echo "FAIL-substitution: [$out]"; exit 1; }
out=$(rescue_public_url_args 'http://host/*')
[ -z "$out" ] || { echo "FAIL-wildcard: [$out]"; exit 1; }
out=$(rescue_public_url_args 'http://host/"q"')
[ -z "$out" ] || { echo "FAIL-quote: [$out]"; exit 1; }
out=$(rescue_public_url_args 'http://host/a\b')
[ -z "$out" ] || { echo "FAIL-backslash: [$out]"; exit 1; }

# 10) 通配符输入必须得到空输出（单独断言：防止 case 里 glob 被展开成文件名而假绿）
out=$(rescue_public_url_args '*')
[ -z "$out" ] || { echo "FAIL-wildcard-only: [$out]"; exit 1; }

# 11) 合法项必须被保留 —— 与上面"全部丢弃"的断言互为对照，防止实现退化成恒返回空
out=$(rescue_public_url_args 'http://10.0.0.1:8080/dsh/')
case "$out" in
  *'--public-url http://10.0.0.1:8080/dsh/'*) : ;;
  *) fail valid-dropped ;;
esac

echo ALL-PASS