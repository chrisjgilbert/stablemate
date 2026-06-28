# Architecture — object inventory

How Stablemate's behaviour maps onto the [`CLAUDE.md`](../../CLAUDE.md)
conventions: **operation objects** (noun, entity-scoped, reached via a method on
the record), **concerns** (one aspect of an entity), **sub-resource controllers**
(no custom verbs), **coordinators** (noun, spans entities), and the **Command
pattern** (narrow, for dispatch over interchangeable actions).

This is the target shape sub-agents build toward. Names are normative — build
`Monitor::CheckIn`, not `CheckInService`. If a real need doesn't fit a row here,
deviate **and leave a one-line note saying why** (CLAUDE.md "Deviate, but say so").

> **No `app/services/`.** Nothing in this document lives there; the directory does
> not exist.

---

## 1 · Records (top-level `app/models/*.rb`)

Thin manifests of `include`s + associations: `User`, `Session`, `WaitlistSignup`,
`ApiKey`, `Monitor`, `PingEvent`, `Incident`, `UptimeDayStat`, `Notification`.

---

## 2 · `Monitor` — the centre of gravity

`app/models/monitor/`

| File | Kind | Reached via | Responsibility |
|---|---|---|---|
| `heartbeat_states.rb` | concern | `monitor.up?`, scopes | Status predicates (`up?`/`down?`/`pending?`/`paused?`) and scopes: `Monitor.overdue` (the detection query), `detectable`. |
| `pausing.rb` | concern | `monitor.pause!` / `monitor.resume!` | Simple state flips (resume → `pending` if never pinged, else re-evaluate). |
| `ping_token.rb` | concern | `monitor.rotate_ping_token!` | Generate on create; rotate (invalidates old URL). |
| `check_in.rb` | **operation** | `monitor.check_in!(received_at:, source_ip:, duration_ms:)` | Record a `PingEvent`, move `last_ping_at`/`next_due_at`, transition `pending→up` / `down→up` (resolve the open incident, enqueue `recovered`). `up→up` = timestamps only. `paused` = record event, no transition/alert. |
| `missed_ping.rb` | **operation** | `monitor.flag_missed!` | Transition `up→down`, open an `Incident` (guarded by the open-incident invariant), enqueue a `down` notification. |
| `uptime.rb` | concern | `monitor.uptime_series(days: 90)`, `monitor.uptime_percent` | Build the 90-element day-status array + overall %, read from `UptimeDayStat` (+ live current day). |
| `uptime_rollup.rb` | **operation** | `monitor.roll_up_uptime(day)` | Compute up/down seconds + ping count for a day from incidents/pings; idempotent upsert of the `UptimeDayStat`. |

`Monitor` itself: `include HeartbeatStates, Pausing, PingToken, Uptime` + the
association `has_many :ping_events / :incidents / :notifications`.

---

## 3 · `User`

`app/models/user/`

| File | Kind | Reached via | Responsibility |
|---|---|---|---|
| `plan.rb` | concern | `user.monitor_limit`, `user.at_monitor_cap?`, `user.remaining_monitor_slots` | Cap keyed off `plan` (`MAX_MONITORS_PER_USER`); counts paused monitors. Backs the model validation `Monitor#within_monitor_cap`. |
| `verification.rb` | concern | `user.verified?`, `user.send_verification_email` | Non-blocking email verification. |
| `monitor_sync.rb` | **operation** | `user.sync_monitors(app:, entries:)` | Idempotent bulk upsert from the gem payload: upsert by `(user, registration_key)`, `source: "gem"`; cap-aware **partial** registration returning `{registered:, skipped:}`. Owned by the user (they own the monitors). |

---

## 4 · `ApiKey`

`app/models/api_key/`

| File | Kind | Reached via | Responsibility |
|---|---|---|---|
| `issuance.rb` | **operation** | `ApiKey.issue(user:, name:)` → `[api_key, raw_token]` | Generate `sm_live_<random>`, store SHA-256 digest + `last4`, return the raw token **once** (transient, never persisted). |
| `authentication.rb` | concern | `ApiKey.authenticating(raw_token)` | Constant-time digest lookup; touch `last_used_at`. |

---

## 5 · Incidents & alerting

- **Incidents** are opened/resolved *by* `Monitor` operations (`missed_ping`,
  `check_in`). `Incident` carries small helpers (`incident.resolve!`,
  `incident.open?`); no incident "service".
- **Alerting is the Command-pattern exception** — dispatch over interchangeable
  channels (email now; webhooks additive in V2):

`app/models/notifications/`

| File | Kind | Responsibility |
|---|---|---|
| `dispatch.rb` | **coordinator** | `Notifications::Dispatch.new(notification).deliver` — selects the channel(s) for a `Notification` and delegates. The Monitor operations create the `Notification` row and enqueue dispatch. |
| `channel.rb` | **command contract** | Base: `#deliver(notification)` (raises `NotImplementedError`). |
| `email_channel.rb` | **command** | Wraps `MonitorMailer#down` / `#recovered`; sets `Notification#delivered_at`. |

> *Deviation note (pre-justified):* a verb-shaped `deliver` dispatcher is allowed
> here precisely because callers dispatch over interchangeable channels through one
> contract — CLAUDE.md's Command-pattern row. It is **not** a default for one-shot
> operations, which stay operation objects.

`MonitorMailer` is an ordinary Action Mailer — the only email-specific code.

---

## 6 · Sign-up / waitlist

- Sign-up is RESTful: `RegistrationsController#new/#create`, `SessionsController`
  from the auth generator.
- The cap→waitlist branch spans `User` and `WaitlistSignup` and is owned by
  neither → a **top-level coordinator**:

`app/models/signup.rb` — `Signup.new(email:, password:).run` returns either a
created `User` (with session + verification email) or a `WaitlistSignup` when
`User.count >= SIGNUP_ACCOUNT_CAP`. The controller stays thin and asks `Signup`.

---

## 7 · Controllers (RESTful, sub-resources — no custom verbs)

| Route | Controller | Notes |
|---|---|---|
| `GET\|POST /ping/:ping_token` | `PingsController#create` | Public hot path; thin → `monitor.check_in!`. Unknown token → opaque `404`. |
| `resources :monitors` | `MonitorsController` | Standard CRUD; loads via `current_user.monitors`. |
| `resource :pause` (nested) | `Monitors::PausesController#create`/`#destroy` | Pause = create, resume = destroy. → `monitor.pause!`/`resume!`. |
| `resource :ping_token, only: :update` (nested) | `Monitors::PingTokensController#update` | Rotate token. → `monitor.rotate_ping_token!`. |
| `GET /sign_up`, `POST /registrations` | `RegistrationsController` | `#create` delegates to `Signup`. |
| `GET /settings/api_keys` | `Settings::ApiKeysController#index/#create/#destroy` | `#create` → `ApiKey.issue`; generate-once modal. |
| `POST /api/v1/monitors/sync` | `Api::V1::Monitors::SyncsController#create` | Bearer auth → `user.sync_monitors`. (Path kept per PRD; controller named for the noun "sync".) |
| `GET /api/v1/monitors[/:id]` | `Api::V1::MonitorsController#index/#show` | Bearer auth, tenant-scoped. |
| `POST /api/v1/monitors/:id/rotate` | `Api::V1::Monitors::PingTokensController#update` | Path kept per PRD; → `monitor.rotate_ping_token!`. |

Bearer auth lives in an `Api::V1::BaseController` concern, not a service.

---

## 8 · Jobs (orchestrate; records do the work)

`app/jobs/`

| Job | Schedule | Body |
|---|---|---|
| `DetectMissedPingsJob` | every 30s | `Monitor.overdue.find_each(&:flag_missed!)` |
| `RollupUptimeJob` | daily | iterate monitors → `monitor.roll_up_uptime(day)` (handles a backfill range) |
| `PrunePingEventsJob` | daily | `PingEvent.prunable.in_batches.delete_all` (scope on `PingEvent`); safety-check a `UptimeDayStat` exists for the day first |

No job contains domain logic beyond iteration + delegation.

---

## 9 · The companion gem (`gem/`)

A separate codebase, but the same spirit: noun-named objects, no junk services.
The **registrar seam is the Command pattern** — interchangeable adapters behind
one contract (only one ships in V1):

| Object | Kind | Responsibility |
|---|---|---|
| `Stablemate::Client` | — | HTTP client for `/api/v1` (bearer). |
| `Stablemate::Registrars::Registrar` | command contract | `#tuples` → registration tuples. |
| `Stablemate::Registrars::SolidQueueRecurring` | command (V1) | Parse `config/recurring.yml`; `registration_key` = task key; interval via Fugit (largest gap for irregular crons). |
| `Stablemate::Registration` | operation | `sync!` — build tuples, POST sync, cache ping URLs. |
| `Stablemate::Execution::Subscriber` | — | Subscribe to `perform.active_job`; on success, resolve job class → task key → ping URL; fire-and-forget ping. |

---

## 10 · Phase → objects introduced

| Phase | New objects |
|---|---|
| 0 | `Monitor` (+ `ping_token` concern, `check_in` operation in its first form), `PingsController`, `User`, `PingEvent`. |
| 1 | `Monitor::{heartbeat_states, pausing, missed_ping}`, full `check_in`; `User::{plan, verification}`; `Signup` (stub — full waitlist in P4); `Notifications::{dispatch, channel, email_channel}`; `MonitorMailer`; sub-resource controllers (pauses, ping_tokens). |
| 2 | `Monitor::{uptime, uptime_rollup}`; `RollupUptimeJob`, `PrunePingEventsJob`; `UptimeDayStat`. |
| 3 | `ApiKey::{issuance, authentication}`; `User::monitor_sync`; `Api::V1::*` controllers; the **gem**. |
| 4 | `Signup` waitlist branch + `WaitlistSignup`; rate-limiting (Rack::Attack / `rate_limit`), not a service. |

Each phase spec's Test Plan tests these objects directly (e.g. a `[model]` test of
`monitor.check_in!`, a `[unit]` test of `Notifications::EmailChannel`).
