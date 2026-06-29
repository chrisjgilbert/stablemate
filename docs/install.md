# Self-hosting Stablemate

Run your own Stablemate instance with Docker. You need a host with **Docker** and
the **Docker Compose plugin**, a **domain name** pointing at it, and an **SMTP**
account to send alert emails. No Ruby or Rails knowledge required.

> Want to wire your *jobs* to Stablemate (the gem / ping URLs)? That's
> [`integrating.md`](integrating.md). This page is about running the **server**.

---

## 1 · Get the code

```sh
git clone https://github.com/<your-org>/stablemate.git
cd stablemate
```

## 2 · Configure

Everything is configured through a single `.env` file — there are **no in-repo
Rails credentials** to manage (you do not need `config/master.key`).

```sh
cp .env.example .env
```

Open `.env` and fill it in. The values you must set:

| Variable | What it is |
|---|---|
| `STABLEMATE_HOST` | Your public hostname, e.g. `status.acme.com`. **Ping URLs and email links are built from this** — it must be the domain your jobs and browser reach. |
| `STABLEMATE_PROTOCOL` | `https` in production (`http` only for a local trial). |
| `SECRET_KEY_BASE` | A long random secret. Generate one (see below). |
| `DB_PASSWORD` | A strong password for the bundled PostgreSQL. |
| `SMTP_*` | Your SMTP provider's host/port/credentials. |
| `STABLEMATE_MAIL_FROM` | The From address on alerts (must be SPF/DKIM-aligned with your SMTP domain). |

Generate a `SECRET_KEY_BASE`:

```sh
docker compose run --rm web bin/rails secret
```

Copy the output into `SECRET_KEY_BASE` in `.env`.

### Caps & waitlist (optional)

Self-hosters normally leave `STABLEMATE_MAX_MONITORS_PER_USER` and
`STABLEMATE_SIGNUP_ACCOUNT_CAP` **unset** — that means unlimited monitors and open
sign-ups with no waitlist. Set them only if you want to throttle a public instance.

## 3 · Start it

```sh
docker compose up -d --build
```

This builds the production image, starts PostgreSQL, and starts the app. On boot
the app **runs database migrations automatically** (`bin/rails db:prepare` creates
and migrates the primary plus the Solid Cache/Queue/Cable databases) — you don't
run migrations by hand.

Watch it come up:

```sh
docker compose logs -f web
```

When you see Puma listening, browse to your `STABLEMATE_HOST`.

> **TLS.** The app expects HTTPS in production and sets HSTS + Secure cookies. Put
> a TLS-terminating reverse proxy (Caddy, nginx, a load balancer, Cloudflare) in
> front of port 80, or terminate TLS at the host. For a quick **local** trial over
> plain HTTP, set `STABLEMATE_PROTOCOL=http` and `STABLEMATE_FORCE_SSL=false` in
> `.env` and visit `http://localhost`.

## 4 · Create the first account

There is no special admin seed — the **first person to sign up** simply registers
an account. Open `https://<your-host>/`, click **Sign up**, and create your login.
You land on the dashboard.

## 5 · Create a monitor and send a ping

1. **New monitor** → give it a name and an expected interval.
2. On the monitor's page, copy the **Ping URL** (it contains a secret token).
3. Hit it from anywhere — the monitor flips from **pending** to **up**:

   ```sh
   curl -fsS https://<your-host>/ping/<ping_token>
   ```

Wire this into the end of your real jobs, or use the companion gem — see
[`integrating.md`](integrating.md).

## 6 · Verify alert email

Stop pinging a monitor past its grace period and Stablemate sends a **down** email;
the next ping sends a **recovered** email. If no email arrives, check
`docker compose logs -f web` for SMTP errors and confirm your `SMTP_*` values and
that `STABLEMATE_MAIL_FROM` is a sender your provider authorises.

---

## Pointing the companion gem at your instance

In a Rails app using the [`stablemate` gem](../gem/README.md), set the endpoint to
your own server — either in the initializer or via the `STABLEMATE_ENDPOINT`
environment variable:

```ruby
# config/initializers/stablemate.rb
Stablemate.configure do |c|
  c.api_key  = Rails.application.credentials.dig(:stablemate, :api_key)
  c.endpoint = "https://status.acme.com"   # your self-hosted Stablemate
end
```

```sh
# or, equivalently
export STABLEMATE_ENDPOINT=https://status.acme.com
```

The gem defaults to the managed instance (`https://stablemate.dev`) only when
neither is set.

---

## Operating it

- **Upgrades.** `git pull && docker compose up -d --build`. Migrations run on boot.
- **Backups.** Your data lives in the `postgres_data` Docker volume. Back it up
  with `docker compose exec postgres pg_dump -U "$DB_USERNAME" "$POSTGRES_DB"`.
  See [`runbook.md`](runbook.md) for restore and deliverability (SPF/DKIM) details.
- **Uploads** (if any) persist in the `storage_data` volume.
- **Logs.** `docker compose logs -f web`.
- **Console.** `docker compose exec web bin/rails console`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Blocked hosts` / 403 on every page | `STABLEMATE_HOST` must match the hostname you're visiting; add extras to `STABLEMATE_HOSTS`. Host authorization is only enforced once you set `STABLEMATE_HOST`. |
| 403 on a `host:port` URL (e.g. a local `localhost:3000` trial) | Set `STABLEMATE_HOST` to the bare host (`localhost`); the port is for the public URL, but Rails matches the Host header without its port. |
| Endless redirect to HTTPS on a plain-HTTP trial | Set `STABLEMATE_FORCE_SSL=false` and `STABLEMATE_PROTOCOL=http`. |
| Ping URLs / email links show the wrong domain | They come from `STABLEMATE_HOST` — fix it and restart (`docker compose up -d`). |
| No alert emails | Check `SMTP_*` and `STABLEMATE_MAIL_FROM`; watch `docker compose logs -f web`. |
| `web` exits on boot | Usually a DB connection issue — confirm `DB_PASSWORD` matches and Postgres is healthy (`docker compose ps`). |
