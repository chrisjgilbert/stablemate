# Integrating your jobs with Stablemate

> Looking to **run your own Stablemate server**? See [`install.md`](install.md) for
> the Docker / docker-compose self-hosting guide. This page is about wiring your
> *jobs* to a Stablemate instance (managed or self-hosted).

Stablemate watches your scheduled jobs by **heartbeat**: each job pings a URL when
it finishes. If a ping is late by more than the grace period, Stablemate emails
you. There are two ways to wire it up — the **gem** (recommended; zero per-job
code) and the **manual** path (a plain HTTP call from any job, in any language).

---

## 1 · The gem path (Rails + Solid Queue)

The companion gem registers your recurring jobs as monitors and pings them on
every successful run. You write no per-job code.

### 1.1 Add the gem

```ruby
# Gemfile
gem "stablemate"
```

```sh
bundle install
```

### 1.2 Get an API key

In the app: **Settings → API keys → Generate key**. The raw key
(`sm_live_…`) is shown **once** — copy it immediately. Store it in credentials:

```sh
bin/rails credentials:edit
```

```yaml
stablemate:
  api_key: sm_live_xxxxxxxxxxxxxxxxxxxx
```

### 1.3 Configure the initializer

```ruby
# config/initializers/stablemate.rb
Stablemate.configure do |c|
  c.api_key         = Rails.application.credentials.dig(:stablemate, :api_key)
  c.endpoint        = "https://stablemate.dev"   # ← your own domain if self-hosting
  c.ping_on_success = true          # ping when a monitored job finishes cleanly
  # c.recurring_path = "config/recurring.yml"  # default
  # c.timeout        = 2                        # HTTP timeout, seconds
end
```

### 1.4 Declare your jobs in `recurring.yml`

The gem reads Solid Queue's recurring config. Each task key becomes a monitor.

```yaml
# config/recurring.yml
daily_digest:
  class: DailyDigestJob
  schedule: every day at 9am

hourly_sync:
  class: HourlySyncJob
  schedule: every hour
```

The interval is parsed from `schedule:` (via Fugit). For irregular crons the
**largest** gap between runs is used as the expected interval; tighten it later in
the monitor's settings if you want a snugger window.

### 1.5 Sync

Registration happens automatically on boot. To force it (e.g. after editing
`recurring.yml`):

```sh
bin/rails stablemate:sync
```

Sync is **idempotent** — it upserts monitors keyed on the task key, so running it
repeatedly is safe. A sync failure logs a warning and never crashes boot.

That's it. On each **successful** job run the gem fires a fire-and-forget ping in
the background. A job that raises does **not** ping — the missed beat is the
signal.

> **Manual fallback without `recurring.yml`.** You can skip registration and use
> execution tracking alone: create a monitor by hand whose **registration key**
> equals the job class name (e.g. `CleanupJob`). The gem's subscriber will ping it
> on every successful run.

---

## 2 · The manual path (any language, any scheduler)

Every monitor has a **ping URL** containing a secret token. Hit it from the end of
your job. Find the URL on the monitor's detail page (it includes a ready-to-paste
`curl` snippet).

### curl (cron, shell)

```sh
# at the end of your job
curl -fsS https://stablemate.dev/ping/<ping_token>
```

A bare `GET` works; `POST` is identical. Optionally report run latency:

```sh
curl -fsS "https://stablemate.dev/ping/<ping_token>?duration_ms=842"
```

### Ruby (Net::HTTP)

```ruby
require "net/http"
Net::HTTP.get_response(URI("https://stablemate.dev/ping/#{ping_token}"))
rescue StandardError
  # best-effort: never let a failed ping break the job
end
```

### Notes

- The **ping token is the only credential** on this path — no API key, no headers.
  Treat the URL as a secret. Rotate it from the monitor's detail page if it leaks
  (the old URL stops working immediately).
- The endpoint always returns `{"ok":true}` on a known token and an opaque `404`
  on an unknown one. It is rate-limited (see [`api.md`](api.md)) generously enough
  for any real cron cadence.

---

## 3 · What you'll see

- A **pending** monitor flips to **up** on its first ping.
- If a ping is overdue past the grace period, the monitor goes **down** and you
  get one `down` email.
- The next successful ping flips it back to **up** and sends one `recovered` email.
- The dashboard shows a 90-day uptime bar per monitor.

See [`api.md`](api.md) for the full HTTP contract and
[`runbook.md`](runbook.md) for operations (backups, deliverability).
