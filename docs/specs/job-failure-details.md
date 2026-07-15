# Job-failure details — show *what error* took a monitor down

Status: **design spec — exploration + proposal, not yet pressure-tested**.
Author: Claude (session), 2026-07-15. Owner: @chrisjgilbert. Extends the V1 data
model in [`README.md`](README.md); composes with (and partially fulfils) the
`PingEvent.kind "failure"` reservation in
[`uptime-monitor.md`](uptime-monitor.md) §3. Follow the architecture rulebook in
[`../../CLAUDE.md`](../../CLAUDE.md).

> This is a **design spec, not a build spec.** It proposes the shape, names the
> reuse boundaries, walks every surface the change touches, and enumerates the
> edge cases. §12 holds the open decisions, each with a recommendation.

---

## 1 · Motivation

Today Stablemate only knows about **absence**: a job that raises simply doesn't
ping (`gem/lib/stablemate/execution/subscriber.rb:68` returns early on
`payload[:exception]`), the monitor sits `up` until the grace window elapses,
and the eventual `down` email says, literally:

> *"Check your job logs to see what happened."*
> (`app/views/monitor_mailer/down.html.erb:7`)

That is the weakest moment in the product loop. The gem **had the exception
object in its hands** at the instant the job died — class, message, backtrace —
and threw it away. The user gets woken up by an email that tells them to go
find, by hand, information we already touched.

This spec closes that loop:

1. **Capture** — when a monitored job fails for good, the gem reports the error
   (class + message) to Stablemate instead of staying silent.
2. **Surface in email** — the `down` alert for a reported failure says *what
   raised and why*, not "go check your logs".
3. **Surface in UI** — the monitor detail page's incident banner and
   recent-events feed show the error; history keeps it per incident.

Two side benefits fall out of the design:

- **Faster detection.** An explicit failure report flips the monitor `down`
  *immediately* — no waiting out `interval + grace` for the absence to become
  visible. For a daily job with a 1-hour grace, that is hours of earlier
  alerting.
- **A manual `/fail` path.** Non-gem users (cron + curl, any language) get the
  same power: `curl .../ping/<token>/fail` from an error trap. This also lays
  the exact rails the future uptime probe needs (`uptime-monitor.md` records
  failed probes as `kind: "failure"` with an error reason — same columns, same
  transitions).

---

## 2 · The core reuse insight

Almost everything downstream of "a monitor went down" is already cause-agnostic
and keeps working unchanged:

- **`Incident`** already has a `cause` string column (default `"missed_ping"`)
  — the schema anticipated a second cause. One open incident per monitor stays
  enforced by the partial unique index.
- **`Notification` + `Notifications::Dispatch` + `EmailChannel`** — the `down` /
  `recovered` events and transition-only alerting (locked decision #2) apply
  as-is; a failure-caused incident is still one `down` email, resolved by the
  next successful ping with one `recovered` email.
- **Recovery** — `Monitor::CheckIn#recover` resolves *whatever* open incident
  exists, regardless of cause. A failure incident recovers by the next
  successful ping with zero new code.
- **`PingEvent.kind`** already defaults to `"success"` and is free to carry
  `"failure"` (reserved by `uptime-monitor.md` §3).
- **`mini_ticks`** (`app/models/monitoring/monitor/uptime.rb:96`) already maps
  any non-`success` kind to a red tick — the dashboard sparkline lights up for
  failures with **zero changes**.
- **`UptimeRollup`** computes up/down seconds from incidents + `monitored?`,
  never from how the signal arrived — failure incidents count as downtime
  correctly, unchanged.
- **`broadcast_status_update`**, badge/row partials, pause/suspend semantics —
  untouched.

The genuinely new machinery is small: a failure-report endpoint, one operation
object (`Monitoring::Monitor::FailureReport`), three nullable columns, a gem
hook, and cause-aware copy in the email + banner.

---

## 3 · How a failure reaches the server

### 3.1 The gem path: `ActiveJob::Base.after_discard` (terminal failures only)

**The key design decision is *when* a failed job run counts as "failed".**
ActiveJob retries make attempt-level failure the wrong signal: a job with
`retry_on Timeout::Error, attempts: 3` that fails once and succeeds on retry
never missed a beat from the user's point of view — reporting the first attempt
would flip the monitor `down` and email, then `recovered` minutes later. Noise.

The right signal is **terminal failure — the job has been discarded and will
not run again this cycle**. Rails ≥ 7.1 gives us exactly this hook as public
API: **`ActiveJob::Base.after_discard`** fires with `(job, exception)` when

- an unhandled exception escapes `perform` (no `retry_on`/`discard_on` matches),
- `retry_on` exhausts its attempts,
- `discard_on` swallows the error.

That is precisely our set, with the exception object in hand, backend-agnostic
(works on Solid Queue, Sidekiq adapter, test/inline adapters), and — unlike the
`perform.active_job` notification, which records the exception on **every**
attempt including ones that will be retried — it fires exactly once per
terminal failure. No thread-local correlation of `perform` / `enqueue_retry`
events, no per-attempt noise.

The railtie registers one global callback (inherited by every job class)
alongside the existing execution subscriber:

```ruby
# gem: wired by the railtie when enabled_in? and an api_key is present
ActiveJob::Base.after_discard do |job, exception|
  Stablemate.execution_subscriber&.handle_discard(job, exception)
end
```

`handle_discard` mirrors `handle_event`: resolve the job class to task key(s)
via the same `class_to_keys` / manual-fallback rules, then fire-and-forget a
**fail ping** on the dispatcher thread. Errors are swallowed exactly as today
(locked decision #4 — nothing may propagate into the host).

- New config: `ping_on_failure` (default `true`), symmetric with
  `ping_on_success`.
- Version guard: `if ActiveJob::Base.respond_to?(:after_discard)` — on hosts
  older than Rails 7.1 failure reporting silently degrades to today's
  missed-beat behaviour. (Verify at implementation time that `after_discard`
  fires before a `retry_on` custom block; if a host's block re-enqueues its own
  work that's their deviation to own.)
- Client truncates before sending (§10): error class ≤ 200 chars, message
  ≤ 1 000 chars.
- **The existing success subscriber is unchanged** — it already ignores raising
  performs, which is correct: attempt-level exceptions are not successes and
  (if non-terminal) not failures either.

### 3.2 The manual path: `POST /ping/:ping_token/fail`

Every monitor's ping URL grows a `/fail` sibling (the Healthchecks-style
convention), so any language/scheduler can report a failure from an error trap:

```sh
# bash cron job
run_backup || curl -fsS "https://stablemate.dev/ping/$TOKEN/fail" \
  --data-urlencode "error_message=backup exited $? — $(tail -c 500 /tmp/backup.err)"
```

Same credential model as the ping path: the token **is** the auth, opaque `404`
on unknown token, both `GET` and `POST` accepted (a bare curl in a trap must
work; params may arrive by query string or form body).

---

## 4 · Data model changes

### `PingEvent` — the event log (pruned at 90 days)

| Column | Type | Notes |
|---|---|---|
| `kind` | *(exists)* | Gains the reserved `"failure"` value. Add a `kind` inclusion validation (`success`/`failure`) while we're here. |
| ⊕ `error_class` | `string`, null | e.g. `"ActiveRecord::Deadlocked"`. Null for successes. |
| ⊕ `error_message` | `text`, null | Truncated server-side to 1 000 chars (§10). |

### `Incident` — the durable record (kept forever)

| Column | Type | Notes |
|---|---|---|
| `cause` | *(exists)* | Gains `"job_failed"` alongside `"missed_ping"`. Add an inclusion validation. |
| ⊕ `error_class` | `string`, null | Copied from the failure ping that **opened** the incident. |
| ⊕ `error_message` | `text`, null | Same. |

**Why denormalise onto the incident?** Two reasons: (a) raw pings are pruned
after `PING_RETENTION` (90 days) but incidents are the permanent outage
history — the error must outlive the ping row; (b) the incident is what the
banner and the email render from, so neither needs to hunt for "the ping event
that opened this incident". The copy is written once, at open, inside the same
transaction — no drift.

### Migration sketch

```ruby
add_column :ping_events, :error_class,   :string
add_column :ping_events, :error_message, :text
add_column :incidents,   :error_class,   :string
add_column :incidents,   :error_message, :text
```

Reversible, additive, no backfill (all existing rows are legitimately null —
V1 recorded successes and missed-beat incidents only). No new indexes: failure
lookups ride the existing `monitor_id` indexes.

---

## 5 · Server behaviour: the `FailureReport` operation

Per the decision table: a complex one-shot operation owned by one entity →
**operation object**, noun-named, entity-scoped, verb-named public method.

```
app/models/monitoring/monitor/failure_report.rb   # Monitoring::Monitor::FailureReport
```

Facade on the monitor, next to `check_in!` / `flag_missed!`:

```ruby
# Record a reported job failure: persist a failure PingEvent and, if the
# monitor was live, flip it down, open a job_failed Incident and alert.
def report_failure!(received_at: Time.current, error_class: nil,
                    error_message: nil, source_ip: nil, duration_ms: nil)
  FailureReport.new(self).report_failure!(...)
end
```

`FailureReport` is the structural sibling of `CheckIn` (it *is* a check-in — of
bad news) and borrows `MissedPing`'s incident/notification half:

1. Under `with_lock` (same serialisation discipline as `CheckIn`/`MissedPing`):
   - create a `PingEvent` `kind: "failure"` with the (truncated) error fields;
   - advance `last_ping_at` and `next_due_at = received_at + interval` — the
     job **did** run and the next run is still expected on cadence. Advancing
     `next_due_at` also keeps the detection sweep honest: the monitor is
     already `down`, and `detectable` only scans `up` monitors, so no
     double-alert path exists;
   - set `first_ping_at ||= received_at` — a failure is contact; measurement
     starts (the alternative leaves the uptime bar showing no-data through a
     reported outage, which reads as "not monitored" when it's "down");
   - transition by status:
     - `up` / `pending` → `down`; open an `Incident(cause: "job_failed",
       error_class:, error_message:)` (same open-incident guard + savepoint
       pattern as `MissedPing#open_incident`); create the `down` Notification;
     - `down` → record the event only. **No new incident, no email** (locked
       decision #2, transition-only). The open incident keeps its original
       cause/error (§12-B);
     - `paused` / `suspended` → record the event only, no transition, no alert
       — exactly `CheckIn`'s rule: a stray ping (of either polarity) must not
       resume or alert a deliberately-unmonitored monitor.
2. Outside the lock: `Notifications::Dispatch#deliver` if a notification was
   created; `broadcast_status_update`.

**No grace period on explicit failures.** Grace exists to absorb *uncertainty
of absence* (a slow run, clock skew). A terminal-failure report is a positive
statement — the job is dead this cycle — so it flips `down` immediately. This
is the headline UX win (§1) and mirrors every heartbeat product's `/fail`
semantics.

**Recovery needs zero new code.** The next successful `check_in!` finds the
open incident (whatever its cause), resolves it, and emits the one `recovered`
email — `CheckIn#recover` is already cause-agnostic.

### Transition table (new rows only)

| Status before | Fail ping arrives | After | Incident | Email |
|---|---|---|---|---|
| `pending` | record failure event | `down` | open `job_failed` + error | one `down` (with error) |
| `up` (incl. inside grace) | record failure event | `down` | open `job_failed` + error | one `down` (with error) |
| `down` | record failure event | `down` | unchanged | none |
| `paused` / `suspended` | record failure event | unchanged | none | none |

---

## 6 · HTTP contract (`api.md` delta)

```
GET  /ping/:ping_token/fail
POST /ping/:ping_token/fail
```

| Param | Type | Meaning |
|---|---|---|
| `error_class` | string | Optional. Exception class name. Truncated to 200 chars. |
| `error_message` | string | Optional. Human-readable error. Truncated to 1 000 chars. |
| `duration_ms` | integer | Optional, same semantics/parsing as the ping path. |

Responses mirror the ping endpoint exactly: `200 {"ok":true}` on a known token
(recorded even when it causes no transition), opaque `404` on unknown token,
`429` over limit. Rate limiting **shares the same per-token and per-IP buckets**
as `/ping/:token` (same `RATE_LIMIT_STORE`, same limits) — `/fail` must not be
a second, independent budget for a runaway loop or a token scanner.

### Routing / controller

Per CLAUDE.md rule 4 (custom verb → sub-resource): the noun hiding in "ping
failed" is a **failure**.

```ruby
# config/routes.rb — beside the existing ping match
match "/ping/:ping_token/fail", to: "pings/failures#create",
      via: %i[get post], as: :ping_failure
```

`Pings::FailuresController#create` stays as thin as `PingsController#create`:
find by token, opaque 404, `monitor.report_failure!(...)`. The shared plumbing
(skip_forgery_protection, the two `rate_limit` declarations + store, the
numeric-param guard) is extracted to an abstract `Pings::BaseController` that
both inherit from — the limiter buckets stay shared because the `by:` lambdas
key on token/IP, not controller.

---

## 7 · Gem changes (summary)

- `Configuration`: add `ping_on_failure` (default `true`).
- `Execution::Subscriber` (or a sibling `Execution::DiscardReporter` if the
  class gets crowded): add `handle_discard(job, exception)` — resolve keys
  exactly like `handle_event`, then dispatch `client.fail_ping(url,
  error_class:, error_message:)` fire-and-forget.
- `Client#fail_ping(ping_url, error_class:, error_message:)` — POST to
  `<ping_url>/fail` with form-encoded params; same timeouts, same
  `:ok/:stale/:error` classification and stale-triggered resync as `#ping`.
- Railtie: register the global `ActiveJob::Base.after_discard` callback when
  the gem is enabled and `respond_to?(:after_discard)`.
- Client-side truncation before send (defence in depth with §10's server-side
  truncation).

---

## 8 · Email changes

`Notifications::EmailChannel` currently calls
`MonitorMailer.send(event, monitor)` — the mailer never sees the incident. Pass
it through so the email is deterministic under `deliver_later` (reading
`monitor.open_incident` at render time would race a fast recovery):

```ruby
MonitorMailer.send(@notification.event, @notification.monitor,
                   incident: @notification.incident).deliver_later
```

`MonitorMailer#down(monitor, incident: nil)` branches on `incident&.cause`:

- **`missed_ping`** (and nil, defensively): today's copy, unchanged — subject
  `"<name> missed its check-in"`, "No ping arrived by …".
- **`job_failed`**: subject **`"<name> failed"`**; body leads with the error:

  > **Nightly backup failed.**
  >
  > The job reported an error:
  >
  > `ActiveRecord::Deadlocked: deadlock detected (PG::TRDeadlockDetected)`
  >
  > [View monitor]

  Error rendered in a monospace block, `error_class` and `error_message`
  separated by `: ` (class alone / message alone degrade gracefully — both are
  optional params on the manual path). Text part mirrors it. The "check your
  job logs" sentence only survives in the missed-ping branch — for a reported
  failure we *are* the log's headline.

`recovered` is untouched.

---

## 9 · UI changes

All server-rendered ERB; no new Stimulus, no new streams — the existing
`broadcast_status_update` already refreshes badge/row on the transition.

### Monitor detail — incident banner (`monitors/show.html.erb:39`)

Cause-aware heading and an error block:

- `missed_ping`: exactly today's banner ("Monitor is down — no ping received",
  expected-by / grace / down-for).
- `job_failed`: heading **"Monitor is down — the job reported a failure"**;
  the `dl` swaps expected-by/grace (meaningless here — nothing was late) for
  the error itself: a monospace, red-on-`down-bg` block showing
  `error_class` and `error_message` (wrapped, `break-words`), plus the same
  "Down for …" row. `data-testid="incident-error"` for the system test.

### Recent events feed (`uptime.rb#recent_events` + partial)

- Failure pings become their own event kind: red dot, label
  `"Failure reported — ActiveRecord::Deadlocked"` (class only in the label;
  the full message lives on the banner/incident — the feed row stays one
  truncated line, as the partial already `truncate`s).
- Incident-open labels become cause-aware: `"Went down — no ping received"`
  vs `"Went down — job reported a failure"`.
- `recent_events` today plucks only `received_at`/`duration_ms` — extend the
  pluck with `kind`/`error_class`. The `Event` struct already carries `kind`.

### Dashboard

Nothing required: the badge flips via the existing broadcast, and
`mini_ticks` already renders non-success kinds as down ticks (§2). The row
partial stays untouched.

---

## 10 · Security & abuse bounds

- **The token is still the only credential.** `/fail` grants nothing `/ping`
  doesn't: anyone holding the token could already manipulate status by
  pinging/withholding. Same opaque 404, same shared rate-limit buckets (§6).
- **Error text is untrusted input.** Rendered only through default ERB escaping
  (HTML) and plain-text email — never `html_safe`, never interpolated into
  headers. Subject lines use only the monitor name (existing behaviour), never
  the error text (header-injection surface, and subjects shouldn't leak error
  contents to notification previews on lock screens either — §12-D).
- **Truncation is server-side and unconditional**: `error_class` → 200 chars,
  `error_message` → 1 000 chars, applied in `FailureReport` (the model layer,
  so the API and any future channel share the bound). Client-side truncation in
  the gem is defence in depth, not the guarantee. Bounds storage: worst case
  ~1.2 KB per failure ping, already rate-capped at 30/min/token and pruned at
  90 days.
- **Tenant scoping unchanged**: error details render only on the owner's pages
  (`current_user.monitors`) and in email to the owner's address.
- **Backtraces are deliberately excluded in V1** (§12-A) — they are the most
  likely place for secrets (file paths, SQL fragments, env dumps in messages
  are the user's own data; full traces multiply the risk and the payload).
- Run `/security-review` on the implementation diff — this touches the public
  ping surface (CLAUDE.md workflow rule 3).

---

## 11 · Testing plan (Definition of Done)

- **[unit] `FailureReport`**: every row of the §5 transition table; truncation;
  `next_due_at`/`last_ping_at`/`first_ping_at` advancement; incident carries
  the error; second failure while down → event only, no incident/email;
  paused/suspended inertness; concurrent fail/success serialisation via the
  lock (mirror the existing `CheckIn`/`MissedPing` test shapes).
- **[request] `/ping/:token/fail`**: 200 + recorded on known token; opaque 404
  unknown; GET and POST; query-string and form params; shared rate-limit
  buckets with `/ping` (a token at its `/ping` limit is throttled on `/fail`
  too); over-long params stored truncated.
- **[mailer]**: `down` with `job_failed` incident renders subject `"<name>
  failed"` + error block (HTML and text); `missed_ping` copy unchanged;
  error-class-only and message-only degrade cleanly.
- **[gem]**: `handle_discard` resolves keys and posts to `<url>/fail` with
  truncated params; `ping_on_failure = false` disables; dispatcher/exception
  swallowing; `after_discard` wiring smoke test on the inline adapter
  (raise with no retry_on → one fail ping; retry_on succeeding on attempt 2 →
  **zero** fail pings; retries exhausted → exactly one).
- **[system] — non-negotiable browser flow**: seed a monitor `up`; hit the fail
  endpoint; assert the detail page shows the red banner **with the error class
  and message**, the recent-events row, and the row badge flipped without a
  reload (Turbo Stream); `perform_enqueued_jobs` and assert the `down` email
  contains the error; then a success ping → banner gone, `recovered` email.
  One robust flow test, per the "flows, not coverage theatre" rule.

Docs: update `api.md` (the `/fail` contract), `integrating.md` (§1.3 new
config flag, §2 curl-on-failure pattern, §3 "what you'll see"), and
`specs/README.md`'s data-model section (new columns/values) when this ships.

---

## 12 · Open decisions (each with a recommendation)

- **A · Backtraces?** Ship class + message only. **Recommend: yes, defer
  backtraces.** They answer the *next* question (where), not this spec's
  question (what); they balloon payload/storage; they're the highest-risk text
  for secret leakage (§10); and the user's error tracker already owns "where".
  A future `error_backtrace` text column (first N app frames, PingEvent-only,
  shown in a `<details>`) is additive and non-breaking if demand shows up.
- **B · Repeated failures while down — update the incident's error?**
  **Recommend: keep the first error** (it's what the email said; an incident is
  "what took it down"). Later failures are visible in recent events. Updating
  in place would make the banner disagree with the email in the user's inbox.
- **C · Should a failure ping while `pending` alert?** Spec says yes (§5): the
  first-ever signal being "I failed" is exactly when a new user most needs the
  loop to work. The alternative (stay pending, wait for a success first) hides
  a real failure behind onboarding state. **Recommend: alert.**
- **D · Error in the email subject?** **Recommend: no** — subject stays
  `"<name> failed"`. Keeps headers injection-proof and lock-screen previews
  clean; the body carries the detail.
- **E · Per-attempt failure reporting (a `ping_on_retry`-style option)?**
  **Recommend: not in V1.** Terminal-only (`after_discard`) is the correct
  default signal (§3.1); per-attempt reporting reintroduces the down/recovered
  noise this design avoids. Revisit only if users ask to see flappy retries.
- **F · New locked decision to record on ship:** *"An explicit failure report
  flips a live monitor `down` immediately — grace applies only to absence"*
  (§5), alongside the existing table in `README.md` §1.

---

## 13 · Out of scope / future

- Webhook/Slack channels for failure alerts — arrives free with the V2
  `Notifications::Channel` expansion; the error already rides the
  incident/notification.
- Error grouping/dedup ("this job has failed with the same error 4 runs
  running"), links out to error trackers, failure-rate stats.
- The uptime probe (`uptime-monitor.md`) writing `kind: "failure"` +
  `error_class` (e.g. `Net::ReadTimeout`, `HTTP 503`) through these same
  columns — this spec deliberately builds the columns it reserved, so the
  probe lands on prepared ground.
