#!/bin/sh
# ============================================================================
# test-web-entry-hint.sh — 「浏览器入口」提示函数
#
# 背景：dsh 在容器内只监听 127.0.0.1:$PORT_INNER，它打印的 URL 行与**给模型的系统提示**
# 都指向这个容器内地址（dsh 0.2.1 起才有 --public-url 公告对外真实地址）。用户与容器内的
# AI 都容易把 127.0.0.1:3081 当成可访问地址 —— 该提示的作用就是把这个差异显式写在启动日志里。
#
# 契约：$1 = 宿主侧对外端口（socat 监听），$2 = dsh 容器内监听端口。
#   - 对外端口必须来自参数（DSH_PORT 可改，硬编码 3080 即为 bug）
#   - 必须点明容器内地址及其"浏览器不可达"
#   - 不得夹带 token 等凭据
# ============================================================================
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export DSH_HOME="$T/home"
mkdir -p "$DSH_HOME"
. "$HERE/../librescue.sh"
fail() { echo "FAIL-$1"; exit 1; }

command -v rescue_web_entry_hint >/dev/null 2>&1 || fail helper-missing

# 1) 默认端口：对外 3080 / 容器内 3081
out=$(rescue_web_entry_hint 3080 3081)
case "$out" in *":3080"*) : ;; *) fail outer-port ;; esac
case "$out" in *"127.0.0.1:3081"*) : ;; *) fail inner-address ;; esac

# 2) 自定义对外端口必须被透传 —— 防止把 3080 写死（DSH_PORT 是可配的）
out=$(rescue_web_entry_hint 18080 3081)
case "$out" in *":18080"*) : ;; *) fail custom-outer-port ;; esac
case "$out" in *":3080"*) fail hardcoded-3080 ;; *) : ;; esac

# 3) 必须说明容器内地址从浏览器不可达（提示的全部意义所在）
out=$(rescue_web_entry_hint 3080 3081)
case "$out" in *container*) : ;; *) fail mentions-container ;; esac
case "$out" in *browser*) : ;; *) fail mentions-browser ;; esac

# 4) 不得夹带凭据（该行会进容器日志；启动 URL 里带进程 token，提示里绝不能带）
case "$out" in *token*) fail token-leak ;; *) : ;; esac

echo ALL-PASS