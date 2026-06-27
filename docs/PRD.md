# Checkmate — Product Requirements Document (V1)

> Cron monitoring for Rails / Solid Queue developers.
> Self-hosted Rails 8 app + a companion Ruby gem that auto-registers heartbeat
> monitors from `config/recurring.yml`.

**Status:** Draft for V1
**Last updated:** 2026-06-27
**Owner:** Chris Gilbert

---

## 1. Summary

Checkmate is a self-hosted cron/background-job monitoring tool. A monitored job
sends a lightweight "ping" to a unique URL each time it runs; if no ping arrives
within the expected interval plus a grace period, Checkmate alerts the owner by
email. Each monitor has a public status page showing uptime history.

The product's wedge is the **companion gem**: Rails/Solid Queue apps drop it in,
and it auto-registers a heartbeat monitor for every recurring job in
`config/recurring.yml` and pings on each successful run — with zero manual
instrumentation.

### Confirmed scope decisions (from discovery)

- **Heartbeat monitors only in V1.** HTTP/uptime monitoring is deferred to V2.
- **Email-only alerting in V1**, architected so webhook and Telegram channels
  are additive in V2.
- **Multi-tenant from day one**, single owner per monitor. No teams, no billing,
  no plan limits in V1.
- The `Monitor` model uses a `monitor_type` discriminator (`heartbeat` only for
  now) so HTTP monitors slot in later without a destructive migration.

### Default decisions taken where discovery left them open

- **Re-alerting:** V1 is **transition-only** — one alert when a monitor goes
  `down`, one recovery notice when it returns `up`. No periodic "still down"
  reminders in V1 (listed as a fast-follow).
- **Email verification:** **No hard gate in V1.** A verification email is sent
  but unverified accounts can still operate (self-hosted, low-abuse context).

---

## 2. Goals and Non-Goals

### 2.1 Goals

1. Let a developer create a heartbeat monitor and receive a unique ping URL in
   under a minute.
2. Detect a missed/late job run within one detection cycle of
   `expected_interval + grace_period` elapsing, and email the owner.
3. Email a recovery notice when a previously-down monitor pings again.
4. Provide a per-monitor **public status page** with uptime history.
5. Ship a **companion gem** that auto-registers heartbeats from
   `config/recurring.yml` and pings on successful Solid Queue job completion via
   `ActiveSupport::Notifications`, requiring no manual code in jobs.
6. Be cleanly **self-hostable on Hetzner via Kamal** with PostgreSQL + Solid
   Queue and no external service dependencies beyond outbound SMTP.
7. Keep the alerting layer **channel-agnostic internally** so V2 channels are
   purely additive.

### 2.2 Non-Goals (V1)

- **HTTP/uptime monitoring** (polling URLs, response-time charts, TLS-expiry
  checks). → V2.
- **Webhook / Telegram / Slack alert channels.** → V2 (architected for, not
  built).
- **Teams, organisations, shared ownership, roles/permissions.** → later.
- **Billing, plans, quotas, usage limits.**
- **Aggregated multi-monitor status sites, custom domains / CNAMEs** for status
  pages. → V2.
- **Cron-expression schedule parsing** (e.g. validating that pings line up with
  a `* * * *` spec). V1 uses a simple expected-interval model.
- **SMS/phone/PagerDuty escalation, on-call rotations.**
- **Periodic "still down" reminder emails.** → fast-follow.

---

## 3. Core Entities & Data Model

All tables use Rails 8 conventions (timestamps, bigint PKs unless noted).
Heartbeat detection is fundamentally one rule: *has a ping arrived within
`expected_interval + grace_period`?*

### 3.1 `User`
The tenant. Owns everything.

| Column | Type | Notes |
|---|---|---|
| `id` | bigint PK | |
| `email_address` | string, unique, not null | Rails 8 auth convention |
| `password_digest` | string | `has_secure_password` |
| `verified_at` | datetime, null | Set when email confirmed; not enforced in V1 |
| `created_at` / `updated_at` | datetime | |

Auth uses the **Rails 8 built-in authentication generator** (sessions +
`has_secure_password`). No Devise, no OAuth in V1.

### 3.2 `ApiKey`
Long-lived bearer token used by the companion gem. A user may have several
(e.g. one per app/environment).

| Column | Type | Notes |
|---|---|---|
| `id` | bigint PK | |
| `user_id` | bigint FK | |
| `name` | string | Human label, e.g. "production" |
| `token_digest` | string, unique | SHA-256 of the key; **raw key shown once** |
| `token_last4` | string | For display/identification |
| `last_used_at` | datetime, null | |
| `created_at` / `updated_at` | datetime | |

Raw token format: `cm_live_<random>`. Stored hashed; never recoverable.

### 3.3 `Monitor`
A single monitored thing. One table, discriminated by `monitor_type` so HTTP
monitors can join later.

| Column | Type | Notes |
|---|---|---|
| `id` | bigint PK | |
| `user_id` | bigint FK | Owner / tenant scope |
| `monitor_type` | string, not null | `"heartbeat"` only in V1 |
| `name` | string, not null | |
| `slug` | string, unique, not null | Public status-page identifier (random) |
| `ping_token` | string, unique, not null | Secret; embedded in the ping URL |
| `expected_interval_seconds` | integer, not null | How often a ping is expected |
| `grace_period_seconds` | integer, not null | Lateness tolerated before `down` |
| `status` | string, not null | `up` / `down` / `paused` / `pending` |
| `public_status_page` | boolean, default false | Status page 404s when off |
| `last_ping_at` | datetime, null | Drives detection |
| `next_due_at` | datetime, null | `last_ping_at + interval` (indexed) |
| `registration_key` | string, null | Stable key for gem idempotent upsert |
| `created_at` / `updated_at` | datetime | |

Notes:
- **`slug` (public) and `ping_token` (secret) are distinct.** The slug can be
  shared freely; the ping token must stay private. Status pages are not
  enumerable.
- `registration_key` is the recurring job's key/name from `config/recurring.yml`,
  scoped per `(user, app)` — used by the gem to upsert without duplicating.
- `pending` = created but never pinged yet (don't alert until first ping seen).
- Indexes: `slug` (unique), `ping_token` (unique),
  `(user_id, registration_key)` (unique, where present), `next_due_at`,
  `(status, next_due_at)`.

### 3.4 `PingEvent`
Raw record of a received ping. Append-only, high volume → pruned.

| Column | Type | Notes |
|---|---|---|
| `id` | bigint PK | |
| `monitor_id` | bigint FK | |
| `received_at` | datetime, not null | |
| `kind` | string | `success` (V1). Reserved: `start` / `fail` for gem run-state |
| `source_ip` | string, null | |
| `duration_ms` | integer, null | Optional: job runtime reported by the gem |
| `created_at` | datetime | |

Retention: **raw `PingEvent`s pruned after 90 days.**

### 3.5 `Incident`
One open record per down-period; the unit of alert **de-duplication**.

| Column | Type | Notes |
|---|---|---|
| `id` | bigint PK | |
| `monitor_id` | bigint FK | |
| `started_at` | datetime, not null | When monitor entered `down` |
| `resolved_at` | datetime, null | Null while open |
| `cause` | string | `missed_ping` (V1) |
| `created_at` / `updated_at` | datetime | |

**At most one open incident (`resolved_at IS NULL`) per monitor.** While an
incident is open, no further "down" alerts are sent — this is how flapping is
suppressed.

### 3.6 `UptimeDayStat` (daily rollup)
Pre-aggregated per-day stats powering long-term status-page history. Cheap, kept
indefinitely.

| Column | Type | Notes |
|---|---|---|
| `id` | bigint PK | |
| `monitor_id` | bigint FK | |
| `day` | date, not null | |
| `up_seconds` | integer | |
| `down_seconds` | integer | |
| `ping_count` | integer | |
| Unique index | `(monitor_id, day)` | |

### 3.7 `Notification`
Audit log of every alert dispatched. Channel-agnostic so V2 channels reuse it.

| Column | Type | Notes |
|---|---|---|
| `id` | bigint PK | |
| `monitor_id` | bigint FK | |
| `incident_id` | bigint FK, null | |
| `channel` | string | `email` (V1); future: `webhook`, `telegram` |
| `event` | string | `down` / `recovered` |
| `delivered_at` | datetime, null | |
| `created_at` | datetime | |

### 3.8 Retention policy (summary)

| Data | Retention |
|---|---|
| `PingEvent` (raw) | 90 days, then pruned |
| `UptimeDayStat` (rollup) | Indefinite |
| `Incident` | Indefinite |
| `Notification` | Indefinite (audit) |

Status page shows **90 days of uptime history** plus **recent ping events**.
(Response-time charts are deferred with HTTP monitoring; `duration_ms` is
captured opportunistically but not a V1 surface.) Retention is a global constant
in V1, not user-configurable.

---

## 4. State Machine & Alerting Logic

### 4.1 Monitor states

```
pending ──first ping──▶ up ──interval+grace elapsed, no ping──▶ down
   ▲                     ▲                                        │
   │                     └──────────────ping received────────────┘
   └─ (initial)        paused ◀──user pauses──▶ (resumes to up/pending)
```

- **`pending`**: created, never pinged. Not eligible for down-alerts.
- **`up`**: last ping within `interval + grace`.
- **`down`**: `now > last_ping_at + interval + grace`. Opens an `Incident`,
  sends a `down` email.
- **`paused`**: user-suspended; excluded from detection and alerting.

### 4.2 Detection

A **Solid Queue recurring job** runs every ~30–60s:

```
SELECT monitors WHERE status = 'up'
  AND next_due_at + grace_period_seconds < now()
```

Each match transitions `up → down`, opens an incident, enqueues a `down`
notification. This is a pure timestamp comparison — no outbound network calls.

### 4.3 Ping handling

On ping receipt for a monitor:
- Record a `PingEvent`, set `last_ping_at = now`, recompute `next_due_at`.
- If status was `pending` → `up`.
- If status was `down` → `up`, **resolve the open incident**
  (`resolved_at = now`), enqueue a `recovered` notification.
- If status was `up` → no-op beyond timestamps (no per-ping noise).

### 4.4 De-duplication & re-alerting (V1)

- **Transition-only.** Exactly one `down` email per incident; exactly one
  `recovered` email when it resolves.
- The open-incident invariant guarantees no duplicate down-alerts for a
  continuing outage.
- **No periodic reminders in V1.** (Fast-follow: an optional per-monitor "remind
  every N hours while down" flag — the data model already supports it via
  repeated `Notification` rows.)

---

## 5. User Flows

### 5.1 Sign up & first monitor (manual)
1. User registers (email + password); verification email sent (non-blocking).
2. Creates a monitor: name, expected interval, grace period.
3. Checkmate shows the **unique ping URL** and a `curl` snippet.
4. User wires the URL into their cron/job. First ping flips `pending → up`.

### 5.2 Adopt the companion gem (the wedge)
1. User generates an **API key** in the UI (shown once).
2. Adds the gem, sets `CHECKMATE_API_KEY` + endpoint.
3. On boot, the gem reads `config/recurring.yml` and **syncs** one heartbeat per
   recurring job (idempotent upsert by `registration_key`).
4. On each successful Solid Queue job run, the gem pings that monitor's URL via
   an `ActiveSupport::Notifications` subscriber. No per-job code.

### 5.3 Outage & recovery
1. Job fails to run / hangs; no ping arrives.
2. After `interval + grace`, detection flips the monitor `down`, opens an
   incident, emails the owner.
3. Job recovers and pings; monitor flips `up`, incident resolves, recovery email
   sent.

### 5.4 Public status page
- Anyone with the URL (`/status/:slug`) sees current status, 90-day uptime
  history, and recent ping events — **only if** `public_status_page` is on.
- Off → 404. Slugs are random and non-enumerable.

### 5.5 Manage monitors
- List / edit / pause / resume / delete; rotate `ping_token`; toggle the public
  page; manage API keys.

---

## 6. API Design (companion-gem facing)

Versioned JSON API under `/api/v1`. **Bearer auth** (`Authorization: Bearer
cm_live_…`) for management endpoints; the per-monitor **ping URL is
self-authenticating** via its secret token (no API key on pings — keeps the hot
path trivial and dependency-free in the gem).

### 6.1 Authentication
```
Authorization: Bearer cm_live_xxxxxxxxxxxx
```
Resolved by hashing and matching `ApiKey.token_digest`; identifies the tenant.
`last_used_at` is touched. Invalid/missing → `401`.

### 6.2 Sync monitors (idempotent bulk upsert)
The gem's core call — reconciles `config/recurring.yml` with Checkmate.

```
POST /api/v1/monitors/sync
Authorization: Bearer <key>
Content-Type: application/json

{
  "app": "my-rails-app",
  "monitors": [
    {
      "registration_key": "daily_digest",
      "name": "Daily digest mailer",
      "expected_interval_seconds": 86400,
      "grace_period_seconds": 3600
    },
    { "registration_key": "cleanup_job", "name": "Cleanup",
      "expected_interval_seconds": 3600, "grace_period_seconds": 600 }
  ]
}
```

Behaviour: upsert by `(user, registration_key)`. Returns each monitor with its
**ping URL** so the gem can map job → URL locally.

```
200 OK
{
  "monitors": [
    { "registration_key": "daily_digest",
      "ping_url": "https://checkmate.example.com/ping/<ping_token>",
      "status": "pending" },
    ...
  ]
}
```

> Reconciliation note: V1 upserts and leaves monitors no longer present in the
> payload untouched (it does not auto-delete). A `prune: true` option to pause
> orphaned monitors is a documented V2 extension.

### 6.3 Ping (hot path, self-authenticating)
```
GET|POST /ping/:ping_token        →  200 {"ok": true}
```
- Optional query/body: `duration_ms`, `kind` (`success` default; `start`/`fail`
  reserved for richer run-state in a later gem version).
- Unknown token → `404` (opaque; no tenant leakage).
- Designed to be callable by a bare `curl` for the manual flow too.

### 6.4 Convenience read endpoints (optional, same bearer auth)
```
GET /api/v1/monitors            → list caller's monitors
GET /api/v1/monitors/:slug      → single monitor + recent status
```

### 6.5 Transport & security
- HTTPS only (TLS terminates at the Kamal/Traefik proxy).
- Bearer token over TLS; **no HMAC/request signing in V1** (documented as a V2
  option if abuse appears).
- Ping endpoint is rate-limited per token to absorb misconfiguration.

---

## 7. Phased Delivery Plan

Each phase is shippable. Phase 0 is a **thin walking skeleton**: one real ping
travels end-to-end before any feature breadth is added.

### Phase 0 — Walking skeleton (end-to-end ping)
- Rails 8 app, PostgreSQL, Solid Queue, Kamal deploy to Hetzner, CI green.
- Migrations for `User`, `Monitor` (heartbeat), `PingEvent`.
- Hardcoded/seeded user + one monitor; `GET /ping/:ping_token` records a
  `PingEvent` and updates `last_ping_at`.
- A bare status read (even JSON) proving the loop.
- **Exit:** `curl` a ping URL in production → row persisted, timestamp moves.

### Phase 1 — Auth, monitors CRUD, detection & email alert
- Rails 8 authentication (sign up / in / out); tenant scoping.
- Monitor CRUD UI (name, interval, grace, pause/resume, token rotation).
- Detection recurring job; `up/down/pending/paused` state machine; `Incident`.
- Action Mailer `down` + `recovered` emails via a channel-agnostic dispatcher.
- **Exit:** create a monitor, stop pinging, receive a down email; resume pinging,
  receive recovery.

### Phase 2 — Public status page + retention
- `/status/:slug` (gated by `public_status_page`); current status + recent pings.
- `UptimeDayStat` rollup job; 90-day `PingEvent` pruning job; 90-day history on
  the page.
- **Exit:** public page renders real uptime history; old raw pings pruned.

### Phase 3 — API + companion gem
- `/api/v1` with bearer auth; `ApiKey` management UI; `POST /monitors/sync`.
- Companion gem: read `config/recurring.yml`, call sync on boot, subscribe to
  Solid Queue via `ActiveSupport::Notifications`, ping on success. Idempotent.
- **Exit:** add the gem to a sample Rails app → monitors auto-appear; a real job
  run pings automatically; stopping the job alerts.

### Phase 4 — Hardening & polish
- Ping rate-limiting; abuse/opaque-error review; mailer deliverability
  (SPF/DKIM); dashboards/empty states; docs + install guide; backup/restore
  runbook for the Hetzner box.
- **Exit:** documented, deployable, dog-fooded on Checkmate's own jobs.

### Deferred to V2 (explicitly)
HTTP/uptime monitoring (polling, response-time charts, TLS-expiry); webhook &
Telegram channels; teams/roles; "still down" reminders; status-page custom
domains & aggregated status sites; gem `prune`/reconciliation deletes; richer
run-state (`start`/`fail`) pings.

---

## 8. Open Questions

1. **Detection cadence vs. resolution.** A 30–60s sweep means down-detection can
   lag the grace boundary by up to one cycle. Acceptable for cron granularity —
   confirm the cycle length.
2. **Re-alert reminders** — keep strictly transition-only for V1 (current
   assumption), or pull the optional "still down every N hours" into V1?
3. **Email verification** — leave non-blocking (current assumption) or gate
   monitor creation on a verified address?
4. **Gem ping reliability** — fire-and-forget vs. a small retry/queue in the gem
   when Checkmate is briefly unreachable (a missed ping could false-alarm). Lean
   fire-and-forget for V1; flag if you want bounded retry.
