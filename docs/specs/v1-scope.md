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
| Decision #4, *"Gem ping reliability — fire-and-forget, errors swallowed"* | **Amended.** Errors are no longer swallowed: a `401` is logged once and a `404` once per task name (§6.5). "Never blocks the job" and "a transient outage is absorbed by the grace period" both survive intact. |
| Decision #6, *"`registration_key` = the recurring.yml task key… the registrar writes it"* | **Amended.** It stops being an internal idempotency key and becomes the monitor's **public address**. A backfill becomes a second writer, and it becomes character-set sensitive. |
| Decision #3, *"No gate on monitor creation"* | **Narrowed.** Survives only as a statement about `bin/rails stablemate:sync`. |
| §2 Security defaults, the whole `ping_token` bullet | **Void.** Every clause — plaintext by design, the dashboard showing it, the API re-serving it, the uninformative 404, per-token rate limiting, rotation — describes surfaces this removes. |
| §3 Data model, `Monitor` | `ping_token` and its unique index are deleted; `source` becomes constant (§3.3). |
| §3 Data model, table set | **Gains `PingKey`** — `project_id`, `name`, `token_digest` (unique), `token_last4`, `last_used_at`, timestamps. A project may hold more than one, so rotation can overlap (§4). |
| §2 Security defaults, the `ApiKey` bullet | **Widened**, not replaced. The same handling — hashed, constant-time compared, shown once, uninformative `401` — now covers both credentials, with the addition that the API key is no longer the credential on the check-in path (§4). |

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
pretend they are all incident fixes.

Once addresses are local, a failed registration degrades from *"all monitoring
silently dead until restart"* to *"a schedule change wasn't picked up this
deploy."* The two railtie defects below are untouched by it, and are handled in
§6.5 and §9.2.

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
| The startup wiring and the read-only fetch (`register_on_boot` stays, as a no-op — §11) | 8 |

~100 lines of the 646 non-comment lines in `gem/lib` — but the count understates
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
| `Monitor::Transfer`, `Monitors::ProjectsController`, the manual branch of `_move.html.erb` (§11) | Its first line is `return … unless @monitor.manual?` |
| `awaiting_setup?` and the branch it drives | `manual? && !ever_pinged? && !suspended?` |
| The provenance chip, `from_gem?`, `manual?`, `source` | Every monitor has one provenance |

Keep the rest of `_move.html.erb`, described by structure rather than by line
range. The heading and the "In &lt;project&gt;" link *above* the branch are the only
place the detail page shows which project a monitor belongs to, and the closing
`</div>` *below* it belongs to that block. What goes is the manual arm: the
`if monitor.manual?` line, its body, the `else` and the `end` — leaving the
non-manual arm's markup in place, unwrapped. Taking a literal line range instead
strands the `else` or drops the closing tag.

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
`monitor_mailer.rb:22`, `:29` and `:42` interpolate the monitor name straight into
all three subjects:

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
| enumerate every monitor and task name | in bulk, no — but see §5.4 | **yes, one request** |
| rewrite name / interval / grace everywhere | no | **yes** |
| emit a "recovered" email | yes | no |
| write ping-event rows | yes | no |

The ping key's exclusives are narrower, but **not transient, and an earlier draft
of this section was wrong to say so.** A forged success on a monitor that is down
runs `CheckIn#recover`, which calls `Incident#resolve!` — and that begins
`return if resolved_at.present?`, so a later genuine recovery **cannot correct
it**. The result is a permanently wrong `resolved_at`, permanently overstated
uptime, and a "recovered" email for a job that never recovered. A forged failure
likewise opens an `Incident` carrying attacker text, which the data model keeps
deliberately so it outlives ping pruning. And `first_ping_at ||= received_at` is
documented as never moving afterwards.

This does not weaken the case for the split — the API key holds every capability
the ping key does, plus enumeration and durable rewrites. It does mean §9.3's
investigability work is under-scoped.

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

**Rotation needs more than one live key**, which is why this is a table rather
than a column on `projects`. The procedure is: issue a second key, deploy it,
watch the first key's `last_used_at` stop moving, revoke it. Because you add
before you remove, nothing breaks in between — and that is also what makes
shown-once affordable, since a lost key has a cheap remedy. §9.4's guard must
account for the window where two are live.

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
response shape, bearer-token extraction, and — the one an implementer will miss —
**the rate-limit responder**. Duplicate them deliberately and keep the shapes
identical to `/api/v1`.

That last one is the same class of bug as the `rescue_from` below, and it is
reached by *omitting* code rather than writing it. `Api::V1::BaseController:48`
holds `RATE_LIMITED = -> { render json: { error: "rate_limited" }, status:
:too_many_requests }`, which is what makes §5.4's `429` row true; a controller
that does not inherit `BaseController` does not have it. §5.3 specifies `by:`, the
two ceilings and the store but no `with:`, and **Rails 8.1's default `with:` is
`-> { raise TooManyRequests }`, not a render** — verified at
`actionpack-8.1.3.1/lib/action_controller/metal/rate_limiting.rb:66`. An unhandled
raise leaves the controller entirely and is dressed by `ActionDispatch::ShowExceptions`
→ `PublicExceptions`, which answers by *request format*: a JSON request gets
`{"status":429,"error":"Too Many Requests"}` — right status, wrong body — and a
form-encoded request with no `Accept` header falls to `render_html`, finds no
`public/429.html`, and returns **`429 text/html` with an empty body** (verified;
`show_exceptions.rb:83-86`). §6.4 sends the check-in form-encoded, so that second
branch is the one the gem actually hits. Give this controller its own copy of the
lambda.

It resolves the project from the key and reaches the monitor only through it:

```ruby
monitor = current_project.monitors.find_by(registration_key: params[:registration_key])
return render_not_found unless monitor
```

Use `find_by` and an explicit guard, not `find_by!`. The contract below promises
`404 {"error": "not_found"}`, and a bang method raises `RecordNotFound` — which,
with no inherited `rescue_from`, is an HTML page, not that.

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

**It needs its own `rescue_from`, and this is a correctness bug if omitted.**
`Api::V1::BaseController` has one; this controller cannot inherit it. Without it,
an `ActionController::API` controller answers a full HTML Rails error page —
measured: a monitor with a NULL `expected_interval_seconds` (the column is
nullable) reaches `save!` inside `check_in!` and returns **422 with
`text/html`**. The gem classifies 422 as transient, absorbs it in the grace
period, and the monitor then goes down with an email saying it *missed its
check-in* — §9.1's exact complaint, manufactured by an unhandled exception.
Mandate `rescue_from` for at least `RecordInvalid` and `RecordNotFound`,
rendering JSON.

**But be clear about what that does and does not fix.** It corrects the content
type; on its own it would not stop the misleading alert, because the harm comes
from the *status* — an absorbing classifier treats a JSON 422 exactly as it
treated an HTML one. That is why §6.5 makes an unexpected `4xx` loud rather than
transient. Both halves are needed, and neither substitutes for the other.

**Name the whole response contract**, since none of it can be inherited:

| Case | Response |
|---|---|
| success | `200 {"ok": true}` |
| missing / unknown / revoked key | `401 {"error": "unauthorized"}` |
| valid key, unknown task | `404 {"error": "not_found"}` |
| over either rate limit | `429 {"error": "rate_limited"}` |
| unhandled | JSON, never HTML |

Do **not** carry over the old endpoint's opaque-404 throttle handler. It existed
because 200-versus-404 was the token oracle; now every auth failure is an
identical 401, so a 429 discloses nothing — and a fake 404 would send the gem
down the "not registered" branch instead of the transient one.

Two smaller omissions: `source_ip` comes from `request.remote_ip`, and its meaning
now depends on `trusted_proxies` because the endpoint sits behind kamal-proxy
rather than being public — which matters because §9.3 proposes making leaks
investigable from that column. And the request body may be form-encoded or JSON;
pick one and state it. Path parameters win over body parameters, so a body-supplied
`registration_key` cannot override the path — that is worth a test rather than
luck.

### 5.3 Rate limiting

Two layers, and **the order matters in the opposite direction to the obvious
one.** Declare **per-monitor first, then per-IP.**

Each layer increments its own counter unconditionally, but the over-limit
responder **halts the filter chain** — so the layer that fires first is the only
one that charges.

Be precise about *why* it halts, because it is the responder's own doing and not
something `rate_limit` arranges. `rate_limiting` calls `with:` and returns
(`rate_limiting.rb:72-90`); nothing after that stops the request. Rails 8.1's
default `with:` halts by raising `TooManyRequests`; this app's `RATE_LIMITED`
halts by rendering. **A `with:` that neither renders nor raises does not halt** —
a logging-only lambda would let the request through *while over the limit*, and
charge both counters on the way. Since §5.2 requires writing a custom `with:`
here, that is a reachable way to silently disable both layers, and the §12 test
that asserts a `429` is what catches it. Put per-IP first and a runaway task's rejections
are charged to the shared host-wide bucket; put per-monitor first and they stop
at the runaway's own bucket.

Measured, one runaway task and one healthy task under the same key: per-monitor
first, the healthy task got 200 and the per-IP counter reached 4; per-IP first,
the healthy task got 429 and the per-IP counter reached 11.

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
by: -> {
  credential = Digest::SHA256.hexdigest(request.authorization.to_s.presence || request.remote_ip)
  "#{credential}|#{Digest::SHA256.hexdigest(params[:registration_key].to_s)}"
}
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

**The numbers, stated rather than implied:** per-monitor 30/minute, per-IP
300/minute, both in a dedicated `ActiveSupport::Cache::MemoryStore` — the test
environment uses `null_store`, so a shared store silently disables both layers in
tests. Measured at these values: 40 tasks checking in twice a minute under one key
pass unthrottled; the per-monitor bound, not the per-IP one, is what a
small-job-count app meets first.

**Two things a Kamal operator needs to know.** The app and its job workers sit
behind one proxy, so **the whole host shares a single per-IP bucket** — 300/minute
is the machine's total check-in budget, not one process's.

And **behind Cloudflare, `request.remote_ip` is a Cloudflare edge address** unless
`STABLEMATE_BEHIND_CLOUDFLARE` is set so the trusted-proxy list is configured. If
it is not, the per-IP layer — the *only* pre-authentication bound — collapses to a
handful of buckets shared across every tenant, and one noisy client throttles
everyone. Setting it is a prerequisite of this design, not an optimisation.

The per-monitor ceiling also bounds the alert-flood in §9.3. Put it on the controller, alongside
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

We accept it, because §6.5 needs the `404` to say "run `stablemate:sync`" and
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
`skipped` reasons, since §12 requires printing them. Two traps: `{}` is truthy, so
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

**Whichever file computes this must `require "set"`** — the same trap as §6.4's
`require "erb"`, one file over, and with a worse ending. The gemspec sets
`required_ruby_version = ">= 3.1"` and dev-depends on `activesupport >= 7.0`, so a
Rails 7 host on Ruby 3.1 is a supported target — and **`Set` is only autoloaded
from Ruby 3.2**. Measured across the three interpreters installed here: `[1,2].to_set`
raises `NoMethodError` on 3.1.6 and works on 3.2.6 and 3.3.6.

The ending is worse than §6.4's because §6.5 puts this call inside the railtie's
`after_initialize`, whose `rescue StandardError` catches `NoMethodError` — so on
Ruby 3.1 the gem logs `boot wiring skipped`, never attaches the subscriber, and
**every check-in is disabled**. That is the incident this document exists to fix,
reproduced on the gem's own oldest supported Ruby, differing only in that this
time there is a log line. `execution/subscriber.rb:3` already requires `set`; the
railtie requires only `rails/railtie`, and §6.5 moves the map-building there.

Treat this as the general rule, not one more special case: **the gem's floor is
Ruby 3.1, so no stdlib that 3.2+ merely autoloads may be used unrequired.**

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

**Two shipped tests die with it** and must be deleted rather than repaired:
`subscriber_test.rb:147` (`test_manual_fallback_pings_by_job_class_name`) and
`:163` (`test_subscribes_to_real_active_job_notifications`, which uses the manual
fallback as its vehicle and needs a different one).

**Say where the union happens.** "May-register" is `recurring.yml` tasks plus
`c.monitors`, but the intersection snippet reads `registrar.tuples`. If
`c.monitors` is folded into the registrar — the natural place — then
`registrar.tuples` is contaminated and the snippet's own allow-list is wrong.
**The registrar stays `recurring.yml`-only; `Registration#sync!` merges the two.**

**Add a fixture.** On every shipped fixture the intersection is a no-op —
`reportable == class_to_keys` exactly, because none of them has a task with a
`class:` and an underivable schedule. §12 requires a test for precisely that case,
so it needs a fifth fixture to exist at all.

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

### 6.4 How a check-in is sent

§6 previously specified only the edges — which tasks may report, when the command
exits non-zero, where it runs, what gets logged — and never the middle. This is
the middle.

`Client#ping` and `#report_failure` stop taking a URL and take a task key:

```ruby
def ping(registration_key)
  classify(post_check_in(registration_key, {}))
end

def report_failure(registration_key, message:)
  classify(post_check_in(registration_key,
                         status: 1, message: message.to_s[0, ERROR_MESSAGE_LIMIT]))
end

# Client has no post_form today; report_failure builds its own request inline
# (client.rb:78-81). Extract that shape rather than inventing a new helper.
def post_check_in(registration_key, params)
  uri = check_in_uri(registration_key)
  http_for(uri).post(uri.request_uri,
                     URI.encode_www_form(params),
                     "Content-Type" => "application/x-www-form-urlencoded",
                     "Authorization" => "Bearer #{config.ping_key}")
end

def check_in_uri(registration_key)
  URI.join(config.endpoint, "/api/v1/monitors/#{ERB::Util.url_encode(registration_key)}/pings")
end
```

`ping` and `report_failure` keep their existing `rescue StandardError` — it is
what makes the whole path fire-and-forget, and the encoder note below depends on
it being there.

Three things to pin down, because each has a wrong-looking-right answer:

- **The encoder is `ERB::Util.url_encode`, and `client.rb` must `require "erb"`.**
  It requires only `net/http`, `json` and `uri` today, and the gem supports a
  plain-Ruby host. Without the require, `ERB` is an uninitialized constant —
  `NameError`, which is a `StandardError`, which `Client#ping`'s rescue swallows
  and reports as `:error`, which §6.5 classifies as transient. Every check-in
  would be dropped with no `401` or `404` logged, and the monitor would go down
  saying it missed its check-in. Verified: the bare require set raises. `CGI.escape` and
  `URI.encode_www_form_component` turn a space into `+`, which decodes as a
  literal `+` in a path segment — so a task named `"my task"` would 404 forever
  while §5.1's route table passed, since none of its examples contain a space.
- **The body stays form-encoded**, as `report_failure` already sends it, so
  `status` and `message` keep working unchanged.
- **Response classification lives in `Client#classify`**, not in
  `Subscriber#deliver`. `classify` already owns this split; the change is which
  states it distinguishes — §6.5 defines four. `Subscriber#deliver` keeps only "act on what the client
  said", and loses `trigger_resync` entirely.

`Subscriber` also sheds more than the address lookup: the `ping_urls:`, `resync:`
and `resync_interval:` keywords, `@resync_mutex`, `@last_resync_at`, `url_for`,
and the `:stale` branch of `deliver`. `dispatch` stops resolving a URL and passes
the key through.

### 6.5 Reading the response, and boot

- `401` — the key is wrong or revoked. Log **once**, loudly.
- `404` — this task is not registered. Log **once per task name**, naming the
  remedy: run `bin/rails stablemate:sync`.
- Any other `4xx` — the server is refusing this check-in for a reason that will
  not resolve itself. Log **once per task name**, as for a `404`. Absorbing it is
  how a server-side fault reaches the user as their job missing a check-in (§5.2).
- `5xx`, a timeout, or a transport failure — transient, absorbed by the grace
  period.

**Route these through `Rails.logger` when Rails is defined.** The gem's logger is
`config.logger || Logger.new($stderr)`, and nothing in the gem ever assigns
`Rails.logger` — so the default is the stderr channel the original boot-sync
warning went to, which is why nobody saw it. Since boot now does nothing else,
this line is the *only* signal a misconfigured deploy produces; leaving it on
stderr bypasses the host's formatter, level and tags.

So `Stablemate.logger` must prefer `Rails.logger` when Rails is loaded, or
`Configuration#logger` must default to it. The snippets below write
`Stablemate.logger.error` assuming that change lands first — without it they are
the very channel this paragraph condemns. There is no `log_error` helper —
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

**On logging at error level.** There is no `log_error` helper — `Logging` provides
only `log_warn`/`log_info` — and adding one does not by itself make
`Stablemate.log_error` work: `Stablemate.singleton_class.include?(Logging)` is
`false`, so the module has no such method to call. Either add `log_error` to
`Logging` and invoke it from an object that includes the module, or call
`Stablemate.logger.error` directly with an explicit `[stablemate]` prefix, as the
snippet above does — but only once `Stablemate.logger` prefers `Rails.logger`, per
the paragraph above. The railtie already uses the latter shape.

`handle_event` also needs a rescue. It is the only public handler without one —
`handle_retry` and `handle_discard` both have one — and an exception raised in a
`perform.active_job` subscriber propagates into `perform_now`, **failing the
host's job**. The gem's "nothing may propagate into the host" guarantee is
currently enforced only on the dispatch side.

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
become: create a project, issue **both** an API key and a ping key, and print the
`stablemate:sync` invocation alongside a ready-to-paste check-in command. Issuing
only the API key would seed a skeleton that can register a monitor and never check
one in — the permanently-grey-row failure this same section warns about.

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
| **Server subtotal** | **~855** |
| Gem deletions (§3.2) | ~100 |
| **Tests broken by UI removal** | ~393 across 15 files, 4 deleted whole |
| **Tests broken by the check-in move** | ~647 across 9 files, 3 deleted whole |
| **Gem suite** | 48 of 94 tests error under the deletions |

Two things the totals hide:

**Capybara cannot set an `Authorization` header.** Eight call sites across
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
monitor is addressable. **The algorithm is `manual-<id>`; see §8.1 for why
deriving from the name is unsafe.**

Two guards it still needs. Check for a collision before assigning — a
`recurring.yml` task key may literally be `manual-7`, and the partial unique index
would otherwise raise `RecordNotUnique`, roll back the wrapping transaction and
fail the deploy. And run the backfill and any later `NOT NULL` in one migration,
since the constraint cannot be added while nulls remain.

### 8.1 Cutover: this must ship in three phases

**Shipping all of this in one deploy takes every healthy monitor dark and emails a
false outage for each one.** The server and the gem are separate repositories with
separate deploys, and the ping key can only be issued from the server interface
*after* the server deploy — so there is necessarily a window where a new server
faces an old gem. Traced end to end, that window is not benign:

1. The old gem's cached address is `…/ping/<token>`; the route is gone → 404.
2. `Client#classify` reads 404 as "address rejected" and triggers a re-sync.
3. The re-sync hits `SyncsController#create`, which calls `ping_url_for(monitor)`
   → `ping_url(monitor.ping_token)`. Helper and column are both deleted → **500**.
4. `sync!` rescues, returns nil, and the dead addresses stay cached. Re-sync is
   throttled to once a minute.
5. Every check-in is then dropped at `subscriber.rb:258` — `return unless url` —
   **the exact line §2 quotes as the incident this document exists to fix.**
6. `DetectMissedPingsJob` sweeps and `flag_missed!` opens an incident and sends a
   `down` email per monitor.

The casualties are precisely the healthy ones: `detectable` is
`where(status: "up")`, so paused, suspended, pending and already-down monitors are
untouched. For a 15-minute job the grace is `max(interval × 0.15, 5.minutes)` =
5 minutes, so the whole window to beat is 20 minutes — server deploy, copy a ping
key from the UI, edit host credentials, redeploy the host. That does not fit.

**Three phases, and the split is free** — the new route does not collide with
`match "/ping/:ping_token"`, and `ping_keys` can be created while `ping_token`
still exists:

- **Phase 1 — additive, server only.** Add `PingKey`, the new endpoint, the route,
  the rate limiters, the `registration_key` backfill. Change nothing else. The old
  ping endpoint, `ping_token`, the rotation controllers and `ping_url` in the sync
  response all keep working.

  **The backfill is the one part of phase 1 that is not inert, and it needs a
  namespace.** `registration_key` is not just an address — it is the upsert
  identity in `Project::MonitorSync`. Derive a backfilled key from the monitor's
  name and a hand-created monitor called `daily_digest` acquires the key
  `daily_digest`; the next `stablemate:sync` then **adopts it** instead of
  creating its own. Reproduced: what is two monitors today becomes one, fed by
  both a shell cron and a Rails job — so killing the shell script leaves the
  monitor green, which is exactly the failure §6.3 forbids elsewhere. It also
  inherits the manual interval, because `gem_may_write?` refuses on a first sync
  where nothing was last sent, so a fifteen-minute job silently keeps an hour-long
  window.

  So **backfill into a namespace the gem does not derive from job names** —
  `manual-<id>` — rather than deriving from the name. A name-derived key is only
  checked against what exists at migration time; this is the collision that
  arrives afterwards, when the gem next syncs. (This narrows the collision to one
  a *human* has to author deliberately — a literal `manual-7` typed into
  `recurring.yml` or `c.monitors` — which is why §8 still guards the migration
  rather than treating the namespace as sufficient.)
- **Phase 2 — the host cuts over.** Issue a ping key, add it to the host's
  credentials, deploy gem `0.2.0`, run `stablemate:sync`, and **verify a real
  check-in has landed** before continuing.
- **Phase 3 — subtractive, server only.** Now delete the ping endpoint,
  `ping_token`, both rotation controllers, `ping_url` from the serializers, and the
  monitor-creation path.

§6.2's care about `pre-deploy` versus `post-deploy` hooks is wasted if this
larger ordering is left implicit.

## 9 · What this does not fix

### 9.1 Alerts still point at the wrong system

A wrong key, DNS failure, blocked egress, a rate limit — in every case the server
sees silence and the email says the job "missed its check-in". Three signals,
cheapest first:

- **The API key already records when it was last used**, on every registration.
  Today the only reader is a "Last used" column in the project view; nothing acts
  on it. *"This app registered within the hour but no monitor has reported for
  longer"* is a positive statement with no false positives. Phrase the threshold
  in hours, not minutes — §5.2 coarsens that write to five-minute granularity.
- **Alert on monitors that have never checked in. This one is IN scope** — see
  §7 for why, §8 for its budget and §12 for its test. It sits here because it
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

§6.5 makes this loud — the rescue now logs — but it does not make it recoverable:
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
# app/mailers/monitor_mailer.rb — all three subjects interpolate the name
subject = "#{monitor.name} reported an error"      # :22
subject = "#{monitor.name} missed its check-in"    # :29
subject: "#{monitor.name} is back up"              # :42
```

`validates :name, presence: true` is the only name validation and the column is an
unbounded `varchar`, so any API key holder can put arbitrary, unbounded text in an
email subject line. The mailer's own comment states the assumption being violated:
*"The subject carries only the monitor name, never the error (headers stay
injection-proof, lock-screen previews clean)."*

**Fix it in the mailer, by truncating what reaches the subject.** That alone
closes it, and it is independent of the credential split. It wants one private
helper used at all three interpolations, not a fix at the two `down` sites — the
`recovered` subject at `:42` is built inline and is the one an implementer reading
only the first code block above would miss.

**Do not simply add a length validation** — an earlier draft said to, and it is
worse than the bug. `CheckIn#check_in!` and `MissedPing#flag_missed!` both `save!`
the whole record, so a validation on `name` gates every check-in and every
down-transition, not just renames. And `ApplicationJob#each_record` rescues only
`RecordNotFound`, so `DetectMissedPingsJob` **aborts on the first over-length
row** — leaving every monitor after it in the sweep, across all tenants, `up` with
no incident and no email, on that run and every subsequent one. Reproduced: one
long-named monitor left a second, genuinely overdue monitor un-flagged.

That turns one API-key request into a fleet-wide alerting outage, which is a worse
version of the capability §4 is measuring. If a validation is wanted as well, it
needs `on: :create`/`on: :update` scoping plus a truncating backfill — **and**
`each_record` must rescue `RecordInvalid` per record and log, which is a
pre-existing fragility this would be the first thing to expose.

Everything else in the content path checks out: `error` is truncated
unconditionally in the model layer, every render escapes, and header injection via
the name is Q-encoded by the mail gem.

Worth adding cheaply: `ping_events` records `source_ip` but nothing about which
key was used. A nullable key reference makes a suspected leak investigable — and
per §4 it must reach `incidents` and `notifications` too, since a forged recovery
is permanent and those rows are what outlive ping pruning.

### 9.4 Two credentials that can disagree

Nothing forces the API key and the ping key to name the same project. Use project
A's API key with project B's ping key and registration writes to A while check-ins
go to B; A's monitors go down permanently and every symptom reads "your job is
down". This mistake is impossible with one credential and permanent with two, so
it needs a permanent guard.

Registration returns the last four characters of **every live ping key** for the
project, and **`bin/rails stablemate:sync` warns loudly** when the configured ping
key matches none of them.

**Not at startup.** §3.1 and §6.5 make boot do no network call at all, so a
booting worker has no registration response to compare against. Putting this check
at boot would re-add exactly the startup HTTP call §2 is about. The command is the
only process that holds the response, so the check belongs there. No escalation —
an API key can already list every monitor in its project.

**A set, not a value** — §4's rotation procedure deliberately keeps two keys live
at once, so a guard comparing against a single key would fire a false alarm during
exactly the operation it is meant to support.

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

## 11 · Decisions an implementer would otherwise have to guess

A build-through of this document produced 45 open questions. Most are safely the
implementer's; these are the ones where guessing wrong causes a defect.

**The API surface after the ping token goes.** Three payloads carry `ping_url` but
there are only **two** literal keys to delete: `monitor_json` has one, the sync
response has its own, and `monitor_detail_json` inherits it by `merge`-ing
`monitor_json` rather than declaring it. `ping_url_for` then has no callers and
goes too. There is no URL to serve once the address is derived from the task key.
Keep `registration_key` in those payloads, since it is now the address. `POST /api/v1/monitors/:id/rotate` goes with the token; answer
it **410 Gone**, not 404, so an old client can tell "removed" from "wrong id".

**`register_on_boot` becomes a deprecated no-op — do not remove the accessor.**
An earlier draft of this section said the opposite and had the reasoning exactly
backwards. It is documented public configuration in `gem/README.md`'s options
table and in the sample initializer in `docs/integrating.md`, so hosts have it in
`config/initializers/stablemate.rb`. Deleting `attr_accessor :register_on_boot`
means `c.register_on_boot = false` raises `NoMethodError` *inside the host's
initializer* — **the host app does not boot.** Verified. Keep the accessor, ignore
the value, and log once that it no longer does anything.

`Stablemate.ping_urls` is the opposite case. It is *not* documented
anywhere a host copies from, so it can simply go. If it is kept for safety, keep
`EMPTY_PING_URLS` with it: the body is `@ping_urls || EMPTY_PING_URLS`, and with
the writers gone `@ping_urls` is always nil, so retaining the method while
deleting the constant raises `NameError` on every call — the same crash class as
the paragraph above.

`merge_ping_urls`, `MERGE_LOCK`, `Registration#refresh_ping_urls!` and the cache
line in `reset!` are internal and go outright; §3.2's table implies them without
naming them.

**"Registered but never checked in"** is `pending? && !ever_pinged?`. §3.3 deletes
`awaiting_setup?`, but §7's replacement copy and §9.1's alert both need the
concept, and it must not be quietly reinvented in two places with different
meaning.

**`_move.html.erb` keeps its non-manual branch**, described that way rather than
as line numbers — the literal ranges an earlier draft gave would strand an `else`
and drop a closing tag. Note the retained copy ("Managed by the gem…") becomes the
text *every* monitor shows once every monitor is gem-sourced, so it needs a reread.

**The `PingKey` mirror is exact unless stated otherwise.** Token length and
alphabet, `masked` format, default key name, revoke-by-destroy, indexes and
foreign key: whatever `ApiKey` does. The three deliberate differences are the
`sm_ping_` prefix, no `last_used_at` write on the check-in path beyond the
five-minute coarsening, and **more than one live key per project**, which rotation
requires.

**§9.4's wire field** is `ping_key_last4`, an array of strings, in the sync
response envelope alongside `monitors` and `skipped`.

**The docs that describe the removed endpoint** are not optional follow-up:
`docs/api.md` (the ping endpoint, `ping_url` in two payloads, rotate),
`docs/install.md`'s "Create a monitor and send a ping", `docs/integrating.md`'s
manual-path section and its manual-fallback note, and
`docs/deploy-hetzner-cloudflare.md`'s verification `curl`. Each describes something
that will 404.

**§10 does not block starting.** An earlier draft said to settle the billing
question first. It overstates the dependency: the `suspended` status and its
special cases in the uptime rollup, the live-day stat, the check-in transition and
the cap scope are untouched by anything in §§3–8. The overlap is that both would
edit `docs/specs/README.md`'s data model, which is a merge conflict rather than a
design dependency. Decide §10 when convenient; do not stop for it.

## 12 · Test plan

- **Browser: the monitor lifecycle without creation.** A registered monitor can be
  edited, paused and deleted; the create route is gone.
- **The detection sweep survives one bad record (§9.3).** A monitor that fails
  validation must not stop `DetectMissedPingsJob` flagging the monitors after it.
- **Backfilled keys cannot be adopted by the gem (§8.1).** A hand-created monitor
  named after a `recurring.yml` task must remain a separate monitor after
  `stablemate:sync` runs.
- **Cutover (§8.1).** After phase 1 and before phase 2, a monitor still checking
  in through the old ping-token URL keeps working and does not go overdue. This is
  the test that proves the phases are separable.
- **Backfill collision (§8).** A `recurring.yml` task key that literally equals a
  generated `manual-<id>` must not make the migration raise.
- **Gem on a plain-Ruby host (§6.4).** A check-in with a space in the task name
  succeeds without Rails loaded, which fails if `erb` is not required.
- **Gem on Ruby 3.1 (§6.3).** The listener attaches and a check-in lands on the
  gemspec's oldest supported interpreter. `Set` is not autoloaded before 3.2, and
  the boot rescue converts the resulting `NoMethodError` into a silently
  disabled gem — so this must run on 3.1 in CI, not be argued about. The gem's CI
  has no Ruby matrix today; a test that only ever runs on 3.3 cannot catch it.
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
- **An oversized monitor name cannot reach an email subject** (§9.3) — asserted on
  all three subjects, including `recovered`; truncated in the mailer, *not*
  rejected by a validation, which would abort the sweep.
- **An out-of-range `expected_interval_seconds` in a sync payload is reported as
  skipped, not raised**, and leaves the other entries applied (§9.5).
- **Rate limiting, three ways.** Two task names under one key must not share a
  counter; two keys on one task name must not share one (this is what catches a
  lambda reading post-authentication state, and the first case alone would pass a
  broken implementation); and **one throttled monitor must not consume another
  monitor's budget** — the layer-order bug in §5.3. Plus: an unauthenticated flood
  is bounded. And **assert the over-limit body**, form-encoded as §6.4 sends it —
  `429 {"error": "rate_limited"}`, not the framework default's empty `text/html`
  (§5.2). Asserting only on the status passes a controller with no `with:` at all.
- **Routing.** A dotted task name arrives intact, and a body-supplied
  `registration_key` cannot override the path parameter.
- **Every response is JSON**, including a monitor that fails validation during
  check-in (§5.2). Note this is a hygiene test, not the fix for the misleading
  alert — that is the next one.
- **An unexpected `4xx` is logged, not absorbed** (§5.2, §6.5). A check-in that
  the server refuses for a reason that will not fix itself must not be reported to
  the user as their job missing a check-in.
- **Gem: the URL encoder round-trips.** A task name containing a space must reach
  the server intact, which `CGI.escape` would not achieve (§6.4).
- **Backfill.** Every monitor without a task name gets a distinct, usable,
  slash-free one, and none of them is a name the gem *derives* from a
  `recurring.yml` job class. (A hand-authored literal `manual-7` is still
  possible, which is the separate collision bullet above.)
- **Command.** Exits non-zero on all four register-nothing paths, prints the
  server's reasons, and refuses to run outside its configured environment.
- **Gem: unlisted job classes never report**, and a task with an underivable
  schedule never reports.
- **Gem: a `c.monitors` key matching a host job class name never binds to it.**
- **Gem: boot with no ping key** — one error line, listener not attached, app
  still boots. **With a ping key and no API key** — listener *is* attached and
  check-ins work, since boot no longer needs the API key (§6.5). **With a broken
  `recurring.yml`** — one error line, app still boots.
- **Gem: `401` and `404` handled differently**, each logged once.
