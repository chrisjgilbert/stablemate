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

Section numbers in the left column are **`README.md`'s**; those in the right are
**this document's**.

| Where (in `README.md`) | What changes |
|---|---|
| Decision #4, *"Gem ping reliability — fire-and-forget, errors swallowed"* | **Amended.** Errors are no longer swallowed: a `401` is logged once and a `404` once per task name (§6.4). "Never blocks the job" and "a transient outage is absorbed by the grace period" both survive intact. |
| Decision #6, *"`registration_key` = the recurring.yml task key… the registrar writes it"* | **Amended.** It stops being an internal idempotency key and becomes the monitor's **public address**. A backfill becomes a second writer, and it becomes character-set sensitive. |
| Decision #3, *"No gate on monitor creation"* | **Narrowed.** Survives only as a statement about `bin/rails stablemate:sync`. |
| §2 Security defaults, the whole `ping_token` bullet | **Void.** Every clause — plaintext by design, the dashboard showing it, the API re-serving it, the uninformative 404, per-token rate limiting, rotation — describes surfaces this removes. |
| §3 Data model, `Monitor` | `ping_token` and its unique index are deleted; `source` becomes constant (§3.3). |

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
- **Check-ins go to one endpoint**, authenticated by a check-in-only credential:
  ```
  POST /api/v1/monitors/{registration_key}/pings
  Authorization: Bearer sm_ping_…
  ```
- **The web interface is for looking, and for the three things only a human
  decides:** overriding a schedule, pausing, and deleting.

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

**The incident fix is the first half of §3.2** — build the address locally and
there is nothing to fetch, cache, or go stale. §3.2's second half (the header
credential) is a security improvement, not an incident fix, and §3.1 and §3.3 are
product decisions that ride along. All are worth doing; this document should not
pretend they are all incident fixes. The two railtie defects below are also
untouched by it, and are handled in §6.4 and §9.2. Once addresses are local, a failed registration degrades from *"all
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
- **Two specific faults never get written** — the rate-limiter fault (§5.3) and
  the URL-parsing fault (§5.1), both of which come from having a credential and a
  task name as adjacent path segments.

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

## 4 · Two credentials

The check-in endpoint authenticates a **ping key** (`sm_ping_…`), a second
project-scoped credential whose only capability is recording a check-in. The
management API keeps the existing API key (`sm_live_…`).

**An earlier draft of this document argued for one credential and was wrong.**
Its reasoning is preserved here because the correction is the argument:

> *"The capability delta is lateral, not a ladder… Each holds a capability the
> other lacks; both independently defeat the product's core promise. There is no
> 'the ping key is the safe one' story to tell."*

That was tested rather than argued, and it failed. **It is a ladder, and the API
key is the top rung.**

### Why, measured

**An API key can durably silence alerting with one request.** `POST
/api/v1/monitors/sync` may rewrite `expected_interval_seconds` on an existing
monitor — `sync_params` permits it, `valid_shape?` checks only `positive?`, the
model validates only `greater_than: 0`, and `gem_may_write?` allows any value
differing from what the gem last sent. Observed: `3600 → 2_147_483_647`, HTTP 200.
And `before_update :recompute_next_due_at` fires on the sync itself, so the
monitor's next due date moves to 2094 **immediately** — no follow-up check-in
needed, nothing visible, one request.

**An API key can also page the owner, in a worse form than the ping key can.**
`monitor_mailer.rb:22` interpolates the monitor name straight into the subject:

```ruby
subject = "#{monitor.name} missed its check-in"
```

`validates :name, presence: true` is the only name validation and the column is an
unbounded `varchar`. So the subject line is attacker-controlled and unbounded. The
ping key's version of this capability — error text via `status=1` — lands in the
*body*, hard-truncated to `ERROR_MESSAGE_LIMIT` in the model layer.

The mailer documents the assumption this violates, in a comment written when the
name was user-authored:

> *"The subject carries only the monitor name, never the error (headers stay
> injection-proof, lock-screen previews clean)."*

**The capability sets are nested, not overlapping:**

| | ping key | API key |
|---|---|---|
| page the owner with chosen text | body, truncated | **subject, unbounded** |
| durably silence alerting | no | **yes, one request, invisible** |
| enumerate every monitor and task name | no | **yes** |
| rewrite name / interval / grace everywhere | no | **yes** |
| emit a "recovered" email | yes | no |
| write ping-event rows | yes | no |

The ping key's two exclusives are transient — both are overwritten by the next
legitimate check-in. Every durable capability belongs to the API key alone.

### The axis the earlier draft never considered

It reasoned about where credentials are *stored* and never about how often they
are *transmitted*. `gem/lib/stablemate/configuration.rb:6` states the property
being given up:

```ruby
# The sm_live_… API key (used for /api/v1 registration; NOT on the ping hot path).
```

Today the management key crosses the wire **once per deploy**. Under §3.2 it would
ride an `Authorization` header on **every job completion, from every worker,
forever** — through every egress proxy, tracing tool and retry buffer on the
highest-volume path in the system. Storage co-location and transmission frequency
are different exposure surfaces, and only the second one changes here.

So the ping key is the ordinary least-privilege answer: the credential on the hot
path cannot read your monitors, cannot rewrite them, and cannot silence them.

### What it costs, and what stays true from the earlier draft

Roughly 450–500 lines mirroring `ApiKey` — model, issuance, controller, views,
project-page wiring, migration, tests, docs — plus §9.4's mismatch guard, which
exists only because there are two.

Two of the earlier draft's observations survive and are worth keeping:

- **The two original objections to reusing the API key really are dead.** The
  `last_used_at` write is coarsened for `ApiKey` regardless (§5.2), and the
  120/min project-wide limiter is a property of inheriting the API base
  controller, not of the credential — Rails resolves a limiter's scope from
  `controller_path` at filter time, so any separate controller gets separate
  buckets, inherited or not. Neither was ever an argument about credentials.
- **Nothing about this is a one-way door.** No credential enters the domain model,
  so the decision could be reversed in either direction later without a backfill.

### Storage: hashed and shown once

Same as `ApiKey` — SHA-256 digest plus `token_last4` for a masked list, raw value
shown once at creation. Nothing needs to reconstruct it: the command prints
ready-to-paste `curl` lines from the host's own config (§6.1), so the web
interface never displays it.

**This must not be a "type" column on `api_keys`.** Authentication looks a token
up across the whole table, so one table means a ping key authenticates the
management API unless every lookup remembers to filter — and forgetting is silent
and permissive. Two tables make the mistake impossible rather than discouraged.

**Share the hashing, not the lookup.** Extract `digest(raw)` only. If the shared
module also owns the lookup and anyone writes `ApiKey.find_by(...)` inside it —
the natural thing to type while moving code *out of* `ApiKey` — both models
authenticate against `api_keys` and the separation silently collapses. Each model
keeps its own three-line `authenticating`.

## 5 · Server design

### 5.1 The route

```ruby
namespace :api do
  namespace :v1 do
    resources :monitors, only: %i[index show] do
      collection { post :sync, to: "monitors/syncs#create" }   # unchanged — §3.1 needs it
    end
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
route. Run this before the route ships, since task names become part of a URL:

```sql
SELECT count(*) FROM monitors WHERE registration_key IS NULL;
SELECT id, project_id, registration_key FROM monitors
WHERE registration_key ~ '[^A-Za-z0-9_.\-]';
```

It will not catch everything: the `/` constraint is defensive, not preventive —
`%2F` routes fine and decodes to a slash-bearing key (verified). Treat the query
as a sizing exercise for the §8 backfill, not a guarantee.

### 5.2 The controller, authentication and tenancy

`Api::V1::Monitors::PingsController` **must not inherit `Api::V1::BaseController`**,
because that base authenticates an `ApiKey` and this endpoint authenticates a
`PingKey`. That is a structural reason, and it is the right kind — an inherited
`before_action :authenticate_api_key!` would have to be suppressed, and
suppression can be forgotten.

Note it is *not* a rate-limiting reason, contrary to an earlier draft. Rails
resolves a limiter's scope from `controller_path` at filter time, so a subclass
gets its own buckets whether it inherits or not; measured — 122 requests to
`monitors#index` returned 429 while the same token on `syncs#create` returned 200.
Inheritance was never what isolated the counters.

Inherit `ActionController::API`, which has no forgery protection to forget;
`ActionController::Base` would reintroduce the trap `pings_controller.rb:5-10`
documents, invisible in the test environment. What must be reimplemented rather
than inherited: `rescue_from ActiveRecord::RecordNotFound`, the `{"error": …}`
response shape, and bearer-token extraction. Duplicate them deliberately and keep
the shapes identical to `/api/v1`.

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

Two layers, and **the order matters in the opposite direction to the obvious
one.** Declare **per-monitor first, then per-IP.**

Rails' limiter increments its counter unconditionally and the layers run in
declaration order, so a request already rejected by one layer still burns the
next one's budget. With per-IP first, a single runaway task exhausts the
host-wide bucket and throttles every other monitor on that host — measured: a
healthy monitor got 429 under per-IP-first and 200 under the reverse.

A per-IP layer is still required, because without it there is no
pre-authentication bound at all: the per-monitor key is attacker-chosen on both
halves, so an anonymous flood mints a fresh bucket per request and never trips.
Measured: 50 anonymous requests produced 50 distinct buckets and zero throttling,
each costing an indexed database query. The same flood against today's `/api/v1`
hits 429 after 300, and self-hosters have no Cloudflare in front.

The cost of putting per-monitor first is that per-IP no longer caps how many
buckets a flood can mint (400 versus 300 in a probe). That is bounded by the
store's own pruning, and by digesting and length-bounding the task-name half of
the key — do both.

The per-monitor layer is keyed on values readable before authentication:

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

Pick the ceiling deliberately; the current per-token limit is 30/min, and it
bounds the alert-flood in §9.3. Put it on the controller, alongside
`PingsController::PER_TOKEN_LIMIT` and `Api::V1::BaseController::PER_KEY_LIMIT` —
that is where every rate-limit constant in this app already lives. (Not in
`config/initializers/stablemate.rb`: this server's file of that name holds the
money and cost-control constants and no rate limits. Note the **host app** has an
unrelated file at the same path holding `Stablemate.configure` — §4 and §6 mean
that one.)

### 5.4 Responses

Authenticated, so the existing API conventions apply: `401` for a missing,
unknown or revoked key; `404` for a valid key with an unknown task name.

**Be honest about what that discloses.** A ping key holder cannot call
`GET /api/v1/monitors`, so the 200/404 split hands them a capability they
otherwise lack: enumerating every task name in the project. Job names leak
business logic — `payroll_export`, `gdpr_purge` — and turn blind forgery into
targeted forgery.

We accept it, because §6.4 needs the `404` to say "run `stablemate:sync`" and
that is the failure this design exists to make visible. State it as an accepted
cost rather than claiming it leaks nothing.

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

**It must hold both credentials.** The API key registers; the ping key is what it
prints in the ready-to-paste `curl` lines. Both live in the same
`Stablemate.configure` block, which is what makes §4's shown-once storage
affordable — the place that needs a finished command already holds the credential.

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

**Say what happens to the class-name fallback.** `resolve_keys` currently falls
back to the job class name when a class is not in the map, using the address cache
as the test for "does a monitor exist with this name?" With no cache that test is
gone, and the fallback would report for every job class in the host app. **Delete
the fallback.** The reportable map is now the complete answer, and
`docs/integrating.md`'s "manual fallback" section — which documents creating a
monitor by hand whose registration key equals a job class name — describes
something the interface can no longer do anyway (§3.3). Remove both.
`test_unmapped_perform_does_not_ping` is the invariant that must stay green.

**`c.monitors` also needs translating.** The server's entry struct reads
`registration_key` / `name` / `expected_interval_seconds` / `grace_period_seconds`;
`{ interval:, grace: }` matches none of them and has no key field, so untranslated
entries are **silently dropped** — sync reports success and every check-in 404s
forever. Durations survive JSON as numeric strings and the server casts them, so
only the field names need mapping. A key colliding with a `recurring.yml` task is
currently resolved last-wins with no warning; reject or report it.

Default `grace` the way the registrar already does — `max(interval * 0.15,
5.minutes)` — so a `c.monitors` entry that omits it behaves like a `recurring.yml`
task rather than getting zero grace. Document seconds as the canonical unit, since
`1.day` requires ActiveSupport and the gem supports a plain-Ruby host.

### 6.4 Reading the response, and boot

- `401` — the key is wrong or revoked. Log **once**, loudly.
- `404` — this task is not registered. Log **once per task name**, naming the
  remedy: run `bin/rails stablemate:sync`.
- Anything else — transient, absorbed by the grace period.

Log through `Rails.logger` when Rails is defined. The gem's logger defaults to
stderr (`lib/stablemate.rb:79`), which is where the original boot-sync warning
went and why nobody saw it — the replacement must not inherit that channel. There is no `log_error` helper —
`Logging` provides only `log_warn`/`log_info` — so one is needed to keep the
`[stablemate]` prefix and the raising-logger guard.

"Once" is per-process state written from background dispatch threads, so it needs
a guard. Note the real risk is not `Set#add?` — 19.2M contended operations
produced zero double-adds — but the `check → log → add` shape people actually
write, where the logging IO releases the GVL. That races about 1% of the time.

**Boot attaches the listener and does nothing else:**

```ruby
config.after_initialize do
  # Log first, so a developer booting locally is told even when the environment
  # allow-list will stop us wiring anything up.
  Stablemate.logger.error("[stablemate] no ping_key configured — check-ins are DISABLED …") if
    Stablemate.config.ping_key.presence.nil?

  next unless Stablemate.config.enabled_in?
  next unless Stablemate.config.ping_key.presence

  registrar = Registrars::SolidQueueRecurring.new   # local YAML only, no network
  Execution::Subscriber.new(class_to_keys: reportable_map(registrar)).subscribe!.subscribe_discards!
rescue StandardError => e
  Stablemate.logger.error("[stablemate] boot wiring skipped: #{e.class}: #{e.message}")
end
```

Five things this gets right, four of which an earlier draft got wrong:

- **It keeps the rescue.** `Psych::SyntaxError` is a `StandardError`, so dropping
  it turns a broken `recurring.yml` from "monitoring off" into "the app will not
  boot" — strictly worse than the bug being fixed.
- **`.presence`, not truthiness.** A set-but-empty environment variable is `""`,
  which is truthy — the gate would pass, the error would never print, and every
  request would carry `Authorization: "Bearer "` for a permanent 401.
  `Configuration#default_environment` already guards against exactly this for
  `RAILS_ENV`.
- **It keeps `enabled_in?`.** The environment allow-list is production-only by
  default and must survive, or a developer's laptop checks in to production
  monitors and masks a real outage. An earlier draft's snippet omitted the line
  while its own prose claimed to keep it.
- **It logs above that gate**, which is the whole reason the log line and the
  gate are separate statements.
- **It uses the real constructor keyword.** `Subscriber.new` takes
  `class_to_keys:`; there is no `reportable:` parameter. §6.3's intersection
  produces a map of the same shape, so it substitutes directly.

Two naming corrections while here: there is **no `log_error` helper** — `Logging`
provides only `log_warn`/`log_info`, and they are private instance methods, so
`Stablemate.log_error` would not resolve even if one existed. Either add
`log_error` to `Logging` and call it from an including object, or use
`Stablemate.logger.error` with an explicit `[stablemate]` prefix as above.

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
| `PingKey` model, issuance, controller, views, migration, project-page wiring | ~200 |
| Never-checked-in alert: scope, job, mailer, notification cause, copy (§9.1) | ~120 |
| **Server subtotal** | **~735** |
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
little while `Project::MonitorSync` is the only *ongoing* writer — the backfill
below is a one-shot migration, not a second write path, which is the sense in
which §0 calls it a second writer. Backfill so every existing
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
- **Alert on monitors that have never checked in. This one is IN scope** — see
  §7 for why, §8 for its budget and §11 for its test. It sits here because it
  belongs with its siblings, not because it is deferred. The threshold must be
  relative to the monitor's own interval, it must fire once, and it needs its own
  wording pointing at setup docs.
- **Notice a whole project going quiet** — the most recent check-in anywhere in
  the project older than the shortest interval-plus-grace in it. Needs a
  project-level incident record.

**Say what was observed, never what it means.** *"No monitor in project Foo has
reported since 14:02"* is true whether the cause is a firewall, a crashing worker
or a deliberate shutdown.

### 9.2 The catch-all around gem startup

§6.4 makes this loud — the rescue now logs — but it does not make it recoverable:
a broken `recurring.yml` still leaves the listener unattached for the life of the
process. Narrowing the rescue so the failure is contained, rather than taking the
listener with it, is the remaining work. It must still catch `Psych::SyntaxError`,
or the app stops booting.

### 9.3 A leaked key pages you at will

A leaked ping key can forge check-ins and failure reports for every monitor in the
project. **Two requests produce one email** carrying up to `ERROR_MESSAGE_LIMIT`
characters of attacker-controlled text from your sending domain. The rate-limit
ceiling in §5.3 is what bounds this; pick it with that in mind.

**One required fix, which is a live bug today.** An earlier draft of this section
said content handling was "clean — truncation is unconditional in the model
layer… Checked, not assumed." That is true of `error` and **false of `name`**:

```ruby
# app/mailers/monitor_mailer.rb:22
subject = "#{monitor.name} missed its check-in"
```

`validates :name, presence: true` is the only name validation and the column is an
unbounded `varchar`, so any API key holder can put arbitrary, unbounded text in an
email subject line. The mailer's own comment states the assumption being violated:
*"The subject carries only the monitor name, never the error (headers stay
injection-proof, lock-screen previews clean)."* Add a length validation and cap
what reaches the subject. This is independent of the credential split and should
ship regardless.

Everything else in the content path checks out: `error` is truncated
unconditionally in the model layer, every render escapes, and header injection via
the name is Q-encoded by the mail gem.

Worth adding cheaply: `ping_events` records `source_ip` but nothing about which
key was used. A nullable key reference makes a suspected leak investigable.

### 9.4 Two credentials that can disagree

Nothing forces the API key and the ping key to name the same project. Use project
A's API key with project B's ping key and registration writes to A while check-ins
go to B; A's monitors go down permanently and every symptom reads "your job is
down". This mistake is impossible with one credential and permanent with two, so
it needs a permanent guard.

Registration returns the last four characters of the project's ping key, and the
gem logs loudly at startup when the configured key does not match. No escalation —
an API key can already list every monitor in its project.

**Return a set, not a value.** §4's rotation procedure deliberately keeps two keys
live at once, so a guard comparing against "the project's ping key" would fire a
false alarm during exactly the operation it is meant to support.

### 9.5 A pre-existing bug in the sync path

An `expected_interval_seconds` above the `int4` ceiling raises an unrescued
`ActiveModel::RangeError` that escapes `Project::MonitorSync` and 500s the whole
request — rolling back the valid entries alongside the bad one. That violates the
"never raises / never leaves the payload half-applied" contract stated twice in
that same file. Found while testing §4's interval-rewrite claim; fix it in the
same change, since §4 relies on that path behaving as documented.

### 9.6 An unrelated bug found while verifying

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
- **Never-checked-in alert (§9.1).** A monitor registered and never checked in
  alerts once, after its own interval rather than a fixed delay, with copy
  distinct from a missed check-in — and does not alert twice.
- **Browser: onboarding.** A brand-new user reaches real instructions from the
  page they land on, and no surface offers monitor creation (§7).
- **Tenant isolation.** The same task name in two projects; checked in with project
  A's key, project B's monitor untouched.
- **Credential separation.** A ping key must be rejected by every other `/api/v1`
  endpoint, and an API key rejected by the check-in endpoint. Assert on the class
  graph too — `assert_not …PingsController.ancestors.include?(BaseController)` —
  because a behavioural test is a snapshot and this controller sits in a directory
  where every sibling inherits the thing it must not.
- **Browser: ping keys.** Issue one from the project page, see it once, see it
  masked afterwards, revoke it.
- **The mismatch guard fires on a real mismatch and stays silent during a
  rotation** with two live keys (§9.4).
- **Monitor name length is bounded**, and an oversized name cannot reach an email
  subject (§9.3).
- **An out-of-range `expected_interval_seconds` in a sync payload is reported as
  skipped, not raised**, and leaves the other entries applied (§9.5).
- **Rate limiting, three ways.** Two task names under one key must not share a
  counter; two keys on one task name must not share one (this is what catches a
  lambda reading post-authentication state, and the first case alone would pass a
  broken implementation); and **one throttled monitor must not consume another
  monitor's budget** — the layer-order bug in §5.3. Plus: an unauthenticated flood
  is bounded.
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
