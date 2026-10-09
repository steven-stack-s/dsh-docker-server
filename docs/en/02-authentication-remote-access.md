# 02 · Authentication & Remote Access

> [English](02-authentication-remote-access.md) | [简体中文](../zh-CN/02-认证与远程访问.md)

**Since v0.6.0 the auth plugin is installed by default.** The image ships
[dsh-remote](https://github.com/xgone/dsh-remote) and provisions an admin account on first boot
(username `admin`, a random 16-character password). The password is printed **once** to the
first-boot log:

```bash
docker logs dsh 2>&1 | grep -A9 'first-boot admin credentials'
```

Use it to log in at `http://<host-ip>:3080`, then change the password and enable MFA under
Settings → Login & Account. To turn the auth layer off (back to unauthenticated LAN-direct mode),
see §3.

## 1. Access Overview

| Method | Security | Use case |
|---|---|---|
| Local access (`127.0.0.1:3080`) | Highest | Browser on the same machine |
| LAN-direct + account login (**default**) | High (password, MFA optional) | LAN usage |
| SSH tunnel | High (encrypted) | Temporary single-user access from outside |
| Reverse proxy + HTTPS | High (auth layer + HTTPS) | Long-term remote access, **with** a public IP |
| Cloudflare Tunnel | High (auth layer + Cloudflare edge TLS) | Long-term remote access, **without** a public IP |

> Browser limitation: some features of `dsh web` (e.g. `crypto.randomUUID`, settings) require a **secure context**
> (HTTPS or localhost). If you hit related errors when accessing the intranet directly by IP, that is the browser's security
> policy; use `localhost`, an SSH tunnel, or HTTPS via a reverse proxy instead.

## 2. Default Authentication (Works Out of the Box)

The image ships the auth plugin and installs it on first boot — **no manual step required**:

- **Account data** lives in `$DSH_HOME/auth/store.json` (inside the mounted volume, so it survives
  container rebuilds); passwords are stored as scrypt hashes.
- **The password is printed once**, only on the run that actually creates the account. Restarts and
  container recreation never show it again — otherwise the password would land in every
  `docker logs` capture (and logs get forwarded, archived and pasted into issues).
- **★ Lost the password / the log is gone? Recover it from the credentials archive.** Besides being
  logged, the first-boot password is **also written in clear text** to
  `$DSH_HOME/profiles/web/cordis.patch.yml` (mode 0600, readable by root/owner only), so you can
  retrieve it at any time — **no need to reset the account**:

  ```bash
  # Run on the host (docker exec defaults to root, so it can read the 0600 file)
  docker exec dsh grep -A8 'id: remote' /data/dsh/profiles/web/cordis.patch.yml
  ```

  The `bootstrap.username` / `bootstrap.password` values there are the initial credentials. The
  first-boot log banner prints this path too (`stored   : ...`), so you can note it down the
  moment you see the password.
- **If you really must reset** (e.g. the archive was erased too): delete
  `<DSH_DATA_DIR>/auth/store.json` and restart — a **fresh** random password is generated and printed.
  ⚠ This also wipes every account and all MFA configuration.
- **Want your own password?** Set `DSH_ADMIN_PASSWORD=<password>` (≥ 6 chars) in `.env`. Nothing is
  printed then (handy when a password manager holds it). It only applies while the account store is
  empty — an existing account is never overwritten.
- **Want your own username?** Set `DSH_DEFAULT_ADMIN_USER=<name>` in `.env` (same empty-store-only
  rule).

> How it works: on first boot the entrypoint writes `bootstrap: {username, password}` into
> `$DSH_HOME/profiles/web/cordis.patch.yml` (mode 0600); with an empty account store the plugin
> provisions the first admin from it (always role `admin`, and a root account that cannot be deleted).

## 3. Log In and Enable MFA

- Visit `http://<host>:3080` and log in as `admin` with the password from the first-boot log
- Settings → Login & Account → Two-factor authentication (MFA) → scan the QR code with Google Authenticator / 1Password
- **MFA is mandatory**: if exposed to the public internet via a reverse proxy, the auth layer is the only line of defense

> Change the password after the first login (Settings → Login & Account). Once changed, the plaintext
> `bootstrap` section in `cordis.patch.yml` becomes inert (it is not read when an account already
> exists). To scrub the plaintext entirely, delete the two `bootstrap:` lines from that file (keep
> `enabled: true`).

## 4. Turning Authentication Off (Back to LAN-Direct)

Authentication is **on by default**. If your deployment only ever runs on a fully trusted intranet
(or the local machine), you can disable it:

```bash
# .env
DSH_SETUP_REMOTE=off
```

```bash
docker compose up -d
```

With it off: no plugin is installed and no account is created — the historical behaviour, with
**no auth layer at all**. Reaching DSH by LAN IP or domain then requires `DSH_TRUSTED_HOSTS`,
otherwise the page opens but `/api` returns 403 (see §5).

> ⚠ Exposing `3080` to the public internet **while** auth is off means anyone who opens the page gets
> a session with full agent privileges (command execution, workspace read/write). Do not do that
> unless another layer (VPN / proxy-side auth) is in front.

## 5. Manual Installation / Upgrade

The image already carries it, so manual installation is normally unnecessary. To **switch versions or
reinstall**:

```bash
# Upgrade to a specific version (plugin & account data go into the /data/dsh volume, survive rebuilds)
docker exec dsh dsh plugin --profile web add @xgone/dsh-remote@<version>
docker restart dsh
```

> 💡 The entrypoint copies the plugin from the image seed only when the profile does **not** already
> have it. A version you upgraded by hand is preserved and never pushed back by the image — unlike
> the "seed only upgrades" rule for dsh itself (plugin upgrades always go through `dsh plugin`).
> Note that `dsh plugin add` needs network access (it forwards to pnpm).

### Config bootstrap (headless setups)

To provision credentials **without** printing them to the log (e.g. a deploy script injecting the
password), besides `DSH_ADMIN_PASSWORD` you can also edit the managed block the entrypoint writes into
`profiles/web/cordis.patch.yml` (inside the `/data/dsh` volume):

```yaml
- id: remote
  config:
    enabled: true
    bootstrap:             # only used when the account store is empty
      username: admin
      password: 'a-strong-password'
```

> The entrypoint marks its own section with
> `# >>> dsh-docker-server: default auth plugin (managed block ...) >>>` and **rewrites that block on
> every boot**. For a permanent customization, remove the marker lines or manage accounts through the
> store instead (the same applies to customizing fields other than `enabled`).

## 6. SSH Tunnel (Temporary Single-User Access from Outside)

```bash
# Local port forwarding: map remote 3080 to local 3080
ssh -L 3080:127.0.0.1:3080 your-user@host-ip
# Then open http://127.0.0.1:3080 in the browser
```

Works wherever Windows/Mac/Linux ship with a built-in `ssh` — no extra configuration needed.

## 7. Reverse Proxy + HTTPS (Long-Term Remote Access, Recommended)

> ℹ **`DSH_TRUSTED_HOSTS` is NOT needed while the auth plugin is installed** (the default): after a
> request passes login, dsh-remote's `trustProxy` normalizes its Host/Origin to loopback before
> handing it to the dsh core, so any domain/tunnel Host works over `/api` once logged in (verified
> 2026-09-17). Access control is carried by the account login + MFA.
>
> Only when the plugin is **off** (`DSH_SETUP_REMOTE=off`) but you still reach DSH by domain/LAN IP
> must you allow-list the Host: put `DSH_TRUSTED_HOSTS=app.example.com` in `.env` (comma-separated,
> ports allowed) — otherwise the page loads but `/api` is rejected with 403 (which looks like a blank
> UI / broken connection).

Using Caddy (automatic HTTPS) as an example; Nginx works the same way:

```bash
# Caddyfile (the domain must resolve to the host; ports 80/443 open)
your-domain.com {
    reverse_proxy 127.0.0.1:3080
}
```

> ⚠ That `3080` is the **host-side** port and tracks `DSH_PORT` in `.env` (default 3080) — if you
> changed `DSH_PORT`, change this too. The tunnel section below is the exact opposite: there
> `cloudflared` talks straight to the `dsh` container, so the **in-container** port is always `3080`
> and does **not** follow `DSH_PORT`. Do not mix the two up (see the port note under
> "§8 Cloudflare Tunnel (No Public IP Required)" below).
>
> ℹ If Caddy shares the same compose network as dsh, `reverse_proxy dsh:3080` also works — that is a
> container-to-container hop, so it is likewise always `3080`.

```bash
# Run Caddy with Docker
docker run -d --name caddy \
  -p 80:80 -p 443:443 \
  -v /path/to/Caddyfile:/etc/caddy/Caddyfile \
  -v caddy_data:/data \
  caddy:2
```

> Before exposing through a reverse proxy, make sure the auth plugin is enabled (the default) and MFA is enabled (see Section 3).

> ⚠ **The reverse-proxy route assumes "the domain resolves to this host, and ports 80/443 are open to
> the internet."** On a home connection behind CGNAT (no public IP from the ISP), or wherever port
> forwarding is not an option, this section cannot work — use the Cloudflare Tunnel below instead. It
> needs **no public IP and no inbound port**.

## 8. Cloudflare Tunnel (No Public IP Required)

The reverse-proxy route above has a hard prerequisite: **the domain must resolve to this host, and
the host's ports 80/443 must be open to the internet.** On a home connection behind CGNAT (the ISP
gives you no public IP) that prerequisite simply does not hold — you have neither a public address to
point DNS at nor any business opening a port on the router for it.

Cloudflare Tunnel flips the direction. A `cloudflared` container opens an **outbound** connection
(TCP 443) to Cloudflare's edge, and public requests come back down that **already-established tunnel**.
No inbound port, no public IP.

```bash
# Direction of travel, in one line
Reverse proxy: public ──inbound──> your host:443 ──> dsh:3080      ← needs public IP + open port
Tunnel:        public ──> Cloudflare edge ──outbound tunnel──> dsh:3080   ← needs neither
```

> 💰 **The tunnel itself is free and needs no payment method.** It is a standalone Cloudflare
> product and is **not part of the Zero Trust line** — if the console asks you to add a payment
> method, that page is for **Access (Zero Trust)**, which the tunnel does not require. This
> distinction matters; it is the usual reason people think they took a wrong turn (see the optional
> section below).

### How it compares to a reverse proxy

| | Reverse proxy + HTTPS (Caddy) | Cloudflare Tunnel |
|---|---|---|
| Public IP required | **Yes** | **No** |
| Inbound port required | **Yes** (80/443) | **No** (outbound 443 only) |
| Who handles TLS | You (Caddy's automatic Let's Encrypt) | Cloudflare's edge (the origin leg is plain HTTP) |
| Domain must be on Cloudflare | No | **Yes** (at least onboarded to Cloudflare) |
| Extra account / cost | None | Cloudflare account, **free** |
| Best fit | VPS, cloud hosts, servers with a public IP | **Home broadband, NAS, CGNAT, machines behind NAT** |

### Setup (verified end-to-end on real hardware, 2026-10-09)

**Step 1 — create the tunnel and grab the token**

Cloudflare Dashboard → left menu **`Networking` → `Tunnels`** → `Create a tunnel` → choose
`Cloudflared`.

> ⚠ Two easy-to-miss details in the **current UI**:
> - The menu is **`Networking`**, not `Networks`;
> - Tunnels are **not** under the `Zero Trust` menu — it is a standalone product (which is exactly
>   why it needs no payment method).

At the `Install cloudflared connector` step, **switch `Select Operating System` to `Docker`
manually**, then copy the string after `--token` (starts with `eyJ`). If you skip the switch, the
page hands you an installer for your *browser's* OS — and you will not find a token there at all.

```bash
# .env
TUNNEL_TOKEN=eyJhIjoi...   (paste what you just copied)
```

> 🔐 `TUNNEL_TOKEN` is a secret: make sure `.env` is git-ignored (it is, by default in this repo)
> and `chmod 600 .env`. A leaked token lets someone point your traffic at their own origin.

**Step 2 — configure the route (this is where most people get stuck)**

Tunnel detail page → **`Routes`** tab → `Add a route`.

| Field | Value | Why |
|---|---|---|
| Route type | **`Published application`** | After `Add a route` you **must pick a type first**. Choosing `Private hostname` creates a **WARP-client-only** path that public visitors can never reach — the symptom is "the tunnel is healthy but the domain won't open." |
| Domain | your domain (e.g. `dsh.example.com`) | Saving this makes Cloudflare add a DNS record automatically. |
| Service → Type | `HTTP` | The origin leg into the container is **plain HTTP** — there is no TLS there. |
| Service → URL | **`http://dsh:3080`** | See the breakdown below — **all three parts matter**. |

> ⚠ **The current form requires a protocol prefix**: entering just `dsh:3080` fails immediately with
> `Invalid service URL format (must start with protocol...)`.

Breaking down `http://dsh:3080`:

```
  http://  dsh  :3080
  └──┬───┘  └┬┘  └─┬─┘
     │       │     └─ The socat port. 3081 is rejected — it binds the container's loopback only,
     │       │        so an inter-container connection can never reach it.
     │       └─ The **compose service name**. `localhost` / `127.0.0.1` here is a guaranteed 502:
     │          that is the cloudflared container's own loopback, and has nothing to do with dsh.
     └─ The protocol prefix. This leg **is http**: TLS terminated at Cloudflare's edge, so the
        tunnel carries plain HTTP. Choosing https here yields a 502.
```

> 💡 **One-line mnemonic: the internal leg is http; only the public leg is https.**

> ⚠ **`:3080` here is the in-container port and has nothing to do with `DSH_PORT` in `.env` — do
> not follow it.** `DSH_PORT` changes the **host-side** published port; socat inside the container
> always listens on `3080` (`SOCAT_PORT` belongs to the entrypoint and is set by neither the compose
> file nor `.env.example`). Tunnel origin traffic takes the `cloudflared → dsh` hop, whose port is
> fixed at `3080`; substituting your `DSH_PORT` value (say 3081) is a guaranteed 502.
> The converse also holds: if you change `DSH_PORT`, you just browse the host on the new port and
> leave this alone.

After saving, check **DNS → Records**: a **CNAME** pointing at `<Tunnel ID>.cfargotunnel.com` should
appear automatically. **That record showing up means the route is correctly configured** — far more
direct than reading any log.

**Step 3 — start it**

```bash
docker compose -f docker-compose.yml -f docker-compose.cloudflare.yml \
  --profile cloudflare up -d
```

> 📌 The file is `docker-compose.cloudflare.yml`, the profile is `cloudflare`, and the service is
> `cloudflared` — similar-looking but **three different things**: `-f` takes the file, `--profile`
> takes the profile.
>
> For day-to-day use, define an alias instead of retyping two `-f` flags:
>
> ```bash
> DC='docker compose -f docker-compose.yml -f docker-compose.cloudflare.yml --profile cloudflare'
> $DC ps                       # status
> $DC logs -f cloudflared      # logs
> $DC stop cloudflared         # stop the tunnel only; dsh keeps running
> ```
>
> **Do not want the tunnel?** Drop `--profile cloudflare` — compose then **ignores** cloudflared
> entirely and never even creates the container. That is the deliberate "not deployed by default"
> behaviour (a running container needs `$DC down` to clean up).

**Step 4 — verify**

```bash
# a) Did the tunnel register? — expect 4 lines
$DC logs cloudflared | grep 'Registered tunnel connection'

# b) Can the containers actually reach each other? (probe dsh from inside cloudflared)
docker exec dsh-cloudflared wget -qO- --spider --timeout=5 http://dsh:3080/

# c) From the public side
curl -I https://dsh.example.com/
```

> ⚠ **On the first `up -d`, cloudflared may take minutes before it starts** — that is expected, not
> a fault: cloudflared has `depends_on: dsh (service_healthy)`, and dsh's healthcheck carries
> `start_period: 300s` (first boot copies the seed and cold-starts).
> So when `logs cloudflared` shows nothing, **first check whether dsh is `healthy` in `ps`**.
>
> Why not skip the wait: the moment the tunnel registers, Cloudflare starts routing public traffic to
> your origin. If the origin is not ready yet, public visitors get a 502 — considerably worse than a
> tunnel that becomes available a few minutes later.

### Security baseline (check every line before exposing)

| Item | Requirement | Why |
|---|---|---|
| `DSH_SETUP_REMOTE` | **Must stay `on`** (the repo default) | This is the **only** authentication line for a public deployment. Turning it off = hanging a machine with full agent privileges on the public internet, where anyone opening the page gets a logged-in session. |
| MFA (TOTP) | Enable **immediately** after the first login | Settings → Login & Account → Two-factor authentication. Without Cloudflare Access this is the single most important defense. |
| `DSH_TRUSTED_HOSTS` | **Do not set it** | With the auth plugin installed (the default), dsh-remote's `trustProxy` normalizes the Host to loopback after login, so the tunnel domain is admitted naturally (verified 2026-09-17, see the top of this section). Setting it is redundant. **Conversely**: if you turn `DSH_SETUP_REMOTE` off, you *must* set your tunnel domain or `/api` returns 403. |
| `DSH_PUBLIC_URL` | **Recommended**: `https://<your-domain>/` (trailing slash) | Otherwise the log line and the **system prompt handed to the model** still name the in-container `127.0.0.1:3081`, producing "the link in the log won't open" and "the address the model gave me won't open". |
| `.env` permissions | `chmod 600 .env` | It holds both `TUNNEL_TOKEN` and your API key. |

> ℹ As with the reverse-proxy section: **the tunnel does not change dsh's trust model.** It only
> carries traffic in; access control is still carried by the account login + MFA.

### Optional: an extra layer with Cloudflare Access

If you want one more gate (say, an email OTP before anyone even reaches the dsh login page), you can
enable Cloudflare Access.

> ⚠ **Access belongs to the Zero Trust line and requires a payment method** (the free tier is
> $0/month for 50 users, but attaching a card grants charging authority). **Skip this section if you
> would rather not attach one** — it is a nice-to-have; the tunnel does not need it. Do not read the
> payment page as a sign that the earlier steps went wrong.

**A free alternative without a card: WAF rate limiting** (Cloudflare Dashboard → `Security` → `WAF`
→ `Rate limiting rules`). Rate-limiting the login endpoint raises the cost of brute-forcing
substantially, at no charge. Suggested settings:

| Field | Suggested value | Rationale |
|---|---|---|
| Match | path contains `/api` (or your concrete login path) | Throttle auth-related requests only, without penalizing static assets. |
| Rate | e.g. `10 requests / 1 minute` per IP | Nobody logs in ten times a minute. |
| Action | `Block` (or `Managed Challenge`) | `Managed Challenge` is gentler on false positives. |

### Troubleshooting

| Symptom | Root cause | Fix |
|---|---|---|
| Public **502**, while the log says the tunnel is registered | **Wrong Service URL** — most often `http://localhost:3080` or `http://127.0.0.1:3080` (that is cloudflared's own loopback), or `https://` for the origin (there is no TLS inside), port `3081` (loopback-only), or **`3080` swapped for your own `DSH_PORT` value** (a host-side port that has nothing to do with in-container socat). | Use **`http://dsh:3080`** and check all three parts. |
| Saving the route fails with `Invalid service URL format (must start with protocol...)` | The current form requires a protocol prefix; you entered bare `dsh:3080`. | Prepend `http://` → `http://dsh:3080`. |
| **No `Public Hostname` tab anywhere** | The UI was renamed. The old label was `Public Hostname`; the current one is **`Routes`** — semantically identical. | Go to `Routes`, then `Add a route` → `Published application`. |
| No `Tunnels` entry under the `Zero Trust` menu | Tunnels are not under Zero Trust — standalone product. | Use the left menu **`Networking` → `Tunnels`**. |
| Tunnel is up but the domain will not open | The route type was left as `Private hostname` (WARP-client-only). | Switch it to `Published application`. |
| No CNAME appears in DNS | The route was not saved, or the domain is not in this Cloudflare account. | Recheck `Routes`; confirm the domain is onboarded to Cloudflare. |
| **Page loads but `/api` returns 403** (looks like a blank UI / broken connection) | Either `DSH_SETUP_REMOTE=off` (in which case you must set `DSH_TRUSTED_HOSTS=<your tunnel domain>` yourself), or port 3080 is not going through the auth plugin's path. | Confirm `DSH_SETUP_REMOTE=on` in `.env` (the default) and use `/api` after logging in. |
| cloudflared exits immediately with `unauthorized` or an empty-token message | `TUNNEL_TOKEN` is missing or wrong. Compose defaults it to an empty string via `${TUNNEL_TOKEN:-}` — **deliberately not failing the compose command**, so that cloudflared itself reports the real reason. | `$DC logs cloudflared \| grep -i 'unauthorized\|token'`; re-copy the token from the console. **dsh is unaffected.** |
| `logs cloudflared` stays silent for a long time | dsh is not healthy yet, so cloudflared has not started (it is gated by `depends_on`). | Check `$DC ps` for dsh `healthy`; a few minutes on first boot is normal (`start_period: 300s`). |

> 📌 Once the tunnel works, if you want to tighten the cloudflared container further (read-only root
> FS + zero capabilities), `docker-compose.cloudflare.yml` already carries a **commented-out**
> hardening block plus a per-item verification recipe. Uncomment it one item at a time *after* the
> tunnel is proven — that way a failure immediately bisects into "misconfiguration" vs
> "over-hardening".

## 9. Security Checklist

- [ ] Remote access: strong password + **MFA (TOTP)**
- [ ] Do not map `3080` directly to the public internet
- [ ] Do not set `DSH_SETUP_REMOTE=off` on a deployment with a public entry point
- [ ] Third-party plugins have full permissions; review their source before installing
- [ ] Back up regularly (see [03](03-upgrade-maintenance.md))
