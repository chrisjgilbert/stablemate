# Phase 3 — API + Companion Gem (the wedge)

**Goal:** a Rails/Solid Queue app adds the `stablemate` gem + an API key, and its
recurring jobs auto-register as monitors and check in on their own — **no
per-job code**. This is the product's differentiator.

PRD refs: §1 (two-layer gem), §3.2 (ApiKey), §6 (API design), §6.6 (gem
architecture), §7 Phase 3, §10 (positioning). Design refs:
[`design-system.md`](design-system.md) — API keys screen + generate-key modal,
gem chip on monitors. Architecture: [`../../CLAUDE.md`](../../CLAUDE.md) +
[`architecture.md`](architecture.md) — `user.sync_monitors` operation, `ApiKey`
issuance/auth concerns, the gem's registrar **Command** seam. Integration ref:
[`../design/design_handoff_stablemate/SOLID_QUEUE_INTEGRATION.md`](../design/design_handoff_stablemate/SOLID_QUEUE_INTEGRATION.md).

---

## 1 · Scope & dependencies

**In:**
- `ApiKey` model + management UI (list, generate-with-once-shown-modal, revoke).
- `/api/v1` JSON API with **bearer auth**: `POST /monitors/sync`,
  `GET /monitors`, `GET /monitors/:id`, `POST /monitors/:id/rotate`.
- The **companion gem** (`stablemate`), two layers behind an adapter seam:
  - **Layer 1 — execution tracking:** subscribes to `perform.active_job`
    (`ActiveSupport::Notifications`), pings on successful perform. Backend-agnostic.
  - **Layer 2 — registration:** a `Registrar` interface; the **`SolidQueueRecurring`
    adapter** (V1 only) reads `config/recurring.yml`, calls `POST /monitors/sync`.
- Gem chip (`source == "gem"`) surfaced on dashboard rows + detail header
  (component already built in Phase 1; this phase makes sync set `source`).

**Out:** other registrar adapters (`SidekiqCron`, `GoodJobCron`, `Whenever` → V2);
the `/fail` check-in + error context (V2, see PRD §10); `prune`/reconciliation
deletes (V2); HMAC request signing (V2).

**Dependencies:** Phase 1 (monitors, auth, ping endpoint, gem chip component).
Phase 2 is not required, but `GET /monitors/:id` returns richer status when
Phase 2 data exists.

---

## 2 · Data model / migrations

- New table **`ApiKey`** (README §4): `user_id`, `name`, `token_digest` (unique),
  `token_last4`, `last_used_at`, timestamps.
- `Monitor` needs no new columns — `registration_key` and `source` already exist
  (from Phase 0). Sync sets them.

---

## 3 · Server-side behaviour & contracts

### 3.1 API key model + lifecycle
- Issued via `ApiKey.issue(user:, name:)` → `[api_key, raw_token]` (the
  `ApiKey::Issuance` operation); lookup via `ApiKey.authenticating(raw)` (the
  `ApiKey::Authentication` concern). No `ApiKeyService`.
- Raw format `sm_live_<random>` (e.g. `"sm_live_" + SecureRandom.alphanumeric(32)`).
- Store **SHA-256 digest** + `token_last4`. Raw key returned **once** at creation
  and never again (no plaintext persisted).
- Revoke = destroy the row (future requests with that key → `401`).
- `last_used_at` touched on each authenticated API request.

### 3.2 Bearer authentication (`/api/v1/*`)
```
Authorization: Bearer sm_live_xxxxxxxxxxxx
```
- Resolve by hashing the presented token and matching `ApiKey.token_digest`
  (constant-time compare). Identifies the tenant `User`. Touch `last_used_at`.
- Invalid/missing → `401` (opaque). All `/api/v1` actions are scoped to the
  resolved user's monitors.
- **Ping endpoints are NOT bearer-authenticated** — the per-monitor `ping_token`
  is the only credential on the hot path (PRD §6.3). Keep it that way.

### 3.3 `POST /api/v1/monitors/sync` (idempotent bulk upsert)
Thin controller (`Api::V1::Monitors::SyncsController#create`) → the
`user.sync_monitors(app:, entries:)` **operation object** (`User::MonitorSync`),
which owns the upsert + cap logic. No sync "service".

Request:
```json
{
  "app": "my-rails-app",
  "monitors": [
    { "registration_key": "daily_digest", "name": "Daily digest mailer",
      "expected_interval_seconds": 86400, "grace_period_seconds": 3600 }
  ]
}
```
Behaviour:
- **Upsert by `(user, registration_key)`.** Existing → update name/interval/grace
  (always allowed, even at cap). New → create with `source = "gem"`,
  `status = "pending"`, fresh `ping_token`.
- **Cap handling — graceful & partial (PRD §6.2):** if new monitors would exceed
  `MAX_MONITORS_PER_USER`, register up to the cap and return the rest under
  `skipped` with `reason: "limit_reached"`. **Do not fail the whole request.**
  Updates to existing monitors are never skipped.
- **No auto-delete:** monitors absent from the payload are left untouched (a
  `prune` option is V2).
- Response `200`:
```json
{
  "monitors": [
    { "registration_key": "daily_digest",
      "ping_url": "https://stablemate.dev/ping/<ping_token>",
      "status": "pending" }
  ],
  "skipped": [ { "registration_key": "cleanup_job", "reason": "limit_reached" } ]
}
```
Returns each registered monitor's **ping URL** so the gem can map job → URL locally.

### 3.4 Read + rotate endpoints
- `GET /api/v1/monitors` → caller's monitors (id, name, status, registration_key,
  ping_url, last_ping_at, next_due_at).
- `GET /api/v1/monitors/:id` → single monitor + recent status (richer with Phase 2).
- `POST /api/v1/monitors/:id/rotate` → new `ping_token`, returns new ping_url.

### 3.5 API keys UI
- `GET /settings/api_keys`: table (name, masked key `sm_live_••••a14c`, created,
  last used, Revoke). Empty state with "Generate your first key".
- Generate flow → modal showing the **full key once** (mono, dark field, Copy) +
  amber "you won't see this key again" warning + Done.

---

## 4 · Companion gem (`stablemate`)

Lives in `gem/` (or a sibling repo) with its **own test suite** (`[gem]`). It
must not depend on the host app's internals — only the public HTTP API.

### 4.1 Configuration
```ruby
Stablemate.configure do |c|
  c.api_key  = Rails.application.credentials.dig(:stablemate, :api_key) # sm_live_…
  c.endpoint = "https://stablemate.dev"   # overridable for self-test
  c.ping_on_success = true
end
```

### 4.2 Layer 1 — execution tracking (backend-agnostic)
- A single subscriber to `ActiveSupport::Notifications` event
  `perform.active_job`. On a **successful** perform, resolve the job to its
  `registration_key` and fire a ping to `/ping/:ping_token`.
- **Failed/errored performs do NOT ping** — a missed beat is the signal.
- **Ping delivery is fire-and-forget (decision #4):** best-effort single async
  request (background thread), errors swallowed, never blocks or raises into the
  job. No retry/queue in V1.
- The hot path carries no API key (uses the cached ping URL / token).

### 4.3 Layer 2 — registration (Solid Queue adapter, V1)
- A `Registrar` interface producing
  `{registration_key, name, expected_interval_seconds, grace_period_seconds}`
  tuples and calling `POST /api/v1/monitors/sync`.
- **`SolidQueueRecurring` adapter:** reads `config/recurring.yml` task entries.
  - `registration_key` = the **task key** (decision #6) — e.g. `daily_digest`.
  - `name` defaults to the task key.
  - `expected_interval_seconds` parsed from the task `schedule:` via **Fugit**.
    For **irregular crons** (uneven gaps), use the **largest gap** (decision #5).
  - `grace_period_seconds` default = `max(interval * DEFAULT_GRACE_FRACTION,
    5.minutes)` unless the user overrides in the UI.
- Runs on boot and via a `rails stablemate:sync` rake task. Idempotent.

### 4.4 Mapping execution → registration (decision #6)
Both layers key on the **Solid Queue task key**:
- Registrar writes `registration_key = task_key`.
- The execution subscriber maps an ActiveJob `perform.active_job` back to the
  recurring **task key** that scheduled it, then pings that monitor's URL.
  - Resolution: build a `job_class → task_key` map from `config/recurring.yml`
    at boot (a recurring task names its `class:`). A `perform` whose job class
    matches a recurring task pings that task's monitor.
  - **Edge case — two recurring tasks share a job class:** the map is
    `class → [task_keys]`; if ambiguous, the gem logs a warning and pings all
    matching monitors (documented limitation; rare). A non-recurring `perform`
    with no matching task key is ignored.
- **Non-Solid-Queue / manual fallback:** an app that skips Layer 2 can still use
  Layer 1 against a **manually-created monitor** whose `registration_key` matches
  the job class name. Document this path.

### 4.5 Gem reliability & safety
- Fire-and-forget; a Stablemate outage never breaks the host app's jobs.
- All network calls time out fast (e.g. 2s) and rescue everything.
- Sync failures log a warning and don't crash boot.

---

## 5 · Test plan (write these first)

### API key model `[model]`
1. Generating a key stores a SHA-256 digest + `token_last4`, returns the raw key
   once; the raw key is not persisted in plaintext.
2. Lookup by raw token matches via digest (constant-time); a wrong token doesn't.

### Bearer auth `[request]`
3. A valid `Authorization: Bearer` resolves the tenant and touches `last_used_at`.
4. Missing/invalid/revoked key → `401` (opaque).
5. `/api/v1/monitors` returns only the authenticated user's monitors.

### Sync endpoint `[request]`
6. New `registration_key`s create monitors with `source == "gem"`,
   `status == "pending"`, and a ping_url is returned.
7. Re-syncing the same payload updates (name/interval/grace) and does **not**
   duplicate (idempotent upsert by `(user, registration_key)`).
8. Cap overflow: a user at 4 monitors syncing 4 new ones registers 1 and returns
   3 under `skipped` with `reason: "limit_reached"`; the request is still `200`.
9. Updates to existing monitors succeed even when the user is at the cap.
10. Monitors absent from the payload are left untouched (no auto-delete).
11. The ping_url in the response actually works (pinging it records a `PingEvent`).

### Rotate / read `[request]`
12. `POST /monitors/:id/rotate` changes `ping_token`; old token → `404` on ping.
13. `GET /monitors/:id` returns the monitor's current status.

### API keys UI `[system]`
14. Generate-key modal shows the full `sm_live_…` once with a copy button and the
    amber "won't see again" warning; the list then shows only the masked form.
15. Revoke removes the key; subsequent API calls with it → `401`.
16. Empty state renders "Generate your first key".

### Gem — Layer 1 `[gem]`
17. A successful `perform.active_job` for a mapped job fires one ping to the
    correct ping URL.
18. A **raising** perform fires **no** ping.
19. Ping delivery is non-blocking and swallows network errors (stub the HTTP
    client to raise → job/perform still completes, no exception propagates).
20. A `perform` with no matching task key fires no ping.

### Gem — Layer 2 `[gem]`
21. Parsing a `recurring.yml` produces one tuple per `class:`-backed task;
    `registration_key == task key`; interval derived from `schedule:` via Fugit.
    `command:`-only (or blank-`class:`) tasks are **skipped with a logged
    notice** — execution tracking resolves pings by job class, so a command
    task's monitor could never be pinged. (Amended from "one tuple per task"
    when the skip shipped.)
22. An irregular cron (`0 9,17 * * *`) yields the **largest gap** as the interval.
23. Grace defaults to `max(interval * DEFAULT_GRACE_FRACTION, 5.minutes)`.
24. `sync!` posts to `/api/v1/monitors/sync` with bearer auth and caches the
    returned ping URLs; re-running is idempotent.

### Gem — mapping `[gem]`
25. `job_class → task_key` map is built from `recurring.yml`; a perform of that
    class resolves to the right task key / ping URL.
26. Two tasks sharing a job class → both monitors pinged + a warning logged.

### End-to-end gem `[gem]`/`[integration]`
27. (PRD Exit) Add the gem to a sample Solid Queue app → monitors auto-appear via
    sync; a real job run pings automatically; stopping the job → down alert.
28. The execution subscriber also fires on a **non-Solid-Queue ActiveJob backend**
    (e.g. the test/async adapter) against a manually-created monitor whose
    `registration_key` matches the job class.

### Required system tests (must ship) — browser-driven, Definition-of-Done gate
The gem/API flows above are `[gem]`/`[request]`; the **UI** flows below must be
real browser system tests:
- **S11 — Generate API key.** From `/settings/api_keys`, click Generate; the modal
  shows the full `sm_live_…` once with a Copy button and the amber "won't see
  again" warning; after dismissing, the list shows only the masked form.
- **S12 — Revoke API key.** Revoke a key from the list; it disappears from the table.
- **S13 — API keys empty state.** With no keys, the page shows the explainer +
  "Generate your first key".
- **S14 — Gem chip.** A monitor with `source == "gem"` shows the **gem chip** on its
  dashboard row and the **"synced from gem"** chip on its detail header; a manual
  monitor shows neither.

---

## 6 · Acceptance criteria (PRD Phase 3 Exit)

- [ ] `POST /api/v1/monitors/sync` is idempotent, enforces the cap gracefully
      (partial + `skipped`), and returns ping URLs.
- [ ] API keys can be generated (shown once), listed (masked), and revoked.
- [ ] Adding the gem to a sample Solid Queue app auto-registers monitors and they
      check in on successful runs with zero per-job code; stopping a job alerts.
- [ ] Layer 1 verified on a non-Solid-Queue ActiveJob backend.
- [ ] Fire-and-forget delivery never breaks the host app.
- [ ] **Required system tests S11–S14 all pass** (`bin/rails test:system` green).
- [ ] All Test Plan scenarios pass; suite + linter green; the gem has its own
      green suite.

---

## 7 · Out of scope / guardrails
- Only the `SolidQueueRecurring` registrar adapter ships. The seam (a `Registrar`
  base/interface) exists so V2 adapters are new classes, not refactors — but do
  **not** build them.
- No `/fail` endpoint or error-context capture (V2 — keep the hot path trivial;
  see PRD §10).
- No `prune`/reconciliation delete, no HMAC signing.
