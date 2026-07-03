# Deploying Stablemate to a Hetzner VM behind Cloudflare (Kamal)

A start-to-finish runbook for the **managed** deployment: one Hetzner Cloud VM,
fronted by Cloudflare, deployed with [Kamal](https://kamal-deploy.org).
kamal-proxy terminates TLS on the box, so there is **no** Caddy, nginx, or
`cloudflared`. Postgres runs as a bundled accessory on the same VM.

> This is the opinionated, Cloudflare-fronted path. For the generic story
> (Docker Compose, or Kamal with plain Let's Encrypt) see
> [`install.md`](install.md). Backups / restore / rollback live in
> [`runbook.md`](runbook.md).

## What you'll end up with

```
Browser ──HTTPS──▶ Cloudflare edge ──HTTPS (Origin Cert)──▶ Hetzner VM
   (CF-managed cert)   WAF · DDoS · cache      (firewall: CF IPs only)
                                                    │
                                              kamal-proxy ──HTTP, private docker net──▶ Puma (app)
                                                                                          │
                                                                                    Postgres (accessory)
```

Two TLS hops: the browser trusts Cloudflare's public cert; Cloudflare trusts the
**Origin Certificate** kamal-proxy serves. Cloudflare SSL mode is **Full
(strict)**. The firewall makes the Origin reachable **only** through Cloudflare.

---

## 0 · Prerequisites

**Accounts / services**
- A **Hetzner Cloud** project (or any Ubuntu VM with a public IP + root SSH).
- A domain on **Cloudflare** (the zone's nameservers point at Cloudflare).
- A **container registry** account — Docker Hub, GitHub Container Registry
  (`ghcr.io`), etc. — and an **access token** (not your password).
- An **SMTP** provider (Postmark, SES, Mailgun, Fastmail…) able to send as your
  domain (SPF/DKIM) — required for down/recovery alert emails.

**On your laptop (the deploy machine)**
- Ruby (matches [`.ruby-version`](../.ruby-version)) + `bundle install` — gives
  you `bin/kamal`.
- Docker running locally (Kamal builds the image here unless you set a remote
  builder).
- An SSH key already able to `ssh root@<vm-ip>`.
- This repo checked out, on the branch/commit you want to ship.

---

## 1 · Provision the Hetzner VM

1. Create a Cloud Server: **Ubuntu 24.04**, a shared-vCPU type is plenty to start
   (e.g. CX22 — 2 vCPU / 4 GB). Add your SSH key during creation.
2. Note its **public IPv4** — this is `STABLEMATE_SERVER_IP` below.
3. Confirm SSH works: `ssh root@<vm-ip> 'echo ok'`.

Kamal installs Docker for you on first run (`kamal setup` runs
`kamal server bootstrap`), so you don't need to pre-install it. If you prefer,
`curl -fsSL https://get.docker.com | sh` on the box also works.

---

## 2 · Cloudflare: DNS, Origin Certificate, SSL mode

1. **DNS** → add an **A record**: name = your host (e.g. `status` for
   `status.example.com`, or `@` for the apex) → your VM's IP → **Proxied**
   (orange cloud).
2. **SSL/TLS → Origin Server → Create Certificate** → accept the defaults
   (RSA/ECC, 15-year validity, your hostname). Cloudflare shows two blocks:
   - the **Origin Certificate** → save as `.kamal/cloudflare-origin.pem`
   - the **Private Key** → save as `.kamal/cloudflare-origin.key`

   Put both on your **deploy machine**, in the repo's `.kamal/` directory. They
   are gitignored (see [`.gitignore`](../.gitignore)) — never commit them.
3. **SSL/TLS → Overview** → set encryption mode to **Full (strict)**.
4. (Recommended) **SSL/TLS → Edge Certificates** → enable **Always Use HTTPS**.

---

## 3 · Lock the origin to Cloudflare (Hetzner Firewall)

So nobody can bypass Cloudflare by hitting the raw IP (skipping its WAF and
DDoS protection), create a **Hetzner Cloud Firewall** and attach it to the VM:

| Direction | Port | Source |
|-----------|------|--------|
| Inbound | 443 (and 80) | **Cloudflare IPv4 + IPv6 ranges** only — <https://www.cloudflare.com/ips/> |
| Inbound | 22 | **your admin IP** only |
| Outbound | all | allow |

Everything else stays closed. Postgres (`5432`) is bound to `127.0.0.1` inside the
VM and is never exposed regardless.

> Keep the Cloudflare ranges under review — they change rarely, but an outdated
> allowlist can drop legitimate traffic. Because we use an Origin Certificate
> (no ACME), this firewall never has to open for certificate issuance/renewal.

---

## 4 · Configure the app

### 4a · Set the deployment target (three ENV vars)

`config/deploy.yml` reads the three deployment-specific values from the
environment (via ERB) rather than hard-coding them, so the **same** config drives
both a manual `bin/kamal deploy` and the GitHub Actions auto-deploy (§8). Export
them in the shell you deploy from:

| ENV var | Set to | Used by |
|---------|--------|---------|
| `KAMAL_REGISTRY_USER` | your registry user, e.g. `youruser` (Docker Hub) — image becomes `youruser/stablemate` | `image` + `registry.username` |
| `STABLEMATE_SERVER_IP` | your VM's public IP | `servers.web` + `accessories.db.host` |
| `STABLEMATE_HOST` | your public hostname, e.g. `status.example.com` | `proxy.host` + container `STABLEMATE_HOST` |

```sh
export KAMAL_REGISTRY_USER='youruser'
export STABLEMATE_SERVER_IP='203.0.113.9'
export STABLEMATE_HOST='status.example.com'
```

They're read with `ENV.fetch`, so a missing one fails the deploy loudly instead
of shipping a blank host. Keep them with the other exports below (a `.env` you
`source`, or your password manager) so every deploy sees them.

Using a registry other than Docker Hub? Uncomment and set `registry.server`
(e.g. `ghcr.io`).

`STABLEMATE_HOST` must match the Cloudflare hostname exactly — ping URLs, email
links, and Host-header authorization are all built from it.

**Alert email From address.** The mailer's built-in default From is currently
`chris@chrisgilbert.dev` (a temporary stand-in until a dedicated sending domain
has SPF/DKIM). Set your own in `deploy.yml`'s `env.clear` so alerts come from an
address you control:

```yaml
    STABLEMATE_MAIL_FROM: "Stablemate <alerts@example.com>"
    STABLEMATE_MAIL_REPLY_TO: support@example.com
```

Use a sender your SMTP provider is authorised to send as (SPF/DKIM aligned) or
mail lands in spam.

### 4b · Rails credentials: master key + SMTP

This deploy uses **`RAILS_MASTER_KEY`** — with it present, Rails derives
`secret_key_base` from `config/credentials.yml.enc`, and SMTP can live there too.

```sh
bin/rails credentials:edit
```

Add your SMTP provider's settings:

```yaml
smtp:
  address: smtp.postmarkapp.com
  port: 587
  user_name: your-smtp-user
  password: your-smtp-password
  domain: example.com
```

Saving writes `config/master.key` locally (gitignored). `.kamal/secrets` reads
that file for `RAILS_MASTER_KEY`. (Alternatively, set the `SMTP_*` env vars in
`deploy.yml`; env takes precedence over credentials.)

#### Quick start: send via a personal account

You don't need a transactional provider on day one — a personal mailbox works as
an SMTP relay to validate alerts. The catch: you must send **as** the
authenticated account (providers rewrite or reject a mismatched From), and you
need an **app-specific password**, not your login password.

Example with a Google (Workspace/Gmail) mailbox at `chris@chrisgilbert.dev`:

1. Enable 2-Step Verification on the account, then create an **App Password**
   (Google Account → Security → App passwords → "Mail"). On Workspace, if "App
   passwords" doesn't appear, an admin must allow it: **Admin console → Security →
   Authentication → 2-step verification → "Allow users to turn on app passwords."**
2. Credentials (`bin/rails credentials:edit`):
   ```yaml
   smtp:
     address: smtp.gmail.com
     port: 587
     user_name: chris@chrisgilbert.dev
     password: your-16-char-app-password
     domain: chrisgilbert.dev
   ```
3. `deploy.yml` env — send **as** that same address:
   ```yaml
       STABLEMATE_MAIL_FROM: "Stablemate <chris@chrisgilbert.dev>"
       STABLEMATE_MAIL_REPLY_TO: chris@chrisgilbert.dev
   ```

Not on Google? Same shape — swap `address`/`domain` for your provider's SMTP host
(Fastmail/iCloud also require an app-specific password). Because you're sending as
your own address, the provider's SPF/DKIM apply and mail lands fine.

Limits to keep in mind: Gmail sends ~500/day (Workspace ~2000). Fine for a few
monitors; move to Postmark/SES/Mailgun with your domain before real users rely on
it (higher limits + a neutral sender). Nothing else in the deploy changes.

### 4c · Secrets — `.kamal/secrets`

`.kamal/secrets` is committed but contains **no raw secrets** — it pulls each
value from your environment or a file. Before deploying, export the two you
supply by hand (the master key and cert come from files automatically, and the
three target vars from §4a):

```sh
export KAMAL_REGISTRY_PASSWORD='your-registry-access-token'
export STABLEMATE_DATABASE_PASSWORD="$(openssl rand -hex 24)"   # pick once, keep it
```

`.kamal/secrets` reads `RAILS_MASTER_KEY`, `STABLEMATE_SSL_CERT`, and
`STABLEMATE_SSL_KEY` **env-first, file-fallback** (`${VAR:-$(cat …)}`): on your
laptop the files supply them, in CI the env (repo secrets) does. You don't set
those three by hand locally.

`STABLEMATE_DATABASE_PASSWORD` is reused as the Postgres accessory's
`POSTGRES_PASSWORD`, so the app and DB can never drift. Store these in a password
manager; `.kamal/secrets` also documents pulling them straight from 1Password.

---

## 5 · Deploy

```sh
bin/kamal setup        # first run: bootstraps Docker, installs kamal-proxy +
                       # the Postgres accessory, builds & pushes the image, deploys
```

On boot the app's entrypoint runs `db:prepare`, creating and migrating the
primary plus the Solid Cache/Queue/Cable databases. Watch it come up:

```sh
bin/kamal logs -f
```

Verify the health endpoint through Cloudflare:

```sh
curl -fsS https://status.example.com/up      # expect HTTP 200
```

Every subsequent release is just:

```sh
bin/kamal deploy
```

---

## 6 · First-run smoke test

1. **Create your account.** There's no admin seed — the first person to sign up
   registers normally. Open `https://<your-host>/`, **Sign up**, land on the
   dashboard. (Note: `STABLEMATE_SIGNUP_ACCOUNT_CAP: 1` in `deploy.yml` caps total
   accounts at 1 while validating demand — raise or remove it to open signups.)
2. **Create a monitor**, copy its **Ping URL** (contains a secret token), and hit
   it:
   ```sh
   curl -fsS https://<your-host>/ping/<ping_token>
   ```
   The monitor flips **pending → up**.
3. **Verify alerts.** Stop pinging past the grace period → expect a **down**
   email; the next ping sends a **recovered** email. No email? Check
   `bin/kamal logs -f` for SMTP errors and confirm `STABLEMATE_MAIL_FROM` is an
   authorised sender. Run a real domain through
   [mail-tester.com](https://www.mail-tester.com) and confirm SPF/DKIM/DMARC pass
   (see [`runbook.md` §2](runbook.md)).

---

## 7 · Day-2 operations

```sh
bin/kamal deploy             # ship a new release (build, push, roll out, migrate)
bin/kamal rollback           # roll back to the previous release
bin/kamal logs -f            # tail app logs
bin/kamal console            # bin/rails console on the box
bin/kamal shell              # a shell in the app container
bin/kamal dbc                # bin/rails dbconsole
```

- **Backups.** Postgres data lives in the host-mounted `data` directory of the
  `stablemate-db` accessory. Set up the nightly `pg_dump` cron and rehearse a
  restore — full procedure in [`runbook.md` §1](runbook.md).
- **Upgrades.** Pull the new code, `bin/kamal deploy`. Migrations run on boot.
- **Rotating the Cloudflare ranges in the firewall** when Cloudflare publishes a
  change — see <https://www.cloudflare.com/ips/>.

---

## 8 · Auto-deploy from CI (GitHub Actions)

Once the manual path works, you can let GitHub ship every green `main` for you.
The **`deploy` job** in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)
runs `bin/kamal deploy` — the **same** command, config, and secrets file you use
by hand — after the test job (`ci`) passes. It's a single workflow: `deploy`
`needs: ci` and is gated so it runs **only on a push to `main`**:

```yaml
deploy:
  needs: ci
  if: github.ref == 'refs/heads/main' && github.event_name == 'push'
```

`github.ref` and `github.event_name` are set by GitHub and can't be forged, so a
pull request — from a fork or otherwise — never satisfies the gate (a PR is
`event_name == 'pull_request'`, `ref == 'refs/pull/N/merge'`). That's what keeps
untrusted PR code away from the deploy secrets, **without** needing a separate
privileged workflow. (The alternative, a `workflow_run` trigger, is more
powerful but opens the classic "pwn request" hole — a second workflow that runs
with secrets and can check out a fork's commit; the gated-job pattern sidesteps
it entirely.) Only someone with write access can push to `main`, so only they
can trigger a deploy.

**How the config values reach the runner.** The runner has none of your local
files or exports, so provide them once under **GitHub → Settings → Secrets and
variables → Actions**:

| Kind | Name | Value | Why stablemate needs it |
|------|------|-------|-------------------------|
| Variable | `KAMAL_REGISTRY_USER` | your Docker Hub user (from §4a) | names the image + registry login |
| Variable | `STABLEMATE_SERVER_IP` | your VM's public IP | SSH + accessory host |
| Variable | `STABLEMATE_HOST` | your public hostname | proxy host + app URLs |
| Secret | `KAMAL_REGISTRY_PASSWORD` | Docker Hub access token | push/pull the image |
| Secret | `RAILS_MASTER_KEY` | contents of `config/master.key` | decrypts credentials |
| Secret | `SSH_PRIVATE_KEY` | deploy key (see below) | runner → VM over SSH |
| Secret | `KNOWN_HOSTS` | `ssh-keyscan <your-vm-ip>` output | pins the VM's host key |
| Secret | `STABLEMATE_DATABASE_PASSWORD` | the DB password from §4c | **bundled Postgres accessory** (an app on SQLite wouldn't need this) |
| Secret | `STABLEMATE_SSL_CERT` | full PEM of `.kamal/cloudflare-origin.pem` | **Cloudflare Origin Cert** (an app on Let's Encrypt `ssl: true` wouldn't need this) |
| Secret | `STABLEMATE_SSL_KEY` | full PEM of `.kamal/cloudflare-origin.key` | private key for that cert |

Variables are non-secret and show in logs; secrets are masked. The three target
vars map to the same `ENV.fetch` reads in `deploy.yml`; the secrets feed
`.kamal/secrets` env-first — no code branches between manual and CI. The last
three secrets are what a Postgres + Cloudflare-Origin-Cert deployment needs on
top of the common four (`KAMAL_REGISTRY_PASSWORD`, `RAILS_MASTER_KEY`,
`SSH_PRIVATE_KEY`, `KNOWN_HOSTS`); switch to SQLite or Let's Encrypt and they
fall away.

**SSH deploy key.** Kamal connects to the VM over SSH from the runner. Generate a
dedicated key pair (don't reuse your laptop's), add the **public** half to the
box, and paste the **private** half as the `SSH_PRIVATE_KEY` secret. Capture the
host key for `KNOWN_HOSTS` at the same time:

```sh
ssh-keygen -t ed25519 -f kamal_deploy -N '' -C 'github-actions-deploy'
ssh-copy-id -i kamal_deploy.pub root@<your-vm-ip>   # or append to authorized_keys
cat kamal_deploy            # paste into the SSH_PRIVATE_KEY secret
ssh-keyscan <your-vm-ip>    # paste the output into the KNOWN_HOSTS secret
```

**Activation & scope.** The gate lives in `ci.yml` on the **default branch**, so
auto-deploy goes live once this is merged to `main`. From then on every push to
`main` that passes CI deploys automatically; manual `bin/kamal deploy` still
works unchanged for out-of-band releases and `bin/kamal rollback`. To pause
auto-deploy, disable the **CI** workflow in the repo's Actions tab (or remove the
`deploy` job).

---

## 9 · Troubleshooting

| Symptom | Fix |
|---|---|
| `525`/`526` from Cloudflare | Origin Cert not served or SSL mode wrong. Confirm the two PEM files are in `.kamal/`, `proxy.ssl` points at them, and Cloudflare is **Full (strict)**. |
| Redirect loop / `too many redirects` | Cloudflare SSL set to **Flexible** — change to **Full (strict)**. |
| `Blocked hosts` / 403 on every page | `STABLEMATE_HOST` must equal the hostname you visit; add extras via `STABLEMATE_HOSTS`. |
| Ping URLs / email links show `stablemate.dev` | `STABLEMATE_HOST` not set to your domain — fix and `bin/kamal deploy`. |
| Alert emails come from the default `chris@chrisgilbert.dev` stand-in | Set `STABLEMATE_MAIL_FROM` in `deploy.yml` env (step 4a). |
| No alert emails at all | SMTP not configured — add it to credentials (step 4b); check `bin/kamal logs -f`. |
| `kamal setup` can't reach the server | Check `ssh root@<ip>` works and port 22 is open to your IP in the firewall. |
| Site unreachable but `/up` works locally on the box | Firewall too tight or DNS not **Proxied** — confirm the A record is orange-clouded and 443 is open to Cloudflare ranges. |

---

Wiring your **jobs** to this instance (the ping URLs / companion gem) is
[`integrating.md`](integrating.md).
