# Ping architecture — one command, one endpoint

Status: **proposed**, not yet built.

Three things change. Monitors are registered by an explicit command instead of
automatically at boot. Check-ins are addressed by task name instead of a URL
fetched from the server. And they authenticate with a header instead of a secret
in the path.

---

## Summary

On 1 August 2026 a host app deployed normally. One network call during startup
timed out. From that moment the app stopped reporting to Stablemate entirely, and
kept not reporting until it was restarted. Four healthy jobs were reported as
down. The jobs were fine — the monitoring was broken, and the alerts blamed the
jobs.

The cause is that the gem asks the server where to send its check-ins when the
app starts, and remembers the answer. If that one call fails it has nothing to
send to, and nothing ever makes it ask again.

**The fix is to stop doing anything over the network at startup.**

- **Registration becomes a command.** `bin/rails stablemate:sync` already exists;
  it becomes the only way a monitor comes into existence. Nothing registers
  automatically at boot, so there is no startup network call left to fail.
- **Check-ins are addressed locally.** A monitor is reached by its task name,
  which the gem already reads from `recurring.yml`. Nothing is fetched, so there
  is nothing to cache and nothing to go stale.
- **Check-ins authenticate with a header.** A new credential — the **ping key** —
  is sent as `Authorization: Bearer`, exactly as the existing API key already is.
  It can record check-ins and nothing else.

```
POST /api/v1/monitors/{registration_key}/pings
Authorization: Bearer sm_ping_…
```

That is the only way to record a check-in, whether it comes from the gem, a shell
script, or another language.

**What this deletes.** About 110 lines of the most delicate code in the gem,
including all of its state shared between threads. The per-monitor ping token and
both token-rotation controllers. Creating a monitor through the web interface,
and everything that existed only to support it. And the entire public
unauthenticated endpoint — two rate limiters, parameter guards, and deliberately
uninformative error responses. The application is left with **no unauthenticated
write endpoint for check-ins**, and **one way for a monitor to come into
existence**.

**What this costs.** Two things, both real:

- A leaked ping key can fake check-ins for every monitor in its project, where a
  leaked ping token affected one — including faking a recovery during a genuine
  outage (§6.3).
- **You cannot see Stablemate work without deploying a Rails app.** Sign up and
  your next step is: add the gem, deploy, run the command, wait for a job to fire.
  There is no browser-only path any more. That is the price of one registration
  path, and it is accepted deliberately (§3.7).

**What this does not fix.** When check-ins stop arriving for any reason,
Stablemate still says "your job is down" — the misleading alert that made the
incident painful. That is separate work, described in §6.1.

---

## The two credentials

Both are project-scoped, both are stored as a hash and shown once, and **neither
ever appears in a URL**:

| | What it is for | Sent as |
|---|---|---|
| **API key** `sm_live_…` | Registering monitors, listing them | `Authorization: Bearer` |
| **Ping key** *(new)* `sm_ping_…` | Recording check-ins, and nothing else | `Authorization: Bearer` |

The per-monitor **ping token** is removed.

Why a second credential rather than reusing the first: the API key can read and
rewrite every monitor you own. The ping key is what gets pasted into a crontab on
a machine that has no business holding anything more powerful.

## 1 · What actually went wrong

From the gem's job-completion handler:

```ruby
# gem/lib/stablemate/execution/subscriber.rb:256-260
def dispatch(key, label:, &request)
  url = url_for(key)
  return unless url                 # ← gives up here, silently
  @dispatcher.call(-> { deliver(url, label, &request) })
```

The gem has a repair mechanism: if a check-in comes back rejected, it re-fetches
its addresses. But that only runs *after* a request has been sent, and a request
can only be sent if an address was found. **The repair is behind the door it is
meant to open.** With no addresses nothing is sent, so nothing is rejected, so
nothing is repaired, for the life of the process.

It is worse under the host's setup, where the job supervisor runs inside the web
server: the supervisor copies its memory to each worker it starts, so one failed
startup call is inherited by all of them.

Three corrections to the original incident write-up:

- **It was not completely silent.** The startup failure logs one line, but to
  standard error rather than the Rails log unless the host configured otherwise.
- **There is a second version of the same bug.** The gem's startup code wraps
  everything in a single catch-all (`railtie.rb:43-75`). A YAML syntax error in
  `recurring.yml` leaves the job listener unattached: no check-ins *and* no
  failure reports, one warning, no recovery. §6.4.
- **And a gate above both.** `railtie.rb:44` is
  `next unless Stablemate.config.api_key`, so everything below it — including the
  listener — is skipped when no API key is set. Confirmed by booting a real Rails
  app against the railtie: with no API key there are zero `perform.active_job`
  listeners, no armed subscriber, and no log line of any kind. §4.4 moves that
  gate.

## 2 · The decision

### 2.1 Registration becomes a command

`bin/rails stablemate:sync` already exists and already reads `recurring.yml`,
builds registration tuples and posts them. It becomes the **only** way a monitor
is created. The railtie stops registering anything.

**This removes the incident's mechanism rather than working around it.** There is
no network call at startup, so there is nothing at startup to fail.

It also makes registration deliberate. Put it in your deploy script:

```sh
bin/rails stablemate:sync
```

**Monitors that are not Rails jobs are declared in config**, so they go through
the same command rather than needing a second path:

```ruby
Stablemate.configure do |c|
  c.monitors = { "pg_backup" => { interval: 1.day, grace: 2.hours } }
end
```

That covers the shell-script case — a nightly `pg_dump` cron, say — with a `curl`
at the end of the script and no web interface involved.

**What this does not remove**, contrary to an earlier draft of this spec: the
`last_synced_name` / `last_synced_expected_interval_seconds` /
`last_synced_grace_period_seconds` columns and the `gem_may_write?` logic that
reads them. Their comment blames boot sync — *"The gem re-syncs on EVERY
production boot, so writing these three unconditionally meant a user who tightened
a monitor in the UI had it silently reverted at the next deploy"* — and the
obvious inference is that a deliberate command makes them unnecessary. It does
not: the recommended usage above puts the command in a deploy script, so it still
runs on every deploy, and a setting a user tightened by hand must still survive
it. The machinery stays.

### 2.2 Address monitors by task name

The gem already knows the task name; it reads it from `recurring.yml` to register
the monitor in the first place. Using it as the address means nothing is fetched,
nothing is cached, and nothing goes stale.

**Why delete rather than repair.** The ordering bug in §1 is about ten lines to
fix. The reason not to: the rejected-request path had tests and the no-address
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
| `register_on_boot` and its read-only variant | — | A second startup network call |

About 110 lines of 680, but the count understates it: this is most of the hard
reasoning in the gem — swapping an immutable snapshot under a lock, guaranteeing
readers never block, throttling re-fetches against a clock that cannot run
backwards. The gem's main test file is 583 lines and every test has to supply a
fake address map.

### 2.3 Put the credential in a header

An earlier draft followed Healthchecks.io and put the ping key in the URL path.
That is right for them — their clients are `curl` invocations in any language and
a single pasted string is their onboarding. A URL-borne credential is charged four
costs a header is not:

- **It is written to logs.** Rails logs request paths verbatim and filters only
  query strings, so it lands in every request log, proxy log and error report.
- **`GET` becomes dangerous.** A check-in is not a read: it advances the monitor's
  clock and, if the monitor is down, resolves the incident and sends a "recovered"
  email. With the credential in a URL, anything that follows a link — chat
  previews, mail providers pre-fetching, antivirus scanners — can fire one. This
  endpoint is `POST` only.
- **It is not a normal REST resource.** Creating a check-in for a monitor is
  `POST …/monitors/{id}/pings`, which is what it now is.
- **Two specific faults never get written** — the rate-limiter fault in §3.5 and
  the URL-parsing fault in §3.2, both of which come from having a credential and a
  task name as adjacent path segments.

The price is one flag: `curl -X POST -H "Authorization: Bearer sm_ping_…"`.

### 2.4 Registration stays a separate call from the check-in

Healthchecks lets a check-in create the monitor if it does not exist
(`?create=1`). It does not transfer:

- **There is nowhere honest to get the schedule from.** If the check-in carries
  the interval and grace, every check-in becomes a settings write and bypasses
  `gem_may_write?`. If they come from a default, a daily job is alerted on hourly.
  Worse, a monitor created that way has no record of what the gem last sent, which
  traps it permanently in the branch of that logic which refuses the first update
  — so the wrong interval sticks.
- **It would throw away the reasons.** Registration returns "we could not register
  this job, and here is why" — over the plan limit, malformed — and the command
  prints each one. A check-in endpoint returns a status code.
- **It would disable the check that catches two apps sharing one project's
  credentials**, which only runs during registration.
- **Counting monitors against the plan limit needs a per-user lock**, which does
  not belong on the highest-volume endpoint in the system.

## 3 · Server design

### 3.1 The `PingKey` model

Stored exactly as `ApiKey` is: a SHA-256 digest plus the last four characters for
a masked list, with the raw value shown once at creation and never recoverable.

```
app/models/ping_key.rb              # the model
app/models/ping_key/issuance.rb     # PingKey.issue(project:, name:) -> [key, raw]
```

Columns mirror `api_keys`: `project_id`, `name`, `token_digest` (unique),
`token_last4`, `last_used_at`, timestamps. The raw format is `sm_ping_` followed
by 32 random characters — a **different prefix** from `sm_live_`, so a key pasted
into the wrong slot fails immediately and secret scanners can tell them apart.

Nothing needs to reconstruct the key after issuance, which is what makes hashing
possible. The command holds it in the host's own config and prints ready-to-paste
`curl` lines itself (§4.2), so the web interface never needs to show it.

*(An earlier draft made this column readable, then encrypted, so a setup card
could show a finished command. Both are dropped. Encrypting one column while
`pg_dump` output sits in object storage for eight weeks with password digests and
Stripe identifiers beside it protects nearly the least sensitive thing in the
file. Encrypt the backup instead — that is a separate, larger, and more useful
piece of work.)*

**Rotation** is: issue a second key, deploy it, watch the first key's `last_used_at`
stop moving, revoke it. Because you add before you remove, nothing breaks in
between — which is also why shown-once is affordable. A lost key has a cheap
remedy.

**This must not be a "type" column on `api_keys`.** Authentication looks a token up
across the whole table. With one table a ping key would authenticate the
management API unless every lookup remembered to filter by type, and forgetting is
silent and permissive — the worst possible default in security code. Two tables
make the mistake impossible rather than discouraged.

**Shared hashing, separate policy.** The existing authentication code is two
methods referencing nothing specific to API keys: hash the token, find it by hash,
compare, record usage. Copying it wholesale means a future fix applied to one copy
and not the other. Extract only the mechanical part — hash, and find by hash with
the constant-time comparison and the comment explaining why it is there. Each
model keeps its own authentication method for its own rules; see §3.4 on usage
recording.

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

**Declare it standalone, not nested.** Nesting `resource :pings` inside
`resources :monitors, param: :registration_key` is wrong three ways, all verified
against this app's router:

- `param: :registration_key` also changes **`show`**, so `GET /api/v1/monitors/42`
  arrives as `registration_key: "42"` while `find_monitor` still reads
  `params[:id]` — a silent breaking change to an endpoint this work has no reason
  to touch.
- Rails prefixes a nested parent's parameter, so the segment is really
  `:monitor_registration_key`, and the constraint names a segment that does not
  exist.
- With the constraint inert, dotted task names break anyway.

**The constraint and `format: false` are both required**, because Rails excludes
dots from dynamic segments and treats a trailing `.foo` as a format. Verified:

```
GET  /api/v1/monitors/42                        => show,   id: "42"          (unchanged)
POST /api/v1/monitors/plain/pings               => create, registration_key: "plain"
POST /api/v1/monitors/reports.daily/pings       => create, registration_key: "reports.daily"
POST /api/v1/monitors/%E6%97%A5%E6%9C%AC/pings  => create, registration_key: "日本"
POST /api/v1/monitors//pings                    => RoutingError
```

One trap when testing: `recognize_path` resolves the controller class, so all of
these raise `RoutingError` until `Api::V1::Monitors::PingsController` exists,
which looks exactly like a broken route.

### 3.3 Authentication, and keeping tenants apart

The check-in controller must **not** inherit `Api::V1::BaseController`, which
authenticates API keys. It authenticates ping keys, resolves the project from the
key, and reaches the monitor only through that project:

```ruby
current_project.monitors.find_by(registration_key: params[:registration_key])
```

That scoping is not optional. Task names are unique only **within** a project and
they are ordinary words — `daily_digest`, `nightly_backup`. Different customers
will collide constantly; that collision is the whole reason projects exist. The
old ping token was unique across the entire database, so isolation was a property
of the schema. Now it is a property of the code, and needs two tests:

- The same task name in two projects; checked in with project A's key, project B's
  monitor must be untouched.
- **A ping key must be rejected by every other `/api/v1` endpoint, and an API key
  rejected by this one.**

Not inheriting the base controller is also what makes §3.5 possible: `rate_limit`
compiles to a `before_action` holding an anonymous lambda, so a subclass cannot
skip an inherited limiter through the ordinary API.

### 3.4 The pings controller

Most of the existing public controller disappears, because an authenticated
endpoint does not need limiters keyed on a URL secret, deliberately uninformative
404s, or reasoning about which tenant a request belongs to. What moves across: the
guard against oversized duration values, the guard against array-shaped
parameters, and the success-or-failure rule reading `status` and `message`.

**Record ping-key usage coarsely.** `ApiKey::Authentication` writes `last_used_at`
on every authentication. A ping key is authenticated after every job in the
project, so an unconditional write would queue a tenant's concurrent check-ins
behind one row and turn every check-in into two writes. Rotation still needs the
signal, so write it only when the stored value is more than five minutes old.

Worth applying the same coarsening to `ApiKey` while here — it has the same
unconditional write and its only reader is a "Last used" column.

### 3.5 Rate limiting

Count per **monitor**, keyed on values readable *before* authentication runs:

```ruby
by: -> { "#{request.authorization.presence || request.remote_ip}|#{params[:registration_key]}" }
```

`rate_limit` installs an ordinary `before_action`, so the limiter runs before the
credential is resolved. Both values above are available then; a
`@current_ping_key` ivar is not. Two ways to get this wrong, both measured through
a real request stack:

- **`by: -> { @current_ping_key }`** — the ivar is `nil`, and Rails builds the key
  with `["rate-limit", scope, name, by].compact.join(":")`. `.compact` **drops the
  nil rather than distinguishing it**, so the whole controller collapses to a
  *single* counter: three tenants and four task names shared one bucket, and an
  anonymous request could exhaust it for everyone.
- **`by: -> { "#{@current_ping_key}|#{params[:registration_key]}" }`** — `.compact`
  does nothing here, because the value is the string `"|alpha"`. Narrower but
  still wrong: one counter per task name, shared across every tenant using it.

Count per monitor rather than per key, or a project with more jobs than the limit
throttles itself into a false project-wide outage — and the gem treats the
resulting 429 as transient, so the symptom is a burst of false "down" alerts.

**Do not use the raw token as the counter key.** `Api::V1::BaseController:51`
currently keys on `request.authorization`, and Rails emits `by:` and the cache key
into an `ActiveSupport::Notifications` payload on every throttle event. Verified by
driving the real limiter past its ceiling:

```
:by        => "Bearer sm_live_xWGEOzS87Raa4ayskOST5S8F3YKZX8W5"
:cache_key => "rate-limit:api/v1/monitors:per-key:Bearer sm_live_xWGEOzS87Raa…"
```

That string is also the literal cache key written to the store, so the comment
there contemplating a move to Solid Cache would persist credentials to Postgres.
Key on a digest instead. Pre-existing defect; fix it rather than reproducing it on
the busiest endpoint in the system.

### 3.6 Error responses

The endpoint is authenticated, so the existing API conventions apply and the
deliberately uninformative responses go:

- Missing, unknown or revoked ping key → `401`, matching the rest of `/api/v1`.
- Valid key, unknown task name → `404`.

Distinguishing them is a gain, not a leak: the caller has already proved they hold
a credential for the project, so being told a task is unregistered reveals nothing
they could not learn from the monitors list. It also gives the gem the signal §4.3
needs.

### 3.7 What leaves the web interface

Creating a monitor moves entirely to the command, so the create path goes:
`MonitorsController#new` and `#create`, `resolve_project`, `new.html.erb`, and the
five `new_monitor_path` links. Editing stays — interval and grace overrides are a
documented feature — and `_form.html.erb` and `_preset_field.html.erb` are shared
with it, so they stay too. **The genuinely create-only surface is about 55 lines.**

The cascade is where the saving actually is. With one creator, every monitor is
gem-registered, so these become unreachable rather than merely unused:

| Becomes dead | Why |
|---|---|
| `Monitor::Transfer`, its controller and view | Its first line is `return … unless @monitor.manual?` |
| `awaiting_setup?` and the branch it drives | Defined as `manual? && !ever_pinged?` |
| The provenance chip | Every monitor has the same provenance |
| `from_gem?` / `manual?` / the `source` column | Constant |

**The cost, stated plainly: there is no browser-only path to seeing the product
work.** A new user must add the gem, deploy, run the command, and wait for a job
to fire. That is accepted — "job monitoring for Rails applications" means users
have Rails apps — but it puts weight on the first-run page, which currently links
to the gem guide with a placeholder `"#"`. That link has to become real, and it is
now the only onboarding route in the product.

`registration_key` needs a **backfill** for existing hand-created monitors, which
have `NULL` and would otherwise be unaddressable. Derive from the name; iterate in
a deterministic order carrying a set of keys already taken in this run, or later
rows collide with ones assigned moments earlier. Four edge cases, all reproduced:

- **Do not use `String#parameterize`** — it strips non-Latin characters entirely,
  so a monitor named 日本語のジョブ derives an empty key. That contradicts §3.2,
  which supports unicode task names. Strip only `/` and surrounding whitespace.
- Duplicate names within one project are common; all but the first need a fallback.
- A name of `"!!!"` or `"   "` derives to blank — `name` is `NOT NULL` but not
  non-blank.
- `monitor-<id>` is not collision-proof either; suffix and retry.

**Leave the column nullable for now.** Making it `NOT NULL` costs roughly 215 test
fixes — 3 of the 4 monitor fixtures have no key, and ~95 `monitors.create` call
sites in `test/` pass none — and buys little while `Project::MonitorSync` is the
only writer, and it already drops blank keys before doing anything else. Add the
constraint when a second writer appears.

### 3.8 Interface additions

The project page gains a ping-key section mirroring the API-key one exactly:
issue, show once in the existing dialog, list masked, revoke, all scoped so
another user's project returns 404, with the keys loaded in the shared
project-page module alongside API keys — that module exists precisely so the page
and the issuing action cannot drift apart.

The existing shown-once dialog hardcodes "API key" in its heading, label and test
identifier. Pass those in as parameters rather than duplicating the file.

## 4 · Gem design

### 4.1 What is added

- A `ping_key` setting, defaulting to the `STABLEMATE_PING_KEY` environment
  variable, matching how the server address already works.
- A `monitors` setting for non-Rails-job monitors (§2.1).
- Check-in and failure-report requests built against
  `/api/v1/monitors/{task}/pings` with a bearer header, reusing the header helper
  registration already uses. The task name is URL-encoded.

### 4.2 The command

`bin/rails stablemate:sync` keeps its job and gains one: after registering, it
prints a ready-to-paste `curl` line for each monitor, using the ping key from the
host's own config. This is what makes the shown-once key affordable — the place
that needs a finished command already holds the credential legitimately.

It returns a count rather than the deleted address map. One trap: with no tasks at
all it currently returns an empty map, so the task prints "synced 0". A
replacement returning `nil` would silently turn that into a failure message.

Registration failures should `abort` — the command runs by hand or from a deploy
script, where a non-zero exit is useful.

### 4.3 Check in only for tasks we could actually register

Today, when a job class is not listed in `recurring.yml`, the gem falls back to
the class name as the task name — but **only if the server previously gave it an
address for that name**. The cache is quietly acting as a server-approved list of
what exists.

Remove the cache and an address becomes constructible for *any* string. The gem
would then check in after every successful run of every job class in the host app
— mailer jobs, file-analysis jobs, every one-off background job.

The cache also does a second job nobody documented. The gem builds two lists from
`recurring.yml`: every task with a job class, and the narrower set whose schedule
it can actually work out. Tasks in the first but not the second — one scheduled
for 30 February, say — are never registered, have no address, and are silently
dropped. So: **build the list of reportable tasks from the narrower one**, plus
anything declared in `c.monitors`. "Could we work out this schedule?" becomes an
explicit condition rather than an accident of a missing cache entry.

### 4.4 Act on the response, and boot

The server distinguishes a bad credential from an unregistered task, so the client
should too:

- `401` — the ping key is wrong or revoked. Log **once**, loudly.
- `404` — this task is not registered. Log **once per task name**, naming the
  remedy: run `bin/rails stablemate:sync`. This is the signal that catches "I
  added a job and forgot to register it", which is the failure mode CLI-only
  registration introduces.
- Anything else, or a transport failure — transient, absorbed by the grace period.

Logging once matters: the current code logs on every check-in, which is how a
message gets filtered out as noise. "Once" is per-process state read and written
from background dispatch threads, and this spec deletes the gem's only mutex, so
it needs its own guard — do not assume `Set#add?` is atomic.

**Boot now does one thing: attach the listener.** No network, no registration:

```ruby
config.after_initialize do
  next unless Stablemate.config.enabled_in?

  if Stablemate.config.ping_key
    registrar = Registrars::SolidQueueRecurring.new   # local YAML only
    Execution::Subscriber.new(class_to_keys: registrar.class_to_keys).subscribe!.subscribe_discards!
  else
    Stablemate.logger.error("[stablemate] no ping_key configured — check-ins are DISABLED …")
  end
end
```

The `api_key` gate goes, since nothing at boot needs it. Nothing blocks this: the
registrar reads `recurring.yml` locally and builds its class map with network
access banned outright (verified by making `TCPSocket` raise).

Two things this does not solve on its own. The environment allow-list is still a
gate above everything and defaults to production only, so a developer booting
locally sees nothing — decide whether the missing-credential error logs above that
gate or below it, and prefer above. And the YAML parse still raises inside the
block, so §6.4 needs its own rescue and the listener has to tolerate an empty
class map.

There is **no railtie test anywhere in the gem suite**, which is why the `api_key`
gate went unnoticed. Add one.

### 4.5 Health

Add a `Stablemate.health` reader exposing the last registration error, the time of
the last successful check-in, and any task names that came back `404`, so "are my
check-ins arriving?" can be answered from a console or a health check. Nothing
about building addresses locally makes anything visible by itself.

## 5 · Sequencing

**There is no migration to manage.** The gem's only consumer, and the only live
account, is a side project the maintainer owns. Server and gem ship together. No
version negotiation, no waiting period, no gem supporting both schemes. The gem's
version goes to `0.2.0` because its public interface changes.

The shared address map and the ability to construct the listener with your own
addresses are documented for hand-wiring. Pre-1.0 with no third-party users, so
they are simply removed.

Two ordering constraints:

1. **Backfill `registration_key` before the check-in route ships** — until then,
   hand-created monitors have no address.
2. **Every live monitor currently checks in through a ping-token URL.** Once that
   route is gone, anything still using it goes overdue and emits one false `down`
   email at its grace boundary. Update the gem and any shell crons in the same
   window, or pause the monitors across it.

Worth checking first, since task names are about to become part of a URL:

```sql
SELECT count(*) FROM monitors WHERE registration_key IS NULL;
SELECT id, project_id, registration_key FROM monitors
WHERE registration_key ~ '[^A-Za-z0-9_.\-]';
```

With the §3.2 constraint in place, only a `/` in a task name is genuinely fatal.

## 6 · What this does not fix

### 6.1 Alerts still point at the wrong system

A wrong ping key, a DNS failure, a blocked outbound connection, a rate limit — in
every case the server sees silence and the email says the job "missed its
check-in". **This changes how check-ins are addressed, not what silence means.**

Separate, parallel work. Three signals, cheapest first:

- **Notice the app is still talking to us.** The API key already records when it
  was last used, on every registration — and nothing reads it. "This app
  registered three minutes ago but no monitor has reported for an hour" is a
  *positive* statement with no false positives: the app is running and can reach
  us, so it is the check-ins specifically that are not arriving. Works with a
  single monitor.
- **Alert on monitors that have never checked in.** Detection only considers
  monitors marked up, so a registered monitor that has never received a check-in
  is invisible to it **forever** and produces no alerts at all. Under CLI-only
  registration this is also what a confused new user hits. Threshold relative to
  the monitor's own interval, fires once, distinct wording pointing at setup docs.
- **Notice a whole project going quiet.** Not "every monitor is down" — monitors go
  overdue in order of how often they run, so waiting for all of them means waiting
  for the slowest. The useful test is: the most recent check-in anywhere in the
  project is older than the shortest interval-plus-grace in it. Needs somewhere to
  record a project-level incident, and says nothing about a project with one
  monitor.

The wording rule: **say what was observed, never what it means.** "No monitor in
project Foo has reported since 14:02" is true whether the cause is a firewall, a
crashing worker or a deliberate shutdown. "Your network is blocked" is a new way
to be wrong.

### 6.2 Two credentials that can disagree

Nothing forces the API key and ping key to belong to the same project. Use project
A's API key with project B's ping key and registration writes to A while check-ins
go to B; A's monitors go down permanently and every symptom reads as "your job is
down". A new kind of mistake, and permanent rather than transitional.

The guard: registration returns the last four characters of the project's ping
key, and the gem logs loudly at startup if the configured key does not match. No
escalation — an API key can already list every monitor in its project. Together
with §4.4's `401` handling this turns "wrong key, silent until the interval
elapses" — about 27 hours for a daily job — into one line at deploy time.

### 6.3 One leaked key exposes a whole project

A leaked ping key lets an attacker fake check-ins **and failure reports** for every
monitor in the project, where a leaked ping token affected one. Faking a check-in
on a monitor that is down does not merely suppress the alert — it resolves the
incident and sends a "recovered" email during a real outage.

Moving the credential into a header narrows this: it is no longer in request logs,
proxy logs or error reports, cannot be fired by a link preview, and will not
appear in a screenshot. What remains is that anyone who can read a host's
credentials or a crontab holds it. Bounded further by hashing at rest, by cheap
safe rotation (§3.1), and by the key having no capability except recording a
check-in.

### 6.4 The catch-all around gem startup

Untouched by any of this and needing the same treatment: narrow the catch-all so a
broken `recurring.yml` cannot silently leave the listener unattached for the life
of the process, and surface it through `Stablemate.health`.

### 6.5 An unrelated bug found while verifying the above

`Execution::Subscriber.install_discard_hook` can install its callback **twice**, so
every terminal job failure reports the error twice. The guard is
`return if @discard_hook`, but the line below it —
`::ActiveJob::Base.respond_to?(:after_discard)` — autoloads `ActiveJob::Base`,
which re-entrantly fires the railtie's own `on_load(:active_job)` hook. At that
moment `@discard_hook` is still `nil`, so the guard does not fire. Measured:
`after_discard_procs.size == 2`, same source location, different object ids.

Load-order dependent, which is why it has not been noticed. Fix by assigning
`@discard_hook` before touching `::ActiveJob::Base`.

## 7 · Test plan

- **Browser test: ping keys.** Issue one from the project page, see it once, see it
  masked afterwards, revoke it.
- **Browser test: the monitor lifecycle without creation.** A registered monitor
  can still be edited, paused and deleted, and the create route is gone (§3.7).
- **Credential separation.** A ping key rejected by every other `/api/v1` endpoint,
  and an API key rejected by the check-in endpoint (§3.3).
- **Tenant isolation.** The same task name in two projects; checked in with project
  A's key, project B's monitor untouched (§3.3).
- **Rate limiting, both directions.** Two task names under one ping key must not
  share a counter, **and two ping keys on the same task name must not share one** —
  the second is what catches a lambda reading post-authentication state, and the
  first alone would pass a broken implementation (§3.5).
- **Routing.** A task name containing a dot arrives intact (§3.2).
- **Backfill.** Duplicate names in one project, a name deriving to blank, and a
  non-Latin name each produce a distinct, usable, slash-free key (§3.7).
- **Gem: unlisted job classes never check in** under the new task list (§4.3).
- **Gem: a task with an unworkable schedule never checks in** (§4.3) — the
  containment the cache was doing by accident.
- **Gem: boot attaches the listener with a ping key and no API key** (§4.4). This
  fails today.
- **Gem: no ping key** — nothing sent, one error line (§4.4).
- **Gem: `401` and `404` handled differently**, each logged once (§4.4).
- **Command: registration failure exits non-zero** and prints the reasons the
  server gave (§4.2).
