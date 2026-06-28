# Stablemate × Solid Queue — Integration

This is the spine of the product: how a Rails app's **Solid Queue recurring jobs** become **monitored
heartbeats** in Stablemate, ideally with **zero per-job code** via the companion gem.

> Code below is illustrative — it shows the intended wiring and contracts, not a finished gem. Adapt
> to the host app's conventions and the actual `solid_queue` version in the Gemfile.

---

## 1 · The heartbeat contract

Every monitor has a unique, rotatable token and a ping endpoint:

```
POST/GET https://stablemate.dev/ping/<token>
```

- A **2xx** marks a successful check-in (records a `Ping`, sets `last_pinged_at`, resolves any open
  incident).
- The monitor is **down** when `now > last_pinged_at + expected_interval + grace_period`. A background
  sweep (itself a recurring job) flips overdue monitors to `down` and emails the owner.
- States: `up` (checked in within window) · `down` (overdue past grace) · `paused` (sweep skips it) ·
  `pending` (created, no ping yet).

Manual wiring is one line at the end of a job:

```ruby
# anywhere your job finishes successfully
Net::HTTP.get(URI("https://stablemate.dev/ping/#{ENV['STABLEMATE_DIGEST_TOKEN']}"))
# or: curl -fsS --retry 3 https://stablemate.dev/ping/<token>
```

---

## 2 · The recurring.yml mapping (gem path)

Solid Queue defines recurring work in `config/recurring.yml`. Each task key becomes a monitor; its
Fugit cron `schedule:` becomes the **expected interval**.

```yaml
# config/recurring.yml
production:
  daily_digest:
    class: DailyDigestJob
    schedule: every day at 9am      # → monitor "daily_digest", interval ~24h
  db_backup:
    command: "Backup.run"
    schedule: every day at 3am      # → monitor "db_backup", interval ~24h
  clear_sessions:
    class: ClearSessionsJob
    schedule: every 15 minutes      # → monitor "clear_sessions", interval 15m
```

Mapping rules:
- `key` → `Monitor#name` (slug) and `solid_queue_task_key`.
- `schedule:` (parsed via **Fugit**) → `expected_interval` = the cron's nominal period. Set a sane
  default `grace_period` (e.g. 10–20% of the interval, min a few minutes); let users tune it.
- Monitors created this way get `source: :gem` → the UI shows the **`gem` chip**.

---

## 3 · The companion gem

### Install
```ruby
# Gemfile
gem "stablemate"
```
```ruby
# config/initializers/stablemate.rb
Stablemate.configure do |c|
  c.api_key = Rails.application.credentials.dig(:stablemate, :api_key) # sm_live_…
  c.ping_on_success = true   # auto-ping when a monitored job completes cleanly
end
```

The `api_key` comes from **Settings → API keys → Generate key** (shown once as `sm_live_…`). The gem
sends it as a bearer token to register monitors and resolve ping tokens.

### Auto-register on boot / deploy
On boot (or a `rails stablemate:sync` task), the gem reads the recurring schedule and upserts monitors:

```ruby
# lib/stablemate/registrar.rb (sketch)
module Stablemate
  class Registrar
    def self.sync!
      tasks = SolidQueue::RecurringTask.all      # or parse config/recurring.yml
      payload = tasks.map do |t|
        {
          key:       t.key,
          name:      t.key,
          interval:  Fugit.parse(t.schedule).rough_frequency, # seconds
          class_name: t.class_name,
        }
      end
      Stablemate::Client.new.upsert_monitors(payload) # POST /api/v1/monitors/sync
    end
  end
end
```

Server side, `POST /api/v1/monitors/sync` (authenticated by the API key) upserts one `Monitor` per
task with `source: :gem`, returning each monitor's ping token. Tasks removed from the schedule can be
soft-paused rather than deleted.

### Auto-ping on success
A Solid Queue / Active Job hook pings the matching monitor when a monitored job finishes without error:

```ruby
# lib/stablemate/job_hook.rb (sketch)
ActiveSupport.on_load(:active_job) do
  around_perform do |job, block|
    block.call
    Stablemate.ping_for(job.class.name) if Stablemate.config.ping_on_success
  rescue => e
    raise # a raised job does NOT ping → the heartbeat correctly goes missing
  end
end
```

Net effect: a developer adds the gem + an API key, and their recurring jobs appear as monitors and
check in on their own — **no per-job code**. That's the "magic that already happened" the UI implies.

---

## 4 · Auto-pause / state sync

- When a queue or recurring task is **paused in Solid Queue**, the gem (or a periodic sync) pauses the
  matching monitor → status `paused`, no false alarms. Resume re-arms it.
- The **overdue sweep** is itself a recurring job (e.g. every minute) that flips monitors to `down`
  and opens an `Incident`; the next successful ping resolves it. Incidents are **open/resolved only**
  (no acknowledge step in V1).

---

## 5 · API surface (authenticated by `sm_live_…` key)

| Endpoint | Purpose |
|---|---|
| `POST /api/v1/monitors/sync` | Upsert monitors from the recurring schedule (gem) |
| `GET  /api/v1/monitors` | List monitors + ping tokens |
| `POST /ping/:token` | Heartbeat check-in (no API key — the token is the secret) |
| `POST /api/v1/monitors/:id/rotate` | Rotate a ping token |

**Key handling:** generate a random `sm_live_<random>`, show it **once**, store only a digest +
`last4` for the UI. Authenticate gem requests with `Authorization: Bearer sm_live_…`; compare by
digest. Ping tokens are separate per-monitor secrets (rotatable), distinct from API keys.

---

## 6 · Why Solid Queue specifically

- It ships in the Rails 8 default stack — no Redis/Sidekiq dependency to assume.
- Recurring tasks are **declarative** (`recurring.yml`), so the gem has a clean, stable source of truth
  to map from — that's what makes zero-config registration honest rather than a wizard.
- The scheduler running late or not at all is exactly the failure a heartbeat catches: a missed
  recurring run = a missed ping = `down`.
