# Ping architecture — the split-credential redesign

Status: **proposed**, not yet built. Replaces the current scheme, where the gem
fetches its ping URLs from the server at boot and holds them in memory.

---

## Summary

On 1 August 2026 a host app deployed normally. One network call during startup
timed out. From that moment the app stopped reporting to Stablemate entirely, and
kept not reporting until it was restarted. Four healthy jobs were reported as
down. The jobs were fine — the monitoring was broken, and the alerts blamed the
jobs.

The cause is that the gem learns where to send its pings by asking the server at
startup, then remembering the answer. If that one call fails, it has no addresses
to send to, and nothing ever makes it ask again.

**The proposal is to stop asking.** Instead of fetching addresses, the gem builds
them itself from settings it already has. To do that safely it needs a new
credential — a "ping key" — which can record check-ins and nothing else.

Two things follow. First, roughly 110 lines of the most delicate code in the gem
get deleted, including all of its shared-between-threads state. Second, a failed
startup call can no longer stop pings, because pings no longer depend on it.

**What this costs.** A ping key covers a whole project rather than a single
monitor, so if one leaks, an attacker can fake check-ins for every job in that
project — including faking a recovery during a real outage. That is a real
downgrade from today and we are accepting it knowingly (§7.3). It is the same
trade Healthchecks.io and Cronitor both make.

**What this does not fix.** If pings stop arriving for any reason, Stablemate
still reports "your job is down" — which is exactly the misleading alert that made
the incident painful. Fixing that is separate work, described in §7.1 and being
done in parallel.

---

## The three credentials

There are already two credentials, and this adds a third. They are easy to
confuse, so:

| | What it is for | Who holds it | Scope | Stored as | Where it appears |
|---|---|---|---|---|---|
| **API key**<br>`sm_live_…` | Managing monitors: listing them, registering them from `recurring.yml`, rotating ping tokens | The gem, in the host app's credentials | One project | A hash — the real value is shown once and never recoverable | An `Authorization` header. Never in a URL |
| **Ping token**<br>32 random characters | Recording a check-in for **one** monitor | Whoever runs the job — often a crontab | One monitor | Plain text, because the dashboard has to display the URL | In the URL. Copy-pasted from the dashboard |
| **Ping key** *(new)*<br>`sm_ping_…` | Recording a check-in for **any** monitor in a project | The gem, in the host app's credentials | One project | A hash — shown once | In the URL, built by the gem |

The point of adding a third rather than reusing the first: the API key can read
and rewrite every monitor you own. The gem sends a request after every single job
run, and we do not want a credential that powerful on a path that busy. The ping
key can only say "this job ran".

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

The gem does have a repair mechanism: if a ping comes back rejected, it re-fetches
its addresses. But that mechanism only runs *after* a ping has been sent — and a
ping can only be sent if an address was found. **The repair is behind the door it
is meant to open.** With no addresses, no ping is sent, so nothing is rejected, so
nothing is repaired. There is no way out of that state short of restarting the
process.

It is also worse under the host's setup, where the job supervisor runs inside the
web server. The supervisor copies its memory to each worker it starts, so one
failed startup call is inherited by all of them.

Two corrections to the original incident write-up:

- **It was not completely silent.** The startup failure does log one line, but to
  standard error rather than the Rails log, unless the host has configured
  otherwise. The signal existed once, in a place nobody was looking.
- **There is a second, worse version of the same bug.** The gem's startup code
  wraps everything — reading `recurring.yml`, registering monitors, attaching the
  job listener — in a single catch-all. If `recurring.yml` has a YAML syntax
  error, the listener is never attached at all: no success pings *and* no failure
  reports, one warning, no recovery. Deleting the address cache does not touch
  this. §7.4 covers it.

## 2 · The decision: delete the mechanism rather than repair it

The gem will build ping URLs itself:

```
POST or GET   {endpoint}/ping/{ping_key}/{registration_key}
```

Both halves are already on hand: the ping key comes from the host app's
configuration, and the `registration_key` is the task name from `recurring.yml`.
Nothing is fetched, so there is nothing to cache, nothing to go out of date, and
no repair mechanism to get stuck behind.

### Why delete rather than fix

The ordering bug in §1 is about ten lines to fix. The reason not to just fix it:
the rejected-ping path had tests, and the no-address path had none — because
nobody thought of it. You cannot write a test for a failure you have not imagined,
but you can remove the code where that class of failure lives.

What goes:

| Removed | ~Lines | Why it mattered |
|---|---|---|
| The shared ping-URL map and the lock protecting it | 25 | The gem's only state shared between threads |
| The re-fetch mechanism, its throttle, mutex and timer | 25 | An entire recovery protocol |
| The two methods that populate the map | 21 | |
| The "list my monitors" API call and the "address rejected" response state | 20 | Only exist to serve the cache |
| The startup wiring that ties them together | 8 | |
| The read-only variant of startup registration | — | A second network call during startup |

That is about 110 lines out of 680, but the count understates it: this is most of
the genuinely hard reasoning in the gem — swapping an immutable snapshot under a
lock, guaranteeing readers never block, throttling re-fetches against a clock that
cannot go backwards. The gem's main test file is 583 lines and *every single test*
has to supply a fake address map.

**Some complexity moves to the server** — one model, one route, one extra database
lookup. That trade is the point: state shared between threads with a recovery
protocol, exchanged for an indexed lookup in Postgres.

### 2.1 Why not just reuse the API key

The gem could ping a header-authenticated endpoint with the API key it already
has. No new credential, no new configuration. This is the strongest alternative
and it was rejected for three reasons:

- Authenticating the API key writes a "last used" timestamp to its database row.
  On the ping path that becomes a database write on one shared row after **every
  job completion**, from every worker.
- The management API allows 120 requests a minute across a whole project; the ping
  endpoint allows 30 a minute per monitor. A project with twenty jobs that all run
  on the hour would throttle itself.
- The API key can read every monitor, bulk-rewrite them, and rotate ping tokens.
  Putting it on the busiest path means it ends up in far more proxy and monitoring
  logs, and a leak costs the whole project.

### 2.2 Two places we deliberately differ from Healthchecks

**We are not copying `?create=1` (create a monitor on its first ping).**
Healthchecks does this and it is genuinely good for them. It does not transfer:

- **There is nowhere honest to get the schedule from.** A monitor needs an
  expected interval and a grace period. If the ping carries them, then every ping
  becomes a settings write, and it bypasses the careful logic that stops a
  redeploy overwriting an interval a user tightened by hand. If they come from a
  default, a job that runs daily gets alerted on hourly. Worse: a monitor created
  this way has no record of what the gem last sent, which permanently traps it in
  the branch of that logic that refuses the first update — so the wrong interval
  sticks.
- **Filling someone's monitor limit is a cheaper attack than faking pings.** Five
  requests fill a free account. The next real registration then reports every
  genuine job as rejected for being over the limit, and the victim is unmonitored
  while the interface tells them to buy more slots. On self-hosted installs there
  is no limit at all by default, so it is unbounded row creation from a URL.
- **`GET` works on this endpoint**, so an image tag in an email would create
  monitors via any link scanner or chat-app link preview. A `GET` that changes
  data is exactly what browsers and scanners assume cannot happen.
- It would need a per-user lock to count monitors correctly, on a public,
  unauthenticated, high-volume endpoint.
- It would disable the check that catches two apps sharing one project's
  credentials, because that check only runs during registration.
- It would throw away the "we could not register this job, and here is why"
  messages that registration returns and the gem logs. A ping endpoint returns
  only a status code.

So registration keeps its job as the **settings channel** — it has a response
body, and settings need one. A ping carries a single fact and gets no reply worth
reading. The important change is that pings no longer *depend* on registration, so
a failed registration is harmless.

**The ping key is shown once and stored only as a hash, unlike Healthchecks',
which is permanently visible in their dashboard.** The obvious objection is that
if you lose it you have to rotate, and rotating a credential that lives in every
deployed config file is dangerous. That is answered by allowing **several live
ping keys per project** (§3.1): create a second one, deploy it, watch the old
one's "last used" timestamp stop moving, then delete it. Because you add before
you remove, nothing breaks mid-rotation — and once rotation is safe, storing only
a hash costs nothing and a database leak yields nothing usable.

There is a useful side effect. Because the key cannot be displayed, the monitor
page shows a template instead of a finished URL:

```
POST https://stablemate.dev/ping/$STABLEMATE_PING_KEY/daily_digest
```

That nudges people toward putting the key in an environment variable rather than
pasting it into a crontab that ends up committed to a config repository — which is
the most likely way it would leak in the first place.

## 3 · Server design

### 3.1 The `PingKey` model

**A table, not a column on `projects`.** Safe rotation needs two keys valid at
once, plus a way to tell whether anything is still using the old one. A single
column cannot hold two values, and a design that cannot rotate safely should be
rejected on that alone.

```
app/models/ping_key.rb              # the model
app/models/ping_key/issuance.rb     # PingKey.issue(project:, name:) -> [key, raw token]
```

Columns mirror `api_keys`: `project_id`, `name`, `token_digest` (unique),
`token_last4`, `last_used_at`, timestamps. The raw format is `sm_ping_` followed
by 32 random characters — a **different prefix** from `sm_live_`, so a key pasted
into the wrong configuration slot fails immediately and automated secret scanners
can tell them apart.

The migration follows the pattern of the projects migration, **including its
correction note**: production has real data, so add the column nullable, backfill
every project, then enforce not-null and add the unique index. Written with
explicit `up` and `down` so it can be rolled back.

**This must not be a "type" column on the existing `api_keys` table.**
Authentication looks a token up across the whole table. With one table, a ping key
would authenticate the management API unless every single lookup remembered to
filter by type — and forgetting is silent and permissive, which is the worst
possible default in security code. Two tables make the mistake impossible rather
than merely discouraged.

**Shared hashing, separate policy.** The existing authentication code is two
methods that reference nothing specific to API keys: hash the token, look it up by
hash, compare, record usage. Copying it wholesale means a future fix applied to
one copy and not the other — a silent divergence in security-critical code.

So extract only the mechanical part into a shared module: hash a token, and find a
record by that hash (with the redundant constant-time comparison and the comment
explaining why it is there). Each model keeps its own authentication method
holding its own rules — the API key records usage on every lookup, the ping key
does not (§3.4). A single shared method with a `record_usage:` switch is rejected
for the same reason as the type column: it can be forgotten.

### 3.2 The route

```ruby
match "/ping/:ping_key/:registration_key", to: "pings#create", via: %i[get post],
      constraints: { registration_key: %r{[^/]+} }, format: false, as: :keyed_ping
match "/ping/:ping_token", to: "pings#create", via: %i[get post], as: :ping
```

**That constraint is mandatory.** Rails treats a dot in the last part of a URL as
a file extension. Tested against this app's own router:

```
# without the constraint
/ping/KEY/reports.daily  =>  registration_key: "reports", format: "daily"
# with it
/ping/KEY/reports.daily  =>  registration_key: "reports.daily"
```

Task names come from a user's `recurring.yml` and nothing validates their format
anywhere in the app. Without the constraint, a task called `reports.daily` would
check in **a different monitor in the same project** — silencing the wrong job's
alerts — and the URL helper would generate exactly the address the router cannot
read back. The gem must also URL-encode the task name when building the address.

Also tested: the one-segment and two-segment routes cannot collide, because a
Rails URL segment never spans a `/`. Declaration order does not matter. But
`/ping/KEY/` with a trailing slash matches the **one-segment** route and returns
404. That is left as-is — a trailing slash is a typo and 404 is the right answer.

Run the check in §5 before this ships.

### 3.2.1 This URL is not RESTful, and that is deliberate

Our own conventions say to find the noun hiding in the verb and to route
everything as a standard resource. This URL breaks that in four ways. Three are
intentional; naming them here is the justification our conventions require.

**`/ping` reads as a verb.** Cosmetically true. The controller is already
`PingsController#create`, so the internal shape is correct and only the path
segment reads wrongly. Renaming it to `/pings` would invalidate every ping URL
currently sitting in a customer's crontab, for no functional gain. Not worth it.

**The credential is in the path rather than an `Authorization` header, and it
identifies the monitor rather than merely proving who is asking.** The RESTful
form would be `POST /monitors/{id}/pings` with a header. Compare what an operator
has to paste:

```sh
curl -fsS https://stablemate.dev/ping/KEY/daily_digest
curl -fsS -X POST -H "Authorization: Bearer KEY" https://stablemate.dev/projects/7/monitors/daily_digest/pings
```

The second is correct and nobody would use it. One copy-pasteable string that
works with no flags *is* the interface, and many of the places it gets used —
minimal containers, basic schedulers, health-check probes — cannot set headers at
all. Every comparable service made the same choice: Healthchecks, Cronitor, Sentry
and Dead Man's Snitch all put the credential in the URL.

The cost is that the credential appears in the path, and Rails logs request paths
verbatim — only query strings are filtered. So ping credentials are already in
production logs today, and will be under the new scheme too. That is unchanged by
this redesign, but §7.3's larger reach makes each logged line worth more.

**`GET` changes state, and this one has a consequence worth stating plainly.**
HTTP treats `GET` as safe, and anything that follows a link will issue one: chat
apps generating link previews, mail providers rewriting and pre-fetching links,
antivirus scanners, browser prefetch. A ping is not a read — it records a
check-in, advances the monitor's clock, and **if the monitor is currently down it
resolves the incident and sends a "recovered" email.** Paste a ping URL into a
chat channel during a real outage and you will be told the outage is over.

We keep `GET` anyway, because removing it means every user writes `curl -X POST`,
and no comparable service asks that. The mitigations are:

- Treat a complete ping URL as a password, and say so next to the copy button on
  the monitor page — not merely in the docs.
- The gem path is less exposed by construction: because the ping key is shown once
  (§2.2), the monitor page displays a `$STABLEMATE_PING_KEY` template rather than
  a working address, so a screenshot or pasted snippet of it cannot be fired. The
  per-monitor token URL is displayed complete, so the risk remains there.

**Possible follow-on, not proposed here.** Healthchecks serves pings from an
entirely separate domain (`hc-ping.com`, distinct from `healthchecks.io`). That is
not about REST, but it addresses the same instinct: session cookies never reach
the ping host, its request logs can be configured separately from the app's — which
matters when credentials are in the path — and rate limiting can be tuned
independently. The cost is another DNS record, another certificate and more deploy
configuration. Worth knowing about; not worth doing yet.

### 3.3 Keeping tenants separate

Today a ping token is unique across the entire database, so a ping can only ever
reach one monitor — that is a property of the schema, not of anyone remembering to
do the right thing.

Task names are only unique **within a project**, and they are ordinary words:
`daily_digest`, `nightly_backup`. Different customers will use identical names
constantly — that collision is the whole reason projects exist.

So the schema no longer guarantees isolation and the code has to. The rule:
**identify the project first, then reach the monitor only through that project.**

```ruby
PingKey.authenticating(params[:ping_key])&.project&.monitor_for(params[:registration_key])
```

A test proving the same task name in two different projects never crosses over is
**mandatory**, matching the equivalent discipline already applied to the
management API.

### 3.4 The pings controller

The controller is about 100 lines today: two rate limiters with long explanatory
comments, a guard against oversized duration values, a guard against
array-shaped parameters, and the success/failure rule. Adding
`if params[:ping_key]` on top of that is exactly the sprawl our own conventions
warn against.

But splitting it in two is also wrong: both URL forms record *the same thing*. The
only difference is how the monitor is identified. So:

1. Move the existing bulk into a shared module — the rate limiters, the parameter
   guards, and a single `record_ping(monitor)`. There is precedent for this in two
   other controller concerns already in the app.
2. Keep **one** action, whose monitor lookup is a two-line branch.

No dedicated lookup class. A class whose entire body is one `if` is not worth
creating.

**The ping key does not record usage on every request.** An API key is
authenticated a handful of times per deploy; a ping key would be authenticated
after every job in the project, so writing a timestamp each time would put every
one of that tenant's concurrent pings in a queue behind one database row, and turn
every ping into two writes. Rotation still needs the signal, so write it coarsely
— only when the recorded time is more than five minutes old.

### 3.5 A real bug in the original proposal: rate limiting

The current limiter counts requests per ping token. On the two-segment route there
is no ping token, so that value is `nil` — and Rails builds the counter's key like
this:

```ruby
# actionpack-8.1.3.1/lib/action_controller/metal/rate_limiting.rb:75
cache_key = ["rate-limit", scope, name, by].compact.join(":")
```

`.compact` **drops the nil entirely** rather than treating it as a distinct value.
Every new-style ping from every customer in the process would therefore share one
counter of 30 per minute. Once over, requests get a 429, which the gem treats as a
transient error and ignores — so the visible result is a burst of false "down"
alerts across unrelated customers. It would never show up in tests, because the
counter lives in memory per process.

The limiter must count per **monitor**, i.e. the ping key and task name together,
never the ping key alone — otherwise a project with more jobs than the limit
throttles itself into a project-wide false outage. This needs a test proving two
task names under one key do not share a counter.

The per-IP limiter is unchanged.

### 3.6 Identical responses for different failures

An unknown ping key, a valid key with an unknown task name, and a rate-limited
request all return the same 404 with no explanation. This is the existing
convention and it stays.

The cost is real: the gem cannot then tell "my key is wrong" from "this job is not
registered yet" — which is exactly the distinction §7 wants. We accept it, because
distinguishing them would let an attacker confirm a valid ping key and then guess
job names against it. We recover the signal on the client side instead (§4.3).

Worth being clear about one thing: the task name in the URL adds **no security**.
For any app whose source is inspectable, `recurring.yml` is public. This is one
secret plus a public label, not two secrets.

### 3.7 What "rotate" now promises

Both rotate actions currently promise the old URL stops working immediately, and
the confirmation dialog says so. With two URL forms live, rotating a monitor's
ping token leaves its ping-key URL working. That is a security control making a
promise it no longer keeps.

Fix the wording, not the behaviour: the confirmation must say the monitor is still
reachable via the project's ping key, and point to where ping keys are revoked.
Rotating the project key from a single monitor's page would take every other
monitor in the project offline at the same time.

### 3.8 Interface

Mirrors the existing API-key interface exactly: a controller that issues a key and
re-renders the project page with the shown-once dialog, a revoke action, both
scoped so another user's project returns 404, a list partial, and the keys loaded
in the shared project-page module alongside API keys — that module exists
precisely so the page and the issuing action cannot drift apart.

The existing shown-once dialog hardcodes "API key" in its heading, label and test
identifier. Pass those in as parameters rather than duplicating the file.

The monitor page gains the template form (§2.2) for gem-registered monitors, and
keeps the literal token URL for hand-created ones.

## 4 · Gem design

### 4.1 What is added

- A `ping_key` setting, defaulting to the `STABLEMATE_PING_KEY` environment
  variable — matching how the server address already works, so setup is one step
  rather than two.
- URL construction inside the HTTP client, with the task name URL-encoded.
- A startup check and log line when no ping key is configured (§4.4).

### 4.2 Ping only the tasks we could actually register

This is the one substantive change beyond deleting the cache, and it fixes an
existing latent bug rather than creating one.

Today, when a job class is not listed in `recurring.yml`, the gem falls back to
using the class name as the monitor name — but **only if the server previously
gave it an address for that name.** The cache is quietly acting as a
server-approved list of what exists.

Remove the cache and an address becomes constructible for *any* string. The gem
would then ping after every successful run of every job class in the host app —
mailer jobs, file-analysis jobs, every one-off background job — thousands a minute
into an endpoint that allows 300.

The cache is also silently doing a second job nobody documented. The gem builds
two lists from `recurring.yml`: one of every task with a job class, and a narrower
one of tasks it can actually work out a schedule for. Tasks in the first list but
not the second — a task scheduled for 30 February, say — are never registered, so
they have no address, so their pings are silently dropped. The same is true of
tasks the server refused to register.

So: **build the list of pingable tasks from the narrower list.** "Could we work
out this schedule?" becomes an explicit condition for pinging, rather than an
accident of a missing cache entry. There is an existing test that pins this
behaviour and it must stay green.

### 4.3 Keep the third response state, change what it means

Under the new scheme a 404 means either the ping key is wrong, or no monitor
exists for that task name. Neither is fixed by re-fetching addresses — but both
are exactly the failures this redesign exists to make visible, and the 404 is the
**only** signal the gem will ever get.

Collapsing the client's response handling to just "worked" and "failed" would put
"your credential is wrong" in the same bucket as "the server had a blip", which is
transient and correctly ignored.

So keep three states, rename the third to `:rejected`, and change what happens:
log **once per task name** — the current code logs on every single ping, which is
how a message gets filtered out as noise — with wording that names the two real
causes rather than the now-impossible "token was rotated".

Add a `Stablemate.health` reader exposing the last registration error, the time of
the last successful ping, and any rejected task names, so "are my pings arriving?"
can be answered from a console or a health check. Nothing about building URLs
locally makes anything visible by itself — this has to be built on purpose.

### 4.4 When no ping key is configured

Neither crash nor quietly carry on.

**Do not crash at startup.** The gem's one absolute rule is that monitoring must
never break the app it monitors. Raising during startup would take down every web
worker in a rolling deploy of someone's revenue-generating app because their
monitoring configuration was stale. That trade is never worth it.

**Do not fall back to the old fetch-and-cache path.** That keeps the bug, keeps
the code we are deleting, and means nobody ever moves across.

Instead: the `stablemate:sync` task — run by hand or from a deploy script, where a
non-zero exit is useful — exits with an error. Startup logs at **error** level
(not warning, the level everything else uses, where it would be invisible) and
skips ping delivery entirely:

```
[stablemate] no ping_key configured — pings are DISABLED and every monitor in
this project will alert as DOWN within one interval + grace. Add
`c.ping_key = Rails.application.credentials.dig(:stablemate, :ping_key)` to
config/initializers/stablemate.rb (or set STABLEMATE_PING_KEY). Find it at
<endpoint>/projects → your project → Ping key. Registration still works without it.
```

What will happen, how to fix it, where to get the value, and what still works.

### 4.5 The `register_on_boot` setting survives, and gets simpler

The original proposal bundled this with the cache, but they are separable. The
map of job classes to task names is read from the local `recurring.yml` and needs
no network access at all. So:

- `true` → register monitors at startup, as now.
- `false` → **nothing happens at startup** except attaching the job listener.
  Pings still work for every task in `recurring.yml`, because the address is built
  locally.

That is strictly better than today, where turning registration off merely swapped
one startup network call for a different one on the same fragile path.

### 4.6 What `sync!` returns

Today it returns the address map, and the rake task prints `"synced N monitor(s)"`
using its size. Without a map it needs something else to count — the number of
monitors the server reported registering. One trap: when there are no tasks at all
it currently returns an empty map, so the task prints "synced 0". A replacement
that returns `nil` would silently turn that into a failure message.

## 5 · Sequencing

**There is no migration to manage.** The gem's only user is a side project the
maintainer controls, so it is updated at the same time. Server and gem ship
together, and a broken moment in between costs one redeploy of an app we own.

That removes what would otherwise be the most expensive part of this work: no
version negotiation, no waiting period to prove the old path is unused before
deleting it, no gem that supports both schemes, no deprecation window.

Two things look like compatibility concessions but are not, and therefore stay:

- **The token URL form is kept** — for hand-created monitors, not for
  compatibility. See §7.5.
- **The ping-key cross-check** (§7.2) — it guards a permanent mistake, not a
  temporary one.

The only ordering that matters: run the server migration before pointing a gem at
the new route.

One thing worth checking against production first, since task names are about to
become part of a URL:

```sql
SELECT id, project_id, registration_key FROM monitors
WHERE registration_key ~ '[^A-Za-z0-9_.\-]';
```

Any result is a monitor whose new-style URL would not survive a round trip. With
the §3.2 constraint in place, only a `/` in the name is genuinely fatal.

## 6 · Things removed from the gem's public interface

The shared address map and the ability to construct the job listener with your own
addresses are documented for people wiring the gem up by hand. The gem is
pre-1.0 with no third-party users, so they go without ceremony.

The README's "manual fallback" section is deleted. What it describes — creating a
monitor by hand whose registration key matches a job class name — is **already
impossible**: the monitor form does not accept a registration key, and the
registration endpoint is the only thing that writes that column. It is a
documented feature that does not work. Anyone who wants it gets explicit
configuration instead.

## 7 · What this does not fix

### 7.1 Alerts still point at the wrong system

A wrong ping key, a DNS failure, a blocked outbound connection, an interfering
proxy, a rate limit — in every case the server sees silence and the email says the
job "missed its check-in". **This redesign changes which address goes quiet, not
what silence means.**

This was the actual damage from the incident, and it is being handled as separate,
parallel work. Three signals, cheapest first:

- **Notice that the app is still talking to us.** The API key already records when
  it was last used, on every registration — and nothing reads it. "This app
  checked in three minutes ago, but no monitor has reported for an hour" is a
  *positive* statement with no false positives: the app is running and can reach
  us, so it is the pings specifically that are not arriving. Works even with a
  single monitor.
- **Alert on monitors that have never checked in.** Detection only considers
  monitors currently marked up, so a monitor that is registered but has never
  received a successful ping is invisible to it **forever** and produces no alerts
  at all. The threshold has to be relative to the monitor's own interval, it must
  fire only once, and it needs its own wording pointing at setup docs.
- **Notice a whole project going quiet.** Not "every monitor is down" — monitors
  go overdue in order of how often they run, so waiting for all of them means
  waiting for the slowest. The useful test is: the most recent ping *anywhere* in
  the project is older than the *shortest* interval-plus-grace in it. That fires as
  soon as the fastest job misses. It needs somewhere to record a project-level
  incident, and it tells you nothing about a project with one monitor.

The wording rule for all of them: **say what was observed, never what it means.**
"No monitor in project Foo has reported since 14:02" is true whether the cause is
a firewall, a crashing worker, or a deliberate shutdown, and it sends the reader
to the right place in all three. "Your network is blocked" is just a new way to be
wrong.

### 7.2 Two credentials that can disagree

Nothing forces the API key and the ping key to belong to the same project. Use
project A's API key with project B's ping key and registration writes to A while
pings go to B. A's monitors go down permanently, and every symptom reads as "your
job is down". This is a **new** kind of mistake — impossible today — and it is
permanent rather than transitional, so it needs a permanent guard.

The guard, shipping with the gem rather than after it: registration returns the
last four characters of the project's ping key, and the gem logs loudly at startup
if the key it holds does not match. There is no escalation in that — an API key can
already read every ping URL in its project.

Together with §4.3's once-per-task logging, this turns "wrong key, silent until
the interval elapses" — about 27 hours for a daily job — into one line at deploy
time. Both halves do real work: §4.3 catches a key that is wrong everywhere, this
catches a key that is valid but belongs somewhere else.

### 7.3 One leaked key now exposes a whole project

Today a leaked ping token lets an attacker fake check-ins for one monitor. A
leaked ping key lets them fake check-ins **and failure reports** for every monitor
in the project. And faking a check-in on a monitor that is currently down does not
just suppress the alert — it resolves the incident and sends a "recovered" email
in the middle of a real outage.

This is the sharpest criticism of the design and it is accepted knowingly, limited
by: storing only a hash, encouraging environment variables over crontab literals
(§2.2), independent rotation with an overlap period (§3.1), and refusing to let
the key create anything (§2.2). The per-monitor token remains available to anyone
who wants the narrower scope.

### 7.4 The catch-all around gem startup

The second bug from §1 is untouched by any of this and needs the same treatment:
narrow the catch-all so a broken `recurring.yml` cannot silently leave the job
listener unattached for the life of the process, and surface it through
`Stablemate.health`.

### 7.5 There will still be two URL forms — on purpose

With no compatibility to preserve, the obvious move is to collapse to one URL
form and delete ping tokens and both rotate actions entirely. That was considered
and **rejected on product grounds**, so it does not quietly become available
later:

- Hand-created monitors have no registration key, and giving them one means making
  it user-editable and validated — which re-opens a decision already made and
  recorded, that names make poor URL fragments because they collide within a
  project and go blank for non-Latin characters.
- **The ping key is shown once, so the dashboard could no longer display a working
  URL at all** — only a template with a placeholder in it. "Create a monitor,
  copy the URL, paste it into a shell script" is a core first-run path and it
  needs a complete, copy-pasteable string. Making the ping key permanently visible
  to solve this would undo §2.2 and bring back the rotation hazard.
- It would delete the only narrowly-scoped ping credential the product has. Per
  §7.3, the project key's reach is this design's biggest cost, and the per-monitor
  token is what limits it for anyone who cares.

So: **two credentials for two separate audiences** — monitors registered from
config files, and monitors created by hand — which is Healthchecks' shape, for
Healthchecks' reasons. Document it that way rather than treating it as unfinished.

## 8 · Test plan

Beyond ordinary unit and request coverage, the parts that are not optional:

- **Browser test.** Generate a ping key from the project page, see it once, see it
  masked in the list afterwards, revoke it. Mirrors the existing API-key test.
- **Tenant isolation.** The same task name in two projects; pinged with project
  A's key, project B's monitor must be untouched (§3.3).
- **Rate limiting.** Two different task names under one ping key must not share a
  counter (§3.5).
- **Routing.** A task name containing a dot must arrive intact (§3.2).
- **Response uniformity.** Unknown key, valid key with unknown task name, and
  over-limit must be indistinguishable (§3.6).
- **Gem: unlisted job classes never ping** under the new task list (§4.2).
- **Gem: no ping key configured** — listener still attached, no pings sent, one
  error line (§4.4).
- **Gem: a task with an unworkable schedule never pings** (§4.2) — the containment
  the cache was doing by accident.
