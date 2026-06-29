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
- **Every flow in the phase's "Required system tests (must ship)" list has a
  passing browser-driven (Capybara) system test.** A phase is not done if any are
  missing, even with all unit/request tests green. (Phase 0 is the one exception —
  it has no UI yet; its end-to-end proof is request/integration level.)
- `bin/rails test` **and** `bin/rails test:system` green; linter
  (`rubocop`/`standard`) clean. **`bin/ci` is the single command that runs all of
  this**; a PreToolUse hook runs it before every `git push` and blocks on failure
  (same script runs in GitHub Actions). Don't push red.
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
| 7 | Cap numbers | `MAX_MONITORS_PER_USER` / `SIGNUP_ACCOUNT_CAP`, **env-driven, default 0 ⇒ OFF/unlimited** (issue #16). Self-host has no caps/waitlist; the managed instance sets them (e.g. 5 / 100). When ON, the global cap re-opens **manually** (raise the env value). |
| 8 | Paused monitors vs. cap | **Count toward the cap.** A `paused` monitor still occupies a slot. Pausing is not a way to exceed the limit. |

---

## 3 · Conventions

### Architecture (non-negotiable)
Stablemate follows a **strict 37signals-inspired, vanilla-Rails** architecture:
keep `app/` small, put logic on records, **no `app/services/` directory**. Use
operation objects (noun, entity-scoped), concerns, sub-resource controllers,
coordinators, and the Command pattern (narrow) per the decision table in
[`../../CLAUDE.md`](../../CLAUDE.md). The concrete per-object/per-phase inventory
is [`architecture.md`](architecture.md) — **its names are normative**. Deviate
only with a one-line justification.

### Stack
- **Latest stable Rails (8.x)**, PostgreSQL, **Solid Queue** (jobs + recurring),
  Solid Cable (Turbo Streams), Solid Cache. Hotwire (Turbo + Stimulus), Tailwind
  CSS, server-rendered (no SPA). Deploy via Kamal to Hetzner. (PRD §2.1.6)
- **Rails 8 built-in authentication generator** (sessions + `has_secure_password`).
  No Devise, no OAuth. (PRD §3.1)

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
  Capybara/Selenium **system tests**. Test scenarios below are written
  framework-agnostically as `Given/When/Then`; a sub-agent may use RSpec +
  FactoryBot instead **if it keeps the whole suite consistent** — pick one and
  stay with it. *(If the team prefers RSpec project-wide, say so and this default
  flips; nothing in the scenarios assumes Minitest.)*
- Layers: `[model]` unit, `[request]` controller/integration, `[job]` Solid Queue
  jobs (use `perform_enqueued_jobs` / inline adapter), `[mailer]` Action Mailer
  (assert via `ActionMailer::Base.deliveries`), `[system]` end-to-end Capybara,
  `[unit]` operation objects / concerns / coordinators, `[gem]` the companion
  gem's own suite.
- **Time** is controlled in tests with `travel_to` / `freeze_time` — detection,
  grace windows and "X ago" formatting all depend on it.

#### System tests (`[system]`) — required, browser-driven
Agents skip these; the specs don't let them. Each phase spec lists **"Required
system tests (must ship)"** — those are Definition-of-Done gates, not optional.
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
- One robust test per flow — not every field permutation (that's `[model]`/`[request]`).

### Money / cost-control constants (single source)
Define in `config/initializers/stablemate.rb` (the `Stablemate` module, mirrored to
`Rails.application.config.x.stablemate`):
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
re-deriving the "0 ⇒ unlimited" rule at each call site.

Tests assert behaviour **relative to these constants**, never hard-coded numbers,
so changing a constant doesn't break the suite. The test environment sets the env
to the managed values (5 / 100) so the default suite exercises the caps-ON path;
caps-OFF tests stub the constants to 0.

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

**Implementing this?** Start with the
[`coordinator-playbook.md`](coordinator-playbook.md) — how to delegate phases to
specialist sub-agents, the sequencing, and the per-phase loop.

Cross-cutting direction every phase reads: [`design-system.md`](design-system.md)
(UI) and [`architecture.md`](architecture.md) (object layout). The root
[`../../CLAUDE.md`](../../CLAUDE.md) carries the architecture rules the coding
agent applies automatically.

Phases 0→1→2 are strictly sequential. **Phase 3 can run in parallel with Phase
2** once Phase 1 lands (the gem/API need monitors + auth, not uptime history),
with the caveat that the API's read endpoints surface richer status once Phase 2
data exists.
