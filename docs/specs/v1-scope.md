# V1 scope — one way in, one way to check in

Status: **proposed**, not yet built. Supersedes the draft that lived at
`ping-architecture.md`, which covered only the incident fix.

This is a scope document. It fixes an incident, and it uses that work to settle
what V1 is: **a monitor comes into existence exactly one way, and reports exactly
one way.**

---

## 0 · What this amends

`docs/specs/README.md` is binding. This document contradicts parts of it, so those
parts need inline amendment notes in the same change, following the pattern
already used there (decision #2: *"Amended by `job-failure-details.md` §5.1"*).

| Where | What changes |
|---|---|
| Decision #4, *"Gem ping reliability — fire-and-forget, errors swallowed"* | **Amended.** Errors are no longer swallowed: a `401` is logged once and a `404` once per task name (§6.4). "Never blocks the job" and "a transient outage is absorbed by the grace period" both survive intact. |
| Decision #6, *"`registration_key` = the recurring.yml task key… the registrar writes it"* | **Amended.** It stops being an internal idempotency key and becomes the monitor's **public address**. A backfill becomes a second writer, and it becomes character-set sensitive. |
| Decision #3, *"No gate on monitor creation"* | **Narrowed.** Survives only as a statement about `bin/rails stablemate:sync`. |
| §2 Security defaults, the whole `ping_token` bullet | **Void.** Every clause — plaintext by design, the dashboard showing it, the API re-serving it, the uninformative 404, per-token rate limiting, rotation — describes surfaces this removes. |
| §3 Data model, `Monitor` | `ping_token` and its unique index are deleted; `source` becomes constant (§4.3). |

Decision #5 (*"user can tighten via UI override"*) **survives, and that is
deliberate.** Monitor *editing* is retained precisely because #5 requires it — and
it is why the `last_synced_*` columns and `gem_may_write?` must stay (§3.1). A
later "finish the job, delete the whole controller" cleanup would silently break a
locked decision.

Two pre-existing errors in that data model are worth fixing while editing it: the
`Monitor` block omits six shipped columns, and lists the status vocabulary without
`suspended`.

---

## 1 · What V1 is

**A scheduled job stops running, we email you.** Everything below is in service of
making that one promise legible.

After this work:

- **Monitors come from one place.** `bin/rails stablemate:sync` reads
  `config/recurring.yml`, plus anything declared in config, and registers it.
  Nothing registers at boot. Nothing is created in the browser.
- **Check-ins go to one endpoint**, authenticated by one credential:
  ```
  POST /api/v1/monitors/{registration_key}/pings
  Authorization: Bearer sm_live_…
  ```
- **The web interface is for looking, and for the two things only a human decides:**
  overriding a schedule, and pausing.

What that costs is stated plainly in §7. The largest remaining question — whether
billing belongs in V1 at all — is §10, and is not decided here.

## 2 · The incident, and what actually fixes it

The gem asked the server where to send check-ins at boot and remembered the
answer. One timed-out call left it with nothing to send to, and nothing ever made
it ask again:

```ruby
# gem/lib/stablemate/execution/subscriber.rb:256-260
def dispatch(key, label:, &request)
  url = url_for(key)
  return unless url                 # ← gives up here, silently
  @dispatcher.call(-> { deliver(url, label, &request) })
```

The repair path is reachable only *after* a request has been sent, and a request
can only be sent if an address was found. **The repair is behind the door it is
meant to open.** Four healthy jobs alerted as down while the monitoring was what
had failed.

**The fix is §3.2 alone** — build the address locally and there is nothing to
fetch, cache, or go stale. §3.1 and §3.3 are product decisions that ride along;
they are worth doing, but this document should not pretend they are incident
fixes. Once addresses are local, a failed registration degrades from *"all
monitoring silently dead until restart"* to *"a schedule change wasn't picked up
this deploy."*

Two related defects, both confirmed by booting a real app against the railtie:

- `railtie.rb:44` is `next unless Stablemate.config.api_key`. With no key there
  are **zero** `perform.active_job` listeners and no log line of any kind.
- `railtie.rb:43-75` wraps all startup wiring in one catch-all, so a YAML syntax
  error leaves the listener unattached with a single warning.

## 3 · The three changes

### 3.1 Registration becomes a command

`bin/rails stablemate:sync` already reads `recurring.yml`, builds tuples and posts
them. It becomes the only registrar. The railtie stops registering.

Monitors that are not Rails jobs are declared in the same place, so they go
through the same command:

```ruby
c.monitors = { "pg_backup" => { interval: 1.day, grace: 2.hours } }
```

**What does not change:** the `last_synced_name` /
`last_synced_expected_interval_seconds` / `last_synced_grace_period_seconds`
columns and `gem_may_write?`. Their comment blames boot sync, and the tempting
inference is that a deliberate command makes them unnecessary. It does not — the
command belongs in a deploy script, so it still runs on every deploy, and a
setting tightened by hand must still survive it. Locked decision #5 depends on it.

### 3.2 Check-ins are addressed locally and authenticated by header

The gem already knows the task name. Using it as the address means nothing is
fetched.

The credential moves out of the URL and into a header, which buys four things a
path-borne secret cannot:

- **It leaves the logs.** Rails logs request paths verbatim and filters only query
  strings.
- **`GET` stops applying.** A check-in advances the monitor's clock and, on a
  monitor that is down, resolves the incident and sends a "recovered" email.
  Anything that follows a link — chat previews, mail prefetch, scanners — could
  fire one. This endpoint is `POST` only.
- **It becomes an ordinary REST resource.**
- **Two specific faults never get written** (§5.3, §5.4).

| Removed from the gem | ~Lines |
|---|---|
| The shared address map and its lock | 25 |
| The re-fetch mechanism, its throttle, mutex and timer | 25 |
| The two methods that populate the map | 21 |
| `list_monitors` and the "address rejected" state | 20 |
| The startup wiring, `register_on_boot`, the read-only fetch | 8 |

~110 lines of the 646 non-comment lines in `gem/lib` — but the count understates
it. This is the gem's only state shared between threads, and most of its hard
reasoning: an immutable snapshot swapped under a lock, readers guaranteed never to
block, re-fetches throttled against a clock that cannot run backwards.

### 3.3 Monitor creation leaves the web interface

The create path goes: `MonitorsController#new` and `#create`, `resolve_project`,
`load_projects`, `new.html.erb`, and the six `new_monitor_path` references — five
links plus `ProjectsController#after_create_path`. Editing stays (decision #5), and
`_form.html.erb` and `_preset_field.html.erb` are shared with it, so they stay —
though the form's project selector at `:4-14` is create-only and goes.

With one creator, these become unreachable rather than merely unused:

| Dead | Why |
|---|---|
| `Monitor::Transfer`, `Monitors::ProjectsController`, the manual branch of `_move.html.erb` | Its first line is `return … unless @monitor.manual?` |
| `awaiting_setup?` and the branch it drives | `manual? && !ever_pinged? && !suspended?` |
| The provenance chip, `from_gem?`, `manual?`, `source` | Every monitor has one provenance |

Keep the rest of `_move.html.erb` — lines `:7-11` and `:26-30` are the only place
the detail page shows which project a monitor belongs to.

**`source` is a breaking API change, not a cleanup.** It is served by
`GET /api/v1/monitors/:id` via `monitor_detail_json` and documented at
`api.md:127`, and the column is `null: false` with a default — so dropping it
needs a migration and an API note.

## 4 · One credential, not two

An earlier draft added a project-scoped ping key so the gem would hold something
that could not read or rewrite monitors. **V1 ships one credential: the existing
API key.** The reasoning matters, because the earlier draft kept a conclusion
whose premise it had already deleted.

**Both credentials would live in the same place, always.** The configuration
surface is a single `Stablemate.configure` block in
`config/initializers/stablemate.rb`, loaded by every process that boots the app —
so every web and job worker would hold both in the same object. The command must
hold both by design, since it needs the API key to register and the ping key to
print usable commands. And the one concrete shell-cron case, the nightly
`pg_dump`, runs **as root on the same host as the app container** and already
holds `RAILS_MASTER_KEY` and a full database dump.

**Both original objections to reusing the API key are already dead**, each to a
change this document makes anyway. The `last_used_at` write is coarsened for
`ApiKey` regardless (§5.2). The 120/min project-wide limiter comes from inheriting
the API base controller, and the check-in controller deliberately does not inherit
it (§5.2) — Rails scopes rate-limit buckets by `controller_path`, so a separate
controller gets a separate bucket even presenting the identical token.

**The capability delta is lateral, not a ladder.** This is the part that settles
it. A leaked API key can rewrite `expected_interval_seconds` on every monitor —
and `gem_may_write?` does not stop it, because it allows any write whose incoming
value differs from what the gem last sent. Setting every interval to a hundred
years **permanently and silently disables all alerting**, and unlike a forged
check-in it persists after the attacker leaves. A leaked ping key can forge
heartbeats and, via `status=1`, page the owner at will with arbitrary text. Each
holds a capability the other lacks; **both independently defeat the product's core
promise.** There is no "the ping key is the safe one" story to tell.

**It is additive later, not a one-way door.** No credential ever enters the domain
model — `check_in!` takes `received_at:`, `source_ip:`, `duration_ms:`, and nothing
about which credential authenticated is persisted. So adding `PingKey` later is a
new table, one `PingKey.authenticating(t) || ApiKey.authenticating(t)` line, and a
deploy to drop the fallback. No backfill, no historical data to reinterpret.

What this deletes from the earlier draft: a model, an issuance operation, a
controller, two views, project-page wiring, a migration, ~185 lines of tests
asserting behaviour already asserted about `ApiKey`, a second config gate of
exactly the kind §2 blames for the incident, and the entire "two credentials that
can disagree" failure mode — roughly 450–500 lines that buy nothing until the two
credentials land in different trust domains.

**Revisit when** someone runs a check-in from a machine that should not hold the
management key — a shell script on a different host, or a customer who asks.

## 5 · Server design

### 5.1 The route

```ruby
namespace :api do
  namespace :v1 do
    resources :monitors, only: %i[index show]
    post "monitors/:registration_key/pings", to: "monitors/pings#create",
         constraints: { registration_key: %r{[^/]+} }, format: false, as: :monitor_pings
  end
end
```

**Declare it standalone.** Nesting inside `resources :monitors, param:
:registration_key` is wrong three ways, all verified: it silently retargets
`show`, so `GET /api/v1/monitors/42` arrives as a registration key while
`find_monitor` still reads `params[:id]`; Rails prefixes the nested parent's
parameter to `:monitor_registration_key`, so the constraint names a segment that
does not exist; and with the constraint inert, dotted task names break.

The constraint and `format: false` are both required — Rails excludes dots from
dynamic segments and treats a trailing `.foo` as a format. Verified:

```
GET  /api/v1/monitors/42                        => show,   id: "42"          (unchanged)
POST /api/v1/monitors/reports.daily/pings       => create, registration_key: "reports.daily"
POST /api/v1/monitors/%E6%97%A5%E6%9C%AC/pings  => create, registration_key: "日本"
POST /api/v1/monitors//pings                    => RoutingError
```

Two traps. `recognize_path` resolves the controller class, so these all raise
`RoutingError` until the controller exists — which reads exactly like a broken
route. And the `/` constraint is defensive, not preventive: `%2F` routes fine and
decodes to a slash-bearing key, so the pre-flight SQL in §8 will not tell you what
you think.

### 5.2 The controller, authentication and tenancy

`Api::V1::Monitors::PingsController` **must not inherit `Api::V1::BaseController`**
— not for credential reasons any more, but so it declares its own rate limiter
(§5.3), since `rate_limit` compiles to an anonymous `before_action` a subclass
cannot skip by name. Inherit `ActionController::API`, which has no forgery
protection to forget; `ActionController::Base` would reintroduce the trap
`pings_controller.rb:5-10` documents, invisible in the test environment.

It resolves the project from the key and reaches the monitor only through it:

```ruby
current_project.monitors.find_by(registration_key: params[:registration_key])
```

**That scoping is now the only thing keeping tenants apart.** The old ping token
was unique across the whole database, so isolation was a property of the schema.
Task names are ordinary words — `daily_digest`, `nightly_backup` — unique only
within a project. A test proving the same task name in two projects never crosses
is mandatory, and it should assert on the **class graph** too
(`assert_not …PingsController.ancestors.include?(BaseController)`), because a
behavioural test is a snapshot and this controller will sit in a directory where
every sibling inherits the thing it must not.

**Coarsen `last_used_at`.** Write it only when the stored value is more than five
minutes old — on the check-in path an unconditional write would queue a tenant's
concurrent check-ins behind one row. Apply the same to `ApiKey`; its only reader
is a "Last used" column.

What moves across from the public controller: the oversized-duration guard, the
array-shaped-parameter guard, and the success-or-failure rule. What does not: the
deliberately uninformative 404s and their reasoning.

### 5.3 Rate limiting

Two layers. **A per-IP layer first**, mirroring the one being deleted, because
without it there is no pre-authentication bound at all — the per-monitor key is
attacker-chosen on both halves, so an anonymous flood mints a fresh bucket per
request and never trips. Measured: 50 anonymous requests produced 50 distinct
buckets and zero throttling, each costing an indexed database query. The same
flood against today's `/api/v1` hits 429 after 300. Self-hosters have no
Cloudflare in front.

Then per **monitor**, keyed on values readable before authentication:

```ruby
by: -> { "#{Digest::SHA256.hexdigest(request.authorization.to_s.presence || request.remote_ip)}|#{params[:registration_key]}" }
```

**Digest it.** Rails emits `by:` and the cache key into an
`ActiveSupport::Notifications` payload on every throttle, and the value is also
the literal cache key written to the store — so an undigested key puts live
credentials into any broadly-subscribed monitoring tool, and into Postgres if the
store ever moves to Solid Cache. `Api::V1::BaseController:51` has this defect
today; fix it there in the same change rather than reproducing it.

Two ways to get the lambda wrong, both measured. `by: -> { @current_ping_key }`
reads an ivar that does not exist yet at filter time; Rails builds the key with
`.compact`, which **drops the nil rather than distinguishing it**, collapsing the
entire controller to one counter. The interpolated form
`"#{@current_ping_key}|#{params[...]}"` collapses to one counter per task name
instead — narrower, still wrong.

Pick the ceiling deliberately and put it in `config/initializers/stablemate.rb`
with the other constants; the current per-token limit is 30/min. It bounds the
alert-flood in §9.3.

### 5.4 Responses

Authenticated, so the existing API conventions apply: `401` for a missing,
unknown or revoked key; `404` for a valid key with an unknown task name.

**Be honest about what that discloses.** An earlier draft claimed it "reveals
nothing they could not learn from the monitors list." With one credential that is
now true — the same key can call `GET /api/v1/monitors`. It was false when the
ping key was separate, and if `PingKey` is ever added, the 200/404 split hands it
a capability it otherwise lacks: enumerating every task name in the project.
Record that as a condition on §4's "revisit when".

## 6 · Gem design

### 6.1 The command

`bin/rails stablemate:sync` gains three things.

**It must exit non-zero when it registers nothing.** Today it exits 0 four ways,
two without making an HTTP request at all: `recurring.yml` missing, the
environment section yielding no registerable tasks, the server refusing every
entry, and a transport failure (which prints via `warn`, setting no status). On a
free plan capped at five, declaring six jobs prints `synced 0` and exits 0. Under
CLI-only registration, "the command exited 0" is the entire evidence a deploy has
that anything is monitored.

**It must refuse to run outside its configured environment**, with a `FORCE=1`
override. `enabled_in?` exists only in the railtie — the rake task never consults
it. Run locally, it registers the *development* section into the production
project and exits 0. That was a nuisance when boot sync corrected it; now
whatever the last hand-run wrote is the entire monitor set.

**It must report what the server refused.** `sync!` currently returns the
process-wide address cache, and the rake task prints `cache.size` — which has
never been a per-run count. Return a result carrying both a count and the
`skipped` reasons, since §11 requires printing them. Two traps: `{}` is truthy, so
a `nil`-returning replacement flips "synced 0" into a failure message; and
`0.size` is `8`, so `.size` must be removed, not just re-pointed.

### 6.2 Where it runs

**Kamal hooks execute on the deploying machine, not in the container.** A bare
`bin/rails stablemate:sync` in a hook runs on the laptop or CI runner with
`RAILS_ENV` unset — i.e. development, i.e. the trap above. The correct form is
`kamal app exec --reuse "bin/rails stablemate:sync"` in a **post-deploy** hook.
`pre-deploy` is wrong and looks right: it runs before `app:boot`, so `--reuse`
execs in the *old* container against the old image's `recurring.yml`, and the
newly added job is never registered.

Note there is no `.kamal/hooks/` directory in this repo, and `config/deploy.yml`
references a `.github/workflows/deploy.yml` that does not exist. "Put it in your
deploy script" currently has nowhere to go — creating that hook is part of this
work.

`app exec` fans out across hosts in parallel. That is safe: `Project::MonitorSync`
holds the user row lock across the run, isolates each insert in a savepoint, and
rescues `RecordNotUnique` into an idempotent update. Its comment blaming "the
railtie's `after_initialize` sync" needs rewriting — multi-host `app exec` is the
live reason now.

### 6.3 Which tasks may report

Today, when a job class is not in `recurring.yml`, the gem falls back to the class
name — but only if the server had given it an address. **The cache is quietly
acting as a server-approved allow-list.** Remove it and an address is
constructible for any string, so the gem would report after every successful run
of every job class in the host app.

The registrar builds two structures, and **both are needed**: `class_to_keys` maps
job class to task keys, while `tuples` is an array carrying no class name at all —
so the class→key direction is unobtainable from `tuples` alone. `tuples` is the
narrower set, skipping tasks with no schedule, command-only tasks, and schedules
whose interval cannot be derived. Intersect them:

```ruby
registerable = registrar.tuples.map { |t| t[:registration_key] }.to_set
reportable   = registrar.class_to_keys
                        .transform_values { |ks| ks.select { |k| registerable.include?(k) } }
                        .reject { |_, ks| ks.empty? }
```

**`c.monitors` keys must never enter this map.** They have no job class by
definition, and the keys are arbitrary user strings — so a key matching a host job
class name binds them, and an unrelated Rails job advances the shell script's
monitor. The monitor reads green while the backup has been failing, which is
precisely the failure this product exists to prevent. Keep two sets: *may-register*
(tuples + `c.monitors`) and *may-report-by-class-name* (tuples only).

**`c.monitors` also needs translating.** The server's entry struct reads
`registration_key` / `name` / `expected_interval_seconds` / `grace_period_seconds`;
`{ interval:, grace: }` matches none of them and has no key field, so untranslated
entries are **silently dropped** — sync reports success and every check-in 404s
forever. Durations survive JSON as numeric strings and the server casts them, so
only the field names need mapping. A key colliding with a `recurring.yml` task is
currently resolved last-wins with no warning; reject or report it.

### 6.4 Reading the response, and boot

- `401` — the key is wrong or revoked. Log **once**, loudly.
- `404` — this task is not registered. Log **once per task name**, naming the
  remedy: run `bin/rails stablemate:sync`.
- Anything else — transient, absorbed by the grace period.

Log through `Rails.logger` when Rails is defined. The gem's logger defaults to
stderr, and §2 diagnoses that exact channel as why the original failure went
unnoticed; the replacement must not inherit it. There is no `log_error` helper —
`Logging` provides only `log_warn`/`log_info` — so one is needed to keep the
`[stablemate]` prefix and the raising-logger guard.

"Once" is per-process state written from background dispatch threads, so it needs
a guard. Note the real risk is not `Set#add?` — 19.2M contended operations
produced zero double-adds — but the `check → log → add` shape people actually
write, where the logging IO releases the GVL. That races about 1% of the time.

**Boot attaches the listener and does nothing else:**

```ruby
config.after_initialize do
  if Stablemate.config.api_key.presence
    registrar = Registrars::SolidQueueRecurring.new   # local YAML only
    Execution::Subscriber.new(reportable: reportable_from(registrar)).subscribe!.subscribe_discards!
  else
    Stablemate.log_error("no api_key configured — check-ins are DISABLED …")
  end
rescue StandardError => e
  Stablemate.log_error("boot wiring skipped: #{e.class}: #{e.message}")
end
```

Four things this gets right that an earlier draft did not:

- **It keeps the rescue.** `Psych::SyntaxError` is a `StandardError`, so dropping
  it turns a broken `recurring.yml` from "monitoring off" into "the app will not
  boot" — strictly worse than the bug being fixed.
- **`.presence`, not truthiness.** A set-but-empty environment variable is `""`,
  which is truthy — the gate would pass, the error would never print, and every
  request would carry `Authorization: "Bearer "` for a permanent 401.
  `Configuration#default_environment` already guards against exactly this for
  `RAILS_ENV`.
- **It logs above the environment gate**, so a developer booting locally is told.
- **It passes the reportable set**, without which §6.3 is not implemented.

`handle_event` also needs a rescue. It is the only public handler without one —
`handle_retry` and `handle_discard` both have one — and an exception raised in a
`perform.active_job` subscriber propagates into `perform_now`, **failing the
host's job**. The gem's "nothing may propagate into the host" guarantee is
currently enforced only on the dispatch side.

Name the encoder: **`ERB::Util.url_encode`**. `CGI.escape` and
`URI.encode_www_form_component` turn a space into `+`, which decodes as a literal
`+` in a path segment — so a task named `"my task"` would 404 forever while §5.1's
route table passed, because none of its examples contain a space.

## 7 · What the user journey becomes

**There is no browser-only path to seeing the product work.** Sign up, and the
next step is: add the gem, deploy, run the command, wait for a job to fire. This
is the largest product cost and it is accepted deliberately.

Three surfaces currently promise what will no longer exist, and all three must be
rewritten in the same change:

- **`projects/show.html.erb:20-27`** — *"No monitors in this project yet. Add one
  manually, or connect the gem…"* with an **Add a monitor** button. This is the
  page a brand-new user lands on immediately after creating their first project.
- **`monitors/index.html.erb:75-82`** — *"No monitors yet — connect the gem or add
  one."*
- **`projects/_first_run.html.erb:36`** — links to the gem guide with a
  placeholder `"#"`. Worse, this card renders only when the user has **no
  projects**, so the moment they create one it becomes unreachable — taking the
  only gem-guide link in the signed-in product with it. The real instructions have
  to live on a page a user with a project can still see.

`stablemate_docs_url` already exists and is used on the marketing pages.

**`db/seeds.rb` creates a manual monitor with no task name and prints a ping URL
for a deleted route.** It is the documented walking-skeleton path, so it must
become: create a project, issue an API key, print the `stablemate:sync` invocation.

**The monitor detail page** loses the ping-URL card entirely — that is the whole
of `_ping_setup.html.erb`, rendered for every monitor, not only ones awaiting
setup. What replaces it is a short "how this monitor reports" block naming the
task key and the command.

**The silent state gets worse before §9.1 fixes it.** Detection only considers
monitors marked `up`, so one that is registered but never checked in is invisible
forever — no alert, no error, a permanently grey row. Today that state is
transient because the setup card tells you exactly what to paste. After this it
becomes the steady state of a mis-registered monitor, and both surfaces that
explained it are being deleted. **§9.1's never-checked-in alert should ship with
this work, not after it.**

## 8 · Change inventory

Measured, not estimated.

| Area | Scale |
|---|---|
| Create path (controller, view, six references, form selector) | ~110 lines |
| Transfer cascade | ~92 |
| Provenance chip + `source` + migration | ~43 |
| Ping-token surface (`_ping_setup`, both rotation controllers, the concern, `PingsController`, helpers, routes, serializers) | ~250 |
| `registration_key` backfill migration | ~40 |
| **Server subtotal** | **~535** |
| Gem deletions (§3.2) | ~110 |
| **Tests broken by UI removal** | ~393 across 15 files, 4 deleted whole |
| **Tests broken by the check-in move** | ~647 across 9 files, 3 deleted whole |
| **Gem suite** | 48 of 94 tests error under the deletions |

Two things the totals hide:

**Capybara cannot set an `Authorization` header.** Six call sites across
`outage_recovery_test.rb`, `uptime_history_test.rb` and `error_notices_test.rb`
drive check-ins with `visit ping_path(...)`. Each must become a direct
`monitor.check_in!` or an in-test HTTP call — weakening them from "the real
endpoint drove this" to "we called the model". Given `CLAUDE.md`'s system-test
rule, decide consciously which flows keep true end-to-end coverage.

**Three assertions stop testing anything rather than failing** — `refute_link "New
monitor"` in three system tests will stay green while proving nothing. Delete them
deliberately.

**Leave `registration_key` nullable for now.** `NOT NULL` costs ~215 test fixes
(95 `monitors.create` call sites pass no key; 3 of 4 fixtures have none) and buys
little while `Project::MonitorSync` is the only writer. Backfill so every existing
monitor is addressable — deriving from the name, iterating deterministically with
a set of keys already taken in this run. Do **not** use `String#parameterize`: it
strips non-Latin characters entirely, so 日本語のジョブ derives to empty, which
contradicts §5.1's unicode support. Strip only `/` and surrounding whitespace, and
handle duplicate names, names deriving to blank, and collisions on the
`monitor-<id>` fallback.

## 9 · What this does not fix

### 9.1 Alerts still point at the wrong system

A wrong key, DNS failure, blocked egress, a rate limit — in every case the server
sees silence and the email says the job "missed its check-in". Three signals,
cheapest first:

- **The API key already records when it was last used**, on every registration —
  and nothing reads it. *"This app registered three minutes ago but no monitor has
  reported for an hour"* is a positive statement with no false positives.
- **Alert on monitors that have never checked in.** As §7 notes, this should ship
  with this work rather than after it.
- **Notice a whole project going quiet** — the most recent check-in anywhere in
  the project older than the shortest interval-plus-grace in it. Needs a
  project-level incident record.

**Say what was observed, never what it means.** *"No monitor in project Foo has
reported since 14:02"* is true whether the cause is a firewall, a crashing worker
or a deliberate shutdown.

### 9.2 The catch-all around gem startup

Narrow it so a broken `recurring.yml` cannot silently leave the listener
unattached — while still catching `Psych::SyntaxError`, or the app stops booting.

### 9.3 A leaked key pages you at will

With one credential the picture is simpler but not smaller: a leaked key can
enumerate every monitor, rewrite every interval, and forge both check-ins and
failure reports. **Two requests produce one email** carrying up to 1,000
characters of attacker-controlled text from your sending domain. The rate-limit
ceiling in §5.3 is what bounds this; pick it with that in mind.

Content handling itself is clean — truncation is unconditional in the model layer,
every render escapes, and header injection through the monitor name is Q-encoded
by the mail gem. Checked, not assumed.

Worth adding cheaply: `ping_events` records `source_ip` but nothing about which
key was used. A nullable key reference makes a suspected leak investigable.

### 9.4 An unrelated bug found while verifying

`Execution::Subscriber.install_discard_hook` installs its callback **twice**, so
every terminal failure reports twice. `defined?(::ActiveJob::Base)` does not force
the autoload but `.respond_to?` does, which re-enters the railtie's
`on_load(:active_job)` hook while `@discard_hook` is still nil. Reproduced:
`after_discard_procs.size == 2`.

The one-line fix has a side effect worth knowing: assigning `@discard_hook` before
touching `::ActiveJob::Base` leaves it set on hosts without `after_discard`
(Rails < 7.1), and `remove_discard_hook` then raises. Use a separate re-entrancy
flag, or clear it on the capability bail-out.

## 10 · The largest V1 question, not decided here

Simplifying the product holistically surfaces something bigger than anything
above, and it is a product call rather than an engineering one.

**Billing is 3,488 lines — 21% of the codebase and 23% of the test suite — for a
capability with no customers and no price.** Two facts, both verified:

- `config/deploy.yml:86` sets `STABLEMATE_SIGNUP_ACCOUNT_CAP: 1`. Production has
  room for exactly one account, and it is the maintainer's.
- `pages/pricing.html.erb:69` renders the Pro price as **"TBC"** with the note
  *"Placeholder — final Pro pricing hasn't been signed off yet."*
  `launch-readiness.md` lists chunks 1–4 as **NOT STARTED**.

It also propagates. Billing is why `Monitor` has a fifth status (`suspended`),
requiring special handling in the uptime rollup, the live-day stat, the check-in
transition and the cap scope; why `Notifications::Dispatch` needs
`after_all_transactions_commit`; and why both the monitor create path and
`Project::MonitorSync` hold a **user** row lock purely for slot accounting.

Removing it is high-reversibility — the code is well-factored and recoverable from
git — but the judgement inside `User::Subscription` (the terminal-versus-unbillable
status distinction, the double-billing guard, the livemode gate) is expensive to
re-derive. If it goes, delete it from `main`, tag the commit, and reference the tag
here. A dormant billing system still costs CI time, dependabot noise, security
scanning surface, and that fifth monitor status.

A smaller adjacent candidate: the waitlist, signup cap and two Slack alerts,
~660 lines, including the app's only Postgres advisory lock.

**Not proposed here — flagged for a decision.** If it goes, it belongs in this V1
scope; if it stays, it should be because the price is about to be set.

## 11 · Test plan

- **Browser: the monitor lifecycle without creation.** A registered monitor can be
  edited, paused and deleted; the create route is gone.
- **Browser: onboarding.** A brand-new user reaches real instructions from the
  page they land on, and no surface offers monitor creation (§7).
- **Tenant isolation.** The same task name in two projects; checked in with project
  A's key, project B's monitor untouched.
- **Structure.** The pings controller does not inherit the API base controller.
- **Rate limiting, both directions.** Two task names under one key must not share a
  counter, **and two keys on one task name must not share one** — the second is
  what catches a lambda reading post-authentication state, and the first alone
  would pass a broken implementation. Plus: an unauthenticated flood is bounded.
- **Routing.** A dotted task name arrives intact.
- **Backfill.** Duplicate names, a name deriving to blank, and a non-Latin name
  each produce a distinct, usable, slash-free key.
- **Command.** Exits non-zero on all four register-nothing paths, prints the
  server's reasons, and refuses to run outside its configured environment.
- **Gem: unlisted job classes never report**, and a task with an underivable
  schedule never reports.
- **Gem: a `c.monitors` key matching a host job class name never binds to it.**
- **Gem: boot with no API key** — one error line, listener not attached, app still
  boots. **And with a broken `recurring.yml`** — one error line, app still boots.
- **Gem: `401` and `404` handled differently**, each logged once.
