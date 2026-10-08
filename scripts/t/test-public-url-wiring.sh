#!/bin/sh
# ============================================================================
# test-public-url-wiring.sh — --public-url 是否真的拼进了**每一处** dsh 启动命令行
#
# 背景（2026-10-08 评估发现的真实缺陷）：entrypoint.sh 算出 PUBLIC_URL_ARGS 并拼进了它自己
# 那两处启动点，但**默认主启动路径** rescue-supervise.sh 自行拼命令行，其 5 处 dsh 启动
# 一处都没带上该参数。后果是**静默失效 + 误导性日志**：用户设了 DSH_PUBLIC_URL，日志打印
# "[entrypoint] public URL: ..." 看起来已生效，而真正拉起 dsh 的进程从未收到该参数 ——
# 该功能唯一的用途（修「日志与模型把 GUI 地址说成容器内 127.0.0.1」）在绝大多数正常部署
# 下完全达不到。
#
# 为什么单测拦不住（这正是本门禁存在的理由）：test-public-url.sh / test-public-url-guard.sh
# 只测"参数构造函数本身"，全绿；没有任何测试断言"参数是否真的拼进了命令行"。这与
# test-entrypoint-order.sh 注释里描述的事故模式同源（单测全绿、真机失效）。
#
# 契约：
#   W1 scripts/rescue-supervise.sh 中**每一处** dsh 启动命令行都必须含 ${PUBLIC_URL_ARGS:-}
#   W2 scripts/entrypoint.sh    中**每一处** dsh 启动命令行都必须含 ${PUBLIC_URL_ARGS:-}
#   W3 引用必须用 ${PUBLIC_URL_ARGS:-} 形式（兼容 set -u；本文件会被独立 source 的测试
#      test-supervise-source.sh 覆盖该场景）
#   W4 启动点数量不得为 0（防止 grep 模式写错导致门禁恒绿 —— 这是"门禁本身失效"的兜底）
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fail() { echo "FAIL-$1"; exit 1; }

check_file() {
  _file="$1"; _label="$2"; _min="$3"
  [ -f "$_file" ] || fail "$_label-missing"

  # 收集真正"启动 dsh"的行：命令行里出现 `dsh --profile` 或 `exec dsh --profile`。
  # 排除注释行与日志文本行（elog/echo 里常引用同样的字样，例如
  # "probe-ready.js missing; supervision disabled - exec dsh directly"）。
  _starts=$(grep -nE '(^|[^[:alnum:]_])(exec )?dsh --profile' "$_file" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE '(elog|echo|printf)' \
    | cut -d: -f1 || true)

  _n=$(printf '%s\n' "$_starts" | grep -c . || true)
  [ "$_n" -ge "$_min" ] || fail "$_label-no-start-sites(head=$_n, expected>=$_min)"

  _bad=0
  for _ln in $_starts; do
    _text=$(sed -n "${_ln}p" "$_file")
    case "$_text" in
      *'${PUBLIC_URL_ARGS:-}'*) : ;;
      *)
        echo "FAIL $_label-line-$_ln: dsh start site does NOT carry \${PUBLIC_URL_ARGS:-}:"
        printf '    %s\n' "$_text"
        _bad=1
        ;;
    esac
  done
  [ "$_bad" -eq 0 ] || exit 1
  echo "  $_label: $_n start site(s), all wired"
}

# W1：监督主循环（默认启动路径）——5 处
check_file "$ROOT/scripts/rescue-supervise.sh" "rescue-supervise.sh" 5

# W2：entrypoint 自身的两处降级启动点
check_file "$ROOT/scripts/entrypoint.sh" "entrypoint.sh" 2

# W3：不得在 **dsh 启动命令行**里残留裸 $PUBLIC_URL_ARGS —— 独立 source 时 set -u 会报 unbound。
#     只检查启动点行本身，不做全文扫：全文扫会误伤普通变量判断
#     （如 entrypoint 里 `[ -n "$PUBLIC_URL_ARGS" ]` 是合法用法，与命令行拼接无关）。
for f in "$ROOT/scripts/rescue-supervise.sh" "$ROOT/scripts/entrypoint.sh"; do
  _starts=$(grep -nE '(^|[^[:alnum:]_])(exec )?dsh --profile' "$f" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE '(elog|echo|printf)' \
    | cut -d: -f1 || true)
  for _ln in $_starts; do
    _text=$(sed -n "${_ln}p" "$f")
    case "$_text" in
      *'$PUBLIC_URL_ARGS'*)
        case "$_text" in
          *'${PUBLIC_URL_ARGS:-}'*) : ;;
          *)
            echo "FAIL bare-PUBLIC_URL_ARGS at $(basename "$f"):$_ln (use \${PUBLIC_URL_ARGS:-}):"
            printf '    %s\n' "$_text"
            exit 1
            ;;
        esac
        ;;
    esac
  done
done
echo '  start sites use ${PUBLIC_URL_ARGS:-} (set -u safe)'

echo 'ALL-PASS'
