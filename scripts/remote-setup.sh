#!/bin/sh
# ============================================================================
# remote-setup.sh — 默认认证插件（@xgone/dsh-remote）的首次启动整备
#
# 由 entrypoint 在「root 首启块」内调用（此时还未降权、三个挂载卷刚 chown 完）。
# 目标：让一个**全新部署**开箱就有访问控制 —— 默认管理员 admin + 随机 16 位密码，
#       密码只打印一次到首次启动日志（docker logs），之后不再出现。
#
# 【为什么放在 root 首启块】本脚本要写 /data/dsh/profiles/web 下的插件树与 manifest，
#   而这些路径的属主在 ③ 步才对齐给运行用户。放在 chown 之后、降权之前执行，写入的文件
#   天然属于 root，由 entrypoint 紧随其后的 **⑤c** 就地收尾属主。
#   ⚠ 早期注释写的是"随后由 ③ 的属主对齐收尾"，那是错的 —— ③ 排在**本步骤之前**，
#   下一个 ③ 只会出现在**下一次启动**；而首次启动会先因 EACCES 自愈耗尽落入 lifeboat，
#   根本走不到下一次启动的正常路径（真机故障 2026-10-10）。故 entrypoint 新增 ⑤c 兜底。
#
# 【为什么用 `cordis.patch.yml` 的 bootstrap 而不是直接写 store.json】
#   两种方式都能预置首个管理员，选 bootstrap 的理由：
#     ① 复用插件自己的凭据通路（scrypt 哈希、0600 权限、原子写）—— 我们不去碰它的
#        内部存储格式，插件的存储实现变了（字段改名/加版本号）也不会让我们写坏账号库；
#     ② 幂等语义由插件保证：**账号库非空即忽略**并打一行 warn，天然适配
#        「容器重建但卷还在」的常见场景，不会覆盖用户改过的密码。
#   代价是明文凭据会短暂存在于 profile 的 cordis.patch.yml 里 —— 这不是新问题，插件
#   文档本身就要求用户这么配（docs/zh-CN/02 的方式 B）。缓解措施见下方「密码只打印一次」。
#
# 【密码只打印一次】首次启动日志里的密码是用户拿到它的唯一途径，但如果我们每轮启动都
#   重新生成并打印，就等于把密码写进了**每一次** docker logs（日志会被转发、归档、贴到
#   issue 里）。故本脚本只在**真正创建账号的那一次**打印：
#     - 若 store.json 已存在账号 -> 直接退出，既不生成也不打印（重启/重建容器都安静）；
#     - 若本次确实新预置了账号 -> 打印密码，并提示可用 DSH_ADMIN_PASSWORD 覆盖。
#   这条「只打印一次」的判据是 store.json 的账号数，而不是我们自己的标记文件 ——
#   标记文件会在卷被清空后残留，而 store.json 是账号是否存在的唯一真相。
#
# 【环境变量】
#   DSH_DEFAULT_ADMIN_USER      默认管理员用户名（默认 admin）
#   DSH_ADMIN_PASSWORD          显式指定密码（默认空 = 随机生成 16 位）
#   DSH_SETUP_REMOTE            总闸：off 则完全不装插件、不建账号（回到内网直连模式）
#   DSH_REMOTE_SEED            插件 seed 目录（默认 /opt/dsh-remote-seed）
#   DSH_HOME                    数据根目录（默认 /data/dsh）
#   RESCUE_PROFILE              目标 profile（默认 web）
#
# 【退出码】恒返回 0 —— 本步骤的任何失败都不该阻断容器启动（插件装不上只是没有认证层，
#   而 PID1 起不来是彻底不可用；与 rescue 子系统「救命路径绝不因辅助功能失败而中断」同款约定）。
#   失败原因通过 rescue_log 与 stderr 双写，便于排查。
#
# 【红线】只写 profile 目录下的插件树、manifest 的 bundles 列表，以及 cordis.patch.yml 里
#   由本脚本管理的标记块；绝不触碰会话 / 记忆 / 工作区数据。账号库（auth/store.json）
#   一律只读 —— 是否已有账号只用于"要不要预置"的判定，本脚本从不写入它。
# ============================================================================

# elog/elog_warn：与入口脚本一致的带时间戳日志；本脚本可能被单独 source 做单测，
# 故缺失时兜底为 printf（单测不关心时间戳格式）。
if ! command -v elog >/dev/null 2>&1; then
  elog() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
fi
# elog_warn：告警走 stderr。刻意与 elog（stdout）分开 —— 启动日志里"正常流程"与"出问题了"
# 混在同一条流里时，排查者要通读全文才能发现异常；分开后 `docker logs dsh 2>&1` 仍能看到，
# 而 grep stderr 就能直达问题。
if ! command -v elog_warn >/dev/null 2>&1; then
  elog_warn() { printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2; }
fi
# rescue_log 由 librescue.sh 提供（审计日志）。单测/独立调用时缺失，兜底为静默 ——
# 保持与调用方一致：审计日志是尽力而为，不得成为失败点。
if ! command -v rescue_log >/dev/null 2>&1; then
  rescue_log() { :; }
fi

# 随机密码：16 位，字母+数字。
# 【字符集】刻意**不含符号**：密码要经 docker logs -> 复制粘贴 -> 手输/密码管理器，
#   而 `$`/`\`/`"`/`'`/反引号在 shell、YAML、URL 里都是转义雷区。用字母数字就消除了
#   一整类"日志里的密码复制过去登不上"的支持成本。16 位 alnum ≈ 95 bit 熵，远超需要。
# 【来源】优先 /dev/urandom（所有 Linux 容器都有）；取不到时退回 openssl；再不行才用
#   $RANDOM 多轮拼接（弱，但总比"没有密码"强 —— 会同时打 WARN）。
# 【长度】严格 16 位。用 od 逐字节取样后按字符集取模会有模偏差，但本用途（人可读的一次性
#   初始密码，且登录带限速 5 次/15 分钟）偏差带来的熵损失可忽略；这里仍用 62 的约数
#   范围的取样方式降低偏差：取 0-255 映射到 62 字符集，模偏差存在但分布远好于 $RANDOM。
remote_gen_password() {
  _rgp_len=16
  _rgp_set='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  _rgp_setlen=62
  _rgp_out=''
  if [ -r /dev/urandom ]; then
    while [ "${#_rgp_out}" -lt "$_rgp_len" ]; do
      # 每轮取 32 字节，足够多轮使用；被拒绝的空样本（od 失败）直接跳出
      _rgp_bytes=$(od -An -tu1 -N32 /dev/urandom 2>/dev/null) || break
      [ -n "$_rgp_bytes" ] || break
      for _rgp_b in $_rgp_bytes; do
        # 拒绝采样：只接受 0..247（= 62*4 - 1），把模偏差压到可忽略；
        # 其余值丢弃重取，保证每个字符等概率。
        if [ "$_rgp_b" -lt 248 ]; then
          _rgp_i=$((_rgp_b % _rgp_setlen))
          # POSIX sh 没有子串展开语法差异：${var#?} 逐个消耗是 portable 的取字符方式
          _rgp_rest=$_rgp_set
          _rgp_j=0
          while [ "$_rgp_j" -lt "$_rgp_i" ]; do
            _rgp_rest=${_rgp_rest#?}
            _rgp_j=$((_rgp_j + 1))
          done
          _rgp_out="$_rgp_out${_rgp_rest%"${_rgp_rest#?}"}"
          [ "${#_rgp_out}" -ge "$_rgp_len" ] && break
        fi
      done
    done
  fi
  if [ "${#_rgp_out}" -lt "$_rgp_len" ]; then
    # 退路一：openssl（部分精简镜像里有）；仍不足则退路二见下
    if command -v openssl >/dev/null 2>&1; then
      _rgp_out=$(openssl rand -base64 48 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-16)
    fi
  fi
  if [ "${#_rgp_out}" -lt "$_rgp_len" ]; then
    # 退路二：$RANDOM 拼接。熵弱得多，但"有密码"远胜"没有密码"；同时显式打 WARN，
    # 让用户知道该密码强度不足、应立刻改掉（静默降级成弱密码是最坏的结果）。
    elog_warn '[remote-setup] WARN /dev/urandom and openssl unavailable; falling back to $RANDOM for the initial password'
    _rgp_out=''
    _rgp_k=0
    while [ "${#_rgp_out}" -lt "$_rgp_len" ]; do
      _rgp_r=$(( (${RANDOM:-0} * 32768 + ${RANDOM:-0}) % _rgp_setlen ))
      _rgp_rest=$_rgp_set
      _rgp_j=0
      while [ "$_rgp_j" -lt "$_rgp_r" ]; do _rgp_rest=${_rgp_rest#?}; _rgp_j=$((_rgp_j + 1)); done
      _rgp_out="$_rgp_out${_rgp_rest%"${_rgp_rest#?}"}"
      _rgp_k=$((_rgp_k + 1))
      [ "$_rgp_k" -gt 64 ] && break
    done
  fi
  printf '%s' "$_rgp_out"
}

# 读取 store.json 里的账号数（0 / 数字）。
# 【为什么用 sed 而不是 node】本函数在 PID1 的启动路径上，node 可能因 profile/内存问题
#   失败；store.json 是我们已知的极简结构（accounts 数组），grep 计数足够可靠，
#   且不会被 JSON 解析异常拖垮启动。解析不出来时返回 0（=视为"无账号"）是**故意保守**：
#   宁可多打印一次密码，也不要在账号其实不存在时静默跳过预置。
remote_store_account_count() {
  _rsac_store="$1"
  [ -f "$_rsac_store" ] || { printf '0'; return 0; }
  # 账号对象形如 {"username":"admin",...}；数 "username" 键出现次数即为账号数。
  _rsac_n=$(grep -o '"username"[[:space:]]*:' "$_rsac_store" 2>/dev/null | wc -l | tr -d ' ')
  case "$_rsac_n" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$_rsac_n" ;; esac
}

# 从 profile 的 cordis.patch.yml 里摘下已有的 remote 配置（原样文本），用于"已配置就跳过"。
# 判据是文件里已有 `id: remote` 行 —— 用户可能自行改过（enabled:false、换账号），
# 我们必须尊重，不能覆盖。
remote_patch_has_remote_row() {
  _rphr_f="$1"
  [ -f "$_rphr_f" ] || return 1
  grep -qE '^[[:space:]]*-?[[:space:]]*id:[[:space:]]*remote[[:space:]]*$' "$_rphr_f"
}

# 幂等地把 remote 插件登记进 profile 的 dsh.profile.bundles（在内存中用 node 改 JSON，
# 保留其它字段与顺序；已存在则不改）。
# $1 = profile 目录；$2 = 插件包名
remote_register_bundle() {
  _rrb_dir="$1"; _rrb_pkg="$2"
  _rrb_manifest="$_rrb_dir/package.json"
  [ -f "$_rrb_manifest" ] || { elog_warn "  profile manifest missing: $_rrb_manifest"; return 1; }
  node -e '
    const fs = require("fs");
    const [file, pkg] = process.argv.slice(1);
    const m = JSON.parse(fs.readFileSync(file, "utf8"));
    m.dsh = m.dsh ?? {};
    m.dsh.profile = m.dsh.profile ?? {};
    const bundles = Array.isArray(m.dsh.profile.bundles) ? m.dsh.profile.bundles : [];
    if (bundles.includes(pkg)) { console.log("already"); process.exit(0); }
    // 追加在末尾：bundle 的 patch 按列表顺序叠加，用户/插件层要排在 dsh-base 与 dsh-web-app 之后
    bundles.push(pkg);
    m.dsh.profile.bundles = bundles;
    fs.writeFileSync(file, JSON.stringify(m, null, 2) + "\n");
    console.log("added");
  ' "$_rrb_manifest" "$_rrb_pkg" 2>&1
}

# 主流程。返回 0 恒成立（见文件头「退出码」）。
remote_setup() {
  _rs_home="${DSH_HOME:-/data/dsh}"
  _rs_profile="${RESCUE_PROFILE:-web}"
  _rs_user="${DSH_DEFAULT_ADMIN_USER:-admin}"
  _rs_seed="${DSH_REMOTE_SEED:-/opt/dsh-remote-seed}"
  _rs_pdir="$_rs_home/profiles/$_rs_profile"
  _rs_patch="$_rs_pdir/cordis.patch.yml"
  _rs_store="$_rs_home/auth/store.json"
  _rs_pkg="${DSH_REMOTE_PLUGIN_NAME:-@xgone/dsh-remote}"

  # 总闸：显式关闭则一个字节都不动（含不装插件）
  if [ "${DSH_SETUP_REMOTE:-on}" = off ]; then
    elog '[remote-setup] DSH_SETUP_REMOTE=off -> skipping default auth plugin setup'
    return 0
  fi

  # 镜像里没带 seed（如 REMOTE_PLUGIN_VERSION 置空构建的镜像）-> 跳过，回到无认证直连模式
  if [ ! -d "$_rs_seed" ] || [ ! -f "$_rs_seed/node_modules/$_rs_pkg/package.json" ]; then
    elog '[remote-setup] no plugin seed in image -> skipping (deployment runs WITHOUT the auth plugin)'
    rescue_log 'remote-setup: plugin seed absent, skipped'
    return 0
  fi

  mkdir -p "$_rs_pdir" 2>/dev/null || true

  # ---- ① 安装/更新插件本体（离线，从镜像 seed 复制）----
  # 判据：profile 里没有插件本体就复制。已存在则**不覆盖** —— 用户可能用
  # `dsh plugin add @xgone/dsh-remote@<更高版本>` 升过，镜像 seed 不该把它顶回旧版
  # （与 dsh 本体「seed 只升不降」的既有约定相反是有意的：插件种子只负责"从无到有"，
  #   升级一律交给 dsh plugin / pnpm，避免镜像版本与用户选择互相打架）。
  if [ ! -f "$_rs_pdir/node_modules/$_rs_pkg/package.json" ]; then
    elog "[remote-setup] installing default auth plugin $_rs_pkg from image seed (offline)"
    mkdir -p "$_rs_pdir/node_modules" 2>/dev/null || true
    # 逐项复制而不是整树替换：profile 的 node_modules 里还躺着用户装过的其它插件，
    # 整树 rm -rf + cp 会把它们一起抹掉。
    for _rs_entry in "$_rs_seed"/node_modules/*; do
      [ -e "$_rs_entry" ] || continue
      _rs_base=${_rs_entry##*/}
      if [ "$_rs_base" = "@deepseek-ai" ] || [ "$_rs_base" = "@xgone" ]; then
        # 作用域目录：合并（保留其中用户已装的其它包）
        mkdir -p "$_rs_pdir/node_modules/$_rs_base" 2>/dev/null || true
        for _rs_sub in "$_rs_entry"/*; do
          [ -e "$_rs_sub" ] || continue
          _rs_subname=${_rs_sub##*/}
          [ -e "$_rs_pdir/node_modules/$_rs_base/$_rs_subname" ] && continue
          cp -a "$_rs_sub" "$_rs_pdir/node_modules/$_rs_base/$_rs_subname" 2>/dev/null \
            || elog_warn "  WARN failed to copy $_rs_base/$_rs_subname"
        done
      else
        [ -e "$_rs_pdir/node_modules/$_rs_base" ] && continue
        cp -a "$_rs_entry" "$_rs_pdir/node_modules/$_rs_base" 2>/dev/null \
          || elog_warn "  WARN failed to copy node_modules/$_rs_base"
      fi
    done
    # pnpm 元数据：只补缺失的，绝不覆盖 profile 已有的 lockfile ——
    # profile 的 lockfile 记录着用户装过的**全部**插件，用 seed 的（只有我们一个包）覆盖它
    # 会让 dsh plugin 认为其它插件没被管理，进而触发重装/报错。
    for _rs_meta in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
      if [ -f "$_rs_seed/$_rs_meta" ] && [ ! -f "$_rs_pdir/$_rs_meta" ]; then
        cp -a "$_rs_seed/$_rs_meta" "$_rs_pdir/$_rs_meta" 2>/dev/null || true
      fi
    done
  else
    elog "[remote-setup] default auth plugin already present in profile (left as-is)"
  fi

  # ---- ② 登记 bundle（幂等）----
  # 插件靠 dsh.profile.bundles 才被激活；manifest 由 entrypoint ⑤ 预置（只含 base+web-app），
  # 故这里补上本插件。用户若已手工登记则原样保留。
  _rs_reg=$(remote_register_bundle "$_rs_pdir" "$_rs_pkg" 2>&1) || true
  case "$_rs_reg" in
    *added*) elog "[remote-setup] registered $_rs_pkg in dsh.profile.bundles" ;;
    *already*) elog "[remote-setup] $_rs_pkg already in dsh.profile.bundles" ;;
    *) elog_warn "[remote-setup] WARN could not register $_rs_pkg in bundles: $_rs_reg" ;;
  esac

  # ---- ③ 首个管理员：只在账号库为空时预置，且密码只打印这一次 ----
  _rs_count=$(remote_store_account_count "$_rs_store")
  if [ "$_rs_count" != 0 ]; then
    elog "[remote-setup] account store already has $_rs_count account(s) -> admin bootstrap skipped (password unchanged, NOT printed again)"
    # 已配置过 remote 行就完全不碰 patch 文件；否则补上（例如用户删了 patch 行但账号还在）
    if remote_patch_has_remote_row "$_rs_patch"; then
      return 0
    fi
    # 账号存在但 patch 没有 remote 行 = 插件根本没被配置过（或用户清掉了）。
    # 此时**不能**生成新密码：会与既有账号的密码不一致，且打印出来的是个登不上的假密码。
    _rs_write_remote_row "$_rs_patch" "$_rs_user" '' 'existing'
    return 0
  fi

  # 账号库为空 -> 真正需要预置。密码来源：显式环境变量优先，否则随机。
  _rs_pw="${DSH_ADMIN_PASSWORD:-}"
  _rs_pw_source='generated'
  if [ -z "$_rs_pw" ]; then
    _rs_pw=$(remote_gen_password)
  else
    _rs_pw_source='from DSH_ADMIN_PASSWORD'
  fi
  # 与插件自身的校验保持一致（bootstrap.password >= 6），并挡住"环境变量误设成空/超短"
  if [ "${#_rs_pw}" -lt 6 ]; then
    elog_warn "[remote-setup] WARN generated/configured password is shorter than 6 chars; regenerating"
    _rs_pw=$(remote_gen_password)
    _rs_pw_source='generated (fallback: configured value too short)'
  fi

  if ! _rs_write_remote_row "$_rs_patch" "$_rs_user" "$_rs_pw" 'bootstrap'; then
    elog_warn "[remote-setup] WARN failed to write remote row into $_rs_patch -> no admin account provisioned"
    rescue_log 'remote-setup: failed to write remote row'
    return 0
  fi

  # ======== 首次启动的凭据横幅（只在这一条路径上打印）========
  # 用醒目的分隔线，因为它在 docker logs 里要和 dsh 的大段启动输出抢注意力。
  #
  # 【输出语言必须是英文】本横幅进 docker logs，属"容器日志"范畴 ——
  # 按本仓库约定，容器日志一律英文（面向任意环境的运维/排障、便于贴 issue 与搜索）；
  # 中文只用于仓库内文档、rescue CLI 提示与各类报告。改动时请勿把中文写回这里。
  #
  # 【密码必须独占行尾】真机 2026-09-30：原格式把密码写成
  #     `password : xxxx   [generated]`
  # —— 密码后面紧跟三个空格与 `[generated]`，用户复制时极易带上尾部空格，
  # 或把密码里的大写字母 O 看成数字 0，于是反复登录失败并撞上限速（429）。
  # 故：密码行的**行尾就是密码**，来源另起一行，不给复制制造干扰。
  #
  # 【必须告知存档位置】同一次真机：用户事后想再确认密码，却在日志里找不到
  # （设计上只打印一次），也不知道密码其实被写进了 profile 的 cordis.patch.yml，
  # 只能来问"这密码从哪来的"。故横幅里直接给出存档路径 —— 让看到密码的**当下**
  # 就知道日后去哪里取回，而不是等忘了再来找。
  elog '============================================================'
  elog ' DSH first-boot admin credentials'
  elog "   username : $_rs_user"
  elog "   password : $_rs_pw"
  elog "   source   : $_rs_pw_source"
  elog "   stored   : $_rs_patch"
  elog '              (mode 0600; plaintext kept there for later recovery)'
  elog ' Change this password and enable MFA right after the first login'
  elog '   (Settings -> Login & Account).'
  elog ' This password is printed ONCE; restarts will not show it again,'
  elog '   but the archive file above keeps it, so you can recover it later.'
  elog '============================================================'
  rescue_log "remote-setup: bootstrapped admin '$_rs_user' ($_rs_pw_source); credentials archived at $_rs_patch (0600)"
  return 0
}

# 把 remote 配置写进 profile 的 cordis.patch.yml（幂等、只替换自己那一段）。
# $1 = patch 文件；$2 = 用户名；$3 = 密码（空 = 只启用不预置凭据）；$4 = 模式标记
#
# 【实现方式】用标记块包裹我们写的内容，重复调用只替换块内内容，块外（用户的其它配置）
#   一字不动。找不到标记块时**追加**到文件末尾 —— 用户的 patch 会被完整保留。
# 【为什么块内是整行 `- id: remote` 的 patch】DSH 的 patch 按 row id 定位，后者覆盖前者的
#   config；写在用户层即最终生效的那个。
_rs_write_remote_row() {
  _wrw_file="$1"; _wrw_user="$2"; _wrw_pw="$3"; _wrw_mode="$4"
  mkdir -p "$(dirname "$_wrw_file")" 2>/dev/null || true
  [ -f "$_wrw_file" ] || : > "$_wrw_file"

  _wrw_begin='# >>> dsh-docker-server: default auth plugin (managed block, do not edit) >>>'
  _wrw_end='# <<< dsh-docker-server: default auth plugin <<<'
  _wrw_tmp="$_wrw_file.tmp.$$"

  # ① 剥掉旧的托管块（若存在），保留其余内容
  if grep -qF "$_wrw_begin" "$_wrw_file" 2>/dev/null; then
    awk -v b="$_wrw_begin" -v e="$_wrw_end" '
      index($0, b) == 1 { skip = 1; next }
      index($0, e) == 1 { skip = 0; next }
      !skip { print }
    ' "$_wrw_file" > "$_wrw_tmp" 2>/dev/null || { rm -f "$_wrw_tmp"; return 1; }
  else
    cp "$_wrw_file" "$_wrw_tmp" 2>/dev/null || { rm -f "$_wrw_tmp"; return 1; }
  fi

  # ② 追加新的托管块
  {
    printf '\n%s\n' "$_wrw_begin"
    printf '# 默认认证插件 @xgone/dsh-remote（由 entrypoint 首启写入）\n'
    printf '# 手工修改后本块会在下次启动被重写；要自定义请改 enabled/其余字段并删除本块标记。\n'
    printf -- '- id: remote\n'
    printf '  config:\n'
    printf '    enabled: true\n'
    if [ -n "$_wrw_pw" ]; then
      # YAML 单引号字符串：内部单引号需写成两个。密码是 alnum，正常不会命中；
      # 但 DSH_ADMIN_PASSWORD 是用户输入，必须转义，否则密码里的引号会让 YAML 解析失败
      # —— 那会让整棵 profile 起不来（用户只看到"启动失败"，完全想不到是密码里的引号）。
      _wrw_pw_q=$(printf '%s' "$_wrw_pw" | sed "s/'/''/g")
      printf '    bootstrap:            # 仅在账号库为空时使用\n'
      printf "      username: '%s'\n" "$_wrw_user"
      printf "      password: '%s'\n" "$_wrw_pw_q"
    elif [ "$_wrw_mode" = 'existing' ]; then
      printf '# 账号库已有账号：不在此预置凭据（避免写入一个与既有密码不符的假密码）。\n'
      printf '# 若这些账号确实可用，直接登录即可；忘记了请删除 %s 后重建容器。\n' "${DSH_HOME:-/data/dsh}/auth/store.json"
    fi
    printf '%s\n' "$_wrw_end"
  } >> "$_wrw_tmp" || { rm -f "$_wrw_tmp"; return 1; }

  # ③ 原子替换（保留原文件权限/属主：cat 覆盖而非 mv）
  _wrw_mode_bits=$(stat -c '%a' "$_wrw_file" 2>/dev/null || printf '644')
  cat "$_wrw_tmp" > "$_wrw_file" || { rm -f "$_wrw_tmp"; return 1; }
  rm -f "$_wrw_tmp"
  # 密码明文在文件里：0600 收紧权限（限 root/属主可读）。这是"明文凭据"的必要缓解，
  # 也是插件文档里"首次登录后移除明文凭据"那条建议的替代品 —— 我们靠权限而非靠用户自觉。
  if [ -n "$_wrw_pw" ]; then
    chmod 600 "$_wrw_file" 2>/dev/null || true
  else
    chmod "$_wrw_mode_bits" "$_wrw_file" 2>/dev/null || true
  fi
  return 0
}

# 本文件只定义函数，**无顶层副作用**（与 librescue.sh / vercmp.sh 同款约定）：
# entrypoint 与单测都靠 `. remote-setup.sh` source 它，source 时跑主流程会污染调用方。
# 需要直接执行（手工排查）时显式调用：sh scripts/remote-setup.sh

