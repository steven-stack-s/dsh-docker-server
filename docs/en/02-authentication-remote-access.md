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
| Reverse proxy + HTTPS | High (auth layer + HTTPS) | Long-term remote access |

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
  first-boot log banner prints this path too (`凭据存档 / stored : ...`), so you can note it down the
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

```bash
# Run Caddy with Docker
docker run -d --name caddy \
  -p 80:80 -p 443:443 \
  -v /path/to/Caddyfile:/etc/caddy/Caddyfile \
  -v caddy_data:/data \
  caddy:2
```

> Before exposing through a reverse proxy, make sure the auth plugin is enabled (the default) and MFA is enabled (see Section 3).

## 8. Security Checklist

- [ ] Remote access: strong password + **MFA (TOTP)**
- [ ] Do not map `3080` directly to the public internet
- [ ] Do not set `DSH_SETUP_REMOTE=off` on a deployment with a public entry point
- [ ] Third-party plugins have full permissions; review their source before installing
- [ ] Back up regularly (see [03](03-upgrade-maintenance.md))
