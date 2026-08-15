# Integrating your jobs with Stablemate

> Looking to **run your own Stablemate server**? See [`install.md`](install.md) for
> the Docker / docker-compose self-hosting guide. This page is about wiring your
> *jobs* to a Stablemate instance (managed or self-hosted).

Stablemate watches your scheduled jobs by **heartbeat**: each job checks in when
it finishes. If a check-in is late by more than the grace period, Stablemate
emails you.

**Your repo is the source of truth.** Jobs are declared in your app's config and
registered by `bin/rails stablemate:sync` — there is no "create a monitor" form,
because a monitor that outlives the job it watched is the failure this design
exists to prevent. §1 covers Rails + Solid Queue, where the gem derives
everything from `recurring.yml` with zero per-job code; §2 covers work that
isn't a Solid Queue task, which is declared the same way and checks in with a
plain HTTP call from any language.

---

## 1 · The gem path (Rails + Solid Queue)

The companion gem registers your recurring jobs as monitors and pings them on
every successful run. You write no per-job code.

### 1.1 Add the gem

The gem isn't on RubyGems yet, so install it straight from the git repository.
Because the gem lives in the `gem/` subdirectory of the Stablemate repo, point
bundler at the gemspec with `glob:`:

```ruby
# Gemfile
gem "stablemate",
    git:  "https://github.com/chrisjgilbert/stablemate",
    glob: "gem/*.gemspec"
```

```sh
bundle install
```

For reproducibility, pin to a specific commit or release tag so a later push to
the repo can't silently change the gem under you:

```ruby
gem "stablemate",
    git:  "https://github.com/chrisjgilbert/stablemate",
    glob: "gem/*.gemspec",
    ref:  "919c0f2"        # a commit SHA, or `tag: "gem-v0.1.0"` once tagged
```

Without a `ref:`/`tag:` bundler tracks the default branch tip and only moves on
`bundle update stablemate`. Self-hosting from your own fork? Swap the `git:` URL
for it.

> Once the gem is published to RubyGems this collapses to `gem "stablemate"` —
> the git block above is the interim install path.

### 1.2 Get an API key

Keys belong to a **project**, so generate one on the project this app should
register its monitors into: **Projects → the project → Generate key**. The raw
key (`sm_live_…`) is shown **once** — copy it immediately; only its digest and
last 4 characters are stored, so a lost key is replaced, never recovered. Store
it in **production-only** credentials (or an env var set only on production
hosts):

```sh
bin/rails credentials:edit --environment production
```

```yaml
stablemate:
  api_key: sm_live_xxxxxxxxxxxxxxxxxxxx
```

Every monitor this app registers lands in that key's project, and the API sees
only that project — another project of the same account is as invisible as
another account's. (Your monitor cap stays per-account, across all projects.)

The key's presence is the gem's per-environment switch, and as a second
guard the gem auto-wires **only in production by default** — dev and test
boots never register monitors or ping them (a laptop pinging a production
monitor would mask a real outage). To monitor staging too, set
`c.environments = %w[production staging]` in the initializer.

### 1.3 Run the install command

One command writes the initializer, shows you what production will register, and
proves both keys against the server — with the two keys from your project page
(each raw key is shown once):

```sh
bin/rails stablemate:install STABLEMATE_API_KEY=sm_live_… STABLEMATE_PING_KEY=sm_ping_…
```

```
writing config/initializers/stablemate.rb
reading config/recurring.yml (production section) — this is what will be monitored:
  reports.daily  every 24h  (derived from '0 9 * * *')
  weekday_report every 72h  (derived from '0 9 * * 1-5')
✗ db_backup      skipped: command task, no class: to observe
  (nothing is registered here — `bin/rails stablemate:sync` does that, in production.)
verifying credentials… ✓ API key valid   ✓ ping key valid
writing .env (STABLEMATE_API_KEY, STABLEMATE_PING_KEY) — your dev machine only
writing .kamal/hooks/post-deploy (kamal detected) — registration runs there, on every deploy

next: add both keys to your production secrets (.kamal/secrets, or the deployed app's credentials)
      — the sync runs in the container, and your local .env doesn't ship.
then deploy, and watch: https://stablemate.dev/projects
```

**It registers nothing.** The whole point is that everything it shows is real
*without* pretending a job has run: the config is written, the intervals are the
ones your schedules actually derive (read from the **production** section, even
though you are running it on a laptop), and both credentials are checked with
two real calls — `GET /api/v1/verify` for the ping key, `GET /api/v1/monitors`
for the API key. A rejected key names *which* one and exits non-zero. Monitors
appear when §1.5's sync runs in production.

**No secret is written into a committed file.** The initializer reads the
environment first and falls back to credentials; the keys go into an existing
`.env` — updated in place on a re-run, which is how you rotate a lost key — or,
with no `.env`, are printed as `bin/rails credentials:edit` lines for you to
paste. A missing `config/recurring.yml` is a note, not an error, and a re-run
never clobbers your initializer or an existing Kamal hook.

`STABLEMATE_ENVIRONMENT=staging` previews a different `recurring.yml` section,
for layouts that don't register from `production`.

This is what it writes, and what you edit later:

```ruby
# config/initializers/stablemate.rb
Stablemate.configure do |c|
  c.api_key         = ENV["STABLEMATE_API_KEY"].presence ||
                      Rails.application.credentials.dig(:stablemate, :api_key)
  c.ping_key        = ENV["STABLEMATE_PING_KEY"].presence ||
                      Rails.application.credentials.dig(:stablemate, :ping_key)
  c.endpoint        = "https://stablemate.dev"   # ← your own domain if self-hosting
  c.ping_on_success = true          # ping when a monitored job finishes cleanly
  c.ping_on_failure = true          # report terminal job failures (unhandled raise,
                                    # retry_on exhausted, discard_on) as error
                                    # notices — the alert says what raised
  # c.environments   = ["production"] # default; add "staging" to monitor staging
  # c.register_on_boot = true         # DEPRECATED and ignored: boot no longer
  #                                   # registers anything — it only attaches the
  #                                   # check-in listener. Registration is
  #                                   # `bin/rails stablemate:sync`. Assigning it
  #                                   # logs a notice and does nothing else.
  # c.recurring_path = "config/recurring.yml"  # default
  # c.timeout        = 2                        # HTTP timeout, seconds
end
```

### 1.4 Declare your jobs in `recurring.yml`

The gem reads Solid Queue's recurring config. Each task key becomes a monitor.
Environment sections (`production:`, `development:`, …) are resolved exactly as
Solid Queue resolves them: the current environment's section when one exists,
the whole file otherwise. Only tasks Solid Queue would actually run in this
environment get registered.

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
**largest** gap between runs is used as the expected interval — correct by
construction, because anything tighter would false-alarm. Want a snugger window?
Declare an override (see below); there is no per-monitor setting in the UI.

> **Your repo owns monitor config.** There is no edit form: `stablemate:sync`
> is the only writer of a monitor's name, interval and grace, and it writes
> whatever your config says on every run. That is the whole point — one source
> of truth, and `bin/rails stablemate:sync` restores it whenever something has
> drifted.
>
> It also means a change to `recurring.yml` lands on the next deploy with
> nothing else to do, and that removing an override puts the derived value back.

**Overriding a derived interval.** A weekday-only cron (`0 9 * * 1-5`) derives a
**72-hour** interval, because Friday 09:00 → Monday 09:00 is the largest gap.
Correct, and useless if you want to know on Tuesday. Override it beside your
declarations:

```ruby
Stablemate.configure do |c|
  c.overrides = { "weekday_report" => { interval: 26.hours } }
end
```

Be clear-eyed about the trade: 26 hours closes the Tuesday blind spot **by
trading it for a false alarm every Saturday morning** (Friday 09:00 + 26h). V1
detection is interval-based, and no single interval can express "weekdays at
9am" — so a weekday-only job means choosing between the blind window and the
weekly cry-wolf. Stablemate stores your cron string from day one, so
cron-aware detection can fix this properly later without a gem release.

Overrides take `interval:` and `grace:`. An unknown key inside the hash, or an
override naming a task the registrar never derived, **fails the whole run before
any request is made** — a silently-ignored typo would leave the weekday job on
its 72-hour window, which is the exact failure overrides exist to close.

> **`command:`-only tasks are skipped** (with a logged notice). Solid Queue runs
> them as `SolidQueue::RecurringJob`, so the gem can't attribute a run back to the
> task and would register a monitor that never gets pinged. Either wrap the command
> in a small job class and use `class:`, or create a monitor manually and append a
> `curl` ping to the command (see §2).
>
> Upgrading from a gem version that *did* register command tasks? Sync never
> deletes monitors, so the old monitor lingers (down or pending, alerting, and
> counting toward your plan's cap) — delete or pause it from its detail page.
> The same applies to monitors an older gem registered from *other
> environments'* sections of an env-keyed `recurring.yml`: they stop receiving
> pings after the upgrade and must be deleted or paused by hand.

### 1.5 Sync

Registration is a **command**. Boot registers nothing — it only attaches the
check-in listener — so monitors appear when you run:

```sh
bin/rails stablemate:sync
```

It prints one line per task, naming the interval **and where it came from**,
then what it could not register and what no longer matches a task:

```
✓ reports.daily  every 24h  (derived from '0 9 * * *')
✓ weekday_report every 26h  (override — derived 72h from '0 9 * * 1-5')
✓ pg_backup      every 24h  (declared in c.monitors)
✗ db_backup      skipped: command task, no class: to observe
! 2 monitor(s) here match no task in this run: old_report, legacy_sync
  (kept, state untouched — retire them with PRUNE=1, or restore the task)

synced 3 for environment 'production'.
```

**It exits non-zero when it registers nothing** — a missing `recurring.yml`, no
registerable task, a server that refused every entry (over your plan's monitor
cap, say), or a request that never completed. Since this command is the only
thing that registers anything, its exit status is your deploy's only evidence
that your jobs are monitored: fail the deploy on it, don't `|| true` it.

**It refuses to run outside `c.environments`** (production only by default),
because both the API key and the `recurring.yml` section are
environment-scoped: a laptop run would replace your production monitor set with
your *development* tasks. `FORCE=1` overrides it if you really mean this one.

**It warns when your two keys name different projects.** Nothing else can catch
this: registration follows the API key, check-ins follow the ping key, so an
app configured with project A's API key and project B's ping key registers
monitors in A that nothing will ever check in to — they go down permanently
while the jobs behind them run fine, and every symptom reads "your job is
down". The sync response carries the last four characters of *every live* ping
key in the project, and the command compares yours against that set. A set, not
a value, so rotating (two keys live at once, old one revoked afterwards) stays
silent. The run still succeeds — the registration itself was fine.

**`PRUNE=1` retires monitors that no task declares any more** — reversibly.
Retiring keeps the monitor, its history and its settings, stops detection and
alerting, and frees its slot against your plan's cap; the next sync that
includes the task revives it with a fresh window and no false alarm. A task
that is still in `recurring.yml` but merely unregisterable (you deleted its
`class:` line, or its schedule stopped parsing) is reported and **never**
retired — fix the task instead. Without the flag, orphans are only reported.
Bake `PRUNE=1` into your deploy hook if you want each deploy to provision
exactly the set your repo declares.

A run that found **no task at all** in `recurring.yml` — the file is missing,
the path doesn't resolve in the container, or the current environment has no
section so the whole file resolved to a list of *other* environments — drops
the flag and says so on stdout. Retirement is bounded by the task list the run
sends, and a list that is short because nothing was read is how a bad parse
retires everything. (So a host that declares work only in `c.monitors` and has
no `recurring.yml` cannot prune; delete the stale monitor from its detail page
instead.)

Sync is **idempotent** — it upserts monitors keyed on the task key, so running
it repeatedly is safe, including in parallel across hosts.

#### Running it on deploy

Kamal hooks run on the **deploying machine**, where `RAILS_ENV` is unset — so a
bare `bin/rails stablemate:sync` in a hook is exactly the wrong-environment run
the guard refuses. Put this in `.kamal/hooks/post-deploy` (and `chmod +x` it):

```sh
#!/bin/sh
set -e
kamal app exec --reuse "bin/rails stablemate:sync"
```

`pre-deploy` is wrong and looks right: it runs before the new container boots,
so `--reuse` execs in the *old* container against the old image's
`recurring.yml` — and the job you just added is never registered.

That's it. On each **successful** job run the gem fires a fire-and-forget ping in
the background. A job that fails **for good** — an unhandled raise, `retry_on`
with its attempts exhausted, or a `discard_on` match — now reports too: the gem
sends the error (`ExceptionClass: message`) to the same monitor, which goes
**down immediately** and the alert email says what raised. Attempts that will
be retried stay completely silent — no error report, and no success ping
either, so a failed attempt never advances the monitor's clock — and a job
that fails once and succeeds on retry never alerts. Terminal-failure reporting needs Rails ≥ 7.1 (Active Job's
`after_discard` hook); on older hosts, and for a job that never runs at all, the
**missed beat remains the backstop** — the monitor still goes down when the
ping is overdue past the grace period.

---

## 2 · Non-Rails work (any language, any scheduler)

A shell cron, a Python script, a job on another box — anything that isn't a
Solid Queue task — is monitored the same way as everything else: **declare it in
your Rails app's config**, then have it check in.

There is no "create a monitor in the UI" path. Declaring the work in your repo
is what makes the monitor exist, which is what stops a monitor outliving the job
it was watching.

### Declare it

```ruby
Stablemate.configure do |c|
  c.monitors = { "pg_backup" => { interval: 1.day, grace: 2.hours } }
end
```

Deploy, and `stablemate:sync` registers `pg_backup` alongside your Solid Queue
tasks. The hash key is the **registration key** — the address the job checks in
at.

### Check in (curl, cron, shell)

```sh
# at the end of your job
curl -fsS -X POST https://stablemate.dev/api/v1/monitors/pg_backup/pings \
  -H "Authorization: Bearer $STABLEMATE_PING_KEY"
```

`POST` only — a check-in has side effects, so nothing that merely follows a link
may fire one. Optionally report run latency:

```sh
curl -fsS -X POST https://stablemate.dev/api/v1/monitors/pg_backup/pings \
  -H "Authorization: Bearer $STABLEMATE_PING_KEY" \
  --data-urlencode "duration_ms=842"
```

### Report failures too (`status` / `message`)

The same endpoint accepts an **error notice**: pass the job's exit code as
`status` (`0`, blank, or absent = success; anything else = failure) and the error
text as `message`. One snippet always fires and `$?` decides the polarity — no
conditional logic in the shell:

```sh
# end of any cron job — success and failure ride the same line
run_backup 2>/tmp/backup.err
curl -fsS -X POST https://stablemate.dev/api/v1/monitors/pg_backup/pings \
  -H "Authorization: Bearer $STABLEMATE_PING_KEY" \
  --data-urlencode "status=$?" \
  --data-urlencode "message=$(tail -c 500 /tmp/backup.err)"
```

A failure check-in flips the monitor **down immediately** — no waiting out the
grace window — and the alert email includes your `message` (or
`exited with status <n>` if you send none). `s` and `m` work as short aliases;
messages are truncated to 1,000 chars server-side.

### Ruby (Net::HTTP)

```ruby
require "net/http"

uri = URI("https://stablemate.dev/api/v1/monitors/pg_backup/pings")
request = Net::HTTP::Post.new(uri)
request["Authorization"] = "Bearer #{ENV['STABLEMATE_PING_KEY']}"
Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
rescue StandardError
  # best-effort: never let a failed check-in break the job
end
```

### Notes

- **The ping key is the credential**, and it is the *only* thing here that is
  secret. The task name in the path is not — which is why it can sit in your
  logs. `stablemate:install` puts the key in your `.env` or credentials; the
  same key works for every task in the project.
- A ping key can **only check in**. It cannot read your monitors or register new
  ones, so the key you ship to every container is not the key that can change
  your account.
- URL-encode the task name if it contains dots or spaces (`reports.daily` works
  as-is in a path segment; a space needs `%20`).
- Responses: `{"ok":true}` on success, an opaque `401` for a bad key and an
  opaque `404` for an unknown task. Rate-limited (see [`api.md`](api.md))
  generously enough for any real cron cadence.
- **Rotating the key** is a project-level operation: issue a new ping key from
  the project page, roll it out, then revoke the old one. Both work in the
  meantime.

---

## 3 · What you'll see

- A **pending** monitor flips to **up** on its first ping.
- If a ping is overdue past the grace period, the monitor goes **down** and you
  get one `down` email.
- A **failure ping** (`status` non-zero — sent by the gem on a terminal job
  failure, or manually via `status`/`message`) flips the monitor **down
  immediately** — no grace wait. The email is titled "*<name>* reported an
  error" and shows the reported error, as does the red incident banner on the
  monitor's detail page.
- The next successful ping flips it back to **up** and sends one `recovered` email.
- The dashboard shows a 90-day uptime bar per monitor.

See [`api.md`](api.md) for the full HTTP contract and
[`runbook.md`](runbook.md) for operations (backups, deliverability).
