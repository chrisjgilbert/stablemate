# Stablemate

Zero-per-job-code monitoring for Rails + Solid Queue. Add the gem and an API
key; your recurring jobs auto-register as monitors and check in on their own.

## Install

```ruby
# Gemfile
gem "stablemate"
```

```ruby
# config/initializers/stablemate.rb
Stablemate.configure do |c|
  c.api_key  = Rails.application.credentials.dig(:stablemate, :api_key) # sm_live_…
  c.endpoint = "https://stablemate.dev" # your own domain if self-hosting
  c.ping_on_success = true
end
```

Get the API key from **Settings → API keys → Generate key** (shown once).

## How it works

Two layers, both keyed on the Solid Queue **task key**:

- **Layer 2 — registration.** On boot (and via `rails stablemate:sync`) the gem
  reads `config/recurring.yml`, turns each `class:`-backed task into a monitor
  (`registration_key` = task key, interval parsed from `schedule:` via Fugit —
  for irregular crons the *largest* gap is used), and upserts them via
  `POST /api/v1/monitors/sync`. Idempotent; a sync failure logs a warning and
  never crashes boot. `command:`-only tasks are **skipped with a logged
  notice** — they run as `SolidQueue::RecurringJob`, so execution tracking
  can't attribute their runs; wrap the command in a job class, or create a
  monitor by hand and ping its URL from the command (details and the upgrade
  path in `docs/integrating.md`).
- **Layer 1 — execution tracking.** A subscriber to `perform.active_job` pings
  the matching monitor on every **successful** run. A raised job does **not**
  ping (a missed beat is the signal). Pings are fire-and-forget on a background
  thread with a short timeout, and every error is swallowed — Stablemate can
  never break your jobs. Backend-agnostic: works on any ActiveJob adapter, not
  just Solid Queue.

### Manual fallback (no Layer 2)

An app that skips registration can still use Layer 1 against a **manually
created** monitor whose `registration_key` equals the job class name (e.g.
`CleanupJob`). The subscriber pings it on success.

## Configuration

| Option | Default | Meaning |
|---|---|---|
| `api_key` | – | `sm_live_…` bearer token (registration only; never on the ping path) |
| `endpoint` | `https://stablemate.dev` (or `STABLEMATE_ENDPOINT` env) | Server base URL — set to your own domain when self-hosting |
| `ping_on_success` | `true` | Ping when a monitored job completes cleanly |
| `recurring_path` | `config/recurring.yml` | Solid Queue recurring config |
| `timeout` | `2` | HTTP timeout (seconds) |

## Development

```sh
cd gem
bundle install
bundle exec rake   # or: ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require File.expand_path(f) }'
```

Tests make no real network calls — the HTTP client is stubbed.

## License

The companion gem is released under the **MIT License** (see [`LICENSE`](LICENSE))
so it can be embedded freely in any Rails app, including closed-source ones. This
is intentionally more permissive than the Stablemate server, which is AGPLv3.
