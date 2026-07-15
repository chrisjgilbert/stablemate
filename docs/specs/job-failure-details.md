# Error notices — show *what error* took a monitor down, not just lateness

Status: **decisions resolved — ready to build** (§12 ratified by the owner,
2026-07-15; build in the §14 chunks, not one mega PR).
Author: Claude (session), 2026-07-15; **merges @chrisjgilbert's Dead-Man's-Snitch-style
"Error Notices" draft** (same date — the ping-param contract, the single `error`
column, the single-entrypoint behaviour, and the demand that the locked-decision-#2
impact be decided here, not worked around in code, all come from that draft).
Owner: @chrisjgilbert. Extends the V1 data model in [`README.md`](README.md) and
**amends locked decision #2** (see §5.1). Composes with (and partially fulfils)
the `PingEvent.kind "failure"` + nullable `error` reservation in
[`uptime-monitor.md`](uptime-monitor.md) §3. Follow the architecture rulebook in
[`../../CLAUDE.md`](../../CLAUDE.md).

> This is a **design spec, not a build spec.** It proposes the shape, names the
> reuse boundaries, walks every surface the change touches, and enumerates the
> edge cases. The §12 decisions are **resolved** — the spec reflects those
> choices; §14 gives the build order and hand-off notes for implementation.

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

This spec adds **error notices** (Dead Man's Snitch's term): a job can report
*"I ran, but I failed"* on an otherwise on-time ping, triggering an immediate
alert distinct from a missed check-in.

1. **Capture** — when a monitored job fails for good, the gem reports the error
   to Stablemate instead of staying silent (the "Rails-native Field Agent":
   DMS needs a shell-wrapper CLI to auto-capture failures; our gem is already
   inside the process with the exception in hand).
2. **Manual path** — non-gem users (cron + curl, any language) send the same
   signal with two extra params on the ping URL they already have.
3. **Surface in email** — the alert for a reported error says *what raised and
   why*, not "go check your logs", via a distinct "job reported an error"
   template (vs today's "job went silent").
4. **Surface in UI** — the monitor detail page's incident banner and
   recent-events feed show the error; history keeps it per incident.

Two side benefits fall out of the design:

- **Faster detection.** An explicit error report flips the monitor `down`
  *immediately* — no waiting out `interval + grace` for the absence to become
  visible. For a daily job with a 1-hour grace, that is hours of earlier
  alerting.
- **Prepared ground for the uptime probe.** `uptime-monitor.md` records failed
  probes as `kind: "failure"` with an error reason — this spec builds exactly
  the columns it reserved.

---

## 2 · The core reuse insight

Almost everything downstream of "a monitor went down" is already cause-agnostic
and keeps working unchanged — this is additive, not a rework:

- **`Incident`** already has a `cause` string column (default `"missed_ping"`)
  — the schema anticipated a second cause. One open incident per monitor stays
  enforced by the partial unique index.
- **`Notification` + `Notifications::Dispatch` + `EmailChannel`** — the `down` /
  `recovered` events and transition-only alerting apply as-is; a reported-error
  incident is still one `down`-class email, resolved by the next successful
  ping with one `recovered` email.
- **Recovery** — `Monitor::CheckIn#recover` resolves *whatever* open incident
  exists, regardless of cause. An error incident recovers by the next
  successful ping with zero new code.
- **`PingEvent.kind`** already defaults to `"success"` and is free to carry the
  reserved `"failure"` value — we just start writing it.
- **The ping endpoint itself** — reporting rides the existing
  `/ping/:ping_token` route (§6), so the rate limits, the opaque-404 token
  handling, forgery skip, and row-locking discipline are inherited, not
  re-implemented. No new controller, no new route.
- **`mini_ticks`** (`app/models/monitoring/monitor/uptime.rb:96`) already maps
  any non-`success` kind to a red tick — the dashboard sparkline lights up for
  failures with **zero changes**.
- **`UptimeRollup`** computes up/down seconds from incidents + `monitored?`,
  never from how the signal arrived — error incidents count as downtime
  correctly, unchanged.
- **`broadcast_status_update`**, badge/row partials, pause/suspend semantics —
  untouched.

The genuinely new machinery is small: two optional ping params, one operation
object for the failure branch, two nullable `error` columns, a gem hook, and
cause-aware copy in the email + banner.

---

## 3 · How a failure reaches the server

### 3.1 The manual path: `status` / `message` params on the existing ping

Dead Man's Snitch convention, folded in as the **primary contract**: the ping
endpoint (`app/controllers/pings_controller.rb`) accepts two new optional
params alongside the existing `duration_ms`:

| Param | Alias | Meaning |
|---|---|---|
| `status` | `s` | Job exit code. `0`, blank, or absent = success; **anything else = failure**. |
| `message` | `m` | Free-text error string (the exception, the last log line, …). |

This beats a separate `/fail` URL for cron ergonomics: one snippet always
fires and `$?` decides the polarity — no conditional logic in the shell:

```sh
# end of any cron job — success and failure ride the same line
run_backup 2>/tmp/backup.err
curl -fsS "https://stablemate.dev/ping/$TOKEN" \
  --data-urlencode "status=$?" \
  --data-urlencode "message=$(tail -c 500 /tmp/backup.err)"
```

Same credential model as today: the token **is** the auth, opaque `404` on
unknown token, `GET` and `POST` both accepted, params by query string or form
body. A non-zero `status` with no `message` still records a failure, with
`error` set to `"exited with status <n>"` so the alert is never blank.

### 3.2 The gem path: `ActiveJob::Base.after_discard` (terminal failures only)

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
events, no per-attempt noise. (The original draft sketched "rescue job
exceptions and auto-send" — `after_discard` is that sketch made concrete, with
retry-awareness for free.)

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
POST to the same cached ping URL with `status=1` and
`message="#{exception.class}: #{exception.message}"` on the dispatcher thread.
Errors are swallowed exactly as today (locked decision #4 — nothing may
propagate into the host).

- New config: `ping_on_failure` (default `true`), symmetric with
  `ping_on_success`.
- Version guard: `if ActiveJob::Base.respond_to?(:after_discard)` — on hosts
  older than Rails 7.1 error reporting silently degrades to today's
  missed-beat behaviour. (Verify at implementation time that `after_discard`
  fires before a `retry_on` custom block; if a host's block re-enqueues its own
  work that's their deviation to own.)
- Client truncates `message` to 1 000 chars before sending (§10).
- **The existing success subscriber is unchanged** — it already ignores raising
  performs, which is correct: attempt-level exceptions are not successes and
  (if non-terminal) not failures either.

---

## 4 · Data model changes

Mostly already scaffolded — `PingEvent.kind` has the unused `"failure"` value
and `Incident.cause` is a plain string. One small migration.

### `PingEvent` — the event log (pruned at 90 days)

| Column | Type | Notes |
|---|---|---|
| `kind` | *(exists)* | Start writing the reserved `"failure"` value. Add a `kind` inclusion validation (`success`/`failure`) while we're here. |
| ⊕ `error` | `text`, null | The reported message, truncated server-side to 1 000 chars (§10). Null for successes. This is the column `uptime-monitor.md` §3 proposed. |

A **single free-text column, not structured `error_class`/`error_message`
pairs**: the manual path sends arbitrary text (an exit code, a log line), so
class/message structure can't be guaranteed anyway; the gem simply prefixes
conventionally (`"ActiveRecord::Deadlocked: deadlock detected"`). One column,
one truncation rule, and the email/banner render one string. Structured
columns can be split out later if filtering-by-class ever becomes a feature.

### `Incident` — the durable record (kept forever)

| Column | Type | Notes |
|---|---|---|
| `cause` | *(exists)* | Gains `"reported_error"` alongside `"missed_ping"`. Add an inclusion validation. |
| ⊕ `error` | `text`, null | Copied from the failure ping that **opened** the incident. |

**Why denormalise onto the incident?** Two reasons: (a) raw pings are pruned
after `PING_RETENTION` (90 days) but incidents are the permanent outage
history — the error must outlive the ping row; (b) the incident is what the
banner and the email render from, so neither needs to hunt for "the ping event
that opened this incident". The copy is written once, at open, inside the same
transaction — no drift.

### Migration sketch

```ruby
add_column :ping_events, :error, :text
add_column :incidents,   :error, :text
```

Reversible, additive, no backfill (all existing rows are legitimately null —
V1 recorded successes and missed-beat incidents only). No new indexes: failure
lookups ride the existing `monitor_id` indexes.

---

## 5 · Server behaviour: one entrypoint, two operations

A failed ping is still a check-in — of bad news — so the controller stays a
one-liner and **`monitor.check_in!` remains the single entrypoint** (per the
draft: no new controller action). The facade grows the new params and routes by
polarity:

```ruby
# Monitoring::Monitor — the facade routes by kind; each outcome keeps its own
# tidy operation object, mirroring the existing CheckIn / MissedPing split.
def check_in!(received_at: Time.current, kind: "success", error: nil,
              source_ip: nil, duration_ms: nil)
  if kind == "failure"
    FailureReport.new(self).report_failure!(received_at:, error:, source_ip:, duration_ms:)
  else
    CheckIn.new(self).check_in!(received_at:, source_ip:, duration_ms:)
  end
end
```

`PingsController#create` maps the wire params to that call: `status`/`s`
present and non-zero → `kind: "failure"`, `error: message.presence ||
"exited with status <n>"`; otherwise the success path, unchanged.

**Why a sibling operation instead of branching inside `CheckIn`?** The draft
sketched "new logic on `CheckIn`", and the shared half (event row, timestamp
advancement, the lock) is indeed identical — but the transition halves point in
opposite directions (`CheckIn` recovers/holds `up`; the failure path opens
incidents and alerts, which is `MissedPing`'s shape). Folding both into one
class makes `apply_transition` a two-axis matrix; the codebase's established
pattern is one operation per outcome (`CheckIn` / `MissedPing`). So:
`Monitoring::Monitor::FailureReport` (noun, entity-scoped, verb-named method —
`app/models/monitoring/monitor/failure_report.rb`), structurally `CheckIn`'s
sibling with `MissedPing`'s incident half. The single-entrypoint intent of the
draft is preserved at the facade, where callers live.

`FailureReport#report_failure!`:

1. Under `with_lock` (same serialisation discipline as `CheckIn`/`MissedPing`):
   - create a `PingEvent` `kind: "failure"` with the (truncated) `error`;
   - advance `last_ping_at` and `next_due_at = received_at + interval` — the
     job **did** run and the next run is still expected on cadence. Advancing
     `next_due_at` also keeps the detection sweep honest: the monitor is
     already `down`, and `detectable` only scans `up` monitors, so no
     double-alert path exists;
   - set `first_ping_at ||= received_at` — a failure is contact; measurement
     starts (the alternative leaves the uptime bar showing no-data through a
     reported outage, which reads as "not monitored" when it's "down");
   - transition by status:
     - `up` / `pending` → `down`; open an `Incident(cause: "reported_error",
       error:)` (same open-incident guard + savepoint pattern as
       `MissedPing#open_incident`); create the `down` Notification;
     - `down` → record the event only. **No new incident, no email** (§5.1).
       The open incident keeps its original cause/error (§12-B);
     - `paused` / `suspended` → record the event only, no transition, no alert
       — exactly `CheckIn`'s rule: a stray ping (of either polarity) must not
       resume or alert a deliberately-unmonitored monitor.
2. Outside the lock: `Notifications::Dispatch#deliver` if a notification was
   created; `broadcast_status_update`.

**No grace period on explicit failures.** Grace exists to absorb *uncertainty
of absence* (a slow run, clock skew). A terminal-failure report is a positive
statement — the job is dead this cycle — so it flips `down` immediately. This
is the headline UX win (§1) and matches DMS/Healthchecks `/fail` semantics.

**Recovery needs zero new code.** The next successful `check_in!` finds the
open incident (whatever its cause), resolves it, and emits the one `recovered`
email — `CheckIn#recover` is already cause-agnostic.

### 5.1 · Amending locked decision #2 (deliberate, not a workaround)

Locked decision #2 (`README.md` §1) reads *"Transition-only — one `down` email
per incident, one `recovered` email on resolution."* It was written when the
only alert trigger was a missed ping; an on-time-but-failed ping is a new
trigger the decision doesn't cover. Per the draft's demand, the decision is
**extended here, deliberately**, and `README.md` §1 must be updated when this
ships:

> **#2 (amended): Alerts are transition-only, and a reported error on a live
> (`up`/`pending`) monitor IS a transition — to `down`, immediately, with no
> grace.** One `down`-class email per incident regardless of cause; a repeat
> reported error while an incident is already open records a `PingEvent` but
> re-alerts **nothing** (exactly like today's repeat-missed-ping behaviour);
> one `recovered` email on resolution. Grace applies only to *absence*.

So: does a second reported error during the same open incident re-alert? **No —
stays silent**, preserving the original decision's noise ceiling: an incident
is one email in, one email out, whatever caused it.

### Transition table (new rows only)

| Status before | Failure ping arrives | After | Incident | Email |
|---|---|---|---|---|
| `pending` | record failure event | `down` | open `reported_error` + error | one `down` (with error) |
| `up` (incl. inside grace) | record failure event | `down` | open `reported_error` + error | one `down` (with error) |
| `down` | record failure event | `down` | unchanged | none |
| `paused` / `suspended` | record failure event | unchanged | none | none |

---

## 6 · HTTP contract (`api.md` delta)

No new route — the existing endpoint grows two optional params:

```
GET  /ping/:ping_token
POST /ping/:ping_token
```

| Param | Type | Meaning |
|---|---|---|
| `status` (alias `s`) | string | Optional exit code. Blank/absent/`0` = success; anything else = failure. `status` wins if both spellings are sent. |
| `message` (alias `m`) | string | Optional error text. Recorded only on failures; truncated to 1 000 chars. Ignored on success pings in V1 (§12-E). |
| `duration_ms` | integer | Unchanged. |

Responses are **identical to today** — `200 {"ok":true}` on a known token
(recorded even when the failure causes no transition), opaque `404`, `429` —
and the per-token / per-IP rate limits apply automatically because it *is* the
same endpoint. `PingsController#create` stays thin: parse polarity, call
`monitor.check_in!(kind:, error:, ...)`.

---

## 7 · Gem changes (summary)

- `Configuration`: add `ping_on_failure` (default `true`).
- `Execution::Subscriber` (or a sibling `Execution::DiscardReporter` if the
  class gets crowded): add `handle_discard(job, exception)` — resolve keys
  exactly like `handle_event`, then dispatch
  `client.report_failure(url, message: "#{exception.class}: #{exception.message}")`
  fire-and-forget.
- `Client#report_failure(ping_url, message:)` — POST to the same ping URL with
  form-encoded `status=1&message=…`; same timeouts, same `:ok/:stale/:error`
  classification and stale-triggered resync as `#ping`.
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

`MonitorMailer#down(monitor, incident: nil)` branches on `incident&.cause` —
the draft's "job reported an error" vs "job went silent" split:

- **`missed_ping`** (and nil, defensively): today's copy, unchanged — subject
  `"<name> missed its check-in"`, "No ping arrived by …".
- **`reported_error`**: subject **`"<name> reported an error"`**; body leads
  with the error:

  > **Nightly backup reported an error.**
  >
  > The job ran and reported a failure:
  >
  > `ActiveRecord::Deadlocked: deadlock detected (PG::TRDeadlockDetected)`
  >
  > [View monitor]

  Error rendered in a monospace block, wrapped. Text part mirrors it. The
  "check your job logs" sentence only survives in the missed-ping branch — for
  a reported error we *are* the log's headline.

`recovered` is untouched.

---

## 9 · UI changes

All server-rendered ERB; no new Stimulus, no new streams — the existing
`broadcast_status_update` already refreshes badge/row on the transition.

### Monitor detail — incident banner (`monitors/show.html.erb:39`)

Cause-aware heading and an error block:

- `missed_ping`: exactly today's banner ("Monitor is down — no ping received",
  expected-by / grace / down-for).
- `reported_error`: heading **"Monitor is down — the job reported an error"**;
  the `dl` swaps expected-by/grace (meaningless here — nothing was late) for
  the error itself: a monospace, red-on-`down-bg` block showing
  `incident.error` (wrapped, `break-words`), plus the same "Down for …" row.
  `data-testid="incident-error"` for the system test.

### Recent events feed (`uptime.rb#recent_events` + partial)

- Failure pings become their own event kind: red dot, label
  `"Error reported — <error>"` with the error truncated to keep the row one
  line (the full text lives on the banner/incident).
- Incident-open labels become cause-aware: `"Went down — no ping received"`
  vs `"Went down — job reported an error"`.
- `recent_events` today plucks only `received_at`/`duration_ms` — extend the
  pluck with `kind`/`error`. The `Event` struct already carries `kind`.

### Dashboard

Nothing required: the badge flips via the existing broadcast, and
`mini_ticks` already renders non-success kinds as down ticks (§2). The row
partial stays untouched.

---

## 10 · Security & abuse bounds

- **The token is still the only credential.** The `status`/`message` params
  grant nothing the bare ping doesn't: anyone holding the token could already
  manipulate status by pinging/withholding. Same endpoint, so the opaque 404
  and both rate-limit buckets apply with zero new wiring.
- **Error text is untrusted input.** Rendered only through default ERB escaping
  (HTML) and plain-text email — never `html_safe`, never interpolated into
  headers. Subject lines use only the monitor name (existing behaviour), never
  the error text (header-injection surface, and subjects shouldn't leak error
  contents to notification previews on lock screens either — §12-D).
- **Truncation is server-side and unconditional**: `error` → 1 000 chars,
  applied in `FailureReport` (the model layer, so the API and any future
  channel share the bound). Client-side truncation in the gem is defence in
  depth, not the guarantee. Bounds storage: worst case ~1 KB per failure ping,
  already rate-capped at 30/min/token and pruned at 90 days.
- **`status` parsing is polarity-only**: blank/absent/`"0"` → success; any
  other value (numeric or not) → failure. A garbage `status` can at worst flip
  the sender's own monitor down — same power the token already confers.
- **Tenant scoping unchanged**: error details render only on the owner's pages
  (`current_user.monitors`) and in email to the owner's address.
- **Backtraces are deliberately excluded in V1** (§12-A) — they are the most
  likely place for secrets (file paths, SQL fragments; env dumps in messages
  are the user's own data; full traces multiply the risk and the payload).
- Run `/security-review` on the implementation diff — this touches the public
  ping surface (CLAUDE.md workflow rule 3).

---

## 11 · Testing plan (Definition of Done)

- **[unit] `FailureReport`**: every row of the §5 transition table; truncation;
  `next_due_at`/`last_ping_at`/`first_ping_at` advancement; incident carries
  the error; second failure while down → event only, no incident/email;
  paused/suspended inertness; concurrent fail/success serialisation via the
  lock (mirror the existing `CheckIn`/`MissedPing` test shapes). Facade
  routing: `check_in!(kind: "failure")` reaches `FailureReport`; default kind
  reaches `CheckIn` unchanged.
- **[request] `/ping/:token`**: `status=1` → 200, failure recorded, monitor
  down; `s=1` alias; `status=0` / absent → success path unchanged; `message`
  stored truncated; non-zero status without message → `"exited with status
  <n>"`; opaque 404 unknown token; GET and POST; existing rate-limit tests
  still pass untouched (same endpoint).
- **[mailer]**: `down` with a `reported_error` incident renders subject
  `"<name> reported an error"` + error block (HTML and text); `missed_ping`
  copy unchanged; a nil incident degrades to the missed-ping copy.
- **[gem]**: `handle_discard` resolves keys and posts `status=1&message=…`
  with truncation; `ping_on_failure = false` disables; dispatcher/exception
  swallowing; `after_discard` wiring smoke test on the inline adapter
  (raise with no retry_on → one failure report; retry_on succeeding on attempt
  2 → **zero** reports; retries exhausted → exactly one).
- **[system] — non-negotiable browser flow**: seed a monitor `up`; hit the
  ping URL with `status=1&message=…`; assert the detail page shows the red
  banner **with the error text**, the recent-events row, and the row badge
  flipped without a reload (Turbo Stream); `perform_enqueued_jobs` and assert
  the down email contains the error; then a success ping → banner gone,
  `recovered` email. One robust flow test, per the "flows, not coverage
  theatre" rule.

Docs: update `api.md` (the new params), `integrating.md` (§1.3 new config
flag, §2 curl-with-`$?` pattern, §3 "what you'll see"), and — **required by
§5.1** — the locked-decisions table in `specs/README.md` (amended #2, the new
columns/values in the data-model section).

---

## 12 · Decisions (RESOLVED — ratified by @chrisjgilbert, 2026-07-15)

Every recommendation below was ratified as written; each entry keeps its
reasoning as the record of *why*.

- **A · Backtraces?** Ship the free-text `error` only. **DECIDED: defer
  backtraces.** They answer the *next* question (where), not this spec's
  question (what); they balloon payload/storage; they're the highest-risk text
  for secret leakage (§10); and the user's error tracker already owns "where".
  A future `error_backtrace` text column (first N app frames, PingEvent-only,
  shown in a `<details>`) is additive and non-breaking if demand shows up.
- **B · Repeated failures while down — update the incident's error?**
  **DECIDED: keep the first error** (it's what the email said; an incident is
  "what took it down"). Later failures are visible in recent events. Updating
  in place would make the banner disagree with the email in the user's inbox.
  (Whether repeats *re-alert* is not open — decided **no** in §5.1.)
- **C · Should a failure ping while `pending` alert?** Spec says yes (§5): the
  first-ever signal being "I failed" is exactly when a new user most needs the
  loop to work. The alternative (stay pending, wait for a success first) hides
  a real failure behind onboarding state. **DECIDED: alert.**
- **D · Error in the email subject?** **DECIDED: no** — subject stays
  `"<name> reported an error"`. Keeps headers injection-proof and lock-screen
  previews clean; the body carries the detail.
- **E · Store `message` on success pings too?** DMS captures output on every
  check-in. **DECIDED: not in V1** — success messages have no surface to
  render on (no incident, no email) and would 10× the text volume of the
  hottest table for nothing. Additive later if a "last run output" panel is
  wanted; the param is simply ignored on success meanwhile.
- **F · Also support a `/fail` URL alias (Healthchecks convention)?**
  **DECIDED: defer.** Two public contracts means double documentation and
  tests for zero new capability — `status=$?` covers the trap-based shell case
  a `/fail` URL serves. Trivially additive later (a route that forces
  `kind: "failure"` into the same controller).
- **G · Per-attempt failure reporting (a `ping_on_retry`-style option)?**
  **DECIDED: not in V1.** Terminal-only (`after_discard`) is the correct
  default signal (§3.2); per-attempt reporting reintroduces the down/recovered
  noise this design avoids. Revisit only if users ask to see flappy retries.

---

## 13 · Out of scope / future

- Webhook/Slack channels for error alerts — arrives free with the V2
  `Notifications::Channel` expansion; the error already rides the
  incident/notification.
- Error grouping/dedup ("this job has failed with the same error 4 runs
  running"), links out to error trackers, failure-rate stats.
- Success-ping output capture (§12-E) and a "last run output" panel.
- The uptime probe (`uptime-monitor.md`) writing `kind: "failure"` + `error`
  (e.g. `Net::ReadTimeout`, `HTTP 503`) through these same columns — this spec
  deliberately builds the columns it reserved, so the probe lands on prepared
  ground.

---

## 14 · Build order & hand-off notes

Three PRs, each independently green (`bin/ci`) and shippable, per the
commit-hygiene rules — deliberately **not** one mega PR:

1. **PR 1 — server: error notices end to end (manual path).** The migration
   (§4), `FailureReport` + the `check_in!` facade routing (§5), the
   `status`/`message`/`s`/`m` params (§6), the cause-aware `down` email (§8),
   and the docs that must move with behaviour: the amended locked decision #2
   in `specs/README.md` (§5.1), `api.md`, and `integrating.md` §2's
   curl-with-`$?` pattern. Tests: the [unit]/[request]/[mailer] items of §11
   plus the browser system test (fail ping → badge flips down live → down
   email carries the error → success ping → recovered). After this PR the
   alert loop is correct for curl users. Known interim gap: the detail-page
   incident banner still shows the generic missed-ping copy for a
   `reported_error` incident until PR 2 lands — acceptable between PRs, not a
   stopping point.
2. **PR 2 — UI surfacing (§9).** Cause-aware incident banner with the error
   block (`data-testid="incident-error"`), cause-aware recent-events labels,
   the `recent_events` pluck extension; extend PR 1's system test to assert
   the banner shows the error.
3. **PR 3 — gem (§3.2, §7).** The `after_discard` wiring, `Client#report_failure`,
   `ping_on_failure` config, the [gem] test items of §11, `integrating.md`
   §1.3. **Stop-and-report condition:** if implementation-time verification
   shows `after_discard` does *not* fire exactly once per terminal failure as
   §3.2 assumes (e.g. ordering against a `retry_on` custom block differs),
   stop and report back rather than substituting a different hook —
   terminal-only reporting is the load-bearing design decision.

Small implementation notes, so the implementer doesn't rediscover them:

- The `MonitorMailer.send(event, monitor, incident:)` call in §8 reaches
  `recovered` too — `recovered` must accept and ignore the `incident:` kwarg.
- The 1 000-char `error` truncation bound lives with the other product
  constants in `config/initializers/stablemate.rb` (e.g.
  `Stablemate::ERROR_MESSAGE_LIMIT`), not inline in `FailureReport`; tests
  assert relative to the constant, never a hard-coded number (specs README
  rule).
- CLAUDE.md workflow checkpoints apply to every PR: TDD, `/code-review` before
  push, `/security-review` on PRs 1 and 3 (public ping surface / token
  handling), `/verify` the live flow before shipping PR 1.
