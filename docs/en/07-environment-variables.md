# 07 · Environment Variables

> **English** | [简体中文](../zh-CN/07-环境变量速查.md)

This is the **full reference for advanced env vars** that live in `docker-compose.yml`'s `${VAR:-default}` fallbacks
but are not listed in `.env.example`.

`.env.example` only lists the 12 vars used in daily deployment (see the file header). The remaining ~25 vars do not
need to be touched by most users. To customize, **pick one** of the two override methods:

- **Method A · edit the compose default** — change the `${VAR:-default}` expression directly in `docker-compose.yml`,
  e.g. turn `mem_limit: ${MEM_LIMIT:-2g}` into `mem_limit: ${MEM_LIMIT:-3g}`.
- **Method B · append the same var in `.env`** — `docker compose` treats vars present in `.env` as overrides for the
  `${VAR:-...}` defaults. Note that values in `.env` do **not** propagate into the container `environment:` block
  unless compose explicitly lists them; this method only works for vars that appear as `${VAR:-...}` somewhere
  in `docker-compose.yml`.

---

## 1. Self-heal / Lifeboat (RESCUE_*)

| Variable | Default | Meaning |
|---|---|---|
| `RESCUE_START_TIMEOUT` | `120` | Lifeboat's wait-for-dsh-ready probe timeout (seconds). **Must be < the compose healthcheck `start_period`** (default 300s) — otherwise the lifeboat will give up before docker does and roll back a still-cold-booting dsh. |
| `RESCUE_KEEP` | `3` | Number of most-recently-usable snapshots retained. The newest healthy baseline is pinned and never rotates. |
| `RESCUE_MAX_ATTEMPTS` | `4` | Boot retry cap. Defaults to `RESCUE_KEEP + 1`. |
| `RESCUE_EVIDENCE_KEEP` | `3` | Number of `evidence/boot-*` evidence dirs to retain. Defaults to `RESCUE_KEEP`. |
| `RESCUE_PROFILE` | `web` | Target profile for rollback (`web` = Web UI; `cli` etc. are also available). |
| `RESCUE_SELFHEAL` | `on` | Master self-heal switch. AND-ed with `RESCUE_AUTO`: if either is `off`, the system diagnoses but does not auto-change. |
| `RESCUE_REMOVE_LIMIT` | `2` | Per-container-lifetime cap on auto plugin removals. |
| `RESCUE_ROLLBACK_LIMIT` | `2` | Per-container-lifetime cap on snapshot rollbacks. |
| `RESCUE_DIAGNOSE_EVIDENCE` | `on` | Whether to tee each dsh boot output into `$DSH_HOME/.rescue/evidence/`. |
| `RESCUE_EVIDENCE_MAX` | `20971520` | Per-`dsh.log` rotation cap (bytes). |
| `RESCUE_INCIDENT_KEEP` | `20` | `$DSH_HOME/.rescue/incidents` retention count. |
| `RESCUE_SNAPSHOT_ON_HEALTHY` | `on` | Whether to auto-capture a "proven to boot" baseline snapshot. Occupies a slot in `RESCUE_KEEP`; the newest is pinned. |
| `RESCUE_SNAPSHOT_MODE` | `hardlink` | `hardlink` = `cp -al` (seconds, almost free, but shares inodes with live tree — **any in-place rewrite contaminates history**; run `rescue verify` to detect). `copy` = `cp -a` (truly immutable, at the cost of full `node_modules` duplication). |
| `RESCUE_SELFHEAL_WINDOW` | `86400` | Sliding window (seconds) for self-heal budgets. Within the window, auto actions count toward the cap; once the window expires, the counters reset. |
| `RESCUE_AUTO_LIFEBOAT` | `on` | Whether to auto-degrade into the lifeboat after self-heal has exhausted its budget. |
| `TMPDIR` | `/data/dsh/tmp` | Temp-file root. **Defaults to the data volume** instead of the tmpfs `/tmp` (which is capped at 128m and fills up while dsh runs temporary tasks / verification tests). dsh's tool-output spill, command-output spool and workspace-change capture all use `os.tmpdir()` and follow this. Reclaim with `rescue clean`. |
| `RESCUE_TMP_KEEP_MIN` | `1440` | Retention window (minutes) for `rescue clean` when reclaiming dsh temp artifacts under `TMPDIR`. Anything newer is treated as possibly in use and never deleted. |

See [06 · Rescue Mode](06-rescue-mode.md). While debugging, set `RESCUE_AUTO=off` and `RESCUE_SELFHEAL=off` so the
system only diagnoses and writes incidents.

---

## 2. Resource limits / runtime

| Variable | Default | Meaning |
|---|---|---|
| `NODE_MAX_OLD_SPACE` | `1024` | Node heap cap (MB). DSH is multi-process; the actual RSS (main + children + client bundle) far exceeds the heap. **The heap must be much smaller than `MEM_LIMIT`** — a good rule: the RSS estimated as `NODE_MAX_OLD_SPACE * 1.5` should stay below half of `MEM_LIMIT`. Otherwise dsh gets OOM-killed by the container (symptom: silent dropped conversations, FATAL ERROR). |
| `PIDS_LIMIT` | `512` | Container process-count cap. socat in fork mode spawns one process per connection; without a cap, concurrent connections can exhaust the container. |
| `SOCAT_MAX_CHILDREN` | `64` | socat concurrent-connection cap. Unbounded external concurrency can exhaust container memory. |
| `MEM_LIMIT` | `2g` | Container memory cap. The N100 + 8GB example leaves headroom for the host OS. |
| `CPU_LIMIT` | `2` | Container CPU cap. |
| `TZ` | `Asia/Shanghai` | Container timezone. Affects all container logs and scheduled tasks. |

---

## 2.5 Security hardening (non-root run / capability / read-only)

Since v0.4.6 the image runs as a **non-root** user and tightens capabilities + read-only root FS:

- **Run user**: the in-image `node` user (uid 1000 gid 1000). The entrypoint first runs as root to seed
  `/opt/dsh` and `chown` the three mounted volumes to the run user, then uses `setpriv` to drop to
  uid 1000 before running dsh / socat / upgrades / rescue. Persistent in-container processes are **not root**.
- **`USER_UID` / `USER_GID`**: override the non-root run user (**usually unnecessary** — leaving them
  unset means `1000:1000`, defaulted by both compose (`${USER_UID:-1000}`) and the entrypoint, and the
  image's built-in `node` user is already `1000`, which matches most NAS/host first non-root users and
  the three mounted volumes). Only override when the volumes on the host are owned by a **different**
  uid and you want to run as that uid.
  ⚠ Prefer a uid that exists in the container's `/etc/passwd` (`1000` = the built-in `node` user):
  `setpriv --init-groups` needs to resolve a username. An unresolvable uid does **not** break startup —
  the entrypoint falls back to dropping privileges **without supplementary groups** (uid/gid still honored).
  (The old note "must equal the Dockerfile build args" was wrong: the image no longer declares those
  build args — they were dead parameters.)
- **Capability convergence** (`docker-compose.yml`): `cap_drop: [ALL]` + minimal allowlist
  `cap_add: [CHOWN, DAC_OVERRIDE, SETUID, SETGID]`. These four are only needed for first-boot
  `chown` of the volumes and `setpriv` uid drop; runtime dsh/agent processes (uid 1000) lack them.
- **Read-only root FS**: `read_only: true` + `tmpfs /tmp` (128m). Only volumes and /tmp are writable.
  **dsh's own temp files do not go to /tmp**: `TMPDIR` defaults to the data volume `/data/dsh/tmp`
  (see `TMPDIR` in §1) — /tmp is a hard 128m in-memory cap that fills quickly while dsh runs
  temporary tasks / verification tests, and after the move /tmp only holds a few system-level
  temp files.
  `NPM_CONFIG_CACHE` defaults to `/opt/dsh/.npm-cache` (inside a writable volume, created and `chown`ed
  to the run user on first boot; usable by both root `docker exec npm` and the node user) so
  `npm install -g` upgrades and rescue cleaning still work.
- **Native addon & HMR — this project no longer touches HMR.** HMR relies on the loader hook
  provided by a native addon (`node-addon-require-builtin`); if that binding fails to load under a
  read-only root FS, dsh throws `--expose-internals is required for HMR service` and crashes (older
  versions did exactly that). **That root cause is fixed by two other layers, not by the HMR switch**:
  the Dockerfile's `NARB_DISABLE_NATIVE_CACHE=1` (the binding loads from the executable volume
  `/opt/dsh` instead) and `tmpfs /tmp:size=128m,exec` in `docker-compose.yml` (Docker's tmpfs
  defaults to `noexec`).
  Since **v0.6.1** this project injects **no `--patch` overlay to disable HMR** — HMR fully follows
  the dsh default (on for the `web` profile). Two findings drove that decision:
  ① measured on dsh 0.2.0-rc.2, starting **without** the overlay is completely normal — no
  `--expose-internals` error; and
  ② more importantly, the process shows **zero inotify handles either way** — HMR's chokidar watcher
  never started in this environment. In other words the disabling layer was **a no-op all along**,
  while costing this project a "turns off an upstream feature" patch and, worse, **masking the real
  signal that the binding is unavailable** (the same root cause makes third-party plugins fail with
  `ERR_MODULE_NOT_FOUND`).
  > ⚠ So if your **own compose** overrides those two fixes (e.g. drops `tmpfs … ,exec` or changes
  > `NARB_DISABLE_NATIVE_CACHE`), verify the binding still loads — otherwise the symptom is either a
  > failing dsh boot or every third-party plugin failing to load. The historical implementation lives
  > in git history (`scripts/hmr-off.yml` was deleted). Note also that as of 0.1.6-alpha.2 the profile
  > manifest's `patchReload` field was removed upstream, so **do not** try to disable HMR through that
  > field (`test-dockerfile-hygiene.sh` guards against it).
- **NAS / kernel caveat**: `cap_drop:[ALL]` may affect in-volume permissions and hard links
  (rescue snapshot `hardlink` uses `cp -al`) on some NAS storage backends (NFS / certain storage pools).
  Verified in this repo's e2e sandbox; before deploying to a target platform, run
  `scripts/t/e2e-container-selftest.sh` to confirm volume permissions and the rescue chain.
- These hardenings are not toggleable (default security posture); edit `docker-compose.yml` manually
  for looser behavior.

---

## 3. Build & image

| Variable | Default | Meaning |
|---|---|---|
| `DSH_IMAGE` | `ghcr.io/steven-stack-s/dsh-docker-server:latest` | Image pulled at `up`. To pin a version explicitly, use the `v<project>-dsh-<dsh>` tag scheme. |
| `DSH_VERSION` | (not in compose) | **For manual `docker build` only** (`--build-arg DSH_VERSION=<version>`): pins the dsh version baked into the seed. Compose **deliberately exposes no local build path** — when `image:` and `build:` share one tag, `docker compose up -d` silently falls back to building from the current directory instead of failing, so switching `DSH_IMAGE` to a tag that is not published yet would quietly run an image built from stale code (hit on a real deployment, 2026-09-17). See the comment above `services:` in `docker-compose.yml`. |
| `PNPM_VERSION` | (not in compose) | Same as above — manual `docker build` only; pins the pnpm version baked into the seed. |
| `REMOTE_PLUGIN_VERSION` | (not in compose) | Same as above — manual `docker build` only: version of the default auth plugin (`@xgone/dsh-remote`) baked into the image. **Empty** (`--build-arg REMOTE_PLUGIN_VERSION=`) builds an image without the plugin, and first boot falls back to unauthenticated LAN-direct mode automatically. |
| `REMOTE_PLUGIN_NAME` | (not in compose) | Same as above — manual `docker build` only: package name of the default auth plugin (default `@xgone/dsh-remote`), for forks or private registries. |
| `DSH_REMOTE_SEED` | `/opt/dsh-remote-seed` | Location of the plugin's offline copy inside the image. The entrypoint copies it into the profile on first boot, **with no network access**. Normally no change needed; set it only if your custom image moved that path. |

---

## 3.5 Default auth plugin (@xgone/dsh-remote)

Since v0.6.0 the image **installs and enables** the auth plugin by default and provisions an admin
account on first boot:

| Variable | Default | Meaning |
|---|---|---|
| `DSH_SETUP_REMOTE` | `on` | Master switch. `off` = install no plugin and create no account, restoring the historical behaviour (no auth layer, LAN-direct only). In that mode, reaching DSH by LAN IP requires `DSH_TRUSTED_HOSTS`, otherwise `/api` returns 403. |
| `DSH_DEFAULT_ADMIN_USER` | `admin` | Username of the first admin. **Used only while the account store is empty** — once `$DSH_HOME/auth/store.json` holds an account this is ignored (no rename, no password reset). |
| `DSH_ADMIN_PASSWORD` | (empty) | Password of the first admin. **Empty = a random 16-character password** is generated and printed to the first-boot log (recommended). If set, nothing is printed (handy when a password manager holds it); it must be at least 6 characters. |

**Get the password** (printed only on the run that actually creates the account):

```bash
docker logs dsh 2>&1 | grep -A9 'first-boot admin credentials'
```

> 📌 **If the log has rotated away, that is fine**: the password is also written in clear text to
> `$DSH_HOME/profiles/web/cordis.patch.yml` (mode 0600), so you can always recover it —
> **no account reset needed**:
>
> ```bash
> docker exec dsh grep -A8 'id: remote' /data/dsh/profiles/web/cordis.patch.yml
> ```
>
> The first-boot log banner prints this path as well (`stored   : ...`).

**Behaviour details** (each one is easy to misread, so they are spelled out):

1. **The password is printed once.** The criterion is whether the account store has an account — not
   how many times the container started. Once the account exists, neither restarts nor container
   recreation print it again; otherwise the password would land in every `docker logs` capture,
   and logs get forwarded, archived and pasted into issues. If you lose it, delete
   `$DSH_HOME/auth/store.json` (i.e. `<DSH_DATA_DIR>/auth/store.json`) and restart — **that removes
   every account and all MFA configuration**.
2. **Existing accounts are never overwritten.** When the store is non-empty the plugin ignores the
   `bootstrap` section in the config and logs a warning, so a password you changed yourself is not
   reset by the image.
3. **The plaintext does land on disk**: `bootstrap.password` in
   `$DSH_HOME/profiles/web/cordis.patch.yml` is stored in clear text (file mode 0600, owner-readable
   only). That is the plugin's documented approach and the only way to provision credentials without
   a browser. After the first login, change the password and enable MFA; once changed, that section
   becomes inert (the account exists, so `bootstrap` is no longer read).
4. **Works offline**: the plugin copy ships inside the image (`DSH_REMOTE_SEED`) and is copied into
   the profile on first boot, with no network access — the same seed mechanism as dsh itself, so
   NAS/intranet deployments get authentication out of the box.
5. **The image never downgrades it**: if the profile already carries the plugin, the entrypoint
   **leaves it alone** — a version you upgraded with
   `dsh plugin add @xgone/dsh-remote@<newer>` is preserved (upgrades go through `dsh plugin`; the
   image seed only handles the "from nothing" case).

---

## 3.6 Advertised public root (--public-url)

| Variable | Default | Meaning |
|---|---|---|
| `DSH_PUBLIC_URL` | (empty) | The advertised public root; **empty = disabled**. Inside the container dsh listens on `127.0.0.1` only, and both the URL line it prints and the **system prompt handed to the model** name that in-container address (`127.0.0.1:3081`) — hence "the link in the log won't open" and "the address the model gave me won't open". Set the real external address to have dsh `--public-url` advertise the correct URL. |
| `DSH_PUBLIC_URL_MIN_VERSION` | `0.2.1-alpha.1` | Capability-guard floor, normally left alone. `--public-url` is appended only when the dsh version in the volume is ≥ this value; earlier dsh **does not know** the option and exits 1 on it, chaining into the self-heal budget. A malformed value falls back to the default and logs one line. |

**What it changes** — exactly four outputs: the printed startup URL line, the default-browser
handoff, the web-surface prompt (the one given to the model), and the `DSH_WEB_URL` environment
variable. The printed and opened forms carry the process credential; the other two are clean URLs.

> ⚠ **It only *advertises* — it grants no trust.** The browser-visible authority must still be named
> with `DSH_TRUSTED_HOSTS` (or covered by a signed-in session when `dsh-remote` is installed). It
> **configures no listener, routing, or cookie scope** — the external leg belongs to your reverse
> proxy. The two settings are **orthogonal**: setting `DSH_PUBLIC_URL` does not admit that Host.

**Format**: an absolute http(s) URL, optionally with a path prefix; it must **not** carry
credentials (`@`), a query or fragment (`?`/`#`), or whitespace. Invalid values are dropped with a
`WARN` line in the startup log.

```bash
# reverse proxy with a path prefix
DSH_PUBLIC_URL=https://app.example.com/dsh/
# direct LAN access (IP + host-side port)
DSH_PUBLIC_URL=http://192.168.1.50:3080/
```

> 📌 Once set, `DSH_WEB_URL` inside the agent's bash is **no longer the loopback address**. Any
> script relying on it for a local liveness probe needs adjusting.

---

## 3.7 Cloudflare Tunnel (cloudflared)

When your home connection is behind CGNAT (no public IP) and port forwarding is not an option, the
outbound tunnel shipped in `docker-compose.cloudflare.yml` gives dsh public reachability. It is
**not deployed by default** — leaving these variables unset changes nothing.

To enable (note **three similar-looking names that are three different things**: `-f` takes the
file, `--profile` takes the profile, and the service is `cloudflared`):

```bash
docker compose -f docker-compose.yml -f docker-compose.cloudflare.yml --profile cloudflare up -d
```

| Variable | Default | Meaning |
|---|---|---|
| `TUNNEL_TOKEN` | (empty) | Tunnel credential (token mode): a long `eyJ...` base64 string obtained when creating the tunnel in the Cloudflare Dashboard. **Empty = cloudflared exits with `unauthorized` after start; dsh is entirely unaffected.** This is the only tunnel variable registered in `.env.example` (at the end, and **still commented out** — uncomment and fill it in yourself). ⚠ It is a secret: keep `.env` git-ignored and `chmod 600 .env`. |
| `CF_CONTAINER_NAME` | `dsh-cloudflared` | The cloudflared **container name** (the compose service name is always `cloudflared` and is not configurable). The `dsh-` prefix makes ownership obvious in host `docker ps` and avoids name collisions with unrelated `cloudflared` containers elsewhere. |
| `CF_MEM_LIMIT` | `256m` | cloudflared container memory cap. cloudflared is very light (Go static binary + a few goroutines); 256m is comfortably enough. |
| `CF_CPU_LIMIT` | `0.5` | cloudflared container CPU cap. The tunnel only forwards traffic; it needs no more. |
| `CF_PIDS_LIMIT` | `128` | cloudflared container process-count cap. |

**Where the defaults live**: the `CF_*` four and the `TUNNEL_TOKEN` fallback all live in
`docker-compose.cloudflare.yml`'s `${VAR:-default}` expressions, **not in `docker-compose.yml`**
(the tunnel is a separate additive layer and overrides no field of the main compose file). To change
a default, use **Method A or B** from the top of this document: edit the `${VAR:-...}` in that compose
file, or append the same variable in `.env`.

> ⚠ **`TUNNEL_TOKEN` falls back to `${TUNNEL_TOKEN:-}` (empty string), not `${TUNNEL_TOKEN:?}`
> (hard failure)** — deliberately. Per the compose-spec, variable interpolation happens while
> **reading the file and building the project model**, i.e. **before profile filtering**. With `:?`,
> merely passing `-f docker-compose.cloudflare.yml` on the command line would make `config` / `ps` /
> `up -d` all fail on the missing token even when you never enable the tunnel. That escalates a
> mistake that **should only affect the tunnel** into "the whole compose command is unusable", which
> is unacceptable for someone who just cloned the repo to run dsh. With `:-`, the consequence stays
> inside the tunnel layer: cloudflared reports `unauthorized` and exits (`restart: unless-stopped`
> keeps retrying, and it never comes up), with an obvious diagnostic entry point:
> `docker compose ... logs cloudflared | grep -i 'unauthorized\|token'`.
>
> 📌 The claim that interpolation precedes profile filtering **rests on the compose-spec text and has
> since been confirmed on real hardware** (2026-10-09). One reason `:-` was chosen is still that it
> does **not** depend on that implementation detail: whether or not compose interpolates services of
> disabled profiles, `:-` errors in neither the "unset" nor the "empty" case. To keep a strict check
> on the caller's side, add a preflight yourself:
> `[ -n "$(grep -E '^TUNNEL_TOKEN=.+' .env)" ] || { echo 'TUNNEL_TOKEN not configured'; exit 1; }`

> ⚠ **The `CF_*` four exist only as `${VAR:-default}` in `docker-compose.cloudflare.yml`**;
> `docker-compose.yml` never references them. That differs slightly from this document's opening
> statement that the vars live in `docker-compose.yml` fallbacks — it follows from the tunnel being
> an additive layer.

Other tunnel behaviour (`profiles` gating, `depends_on` waiting for dsh to be healthy, no mapped
ports, resource and log caps, and the optional further-hardening checklist) is documented in the
header comments of `docker-compose.cloudflare.yml` and in the "Cloudflare Tunnel" section of
[02 · Authentication & Remote Access](02-authentication-remote-access.md).

---

## 4. Toolchain

| Variable | Default | Meaning |
|---|---|---|
| `NPM_REGISTRY` | `https://registry.npmmirror.com` | npm/pnpm registry used inside the container (for initial install, dsh upgrades, pnpm install). Keep the default in CN; switch to `https://registry.npmjs.org` for deployments outside CN. |
| `NPM_CONFIG_CACHE` | `/opt/dsh/.npm-cache` | npm/pnpm download cache directory inside the container. Defaults to a writable dir inside a mounted volume (under a read-only root FS `/root/.npm` is unwritable and would break upgrades); override only to another writable path. The cleanup command (`rescue clean`) empties the `_cacache` inside it. |

---

## 5. Credentials

| Variable | Default | Meaning |
|---|---|---|
| `DEEPSEEK_API_KEY_FILE` | (empty) | Mount the model key from a file (docker secret / bind mount) instead of an env var. **Takes priority over `DEEPSEEK_API_KEY`** so the key never appears in `docker inspect`. Example: `DEEPSEEK_API_KEY_FILE=/run/secrets/deepseek_api_key`. |

---

## 6. Debugging tips

- **Inspect the resolved env**: `docker compose config` prints the fully-rendered YAML, including the final value of every `${VAR:-...}`.
- **Diff `.env` vs defaults**: `docker compose config | grep -E '^\s*- [A-Z_]+=' | sort` lists every env that enters the container.
- **One-off override without polluting `.env`**: `VAR=value docker compose up -d`.
