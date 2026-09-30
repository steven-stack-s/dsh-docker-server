#!/bin/sh
# ============================================================================
# test-remote-setup.sh — 默认认证插件整备（scripts/remote-setup.sh）的门禁
#
# 背景：v0.6.0 起镜像默认装认证插件并在首启创建管理员账号（随机 16 位密码）。
# 这条链路是**静默失败高发区**：
#   - 密码没生成/没打印 → 用户拿不到账号，只能删数据卷；
#   - 每轮启动都重新生成并打印 → 密码被写进每一次 docker logs（会被转发、归档、贴 issue）；
#   - 覆盖用户改过的账号 → 用户被锁在门外；
#   - 插件树复制不全（漏 node_modules，或漏 dsh.profile.bundles 登记）→ profile 起不来
#     → 自愈耗尽 → 进 lifeboat，而根因看不出来。
#
# 本测试**不依赖 docker、不联网、不改真实仓库**：全部在 mktemp 沙箱里构造假 DSH_HOME 与假 seed，
# 只断言可观察行为（补丁文件内容、日志输出、退出码）。
#
# 覆盖：
#   T1  密码生成器：长度恒 16、纯字母数字、多次调用不重复
#   T2  首启（无账号）：装插件 + 登记 bundle + 写 bootstrap 段 + 打印密码
#   T3  二次启动（账号已存在）：不打印密码、不覆盖既有 bootstrap、不改用户自己的 patch 内容
#   T4  幂等：连续两次 remote_setup，托管块只有一份（不重复追加）
#   T5  用户 patch 内容不被破坏（托管块之外的配置原样保留）
#   T6  显式密码（DSH_ADMIN_PASSWORD）：按用户给的值写入，且日志标注来源
#   T7  短密码（<6）：被拒绝并退回随机生成（否则插件 apply 时会 throw，让整棵 profile 起不来）
#   T8  DSH_SETUP_REMOTE=off：一个字节都不动
#   T9  seed 缺失（不带插件的镜像）：跳过且不报错、不创建 patch
#   T10 profile 里已有插件时不覆盖（用户手工升级过的版本被保留）
#   T11 source 本文件不得有顶层副作用（否则 entrypoint 一 source 就跑一遍主流程）
#   T12 Dockerfile 必须提供 seed 构建参数与 /opt/dsh-remote-seed，entrypoint 必须接线
# ============================================================================
set -u
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/remote-setup.sh"
[ -f "$SCRIPT" ] || { echo "FAIL script-missing"; exit 1; }

# 注意 ${2:-}：本脚本 set -u，而部分断言（如静态门禁）没有附加信息要打印。
# 裸写 $2 会在"只传一个参数"时报 "parameter not set" —— 那会让门禁自己崩掉，
# 表现为难以理解的错误而不是 FAIL-xxx，反而掩盖了真正被检测到的问题。
fail() { echo "FAIL-$1${2:+: $2}"; exit 1; }

# 在沙箱里跑一次 remote_setup，回传 stdout+stderr。
# $1 = DSH_HOME；其余通过环境变量由调用方预设（用 env 传，避免污染本进程）
run_setup() {
  _rs_home="$1"
  DSH_HOME="$_rs_home" \
  DSH_REMOTE_SEED="${SEED_DIR:-$T/seed}" \
  RESCUE_PROFILE=web \
  DSH_SETUP_REMOTE="${SETUP:-on}" \
  DSH_ADMIN_PASSWORD="${ADMIN_PW:-}" \
  DSH_DEFAULT_ADMIN_USER="${ADMIN_USER:-admin}" \
  TMPDIR="$T" \
    sh -c '. "$1"; remote_setup' sh "$SCRIPT" 2>&1
}

# 构造一个"最小可用 profile 目录"，模拟 entrypoint ⑤ 预置的 manifest
mkprofile() {
  _mk_home="$1"
  mkdir -p "$_mk_home/profiles/web"
  cat > "$_mk_home/profiles/web/package.json" <<'PPF'
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {},
  "dsh": {
    "profile": {
      "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"]
    }
  }
}
PPF
}

# 构造假 seed：只需具备 remote_setup 会检查的三个路径
mkseed() {
  _ms_dir="$1"
  mkdir -p "$_ms_dir/node_modules/@xgone/dsh-remote/lib" "$_ms_dir/node_modules/@deepseek-ai/dsh-base"
  printf '{"name":"@xgone/dsh-remote","version":"0.3.5","dsh":{"bundle":{"patch":"./cordis.patch.yml"}}}\n' \
    > "$_ms_dir/node_modules/@xgone/dsh-remote/package.json"
  printf -- '- insert: []\n' > "$_ms_dir/node_modules/@xgone/dsh-remote/cordis.patch.yml"
  printf '{"name":"@deepseek-ai/dsh-base","version":"0.2.0-rc.2"}\n' \
    > "$_ms_dir/node_modules/@deepseek-ai/dsh-base/package.json"
  printf 'lockfileVersion: 9.0\n' > "$_ms_dir/pnpm-lock.yaml"
  printf 'packages:\n  - .\n' > "$_ms_dir/pnpm-workspace.yaml"
  printf '{"name":"dsh-remote-seed","private":true,"dependencies":{"@xgone/dsh-remote":"0.3.5"}}\n' \
    > "$_ms_dir/package.json"
}

# 写一个"账号已存在"的 store.json
mkstore() {
  _mst_home="$1"
  mkdir -p "$_mst_home/auth"
  cat > "$_mst_home/auth/store.json" <<'STJ'
{
  "version": 1,
  "secret": "0123456789012345678901234567890123456789",
  "accounts": [
    { "username": "admin", "role": "admin", "passwordHash": "scrypt$AA$BB", "protected": true }
  ]
}
STJ
}

SEED_DIR="$T/seed"; mkseed "$SEED_DIR"

# ---- T1 密码生成器 ----
. "$SCRIPT"
command -v remote_gen_password >/dev/null 2>&1 || fail t1-fn-missing
_p1=$(remote_gen_password)
[ "${#_p1}" = 16 ] || fail t1-length "expected 16 chars, got ${#_p1} ('$_p1')"
case "$_p1" in *[!A-Za-z0-9]*) fail t1-charset "non-alnum char in '$_p1'" ;; esac
# 多次调用必须不同（若生成器退化成常量或恒定种子，这里立刻红）
_p2=$(remote_gen_password); _p3=$(remote_gen_password)
[ "$_p1" != "$_p2" ] || fail t1-not-random "two calls produced the same password"
[ "$_p2" != "$_p3" ] || fail t1-not-random "two calls produced the same password"
# 生成 20 次全部 16 位且唯一（抓"偶尔短一位"的边界，如拒绝采样循环提前退出）
_i=0; _seen=''
while [ "$_i" -lt 20 ]; do
  _pp=$(remote_gen_password)
  [ "${#_pp}" = 16 ] || fail t1-length-loop "iteration $_i gave ${#_pp} chars"
  case " $_seen " in *" $_pp "*) fail t1-duplicate "duplicate password in 20 draws" ;; esac
  _seen="$_seen $_pp"
  _i=$((_i + 1))
done

# ---- T2 首启：装插件 + 登记 bundle + 写 bootstrap + 打印密码 ----
H2="$T/h2"; mkprofile "$H2"
out2=$(run_setup "$H2")
printf '%s' "$out2" | grep -q 'installing default auth plugin' || fail t2-no-install-log "$out2"
printf '%s' "$out2" | grep -q 'registered @xgone/dsh-remote in dsh.profile.bundles' || fail t2-no-register-log "$out2"
printf '%s' "$out2" | grep -q 'first-boot admin credentials' || fail t2-no-banner "$out2"
# 插件本体必须真的落进 profile（漏了它 profile 起不来，而日志照样"成功"）
[ -f "$H2/profiles/web/node_modules/@xgone/dsh-remote/package.json" ] || fail t2-plugin-not-copied
[ -f "$H2/profiles/web/node_modules/@deepseek-ai/dsh-base/package.json" ] || fail t2-scoped-merge-failed
# bundle 登记进 manifest
grep -q '"@xgone/dsh-remote"' "$H2/profiles/web/package.json" || fail t2-bundle-not-registered
# bootstrap 段写入 patch，且用户名正确
P2="$H2/profiles/web/cordis.patch.yml"
[ -f "$P2" ] || fail t2-patch-missing
grep -q 'id: remote' "$P2" || fail t2-patch-no-remote-row
grep -q "username: 'admin'" "$P2" || fail t2-patch-no-username
grep -q 'bootstrap:' "$P2" || fail t2-patch-no-bootstrap
# 日志里的密码必须与写进 patch 的一致（否则用户拿到的是登不上的假密码）
_pw2=$(printf '%s' "$out2" | sed -n 's/.*密码   \/ password : \([A-Za-z0-9]*\).*/\1/p' | head -n1)
[ -n "$_pw2" ] || fail t2-password-not-printed "$out2"
[ "${#_pw2}" = 16 ] || fail t2-printed-password-length "${#_pw2}"
grep -q "password: '$_pw2'" "$P2" || fail t2-printed-mismatch-patch "printed=$_pw2"

# ---- T3 二次启动（账号已存在）：不打印密码、不覆盖 ----
H3="$T/h3"; mkprofile "$H3"; mkstore "$H3"
# 预置一份"用户改过"的 patch，含用户自己的行与一份旧托管块
cat > "$H3/profiles/web/cordis.patch.yml" <<'UPF'
# 用户自己的配置
- id: user-row
  config:
    key: keepme
UPF
out3=$(run_setup "$H3")
if printf '%s' "$out3" | grep -q '密码   / password'; then
  fail t3-password-reprinted "password must NOT be printed when accounts already exist: $out3"
fi
printf '%s' "$out3" | grep -q 'admin bootstrap skipped' || fail t3-no-skip-log "$out3"
# 用户的配置必须原样保留
grep -q 'id: user-row' "$H3/profiles/web/cordis.patch.yml" || fail t3-user-config-clobbered
grep -q 'key: keepme' "$H3/profiles/web/cordis.patch.yml" || fail t3-user-config-clobbered
# 账号存在但 patch 没有 remote 行 -> 应补一个不带 bootstrap 的启用行（不生成假密码）
grep -q 'id: remote' "$H3/profiles/web/cordis.patch.yml" || fail t3-missing-enable-row
if grep -q "password:" "$H3/profiles/web/cordis.patch.yml"; then
  fail t3-bogus-password-written "must not write a password when accounts already exist"
fi

# ---- T4 幂等：连续两次不产生两份托管块 ----
H4="$T/h4"; mkprofile "$H4"
run_setup "$H4" >/dev/null 2>&1
run_setup "$H4" >/dev/null 2>&1
_n4=$(grep -c 'begin$' "$H4/profiles/web/cordis.patch.yml" 2>/dev/null || true)
# 托管块用 ">>>" 结尾的行标记开始
_n4=$(grep -c 'managed block, do not edit' "$H4/profiles/web/cordis.patch.yml")
[ "$_n4" = 1 ] || fail t4-duplicate-block "expected exactly 1 managed block, found $_n4"

# ---- T5 用户 patch 内容在重跑中保留 ----
cat > "$H4/profiles/web/cordis.patch.yml.bak" <<'EOF'
EOF
# 在已有托管块前追加用户内容，再跑一次
{ printf -- '- id: another-user-row\n  config:\n    x: 1\n'; cat "$H4/profiles/web/cordis.patch.yml"; } \
  > "$H4/profiles/web/cordis.patch.yml.new"
mv "$H4/profiles/web/cordis.patch.yml.new" "$H4/profiles/web/cordis.patch.yml"
mkstore "$H4"   # 让这次走"账号已存在"分支
run_setup "$H4" >/dev/null 2>&1
grep -q 'id: another-user-row' "$H4/profiles/web/cordis.patch.yml" || fail t5-user-row-lost
_n5=$(grep -c 'managed block, do not edit' "$H4/profiles/web/cordis.patch.yml")
[ "$_n5" = 1 ] || fail t5-block-duplicated "found $_n5 managed blocks"

# ---- T6 显式密码 ----
H6="$T/h6"; mkprofile "$H6"
export ADMIN_PW='MyExplicitPass123'
out6=$(run_setup "$H6")
printf '%s' "$out6" | grep -q 'MyExplicitPass123' || fail t6-explicit-not-printed "$out6"
printf '%s' "$out6" | grep -q 'from DSH_ADMIN_PASSWORD' || fail t6-source-not-labelled "$out6"
grep -q "password: 'MyExplicitPass123'" "$H6/profiles/web/cordis.patch.yml" || fail t6-explicit-not-written
unset ADMIN_PW

# ---- T7 短密码退回随机 ----
H7="$T/h7"; mkprofile "$H7"
export ADMIN_PW='abc'
out7=$(run_setup "$H7")
grep -q "password: 'abc'" "$H7/profiles/web/cordis.patch.yml" && fail t7-short-password-accepted
_pw7=$(printf '%s' "$out7" | sed -n 's/.*密码   \/ password : \([A-Za-z0-9]*\).*/\1/p' | head -n1)
[ "${#_pw7}" = 16 ] || fail t7-fallback-not-16 "${#_pw7}"
unset ADMIN_PW

# ---- T8 DSH_SETUP_REMOTE=off：一个字节都不动 ----
H8="$T/h8"; mkprofile "$H8"
before8=$(cat "$H8/profiles/web/package.json")
export SETUP=off
out8=$(run_setup "$H8")
unset SETUP
printf '%s' "$out8" | grep -q 'DSH_SETUP_REMOTE=off' || fail t8-no-off-log "$out8"
[ ! -e "$H8/profiles/web/node_modules/@xgone/dsh-remote" ] || fail t8-plugin-installed-when-off
[ ! -e "$H8/profiles/web/cordis.patch.yml" ] || fail t8-patch-written-when-off
[ "$(cat "$H8/profiles/web/package.json")" = "$before8" ] || fail t8-manifest-changed-when-off

# ---- T9 seed 缺失：跳过、不报错、不建 patch ----
H9="$T/h9"; mkprofile "$H9"
export SEED_DIR="$T/no-such-seed"
out9=$(run_setup "$H9")
unset SEED_DIR
printf '%s' "$out9" | grep -q 'no plugin seed in image' || fail t9-no-skip-log "$out9"
[ ! -e "$H9/profiles/web/cordis.patch.yml" ] || fail t9-patch-written-without-seed

# ---- T10 profile 已有插件：不覆盖（保留用户在容器内升级过的版本）----
H10="$T/h10"; mkprofile "$H10"
mkdir -p "$H10/profiles/web/node_modules/@xgone/dsh-remote"
printf '{"name":"@xgone/dsh-remote","version":"9.9.9-user-upgraded"}\n' \
  > "$H10/profiles/web/node_modules/@xgone/dsh-remote/package.json"
out10=$(run_setup "$H10")
printf '%s' "$out10" | grep -q 'already present in profile' || fail t10-no-present-log "$out10"
grep -q '9.9.9-user-upgraded' "$H10/profiles/web/node_modules/@xgone/dsh-remote/package.json" \
  || fail t10-user-version-overwritten

# ---- T11 source 不得有顶层副作用 ----
# 在干净沙箱里 source，且故意不提供 DSH_HOME/seed：若 source 时跑了主流程，会创建文件或打日志。
_h11="$T/h11"; mkdir -p "$_h11"
_out11=$(DSH_HOME="$_h11" DSH_REMOTE_SEED="$T/no-such-seed" sh -c '. "$1"; echo "__SOURCED__"' sh "$SCRIPT" 2>&1)
printf '%s' "$_out11" | grep -q '__SOURCED__' || fail t11-source-failed "$_out11"
if printf '%s' "$_out11" | grep -qE 'remote-setup\]'; then
  fail t11-source-has-side-effects "sourcing printed setup output: $_out11"
fi
[ -z "$(find "$_h11" -mindepth 1 2>/dev/null)" ] || fail t11-source-created-files

# ---- T12 镜像/entrypoint 接线 ----
DF="$ROOT/Dockerfile"; EP="$ROOT/scripts/entrypoint.sh"
grep -q '^ARG REMOTE_PLUGIN_VERSION=' "$DF" || fail t12-dockerfile-missing-plugin-arg
grep -q '/opt/dsh-remote-seed' "$DF" || fail t12-dockerfile-missing-seed-dir
grep -qE '^COPY .*scripts/remote-setup\.sh .*/opt/dsh-rescue/' "$DF" || fail t12-dockerfile-missing-copy
grep -q '/opt/dsh-rescue/remote-setup.sh' "$DF" || fail t12-dockerfile-missing-crlf-fix
# entrypoint 必须真的调用它（拷贝了但不调用 = 功能静默不存在）
grep -q 'remote_setup' "$EP" || fail t12-entrypoint-not-wired
# 调用必须在 root 首启块内（插件与 patch 要写挂载卷，降权后没权限）
grep -qE '\.\s+"\$RS_SCRIPT"' "$EP" || fail t12-entrypoint-not-sourcing

# ---- T13 构建期 pnpm 必须用绝对路径（真机事故 2026-09-30）----
# tag v0.6.0-dsh-0.2.0-rc.2 的镜像构建在插件 seed 层失败，exit code 127。
# 根因：npm 层把 pnpm 装进 /opt/dsh-seed（行内 NPM_CONFIG_PREFIX 覆盖 ENV），
# 而 ENV PATH=/opt/dsh/bin:$PATH 指向的是**运行时挂载卷**路径，不含 /opt/dsh-seed/bin，
# 于是裸写 `pnpm` 直接 command not found。
# 本仓库对 seed 内可执行文件一律用绝对路径（entrypoint / rescue 都如此），此处必须一致。
# 断言方式：该 RUN 块内**不得**出现裸的 pnpm 调用。匹配规则要覆盖两种真实写法：
#   - 续行行首带缩进：`    pnpm add ...`（本仓库的实际形态）
#   - 命令分隔后紧跟：`; pnpm add` / `&& pnpm add` / `( pnpm add`
# 故用 (^|[;&|(])[[:space:]]*pnpm —— 注意 `$pnpm_bin` 与 `/abs/path/pnpm` 都不匹配
# （前者是 `$` 开头，后者 pnpm 前是 `/`），这正是"绝对路径写法不被误报"的原因。
# 单测全绿而构建失败，正是本项目最忌讳的"绿着但已失效"，故必须有这道静态门禁。
if awk '
  /^RUN /  { inrun = ($0 ~ /\\$/) ; next }
  inrun    { inrun = ($0 ~ /\\$/) }
  inrun && /(^|[;&|(])[[:space:]]*pnpm[[:space:]]/ { print "bare pnpm at line " NR ": " $0; bad = 1 }
  END      { exit bad }
' "$DF"; then :; else fail t13-dockerfile-bare-pnpm; fi
# 正向断言：必须存在绝对路径变量与实际调用，否则上面的"不得出现"会因整块被删而空过
grep -q 'pnpm_bin=/opt/dsh-seed/bin/pnpm' "$DF" || fail t13-missing-pnpm-bin-var
grep -q '"\$pnpm_bin" add ' "$DF" || fail t13-missing-abs-pnpm-invoke
# 且必须在调用前断言该文件可执行 —— 否则将来 seed 换成不含 pnpm 的基础镜像时，
# 失败信息会退化成难以定位的 127，而不是明确的致命提示。
grep -qF 'if [ ! -x "$pnpm_bin" ]; then' "$DF" || fail t13-missing-pnpm-exec-check

echo ALL-PASS
