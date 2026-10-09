#!/bin/sh
# ============================================================================
# test-cloudflare-tunnel.sh — Cloudflare Tunnel 覆盖文件的「默认不部署」门禁
#
# 【为什么需要这条门禁】
#   Cloudflare Tunnel 一旦被**默认**部署，dsh 的 3080 端口就经由 cloudflared 出网暴露，
#   而 cloudflared 的 ingress 规则指向的是 dsh 服务本身 —— 等于把"内网直连也要靠
#   DSH_TRUSTED_HOSTS 兜底"的那套边界整个绕开了。用户明确要求：**可选、默认不部署**。
#   这个"默认不部署"在 compose 里唯一的实现机制就是 `profiles:` —— docker compose
#   在未显式 `--profile cloudflare` 时，**不会启动任何带 profiles 的服务**。
#
#   而 profiles 恰恰是最容易在后续重构中被"顺手"删掉/改名的行：它看起来只是几行 YAML，
#   删掉之后 `docker compose up -d` 仍然成功、容器照跑，**功能全对、只有边界没了**。
#   这正是 test-compose-wiring.sh 顶部记的那类教训（"门禁漏报但功能坏了"）：本脚本把
#   "profiles 必须存在且精确等于 cloudflare"变成红灯，让沉默的边界回退无法合入。
#
# 【为什么不用 `docker compose config` 校验】
#   CI 的 unit-tests job 跑在 bare ubuntu-latest 的 shell 上（见 .github/workflows/
#   docker-image.yml），**没有 docker daemon**。任何依赖 `docker compose` 的断言都会在
#   CI 里退化成"命令不存在→跳过→恒绿"，比没有门禁更危险。故本脚本只用 sh + grep + node。
#
# 【YAML 解析的降级策略（必须显式，绝不静默）】
#   本仓库**没有** YAML 依赖：实测 `node -e "require('js-yaml')"` → Cannot find module
#   'js-yaml'，也没有 `yaml` 包，宿主无 python3。故本脚本的默认路径是**结构化的文本
#   断言**（按缩进界定服务段后逐行精确匹配），解析器可得时再加一层真结构校验。
#   降级时必须打印 DROP 提示，明确宣告"只做了文本断言、没做完整 YAML 语法校验"。
#   静默跳过校验然后打印 ALL-PASS 属于"假装验证通过"，是这次明确禁止的行为。
# ============================================================================
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CF="$ROOT/docker-compose.cloudflare.yml"
MAIN="$ROOT/docker-compose.yml"
fail() { echo "FAIL-$1"; exit 1; }

# --- 反向护栏（总闸）：先证明"文件真的读得到"。否则下面每一条 grep 都会因为读不到文件
#     而"看起来通过"—— 这是 test-compose-wiring.sh 明确记过的坑位。
[ -f "$CF" ] || fail cloudflare-compose-missing
[ -s "$CF" ] || fail cloudflare-compose-empty
[ -f "$MAIN" ] || fail main-compose-missing

# ---------------------------------------------------------------------------
# 0) 语法硬伤：YAML 不允许 TAB 缩进，含 TAB 的文件 docker compose 直接报错。
#    不用 grep -P（busybox/dash 环境不一定有 PCRE），改匹配字面 TAB。
# ---------------------------------------------------------------------------
if grep -q "$(printf '\t')" "$CF"; then
  fail cloudflare-compose-has-tab
fi

# services 顶层键必须存在（行首零缩进锚定，避免命中注释里的 "services"）
grep -qE '^services:[[:space:]]*$' "$CF" || fail services-topkey-missing
# 反向护栏：文件里必须真的有服务定义（缩进两格的服务名 + 冒号）
grep -qE '^  [A-Za-z0-9._-]+:[[:space:]]*$' "$CF" || fail no-service-defined

# ---------------------------------------------------------------------------
# 1) 提取 cloudflared 服务段（从 "  cloudflared:" 到下一个同级或更浅缩进的键为止）。
#    这是后续全部结构断言的基准：不先切出"这一段"，断言 ports: 就会误判到主 compose
#    的 dsh 段（任务描述专门点名了这个误判风险）。
# ---------------------------------------------------------------------------
SEG=$(awk '
  /^  cloudflared:[[:space:]]*$/ { inseg=1; print; next }
  inseg && /^  [A-Za-z0-9._-]+:[[:space:]]*$/ { inseg=0 }   # 下一个同级服务 → 段结束
  inseg && /^[^[:space:]]/ { inseg=0 }                       # 回到零缩进（顶层键）→ 段结束
  inseg { print }
' "$CF")

if [ -z "$SEG" ]; then
  echo "FAIL cloudflared-service-missing (docker-compose.cloudflare.yml 里没有 \"  cloudflared:\" 服务段)"
  exit 1
fi
# 反向护栏：段必须非空且确实含键值行，防止 awk 规则写错导致"空段恒通过"
printf '%s\n' "$SEG" | grep -qE '^    [A-Za-z_][A-Za-z0-9_-]*:' || fail cloudflared-segment-empty

# 段内**非注释行**视图：所有"某键必须存在"的断言一律基于它。
# 【为什么必须剔除注释行 —— 变异测试实测抓到的假绿】本覆盖文件的注释里会出现
# `${TUNNEL_TOKEN:?}`（解释为何不用 `:?`）、`read_only`/`tmpfs`（T1 要求保留但注释掉）
# 等字样。若直接对整段 grep `TUNNEL_TOKEN`，那么**把真正的 `- TUNNEL_TOKEN=...` 注入行
# 删掉之后**，注释里的字样仍会让断言通过 —— 门禁恒绿而隧道根本无法认证（实测确认过
# 这个假绿，见 B5 变异用例）。这正是 test-compose-wiring.sh 记的"门禁漏报但功能坏了"
# 的又一实例，故"必须存在"类断言一律只看非注释行。
SEG_CODE=$(printf '%s\n' "$SEG" | grep -vE '^[[:space:]]*#')

# ---------------------------------------------------------------------------
# 2) 【核心门禁】profiles 必须存在且精确包含 cloudflare
#
#    为什么要求"精确"而不是"包含"：profiles 若被写成 `- cloudflare-tunnel` 或 `- cf`，
#    用户按文档 `--profile cloudflare` 启动会**什么都起不来**（且是静默失败），
#    而"默认不部署"的边界看着还在。故既要求键存在，也要求值精确等于 cloudflare。
# ---------------------------------------------------------------------------
printf '%s\n' "$SEG" | grep -qE '^    profiles:[[:space:]]*$' \
  || fail cloudflared-missing-profiles-key
# profiles 列表项（缩进 6 格 + "- "）：必须有一项精确等于 cloudflare
printf '%s\n' "$SEG" | grep -qE '^      -[[:space:]]+cloudflare[[:space:]]*$' \
  || fail cloudflared-profiles-not-cloudflare
# 反向护栏：profiles 段里不允许出现 cloudflare 之外的 profile 名（防止改名后"两个名字
# 都写"从而掩盖漂移）。只扫 profiles 块内部，避免误伤其他列表。
profiles_extra=$(printf '%s\n' "$SEG" | awk '
  /^    profiles:[[:space:]]*$/ { inp=1; next }
  inp && /^    [A-Za-z_]/ { inp=0 }
  inp && /^      -[[:space:]]+/ {
    v=$0; sub(/^[[:space:]]*-[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
    if (v != "cloudflare") print v
  }
')
[ -z "$profiles_extra" ] || {
  echo "FAIL cloudflared-profiles-unexpected-extra: $profiles_extra"
  exit 1
}

# ---------------------------------------------------------------------------
# 3) 端口：cloudflared 是**出站**隧道（主动连 Cloudflare 边缘），不需要也不应该映射端口。
#    出现 ports: 通常意味着有人把它当成"再来一个 web 入口"来改，直接破坏暴露面假定。
#    只检查切出来的 cloudflared 段 —— 主 compose 的 dsh 段有 ports，绝不能被算进来。
# ---------------------------------------------------------------------------
if printf '%s\n' "$SEG_CODE" | grep -qE '^    ports:[[:space:]]*$'; then
  fail cloudflared-should-not-publish-ports
fi
# 反向护栏：确认"段内无 ports"不是因为段被切空了 —— 段内至少要有一个已知的多行键区
# （environment / command / image / volumes / restart / depends_on），否则上面那条断言
# 等于在空气上做检查。
printf '%s\n' "$SEG" | grep -qE '^    (environment|command|image|volumes|restart|depends_on):' \
  || fail cloudflared-segment-suspiciously-empty

# ---------------------------------------------------------------------------
# 4) image：必须是官方 cloudflare/cloudflared（允许 registry 前缀 / tag / digest）
# ---------------------------------------------------------------------------
printf '%s\n' "$SEG_CODE" | grep -qE '^    image:[[:space:]]*["'"'"']?[^"'"'"'[:space:]]*cloudflare/cloudflared([:@][^"'"'"'[:space:]]*)?["'"'"']?[[:space:]]*$' \
  || fail cloudflared-image-not-official

# 段内**非注释行**视图（定义见上方 SEG_CODE 处）。

# ---------------------------------------------------------------------------
# 5) command：必须含 tunnel 子命令；且必须含 --no-autoupdate。
#    --no-autoupdate 的理由：容器内自更新会拉取新版二进制并重启，与我们锁定的镜像版本
#    不一致；且 read_only 根文件系统下自更新往往失败得很隐蔽（表现为隧道时断时续）。
# ---------------------------------------------------------------------------
printf '%s\n' "$SEG_CODE" | grep -q 'no-autoupdate' || fail cloudflared-missing-no-autoupdate
printf '%s\n' "$SEG_CODE" | grep -qE '(^|[[:space:]"'"'"'-])tunnel([[:space:]"'"'"']|$)' \
  || fail cloudflared-missing-tunnel-subcommand

# ---------------------------------------------------------------------------
# 6) environment：TUNNEL_TOKEN（隧道凭据）与 TZ（日志时间本地化）都必须注入。
#    TUNNEL_TOKEN 走 environment 而非命令行，是为了避免 token 出现在 `docker inspect`
#    的 Cmd 字段与本机进程列表里。
#
#    断言的是**赋值行**（`- TUNNEL_TOKEN=...`）而不是裸词，这样注释里的说明文字不会撞绿；
#    同时要求是 `:-` 形式而非 `:?` —— `:?` 会在变量缺失时让 `docker compose config`
#    整体报错，而隧道是可选组件，缺 token 时应当只有 cloudflared 起不来。
# ---------------------------------------------------------------------------
printf '%s\n' "$SEG_CODE" | grep -qE '^[[:space:]]*-[[:space:]]*TUNNEL_TOKEN=' \
  || fail cloudflared-missing-tunnel-token
printf '%s\n' "$SEG_CODE" | grep -qE '^[[:space:]]*-[[:space:]]*TZ=' || fail cloudflared-missing-tz

# 变量引用清点：段内所有 ${...} 引用必须都是 `:-` 默认值形式，不得出现 `:?`（见上）。
# 只看非注释行，避免注释里作为"反面教材"引用的 ${TUNNEL_TOKEN:?} 撞红。
bad_ref=$(printf '%s\n' "$SEG_CODE" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*:\?[^}]*\}' || true)
[ -z "$bad_ref" ] || {
  echo "FAIL cloudflared-uses-required-expansion: $bad_ref"
  exit 1
}

# ---------------------------------------------------------------------------
# 7) 主 compose 不得被本改动污染：cloudflared 必须**只**活在独立覆盖文件里。
#    若有人图省事把 cloudflared 塞进 docker-compose.yml，则所有 `docker compose up -d`
#    的用户都会莫名多起一个隧道容器 —— "默认不部署"当场失效。
#    忽略注释行，避免被说明文字里的 "cloudflared" 字样误伤。
# ---------------------------------------------------------------------------
if grep -vE '^[[:space:]]*#' "$MAIN" | grep -qE 'cloudflared'; then
  echo "FAIL main-compose-must-not-declare-cloudflared"
  grep -nE 'cloudflared' "$MAIN"
  exit 1
fi
# 同上：主 compose 里也不该冒出 cloudflare profile（独立文件设计的一部分）
if grep -vE '^[[:space:]]*#' "$MAIN" | grep -qE '^[[:space:]]*-[[:space:]]*cloudflare[[:space:]]*$'; then
  fail main-compose-must-not-declare-cloudflare-profile
fi
# 【反向护栏】确保上面两条不是"因为主 compose 读不到才通过"：它必须非空且含 services 与 dsh
[ -s "$MAIN" ] || fail main-compose-empty
grep -qE '^services:[[:space:]]*$' "$MAIN" || fail main-compose-services-missing
grep -qE '^  dsh:[[:space:]]*$'    "$MAIN" || fail main-compose-dsh-service-missing

# ---------------------------------------------------------------------------
# 8) 覆盖文件的 compose 语义：它必须能**叠加**在主 compose 之上。
#
#    【为什么不禁止覆盖文件里出现 dsh:】初版这里断言"覆盖文件不得出现 dsh 服务"，
#    结果对合法的叠加写法误报 —— compose 覆盖文件的常见用途恰恰是给既有服务追加
#    networks/depends_on（例如把 dsh 也并入隧道网络）。任务契约里从未禁止这一点。
#    门禁误报会逼人删掉真需求，比漏报更糟，故放宽为：覆盖文件里若声明了 dsh，
#    它必须是**纯增量**（只允许 networks/depends_on/extra_hosts 这类接线键），
#    不得改写 dsh 的 image/ports/command 等既定行为（那才会造成"两份 dsh 定义"漂移）。
# ---------------------------------------------------------------------------
if grep -qE '^  dsh:[[:space:]]*$' "$CF"; then
  dsh_seg=$(awk '
    /^  dsh:[[:space:]]*$/ { inseg=1; print; next }
    inseg && /^  [A-Za-z0-9._-]+:[[:space:]]*$/ { inseg=0 }
    inseg && /^[^[:space:]]/ { inseg=0 }
    inseg { print }
  ' "$CF")
  bad_dsh=$(printf '%s\n' "$dsh_seg" | grep -vE '^[[:space:]]*#' | \
    grep -oE '^    [A-Za-z_][A-Za-z0-9_-]*:' | tr -d ' :' | \
    grep -vxE 'networks|depends_on|extra_hosts' || true)
  [ -z "$bad_dsh" ] || {
    echo "FAIL cloudflare-overlay-must-not-rewrite-dsh-keys: $(printf '%s' "$bad_dsh" | tr '\n' ' ')"
    exit 1
  }
fi

# ---------------------------------------------------------------------------
# 8b) 【「默认不部署」的行为断言】—— 必须真的能变红，不能恒真。
#
# 【这里踩过的坑，必须记下来】任务描述初稿要求断言「`docker compose up -d`（不带
#   --profile）不会启动 cloudflared」。但本仓库**没有 docker**（CI 的 unit-tests job 在
#   bare shell 上跑），而且**主 compose 里一个 profile 都没有** —— 这条断言在本地与 CI
#   都无法执行、也无法证伪，属于典型的**恒真断言**：写了等于没写，却让人以为有覆盖。
#   门禁里最危险的不是漏报，而是这种"看起来在测、实际测空气"的条目。
#
# 【替代方案】改为对 compose-spec 的 profiles 语义做一次**离线求值**：用最小实现判定
#   在给定命令行下每个服务是否被启动。这不需要 docker，也不需要主 compose 里有 profile。
#
# 【compose-spec 15-profiles.md 原文口径（compose-author 已核对原文）】
#   "A service is **ignored** by Compose when none of the listed profiles match the
#    active ones, **unless the service is explicitly targeted by a command**."
#   → 由此推出两条**方向相反**的结论，两条都要断，且都必须是可证伪的：
#     (a) 不带 --profile 且不点名：cloudflared **不被启动**（这是"默认不部署"）
#     (b) 显式点名 cloudflared：**会被启动**（profile 被显式目标激活）
#   只断 (a) 会漏掉"有人把 profiles 写成恒真"的退化；只断 (b) 会漏掉边界本身。
#   ⚠ 绝不要反着写："显式点名也拉不起来"是**错的**，那样写门禁会误报红灯。
# ---------------------------------------------------------------------------
node -e '
  const fs = require("fs");
  const file = process.argv[1];

  // —— 最小 compose 解析：只取 services → 服务名 → profiles 列表 ——
  // 刻意手写而不是引 YAML 库：本仓库无 YAML 依赖，且此处只需要"缩进 2 格的服务名 +
  // 缩进 6 格的 profiles 列表项"这一种形态，比引库更可控（也避免解析器自身出 bug）。
  const lines = fs.readFileSync(file, "utf8").split("\n");
  const svc = {};
  let cur = null, inProfiles = false;
  for (const raw of lines) {
    if (/^\s*#/.test(raw) || !raw.trim()) continue;          // 注释/空行一律忽略
    let m;
    if ((m = raw.match(/^  ([A-Za-z0-9._-]+):\s*$/))) {       // 服务名（缩进 2 格）
      cur = m[1]; svc[cur] = { profiles: [] }; inProfiles = false; continue;
    }
    if (cur && (m = raw.match(/^    profiles:\s*$/))) { inProfiles = true; continue; }
    if (cur && /^    [A-Za-z_]/.test(raw)) { inProfiles = false; continue; }  // 同级键 → 离开 profiles
    if (cur && inProfiles && (m = raw.match(/^      -\s+(.+?)\s*$/))) {
      svc[cur].profiles.push(m[1].replace(/^["'"'"']|["'"'"']$/g, ""));
    }
  }

  // —— compose-spec profiles 求值 ——
  // active: 命令行 --profile 指定的集合; targeted: 命令行显式点名的服务集合
  const isStarted = (name, active, targeted) => {
    const p = svc[name].profiles;
    if (targeted.has(name)) return true;          // 显式点名 → 无条件启动
    if (p.length === 0) return true;              // 无 profiles → 永远参与
    return p.some((x) => active.has(x));          // 任一 profile 命中 → 启动
  };

  const die = (msg) => { console.error("FAIL cloudflare-default-not-deployed: " + msg); process.exit(1); };
  if (!svc.cloudflared) die("解析不到 cloudflared 服务（门禁自身或文件结构有问题）");

  const NONE = new Set();
  // (a) 默认路径：无 --profile、不点名 → 必须不启动
  if (isStarted("cloudflared", NONE, NONE))
    die("不带 --profile 时 cloudflared 仍会被启动 —— 「默认不部署」已失效！");
  // (b) 显式点名 → 必须启动（防止有人用恒真写法把 (a) 糊弄过去后功能不可达）
  if (!isStarted("cloudflared", NONE, new Set(["cloudflared"])))
    die("显式 `docker compose up cloudflared` 竟无法启动 cloudflared —— profile 机制把功能锁死了");
  // (c) 带 --profile cloudflare → 必须启动（文档承诺的启用方式）
  if (!isStarted("cloudflared", new Set(["cloudflare"]), NONE))
    die("带 --profile cloudflare 时 cloudflared 不启动 —— 文档承诺的启用方式失效");
  // (d) 无关 profile → 仍必须不启动（防止 profiles 写成通配/空值导致"任何 profile 都激活"）
  if (isStarted("cloudflared", new Set(["somethingelse"]), NONE))
    die("无关 profile 也能激活 cloudflared —— profiles 声明退化");

  console.log("  [profiles] 求值通过: 默认=不启动 / --profile cloudflare=启动 / 显式点名=启动");
' "$CF" || fail cloudflare-default-not-deployed

# ---------------------------------------------------------------------------
# 9) 结构校验层（取决于解析器是否可得）
#    只在 js-yaml / yaml 可得时做真解析；不可得时**显式打印降级提示**。
#    绝不静默：降级必须让读者知道"哪些校验没做"。
# ---------------------------------------------------------------------------
YAML_PARSER=$(node -e '
  for (const m of ["js-yaml", "yaml"]) {
    try { require.resolve(m); process.stdout.write(m); process.exit(0); } catch {}
  }
  process.exit(1);
' 2>/dev/null || true)

if [ -n "$YAML_PARSER" ]; then
  echo "  [YAML] 使用结构解析器: $YAML_PARSER（附加结构校验）"
  node -e '
    const fs = require("fs");
    const mod = process.argv[1];
    const file = process.argv[2];
    const doc = (mod === "js-yaml")
      ? require("js-yaml").load(fs.readFileSync(file, "utf8"))
      : require("yaml").parse(fs.readFileSync(file, "utf8"));
    const die = (m) => { console.error("FAIL cloudflare-structural: " + m); process.exit(1); };
    if (!doc || typeof doc !== "object") die("顶层不是映射");
    if (!doc.services || typeof doc.services !== "object") die("缺少 services 映射");
    const svc = doc.services.cloudflared;
    if (!svc || typeof svc !== "object") die("services.cloudflared 不是映射");
    if (!Array.isArray(svc.profiles) || svc.profiles.indexOf("cloudflare") === -1)
      die("services.cloudflared.profiles 不包含 cloudflare（默认不部署机制失效）");
    if (svc.ports) die("services.cloudflared 不应声明 ports");
    if (String(svc.image || "").indexOf("cloudflare/cloudflared") === -1)
      die("services.cloudflared.image 不是 cloudflare/cloudflared");
    console.log("  [YAML] 结构校验通过: services.cloudflared.profiles 含 cloudflare");
  ' "$YAML_PARSER" "$CF" || fail cloudflare-structural-check
else
  # 显式降级提示 —— 不是可选的礼貌输出，而是"我没做结构校验"的诚实声明。
  echo "  [DROP] 未找到 js-yaml / yaml 模块（仓库无 YAML 依赖，宿主无 python3）。"
  echo "  [DROP] 已降级为**纯文本断言**：按缩进切出 cloudflared 服务段后逐行精确匹配。"
  echo "  [DROP] 未执行的结构校验：整份 YAML 的完整语法合法性（嵌套/锚点/多文档等）。"
  echo "  [DROP] 已覆盖：services 顶层键、cloudflared 段存在性、profiles/image/command/environment。"
fi

echo 'ALL-PASS'
