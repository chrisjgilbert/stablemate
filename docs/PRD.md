# Stablemate — Product Requirements Document (V1)

> **Dead simple cron monitoring for Rails applications.**
> An open-source, multi-tenant Rails 8 app + a companion Ruby gem that
> auto-registers heartbeat monitors from `config/recurring.yml`.
>
> **Positioning:** Dead simple. The whole product is one promise — *if a
> scheduled job stops running, we email you.* Every V1 decision is filtered
> against that: if a feature doesn't serve "a Rails dev's cron job went quiet and
> they found out fast," it waits for V2.
>
> **Hosting model (decided): open source + paid hosting.** The Stablemate server
> app is **free and self-hostable** under AGPLv3 — run your own instance, no caps,
> your infrastructure. We *also* run a **paid, managed hosted version**
> (`stablemate.dev`) for teams who'd rather not operate it; that's the business.
> The same codebase powers both. Our Hetzner-via-Kamal setup is just how *we* run
> the managed instance, not part of the product.
>
> The **companion gem is MIT-licensed** (it embeds in users' apps); the **server
> is AGPLv3** (so a competitor can't run a closed fork as a rival hosted service).
> The paid tier's exact shape (managed-hosting-only vs. open-core feature-gating)
> is **not yet decided** — see §11.

**Status:** Draft for V1
**Last updated:** 2026-06-29
**Owner:** Chris Gilbert

---

## 1. Summary

Stablemate is an open-source cron/background-job monitoring tool for Rails
developers, offered both self-hosted (free) and as a paid managed service. A
monitored job sends a lightweight "ping" to a unique URL each time it runs; if no
ping arrives within the expected interval plus a grace period, Stablemate emails
the owner. The owner sees each monitor's status and uptime history in their
authenticated dashboard. That's the whole product.

The product's wedge is the **companion gem**: Rails/Solid Queue apps drop it in,
and it auto-registers a heartbeat monitor for every recurring job in
`config/recurring.yml` and pings on each successful run — with zero manual
instrumentation.

The gem is built in **two layers** (see §6.6):

- **Execution tracking** subscribes to ActiveJob's `perform.active_job`
  `ActiveSupport::Notifications` event — *not* a Solid-Queue-specific hook. Since
  Solid Queue is an ActiveJob backend, Solid Queue users get the identical
  result, but the same code makes the gem portable to any ActiveJob backend
  (Sidekiq, GoodJob, Resque, Delayed Job). Same effort, free portability.
- **Auto-registration** (schedule discovery) is inherently scheduler-specific and
  ships **Solid Queue `config/recurring.yml` only** in V1, behind a registrar
  adapter seam so other sources (`sidekiq-cron`, `good_job.cron`, the `whenever`
  gem) are additive in V2 without touching the core.

A consequence worth stating: even in V1, a non-Solid-Queue Rails app can create a
monitor manually and still get **automatic execution pings by job class** via the
ActiveJob layer — they just don't get the zero-config auto-registration magic
yet.

### Confirmed scope decisions (from discovery)

- **Heartbeat monitors only in V1.** HTTP/uptime monitoring is deferred to V2.
- **Email-only alerting in V1**, architected so webhook channels are additive in
  V2.
- **Multi-tenant from day one**, single owner per monitor. No teams in V1.
- **Open source + paid hosting (decided).** The server app is free and
  self-hostable (AGPLv3); we also run a paid managed instance. Same codebase.
  Model is **managed-hosting / feature parity** — the *only* gate is monitor
  count, no features are paywalled (§11).
- **Self-serve billing IS in V1 (Stripe-direct).** The hosted tier sells via
  **Stripe Checkout + Customer Portal**, with **Stripe Tax** for VAT/sales tax;
  flat tiers gated on monitor count (Free + Pro). Built with the **Pay gem**.
  Billing is **hosted-only and config-gated** (Stripe keys present → on); a
  self-hoster has no billing and no plan enforcement. Full detail in §12.
  Sequenced **last** (Phase 5) so the core product ships and is validated first.
- **Monitor cap and signup cap are hosted-instance policy, not product limits.**
  The per-user monitor cap (`MAX_MONITORS_PER_USER`) and the global signup cap +
  waitlist (`SIGNUP_ACCOUNT_CAP`) are **config-driven and default to OFF /
  unlimited**, so a **self-hoster has no caps and no waitlist**. On
  `stablemate.dev` the monitor cap becomes the **plan boundary** (Free = 5; Pro =
  higher/unlimited), driven by `User.plan` synced from the Stripe subscription.
  *Implementation note: the current build bakes the caps in — they need
  config-gating (issue #16).*
- The `Monitor` model uses a `monitor_type` discriminator (`heartbeat` only for
  now) so HTTP monitors slot in later without a destructive migration.
- **Gem execution tracking is built on ActiveJob**, not Solid Queue directly —
  portable to any ActiveJob backend at no extra cost. **Auto-registration is
  Solid Queue (`recurring.yml`) only in V1**, behind an adapter seam; other
  schedulers are V2.
- **Incident acknowledgement is out of V1.** Incidents open on `down` and resolve
  on recovery — no manual "acknowledge" step or `acknowledged_at` state. (The
  design comp included an Acknowledge action; it is cut.)

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
4. Show the owner each monitor's current status and **90-day uptime history** in
   the authenticated dashboard.
5. Ship a **companion gem** that auto-registers heartbeats from
   `config/recurring.yml` and pings on successful Solid Queue job completion via
   `ActiveSupport::Notifications`, requiring no manual code in jobs.
6. Be **straightforwardly self-hostable**: a multi-tenant Rails 8 app (PostgreSQL
   + Solid Queue) that runs from a single Docker image with env-based config and
   no external dependencies beyond outbound SMTP. The same app also runs as our
   **paid managed instance** on Hetzner via Kamal; self-hosting must be a
   first-class, documented path, not an afterthought.
7. Keep the alerting layer **channel-agnostic internally** so V2 channels are
   purely additive.
8. On the managed instance, let a Free user **self-serve upgrade to Pro** (Stripe
   Checkout) and manage/cancel their subscription (Stripe Customer Portal), with
   their monitor cap following their plan. Billing is hosted-only and invisible to
   self-hosters (§12).

### 2.2 Non-Goals (V1)

- **HTTP/uptime monitoring** (polling URLs, response-time charts, TLS-expiry
  checks). → V2.
- **Public / shareable status pages.** → V2, bundled with HTTP uptime
  monitoring, where a *public service* status page is a coherent story. Internal
  cron jobs have no external audience, so V1 keeps uptime history inside the
  owner's authenticated dashboard only. (See §9 for the rationale.)
- **Webhook / Slack alert channels.** → V2 (architected for, not built).
- **Teams, organisations, shared ownership, roles/permissions.** → later.
- **Usage / metered billing.** Pricing is flat tiers gated on monitor count — we
  do **not** meter pings or bill by usage. (Self-serve subscription billing itself
  *is* in V1 for the hosted tier — see Goal 8 and §12.)
- **In-app team billing, seats, multiple payment methods, marketplace billing.**
  V1 is a single Pro tier per account; teams/seats are V2.
- **Aggregated multi-monitor status sites, custom domains / CNAMEs.** → V2.
- **Cron-expression schedule parsing** (e.g. validating that pings line up with
  a `* * * *` spec). V1 uses a simple expected-interval model.
- **SMS/phone/PagerDuty escalation, on-call rotations.**
- **Periodic "still down" reminder emails.** → fast-follow.

> **Note — reversed decision:** earlier drafts listed *customer self-hosting* as a
> non-goal. That is reversed: self-hosting is now a **core goal** (Goal 6). What
> remains out of V1 is only the *paid* side's plumbing (billing/checkout above)
> and managed-tier niceties; the free self-hostable app is in scope.

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
| `plan` | string, not null, default `free` | `free` or `pro`; on the hosted tier synced from the Stripe subscription via webhook (§12). Always `free` on a self-hosted instance. |
| `created_at` / `updated_at` | datetime | |

Auth uses the **Rails 8 built-in authentication generator** (sessions +
`has_secure_password`). No Devise, no OAuth in V1.

**Monitor cap.** The cap is keyed off `plan` (Free = 5, Pro = higher/unlimited),
enforced on creation in both the UI and the API (§6.2). When caps are disabled by
config (the self-host default), there is no limit (issue #16).

### 3.1b Billing (hosted-only, via the Pay gem)
The managed tier uses the **[Pay gem](https://github.com/pay-rails/pay)** with the
Stripe backend, which provides its own tables — `pay_customers`,
`pay_subscriptions`, `pay_charges`, `pay_payment_methods` — associated polymorphically
to `User`. We do **not** hand-roll subscription state. `User.plan` is **derived
from the active `Pay::Subscription`** (kept in sync by Stripe webhooks, §12): an
active Pro subscription ⇒ `plan = "pro"`; none/cancelled ⇒ `free`. On a
self-hosted instance the Pay tables simply stay empty and everyone is `free` with
caps off. No new bespoke billing columns on `User` beyond `plan`.

### 3.1a `WaitlistSignup`
Captures interested emails once the launch signup cap is reached.

| Column | Type | Notes |
|---|---|---|
| `id` | bigint PK | |
| `email_address` | string, unique, not null | |
| `created_at` | datetime | |

When `User.count >= SIGNUP_ACCOUNT_CAP` (config, default 100), the sign-up flow
creates a `WaitlistSignup` instead of a `User`. No account, no monitors, no
login — just a list to invite from later. Raising the cap re-opens sign-ups.

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

Raw token format: `sm_live_<random>`. Stored hashed; never recoverable.

### 3.3 `Monitor`
A single monitored thing. One table, discriminated by `monitor_type` so HTTP
monitors can join later.

| Column | Type | Notes |
|---|---|---|
| `id` | bigint PK | |
| `user_id` | bigint FK | Owner / tenant scope |
| `monitor_type` | string, not null | `"heartbeat"` only in V1 |
| `name` | string, not null | |
| `ping_token` | string, unique, not null | Secret; embedded in the ping URL |
| `expected_interval_seconds` | integer, not null | How often a ping is expected |
| `grace_period_seconds` | integer, not null | Lateness tolerated before `down` |
| `status` | string, not null | `up` / `down` / `paused` / `pending` |
| `last_ping_at` | datetime, null | Drives detection |
| `next_due_at` | datetime, null | `last_ping_at + interval` (indexed) |
| `registration_key` | string, null | Stable key for gem idempotent upsert |
| `created_at` / `updated_at` | datetime | |

Notes:
- The **`ping_token` is secret** — it is the only credential on the ping path,
  so it must stay private. There is no public identifier in V1 (public status
  pages are deferred to V2, so no shareable `slug` is needed yet).
- `registration_key` is the recurring job's key/name from `config/recurring.yml`,
  scoped per `(user, app)` — used by the gem to upsert without duplicating.
- `pending` = created but never pinged yet (don't alert until first ping seen).
- Indexes: `ping_token` (unique),
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
| `channel` | string | `email` (V1); future: `webhook` |
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

The authenticated monitor detail view shows **90 days of uptime history** plus
**recent ping events**. (Response-time charts are deferred with HTTP monitoring;
`duration_ms` is captured opportunistically but not a V1 surface.) Retention is a
global constant in V1, not user-configurable.

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
1. User registers (email + password). **If the global signup cap is reached**,
   the form instead captures a `WaitlistSignup` and shows a "you're on the list"
   confirmation — no account is created (§3.1a). Otherwise a verification email is
   sent (non-blocking).
2. Creates a monitor: name, expected interval, grace period. On the hosted tier,
   once the Free cap is hit the form is **blocked with an "at your 5-monitor
   limit — upgrade to Pro" prompt** linking to checkout (§5.6). Self-hosted: no
   cap.
3. Stablemate shows the **unique ping URL** and a `curl` snippet.
4. User wires the URL into their cron/job. First ping flips `pending → up`.

### 5.2 Adopt the companion gem (the wedge)
1. User generates an **API key** in the UI (shown once).
2. Adds the gem, sets `STABLEMATE_API_KEY` + endpoint.
3. On boot, the gem's **Solid Queue registrar adapter** reads
   `config/recurring.yml` and **syncs** one heartbeat per recurring job
   (idempotent upsert by `registration_key`).
4. On each successful job run, the gem's ActiveJob subscriber
   (`perform.active_job`) pings the matching monitor's URL. No per-job code, and
   it works for any ActiveJob backend — Solid Queue users just also get step 3's
   auto-registration for free.

### 5.3 Outage & recovery
1. Job fails to run / hangs; no ping arrives.
2. After `interval + grace`, detection flips the monitor `down`, opens an
   incident, emails the owner.
3. Job recovers and pings; monitor flips `up`, incident resolves, recovery email
   sent.

### 5.4 Review status & history (authenticated)
- The owner opens a monitor's detail page and sees current status, the 90-day
  uptime bar, and recent ping events. This is owner-only; there is no public
  view in V1.

### 5.5 Manage monitors
- List / edit / pause / resume / delete; rotate `ping_token`; manage API keys.

### 5.6 Upgrade & manage subscription (hosted tier only)
1. A Free user clicks **Upgrade to Pro** (from billing settings or the at-limit
   prompt). We create/refresh their Stripe customer and redirect to a **Stripe
   Checkout** session (Stripe Tax computes VAT/sales tax at checkout).
2. On success, Stripe fires a webhook → Pay updates the subscription → `User.plan`
   becomes `pro` → the monitor cap lifts. The user lands back on a confirmation.
3. To change card, view invoices, or cancel, the user opens the **Stripe Customer
   Portal** (a hosted page) from billing settings. Cancellation/expiry fires a
   webhook → `plan` reverts to `free`.
4. **Downgrade over the cap:** if a now-Free user has more than the Free cap of
   monitors, existing monitors keep running, but **creating new ones is blocked**
   until they're back under the cap. We do not auto-delete or auto-pause. *(Policy
   choice — see §8 open questions.)*
5. This entire flow is **absent on a self-hosted instance** (no Stripe keys → no
   billing UI, no plans).

---

## 6. API Design (companion-gem facing)

Versioned JSON API under `/api/v1`. **Bearer auth** (`Authorization: Bearer
sm_live_…`) for management endpoints; the per-monitor **ping URL is
self-authenticating** via its secret token (no API key on pings — keeps the hot
path trivial and dependency-free in the gem).

### 6.1 Authentication
```
Authorization: Bearer sm_live_xxxxxxxxxxxx
```
Resolved by hashing and matching `ApiKey.token_digest`; identifies the tenant.
`last_used_at` is touched. Invalid/missing → `401`.

### 6.2 Sync monitors (idempotent bulk upsert)
The gem's core call — reconciles `config/recurring.yml` with Stablemate.

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

**Monitor cap handling (graceful, partial).** If the payload would take the user
over `MAX_MONITORS_PER_USER`, sync registers up to the cap and returns the
remainder under `skipped` with `reason: "limit_reached"` — it does **not** fail
the whole request. Already-existing monitors always update (the cap only blocks
*new* ones). The gem logs a warning for skipped jobs so the developer sees they
need to raise their plan (later) or trim monitored jobs.

```
200 OK
{
  "monitors": [
    { "registration_key": "daily_digest",
      "ping_url": "https://stablemate.dev/ping/<ping_token>",
      "status": "pending" },
    ...
  ],
  "skipped": [
    { "registration_key": "cleanup_job", "reason": "limit_reached" }
  ]
}
```

> Reconciliation note: V1 upserts and leaves monitors no longer present in the
> payload untouched (it does not auto-delete). A `prune: true` option to pause
> orphaned monitors is a documented V2 extension.

### 6.3 Ping (hot path, self-authenticating)
```
GET|POST /ping/:ping_token        →  200 {"ok": true}   # success check-in
GET|POST /ping/:ping_token/fail   →  200 {"ok": true}   # failure check-in (V2)
```
- Optional `duration_ms` on the success ping.
- **Failure reporting (V2, deferred):** a sibling `/fail` URL (Dead Man's Snitch
  pattern) marks the run as failed and may carry `error_class` / `error_message`
  for alert context — see §10. V1 ships success pings only; absence is the signal.
- Unknown token → `404` (opaque; no tenant leakage).
- Designed to be callable by a bare `curl` for the manual flow too.

### 6.4 Convenience read endpoints (optional, same bearer auth)
```
GET /api/v1/monitors            → list caller's monitors
GET /api/v1/monitors/:id        → single monitor + recent status
```

### 6.5 Transport & security
- HTTPS only (TLS terminates at the Kamal/Traefik proxy).
- Bearer token over TLS; **no HMAC/request signing in V1** (documented as a V2
  option if abuse appears).
- Ping endpoint is rate-limited per token to absorb misconfiguration.

### 6.6 Companion gem architecture (two layers + adapter seam)

The gem deliberately separates *how jobs run* from *how jobs are discovered*:

**Layer 1 — Execution tracking (backend-agnostic, V1).**
A single subscriber to ActiveJob's `ActiveSupport::Notifications` event
`perform.active_job`. On a successful `perform`, it looks up the monitor for that
job (by `registration_key`, derived from the job class) and fires a ping to
`/ping/:ping_token`. Because every mainstream Rails queue (Solid Queue, Sidekiq,
GoodJob, Resque, Delayed Job) runs jobs through ActiveJob, this one subscriber
covers them all. Failed/errored performs do **not** ping (a missed beat is the
signal). The hot ping path stays dependency-free (see §6.3).

**Layer 2 — Registration (scheduler-specific, adapter seam).**
A `Registrar` interface that produces `{registration_key, name,
expected_interval_seconds, grace_period_seconds}` tuples and calls
`POST /api/v1/monitors/sync` (§6.2):

| Adapter | Source of truth | Ships |
|---|---|---|
| `SolidQueueRecurring` | `config/recurring.yml` (`schedule:` → interval) | **V1** |
| `SidekiqCron` | `sidekiq-cron` schedule | V2 |
| `GoodJobCron` | `config.good_job.cron` | V2 |
| `Whenever` | `config/schedule.rb` | V2 |

Only the V1 adapter is built; the seam means a V2 adapter is a new class, not a
refactor. Cron schedules are converted to an `expected_interval_seconds` (the
gap between consecutive runs) with a default grace; manual override remains
possible in the UI.

**Mapping execution to registration.** Both layers key on `registration_key`
(stable, derived from the job/task identity), so a ping from Layer 1 finds the
monitor Layer 2 created. A non-Solid-Queue app that skips Layer 2 can still use
Layer 1 against a manually-created monitor whose `registration_key` matches the
job class.

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
- Rails 8 authentication (sign up / in / out); tenant scoping; `User.plan`.
- Monitor CRUD UI (name, interval, grace, pause/resume, token rotation), with the
  **plan-based monitor cap** enforced (Free = 5) and an at-limit message. Cap is
  config-gated and off by default for self-hosters (#16).
- Detection recurring job; `up/down/pending/paused` state machine; `Incident`.
- Action Mailer `down` + `recovered` emails via a channel-agnostic dispatcher.
- **Exit:** create a monitor, stop pinging, receive a down email; resume pinging,
  receive recovery. Creating a 6th monitor is blocked.

### Phase 2 — Uptime history (authenticated) + retention
- Monitor detail view: 90-day uptime bar + recent ping events, owner-only.
- `UptimeDayStat` rollup job; 90-day `PingEvent` pruning job.
- **Exit:** the detail page renders real uptime history; old raw pings pruned.

### Phase 3 — API + companion gem
- `/api/v1` with bearer auth; `ApiKey` management UI; `POST /monitors/sync`.
- Companion gem, two layers (§6.6): the ActiveJob `perform.active_job` execution
  subscriber (backend-agnostic) + the Solid Queue `recurring.yml` registrar
  adapter behind a `Registrar` seam. Idempotent.
- **Exit:** add the gem to a sample Solid Queue app → monitors auto-appear; a
  real job run pings automatically; stopping the job alerts. Verify the execution
  subscriber also fires on a non-Solid-Queue ActiveJob backend against a
  manually-created monitor.

### Phase 4 — Launch hardening, self-host packaging & polish
- **Launch signup cap + waitlist** (`SIGNUP_ACCOUNT_CAP`, `WaitlistSignup`,
  capacity-reached sign-up state) — config-gated cost protection; off for
  self-hosters (#16).
- **Self-host packaging:** Docker image + `docker-compose`, env-based config, a
  tested `docs/install.md` (#17).
- Ping rate-limiting; abuse/opaque-error review; mailer deliverability
  (SPF/DKIM); dashboards/empty states; backup/restore runbook for our Hetzner box.
- **Exit:** documented and deployable both ways — a self-hoster can stand it up
  from the guide with no caps; our managed instance has caps/waitlist on.

### Phase 5 — Hosted tier billing (Stripe self-serve)
The revenue layer; hosted-only and config-gated, so it never affects self-hosters.
Sequenced last so the core product ships and is validated first. **Touches
payments → run `/security-review`.**
- **Pay gem + Stripe** backend; `pay_*` tables; Stripe **Checkout** (upgrade) and
  **Customer Portal** (manage/cancel), plus **Stripe Tax** for VAT/sales tax.
- Webhook endpoint syncing `Pay::Subscription` → `User.plan`; the monitor cap
  follows the plan (Free = 5, Pro = higher/unlimited).
- Billing settings UI; the at-limit "Upgrade to Pro" prompt (§5.6); downgrade-
  over-cap handling (§8).
- All of it dormant unless Stripe keys are configured (self-host = no billing).
- **Exit:** on a Stripe-keyed instance, a Free user upgrades via Checkout → plan
  flips to Pro via webhook → cap lifts; cancel via Portal → reverts to Free. A
  keyless (self-host) instance shows no billing and stays unlimited.

### Deferred to V2 (explicitly)
> The live, triageable version of this list — grouped, with source refs and the
> per-item rationale — is maintained in [`docs/roadmap.md`](roadmap.md). The prose
> below is the original PRD record.

HTTP/uptime monitoring (polling, response-time charts, TLS-expiry); public /
shareable status pages (with custom domains & aggregated status sites);
registrar adapters for other schedulers (`sidekiq-cron`, `good_job.cron`,
`whenever`); webhook channels; teams/roles; "still down" reminders; incident
acknowledgement; gem `prune`/reconciliation deletes; richer run-state
(`start`/`fail`) pings — **including capturing the failure's error class +
message and surfacing it as alert context** (deferred but intended; the exception
is already available in the ActiveJob `perform.active_job` payload). Full stack
traces stay out of scope — that's Mission Control / an error tracker's job; see
§10. Also from the Dead Man's Snitch playbook: **scheduled pause / maintenance
windows** (mute a monitor over a known deploy/downtime window) and a **periodic
digest email** (weekly health summary of all a user's monitors).

---

## 10. Positioning vs. Mission Control — Jobs (and error trackers)

Recorded so future scope decisions don't drift into a neighbour's lane.

- **Mission Control — Jobs** is an in-app dashboard that introspects jobs the
  system *ran* (finished/failed, errors, backtraces, retry/discard). Stablemate's
  job is the inverse: detecting runs that **didn't happen** (scheduler down,
  broken `recurring.yml`, host offline, misconfigured cron) — the *silence* a
  queue dashboard is structurally blind to. Stablemate is also **external** (works
  when the app is down) and **push** (it emails you; a dashboard you must remember
  to check does not). They are complementary: Stablemate says *that* a scheduled
  job stopped running and roughly what broke; Mission Control is where you go to
  inspect and retry.
- **Error trackers** (Sentry, Honeybadger, AppSignal) own full exceptions +
  backtraces. Stablemate should carry just enough error context (class + message)
  to make an alert actionable, and link out for the rest — not become a worse
  error tracker.
- **Implication for the error feature above:** surface error class + message in
  the alert/detail (intended, deferred); keep full backtraces out. Staying in the
  "detect the absence, tell you, give just enough to know where to look" lane is
  what keeps the product *dead simple*.
- **Intended mechanism — a `/fail` check-in (Dead Man's Snitch pattern).** When
  the error feature lands, a job reports failure by hitting a sibling of its ping
  URL — `POST /ping/:ping_token/fail` — optionally carrying `error_class` and
  `error_message` in the body. Success pings the normal URL; a raised exception
  pings `/fail`. The gem's ActiveJob subscriber does this automatically (success
  vs. rescued exception on `perform.active_job`); a hand-rolled job can `curl` the
  `/fail` URL just as simply. This keeps the hot path trivial, stays curl-able,
  and captures just enough context (class + message) without a backtrace. It
  supersedes the earlier `kind=fail` query-param sketch in §6.3.

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
   when Stablemate is briefly unreachable (a missed ping could false-alarm). Lean
   fire-and-forget for V1; flag if you want bounded retry.
5. **Cron → expected-interval conversion.** The registrar derives
   `expected_interval_seconds` from a recurring task's cron `schedule:` (the gap
   between consecutive runs). Irregular crons (e.g. `0 9,17 * * *` — uneven gaps)
   don't have a single interval. V1 proposal: use the *largest* gap as the
   interval (avoids false alarms) and let the user override in the UI. Confirm.
6. **ActiveJob job → monitor mapping key.** Execution pings match a monitor by
   `registration_key` derived from the job class. Need to settle the exact
   derivation (class name vs. Solid Queue task key) so a recurring task and its
   ActiveJob `perform` resolve to the *same* monitor. Low risk, but pin it before
   the gem work in Phase 3.
7. **Cap numbers.** `MAX_MONITORS_PER_USER = 5` and `SIGNUP_ACCOUNT_CAP = 100` are
   placeholders chosen to bound cost at launch. Both are constants/config, trivial
   to change — confirm the figures (and whether the global cap should re-open
   automatically or stay manual).
8. **Paused monitors and the cap.** Does a `paused` monitor count toward the
   5-monitor limit? Proposal: **yes** (it still occupies a slot and could be
   resumed); pausing is not a way to exceed the cap. Confirm.
9. **Pro price & shape (billing).** What is Pro's monthly price, is there an annual
   discount, and is Pro "unlimited monitors" or a high fixed cap (e.g. 100)? Also:
   offer a free trial on Pro, or straight to paid? Needed before Phase 5.
10. **Downgrade over the cap.** When a Pro user cancels and is left with more than
    the Free cap of monitors, proposal: existing monitors keep running but **no new
    ones** until back under the cap (no auto-delete/auto-pause). Confirm — the
    alternative (auto-pause the newest over-cap monitors) risks silently dropping
    monitoring on a downgrade.
11. **Stripe-direct tax burden.** We chose Stripe-direct over a Merchant of Record,
    so VAT/sales-tax **registration and remittance are ours** (Stripe Tax only
    calculates). Confirm comfort with that ongoing admin; revisit an MoR (Paddle/
    Lemon Squeezy, both supported by Pay) if it becomes a burden.

---

## 9. Design rationale: why no public status pages in V1

The positioning is **"dead simple cron monitoring for Rails applications."** The
one promise is: *a scheduled job stops running → you get an email.* Features earn
their place only by serving that promise.

A *public, shareable* status page does not:

- **The audience doesn't exist for V1's subject.** Public status pages come from
  the uptime-monitoring playbook, where external users of a *public service* want
  to know "is it down, or just me?" V1 monitors **internal background jobs**
  (`nightly-db-backup`, `stripe-webhook-sync`). Nobody outside the team needs —
  or should have — a public page about whether a backup cron ran.
- **It's the orphaned half of a feature we already cut.** Public pages pair
  naturally with HTTP/uptime monitoring of public services, which is deferred to
  V2. Shipping the public display surface in V1 means building the front end for
  a capability that isn't there yet.
- **The valuable part is kept, just scoped correctly.** Uptime history (90-day
  bar, incident timeline, recent pings) is genuinely useful — *to the owner*. It
  lives in the authenticated dashboard, which we build regardless. Only the
  unauthenticated, shareable wrapper is cut.

**What we give up:** the "Powered by Stablemate" growth loop from shared pages.
That loop only spins if owners actually share these pages, which is unlikely for
internal jobs — speculative virality, and a weak reason to carry a whole feature
in the thinnest possible V1.

**When it returns:** V2, bundled with HTTP/uptime monitoring, where "show the
world your *service* is up" is a coherent story. (The deferred `slug` /
public-toggle fields slot back onto `Monitor` then, non-destructively.)

---

## 11. Hosting & licensing model (open source + paid hosting)

**Decided:** Stablemate is **open source and free to self-host**, and we **also**
sell a **managed hosted version**. The same codebase serves both — this is the
Plausible / PostHog / Sentry-style model, which fits a Rails-developer audience
that values self-hostable OSS.

**Licensing.**
- **Server app → AGPLv3** (`/LICENSE`). The copyleft + §13 network clause means
  anyone who hosts a *modified* version must publish their changes — deterring a
  competitor from running a closed fork as a rival hosted service.
- **Companion gem → MIT** (`/gem/LICENSE`). Users embed it in their own (often
  closed-source) apps, so it must be permissive; AGPL on a client library would
  kill adoption.

**Self-host vs. managed.**
- **Self-hosted instance:** no monitor cap, no signup cap, no waitlist — it's the
  operator's own infrastructure. These limits are config-driven and default OFF.
- **Managed instance (`stablemate.dev`):** we turn the caps/waitlist ON to bound
  cost at launch (§1). Deployed by us via Kamal on Hetzner.

**Paid-tier differentiation — DECIDED: managed-hosting / feature parity.** Every
feature lives in the OSS app; the paid tier is purely "we run it" plus a higher
monitor cap. **No features are paywalled** — the *only* difference between Free
and Pro is the monitor count. (We rejected open-core: it adds complexity and
community friction for little gain at this stage. Feature-gating could be
revisited far later, but is explicitly out of scope.)

Full billing design (Stripe-direct, flat tiers, self-serve in V1) is in **§12**.

**Implications (tracked):**
- Docker image + `docker-compose` + env config + tested `docs/install.md` — issue
  **#17**.
- Caps must be config-gated, default off for self-hosters — issue **#16**.
- Self-serve billing — **§12**, Phase 5.

---

## 12. Hosted tier & billing (decided)

Revenue layer for the managed instance only. **Hosted-only and config-gated** —
dormant unless Stripe keys are present, so self-hosters never see billing and stay
unlimited.

### Plans (flat tiers gated on monitor count)
| Plan | Monitors | Price | Notes |
|---|---|---|---|
| **Free** | 5 | £0 | The hosted on-ramp; bounded at launch by the signup cap/waitlist (§1). |
| **Pro** | higher / unlimited | flat £/mo (+ annual) | Lifts the cap. **Exact price + whether Pro is "unlimited" or a high cap are open — see §8.** |

No usage metering, no per-seat pricing (teams are V2). The monitor cap *is* the
plan boundary, driven by `User.plan`.

### Provider & stack — Stripe-direct via the Pay gem
- **[Pay gem](https://github.com/pay-rails/pay)** (Stripe backend) for subscription
  state — we don't hand-roll it. Idiomatic vanilla Rails; provides the `pay_*`
  tables (§3.1b).
- **Stripe Checkout** (hosted) for upgrade and **Stripe Customer Portal** (hosted)
  for card changes / invoices / cancellation — we build **no** card forms,
  dunning, or invoice UI. **No card data ever touches our servers** (PCI scope
  stays minimal).
- **Stripe Tax** computes VAT/sales tax at checkout. *Compliance note:* Stripe Tax
  calculates and collects, but as seller of record **we own registration and
  remittance** in the relevant jurisdictions (the deliberate trade-off vs. a
  Merchant of Record — see §8 for revisiting if admin gets heavy).
- **Webhooks** (`Billing::WebhooksController`) with **signature verification** are
  the source of truth: `checkout.session.completed`, `customer.subscription.*`,
  `invoice.*` → Pay updates `Pay::Subscription` → a thin sync sets `User.plan`.

### Architecture (vanilla Rails, per CLAUDE.md)
- Plan logic lives on the record: a `User::Plan` concern (cap keyed off `plan`)
  and a `User::Subscription` concern wrapping Pay. Checkout/portal are RESTful
  sub-resources (`Billing::CheckoutsController#create`,
  `Billing::PortalSessionsController#create`) — no `BillingService` bucket.
- Config-gate: a single `billing_enabled?` (true when Stripe keys are set). Off ⇒
  routes/UI hidden, caps unlimited, Pay tables empty. This is the self-host path.

### Security
Payments touch sensitive surface → **`/security-review` is required for Phase 5**:
verified webhook signatures, idempotent webhook handling, no trusting client-side
plan claims (plan only ever changes via a verified webhook), and the usual
opaque-error discipline.

### Out of scope for V1 billing
Coupons/credits, proration edge-case UI beyond Stripe defaults, multiple
currencies beyond Stripe's checkout defaults, invoicing/PO flows, team seats,
and feature-gating (parity model, §11).
