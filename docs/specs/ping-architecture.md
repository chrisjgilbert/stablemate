# Ping architecture — the split-credential redesign

Status: **proposed**, not yet built. Supersedes the fetch-and-cache ping-URL
scheme described in [`projects.md`](projects.md) §§345-347.

Prompted by an incident in a host app (`tokenprice.fyi`, 2026-08-01): a single
transient timeout on the gem's boot sync silently and permanently disabled every
ping for the life of the process, and four healthy jobs alerted as `down`. The
monitoring was down; the alerts blamed the jobs.

---

## 1 · The defect, precisely

`gem/lib/stablemate/execution/subscriber.rb:256-260`:

```ruby
def dispatch(key, label:, &request)
  url = url_for(key)
  return unless url                 # ← no log; trigger_resync lives BELOW this
  @dispatcher.call(-> { deliver(url, label, &request) })
```

`trigger_resync` is reachable only from `deliver`, which is reachable only after
`url_for` returned non-nil. **The recovery path is downstream of the thing that
fails.** An empty cache is an absorbing state: no ping, no log, no resync, for the
process lifetime. Under `SOLID_QUEUE_IN_PUMA` the supervisor forks workers that
inherit the empty cache, so one parent failure propagates to all of them.

Two corrections to the incident report:

- It is not *entirely* silent. `registration.rb:31` logs `sync failed: …` — but to
  **stderr**, not `Rails.logger`, unless the host set `c.logger`. The signal
  existed, once, in the wrong stream.
- **There is a worse sibling one level up.** `railtie.rb:43-75` wraps the entire
  boot wiring in one `rescue StandardError`. A `Psych::SyntaxError` from a
  malformed `recurring.yml` means the subscriber is never attached at all — no
  success pings *and* no failure reports, one warning, no recovery. Same shape.
  Deleting the URL cache does not touch it; §7.4 covers it separately.

## 2 · Decision: delete the cache, don't repair it

We adopt Healthchecks.io's split-credential model. A second, project-scoped
credential — the **ping key** — is issued from the dashboard and configured in the
host app alongside the API key. The ping target becomes derivable client-side:

```
POST|GET {endpoint}/ping/{ping_key}/{registration_key}
```

No fetch, no cache, no `:stale`, no resync.

**The reason is deletion, not boot fragility.** The ordering defect in §1 is
repairable in ~10 lines. What is not repairable is the class of bug: the `:stale`
path had tests, the empty-cache path had none, because nobody imagined it. You
cannot test a failure mode you have not thought of, but you can delete the
machinery that hosts it. What goes:

| Deleted | ~Lines | Kind |
|---|---|---|
| `Stablemate.ping_urls` / `merge_ping_urls` / `MERGE_LOCK` / `EMPTY_PING_URLS` | 25 | **the gem's only cross-thread mutable state** |
| `@resync` / `@resync_interval` / `@resync_mutex` / `@last_resync_at` / `trigger_resync` | 25 | throttled recovery protocol, monotonic clock |
| `Registration#cache_ping_urls`, `#refresh_ping_urls!` | 21 | |
| `Client#list_monitors`, the `:stale` branch of `classify` | 20 | a response state that exists only to serve the cache |
| railtie's `load_ping_urls` lambda + `resync:` wiring | 8 | |
| the `register_on_boot = false` read-only-fetch mode | — | a *second* boot-time network dependency |

~110 lines of ~680 in `gem/lib`, but the line count understates it: this is most
of the hard reasoning in the gem (the frozen-snapshot swap, the "readers never
take this lock" invariant, the bounded-resync throttle). `subscriber_test.rb` is
583 lines in which *every* test passes a `ping_urls:` hash.

**The complexity moves rather than vanishing** — the server gains a model, a
route and one more `find_by`. That is the trade we are making deliberately:
concurrent mutable state with a recovery protocol, exchanged for an indexed
lookup.

### 2.1 Why a second credential rather than reusing the API key

Reusing `sm_live_` on the ping path (`POST /api/v1/monitors/:registration_key/pings`,
header-authed) would also delete the cache, with no new credential and no
migration. It is the strongest alternative and was rejected on three grounds:

- `ApiKey::Authentication.authenticating` does `touch(:last_used_at)` — a row
  UPDATE on one contended row **on every job completion**, from every worker.
- The `/api/v1` limiter is 120/min shared across a project, versus 30/min per
  monitor. A project with 20 jobs firing on the minute self-throttles.
- Blast radius: `sm_live_` reads every monitor, bulk-rewrites them, and rotates
  ping tokens. Putting it on the highest-volume path puts it in far more proxy
  and APM logs.

The ping key exists so the gem holds a credential that **cannot read or rewrite
your monitors**. That is the posture argument, and it is the real one.

### 2.2 Deliberate divergences from Healthchecks

**No `?create=1` auto-provisioning.** Healthchecks' checks do not carry a
gem-derived interval and grace, and Healthchecks has no billing-coupled monitor
cap. This app has both:

- There is **no legitimate source for interval and grace**. From ping params, the
  hot path becomes a settings write that bypasses `Project::MonitorSync#gem_may_write?`
  — the carefully-argued logic that stops a boot sync clobbering a user's UI
  override. From a default, a daily job alarms hourly. Worse, an auto-provisioned
  monitor has `last_synced_*` all nil, which parks it permanently in
  `gem_may_write?`'s documented first-sync coin-flip branch, so the **wrong
  interval sticks**.
- **Cap exhaustion is a cheaper attack than forging pings.** Five unauthenticated
  requests fill a free account; the next real sync returns every genuine job under
  `skipped: "limit_reached"` and the victim is blind, with the UI telling them to
  buy slots. On self-host `MAX_MONITORS_PER_USER = 0 ⇒ unlimited`, so it is
  unbounded row creation from a URL.
- `GET` is supported, so `<img src=".../ping/KEY/x?create=1">` creates rows via any
  link scanner or Slack unfurl. A GET that mutates structure is exactly what the
  safe-method contract exists to prevent.
- It would need `user.with_lock` (per-user cap accounting) **on the public hot
  path**, serialising a tenant's pings behind one lock.
- It kills `Project::MonitorSync#diverging_app?` — the shared-key collision
  detector (§13-B3) — because `last_synced_app` is written only by sync.
- It discards the `skipped`/`limit_reached` reason strings that
  `Registration#log_skipped` exists to surface. `PingsController` renders
  `{ok: true}` and the client only inspects HTTP status.

Sync keeps its job as the **config channel** — it has a response body, and config
needs one. The ping is one bit, fire-and-forget. Once the ping no longer depends
on it, a failed sync is harmless by construction.

**Ping key is shown-once + digest-only, not displayable.** Healthchecks shows
theirs permanently on the project settings page. The objection to shown-once —
"lose it and you must rotate, and rotation is the dangerous operation" — is
answered by allowing **multiple live ping keys per project** (§3.1): mint a
second, deploy, watch `last_used_at` on the first go stale, revoke. Rotation
becomes additive-then-subtractive, and then digest-only storage costs nothing and
a database leak yields nothing usable.

There is a second-order benefit. With the key not displayable, the monitor card
shows a **template** rather than a URL:

```
POST https://stablemate.dev/ping/$STABLEMATE_PING_KEY/daily_digest
```

which pushes operators toward env-var injection instead of a literal pasted into
a crontab that gets committed to a config repo. That mitigates the largest
distribution risk in the design, for free.

## 3 · Server design

### 3.1 `PingKey`

A record, not a column on `projects`. Rotation needs two live values plus a drain
signal (`last_used_at` on the old key answers "is anything still using it?"); a
single column cannot express that, and a design that cannot rotate safely should
be rejected on that basis alone.

```
app/models/ping_key.rb              # manifest: include Authentication; belongs_to :project; masked
app/models/ping_key/issuance.rb     # operation: PingKey.issue(project:, name:) -> [key, raw]
```

`ping_keys`: `project_id`, `name`, `token_digest` (unique), `token_last4`,
`last_used_at`, timestamps — mirroring `api_keys`
(`db/migrate/20260628183139_create_api_keys.rb`). Raw format `sm_ping_<32
alphanumeric>`, a **distinct prefix** from `sm_live_` so a key pasted into the
wrong config slot fails loudly and secret scanners can tell them apart.

Migration follows the pattern of `20260714120000_create_projects_and_reparent_ownership.rb`
— **and its deviation note**: production has real data, so add nullable →
backfill *every* project (including keyless and gem-less ones) → enforce
`NOT NULL` + unique index. Explicit `up`/`down`, no `change`, so `db:rollback`
round-trips. `StrongMigrations.start_after = 20260715144540`, so a new table with
a unique index is checked and safe.

**Not** a `scope`/`kind` column on `api_keys`. `authenticating` does a global
`find_by(token_digest:)`; with one table a ping key authenticates `/api/v1`
unless every call site remembers to scope. `ApiKey.authenticating(raw, scope:)`
fails **open** — forget the argument at one call site and a ping key becomes a
management key. Two tables makes the escalation structurally impossible, which is
the entire point of a split credential.

#### Shared digest logic

`ApiKey::Authentication` is two class methods referencing nothing class-specific
(`digest`, `find_by(token_digest:)`, `secure_compare`, `touch`). A
`PingKey::Authentication` would be a character-for-character copy, and a fix
applied to one and not the other is a silent divergence in security-critical
code.

Extract **only the primitive**, not the policy: `app/models/concerns/hashed_token.rb`,
exposing `digest(raw)` and `find_by_token(raw)` (indexed lookup + `secure_compare`
+ the comment explaining why the compare is belt-and-braces). Each model keeps its
own `authenticating` holding its own policy:

- `ApiKey`: `find_by_token(raw)&.tap { it.touch(:last_used_at) }`
- `PingKey`: `find_by_token(raw)` — **no touch**, see §3.4.

A single shared `authenticating(touch_usage:)` is rejected for the same
fail-open reason as the `scope` column.

### 3.2 Route

```ruby
match "/ping/:ping_key/:registration_key", to: "pings#create", via: %i[get post],
      constraints: { registration_key: %r{[^/]+} }, format: false, as: :keyed_ping
match "/ping/:ping_token", to: "pings#create", via: %i[get post], as: :ping
```

The constraint is **not optional**. Verified against this app's own router:

```
# without the constraint
/ping/KEY/reports.daily  =>  registration_key: "reports", format: "daily"
# with it
/ping/KEY/reports.daily  =>  registration_key: "reports.daily"
```

`registration_key` is unvalidated free text from a stranger's `recurring.yml`
(`Project::MonitorSync::Entry` takes `raw[:registration_key].presence` verbatim;
`Monitoring::Monitor` has no format validation). Without the constraint a dotted
task key resolves to **a different monitor in the same project** — silencing the
wrong job's alert — and `keyed_ping_path` generates the very string the router
cannot read back. The gem must `ERB::Util.url_encode` the key when building the
URL.

Also verified: the two routes are disjoint (dynamic segments do not cross `/`), so
declaration order is irrelevant. But `/ping/KEY/` (trailing slash) falls through
to the **one-segment** route as `ping_token: "KEY"` → opaque 404. Documented, not
fixed; a trailing slash is a typo and 404 is the correct answer.

Run the format audit in §5 before the route ships.

### 3.3 Lookup, and the cross-tenant guarantee

Today `Monitoring::Monitor.find_by(ping_token:)` runs against a **globally
unique** index, so a ping resolves to exactly one monitor *by construction*.
`(project_id, registration_key)` is unique **per project only**, and registration
keys are low-entropy and human-chosen — `daily_digest`, `nightly_backup` collide
across tenants constantly. That collision is the entire motivation for projects
(`projects.md` §44).

So the new form replaces a structural guarantee with a discipline: **resolve the
project first, then every subsequent query goes through `project.monitors`.**

```ruby
PingKey.authenticating(params[:ping_key])&.project&.monitor_for(params[:registration_key])
```

with `Project#monitor_for(registration_key)` a one-line facade over
`monitors.find_by`. A test asserting the same `registration_key` in two projects
never crosses is **mandatory**, mirroring the cross-project opaque-404 discipline
in `Api::V1::BaseController`.

### 3.4 `PingsController`

The controller is ~100 lines today — two rate limiters with long rationale
comments, `numeric_duration_ms`'s int4-range guard, `string_param`'s array-param
defence, the failure-polarity rule. Bolting `if params[:ping_key]` onto that is
the drift CLAUDE.md rule 4 exists to prevent.

But a sub-resource is the wrong answer and so is a finder object: both URL forms
are the **same resource** (a ping), and the variability is purely in
*identification*. So:

1. Extract the existing fat into `app/controllers/concerns/ping_recording.rb` —
   `skip_forgery_protection`, both `rate_limit` declarations, `numeric_duration_ms`,
   `string_param`, `record_ping(monitor)`. (Precedent: `concerns/account_credentials.rb`,
   `concerns/project_show_data.rb`.)
2. Keep **one** `PingsController#create` whose private `find_monitor` is a
   two-line branch.

No `Monitoring::Monitor::PingLookup` — a class whose whole body is one `if` is
the junk drawer wearing a noun costume.

**No `last_used_at` touch on `PingKey`.** `ApiKey` is touched a handful of times
per deploy; a ping key would be touched on every ping from every job in the
project, serialising a tenant's concurrent pings on one row lock and turning every
ping into a second write. Rotation still needs the drain signal, so write it
coarsely — only when `last_used_at` is older than 5 minutes.

### 3.5 Rate limiting — a live bug in the proposal as originally written

`app/controllers/pings_controller.rb:42` uses `by: -> { params[:ping_token] }`. On
the two-segment route that param is `nil`, and Rails 8.1 builds the bucket key as

```ruby
# actionpack-8.1.3.1/lib/action_controller/metal/rate_limiting.rb:75
cache_key = ["rate-limit", scope, name, by].compact.join(":")
```

`nil` is **compacted away**, not distinguished. So every keyed ping from every
tenant in the process would share one 30/min bucket. Over limit → 429 →
`Client#classify` → `:error` → swallowed → **mass cross-tenant false-`down`
storm**, invisible in tests because the store is a per-process `MemoryStore`.

The per-credential limiter must key on the **resolved monitor**, i.e. the
compound `(ping_key, registration_key)`, never on the first segment alone — a
project with more recurring jobs than the limit would otherwise throttle itself
into a project-wide false outage. Requires a request test asserting two slugs
under one key do not share a bucket.

The per-IP layer keeps its current shape and its opaque-404 over-limit response.

### 3.6 Opaque responses

Unknown ping key, valid key + unknown `registration_key`, and rate-limited all
return the **same opaque 404**. This is the standing convention and it is kept.

The cost is real and should be stated: the gem cannot then distinguish "my key is
wrong" from "my job is not registered yet", which is exactly the distinction
§7 wants. We accept it — differentiating would build an oracle confirming ping-key
validity and let an attacker enumerate low-entropy job names — and recover the
signal on the client side instead (§4.3). Note also that the second segment adds
**no entropy**: for an inspectable app, `recurring.yml` is public. This is one
secret plus a public identifier, not two factors.

### 3.7 Rotation semantics

`Monitors::PingTokensController` and its API twin both promise the old URL stops
working *immediately*, and the UI confirm dialog says so verbatim. With both forms
live, rotating a gem monitor's `ping_token` leaves its keyed URL fully functional.
That is a broken promise in a security control.

Fix in copy, not behaviour: the rotate confirmation must say the monitor remains
reachable via the project ping key, and the ping-key section must be where you go
to revoke that. Rolling the project key from a per-monitor rotate would take every
other monitor in the project down with it.

### 3.8 UI

Mirrors the API-key surface exactly: `Projects::PingKeysController` (`create`
re-renders `projects/show` with the shown-once modal, `destroy` revokes, both
scoped through `current_user.projects`), `app/views/projects/_ping_keys.html.erb`,
and `@ping_keys` loaded in `ProjectShowData` alongside `@api_keys` — that concern
exists precisely so `show` and the issuance action cannot drift.

`_generated_modal.html.erb` hardcodes "API key" copy at lines 11-19
(`aria-label`, `data-testid="api-key-modal"`, `label:`). Parameterise via locals
rather than forking it.

`app/views/monitors/_ping_setup.html.erb` gains the template form (§2.2) for
gem-sourced monitors, keeping the literal token URL for manual ones.

## 4 · Gem design

### 4.1 Added

- `Configuration#ping_key`, defaulting to `ENV["STABLEMATE_PING_KEY"]` — same
  env-first pattern as `endpoint` (`configuration.rb:53`), so the operator's
  migration collapses from four manual steps to two.
- `Client#ping(registration_key)` / `#report_failure(registration_key, message:)`
  build their own URL. `ERB::Util.url_encode` on the key.
- A boot gate + log line when `ping_key` is absent (§4.4).

### 4.2 The key set comes from `tuples`, not `class_to_keys`

This is the substantive change beyond deleting the cache, and it fixes a latent
bug rather than creating one.

`resolve_keys` currently falls back to the job class name **only if a URL is
cached for it** — using the cache as a server-authoritative allow-list. Delete the
cache and a URL is derivable for *every* string, so the gem would ping
`/ping/KEY/<AnyJobClass>` on every successful perform of every job class:
`MailDeliveryJob`, `AnalyzeJob`, every ad-hoc `perform_later`. Thousands a minute
into an endpoint bounded at 300/min.

The cache is also doing **undocumented containment**. `class_to_keys`
(`solid_queue_recurring.rb:98-107`) skips only non-Hash entries and blank
`class:`. `tuples` skips much more: no `schedule:`, command-only, and unsizable
schedules. A task like `{class: NeverJob, schedule: "0 0 30 2 *"}` is in
`class_to_keys` but not `tuples`, so it is never registered, has no cached URL,
and is silently dropped at `dispatch:258`. The same is true of keys the server
returned under `skipped`.

So: **build the subscriber's pingable key set from `registrar.tuples`.** "Can I
size this schedule?" becomes an explicit ping gate instead of an emergent
property of a cache miss. `test_unmapped_perform_does_not_ping`
(`subscriber_test.rb:114`) is the invariant this must keep green.

### 4.3 `:stale` is repurposed, not deleted

Under the new scheme a 404 means the ping key is wrong, or no monitor exists for
that key. Neither is fixable by refreshing URLs — but both are exactly the failure
class this redesign exists to make loud, and the 404 is the **only** signal the
gem will ever get. Collapsing `classify` to `:ok`/`:error` would merge "your
credential is wrong" into the same bucket as "the server 500'd", which is
transient and correctly ignored.

Keep the three-way split, rename the third state `:rejected`, and change the
remedy: log **once per key** (not per ping — the current line fires on every
ping, which is the opposite of what an operator needs) with text that names the
two real causes rather than the now-impossible "token rotated?".

Add `Stablemate.health` — `last_sync_error`, `last_successful_ping_at`,
`rejected_keys` — so "are my pings landing?" is answerable from a console or a
health check. Nothing about deriving a URL makes anything observable; this has to
be built deliberately.

### 4.4 Missing `ping_key`: loud where loud is safe

Neither hard-fail nor silent fallback.

**Do not raise at boot.** It inverts the gem's one non-negotiable invariant
(`railtie.rb:11-12`, enforced by the rescue at `:73`): monitoring must never break
the host. A raise in `after_initialize` takes down every Puma worker in a rolling
deploy of a customer's *revenue* app because their *monitoring* config is stale.

**Do not fall back to fetch-and-cache.** It keeps the bug, keeps the code we are
deleting, and guarantees nobody migrates.

Instead: `rails stablemate:sync` — run by hand or from a deploy script, where a
non-zero exit is a feature — `abort`s with the remediation. Boot logs at **ERROR**
(not `log_warn`, the level everything else uses, where it would be invisible) and
skips Layer 1 with no fallback retained:

```
[stablemate] no ping_key configured — pings are DISABLED and every monitor in
this project will alert as DOWN within one interval + grace. Add
`c.ping_key = Rails.application.credentials.dig(:stablemate, :ping_key)` to
config/initializers/stablemate.rb (or set STABLEMATE_PING_KEY). Find it at
<endpoint>/projects → your project → Ping key. Registration still works without it.
```

Consequence, exact fix, where to get it, what still works.

### 4.5 `register_on_boot = false` survives, with a better meaning

The two were bundled in the original proposal but are separable. `class_to_keys`
comes from the registrar, which reads `recurring.yml` locally and needs no network
and no API key. So:

- `true` → `registration.sync!` only (unchanged).
- `false` → **nothing at boot at all** except attaching the subscriber. Layer 1
  keeps working for every declared task, because the URL is computed.

Strictly better than today, where the flag traded an upsert for a *different*
boot-time network dependency on the same fragile path.

### 4.6 `Registration#sync!`'s return contract

`sync!` returns `Stablemate.ping_urls`, and `stablemate.rake:6-13` does
`cache = Stablemate.sync!; puts "synced #{cache.size} monitor(s)"`. With no cache
it needs a new success value (the registered count from the response). Watch the
`tuples.empty?` early return at `registration.rb:24`: it returns a truthy `{}` so
the task prints "synced 0", not "sync failed". A nil-returning replacement
silently flips that message.

## 5 · Sequencing

**There is no migration to manage.** The gem's only consumer is a side project
the maintainer controls, so it is updated in the same pass. Server and gem ship
together; a broken intermediate state costs one redeploy of an app we own.

This removes what would otherwise be the most expensive part of the change: no
version-negotiation header, no bake period to prove the fetch-and-cache path
unused before deleting it, no dual-mode gem, no deprecation window, no
compatibility matrix. `VERSION` goes to `0.2.0` because the public API changes,
not because anything needs to detect it.

Two things that look like migration concerns but are **not**, and therefore stay:

- **The token URL form is kept** — for the manual-monitor population, not for
  back-compat. See §7.5.
- **The ping-key `last4` cross-check** (§7.2) — it catches a permanent failure
  mode, not a transitional one.

The only sequencing that survives is the trivial kind: apply the server migration
before pointing a gem at the new route.

Still worth running once against production before the route ships, since
`registration_key` is about to become a URL path segment:

```sql
SELECT id, project_id, registration_key FROM monitors
WHERE registration_key ~ '[^A-Za-z0-9_.\-]';
```

Any hit is a monitor whose keyed URL will not round-trip. With the §3.2 route
constraint in place, only `/` is genuinely fatal.

## 6 · Public API removed

`Stablemate.ping_urls`, `.merge_ping_urls` and `Subscriber#initialize(ping_urls:)`
are documented public API for hand-wired hosts. Pre-1.0 and no third-party
consumers, so they go without ceremony.

`gem/README.md`'s "Manual fallback" section (§77-82) is deleted. Its documented
entry point — a hand-created monitor whose `registration_key` is a job class name
— is **already unreachable**: `MonitorsController#monitor_params` permits only
`name`, `expected_interval_seconds`, `grace_period_seconds`, and
`Project::MonitorSync` is the column's only writer. It is a documented feature
that does not work. Anyone who wants it gets explicit config instead.

## 7 · What this does *not* fix

### 7.1 Alerts still point at the wrong system

Wrong ping key, DNS failure, egress firewall, TLS interception, a 429 — in every
case the server sees silence and `MonitorMailer#down` says the job "missed its
check-in". **The redesign changes which URL is silent, not what silence means.**

This is the actual harm from the incident and it is being handled as a separate,
parallel change. Three signals, in cost order:

- **`api_keys.last_used_at`** — already written on every sync, never read. "Key
  used 3 minutes ago, monitors silent for an hour" is a *positive,
  false-positive-free* claim: the app is up and reaching us, the pings
  specifically are not landing. Works at one monitor. Strongest available answer.
- **Never-pinged alerting.** `detectable` is `where(status: "up")`, so a `pending`
  monitor is invisible to detection **forever** — registered-but-never-pinged
  produces zero alerts, indefinitely. Threshold must be interval-relative, it must
  fire once, and it must be distinct copy linking to setup docs.
- **Project silence.** Not "all monitors are down" — they go overdue in interval
  order, so that fires at the *slowest* monitor's cadence. The right predicate is
  `MAX(last_ping_at)` across live monitors older than `MIN(interval + grace)`.
  Needs a project-scoped incident identity (`incidents.monitor_id` is `NOT NULL`)
  and is vacuous at one monitor.

Alert copy must **state the observation, never the diagnosis** — "No monitor in
project Foo has reported since 14:02" is true whether the cause is a firewall, a
crash-looping worker, or a scale-to-zero, and sends the operator to the right
system in all three. "Your network is blocked" is a new way to be wrong.

### 7.2 A second, independently-wrong secret

Nothing forces `api_key` and `ping_key` to name the same project. Paste project
A's API key and project B's ping key: syncs create monitors in A, pings land in B,
A's monitors go permanently down, and every symptom reads as "your job is down".
This is a **new** class of misconfiguration, structurally impossible today — and
it is permanent, not transitional, so it needs a permanent guard.

Mitigation, shipped with the gem rather than after it: sync returns the project's
ping-key `last4` (no escalation — a bearer key already reads every `ping_url` in
that project) and the gem logs a loud mismatch at boot. Combined with §4.3's
once-per-key `:rejected` logging, that converts "wrong key, silent until
`interval + grace` elapses" — ~27 hours for a daily job — into one line at deploy.
Both halves are load-bearing: §4.3 catches a key that is wrong everywhere, this
catches a key that is valid but points somewhere else.

### 7.3 Blast radius

A leaked ping key forges heartbeats **and** `status=1` failure reports for every
monitor in the project, versus one monitor today. And a forged ping on a `down`
monitor does not merely suppress the alert — `CheckIn#recover` resolves the
incident and emails a **false all-clear** during a real outage.

This is the sharpest criticism of the design and it is accepted knowingly, bounded
by: digest-only storage, env-var distribution rather than crontab literals (§2.2),
independent rotation with an overlap window (§3.1), and no create capability
(§2.2). The per-monitor token stays available for anyone who wants the tighter
scope.

### 7.4 The railtie's blanket rescue

§1's sibling bug is untouched by any of this and needs the same treatment: narrow
the rescue so a malformed `recurring.yml` cannot silently leave the subscriber
unattached for the process lifetime, and surface it through `Stablemate.health`.

### 7.5 "One interface" is not reached — and this is not a back-compat concession

With no migration to manage, the obvious move is to collapse to a single URL form
and delete `ping_token`, `rotate_ping_token!` and both rotate controllers. That
was considered and **rejected on product grounds**, so it does not become
available later either:

- UI-created monitors have no `registration_key`. Reaching one form means making
  it UI-settable and format-validated, which re-opens `projects.md` §13-S3 —
  slugs were dropped from V1 because name-derived ones collide within a project
  and go blank on non-ASCII names.
- **The ping key is shown-once (§2.2), so the dashboard could no longer display a
  working URL at all** — only a `$STABLEMATE_PING_KEY` template. "Create a monitor
  in the UI, copy the URL, paste it into a bash script" is a core onboarding path
  and it needs an opaque, complete, copy-pasteable string. Making the ping key
  displayable to fix this would undo §2.2 and hand back the rotation hazard.
- It would delete the only narrowly-scoped ping credential the product has. Per
  §7.3 the project key's blast radius is the design's sharpest cost; the
  per-monitor token is what bounds it for anyone who wants that.

So this is **two credentials for two disjoint populations** — gem-registered
monitors (slug-addressable, config-as-code) and hand-wired ones (token-only,
copy-paste) — and it is Healthchecks' shape for the same reason. Document it as
"one interface per population" rather than pretending at convergence, and do not
carry it as debt.

## 8 · Test plan

Beyond unit and request coverage, the non-negotiable pieces:

- **`[system]`** Generate a ping key from the project page → shown once → masked
  in the list → revoke. Mirrors `test/system/api_keys_test.rb`.
- **`[request]`** Cross-tenant: the same `registration_key` in two projects, pinged
  with project A's key, must never touch project B's monitor (§3.3).
- **`[request]`** Rate limiting: two different `registration_key`s under one ping
  key do **not** share a bucket (§3.5).
- **`[request]`** Route: `/ping/KEY/reports.daily` reaches `registration_key ==
  "reports.daily"` (§3.2).
- **`[request]`** Opaque 404 parity: unknown key, valid key + unknown slug, and
  over-limit are indistinguishable (§3.6).
- **`[gem]`** `test_unmapped_perform_does_not_ping` stays green under the
  `tuples`-derived key set (§4.2).
- **`[gem]`** Boot with no `ping_key`: subscriber attached, no pings, one ERROR
  line (§4.4).
- **`[gem]`** A task in `class_to_keys` but not `tuples` never pings (§4.2) — the
  containment the cache was doing accidentally.
