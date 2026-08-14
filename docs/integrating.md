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
**largest** gap between runs is used as the expected interval; tighten it later in
the monitor's settings if you want a snugger window.

> **Who wins when you edit a synced monitor.** The gem re-registers on every
> production boot, and remembers what it last sent for the **name**, **interval**
> and **grace**. While the stored value still matches that, the gem owns it and
> keeps it current — so a `recurring.yml` change lands on the next boot without
> you touching anything.
>
> Edit one of those three in the UI and the gem leaves it alone: your override
> survives every re-sync that has nothing new to say. But if `recurring.yml`
> itself later changes that setting, **the schedule wins** and your override is
> replaced. That is deliberate — the interval and grace describe how often the
> job *actually* runs, so an override derived from the old schedule is stale and
> would false-alarm, which is the failure this product exists to prevent. Re-apply
> your override after a schedule change if you still want the snugger window.
>
> Monitors registered by a gem version older than this rule have nothing
> remembered yet, so their **first** sync writes nothing and only records what it
> sent. If `recurring.yml` had already changed for one of them, that change lands
> on the following change rather than that first sync.

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

## 2 · The manual path (any language, any scheduler)

Every monitor has a **ping URL** containing a secret token. Hit it from the end of
your job. Find the URL on the monitor's detail page — shown up top while the
monitor awaits its first ping, and inside the **"Ping URL & setup"** section at
the bottom once it's live (it includes a ready-to-paste `curl` snippet).

### curl (cron, shell)

```sh
# at the end of your job
curl -fsS https://stablemate.dev/ping/<ping_token>
```

A bare `GET` works; `POST` is identical. Optionally report run latency:

```sh
curl -fsS "https://stablemate.dev/ping/<ping_token>?duration_ms=842"
```

### Report failures too (`status` / `message`)

The same URL accepts an **error notice**: pass the job's exit code as `status`
(`0`, blank, or absent = success; anything else = failure) and the error text as
`message`. One snippet always fires and `$?` decides the polarity — no
conditional logic in the shell:

```sh
# end of any cron job — success and failure ride the same line
run_backup 2>/tmp/backup.err
curl -fsS "https://stablemate.dev/ping/<ping_token>" \
  --data-urlencode "status=$?" \
  --data-urlencode "message=$(tail -c 500 /tmp/backup.err)"
```

A failure ping flips the monitor **down immediately** — no waiting out the
grace window — and the alert email includes your `message` (or
`exited with status <n>` if you send none). `s` and `m` work as short aliases;
messages are truncated to 1,000 chars server-side.

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
  Treat the URL as a secret. Rotate it from the **"Ping URL & setup"** section of
  the monitor's detail page if it leaks (the old URL stops working immediately).
- The endpoint always returns `{"ok":true}` on a known token and an opaque `404`
  on an unknown one. It is rate-limited (see [`api.md`](api.md)) generously enough
  for any real cron cadence.

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
