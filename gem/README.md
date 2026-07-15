# Stablemate

Zero-per-job-code monitoring for Rails + Solid Queue. Add the gem and an API
key; your recurring jobs auto-register as monitors and check in on their own.

## Install

Not on RubyGems yet — install from git. The gem lives in the `gem/`
subdirectory of the Stablemate repo, so point bundler at the gemspec with
`glob:`:

```ruby
# Gemfile
gem "stablemate",
    git:  "https://github.com/chrisjgilbert/stablemate",
    glob: "gem/*.gemspec"
```

Pin to a `ref:` (commit SHA) or a release `tag:` so a repo push can't change the
gem under you — without one, bundler tracks the default branch tip. Once it's
published this becomes the usual `gem "stablemate"`.

```ruby
# config/initializers/stablemate.rb
Stablemate.configure do |c|
  c.api_key  = Rails.application.credentials.dig(:stablemate, :api_key) # sm_live_…
  c.endpoint = "https://stablemate.dev" # your own domain if self-hosting
  c.ping_on_success = true
  c.ping_on_failure = true  # report terminal job failures as error notices
end
```

Get the API key from your project in Stablemate — **open the project → Generate
key** (shown once). **Generate one API key per project:** the key *is* how
Stablemate knows which project an app's monitors belong to, so give each app its
own project and its own key (two apps sharing one key land in the same project and
can collide on task keys).

**Store the key where only production can see it** — per-environment
credentials (`rails credentials:edit --environment production`) or an env var
set only on production hosts. The gem auto-wires **only in production by
default** (`c.environments = ["production"]`), so even a key in shared
credentials won't make dev/test boots register monitors or ping them — a
laptop pinging a production monitor would mask a real outage. To monitor
staging too, add it: `c.environments = %w[production staging]`.

## How it works

Two layers, both keyed on the Solid Queue **task key**:

- **Layer 2 — registration.** On boot (and via `rails stablemate:sync`) the gem
  reads `config/recurring.yml` with Solid Queue's own section rule — the
  current environment's section when one exists, the whole file otherwise —
  turns each `class:`-backed task into a monitor (`registration_key` = task
  key, interval parsed from `schedule:` via Fugit — for irregular crons the
  *largest* gap is used), and upserts them via
  `POST /api/v1/monitors/sync`. Idempotent; a sync failure logs a warning and
  never crashes boot. `command:`-only tasks are **skipped with a logged
  notice** — they run as `SolidQueue::RecurringJob`, so execution tracking
  can't attribute their runs; wrap the command in a job class, or create a
  monitor by hand and ping its URL from the command (details and the upgrade
  path in `docs/integrating.md`).
- **Layer 1 — execution tracking.** A subscriber to `perform.active_job` pings
  the matching monitor on every **successful** run, and a global
  `ActiveJob::Base.after_discard` callback (Rails ≥ 7.1) reports **terminal
  failures** — an unhandled raise, `retry_on` exhausted, or `discard_on` — as
  an error notice (`status=1` + `ExceptionClass: message`) on the same ping
  URL, flipping the monitor down immediately with the error in the alert.
  Attempts that will be retried report nothing; on hosts older than 7.1 (and
  for a job that never runs at all) the missed beat remains the signal. All
  requests are fire-and-forget on a background thread with a short timeout,
  and every error is swallowed — Stablemate can never break your jobs.
  Backend-agnostic: works on any ActiveJob adapter, not just Solid Queue.

### Manual fallback (no Layer 2)

An app that skips registration can still use Layer 1 against a **manually
created** monitor whose `registration_key` equals the job class name (e.g.
`CleanupJob`). The subscriber pings it on success and reports its terminal
failures.

## Configuration

| Option | Default | Meaning |
|---|---|---|
| `api_key` | – | `sm_live_…` bearer token (registration only; never on the ping path) |
| `endpoint` | `https://stablemate.dev` (or `STABLEMATE_ENDPOINT` env) | Server base URL — set to your own domain when self-hosting |
| `environments` | `["production"]` | Environments where the railtie auto-wires (boot sync + subscriber). Array, bare string/symbol, or `nil` (= wherever an `api_key` is set). `rails stablemate:sync` runs regardless — but it still reads the *current* environment's `recurring.yml` section, so run it in the environment you mean to register |
| `environment` | `Rails.env` (else `RAILS_ENV`/`RACK_ENV`, else `development`) | The environment name used by the gate above and for `recurring.yml` section scoping |
| `ping_on_success` | `true` | Ping when a monitored job completes cleanly |
| `ping_on_failure` | `true` | Report a terminal job failure (unhandled raise, `retry_on` exhausted, `discard_on`) as an error notice — the monitor goes down immediately and the alert carries `ExceptionClass: message` (truncated to 1,000 chars). Needs Rails ≥ 7.1; retried attempts never report |
| `register_on_boot` | `true` | Auto-register monitors from `recurring.yml` on boot (Layer 2). Set `false` to manage monitors yourself (UI, or an explicit `rails stablemate:sync`) and stop every boot from upserting your `recurring.yml`. With it off, boot still attaches Layer 1 and loads your existing monitors' ping URLs read-only (`GET /monitors`), so successful runs still check in — the gem just never creates or edits monitors from `recurring.yml` |
| `recurring_path` | `config/recurring.yml` | Solid Queue recurring config |
| `timeout` | `2` | HTTP timeout (seconds) |
| `logger` | stderr logger | Where gem warnings go (sync failures, skipped tasks) — set `Rails.logger` to fold into app logs |

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
