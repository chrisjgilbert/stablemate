# Spec — Uptime Monitors (active HTTP checks)

Status: **draft for review**. Author: Claude (session), 2026-07-14.
Owner: @chrisjgilbert. Supersedes nothing; extends the V1 data model in
[`README.md`](README.md).

> This is a design spec, not a build spec. It proposes the shape, calls the
> reuse boundaries explicitly, and lists the decisions that need your sign-off
> (§12) before anyone writes a migration. Follow the architecture rulebook in
> [`../../CLAUDE.md`](../../CLAUDE.md).

---

## 1 · Motivation

Stablemate V1 monitors **heartbeats**: a job (or the companion gem) pushes an
inbound ping to `POST /ping/:ping_token` on a schedule, and the detection sweep
declares the monitor `down` when a ping fails to arrive within
`expected_interval + grace`. It answers *"did this cron run?"*.

It cannot answer the other half of the same question a user asks about their
app: *"is the site up right now?"* — because that requires Stablemate to
**reach out** and check, not wait to be pinged.

An **uptime monitor** is the active/outbound complement: Stablemate makes an
HTTP request to a URL on a schedule and records whether it answered. The natural
default target is the app's own **`/up`** health endpoint — Rails ships one
(`get "up" => "rails/health#show"`, already in our own `config/routes.rb`), so
every Rails app already has the thing worth checking. The companion gem, which
already auto-registers a heartbeat monitor per recurring job, can register one
uptime monitor for the app itself with **zero extra config** by defaulting to
`<app_url>/up`.

The two types are complementary, not redundant:

| | Heartbeat (V1) | Uptime (this spec) |
|---|---|---|
| Direction | inbound — target pings us | outbound — we probe target |
| Detects | a job/cron that stopped running | an endpoint that stopped answering |
| Credential | `ping_token` (inbound secret) | none (we hold the URL) |
| "Signal" | arrival of a ping | HTTP response to our request |
| Failure = | *absence* of a ping past grace | a *bad response* (non-2xx / timeout / error) |
| Gem role | registers + **pings** on job success | registers the URL; **we** do the pinging |

---

## 2 · The core reuse insight

Almost the entire down/up lifecycle is already type-agnostic and keyed on
records, not on *how* the signal arrived:

- **`Incident`** — one open incident per monitor (partial unique index).
- **`Notification` + `Notifications::Dispatch` + `EmailChannel`** — the `down`
  and `recovered` emails, transition-only (locked decision #2).
- **`PingEvent`** — an event log; `kind` already defaults to `"success"` and is
  free to carry a `"failure"` kind.
- **`UptimeDayStat` + `Monitoring::Monitor::UptimeRollup`** — computes uptime %
  purely from **incidents + ping_events + `first_ping_at` + `monitored?`**
  (verified in `uptime_rollup.rb`). It never looks at *how* a ping was produced.
- **`broadcast_status_update`**, the badge/row partials, the cap, the status
  vocabulary (`pending/up/down/paused/suspended`), pause/resume.

**Consequence:** if an uptime probe (a) records a `success` `PingEvent` and sets
`first_ping_at` on success, and (b) opens/resolves `Incident`s on the
down/up transitions, then the dashboard sparkline, uptime %, the daily rollup,
and both alert emails all work **unchanged**. The only genuinely new machinery is
the outbound probe itself and its scheduling.

This spec deliberately keeps uptime monitors inside the existing
`Monitoring::Monitor` record (a `monitor_type` discriminator), **not** a separate
STI subclass or table — see §12-A for the trade-off and recommendation.

---

## 3 · Data model changes

`monitor_type` already exists (`string`, default `"heartbeat"`) and `PingEvent.kind`
already exists — the V1 schema anticipated this. New/rebound columns:

### `Monitor` (additions)

| Column | Type | Notes |
|---|---|---|
| `url` | `string`, null | Absolute `http(s)` URL to probe. **Required for `uptime`, null for `heartbeat`.** Enforce with a conditional validation, not a NOT NULL. |
| ⊕ `request_timeout_ms` | `int`, default `5000` | Per-probe connect+read timeout. Uptime-only. |
| ⊕ `last_checked_at` | `datetime`, null | When we last probed (distinct from `last_ping_at`, which is the last *success*). Uptime-only; drives "checked 20s ago" in the UI. |

**Reused as-is (semantics shift per type, columns don't):**

- `expected_interval_seconds` → for uptime, **the probe cadence** ("check every
  N"). A successful probe advances `next_due_at = now + expected_interval` exactly
  like a heartbeat ping, so the *same* record fields drive both.
- `grace_period_seconds` → for uptime, **the confirmation window**: how long an
  endpoint may keep failing before we declare `down` (flap tolerance — see §5).
- `next_due_at`, `last_ping_at`, `first_ping_at`, `status`, `source` → unchanged
  meaning.
- `ping_token` → **heartbeat-only**; stays null for uptime monitors (no inbound
  credential). The `PingToken` concern's generation should be gated on
  `heartbeat?` (§4).
- `registration_key` → still the gem's idempotency key; an uptime monitor the gem
  registers for `/up` gets its own reserved key (§8).

### `PingEvent` (no migration; new value)

`kind` gains a `"failure"` value for a recorded failed probe (HTTP error /
non-2xx / timeout). Success probes record `kind: "success"` exactly like an
inbound ping, so `ping_count` and `first_ping_at` behave identically. Optionally
capture the failure reason in a nullable `error` string (⊕, defer to V2 if we
want to keep the migration tiny) — `duration_ms` is already there for latency.

### Migration sketch

```ruby
add_column :monitors, :url, :string
add_column :monitors, :request_timeout_ms, :integer, default: 5000, null: false
add_column :monitors, :last_checked_at, :datetime
# monitor_type already exists; add a partial index for the probe sweep:
add_index :monitors, [:monitor_type, :next_due_at]
```

Reversible, no backfill (existing rows are all `heartbeat`, `url` null).

---

## 4 · Domain design (architecture-compliant)

Read the domain off the tree — the new files slot beside the heartbeat ones:

```
app/models/monitoring/
  monitor.rb                    # thin manifest: include UptimeChecks; type dispatch
  monitor/
    heartbeat_states.rb         # (existing) status vocab + `overdue` scope
    check_in.rb                 # (existing) inbound ping → transition/recover
    missed_ping.rb              # (existing) overdue → down + alert
    uptime_checks.rb            # NEW concern: type predicates, `due_for_probe` scope
    probe.rb                    # NEW operation: outbound GET → record → transition/alert
    ...
app/jobs/
  probe_due_monitors_job.rb     # NEW recurring sweep: iterate due, call probe!
```

### `Monitoring::Monitor::UptimeChecks` (concern)

The type vocabulary + the probe scope, mirroring `HeartbeatStates`:

```ruby
def heartbeat? = monitor_type == "heartbeat"
def uptime?    = monitor_type == "uptime"

scope :uptime, -> { where(monitor_type: "uptime") }

# Uptime monitors currently being watched whose next probe is due. `monitored?`
# excludes paused/suspended/pending; NULL next_due_at (freshly created, never
# probed) is included so the first probe fires promptly — see §5 on the pending→
# first-probe transition.
scope :due_for_probe, -> {
  uptime.where(status: %w[up down]).where("next_due_at <= ? OR next_due_at IS NULL", Time.current)
}
```

### `Monitoring::Monitor::Probe` (operation) — the one new verb, given back to the noun

Reached via `monitor.probe!`. It is the uptime analog of CheckIn **and**
MissedPing fused into one step, because — unlike a heartbeat — the probe *is* the
detection: the result is known synchronously.

```
monitor.probe! →
  1. GET url with request_timeout_ms (SSRF-guarded — §9), following ≤ N redirects.
  2. Record a PingEvent (kind "success" | "failure", duration_ms, source ignored).
  3. Stamp last_checked_at = now.
  4. On SUCCESS (2xx):
       - reuse the CheckIn recovery path: pending/down/up → up, set
         last_ping_at/first_ping_at, next_due_at = now + expected_interval,
         resolve open incident + dispatch `recovered` (down→up only).
  5. On FAILURE (non-2xx / timeout / connection error / too many redirects):
       - do NOT advance last_ping_at.
       - still set next_due_at = now + expected_interval (so we keep probing).
       - if the confirmation window (§5) has elapsed and status is up: reuse the
         MissedPing path → down + open incident + dispatch `down`.
  6. broadcast_status_update.
```

**Do we literally call `check_in!` / `flag_missed!`, or extract a shared core?**
Recommended: extract the pure *transition + incident + alert* half of CheckIn and
MissedPing into small private helpers the two operations share, so `Probe`
composes them rather than duplicating the with_lock/incident/notification dance.
`check_in!` today also creates the PingEvent and computes `next_due_from` — for
uptime we want to record a *failure* event and drive the down side too, so a thin
shared "recover"/"open-incident-and-alert" seam is cleaner than calling the public
methods wholesale. This keeps transition-only alerting (decision #2) in exactly
one place for both types.

### `ProbeDueMonitorsJob` (recurring) — jobs orchestrate, records do the work

Mirrors `DetectMissedPingsJob` precisely (rule #5): iterate the scope, call the
record method, no domain logic in the job.

```ruby
class ProbeDueMonitorsJob < ApplicationJob
  queue_as :default
  def perform
    Monitoring::Monitor.due_for_probe.find_each(&:probe!)
  end
end
```

Scheduled in `config/recurring.yml` every `DETECTION_INTERVAL` (30s), beside
`detect_missed_pings`. The sweep is the *cadence ceiling*; each monitor's own
`expected_interval_seconds` (via `next_due_at`) is what actually decides whether
it's probed this tick, so a 5-minute monitor isn't hit every 30s.

> Note on outbound work in a sweep: probes make real network calls, so a slow
> endpoint must not stall the sweep for everyone. Options in §12-C (per-probe
> job vs. bounded concurrency vs. sequential-with-tight-timeout). Recommendation:
> enqueue one `ProbeMonitorJob` per due monitor from the sweep, so each probe
> runs in its own job with its own timeout and a hung endpoint can't block the
> others. `DetectMissedPingsJob` is pure DB and can stay a single sweep; the
> uptime sweep should fan out.

---

## 5 · Down-detection, grace, and flap tolerance

A single failed request is often a transient blip (a deploy, a GC pause, a packet
drop). Declaring `down` on the first failure would make uptime monitors noisy.
`grace_period_seconds` is reused as the **confirmation window**:

- **Recommended rule (time-based, reuses existing fields):** the *first* failure
  after an up state stamps a "failing since" marker (reuse `next_due_at`'s cousin
  — see below). The monitor flips to `down` only once it has been failing
  continuously for `grace_period_seconds`. Success at any point clears the marker.
  This mirrors heartbeat grace ("overdue for longer than grace") and keeps one
  mental model.

  Implementation choice for "failing since": either (a) a nullable
  `failing_since` column (explicit, one more column), or (b) derive it from "the
  earliest consecutive `failure` PingEvent since the last `success`" (no column,
  a small query). Recommendation: **(a) `failing_since`** — explicit, index-free,
  and avoids a scan on every probe. Cleared on success, set on the first failure.

- **Alternative (count-based):** down after *N consecutive failures*, N derived
  from `ceil(grace / interval)`. Simpler to reason about per-probe but couples the
  threshold to the cadence. Rejected as the default; time-based matches heartbeat.

Either way the **transition** (up→down, incident, alert) reuses `MissedPing`'s
guts, so "exactly one down email per incident / one recovered email" holds for
both types automatically.

**`pending` → first probe.** A freshly created uptime monitor starts `pending`
(never checked), same as heartbeat. `due_for_probe` includes `NULL next_due_at`
but the scope filters to `status IN (up, down)`. Resolve this one of two ways
(§12-D): include `pending` in the probe scope so the first successful probe flips
`pending→up` (recommended — symmetric with a heartbeat's first inbound ping
flipping `pending→up`), or seed `next_due_at` at creation. Recommendation:
**include `pending`** and let the first probe be the thing that lifts it out of
pending, exactly as the first ping does for heartbeat.

---

## 6 · UI / UX (Hotwire-first, server-driven)

Creation splits by type. Cleanest vanilla-Rails shape (rule #4 — find the noun,
avoid a custom verb): the "new monitor" screen offers the two types, and the form
renders the fields for the chosen type. Options in §12-B; recommendation is a
single `monitor_type` select on the existing form that toggles the type-specific
fields with a **small Stimulus controller** (the one allowed client-side bit —
show/hide the `url` field vs. the ping-URL card), posting to the same
`MonitorsController#create`.

Per type:

- **Heartbeat** (unchanged): after create, show the **ping-URL card** (the
  `/ping/:ping_token` endpoint + copy button).
- **Uptime**: no ping-URL card (no inbound token). Instead show the **checked
  URL**, the **last check** result + latency (`last_checked_at`, `duration_ms`),
  and "checking every N". The `url` and `request_timeout_ms` are editable.

Shared, unchanged: the live badge/row (Turbo Stream over Solid Cable), the uptime
panel + sparkline, incident history, pause/resume, the down/recovered emails. A
small **type chip** ("Heartbeat" / "Uptime", alongside the existing "gem" chip)
tells the two apart in the list.

`monitor_params` gains `:monitor_type, :url, :request_timeout_ms` (permitted only
on create for `monitor_type`; editing type is out of scope).

---

## 7 · The `/up` default & gem integration (the headline)

The user's framing: *"similar to how the gem auto-syncs using solid queue config,
perhaps it could use the /up path by default."* Two layers, both opt-inable:

1. **In the Stablemate UI**, when a user picks "Uptime", default the URL host to
   empty and the **path to `/up`** (Rails' built-in health route), so the common
   case is "type your domain, done". Purely a form default.

2. **In the companion gem**, register one uptime monitor for the app itself,
   defaulting to `<app_url>/up`, alongside the heartbeat monitors it already
   syncs from `recurring.yml`. This is the zero-config story:

   - The gem needs the app's **externally reachable base URL** — it already knows
     the *Stablemate* endpoint (`config.endpoint`) but not the *host app's* URL.
     Add `Stablemate.config.app_url` (or read
     `Rails.application.routes.default_url_options`/`action_mailer` if set).
   - The registrar emits an extra sync tuple:
     `{ registration_key: "uptime:self", monitor_type: "uptime",
        url: "#{app_url}/up", name: "<app> uptime", expected_interval_seconds: …,
        grace_period_seconds: … }`.
   - `User::MonitorSync` upserts it by `registration_key` exactly like a heartbeat
     entry — but `Entry`/the operation must learn `monitor_type` + `url`
     (currently it hard-codes neither, and deliberately whitelists only four
     attributes — extend that whitelist, keep the mass-assignment guard).
   - Crucially, an uptime monitor the gem registers is **not pinged by the gem** —
     Stablemate probes it. So the gem's execution subscriber (Layer 1) ignores it;
     only Layer 2 (registration) touches it. This is a cleaner division than
     heartbeat: register once, we watch it.

   **Gate it (§12-E).** Auto-probing an app requires (a) a reachable public URL
   and (b) the user's intent to have us hit it. Recommendation: **opt-in** via a
   `Stablemate.config.monitor_uptime = true` (default false) + a resolvable
   `app_url`; without both, the gem registers heartbeats only, as today. `/up` is
   the *default path* once enabled, not an automatic behavior on every install.

---

## 8 · Security — outbound HTTP is a new attack surface (SSRF)

This is the single most important new-risk section and must go through
`/security-review` (CLAUDE.md workflow #3 — new outbound surface + user-supplied
URLs). Stablemate making HTTP requests to **user-controlled URLs** is a textbook
SSRF vector: a user (or a compromised account) could point a monitor at
`http://169.254.169.254/…` (cloud metadata), `http://localhost:…` (our own
internal services), or an internal-only host and use our egress as a proxy /
port-scanner, or read back internal responses via latency/status.

Mandatory controls (V1):

- **Scheme allow-list:** `http` / `https` only. Reject `file:`, `gopher:`,
  `ftp:`, etc. at validation time.
- **Resolve-then-block private ranges:** resolve the host and refuse to connect to
  loopback, link-local (`169.254.0.0/16`, incl. the metadata IP), RFC-1918
  private, ULA/`fc00::/7`, `::1`, and `0.0.0.0`. Do the check against the
  **resolved IP actually connected to**, and re-check on each redirect hop —
  otherwise DNS-rebinding / a redirect to `localhost` bypasses a validation-time
  check. (A pinned-resolver / connect-to-checked-IP approach beats a
  validate-the-string approach.)
- **Redirect cap:** follow at most e.g. 3 redirects, re-validating each hop; treat
  exceeding it as a failed probe, not a crash.
- **Timeouts:** `request_timeout_ms` on both connect and read (matches the
  `Net::HTTP` open/read-timeout pattern already used in `WaitlistSignup::SlackAlert`).
- **Response cap:** we only need the status code — read a bounded number of bytes
  (or `HEAD`? many health endpoints only answer `GET` — use `GET` with a small
  read cap). Never buffer an unbounded body.
- **No secrets outbound:** send a fixed, identifiable User-Agent
  (`Stablemate-Uptime/1.0 (+https://stablemate.dev)`); never forward cookies,
  auth, or the requesting user's data.
- **Self-host caveat:** a self-hoster may legitimately want to monitor an internal
  URL. Make the private-range block a config toggle
  (`STABLEMATE_ALLOW_PRIVATE_PROBE_TARGETS`, default **off** on the managed
  instance, documented as dangerous). Don't hard-code a policy that only suits the
  hosted tier.
- **Rate/abuse:** the cap (`MAX_MONITORS_PER_USER`) already bounds how many URLs a
  user can make us hit; the per-monitor cadence bounds frequency. Note it, no new
  limiter needed for V1.

The probe records failures as `PingEvent kind:"failure"` and swallows all network
errors into "down evidence" — it must **never** raise into the sweep/job (same
never-crash-boot discipline the gem follows).

---

## 9 · API surface

- **Read:** `GET /api/v1/monitors` / `:id` already serialize monitors; add
  `monitor_type`, `url`, `last_checked_at` to the payload (no new routes).
- **Sync:** `POST /api/v1/monitors/sync` (`Api::V1::Monitors::SyncsController` →
  `User::MonitorSync`) learns to accept `monitor_type` + `url` per entry, so the
  gem can register the `/up` uptime monitor through the *same* endpoint. Keep the
  strict attribute whitelist (`Entry`), just widen it by two fields and validate
  `url`/type server-side (never trust the client's `status`/`source`).
- **No public inbound endpoint** for uptime — there is no ping to receive. The
  `/ping/:ping_token` hot path is untouched and remains heartbeat-only.

---

## 10 · Testing plan (system tests non-negotiable — CLAUDE.md)

Follow the existing layer taxonomy. Control time with `travel_to`; stub the
outbound HTTP at the probe boundary (WebMock/`Net::HTTP` stub) — never hit the
network in tests.

- **[unit] `Probe`:** success→up (+recovery), failure within grace stays up,
  failure past grace→down+incident+one `down` email, recovery→one `recovered`
  email, timeout/connection-error = failure, non-2xx = failure, redirect handling,
  **SSRF: a private/loopback/metadata URL is refused** (the key security test).
- **[model] `UptimeChecks`:** `due_for_probe` scope (respects `next_due_at`,
  excludes paused/suspended, includes pending/never-probed per §5).
- **[job] `ProbeDueMonitorsJob`:** iterates due monitors, calls `probe!`, ignores
  heartbeat monitors and not-due ones.
- **[request] `MonitorsController`:** create an uptime monitor (url required,
  validated), tenant scoping unchanged; `MonitorSync` upserts an uptime entry.
- **[gem] registrar/sync:** emits the `/up` uptime tuple only when enabled +
  `app_url` present; the execution subscriber never pings an uptime monitor.
- **[mailer]** reuse — the down/recovered emails are type-agnostic; one test that
  an uptime-caused incident sends them.
- **[system] the end-to-end flow (required):** create an uptime monitor in the
  browser (Stimulus toggle shows the URL field, not a ping-URL card) → dashboard
  shows it `pending`/`up` → drive a probe (stubbed endpoint returns 500) under
  `travel_to` past grace → the badge flips to **down** live (Turbo Stream) and a
  `down` email is sent → endpoint returns 200, probe → badge flips **up** and a
  `recovered` email is sent. This is the DoD flow; a PR without it gets sent back.

---

## 11 · Rollout / phasing

1. **Migration + model** — columns, `UptimeChecks` concern, `Probe` operation
   (shared-transition refactor of CheckIn/MissedPing), unit tests. SSRF guard
   lands here, with `/security-review`.
2. **Sweep + job** — `ProbeDueMonitorsJob` + fan-out, `recurring.yml` entry,
   `/verify` the real up→down→recovery cycle against a throwaway local endpoint.
3. **UI** — type select + Stimulus toggle, uptime show page, chips, system test.
4. **Gem** — `app_url`/`monitor_uptime` config, `/up` registration tuple,
   `MonitorSync` widening, gem tests. Ship behind the opt-in flag.

Each phase keeps `bin/ci` green and stands alone.

---

## 12 · Open decisions — need your call

Recommendations in **bold**; these change the shape enough to confirm first.

- **A. One record vs. STI.** **Recommend: keep one `Monitor` record with a
  `monitor_type` discriminator** (the column already exists; maximal reuse of
  incidents/rollup/UI). STI (`UptimeMonitor < Monitor`) would give cleaner
  per-type methods but fights the existing `Monitoring::Monitor` namespacing
  deviation and duplicates the manifest. Only worth it if the types diverge a lot
  later.
- **B. Creation UX.** **Recommend: one form + `monitor_type` select + a small
  Stimulus field-toggle**, posting to the existing controller. Alt: two separate
  "new" routes (`/monitors/new?type=uptime` or a sub-resource). The select is less
  surface.
- **C. Probe execution model.** **Recommend: sweep enqueues one probe job per due
  monitor** (isolation from slow endpoints). Alt: single sequential sweep with a
  tight timeout (simpler, but one hung host delays the batch), or bounded
  concurrency in-process.
- **D. `pending` first probe.** **Recommend: include `pending` uptime monitors in
  `due_for_probe`** so the first probe lifts them out of pending (symmetric with
  heartbeat's first ping). Alt: seed `next_due_at` at create.
- **E. Gem auto-registration default. — DECIDED: opt-in.**
  (`config.monitor_uptime = true` + a resolvable `app_url`); `/up` is the default
  *path*, not an automatic install-time behavior. Auto-probing needs a reachable
  URL and explicit intent. (Rejected: on-by-default when `app_url` is derivable —
  more magic, more surprise, and a hosted instance probing an unintended URL.)
- **F. Grace semantics. — DECIDED: time-based confirmation window** via a
  `failing_since` column, reusing `grace_period_seconds` (mirrors heartbeat
  grace). (Rejected: N-consecutive-failures — couples the threshold to cadence.)
- **G. Success criterion.** V1: **`2xx` = up**, everything else = down. Do we want
  a configurable expected-status / body-match in V1, or defer? **Recommend:
  defer** — keep the migration and UI minimal; add `expected_status` in a V2.
```
