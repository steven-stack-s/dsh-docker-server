# 04 · Troubleshooting

> [English](04-troubleshooting.md) | [简体中文](../zh-CN/04-故障排查.md)

| Symptom | Cause | Fix |
|---|---|---|
| Container restarts repeatedly, logs `listen EADDRINUSE 127.0.0.1:3080` | The old entrypoint makes socat and dsh fight over the same port | Make sure you use this repo's entrypoint (socat listens on 3080, dsh on 3081) and rebuild the container |
| Errors at startup like `plugin tree failed to load` / `node:zlib` | The base image's Node version is too old | Use this repo's Dockerfile (`node:24-slim`; DSH requires Node ≥ 22.18) |
| The page opens but `/api/...` returns 403 | Not authenticated (the auth plugin is installed by default) or the Host is not allow-listed (with `DSH_SETUP_REMOTE=off`) | Default setup: log in as `admin` with the password from the first-boot log (see [02](02-authentication-remote-access.md)); after login the Host is normalized to loopback, so no allow-list is needed. With the plugin off: set `DSH_TRUSTED_HOSTS` in `.env` (see [01](01-quick-start.md)) |
| Can't find the initial admin password | It is printed **only on the run that created the account** (so it never lands in every `docker logs`) | **Recover it from the credentials archive first** (no reset needed): `docker exec dsh grep -A8 'id: remote' /data/dsh/profiles/web/cordis.patch.yml` — the first-boot password is written there in clear text (0600). It is in the log too: `docker logs dsh 2>&1 \| grep -A9 'first-boot admin credentials'` |
| No password banner on first boot, yet login asks for one | The volume **already holds an account** (a prior manual dsh-remote install, or this is not the first boot) | The image deliberately **never overwrites existing accounts**: log in with your original credentials; if truly lost, recover the archive as above, or delete `<DSH_DATA_DIR>/auth/store.json` and `docker restart dsh` to regenerate (⚠ wipes all accounts and MFA) |
| Login says `too many attempts; retry in Ns` | The auth plugin's **login rate limit**: max 5 failures per 15-minute window (not a failure) | `docker restart dsh` clears it immediately — the counters live in memory only, so **do not wait out the N seconds**. Then verify the password (row above), minding uppercase `O` vs digit `0` and digit `1` vs lowercase `l` |
| LAN access still returns 403 with the plugin installed | Browser holds a stale frontend that does not match the new plugin | Hard-refresh or reopen in a private window (server logs look normal in this case — not a failure) |
| Settings page shows `settings are unavailable in this browser` | DSH design: settings are loopback-only | Not a blocker; change settings with curl from the host via `/api/settings.mutate` (see below) |
| `crypto.randomUUID is not a function` | Accessing from a non-HTTPS / non-localhost origin (browser secure context) | Use `localhost`, an SSH tunnel, or a reverse proxy with HTTPS (see [02](02-authentication-remote-access.md)) |
| Copying from the seed on first boot is slow | Windows + WSL bind mount crosses filesystems | Seconds on Linux; on Windows, use a docker named volume or wait for the first copy |
| `docker compose up` reports `DEEPSEEK_API_KEY` not set | `.env` is not configured | Run `cp .env.example .env` and fill in the key |
| Container won't start / repeated crashloop | Broken plugin fails to boot; auto-rollback didn't fire (no snapshot / RESCUE_AUTO=off / RESCUE_SELFHEAL=off / rescue tooling not installed) | Check the logs for `selfheal rollback to` / `no-evidence fallback: rollback to` / `booting clean lifeboat profile` markers, then inspect attribution with `docker exec dsh rescue report`; rebuild the image or enter the lifeboat with `RESCUE=1` to remove the bad plugin (see [06 · Rescue Mode](06-rescue-mode.md)) |

## Configure models with curl on the host

When the settings page is unavailable, you can read and mutate settings from the host with curl.

```bash
# 1. Log in and grab the cookie (the auth plugin is enabled by default; skip if DSH_SETUP_REMOTE=off)
#    Username defaults to admin; the password is in the first-boot log:
#    docker logs dsh 2>&1 | grep -A9 'first-boot admin credentials'
curl -s -c /tmp/dsh-cookies.txt -X POST http://127.0.0.1:3080/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"你的用户名","password":"你的密码"}'

# 2. Inspect the current settings
curl -s -b /tmp/dsh-cookies.txt -X POST http://127.0.0.1:3080/api/settings.describe \
  -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"r1","method":"settings.describe","payload":{}}'

# 3. Mutate the llm-deepseek namespace (e.g. baseURL)
curl -s -b /tmp/dsh-cookies.txt -X POST http://127.0.0.1:3080/api/settings.mutate \
  -H 'Content-Type: application/json' \
  -d '{"type":"client-request","rpcId":"r2","method":"settings.mutate","payload":{"ns":"llm-deepseek","ops":[{"op":"set","path":["baseURL"],"value":"https://api.deepseek.com"}]}}'
```

## Startup / runtime crash: check auto-attribution and incident report first

If dsh web fails to start or crashes at runtime, the container automatically **attributes and records an incident** under `$DSH_HOME/.rescue/`. Run:

```bash
docker logs dsh --tail 100 | grep -iE 'diagnose|heal|incident|rollback|lifeboat'   # entrypoint attribution / self-heal trail
docker exec dsh rescue report                                                 # incident overview (phase/root-cause/offender/outcome)
docker exec dsh rescue report <id>                                            # expand one: rationale + self-heal actions + redline assertion
docker exec dsh rescue incident list
tail -30 /data/dsh/.rescue/log/rescue.log                                     # audit log (in the volume, browsable offline)
```

> Redline note: the automated diagnosis only reads evidence and only touches the four plugin-tree files plus `.rescue` state. `redline.cordisPatchTouched` is guaranteed `false` by construction; a `true` means some code crossed the redline — stop and intervene manually, and if recovery still fails, enter the lifeboat with `RESCUE=1` (see 06-rescue-mode).

**Reading the outcome:** `report-only` = auto-attribution found no plugin cause / no baseline, no auto change — needs a human; `recovered-remove` / `recovered-rollback` = recovered by auto-removing a plugin or rolling back a snapshot. If `rootCause.category=unknown` and it keeps returning report-only, it is usually a non-plugin issue (program / upgrade / resources) — see 03-upgrade-maintenance for the `dsh-reinstall` fallback.

## Collect diagnostics


When reporting a problem, please attach:

```bash
docker ps | grep dsh
docker logs dsh --tail 50
docker exec dsh dsh --version
```
