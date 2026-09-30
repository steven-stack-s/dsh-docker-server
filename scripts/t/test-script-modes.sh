#!/bin/sh
# ============================================================================
# test-script-modes.sh — 入口/测试脚本的可执行位门禁
#
# 背景：这些文件在 git 里曾经是 644（靠镜像 Dockerfile 的 chmod 赋权）。镜像内没问题，但
# clone 之后直接 ./rescue 或 ./scripts/t/test-x.sh 会 Permission denied —— 真机手工验证时
# 就踩到过（bind-mount 覆盖后容器里也丢了执行位）。这里把它变成红灯。
#
# 【为什么查 git index 而不是文件系统权限】2026-09-30 踩过一次，代价是 main 连续三次
#   构建失败：本仓库 `.git/config` 里是 **core.filemode=false**（bind mount / NAS 上常见），
#   git 会**忽略 chmod**，于是 `chmod +x` 之后 `git add` 并不记录模式变化 ——
#   本地文件系统是 755（门禁绿），CI 按 index 里的 644 落盘（门禁红）。
#   只查 `[ -x ]` 就永远抓不到这个差异，因为它测的是**本地**而不是**别人 clone 到的**东西。
#   改查 git index（= clone/checkout 后真正落盘的模式）后，本地与 CI 判断一致，
#   这类"本地绿、CI 红"当场可复现。修法见下方 usage。
#
# 约定：需要被"直接执行"的脚本必须带可执行位；被 source 的库（librescue / rescue-supervise /
# remote-setup）不需要，也不应该靠执行它们来工作。
#
# 新增测试脚本后如果本门禁报红（本地也一样会红），用：
#     git update-index --chmod=+x scripts/t/<你的脚本>.sh
# 而不是 `chmod +x`（后者在 core.filemode=false 下不入库）。
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

bad=0
check_exec() {
  [ -f "$ROOT/$1" ] || return 0
  # 优先读 git index 里的模式：那才是 clone / CI checkout 之后**真正落盘**的模式。
  mode=$(git -C "$ROOT" ls-files -s -- "$1" 2>/dev/null | awk '{print $1}')
  if [ -n "$mode" ]; then
    [ "$mode" = "100755" ] || { echo "FAIL not-executable-in-git: $1 (git index mode=$mode)"; bad=1; }
  else
    # 未纳入 git（本地临时文件等）时退回文件系统检查
    [ -x "$ROOT/$1" ] || { echo "FAIL not-executable: $1"; bad=1; }
  fi
}

# 需要直接执行的
check_exec scripts/entrypoint.sh
check_exec scripts/rescue
check_exec scripts/ci-image-tags.sh
check_exec scripts/logtag.js
check_exec scripts/logtee.js
# 会被 source 的库：显式断言它们**不该**被当成可直接执行的脚本（反过来也成立 ——
# 它们不需要 +x，所以这里不检查；仅留注释说明为何缺席上面的清单）
for f in scripts/t/*.sh; do
  [ -f "$f" ] || continue
  rel=${f#"$ROOT"/}
  check_exec "$rel"
done

[ "$bad" -eq 0 ] || exit 1
echo 'ALL-PASS'
