# Ping architecture — authenticated check-ins

Status: **proposed**, not yet built. Replaces two things: the scheme where the gem
fetches its check-in URLs from the server at startup and holds them in memory, and
the public unauthenticated ping endpoint.

---

## Summary

On 1 August 2026 a host app deployed normally. One network call during startup
timed out. From that moment the app stopped reporting to Stablemate entirely, and
kept not reporting until it was restarted. Four healthy jobs were reported as
down. The jobs were fine — the monitoring was broken, and the alerts blamed the
jobs.

The cause is that the gem learns where to send its check-ins by asking the server
at startup, then remembering the answer. If that one call fails it has nothing to
send to, and nothing ever makes it ask again.

**The proposal has three parts.**

*Stop asking.* A monitor is addressed by its task name — the `registration_key` —
which the gem already reads from `recurring.yml`. Nothing is fetched, so there is
nothing to cache and nothing to go stale.

*Authenticate the check-in.* A new credential, the **ping key**, is sent in an
`Authorization` header exactly as the existing API key already is. It can record
check-ins and nothing else.

*Let the interface set a task name.* The monitor form currently cannot write
`registration_key`, which is the one and only reason a hand-created monitor would
be unreachable under the new scheme. One field fixes it.

```
POST /api/v1/monitors/{registration_key}/pings
Authorization: Bearer sm_ping_…
```

That is now the **only** way to record a check-in — the same request whether it
comes from the gem, a shell script, or another language.

**What this deletes.** About 110 lines of the most delicate code in the gem,
including all of its state shared between threads. The per-monitor ping token and
both token-rotation controllers. And the entire public unauthenticated endpoint —
its two rate limiters, its parameter guards, and its deliberately uninformative
error responses. The application is left with **no unauthenticated write endpoint
for check-ins.**

**What this costs.** A ping key covers a whole project rather than a single
monitor, so a leaked one can fake check-ins for every job in that project —
including faking a recovery during a real outage. That is a real reduction from
the per-monitor token and it is accepted knowingly (§6.3). Moving the credential
out of the URL claws back most of the exposure that made it dangerous.

**What this does not fix.** If check-ins stop arriving for any reason, Stablemate
still reports "your job is down" — the misleading alert that made the incident
painful. That is separate work, described in §6.1 and being done in parallel.

> **An earlier draft of this spec also proposed deleting the manual path
> entirely** — no hand-created monitors, gem-only. A pressure-test review killed
> it, correctly. The manual path was never blocked by the credential; it was
> blocked by the missing form field above. Deleting it would have cost the
> `Transfer` operation, the `source` column, the provenance chip,
> `awaiting_setup?`, roughly 300 lines of browser tests, the entire copy-paste
> onboarding path, the form that `uptime-monitor.md` §6 is built on — and
> Stablemate's ability to monitor its own nightly Postgres backup, which
> `runbook.md:41-45` runs as a root shell cron outside Rails. §3.7 is the whole
> of what that section was trying to achieve.

---

## The two credentials

The redesign adds one credential and removes one. Afterwards there are two, and
**neither ever appears in a URL**:

| | What it is for | Scope | Stored as | Sent as |
|---|---|---|---|---|
| **API key**<br>`sm_live_…` | Managing monitors: listing them, registering them from `recurring.yml` | One project | A hash — shown once, never recoverable | `Authorization: Bearer` |
| **Ping key** *(new)*<br>`sm_ping_…` | Recording check-ins, and nothing else | One project | Plain text — displayable, see §3.1 | `Authorization: Bearer` |

The **ping token** — a per-monitor secret in the URL — is removed.

Why a second key rather than reusing the first: the API key can read and rewrite
every monitor you own. The ping key is what gets pasted into a crontab on a
machine that has no business holding anything more powerful. **That justification
depends on the manual path existing** — if check-ins only ever came from the gem,
both credentials would sit in the same credentials file, on the same host, held by
the same process, and the second one would separate nothing from anything. Because
the manual path stays, the ping key goes somewhere the API key does not.

---

## 1 · What actually went wrong

Here is the code that fails, from the gem's job-completion handler:

```ruby
# gem/lib/stablemate/execution/subscriber.rb:256-260
def dispatch(key, label:, &request)
  url = url_for(key)
  return unless url                 # ← gives up here, silently
  @dispatcher.call(-> { deliver(url, label, &request) })
```

The gem does have a repair mechanism: if a check-in comes back rejected, it
re-fetches its addresses. But that only runs *after* a request has been sent, and
a request can only be sent if an address was found. **The repair is behind the
door it is meant to open.** With no addresses nothing is sent, so nothing is
rejected, so nothing is repaired. There is no way out short of restarting the
process.

It is worse under the host's setup, where the job supervisor runs inside the web
server. The supervisor copies its memory to each worker it starts, so one failed
startup call is inherited by all of them.

Three corrections to the original incident write-up:

- **It was not completely silent.** The startup failure logs one line, but to
  standard error rather than the Rails log unless the host configured otherwise.
  The signal existed once, where nobody was looking.
- **There is a second, worse version of the same bug.** The gem's startup code
  wraps everything — reading `recurring.yml`, registering monitors, attaching the
  job listener — in a single catch-all (`railtie.rb:43-75`). If `recurring.yml`
  has a YAML syntax error the listener is never attached at all: no success
  check-ins *and* no failure reports, one warning, no recovery. Deleting the
  address cache does not touch this. §6.4 covers it.
- **And a third gate above both.** `railtie.rb:44` is
  `next unless Stablemate.config.api_key`. Everything below it — including the
  job listener — is skipped when no API key is set. §4.4 and §4.5 both depend on
  moving that gate.

## 2 · The decision

Three changes. Each stands on its own.

### 2.1 Address monitors by task name, not by a fetched URL

The gem already knows the task name — it reads it from `recurring.yml` to register
the monitor in the first place. Using it as the address means nothing is fetched,
nothing is cached, nothing goes stale, and there is no repair mechanism to get
stuck behind.

**Why delete rather than fix.** The ordering bug in §1 is about ten lines to
repair. The reason not to: the rejected-request path had tests and the no-address
path had none, because nobody thought of it. You cannot write a test for a failure
you have not imagined, but you can remove the code where that class of failure
lives.

| Removed from the gem | ~Lines | Why it mattered |
|---|---|---|
| The shared address map and the lock protecting it | 25 | The gem's only state shared between threads |
| The re-fetch mechanism, its throttle, mutex and timer | 25 | An entire recovery protocol |
| The two methods that populate the map | 21 | |
| The "list my monitors" call and the "address rejected" response state | 20 | Exist only to serve the cache |
| The startup wiring tying them together | 8 | |
| The read-only variant of startup registration | — | A second network call during startup |

About 110 lines of 680, but the count understates it: this is most of the genuinely
hard reasoning in the gem — swapping an immutable snapshot under a lock,
guaranteeing readers never block, throttling re-fetches against a clock that
cannot run backwards. The gem's main test file is 583 lines and every single test
has to supply a fake address map.

### 2.2 Put the credential in a header, not the URL

An earlier draft followed Healthchecks.io and put the ping key in the URL path:
`POST /ping/{ping_key}/{registration_key}`. That is the right shape for
Healthchecks, whose clients are `curl` invocations in any language, and it is what
makes their onboarding a single pasted string.

It is still the wrong shape here, and the reason is not that our clients are
different — a shell script uses this endpoint too. It is that a URL-borne
credential is charged four costs a header is not:

- **It is written to logs.** Rails logs request paths verbatim and filters only
  query strings, so a credential in the path lands in every request log, proxy log
  and error report.
- **`GET` becomes dangerous.** A check-in is not a read: it advances the monitor's
  clock and, if the monitor is currently down, resolves the incident and sends a
  "recovered" email. With the credential in a URL, anything that follows a link —
  chat previews, mail providers pre-fetching, antivirus scanners — can fire one.
  This endpoint is `POST` only.
- **It is not a normal REST resource.** Creating a check-in for a monitor is
  `POST …/monitors/{id}/pings`, which is what it now is.
- **Two specific faults never get written** — the rate-limiter fault in §3.5 and
  the URL-parsing fault in §3.2, both of which come from having a credential and a
  task name as adjacent path segments.

The price is one flag: `curl -X POST -H "Authorization: Bearer sm_ping_…"` instead
of `curl <url>`. Worth it, and §3.8 makes the setup card hand you the whole line.

### 2.3 Registration stays a separate call

Healthchecks lets a check-in create the monitor if it does not exist
(`?create=1`). That is genuinely good for them and does not transfer:

- **There is nowhere honest to get the schedule from.** A monitor needs an
  expected interval and a grace period. If the check-in carries them, every
  check-in becomes a settings write and bypasses the logic that stops a redeploy
  overwriting an interval a user tightened by hand. If they come from a default, a
  job that runs daily gets alerted on hourly. Worse: a monitor created this way has
  no record of what the gem last sent, which permanently traps it in the branch of
  that logic that refuses the first update — so the wrong interval sticks.
- **It would throw away the reasons.** Registration returns "we could not register
  this job, and here is why" — over the plan limit, malformed — and the gem logs
  each one. A check-in endpoint returns a status code.
- **It would disable the check that catches two apps sharing one project's
  credentials**, which only runs during registration.
- **Counting monitors correctly needs a per-user lock**, which does not belong on
  the highest-volume endpoint in the system.

So registration keeps its job as the **settings channel** — it has a response body,
and settings need one. A check-in carries a single fact and gets no reply worth
reading. The change that matters is that check-ins no longer *depend* on
registration, so a failed registration is harmless.

## 3 · Server design

### 3.1 The `PingKey` model

**A table, not a column on `projects`.** Safe rotation needs two keys valid at
once, plus a way to tell whether anything is still using the old one. A single
column cannot hold two values. Rotation is then: create a second key, deploy it,
watch the first one's "last used" timestamp stop moving, delete it. Because you add
before you remove, nothing breaks in between.

```
app/models/ping_key.rb              # the model
app/models/ping_key/issuance.rb     # PingKey.issue(project:, name:) -> ping_key
```

Columns: `project_id`, `name`, `token`, `last_used_at`, timestamps. The raw format
is `sm_ping_` followed by 32 random characters — a **different prefix** from
`sm_live_`, so a key pasted into the wrong configuration slot fails immediately
and automated secret scanners can tell them apart.

**Stored in plain text and displayable, unlike the API key.** This reverses an
earlier draft, and the reasoning is the one `docs/specs/README.md` already applies
to the current ping token: the application has to be able to *reconstruct a
working command* for the setup card (§3.8), and a shown-once secret cannot be
reconstructed. Three things make that acceptable here, where it would not be for
the API key:

- It is header-only, so unlike the ping token it never reaches a log.
- Its only capability is recording a check-in. It cannot read, rewrite or delete
  anything.
- Rotation is safe and cheap (above), so a suspected leak has a real remedy rather
  than a scary one.

The cost is honest and worth stating: a database leak yields live ping keys, where
the API key digest yields nothing. That is the trade.

**This must not be a "type" column on the existing `api_keys` table.**
Authentication looks a token up across the whole table. With one table a ping key
would authenticate the management API unless every single lookup remembered to
filter by type — and forgetting is silent and permissive, the worst possible
default in security code. Two tables make the mistake impossible rather than
merely discouraged. (The storage difference above is a second, independent reason
they cannot share a table.)

### 3.2 The route

```ruby
namespace :api do
  namespace :v1 do
    resources :monitors, only: %i[index show]
    post "monitors/:registration_key/pings", to: "monitors/pings#create",
         constraints: { registration_key: %r{[^/]+} }, format: false, as: :monitor_pings
  end
end
```

**Declare it standalone, not nested.** The obvious version — nesting
`resource :pings` inside `resources :monitors, param: :registration_key` — is
wrong in three ways, all verified against this app's router:

- `param: :registration_key` also changes **`show`**, so `GET /api/v1/monitors/42`
  arrives as `registration_key: "42"` while `Api::V1::BaseController#find_monitor`
  still reads `params[:id]`. A silent breaking change to an endpoint this work has
  no business touching.
- Rails prefixes a nested parent's parameter, so the segment is actually
  `:monitor_registration_key`. The constraint, written against `registration_key`,
  names a segment that does not exist.
- Because the constraint never applies, dotted task names break anyway.

**The constraint and `format: false` are both required.** Rails excludes dots from
dynamic URL segments by default and treats a trailing `.foo` as a format. Verified
behaviour with the declaration above:

```
GET  /api/v1/monitors/42                        => show,   id: "42"          (unchanged)
POST /api/v1/monitors/plain/pings               => create, registration_key: "plain"
POST /api/v1/monitors/reports.daily/pings       => create, registration_key: "reports.daily"
POST /api/v1/monitors/%E6%97%A5%E6%9C%AC/pings  => create, registration_key: "日本"
POST /api/v1/monitors//pings                    => RoutingError
```

One trap when testing this: `recognize_path` resolves the controller class, so
these all raise `RoutingError` until `Api::V1::Monitors::PingsController` exists —
which looks exactly like a broken route. Stub the class before concluding the
routing is wrong.

### 3.3 Authentication, and keeping tenants apart

The check-in controller must **not** inherit `Api::V1::BaseController`, which
authenticates API keys. It authenticates ping keys instead, resolves the project
from the key, and reaches the monitor only through that project:

```ruby
current_project.monitors.find_by(registration_key: params[:registration_key])
```

That scoping is not optional. Task names are unique only **within** a project, and
they are ordinary words — `daily_digest`, `nightly_backup`. Different customers
will use identical names constantly; that collision is the whole reason projects
exist. The old ping token was unique across the entire database, so isolation was
a property of the schema. Now it is a property of the code, and needs two tests:

- The same task name in two projects; checked in with project A's key, project B's
  monitor must be untouched.
- **A ping key must be rejected by every other `/api/v1` endpoint, and an API key
  must be rejected by this one.** This is the test that closes the escalation risk
  §3.1 designed against.

Note that not inheriting the base controller is also what makes §3.5 possible:
`rate_limit` compiles to a `before_action` holding an anonymous lambda, so a
subclass cannot skip or replace an inherited limiter.

### 3.4 The pings controller

The existing public controller carries a lot that now disappears, because the
endpoint is authenticated: two rate limiters keyed on a URL secret, deliberately
uninformative 404s to avoid confirming whether a token exists, and the reasoning
about not leaking which tenant a request belongs to. None of that is needed once a
request must present a credential.

What survives and moves across: the guard against oversized duration values, the
guard against array-shaped parameters, and the success-or-failure rule that reads
`status` and `message`.

**Record ping-key usage coarsely.** `ApiKey::Authentication` writes
`last_used_at` on every authentication. A ping key is authenticated after every
job in the project, so an unconditional write would queue all of a tenant's
concurrent check-ins behind one row and turn every check-in into two writes.
Rotation still needs the signal, so write it only when the recorded value is more
than five minutes old.

Worth applying the same coarsening to `ApiKey` while here — it has the same
unconditional `touch` and nothing depends on the precision. The only reader is a
"Last used" column in the project view.

### 3.5 Rate limiting

Count per **monitor**, and key the counter on values available *before*
authentication runs:

```ruby
by: -> { "#{request.authorization.presence || request.remote_ip}|#{params[:registration_key]}" }
```

`rate_limit` installs an ordinary `before_action`, so the limiter runs *before*
the credential is resolved. Both values above are readable at that point; a
`@current_ping_key` ivar is not. Two ways to get this wrong, both measured through
a real request stack:

- **`by: -> { @current_ping_key }`** — the ivar is `nil`, and Rails builds the
  counter key with `["rate-limit", scope, name, by].compact.join(":")`. `.compact`
  **drops the nil rather than distinguishing it**, so the whole controller
  collapses to a *single* counter: three tenants and four task names shared one
  bucket, and an anonymous request could exhaust it for everybody.
- **`by: -> { "#{@current_ping_key}|#{params[:registration_key]}" }`** — here
  `.compact` does nothing, because the value is the string `"|alpha"`. The
  collapse is narrower but still wrong: one counter per task name, shared across
  every tenant using that name.

Count per monitor rather than per key, or a project with more jobs than the limit
throttles itself into a false project-wide outage — and the gem treats the
resulting 429 as transient and ignores it, so the symptom would be a burst of
false "down" alerts.

**Do not use the raw token as the counter key.** `Api::V1::BaseController:51`
currently keys on `request.authorization`. Rails emits `by:` and the cache key
into an `ActiveSupport::Notifications` payload on every throttle event, so a
broadly-subscribed monitoring tool captures live credentials — verified by driving
the real limiter past its ceiling and printing the payload:

```
:by        => "Bearer sm_live_xWGEOzS87Raa4ayskOST5S8F3YKZX8W5"
:cache_key => "rate-limit:api/v1/monitors:per-key:Bearer sm_live_xWGEOzS87Raa…"
```

That string is also the literal cache key written to the store, so the comment
there contemplating a move to Solid Cache would persist credentials to Postgres.
Key on a digest instead. This is a pre-existing defect; fix it rather than
reproducing it on the busiest endpoint in the system.

One caveat on §3.3's claim that a subclass cannot escape an inherited limiter:
that is true of the ordinary `skip_before_action :name` API, because the callback
is an anonymous lambda with no name to reference. It is not absolute — a subclass
can dig the proc out of `_process_action_callbacks` and skip it, or override the
private `#rate_limiting` helper. Both are conspicuous in a diff, which is the
property actually wanted.

### 3.6 Error responses

Now that the endpoint is authenticated, the existing API conventions apply and the
deliberately uninformative responses can go:

- Missing, unknown or revoked ping key → `401`, matching the rest of `/api/v1`.
- Valid key, unknown task name → `404`.

Those being **distinguishable** is a gain, not a leak: a caller has already proved
they hold a credential for the project, so telling them a task is unregistered
reveals nothing they could not learn from the monitors list. It also gives the gem
the signal §4.3 needs.

### 3.7 The monitor form gains a task name

This is the change that keeps the manual path alive, and it is one field.

`MonitorsController#monitor_params` permits only `name`,
`expected_interval_seconds` and `grace_period_seconds`; `Project::MonitorSync` is
the only writer of `registration_key` anywhere in the app. So a hand-created
monitor has no task name, and under §2.1 a monitor with no task name has no
address. That — not the credential, not the endpoint — is the only thing that
would have made hand-created monitors unusable.

The field itself is one line. **The fallout is not** — measured, not estimated:
adding the field and its validations takes the suite from `515 runs, 0 failures`
to **27 failures and 188 errors across 25 files**, because roughly 95
`monitors.create`/`new` call sites in `test/` pass no task name, and 3 of the 4
monitors in `test/fixtures/monitors.yml` have none. Budget for that rather than
discovering it.

What the change actually involves:

- **Permit `registration_key` and add the field.** On its own — no validations —
  this is genuinely free: the suite stays green, the monitor saves, `source` stays
  `"manual"`, and `project.monitors.find_by(registration_key:)` finds it.
- **Validate: present, `without: %r{/}`, and unique `scope: :project_id`.** The
  scope is required, not decorative — an unscoped uniqueness validation breaks
  cross-project task-name reuse, which `syncs_controller_test.rb:108-120` asserts
  explicitly. Give the uniqueness validator `allow_nil`, or a nil key collects a
  spurious "has already been taken" alongside "can't be blank" (the validator
  matches the other `NULL` rows).
- **Adjust `Project::MonitorSync#persist_create` in the same change.** This is the
  non-obvious one. A Rails uniqueness validation silently disables the operation's
  concurrent-create recovery: `save_isolated` now fails on the validator's
  pre-flight `SELECT`, so the `rescue ActiveRecord::RecordNotUnique` branch that
  re-finds and upserts never runs, and the gem is told its task was "invalid"
  instead of registered. `monitor_sync_test.rb:175` catches it. The create path
  needs to treat a uniqueness *validation* failure the way it already treats the
  database error.
- **Backfill, in the same migration as the `NOT NULL`.** Every hand-created
  monitor has `NULL` today, so each is unaddressable until backfilled, and
  `SET NOT NULL` against un-backfilled rows fails outright. Derive from the name;
  iterate in a deterministic order carrying a set of keys already taken *in this
  run*, or later rows collide with ones assigned moments earlier. Four edge cases,
  all reproduced:
  - **Do not use `String#parameterize`** — it strips non-Latin characters
    entirely, so a monitor named 日本語のジョブ derives an empty key and falls back
    to `monitor-<id>`. That contradicts §3.2, which supports unicode task names.
    Strip only `/` and surrounding whitespace.
  - Duplicate names within one project are common; all but the first need the
    fallback.
  - A name of `"!!!"` or `"   "` derives to blank — `name` is `NOT NULL` but not
    non-blank.
  - `monitor-<id>` is not collision-proof either: a pre-existing key that happens
    to equal `monitor-<some other id>` makes it raise. Suffix and retry.
- The gem's registration path is unaffected — `unique_entries` drops blank keys
  before anything else, and `persist_create` always writes the column.

A side effect worth noting: `docs/integrating.md` currently documents a manual
fallback where you "create a monitor by hand whose registration key equals the job
class name". That has never been possible, because the form omits the column. This
field makes the documentation true for the first time.

### 3.8 Interface

The project page gains a ping-key section mirroring the API-key one: issue,
revoke, list, all scoped so another user's project returns 404, with the keys
loaded in the shared project-page module alongside API keys — that module exists
precisely so the page and the issuing action cannot drift apart. Unlike API keys
the value stays visible, so the list shows it with a copy button rather than a
masked stub, and there is no shown-once dialog.

The monitor setup card keeps its current job — hand the user one line to paste —
and changes only its contents:

```sh
curl -fsS -X POST -H "Authorization: Bearer sm_ping_…" \
  https://stablemate.dev/api/v1/monitors/pg_backup/pings
```

This is why §3.1 keeps the ping key readable. A shown-once key would reduce this
card to a template with a placeholder in it, and copy-paste onboarding is the
thing worth protecting: sign up, create a project, create a monitor, paste one
line, watch it go green — with no Rails app required.

## 4 · Gem design

### 4.1 What is added

- A `ping_key` setting, defaulting to the `STABLEMATE_PING_KEY` environment
  variable — matching how the server address already works.
- Check-in and failure-report requests built against
  `/api/v1/monitors/{task}/pings` with a bearer header, reusing the header helper
  the registration call already uses. The task name is URL-encoded.
- A startup check and log line when no ping key is configured (§4.4).

### 4.2 Check in only for tasks we could actually register

This is the one substantive change beyond deleting the cache, and it fixes an
existing latent bug rather than creating one.

Today, when a job class is not listed in `recurring.yml`, the gem falls back to
using the class name as the task name — but **only if the server previously gave
it an address for that name.** The cache is quietly acting as a server-approved
list of what exists.

Remove the cache and an address becomes constructible for *any* string. The gem
would then check in after every successful run of every job class in the host app
— mailer jobs, file-analysis jobs, every one-off background job.

The cache is also silently doing a second job nobody documented. The gem builds two
lists from `recurring.yml`: one of every task with a job class, and a narrower one
of tasks whose schedule it can actually work out. Tasks in the first but not the
second — a task scheduled for 30 February, say — are never registered, so they have
no address, so their check-ins are silently dropped. The same is true of tasks the
server refused to register.

So: **build the list of reportable tasks from the narrower list.** "Could we work
out this schedule?" becomes an explicit condition rather than an accident of a
missing cache entry. An existing test pins this behaviour and must stay green.

### 4.3 Act on the response

The server now distinguishes a bad credential (`401`) from an unregistered task
(`404`), so the client should too:

- `401` — the ping key is wrong or revoked. Log **once**, loudly. Nothing will
  work until it is fixed.
- `404` — this task is not registered. Log **once per task name**. If registration
  is enabled, the next successful registration fixes it.
- Anything else, or a transport failure — transient, absorbed by the monitor's
  grace period, as now.

Logging once matters: the current code logs on every check-in, which is how a
message gets filtered out as noise. Note that "once" is per-process state read and
written from the background dispatch threads, and this spec deletes the gem's only
mutex — so it needs its own guard. A `Concurrent::Map` or a plain mutex around a
`Set`; do not assume `Set#add?` is atomic under threads.

Add a `Stablemate.health` reader exposing the last registration error, the time of
the last successful check-in, and any rejected task names, so "are my check-ins
arriving?" can be answered from a console or a health check. Nothing about
building addresses locally makes anything visible by itself.

### 4.4 When no ping key is configured

Neither crash nor quietly carry on.

**Do not crash at startup.** The gem's one absolute rule is that monitoring must
never break the app it monitors. Raising during startup would take down every web
worker in a rolling deploy of someone's revenue-generating app because their
monitoring configuration was stale.

**Do not fall back to the old fetch-and-cache path.** That keeps the bug and keeps
the code we are deleting.

Instead: the `stablemate:sync` task — run by hand or from a deploy script, where a
non-zero exit is useful — exits with an error. Startup logs at **error** level
(not warning, the level everything else uses, where it would be invisible) and
skips check-in delivery:

```
[stablemate] no ping_key configured — check-ins are DISABLED and every monitor in
this project will alert as DOWN within one interval + grace. Add
`c.ping_key = Rails.application.credentials.dig(:stablemate, :ping_key)` to
config/initializers/stablemate.rb (or set STABLEMATE_PING_KEY). Find it at
<endpoint>/projects → your project → Ping key. Registration still works without it.
```

**That message would be unreachable where it naturally belongs, and fixing that is
part of the work.** `railtie.rb:44` is `next unless Stablemate.config.api_key`, so
a host with a ping key but no API key — a legitimate configuration once check-ins
and registration use different credentials — skips the entire block silently.
Confirmed by booting a real Rails app against the railtie: with no API key there
are **zero** `perform.active_job` listeners, no armed subscriber, and no log line
of any kind; with one, the same event delivers a check-in.

The gate has to become "wire up whatever the configured credentials allow":

```ruby
config.after_initialize do
  next unless Stablemate.config.enabled_in?
  registrar = Registrars::SolidQueueRecurring.new   # local YAML only, no network

  if Stablemate.config.api_key
    Registration.new(registrar:).sync! if Stablemate.config.register_on_boot
  else
    Stablemate.logger.error("[stablemate] no api_key — monitors will not be registered …")
  end

  if Stablemate.config.ping_key
    Execution::Subscriber.new(class_to_keys: registrar.class_to_keys).subscribe!.subscribe_discards!
  else
    Stablemate.logger.error("[stablemate] no ping_key configured — check-ins are DISABLED …")
  end
end
```

Nothing blocks this: the registrar reads `recurring.yml` locally and builds its
class map with network access banned outright (verified by making `TCPSocket`
raise).

Two things this sketch does not solve on its own:

- **The environment allow-list is still a gate above both branches**, and defaults
  to production only. So a developer booting locally with no ping key sees
  nothing. Decide explicitly whether the missing-credential error logs above that
  gate (log always, wire only in permitted environments) or stays below it with
  everything else. The former is more useful and is what §6.1's "make the broken
  state observable" argues for.
- **Both branches share the same memoised YAML parse**, so a syntax error in
  `recurring.yml` still raises in whichever branch touches it first. Delivering
  §6.4 means each branch needs its own rescue *and* the listener has to tolerate
  an empty class map.

There is also **no railtie test anywhere in the gem suite** — which is precisely
why this gate's behaviour went unnoticed. Add one.

### 4.5 `register_on_boot = false` survives, and gets simpler

The original proposal bundled this with the cache, but they are separable. The map
of job classes to task names is read from the local `recurring.yml` and needs no
network access. So:

- `true` → register monitors at startup, as now.
- `false` → **nothing happens at startup** except attaching the job listener.
  Check-ins still work for every task in `recurring.yml`, because the address is
  built locally.

That second bullet is only true once §4.4's gate is fixed — today the API key
check above it would skip the listener too.

### 4.6 What `sync!` returns

Today it returns the address map, and the rake task prints `"synced N monitor(s)"`
using its size. Without a map it needs something else to count — the number of
monitors the server reported registering. One trap: with no tasks at all it
currently returns an empty map, so the task prints "synced 0". A replacement
returning `nil` would silently turn that into a failure message.

## 5 · Sequencing

**There is no migration to manage.** The gem's only consumer, and the only live
account, is a side project the maintainer owns. Server and gem ship together, and
a broken moment in between costs one redeploy of an app we own. No version
negotiation, no waiting period, no gem supporting both schemes, no deprecation
window. The gem's version goes to `0.2.0` because its public interface changes.

The shared address map and the ability to construct the job listener with your own
addresses are documented for people wiring the gem up by hand. Pre-1.0 with no
third-party users, so they are simply removed.

Two ordering constraints that do matter:

1. **Backfill `registration_key` before enforcing it** (§3.7), and before the
   check-in route ships — until then, hand-created monitors have no address.
2. **Existing monitors keep working across the cutover only if their check-in
   source is updated in the same deploy.** Every live monitor currently checks in
   via a ping-token URL. Once that route is gone, anything still using it goes
   overdue and emits one false `down` email at its grace boundary. Update the gem
   and any shell crons in the same window, or pause the monitors across it.

Check what is actually out there first — task names are about to become part of a
URL, and the manual population needs a backfill:

```sql
SELECT source, count(*) FROM monitors GROUP BY source;
SELECT count(*) FROM monitors WHERE registration_key IS NULL;
SELECT id, project_id, registration_key FROM monitors
WHERE registration_key ~ '[^A-Za-z0-9_.\-]';
```

With the §3.2 constraint in place only a `/` in a task name is genuinely fatal.

## 6 · What this does not fix

### 6.1 Alerts still point at the wrong system

A wrong ping key, a DNS failure, a blocked outbound connection, an interfering
proxy, a rate limit — in every case the server sees silence and the email says the
job "missed its check-in". **This redesign changes how check-ins are addressed,
not what silence means.**

This was the actual damage from the incident, and it is separate, parallel work.
Three signals, cheapest first:

- **Notice that the app is still talking to us.** The API key already records when
  it was last used, on every registration — and nothing reads it. "This app checked
  in three minutes ago, but no monitor has reported for an hour" is a *positive*
  statement with no false positives: the app is running and can reach us, so it is
  the check-ins specifically that are not arriving. Works even with a single
  monitor.
- **Alert on monitors that have never checked in.** Detection only considers
  monitors currently marked up, so a monitor that is registered but has never
  received a successful check-in is invisible to it **forever** and produces no
  alerts at all. This is also the failure mode a confused new user hits: a
  permanently grey row, no email, no error. The threshold has to be relative to the
  monitor's own interval, it must fire once, and it needs its own wording pointing
  at setup docs.
- **Notice a whole project going quiet.** Not "every monitor is down" — monitors go
  overdue in order of how often they run, so waiting for all of them means waiting
  for the slowest. The useful test is: the most recent check-in *anywhere* in the
  project is older than the *shortest* interval-plus-grace in it. That fires as soon
  as the fastest job misses. It needs somewhere to record a project-level incident,
  and it tells you nothing about a project with one monitor.

The wording rule for all of them: **say what was observed, never what it means.**
"No monitor in project Foo has reported since 14:02" is true whether the cause is a
firewall, a crashing worker, or a deliberate shutdown, and it sends the reader to
the right place in all three. "Your network is blocked" is just a new way to be
wrong.

### 6.2 Two credentials that can disagree

Nothing forces the API key and the ping key to belong to the same project. Use
project A's API key with project B's ping key and registration writes to A while
check-ins go to B. A's monitors go down permanently, and every symptom reads as
"your job is down". This is a **new** kind of mistake, and permanent rather than
transitional, so it needs a permanent guard.

The guard, shipping with the gem rather than after it: registration returns the
last four characters of the project's ping key, and the gem logs loudly at startup
if the key it holds does not match. There is no escalation in that — an API key can
already list every monitor in its project.

Together with §4.3's `401` handling, this turns "wrong key, silent until the
interval elapses" — about 27 hours for a daily job — into one line at deploy time.

### 6.3 One leaked key exposes a whole project

A leaked ping key lets an attacker fake check-ins **and failure reports** for every
monitor in the project, where a leaked ping token affected one. And faking a
check-in on a monitor that is currently down does not just suppress the alert — it
resolves the incident and sends a "recovered" email during a real outage.

Moving the credential into a header narrows this considerably compared with the
URL design: it is no longer written to request logs, proxy logs or error reports,
cannot be fired by a link preview, and will not appear in a screenshot of a
crontab. What remains is that anyone who can read a host's credentials or a crontab
file holds it.

Bounded further by rotation being safe and cheap (§3.1) and by the key having no
capability except recording a check-in. Not bounded by hashing, because §3.1
deliberately keeps it readable — that is the trade the setup card buys.

### 6.4 The catch-all around gem startup

The second bug from §1 is untouched by any of this and needs the same treatment:
narrow the catch-all so a broken `recurring.yml` cannot silently leave the job
listener unattached for the life of the process, and surface it through
`Stablemate.health`.

### 6.5 An unrelated bug found while verifying the above

Not caused by this work and not fixed by it, but it was found while booting the
railtie and should not be lost.

`Execution::Subscriber.install_discard_hook` can install its callback **twice**,
so every terminal job failure reports the error twice. The guard is
`return if @discard_hook`, but the line below it —
`::ActiveJob::Base.respond_to?(:after_discard)` — autoloads `ActiveJob::Base`,
which re-entrantly fires the railtie's own `on_load(:active_job)` hook. At that
moment `@discard_hook` is still `nil`, so the guard does not fire and both calls
install a proc. Measured: `after_discard_procs.size == 2`, both with the same
source location and different object ids.

It is load-order dependent — anything that touches `ActiveJob::Base` earlier makes
it collapse back to one — which is why it has not been noticed. Fix by assigning
`@discard_hook` (or an in-progress flag) *before* touching `::ActiveJob::Base`.

## 7 · Test plan

Beyond ordinary unit and request coverage, the parts that are not optional:

- **Browser test: the manual path end to end.** Create a monitor with a task name,
  copy the `curl` line from the setup card, and drive a check-in with it. This is
  the flow §3.7 exists to preserve and the one an earlier draft would have
  deleted.
- **Browser test: ping keys.** Issue one from the project page, see it listed and
  copyable, revoke it.
- **Credential separation.** A ping key must be rejected by every other `/api/v1`
  endpoint, and an API key rejected by the check-in endpoint (§3.3).
- **Tenant isolation.** The same task name in two projects; checked in with project
  A's key, project B's monitor must be untouched (§3.3).
- **Rate limiting, both directions.** Two task names under one ping key must not
  share a counter, **and two ping keys on the same task name must not share one** —
  the second case is what catches a lambda that reads post-authentication state,
  and the first alone would pass a broken implementation (§3.5).
- **Routing.** A task name containing a dot must arrive intact (§3.2).
- **Validation.** A task name containing `/` must be rejected by the form, not by
  the router. Task names must stay reusable across projects and unique within one
  (§3.7).
- **Registration survives the new validation.** `Project::MonitorSync`'s
  concurrent-create recovery must still upsert rather than report "invalid" —
  `monitor_sync_test.rb:175` already covers this and must stay green (§3.7).
- **Backfill.** Duplicate names in one project, a name that derives to blank, and
  a non-Latin name must each produce a distinct, usable, slash-free key (§3.7).
- **Gem: unlisted job classes never check in** under the new task list (§4.2).
- **Gem: a ping key but no API key** — job listener still attached, check-ins still
  sent (§4.4). This fails today.
- **Gem: no ping key configured** — listener attached, nothing sent, one error line
  (§4.4).
- **Gem: a task with an unworkable schedule never checks in** (§4.2) — the
  containment the cache was doing by accident.
- **Gem: `401` and `404` are handled differently** and each logs once (§4.3).
