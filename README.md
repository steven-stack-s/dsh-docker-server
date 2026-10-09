**English** | [简体中文](README.zh-CN.md)

# Deploy DeepSeek Harness (DSH) with Docker

[![GitHub Release](https://img.shields.io/github/v/release/steven-stack-s/dsh-docker-server?sort=semver&color=5965d8)](https://github.com/steven-stack-s/dsh-docker-server/releases)
[![Image Build](https://github.com/steven-stack-s/dsh-docker-server/actions/workflows/docker-image.yml/badge.svg)](https://github.com/steven-stack-s/dsh-docker-server/actions/workflows/docker-image.yml)
[![GHCR](https://img.shields.io/badge/ghcr.io-dsh--docker--server-2496ED?logo=docker&logoColor=white)](https://github.com/steven-stack-s/dsh-docker-server/pkgs/container/dsh-docker-server)
[![DeepSeek Harness](https://img.shields.io/badge/DeepSeek%20Harness-0.2.1--alpha.1-4aa3ff)](https://github.com/deepseek-ai/deepseek-harness)
[![License](https://img.shields.io/github/license/steven-stack-s/dsh-docker-server?color=3b7a57)](https://github.com/steven-stack-s/dsh-docker-server/blob/main/LICENSE)

> Deploy [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH) — DeepSeek's official AI coding agent framework (Web UI + CLI) — on **any Docker environment** with one command.

---

## ✨ Highlights

**🧱 Architecture — three-layer separation, ready in seconds, upgrades without image rebuilds**

- **Version-pinned at build + in-image seed** — dsh+pnpm are pre-installed into a seed (`/opt/dsh-seed`) at build time; on first boot the seed is copied to `/opt/dsh` (offline, version-pinned, ready in seconds). The seed stays in the image layer, so a broken main program can be restored offline.
- **Program decoupled from image, upgraded in-container** — the DSH program lives on a mounted volume; daily upgrades are `docker exec dsh npm install -g @deepseek-ai/dsh@<version> && docker restart dsh` — no image rebuild needed. **An image upgrade carries dsh along**: on startup the entrypoint compares the image seed with the dsh in the volume and syncs when the seed is newer (see [docs 03](docs/en/03-upgrade-maintenance.md)).
- **Fully persisted data** — three separate volumes for program / user data (sessions, configs, plugins, memory) / workspace; backup = copy the directory.
- **Access control available out of the box** — ships the [dsh-remote](https://github.com/xgone/dsh-remote) auth plugin (password + MFA) and creates `admin` with a **random 16-character password** on first boot, printed to the first-boot log (**once only**). The plugin is baked into the image as an offline seed, so intranet/NAS deployments get authentication too. To go back to unauthenticated LAN-direct mode: `DSH_SETUP_REMOTE=off`.
- **Secure by default** — `dsh web` intentionally listens only on `127.0.0.1:3081` (official security design); `socat` forwards the external `3080` port into it.
- **Multi-architecture** — GitHub Actions automatically builds `linux/amd64` + `linux/arm64` images and publishes them to `ghcr.io`.

**🛟 Self-healing — deterministic root-cause analysis, red-line-guarded auto recovery**

- **Deterministic root-cause analysis (no LLM)** — `diagnose.js` attributes boot failures with a rules table + change context and recommends an action (`remove-plugin` / `rollback` / `report-only`); unit-testable, auditable, and predictable.
- **Hard red lines** — auto-recovery touches only the plugin-tree four-piece set (package.json / pnpm-lock.yaml / pnpm-workspace.yaml / node_modules) plus `.rescue` state, **never cordis.patch.yml / sessions / memory / configs / credentials**.
- **Complete fallback ladder** — snapshot rollback → plugin removal → escalated rollback → report-only → lifeboat; every rung has a budget cap and full audit logging.
- **Near-zero-cost snapshots + evidence loop** — `cp -al` hard-link snapshots (auto-degrades to `cp -a` across filesystems); boot output flows through a fifo with per-line timestamps, dual-written to docker logs and evidence, so failures are always traceable.

---

## 📦 Quick Start (3 steps)

```bash
# 1. Clone and configure
git clone https://github.com/steven-stack-s/dsh-docker-server.git && cd dsh-docker-server
cp .env.example .env            # edit .env, fill in DEEPSEEK_API_KEY (the rest can stay at defaults)

# 2. Start (on first boot, DSH is copied from the in-image seed; ready in seconds)
docker compose up -d

# 3. Get the initial admin password — printed ONCE in the first-boot log
docker logs dsh 2>&1 | grep -A9 'first-boot admin credentials'
#    username: admin, password: a random 16-character string; log in at http://<host-ip>:3080
#    (then change it and enable MFA under Settings → Login & Account)

# 4. If the UI asks for a one-time token, it is printed in docker logs too, e.g.
#    http://<host-ip>:3080/?token=<token> (later visits need no token)
```

> 🔐 **Authentication is ON by default.** First boot installs the `@xgone/dsh-remote` auth plugin and
> creates an admin account — the password is **printed once only**, and restarts or container
> recreation will not show it again (so it never lands in every `docker logs` capture).
> Lost it? Delete `<DSH_DATA_DIR>/auth/store.json` and restart to get a fresh one (⚠ this wipes all
> accounts and MFA config). Prefer your own password? Set `DSH_ADMIN_PASSWORD` in `.env` (≥6 chars;
> nothing is logged then). To disable the auth layer (fully trusted intranet only):
> `DSH_SETUP_REMOTE=off`. See [docs/en/02-authentication-remote-access.md](docs/en/02-authentication-remote-access.md).

> 💡 `.env.example` only lists the vars used in daily deployment. Advanced knobs (self-heal details, resource
> tuning, npm registry, key-file mount, etc.) are defaulted in `docker-compose.yml` via `${VAR:-default}` — edit
> the compose file when you need them, or override in `.env` by adding the same variable. See the full reference:
> [docs/en/07-environment-variables.md](docs/en/07-environment-variables.md).

Detailed steps: [docs/en/01-quick-start.md](docs/en/01-quick-start.md)

---

## 📚 Documentation

| Doc | Content |
|---|---|
| [docs/en/01-quick-start.md](docs/en/01-quick-start.md) | Install, configure, token access, verify |
| [docs/en/02-authentication-remote-access.md](docs/en/02-authentication-remote-access.md) | Default auth, SSH tunnel, reverse proxy, Cloudflare Tunnel |
| [docs/en/03-upgrade-maintenance.md](docs/en/03-upgrade-maintenance.md) | Upgrade, plugins, keys, backup |
| [docs/en/04-troubleshooting.md](docs/en/04-troubleshooting.md) | Troubleshooting |
| [docs/en/05-platform-differences.md](docs/en/05-platform-differences.md) | Linux / NAS / Docker Desktop differences |
| [docs/en/06-rescue-mode.md](docs/en/06-rescue-mode.md) | Plugin rescue: auto-rollback + **auto-diagnose / root-cause / smart self-heal** + lifeboat, with `rescue report` incident review |
| [docs/en/07-environment-variables.md](docs/en/07-environment-variables.md) | Full reference for advanced env vars (default, purpose, override method) |

---

## 🔧 Directory Structure

```
.
├── docker-compose.yml        # deployment config (vars in .env.example)
├── Dockerfile                # base image: node:24 + git + socat + openssh-client + pre-baked dsh seed
├── scripts/                  # runtime code: container entrypoint, rescue CLI, shared library, probes
├── .env.example              # env template (copy to .env)
├── docs/
│   ├── en/                   # English docs
│   └── zh-CN/                # 简体中文文档
├── scripts/t/                # tests: unit tests + host-side end-to-end acceptance scripts
└── .github/workflows/        # CI: build image and publish to ghcr.io

> Running `scripts/t/test-*.sh` requires **node on the host** (6 of them invoke Node scripts such as
> diagnose.js / report.js / probe-ready.js; ubuntu-latest in CI ships it — on a bare shell host install
> node first, or run them with the node inside the container).
```

---

## 🏗️ Architecture

```
Browser
   |
   v
Host :3080 ──> container socat(0.0.0.0:3080) ──> dsh web(127.0.0.1:3081)
```

- At build time, dsh+pnpm are pre-installed into a seed (`/opt/dsh-seed`); the runtime also includes `node:24-slim` + git + ca-certificates + tzdata + socat + openssh-client.
- On first boot, `scripts/entrypoint.sh` copies the seed to the mounted volume `/opt/dsh` (in seconds, offline, version-pinned); pnpm comes along with the seed.
- Custom build: `docker build --build-arg DSH_VERSION=<version> --build-arg APT_MIRROR=mirrors.aliyun.com -t dsh-docker-server:<version> .`
- Three persistent volumes: `./programs` (DSH program), `./dsh` (DSH_HOME user data), `./workspace` (agent workspace).

---

## ⚠️ Security Notes

- `DEEPSEEK_API_KEY` lives only in `.env` (ignored by `.gitignore`) — never commit it.
- Do not expose port `3080` directly to the public internet; for remote access, add authentication + a reverse proxy / Cloudflare Tunnel
  (the latter suits **home connections with no public IP** — an outbound-only tunnel with no inbound port at all; see `docker-compose.cloudflare.yml`).
- Back up the whole deployment directory regularly.
- **Default security posture** (since v0.4.6): the container runs as a **non-root** `node` user
  (uid 1000, the entrypoint chowns the volumes on first boot, then `setpriv` drops privileges),
  with `cap_drop:[ALL]` (4 minimal caps kept), a read-only root FS (`read_only` + `tmpfs /tmp`) and
  `no-new-privileges`. The web process and plugins no longer run as root. Native-addon loading under
  a read-only root FS is fixed by two layers: `NARB_DISABLE_NATIVE_CACHE=1` (the binding loads from
  the executable volume `/opt/dsh`) and `tmpfs /tmp:…,exec`. **HMR is no longer touched by this
  project** — it fully follows the dsh default (since v0.6.1).
  See the "Security hardening" section in [docs/en/07-environment-variables.md](docs/en/07-environment-variables.md).
---

## 🏷️ Releases

Release history in [CHANGELOG.md](CHANGELOG.md). Image tags follow the dual-version scheme `v<project-version>-dsh-<dsh-version>` (e.g. `v0.5.4-dsh-0.1.7-rc.2`); pushing a tag in that format auto-builds multi-arch images to `ghcr.io`.

> To run a **pinned** dsh version, set `DSH_IMAGE=ghcr.io/steven-stack-s/dsh-docker-server:v<project-version>-dsh-<dsh-version>` in `.env` (its seed matches that exact dsh version). The default `:latest` is rebuilt on every tag push and tracks the newest published version — it is not a fixed build.

## 📄 License

[MIT](LICENSE)
