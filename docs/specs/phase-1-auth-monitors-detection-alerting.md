# Phase 1 — Auth, Monitor CRUD + Cap, Detection & Email Alerting

**Goal:** a developer can sign up, create a monitor (within a 5-monitor cap),
wire its ping URL, and — when pings stop — receive a `down` email, then a
`recovered` email when pings resume. This is the core promise of the product.

PRD refs: §3.1–§3.7, §4 (state machine), §5.1/§5.3/§5.5, §7 Phase 1.
Design refs: [`design-system.md`](design-system.md) screens — auth, dashboard,
new/edit form, monitor detail (history panel is Phase 2).
Architecture: [`../../CLAUDE.md`](../../CLAUDE.md) +
[`architecture.md`](architecture.md) — operation objects/concerns/sub-resource
controllers, **no `app/services/`**.

---

## 1 · Scope & dependencies

**In:**
- Rails 8 authentication (sign up / in / out), sessions, `has_secure_password`.
- Tenant scoping: a user sees and edits only their own monitors.
- Monitor CRUD UI: list, new/edit (name, interval, grace, human-friendly
  presets), pause/resume, delete, **rotate `ping_token`**.
- **5-monitor-per-user cap** enforced on create (UI + model), with an at-limit
  message and an "n / 5" count on the dashboard.
- Full **state machine** `pending/up/down/paused` (PRD §4.1).
- **Detection** recurring job (every 30s) flipping overdue monitors to `down`,
  opening an `Incident`, enqueuing a `down` notification.
- **Ping handling** upgraded from Phase 0: resolves incidents + enqueues
  `recovered` on recovery.
- Action Mailer `down` + `recovered` emails via a **channel-agnostic command
  layer** (`Notifications::Dispatch` + `Notifications::EmailChannel`).
- A (non-blocking) email **verification** email on signup.
- Reusable UI components from [`design-system.md`](design-system.md#2--reusable-components-build-as-viewcomponents-or-partials).
- Live status via Turbo Streams over Solid Cable (dashboard rows + detail badge).

**Out:** uptime history panel / rollups / pruning (Phase 2); API + gem (Phase 3);
waitlist + signup cap + ping rate-limiting (Phase 4); "still down" reminders.

**Dependencies:** Phase 0 (app, ping endpoint, base models).

---

## 2 · Data model / migrations

- Run `bin/rails generate authentication` → `Session` + auth plumbing; build on
  the generated controllers/views, don't hand-roll auth. Add `verified_at` to
  `users` if not already present (Phase 0 added it). Use `bin/rails generate
  mailer`/`controller`/`migration` for the rest rather than writing files by hand.
- New tables: **`Incident`**, **`Notification`** (full README §4 columns).
  - `Incident`: **partial unique index** on `monitor_id WHERE resolved_at IS NULL`
    — enforces "at most one open incident per monitor" at the DB level.
- `Monitor` already has all needed columns from Phase 0.

---

## 3 · Behaviour & contracts

### 3.1 Authentication
- Sign up: email + password → creates `User` (plan `"free"`), starts a session,
  sends a **verification email** (non-blocking — user is fully usable immediately,
  `verified_at` stays null until they click). Sign-up subtitle copy: **"Free — up
  to 5 monitors"** (design R3.1).
- Sign in / sign out via the generated controllers.
- All monitor routes require a session; unauthenticated → redirect to `/sign_in`.

### 3.2 Tenant scoping
- `User has_many :monitors`. Every controller action loads via
  `current_user.monitors.find(params[:id])` so a foreign id raises
  `RecordNotFound` → `404`. **There is a test that user B cannot read/edit/delete
  user A's monitor.**

### 3.3 Monitor CRUD + cap
- Create/edit fields: `name`, `expected_interval_seconds`, `grace_period_seconds`.
  Form offers human presets (Every 5 min / Hourly / Daily / Weekly + Custom) for
  interval and sensible grace presets + Custom; the stored value is seconds.
- New manual monitor: `source = "manual"`, `status = "pending"`, fresh
  `ping_token`.
- **Cap:** a user may own at most `MAX_MONITORS_PER_USER` (5) monitors,
  **paused ones included** (locked decision #8). Enforced by a model validation
  (`validate :within_monitor_cap, on: :create`) **and** guarded in the UI (the
  New-monitor action shows the at-limit state when at cap). Editing an existing
  monitor is never blocked by the cap.
- Pause/resume: a **sub-resource controller** (`Monitors::PausesController`,
  `resource :pause` — pause = `#create`, resume = `#destroy`; no `POST /:id/pause`
  custom verb) delegating to `monitor.pause!` / `monitor.resume!` (the
  `Monitor::Pausing` concern). Resuming returns to `pending` if never pinged, else
  `up` (re-evaluated against `next_due_at`).
- Rotate token: a sub-resource (`Monitors::PingTokensController#update`,
  `resource :ping_token, only: :update`) calling `monitor.rotate_ping_token!`
  (the `Monitor::PingToken` concern). Old URL stops working immediately; detail
  page shows the new URL.
- Delete: destroys the monitor and dependent `PingEvent`/`Incident`/`Notification`
  rows (`dependent: :destroy`).

### 3.4 State machine (PRD §4.1)
```
pending ──first ping──▶ up ──interval+grace elapsed, no ping──▶ down
   ▲                     ▲                                        │
   │                     └──────────────ping received────────────┘
   └─ (initial)        paused ◀──user pauses──▶ (resumes to up/pending)
```
- `pending`: created, never pinged. **Not eligible for down-alerts.**
- `up`: last ping within `interval + grace`.
- `down`: `now > last_ping_at + interval + grace`. Opens an incident, sends `down`.
- `paused`: excluded from detection and alerting.

Implement per [`architecture.md`](architecture.md#2--monitor--the-centre-of-gravity):
status predicates + scopes in a `Monitor::HeartbeatStates` **concern**;
`monitor.check_in!` and `monitor.flag_missed!` as **operation objects**
(`Monitor::CheckIn`, `Monitor::MissedPing`); `pause!`/`resume!` in a
`Monitor::Pausing` concern. No state-machine gem, no `*Service`. Each operation is
unit-tested directly.

### 3.5 Detection (recurring job, every 30s)
A Solid Queue recurring task `DetectMissedPingsJob`:
```sql
SELECT monitors WHERE status = 'up'
  AND next_due_at + (grace_period_seconds || ' seconds')::interval < now()
```
The job is **orchestration only** — it iterates and delegates to the record
(`Monitor.overdue.find_each(&:flag_missed!)`); the logic lives in the
`Monitor::MissedPing` operation. For each overdue monitor (pure timestamp
comparison, no network calls), `flag_missed!`:
1. Transitions `up → down`.
2. Opens an `Incident` (`started_at = now`, `cause = "missed_ping"`) — **only if no
   open incident exists** (the partial unique index is the backstop).
3. Enqueues a `down` `Notification` and hands it to `Notifications::Dispatch`.
4. Broadcasts a Turbo Stream badge/row update.

Wire it in `config/recurring.yml` at `every: "30s"` (uses `DETECTION_INTERVAL`).

### 3.6 Ping handling (extends Phase 0)
`PingsController#create` stays thin and delegates to `monitor.check_in!` (the
`Monitor::CheckIn` operation object). On ping receipt the operation:
- Records a `PingEvent`; sets `last_ping_at = now`; recomputes `next_due_at`.
- `pending → up`.
- `down → up`: **resolve the open incident** (`resolved_at = now`); enqueue a
  `recovered` `Notification`; broadcast update.
- `up → up`: timestamps only, no notification (no per-ping noise).
- `paused`: a ping still records the event + timestamps but does **not** change
  status or alert (paused means "don't monitor"). *(Document this choice in the
  ping controller; the test pins it.)*

### 3.7 Alerting (channel-agnostic, Command pattern)
- The `Monitor` operation creates the `Notification` row (`channel: "email"`) and
  hands it to `Notifications::Dispatch` (a **coordinator**), which selects the
  channel(s) and delegates to a `Notifications::Channel` **command** — V1 ships one,
  `Notifications::EmailChannel`, wrapping `MonitorMailer`. The mailer is the only
  email-specific piece; new channels (webhook, V2) are additive commands behind the
  same contract. This is the Command-pattern exception, **not** a default service —
  see [`architecture.md` §5](architecture.md#5--incidents--alerting). No
  `app/services/`, no `*Dispatcher` PORO.
- **Transition-only (decision #2):** exactly one `down` email per incident,
  exactly one `recovered` email on resolution. The open-incident invariant
  guarantees no duplicate down-alerts during a continuing outage.
- `MonitorMailer#down` and `#recovered`: plain, scannable emails — monitor name,
  what happened, expected-by time, link to the detail page. Set `delivered_at` on
  the `Notification` after delivery.

### 3.8 Live UI (Turbo Streams)
- When a ping lands or detection flips a monitor, broadcast a replace of the
  dashboard row and the detail header badge over Solid Cable. DOM is the source
  of truth; no client polling.

---

## 4 · Test plan (write these first)

### Auth `[request]`/`[system]`
1. Sign up with email + password creates a `User` with `plan == "free"`,
   `verified_at` nil, starts a session, and enqueues a verification email.
2. An unverified user can still create monitors (no gate).
3. Sign in / sign out work; protected routes redirect anonymous users to `/sign_in`.
4. `[system]` sign-up screen shows subtitle "Free — up to 5 monitors".

### Tenant scoping `[request]`
5. User B requesting user A's monitor (show/edit/update/destroy) gets `404`.
6. Dashboard lists only `current_user`'s monitors.

### Monitor CRUD + cap `[model]`/`[request]`/`[system]`
7. Creating a monitor stores interval/grace in seconds and generates a unique
   `ping_token`, `source == "manual"`, `status == "pending"`.
8. `[model]` a user with 5 monitors cannot create a 6th (validation error).
9. `[model]` paused monitors count toward the cap (5 incl. paused → 6th blocked).
10. `[system]` at the cap, the New-monitor action shows the at-limit state and the
    dashboard shows "5 / 5".
11. Editing an existing monitor when at cap succeeds (cap only blocks creation).
12. Rotating a token changes `ping_token`; the old token now returns `404` on ping.
13. Deleting a monitor removes dependent pings/incidents/notifications.
14. `[system]` post-create reveals the ping-URL card + curl snippet.

### State machine `[model]`
15. `pending` + first ping → `up`.
16. `up` with `now > last_ping_at + interval + grace` → eligible for `down`.
17. `pending` is **never** marked `down` by detection (not eligible).
18. `paused` is excluded from detection regardless of `next_due_at`.
19. `resume!` → `pending` if never pinged, else re-evaluates to `up`/`down`.

### Detection job `[job]`
20. `freeze_time`; given an `up` monitor past its grace window, running the job
    flips it to `down`, opens exactly one `Incident`, and enqueues one `down`
    notification.
21. Running the job twice does **not** open a second incident or send a second
    `down` email (open-incident invariant).
22. A monitor still within `interval + grace` is left `up`.
23. The job makes no outbound HTTP calls (pure DB).

### Ping handling / recovery `[request]`/`[model]`
24. A `down` monitor that receives a ping → `up`, its open incident gets
    `resolved_at`, and exactly one `recovered` notification is enqueued.
25. An `up` monitor receiving a ping sends no notification.
26. A `paused` monitor receiving a ping records the event but stays `paused` and
    sends nothing.

### Alerting `[mailer]`/`[unit]`
27. `MonitorMailer#down` renders with monitor name, expected-by time, detail link;
    delivered to the owner's email.
28. `MonitorMailer#recovered` renders and is delivered on recovery.
29. `Notifications::Dispatch` creates a `Notification` row per dispatch with
    correct `channel`/`event` and `Notifications::EmailChannel` sets `delivered_at`.
30. End-to-end `[system]`/`[job]`: create monitor → no ping → detection → down
    email; ping again → recovery email. (The PRD Exit, as one test.)

### Live UI `[system]`
31. When a monitor flips to `down`, the dashboard row badge updates without a full
    page reload (Turbo Stream).

---

## 5 · Acceptance criteria (PRD Phase 1 Exit)

- [ ] Create a monitor, stop pinging → receive a `down` email within one detection
      cycle of `interval + grace` elapsing.
- [ ] Resume pinging → receive a `recovered` email; incident resolved.
- [ ] Creating a 6th monitor is blocked with a clear at-limit message.
- [ ] Exactly one `down` and one `recovered` email per incident (no duplicates,
      no reminders).
- [ ] Tenant isolation holds (cross-tenant access impossible).
- [ ] All Test Plan scenarios pass; suite + linter green.

---

## 6 · Out of scope / guardrails
- No uptime-history panel yet (Phase 2) — the detail page shows status, ping URL,
  settings, and recent events list can be a simple `last N PingEvents` for now;
  the 90-day bar lands in Phase 2.
- No acknowledge action, no public toggle (cut from V1).
- No periodic reminders.
