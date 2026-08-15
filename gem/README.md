# Stablemate

Zero-per-job-code monitoring for Rails + Solid Queue. Add the gem, run one
command; your recurring jobs register as monitors and check in on their own.

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

Then run the setup command with the two keys from your project page (**Generate
key** and **Generate ping key**; each raw key is shown once):

```sh
bin/rails stablemate:install STABLEMATE_API_KEY=sm_live_… STABLEMATE_PING_KEY=sm_ping_…
```

```
writing config/initializers/stablemate.rb
reading config/recurring.yml (production section) — this is what will be monitored:
  reports.daily  every 24h  (derived from '0 9 * * *')
  weekday_report every 72h  (derived from '0 9 * * 1-5')
✗ db_backup      skipped: command task, no class: to observe
  (an interval is the LARGEST gap between runs … — tighten one with c.overrides.)
  (nothing is registered here — `bin/rails stablemate:sync` does that, in production.)
verifying credentials… ✓ API key valid   ✓ ping key valid
writing .env (STABLEMATE_API_KEY, STABLEMATE_PING_KEY) — your dev machine only
writing .kamal/hooks/post-deploy (kamal detected) — registration runs there, on every deploy

next: add both keys to your production secrets (.kamal/secrets, or the deployed app's credentials)
      — the sync runs in the container, and your local .env doesn't ship.
then deploy, and watch: https://stablemate.dev/projects
```

**It registers nothing, on purpose.** It writes the config, shows the intervals
it *would* register — always reading the **production** section, wherever you
run it — and proves both credentials with two real calls (`GET /api/v1/verify`
for the ping key, `GET /api/v1/monitors` for the API key). A rejected key names
*which* key and exits non-zero. Monitors appear when `bin/rails stablemate:sync`
runs, in production, from your deploy hook.

**No secret lands in a committed file.** The initializer it writes reads
`ENV["…"].presence || Rails.application.credentials.dig(…)`; the keys themselves
are appended to an existing `.env` (and *updated* there on a re-run — that is
how you rotate) or, with no `.env`, printed as `bin/rails credentials:edit`
lines. Re-running is safe: an existing initializer is never clobbered, and
neither is an existing `.kamal/hooks/post-deploy`.

| Variable | Effect |
|---|---|
| `STABLEMATE_API_KEY` | Required. Registers monitors; verified against `GET /api/v1/monitors` |
| `STABLEMATE_PING_KEY` | Required. Rides every check-in; verified against `GET /api/v1/verify`, which records nothing |
| `STABLEMATE_ENVIRONMENT` | Preview a different `recurring.yml` section (default `production`) |

This is what it writes:

```ruby
# config/initializers/stablemate.rb
Stablemate.configure do |c|
  c.api_key  = ENV["STABLEMATE_API_KEY"].presence ||
               Rails.application.credentials.dig(:stablemate, :api_key)  # sm_live_…
  c.ping_key = ENV["STABLEMATE_PING_KEY"].presence ||
               Rails.application.credentials.dig(:stablemate, :ping_key) # sm_ping_…
  c.endpoint = ENV["STABLEMATE_ENDPOINT"].presence || "https://stablemate.dev"
end
```

**Generate one API key per project:** the key *is* how
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

- **Layer 2 — registration.** `bin/rails stablemate:sync` (boot registers
  nothing) reads `config/recurring.yml` with Solid Queue's own section rule — the
  current environment's section when one exists, the whole file otherwise —
  turns each `class:`-backed task into a monitor (`registration_key` = task
  key, interval parsed from `schedule:` via Fugit — for irregular crons the
  *largest* gap is used; the raw schedule string rides along too, stored by the
  server and not yet acted on), adds any `c.monitors` declarations, and upserts
  them via
  `POST /api/v1/monitors/sync`. Idempotent; a run that registers nothing exits
  non-zero. `command:`-only tasks are **skipped with a logged
  notice** — they run as `SolidQueue::RecurringJob`, so execution tracking
  can't attribute their runs; wrap the command in a job class, or create a
  monitor by hand and ping its URL from the command (details and the upgrade
  path in `docs/integrating.md`). See [Registering monitors](#registering-monitors)
  for what the command prints and when it fails.
- **Layer 1 — execution tracking.** A subscriber to `perform.active_job` pings
  the matching monitor on every **successful** run, and a global
  `ActiveJob::Base.after_discard` callback (Rails ≥ 7.1) reports **terminal
  failures** — an unhandled raise, `retry_on` exhausted, or `discard_on` — as
  an error notice (`status=1` + `ExceptionClass: message`) on the same ping
  URL, flipping the monitor down immediately with the error in the alert.
  Attempts that will be retried send nothing at all — no report, and no
  success ping that would advance the monitor's clock; on hosts older than
  7.1 (and for a job that never runs at all) the missed beat remains the
  signal. All
  requests are fire-and-forget on a background thread with a short timeout,
  and every error is swallowed — Stablemate can never break your jobs.
  Backend-agnostic: works on any ActiveJob adapter, not just Solid Queue.

## Registering monitors

`bin/rails stablemate:sync` is the only writer of monitor configuration — the
web interface has no create or edit form — so it reports what it did rather
than exiting quietly:

```
✓ reports.daily  every 24h  (derived from '0 9 * * *')
✓ weekday_report every 26h  (override — derived 72h from '0 9 * * 1-5')
✓ pg_backup      every 24h  (declared in c.monitors)
✗ db_backup      skipped: command task, no class: to observe
! 2 monitor(s) here match no task in this run: old_report, legacy_sync
  (kept, state untouched — retire them with PRUNE=1, or restore the task)

synced 3 for environment 'production'.
```

A skipped job is **not monitored**, so it is named with its reason. The
derivation is named too: the interval is the *largest* gap between runs, so a
weekday-only cron derives 72 hours — see `c.overrides` below.

**It exits non-zero when it registers nothing**, whether that is a missing
`recurring.yml`, no registerable task, a server that refused every entry, or a
request that never completed. "Exited 0" is your deploy's only evidence that
anything is monitored, so treat a red sync like a red test.

**It refuses to run outside `c.environments`.** `recurring.yml` is
section-scoped, so a laptop run would replace your production monitor set with
your development tasks. `FORCE=1` overrides it when you really mean this one.

**It warns loudly when your two keys name different projects.** Registration
follows the API key; check-ins follow the ping key — point them at different
projects and the monitors this run registers go down permanently while the jobs
behind them run fine, with every symptom reading "your job is down". The sync
response carries the last four characters of *every live* ping key in the
project (a set, so a rotation with two keys live at once is silent), and the
command compares your configured key against it. It stays a warning: the
registration itself was fine.

| Variable | Effect |
|---|---|
| `PRUNE=1` | Monitors matching no task this run are **retired** — reversibly, keeping their history and settings; the next sync that includes the task revives them. A task that is still declared but merely unregisterable (a deleted `class:` line, a broken schedule) is reported and never retired. Without the flag, orphans are only reported. A run that found **no task at all** in `recurring.yml` (missing file, wrong path, a section that resolved to other environments) drops the flag and says so, rather than sending a key list it cannot vouch for — a short list is how a bad parse retires everything |
| `FORCE=1` | Run anyway, outside `c.environments` |

**Run it on deploy, in the container.** Kamal hooks execute on the deploying
machine, where `RAILS_ENV` is unset — so a bare `bin/rails stablemate:sync` in
a hook is exactly the wrong-environment run the guard refuses. Use a
**post-deploy** hook (`.kamal/hooks/post-deploy`):

```sh
#!/bin/sh
set -e
kamal app exec --reuse "bin/rails stablemate:sync"
```

`pre-deploy` is wrong and looks right: it runs before the new container boots,
so `--reuse` execs in the *old* one against the old image's `recurring.yml`,
and a newly added job is never registered. Fanning out across hosts in parallel
is safe — the sync is idempotent and serialised server-side.

## Configuration

| Option | Default | Meaning |
|---|---|---|
| `api_key` | `STABLEMATE_API_KEY` env | `sm_live_…` bearer token. **Registration only** (`bin/rails stablemate:sync`); never on the check-in path |
| `ping_key` | `STABLEMATE_PING_KEY` env | `sm_ping_…` bearer token, sent as `Authorization: Bearer` on **every check-in**. Without it boot logs one error and attaches no listener — check-ins are disabled |
| `endpoint` | `https://stablemate.dev` (or `STABLEMATE_ENDPOINT` env) | Server base URL — set to your own domain when self-hosting |
| `environments` | `["production"]` | Environments where the railtie attaches the check-in listener **and where `bin/rails stablemate:sync` will run at all**. Array, bare string/symbol, or `nil` (= wherever a `ping_key` is set). Sync refuses anywhere else, because it reads the *current* environment's `recurring.yml` section and would replace the project's monitors with that environment's tasks; `FORCE=1` overrides it |
| `environment` | `Rails.env` (else `RAILS_ENV`/`RACK_ENV`, else `development`) | The environment name used by the gate above and for `recurring.yml` section scoping |
| `ping_on_success` | `true` | Ping when a monitored job completes cleanly |
| `ping_on_failure` | `true` | Report a terminal job failure (unhandled raise, `retry_on` exhausted, `discard_on`) as an error notice — the monitor goes down immediately and the alert carries `ExceptionClass: message` (truncated to 1,000 chars). Needs Rails ≥ 7.1; retried attempts never report |
| `monitors` | `{}` | Work that is **not** a Rails job — a shell cron, a backup script — declared here so it registers through the same command: `c.monitors = { "pg_backup" => { interval: 86_400, grace: 7_200 } }`. **Seconds** are the unit (`1.day` works too on a Rails host); an omitted `grace` defaults like a task's (15% of the interval, minimum 5 minutes). These keys have no job class, so nothing auto-pings them — the work checks itself in. A key that repeats a `recurring.yml` task key, or an entry with no `interval:` or an unknown setting, fails the run |
| `overrides` | `{}` | Corrections to a **derived** interval, keyed by task key, in seconds: `c.overrides = { "weekday_report" => { interval: 93_600 } }`. The derived interval is the *largest* gap between runs, so `0 9 * * 1-5` derives 72 hours (Friday → Monday) — correct by construction, and useless if you want to know on Tuesday. Only `interval:` and `grace:` are accepted, and an interval-only override recomputes grace from the new interval. A key matching no derived task — a typo, a `c.monitors` key, a `command:` task, a schedule that can't be sized — fails the whole run before any request is made |
| `register_on_boot` | – | **Deprecated and ignored.** Boot no longer registers anything — it only attaches the check-in listener. Monitors are registered by `bin/rails stablemate:sync`. The option is still accepted (removing the accessor would raise `NoMethodError` inside a host's committed initializer and stop the app booting); assigning it logs a notice once and has no other effect |
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
