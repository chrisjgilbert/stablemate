# Stablemate — Locked Decisions & Data Model

The durable record of the **binding product/architecture decisions**, the
**authoritative data model**, and the project **conventions** for Stablemate.

> V1 is shipped. The original PRD, the design handoff, and the per-phase build
> specs (phases 0–4) that these decisions were carved out of have been archived
> out of the repo. What remains here is the part that stays true after the build:
> the decisions the code is expected to honour going forward. The architecture
> rulebook the coding agent applies is [`../../CLAUDE.md`](../../CLAUDE.md).

---

## 1 · Locked decisions (binding)

Several originally-open product questions are decided and binding:

| # | Question | Decision |
|---|---|---|
| 1 | Detection sweep cadence | **30 seconds** (Solid Queue recurring task `every: "30s"`). Down-detection may lag the grace boundary by up to one cycle; acceptable for cron granularity. |
| 2 | Re-alert reminders | **Transition-only** — one `down` email per incident, one `recovered` email on resolution. No "still down" reminders in V1. |
| 3 | Email verification | **Non-blocking** — verification email is sent, but unverified users operate fully. No gate on monitor creation. |
| 4 | Gem ping reliability | **Fire-and-forget** — best-effort single async request, errors swallowed, never blocks the job. A transient outage is absorbed by the grace period. |
| 5 | Irregular-cron interval | **Largest gap** — `expected_interval_seconds` = the longest gap between consecutive runs; user can tighten via UI override. |
| 6 | ActiveJob → monitor mapping key | **Solid Queue task key** — `registration_key` = the `recurring.yml` task key. The registrar (Layer 2) writes it; the execution subscriber (Layer 1) resolves a job's `perform.active_job` back to that key. |
| 7 | Cap numbers | `MAX_MONITORS_PER_USER` / `SIGNUP_ACCOUNT_CAP`, **env-driven, default 0 ⇒ OFF/unlimited** (issue #16). Self-host has no caps/waitlist; the managed instance sets them (e.g. 5 / 100). When ON, the global cap re-opens **manually** (raise the env value). |
| 8 | Paused monitors vs. cap | **Count toward the cap.** A `paused` monitor still occupies a slot. Pausing is not a way to exceed the limit. |

---

## 2 · Conventions

### Architecture (non-negotiable)
Stablemate follows a **strict 37signals-inspired, vanilla-Rails** architecture:
keep `app/` small, put logic on records, **no `app/services/` directory**. Use
operation objects (noun, entity-scoped), concerns, sub-resource controllers,
coordinators, and the Command pattern (narrow) per the decision table in
[`../../CLAUDE.md`](../../CLAUDE.md). Object naming follows that decision table
and the names already established in `app/` — match the shipped code. Deviate
only with a one-line justification.

### Stack
- **Latest stable Rails (8.x)**, PostgreSQL, **Solid Queue** (jobs + recurring),
  Solid Cable (Turbo Streams), Solid Cache. Hotwire (Turbo + Stimulus), Tailwind
  CSS, server-rendered (no SPA). Deploy via Kamal to Hetzner.
- **Rails 8 built-in authentication generator** (sessions + `has_secure_password`).
  No Devise, no OAuth.

### Use Rails, don't fight it
Stablemate is a deliberately boring, idiomatic, vanilla Rails app (full rules in
[`../../CLAUDE.md`](../../CLAUDE.md)):
- **Latest stable Rails**; `rails new` defaults; don't swap defaults without a note.
- **Rails commands over hand-rolling** — `bin/rails generate` (authentication,
  model, migration, controller, mailer, job, stimulus, scaffold), `db:*`, Kamal
  generators. Trim generated output; don't reinvent it.
- **Hotwire-first, server-driven reactivity:** ERB → Turbo Frames → Turbo Streams
  (broadcast over Solid Cable) → a small Stimulus controller only for client-side
  bits. No SPA, no client polling, no JSON API for our own UI. DOM is the source
  of truth.
- **Classic vanilla patterns:** associations, scopes, validations, enums,
  `has_secure_password`, `has_secure_token`/`generates_token_for`, `rate_limit`,
  Action Mailer, Active Job, fixtures. If you're inventing a pattern, you're
  probably missing a built-in.

### Testing
- **Default framework: Minitest** (Rails 8 default) with fixtures and
  Capybara/Selenium **system tests**.
- Layers: `[model]` unit, `[request]` controller/integration, `[job]` Solid Queue
  jobs (use `perform_enqueued_jobs` / inline adapter), `[mailer]` Action Mailer
  (assert via `ActionMailer::Base.deliveries`), `[system]` end-to-end Capybara,
  `[unit]` operation objects / concerns / coordinators, `[gem]` the companion
  gem's own suite.
- **Time** is controlled in tests with `travel_to` / `freeze_time` — detection,
  grace windows and "X ago" formatting all depend on it.

#### System tests (`[system]`) — required, browser-driven
Every key user-facing flow ships with a browser-driven Capybara system test — see
the rule in [`../../CLAUDE.md`](../../CLAUDE.md).
- **Real browser, headless.** Chromium is preinstalled at
  `$PLAYWRIGHT_BROWSERS_PATH`; **never run `playwright install`.** Prefer the Rails
  default `driven_by :selenium, using: :headless_chrome`; if Selenium Manager's
  driver download is blocked in the sandbox, use **cuprite** (Ferrum) pointed at
  the preinstalled Chromium binary (CDP, no chromedriver). The SessionStart hook
  ensures the browser is available.
- **Drive the UI, assert what the user sees** — they exist to catch Turbo/Stimulus
  behaviour (live status replacement over Solid Cable, the copy button, the
  generate-key modal, waitlist mode) that request tests can't.
- **For flows that cross time/jobs/email** (outage → down email → recovery), drive
  the UI to set up state, then trigger detection inline (`perform_enqueued_jobs` /
  run the job) under `travel_to`, and assert the row/badge flips and the email
  was sent (`ActionMailer::Base.deliveries`).

### CI / Definition of Done
- `bin/rails test` **and** `bin/rails test:system` green; linter
  (`rubocop`/`standard`) clean. **`bin/ci` is the single command that runs all of
  this**. A PreToolUse hook runs `bin/ci --fast` (skips `test:system`) before
  every `git push` and blocks on failure; GitHub Actions runs the **full**
  `bin/ci` on every push/PR — that's the check required to be green before
  merging. Don't merge red.
- No N+1 on index/detail pages. Migrations are reversible
  (`bin/rails db:migrate` / `db:rollback` both run). Non-obvious behaviour is
  documented in the relevant view/job/model.

### Money / cost-control constants (single source)
Defined in `config/initializers/stablemate.rb` (the `Stablemate` module, mirrored
to `Rails.application.config.x.stablemate`):
```ruby
MAX_MONITORS_PER_USER   = ENV.fetch("STABLEMATE_MAX_MONITORS_PER_USER", 0).to_i  # 0 ⇒ unlimited
SIGNUP_ACCOUNT_CAP      = ENV.fetch("STABLEMATE_SIGNUP_ACCOUNT_CAP", 0).to_i     # 0 ⇒ always open
DETECTION_INTERVAL      = 30.seconds
PING_RETENTION          = 90.days
DEFAULT_GRACE_FRACTION  = 0.15   # gem-derived grace = 15% of interval, min 5.minutes
```
The two caps are **config-gated and default to OFF / unlimited** (issue #16): a
self-hoster has no per-user monitor cap and no signup cap/waitlist; the managed
instance switches them on via env. Use `Stablemate.monitor_cap_enabled?` /
`Stablemate.signup_cap_enabled?` (true only for a positive value) rather than
re-deriving the "0 ⇒ unlimited" rule at each call site. Tests assert behaviour
**relative to these constants**, never hard-coded numbers.

### Security defaults
- `ping_token` and `ApiKey` raw tokens are **secrets**: tokens are random,
  stored hashed (SHA-256), compared in constant time, shown raw exactly once.
  Unknown ping token → opaque `404` (no tenant leak).
- All tenant-scoped queries go through `current_user.monitors` (never
  `Monitor.find` by bare id in user-facing controllers) — cross-tenant access
  must be impossible, and there is a test for it in every CRUD slice.

---

## 3 · Data model (authoritative)

The shipped table set. Columns beyond the original PRD are marked ⊕.

### `User`
`id`, `email_address` (unique, citext or lower-indexed), `password_digest`,
`verified_at` (null), `plan` (string, default `"free"`), timestamps.

### `Session` (Rails 8 auth generator)
As generated by `bin/rails generate authentication` — `user_id`, `ip_address`,
`user_agent`, token. Don't hand-roll.

### `WaitlistSignup`
`id`, `email_address` (unique), `created_at`. (No `updated_at` needed.)

### `ApiKey`
`id`, `user_id`, `name`, `token_digest` (unique), `token_last4`, `last_used_at`
(null), timestamps. Raw format `sm_live_<random>`; shown once.

### `Monitor`
`id`, `user_id`, `monitor_type` (string, default `"heartbeat"`), `name`,
`ping_token` (unique, secret), `expected_interval_seconds` (int),
`grace_period_seconds` (int), `status` (string: `up`/`down`/`paused`/`pending`),
`last_ping_at` (null), `next_due_at` (null), `registration_key` (null),
⊕ `source` (string: `"manual"`/`"gem"`, default `"manual"`), timestamps.

- `registration_key` ≡ the `recurring.yml` task key (the gem's Layer 2 writes it).
- `source` drives the **gem chip** in the UI. Set to `"gem"` by the sync
  endpoint, `"manual"` otherwise.
- Indexes: `ping_token` (unique); `(user_id, registration_key)` unique **where
  `registration_key IS NOT NULL`**; `next_due_at`; `(status, next_due_at)`.

### `PingEvent`
`id`, `monitor_id`, `received_at` (not null), `kind` (string, default
`"success"`), `source_ip` (null), `duration_ms` (null), `created_at`.
Pruned after `PING_RETENTION`.

### `Incident`
`id`, `monitor_id`, `started_at` (not null), `resolved_at` (null), `cause`
(string, default `"missed_ping"`), timestamps. **At most one open
(`resolved_at IS NULL`) per monitor** — enforce with a partial unique index.

### `UptimeDayStat`
`id`, `monitor_id`, `day` (date), `up_seconds` (int), `down_seconds` (int),
`ping_count` (int). Unique `(monitor_id, day)`. Kept indefinitely.

### `Notification`
`id`, `monitor_id`, `incident_id` (null), `channel` (string, default
`"email"`), `event` (string: `down`/`recovered`), `delivered_at` (null),
`created_at`. Audit log; channel-agnostic for V2.
