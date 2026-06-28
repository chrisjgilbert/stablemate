# Stablemate — Implementation Specs

These specs translate [`docs/PRD.md`](../PRD.md) and the design handoff
([`docs/design-change-request.md`](../design-change-request.md) + the Claude
Design package) into **TDD-ready work units**. Each phase spec is a
self-contained, shippable slice that one specialist sub-agent can pick up,
write failing tests against, and implement to green.

> **The PRD is the product source of truth. These specs are the build
> contract.** Where the design handoff and the PRD differed, the reconciliation
> is recorded below (§4) and baked into the per-phase specs — sub-agents should
> follow the specs, not re-derive from the source docs.

---

## 1 · How to use these specs (for the implementing sub-agent)

Each phase spec follows the same shape:

1. **Scope & dependencies** — what's in, what's explicitly out, what must exist first.
2. **Data model / migrations** — exact columns, types, indexes, constraints.
3. **Behaviour & contracts** — the rules, request/response shapes, state transitions.
4. **Test plan** — enumerated `Given / When / Then` scenarios, each tagged with
   the test layer it belongs in (`[model]`, `[request]`, `[job]`, `[mailer]`,
   `[system]`, `[unit]`). **These are the failing tests you write first.**
5. **Acceptance criteria** — the phase's PRD "Exit" condition, made checkable.
6. **Out of scope / deferred** — guardrails so the slice stays thin.

**TDD loop:** for each scenario in the Test Plan, write the failing test,
implement the smallest change to pass it, refactor, move on. A phase is "done"
only when every scenario is green and the Acceptance Criteria check out.

**Definition of Done (every phase):**
- All Test Plan scenarios implemented and passing.
- `bin/rails test` (+ system tests) green; linter (`rubocop`/`standard`) clean.
- No N+1 on index/detail pages (assert with `bullet` or a query-count test
  where the spec calls for it).
- Migrations are reversible and `bin/rails db:migrate` / `db:rollback` both run.
- New behaviour is documented in the relevant view/job/model where non-obvious.

---

## 2 · Locked decisions (resolved open questions)

The PRD §8 left several questions open. These are now decided and binding for
all specs:

| # | Question (PRD §8) | Decision |
|---|---|---|
| 1 | Detection sweep cadence | **30 seconds** (Solid Queue recurring task `every: "30s"`). Down-detection may lag the grace boundary by up to one cycle; acceptable for cron granularity. |
| 2 | Re-alert reminders | **Transition-only** — one `down` email per incident, one `recovered` email on resolution. No "still down" reminders in V1. |
| 3 | Email verification | **Non-blocking** — verification email is sent, but unverified users operate fully. No gate on monitor creation. |
| 4 | Gem ping reliability | **Fire-and-forget** — best-effort single async request, errors swallowed, never blocks the job. A transient outage is absorbed by the grace period. |
| 5 | Irregular-cron interval | **Largest gap** — `expected_interval_seconds` = the longest gap between consecutive runs; user can tighten via UI override. |
| 6 | ActiveJob → monitor mapping key | **Solid Queue task key** — `registration_key` = the `recurring.yml` task key. The registrar (Layer 2) writes it; the execution subscriber (Layer 1) resolves a job's `perform.active_job` back to that key. See Phase 3 §"Mapping". |
| 7 | Cap numbers | `MAX_MONITORS_PER_USER = 5`, `SIGNUP_ACCOUNT_CAP = 100`. Both config constants. Global cap re-opens **manually** (raise the constant). |
| 8 | Paused monitors vs. cap | **Count toward the cap.** A `paused` monitor still occupies a slot. Pausing is not a way to exceed the limit. |

---

## 3 · Conventions

### Stack
- **Rails 8**, PostgreSQL, **Solid Queue** (jobs + recurring), Solid Cable
  (Turbo Streams), Solid Cache. Hotwire (Turbo + Stimulus), Tailwind CSS,
  server-rendered (no SPA). Deploy via Kamal to Hetzner. (PRD §2.1.6)
- **Rails 8 built-in authentication generator** (sessions + `has_secure_password`).
  No Devise, no OAuth. (PRD §3.1)

### Testing
- **Default framework: Minitest** (Rails 8 default) with fixtures and
  Capybara/Selenium **system tests**. Test scenarios below are written
  framework-agnostically as `Given/When/Then`; a sub-agent may use RSpec +
  FactoryBot instead **if it keeps the whole suite consistent** — pick one and
  stay with it. *(If the team prefers RSpec project-wide, say so and this default
  flips; nothing in the scenarios assumes Minitest.)*
- Layers: `[model]` unit, `[request]` controller/integration, `[job]` Solid Queue
  jobs (use `perform_enqueued_jobs` / inline adapter), `[mailer]` Action Mailer
  (assert via `ActionMailer::Base.deliveries`), `[system]` end-to-end Capybara,
  `[unit]` POROs/services, `[gem]` the companion gem's own suite.
- **Time** is controlled in tests with `travel_to` / `freeze_time` — detection,
  grace windows and "X ago" formatting all depend on it.

### Money / cost-control constants (single source)
Define in `config/stablemate.rb` (a small config object or `Rails.application.config.x.stablemate`):
```ruby
MAX_MONITORS_PER_USER   = 5
SIGNUP_ACCOUNT_CAP      = 100
DETECTION_INTERVAL      = 30.seconds
PING_RETENTION          = 90.days
DEFAULT_GRACE_FRACTION  = 0.15   # gem-derived grace = 15% of interval, min 5.minutes
```
Tests assert behaviour **relative to these constants**, never hard-coded numbers,
so changing a constant doesn't break the suite.

### Security defaults
- `ping_token` and `ApiKey` raw tokens are **secrets**: tokens are random,
  stored hashed (SHA-256) where the PRD says so, compared in constant time,
  shown raw exactly once. Unknown ping token → opaque `404` (no tenant leak).
- All tenant-scoped queries go through `current_user.monitors` (never
  `Monitor.find` by bare id in user-facing controllers) — cross-tenant access
  must be impossible, and there is a test for it in every CRUD slice.

---

## 4 · Reconciled data model (authoritative)

This merges the PRD §3 tables with the design handoff's `source` / task-key
concepts. **Build to this table set.** Columns added beyond the PRD are marked ⊕.

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

- `registration_key` ≡ the design handoff's `solid_queue_task_key` (the
  `recurring.yml` task key). One column, two names — call it `registration_key`.
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

### Phasing of migrations
A phase only creates the tables it needs (see each spec). Forward-compat columns
(`plan`, `monitor_type`, `source`, `registration_key`) ship from the migration
that first introduces their table, so later phases never need a destructive
migration.

---

## 5 · Phase map

| Phase | Spec | Ships | Depends on |
|---|---|---|---|
| 0 | [`phase-0-walking-skeleton.md`](phase-0-walking-skeleton.md) | One real ping end-to-end | — |
| 1 | [`phase-1-auth-monitors-detection-alerting.md`](phase-1-auth-monitors-detection-alerting.md) | Auth, monitor CRUD + cap, detection, email alerts | 0 |
| 2 | [`phase-2-uptime-history-retention.md`](phase-2-uptime-history-retention.md) | 90-day uptime history, rollups, pruning | 1 |
| 3 | [`phase-3-api-and-gem.md`](phase-3-api-and-gem.md) | `/api/v1`, API keys, sync, companion gem | 1 (2 for richer detail data) |
| 4 | [`phase-4-launch-hardening.md`](phase-4-launch-hardening.md) | Waitlist/signup cap, rate-limit, deliverability, docs | 1–3 |

Cross-cutting UI direction lives in
[`design-system.md`](design-system.md) — every phase that builds screens reads it.

Phases 0→1→2 are strictly sequential. **Phase 3 can run in parallel with Phase
2** once Phase 1 lands (the gem/API need monitors + auth, not uptime history),
with the caveat that the API's read endpoints surface richer status once Phase 2
data exists.
