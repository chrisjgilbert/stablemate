# Ping architecture — authenticated check-ins

Status: **proposed**, not yet built. Replaces two things: the scheme where the gem
fetches its ping URLs from the server at startup and holds them in memory, and the
public unauthenticated ping endpoint.

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

**The proposal has two parts.**

*Stop asking.* The gem addresses a monitor by its task name, which it already
reads from `recurring.yml`. Nothing is fetched, so there is nothing to cache and
nothing to go stale.

*Authenticate the check-in.* A new credential — a **ping key** — is sent in an
`Authorization` header, exactly as the existing API key already is. It can record
check-ins and nothing else.

```
POST /api/v1/monitors/{registration_key}/pings
Authorization: Bearer sm_ping_…
```

**What this deletes.** About 110 lines of the most delicate code in the gem,
including all of its state shared between threads. And, because check-ins are now
authenticated, the entire public unauthenticated ping endpoint — its two rate
limiters, its parameter guards, its deliberately uninformative error responses,
the per-monitor ping token, and both token-rotation controllers. The application
is left with **no unauthenticated write endpoint at all.**

**What this costs.** Stablemate stops being able to monitor anything that is not
an ActiveJob job in a Rails app the gem is installed in. Shell scripts, `command:`
recurring tasks, and jobs in other languages have no way in. That is a deliberate
narrowing to match what the README already claims — "job monitoring for Rails
applications" — and §6 sets out exactly what is given up.

**What this does not fix.** If check-ins stop arriving for any reason, Stablemate
still reports "your job is down", which is the misleading alert that made the
incident painful. That is separate work, described in §7.1 and being done in
parallel.

> **Gate before building §6.** Removing manual monitors deletes a shipped feature.
> The projects migration records that production has real users with monitor rows,
> and `source` defaults to `"manual"`, so monitors created in the interface or
> predating the gem are manual. Run `SELECT source, count(*) FROM monitors GROUP
> BY source;` first. If real customers hold manual monitors, §6 needs a migration
> plan or should be dropped; §§1–5 are unaffected either way.

---

## The two credentials

The redesign adds one credential and removes one. Afterwards there are two, they
work the same way, and **neither ever appears in a URL**:

| | What it is for | Scope | Stored as | Sent as |
|---|---|---|---|---|
| **API key**<br>`sm_live_…` | Managing monitors: listing them, registering them from `recurring.yml` | One project | A hash — the real value is shown once and never recoverable | `Authorization: Bearer` |
| **Ping key** *(new)*<br>`sm_ping_…` | Recording check-ins, and nothing else | One project | A hash — shown once | `Authorization: Bearer` |

The **ping token** — a secret in the URL identifying one monitor — is removed
(§6).

Why add a second key rather than reuse the first: the API key can read and rewrite
every monitor you own. The gem sends a request after every single job run, and a
credential that powerful does not belong on a path that busy. The ping key can
only say "this job ran".

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

Two corrections to the original incident write-up:

- **It was not completely silent.** The startup failure logs one line, but to
  standard error rather than the Rails log unless the host configured otherwise.
  The signal existed once, where nobody was looking.
- **There is a second, worse version of the same bug.** The gem's startup code
  wraps everything — reading `recurring.yml`, registering monitors, attaching the
  job listener — in a single catch-all. If `recurring.yml` has a YAML syntax
  error the listener is never attached at all: no success check-ins *and* no
  failure reports, one warning, no recovery. Deleting the address cache does not
  touch this. §7.4 covers it.

## 2 · The decision

Two changes that are independent and each stand on their own.

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

An earlier draft of this design followed Healthchecks.io and put the ping key in
the URL path: `POST /ping/{ping_key}/{registration_key}`. That is the right shape
for Healthchecks, whose clients are `curl` invocations in any language. It is the
wrong shape here, where the only client is a Ruby gem.

Healthchecks puts the credential in the URL to buy one property: a single
copy-pasteable string that works with no flags, in environments that cannot set
headers. Once §6 removes the audience that needs that, the property is worth
nothing and its costs are all still charged.

Moving the credential to a header fixes four things at once:

- **It leaves the logs.** Rails logs request paths verbatim and filters only query
  strings, so a credential in the path is written to every request log, every
  proxy log, and every error report. A header is not logged.
- **`GET` stops applying.** A check-in is not a read: it advances the monitor's
  clock and, if the monitor is currently down, resolves the incident and sends a
  "recovered" email. With the credential in a URL, anything that follows a link —
  chat-app previews, mail providers pre-fetching, antivirus scanners, browser
  prefetch — can fire one. This endpoint is `POST` only.
- **It is a normal REST resource.** Creating a check-in for a monitor is
  `POST …/monitors/{id}/pings`, which is what it now is.
- **Two specific bugs never get written.** The rate-limiter fault in §3.5 and the
  URL-parsing fault in §3.2 both come from having a credential and a task name as
  adjacent path segments.

It still satisfies the principle from the incident report that the gem should have
no privileged path — a person can type
`curl -H "Authorization: Bearer sm_ping_…"` just as easily. Nothing here is
fetch-only.

The one thing lost: you can no longer paste a check-in URL into a browser to test
it. That is a small debugging convenience, and `curl -v` replaces it.

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
column cannot hold two values, and a design that cannot rotate safely should be
rejected on that alone. Rotation is then: create a second key, deploy it, watch
the first one's "last used" timestamp stop moving, delete it. Because you add
before you remove, nothing breaks in between.

```
app/models/ping_key.rb              # the model
app/models/ping_key/issuance.rb     # PingKey.issue(project:, name:) -> [key, raw token]
```

Columns mirror `api_keys`: `project_id`, `name`, `token_digest` (unique),
`token_last4`, `last_used_at`, timestamps. The raw format is `sm_ping_` followed
by 32 random characters — a **different prefix** from `sm_live_`, so a key pasted
into the wrong configuration slot fails immediately and automated secret scanners
can tell them apart.

Because the key is never displayed after creation, only its hash is stored. A
database leak yields nothing usable.

The migration adds a new table with a unique index, which is safe. Written with
explicit `up` and `down` so it can be rolled back.

**This must not be a "type" column on the existing `api_keys` table.**
Authentication looks a token up across the whole table. With one table a ping key
would authenticate the management API unless every single lookup remembered to
filter by type — and forgetting is silent and permissive, the worst possible
default in security code. Two tables make the mistake impossible rather than
merely discouraged.

**Shared hashing, separate policy.** The existing authentication code is two
methods referencing nothing specific to API keys: hash the token, look it up by
hash, compare, record usage. Copying it wholesale means a future fix applied to
one copy and not the other — a silent divergence in security-critical code.

So extract only the mechanical part into a shared module: hash a token, and find a
record by that hash, with the redundant constant-time comparison and the comment
explaining why it is there. Each model keeps its own authentication method holding
its own rules — the API key records usage on every lookup, the ping key does not
(§3.4). A single shared method with a `record_usage:` switch is rejected for the
same reason as the type column: it can be forgotten.

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

The standalone form leaves `show` on `:id` and puts the constraint on the segment
it is meant to guard.

**The constraint and `format: false` are both required.** Rails excludes dots from
dynamic URL segments by default and treats a trailing `.foo` as a format.
Task names come from a user's `recurring.yml` and nothing validates their format
anywhere in the app. Verified behaviour with the declaration above:

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

Note this is a **better** failure than the URL-credential design had: there, a
dotted task name silently checked in a *different monitor in the same project*.
Here it is a routing error, so the worst case is a check-in that does not arrive
rather than one that arrives at the wrong monitor. The gem must still URL-encode
the task name.

Before this ships, check what is actually out there — task names are about to
become part of a URL:

```sql
SELECT id, project_id, registration_key FROM monitors
WHERE registration_key ~ '[^A-Za-z0-9_.\-]';
```

With the constraint in place only a `/` in the name is genuinely fatal.

### 3.3 Authentication, and keeping tenants apart

The check-in controller must **not** inherit the existing API base controller,
which authenticates API keys. It authenticates ping keys instead, resolves the
project from the key, and reaches the monitor only through that project:

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

### 3.4 The pings controller

The existing public controller carries a lot that now disappears, because the
endpoint is authenticated: two rate limiters keyed on a URL secret, deliberately
uninformative 404s to avoid confirming whether a token exists, and the reasoning
about not leaking which tenant a request belongs to. None of that is needed once a
request must present a credential the API base already knows how to reject.

What survives and moves across: the guard against oversized duration values, the
guard against array-shaped parameters, and the success-or-failure rule that reads
`status` and `message`.

**The ping key does not record usage on every request.** An API key is
authenticated a handful of times per deploy; a ping key would be authenticated
after every job in the project, so writing a timestamp each time would queue all
of that tenant's concurrent check-ins behind one database row and turn every
check-in into two writes. Rotation still needs the signal, so write it coarsely —
only when the recorded time is more than five minutes old.

### 3.5 Rate limiting

Count per **monitor** — the ping key and task name together — not per key. A
project with more jobs than the limit would otherwise throttle itself into a
false project-wide outage, and the gem treats the resulting 429 as a transient
error and ignores it, so the visible symptom would be a burst of false "down"
alerts.

This is worth stating because the URL-credential draft had a real bug here. Its
limiter counted per ping token, and on a two-segment route that value is `nil` —
and Rails builds the counter key with `["rate-limit", scope, name, by].compact`,
which **drops the nil entirely** rather than treating it as distinct. Every
check-in from every customer in the process would have shared one counter. Moving
to a header removes the shape that made that possible, but the per-monitor keying
is still the requirement.

A per-IP limiter is no longer the main defence, since requests must authenticate,
but keep one as a coarse bound.

### 3.6 Error responses

Now that the endpoint is authenticated, the existing API conventions apply and the
deliberately uninformative responses can go:

- Missing, unknown or revoked ping key → `401`, matching the rest of `/api/v1`.
- Valid key, unknown task name → `404`.

Those being **distinguishable** is a gain, not a leak: a caller has already proved
they hold a credential for the project, so telling them a task is unregistered
reveals nothing they could not learn from the monitors list. It also gives the gem
the signal §4.3 needs — "my key is wrong" and "this job is not registered yet"
were indistinguishable under the old design and had to be teased apart on the
client.

### 3.7 Interface

The project page gains a ping-key section mirroring the API-key one exactly: issue
a key and re-render the page with the shown-once dialog, revoke, both scoped so
another user's project returns 404, and the keys loaded in the shared project-page
module alongside API keys — that module exists precisely so the page and the
issuing action cannot drift apart.

The existing shown-once dialog hardcodes "API key" in its heading, label and test
identifier. Pass those in as parameters rather than duplicating the file.

The monitor page's setup card changes meaning entirely. There is no URL to copy,
because there is no URL that works on its own. It becomes instructions: add the
gem, put the ping key in credentials, declare the task in `recurring.yml`.

## 4 · Gem design

### 4.1 What is added

- A `ping_key` setting, defaulting to the `STABLEMATE_PING_KEY` environment
  variable — matching how the server address already works, so setup is one step
  rather than two.
- Check-in and failure-report requests built against
  `/api/v1/monitors/{task}/pings` with a bearer header, reusing the header helper
  the registration call already uses. The task name is URL-encoded.
- A startup check and log line when no ping key is configured (§4.4).

### 4.2 Check in only for tasks we could actually register

This is the one substantive change beyond deleting the cache, and it fixes an
existing latent bug rather than creating one.

Today, when a job class is not listed in `recurring.yml`, the gem falls back to
using the class name as the monitor name — but **only if the server previously
gave it an address for that name.** The cache is quietly acting as a
server-approved list of what exists.

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
  is enabled, it will be fixed by the next successful registration.
- Anything else, or a transport failure — transient, absorbed by the monitor's
  grace period, as now.

Logging once matters: the current code logs on every check-in, which is how a
message gets filtered out as noise.

Add a `Stablemate.health` reader exposing the last registration error, the time of
the last successful check-in, and any rejected task names, so "are my check-ins
arriving?" can be answered from a console or a health check. Nothing about
building addresses locally makes anything visible by itself — this has to be built
on purpose.

### 4.4 When no ping key is configured

Neither crash nor quietly carry on.

**Do not crash at startup.** The gem's one absolute rule is that monitoring must
never break the app it monitors. Raising during startup would take down every web
worker in a rolling deploy of someone's revenue-generating app because their
monitoring configuration was stale.

**Do not fall back to the old fetch-and-cache path.** That keeps the bug, keeps
the code we are deleting, and means nobody ever moves across.

Instead: the `stablemate:sync` task — run by hand or from a deploy script, where a
non-zero exit is useful — exits with an error. Startup logs at **error** level
(not warning, the level everything else uses, where it would be invisible) and
skips check-in delivery entirely:

```
[stablemate] no ping_key configured — check-ins are DISABLED and every monitor in
this project will alert as DOWN within one interval + grace. Add
`c.ping_key = Rails.application.credentials.dig(:stablemate, :ping_key)` to
config/initializers/stablemate.rb (or set STABLEMATE_PING_KEY). Find it at
<endpoint>/projects → your project → Ping key. Registration still works without it.
```

What will happen, how to fix it, where to get the value, and what still works.

### 4.5 The `register_on_boot` setting survives, and gets simpler

The original proposal bundled this with the cache, but they are separable. The map
of job classes to task names is read from the local `recurring.yml` and needs no
network access. So:

- `true` → register monitors at startup, as now.
- `false` → **nothing happens at startup** except attaching the job listener.
  Check-ins still work for every task in `recurring.yml`, because the address is
  built locally.

Strictly better than today, where turning registration off merely swapped one
startup network call for a different one on the same fragile path.

### 4.6 What `sync!` returns

Today it returns the address map, and the rake task prints `"synced N monitor(s)"`
using its size. Without a map it needs something else to count — the number of
monitors the server reported registering. One trap: with no tasks at all it
currently returns an empty map, so the task prints "synced 0". A replacement
returning `nil` would silently turn that into a failure message.

## 5 · Sequencing

**There is no migration to manage for the gem.** Its only user is a side project
the maintainer controls, so it is updated at the same time. Server and gem ship
together, and a broken moment in between costs one redeploy of an app we own.

That removes what would otherwise be the most expensive part: no version
negotiation, no waiting period to prove the old path unused, no gem supporting
both schemes, no deprecation window. The gem's version goes to `0.2.0` because its
public interface changes, not because anything needs to detect it.

The shared address map and the ability to construct the job listener with your own
addresses are documented for people wiring the gem up by hand. Pre-1.0 with no
third-party users, so they go without ceremony.

**§6 is a different matter** and is gated on the query in the summary.

## 6 · What the product gives up

This is the part to disagree with if any of it is going to be disagreed with.

Removing the public check-in endpoint means Stablemate can only monitor **an
ActiveJob job, in a Rails app, with the gem installed.** Specifically lost:

- **`command:` recurring tasks.** Solid Queue runs these without a job class, so
  the gem cannot attribute a run to them. The documented workaround today is
  either wrapping the command in a job class or creating a monitor by hand and
  appending a `curl`. Only the first survives.
- **Anything not in a Rails app** — a backup script on the same box, a job in
  another language, a scheduled task in a managed service.
- **Monitors created in the interface.** With no way to check them in, creating one
  produces a monitor that can only ever be pending.

### What that deletes

Directly: the ping token column and its concern, both token-rotation controllers,
the public check-in route and the unauthenticated parts of its controller, and
monitor creation in the interface.

By cascade, and this reaches further than it first appears:

| Becomes dead | Why |
|---|---|
| `Monitor::Transfer` and its controller and view | Its first line is `return … unless @monitor.manual?` |
| `awaiting_setup?` and the branch it drives | Defined as `manual? && !ever_pinged?` |
| The gem provenance chip | Every monitor is from the gem, so it distinguishes nothing |
| `from_gem?` / `manual?` / the `source` column | Constant |

Plus roughly 228 lines across four browser-test files.

### Why this is defensible

The README already says "Dead simple job monitoring for **Rails applications**",
and the landing page mentions Rails four times and Solid Queue once, with no
mention of `curl` or cron. Meanwhile `docs/integrating.md` §2 is a full section
titled "The manual path (any language, any scheduler)". Those two have disagreed
since before this redesign. This resolves the disagreement in favour of what the
product actually claims to be.

It is also the safe direction to be wrong in. Adding a per-monitor URL credential
back later is a column and a route. Removing one after customers depend on it is
the hard direction. Narrow now, widen on evidence.

### Why it might still be wrong

Every comparable service — Healthchecks, Cronitor, Dead Man's Snitch, Sentry — is
language-agnostic, and the single copy-pasteable URL is how all of them onboard.
Giving it up forecloses the "I have one weird cron job" entry point, which is
often how a team first tries a monitoring product. That is a positioning decision,
not a technical one, and it should be made deliberately rather than as a
consequence of this redesign.

## 7 · What this does not fix

### 7.1 Alerts still point at the wrong system

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
  alerts at all. The threshold has to be relative to the monitor's own interval, it
  must fire only once, and it needs its own wording pointing at setup docs.
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

### 7.2 Two credentials that can disagree

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

### 7.3 One leaked key exposes a whole project

A leaked ping key lets an attacker fake check-ins **and failure reports** for every
monitor in the project, where a leaked ping token affected one. And faking a
check-in on a monitor that is currently down does not just suppress the alert — it
resolves the incident and sends a "recovered" email during a real outage.

Moving the credential into a header narrows this considerably compared with the
URL design: it is no longer written to request logs, proxy logs or error reports,
cannot be fired by a link preview, and will not appear in a screenshot of a
crontab. What remains is that anyone who can read the host app's credentials holds
it — which is true of the API key too, and that one is strictly more powerful.

Bounded further by storing only a hash, independent rotation with an overlap
period (§3.1), and refusing to let the key create anything (§2.3).

### 7.4 The catch-all around gem startup

The second bug from §1 is untouched by any of this and needs the same treatment:
narrow the catch-all so a broken `recurring.yml` cannot silently leave the job
listener unattached for the life of the process, and surface it through
`Stablemate.health`.

## 8 · Test plan

Beyond ordinary unit and request coverage, the parts that are not optional:

- **Browser test.** Generate a ping key from the project page, see it once, see it
  masked afterwards, revoke it. Mirrors the existing API-key test.
- **Credential separation.** A ping key must be rejected by every other `/api/v1`
  endpoint, and an API key rejected by the check-in endpoint (§3.3).
- **Tenant isolation.** The same task name in two projects; checked in with project
  A's key, project B's monitor must be untouched (§3.3).
- **Rate limiting.** Two different task names under one ping key must not share a
  counter (§3.5).
- **Routing.** A task name containing a dot must arrive intact (§3.2).
- **Gem: unlisted job classes never check in** under the new task list (§4.2).
- **Gem: no ping key configured** — listener still attached, nothing sent, one
  error line (§4.4).
- **Gem: a task with an unworkable schedule never checks in** (§4.2) — the
  containment the cache was doing by accident.
- **Gem: `401` and `404` are handled differently** and each logs once (§4.3).
