# Design-Review Fixes — Concurrency, Billing & Reliability Hardening

**Goal:** close the correctness, concurrency, and product-logic gaps found in the
design review without changing the architecture. Every fix keeps the vanilla-Rails
shape — logic on records/operation objects, thin controllers, no `app/services/` —
and ships with the tests (incl. browser-driven system tests) the DoD requires.

This spec is organised as **work units (WU)**, each a self-contained, shippable
slice tagged with the review finding(s) it closes. Severity carried over from the
review: **H** = high, **M** = medium, **L** = low.

Architecture: [`../../CLAUDE.md`](../../CLAUDE.md) + [`architecture.md`](architecture.md).
The root cause behind WU-1/WU-3/M1 is the same missing ingredient — **no row
locking or state re-validation between the public check-in path and the detection
sweep** — so WU-1 is the keystone.

---

## 1 · Scope & dependencies

**In:** WU-1 … WU-11 below (all High, Medium, and Low findings).

**Out:** any new product surface. No status-history table (WU-10 uses a cheap
`first_ping_at` clamp instead); no webhook queue rework beyond keeping external
I/O out of the idempotency transaction; no gem transport rewrite (WU-8 is
result-handling only).

**Dependencies:** Phases 1–4 shipped. WU-1 lands first (other monitor-path WUs
build on the locking helper). WU-4…WU-7 (billing) and WU-8 (gem) are independent
and may land in any order.

---

## 2 · Data model / migrations

Three small, reversible migrations. No destructive changes.

| # | Change | For |
|---|--------|-----|
| 2.1 | **Unique partial index** `index_notifications_on_incident_and_event` on `notifications (incident_id, event) WHERE incident_id IS NOT NULL`. | M1 — DB backstop against a second `down`/`recovered` row for one incident. |
| 2.2 | Add **`monitors.first_ping_at`** (`datetime`, null). Backfill from the earliest surviving `PingEvent` per monitor (best-effort; null when unknown). | M8 — clamp rollup measurement so pre-first-ping days can't be scored `up`. |
| 2.3 | Add **`users.awaiting_downgrade_choice`** (`boolean`, `null: false`, `default: false`). | M5 — represent "owes a choose-N decision" distinctly from suspended-count. |

> **Locking:** we use pessimistic `with_lock` (a `SELECT … FOR UPDATE` reload) in
> the transition operations rather than adding a `lock_version` column, so the busy
> public ping path never raises `StaleObjectError`. No schema change for WU-1/WU-3.

The two caps stay config-gated per README §2; `FREE_PLAN_MONITOR_LIMIT` remains the
single source for the choose-N count (do **not** hard-code 5 in views/JS/specs).

---

## 3 · Behaviour & contracts

### WU-1 · Concurrency-safe monitor transitions  *(H2 detection race, M1 double email)*

The public ping endpoint and the 30 s detection sweep both mutate the same
`monitors` row from stale in-memory reads. Serialise the read-modify-write.

- **`Monitoring::Monitor::MissedPing#call`** (`missed_ping.rb`): wrap the transition
  in `@monitor.with_lock` and, after the lock reloads the row, re-check **both**
  `up?` **and** `overdue_now?` before flipping to `down`. A monitor pinged between
  the `overdue` query and this call is no longer overdue → no-op (no false down,
  no incident, no email). The existing open-incident guard + `rescue
  RecordNotUnique` stays.
- **`Monitoring::Monitor::CheckIn#recover`** (`check_in.rb`): perform the recovery
  branch inside the existing transaction under `@monitor.with_lock`, re-checking
  `down?` after the reload. Two simultaneous recovery pings then serialise; only the
  first resolves the incident and creates the `recovered` notification. Index 2.1
  is the DB backstop — rescue its `RecordNotUnique` and skip the duplicate dispatch.
- The **`down` alert is unchanged** (already guarded). Keep dispatch/broadcast
  **after** the transaction commits.

Invariant after WU-1: a monitor is `down` **iff** it has an open incident (see
WU-2, which closes the one remaining way to break it).

### WU-2 · Pause/suspend/reactivate must reconcile the open incident  *(H1)*

A `down` monitor carries an open `Incident`. Today `pause!`/`suspend!` only flip
`status`, and a ping received while paused refreshes `next_due_at` without
resolving the incident — so a later resume lands on `up` with a **stranded open
incident**, which `UptimeRollup` then counts as unbounded downtime.

Add one record method and call it from both leaving-live paths:

- **`Monitoring::Monitor#resolve_open_incident!(at: Time.current)`** — resolves the
  currently-open incident if any (no notification; leaving-live is not a recovery
  the user should be emailed about). Idempotent.
- **`Pausing#pause!`** and **`Suspension#suspend!`**: when the monitor is `down`,
  call `resolve_open_incident!` as part of the same update. Rationale: a paused /
  plan-suspended monitor is "not measured" — it must not accrue downtime, and it
  must not resume `up` with a dangling incident.
- **`HeartbeatStates#reactivate_heartbeat!`**: if it lands on `up` (not overdue)
  but an incident is somehow still open, resolve it (belt-and-braces).
- **`UptimeRollup#raw_down_seconds`**: additionally ignore incident overlap on days
  the monitor was not being measured (defensive; with the above, no such incident
  should exist, but the rollup must never manufacture downtime for a not-measured
  window).

### WU-3 · Serialise the monitor-cap check-and-create  *(H3 + the sync variant)*

`within_monitor_cap` is an unlocked `count >= limit` read with no DB backstop, so
concurrent creates race past it.

- **UI create** (`MonitorsController#create`): perform the build+save inside
  `current_user.with_lock { … }` so concurrent creates for the same user serialise
  and each re-reads a fresh count. Keep the controller otherwise thin.
- **Gem sync** (`User::MonitorSync::Operation#call`): wrap the whole run in
  `@user.with_lock`, seeding `@slots` **after** acquiring the lock. The existing
  `RecordNotUnique` rescue (same-key idempotency) stays.
- No behaviour change for the happy path; only the race is closed. (Optional
  hardening note: a future `users.active_monitor_count` counter with a `CHECK`
  would move the invariant fully into the DB — out of scope here.)

### WU-4 · Reject checkout when already Pro  *(H4)*

`Billing::CheckoutsController#create` must guard before creating a Stripe session:

```
return redirect_back_or_to(billing_subscription_path,
  alert: "You're already on Pro.") if current_user.subscribed_to_pro?
```

Uses the Pay mirror (`subscribed_to_pro?`), so it can't be fooled by a stale
client. Prevents a second concurrent subscription / double charge.

### WU-5 · Downgrade UX for Pro users at/under the Free cap  *(M4)*

The "Downgrade to Free" link shows for every Pro user, but `#new` always renders
the "select exactly N" picker and the Stimulus controller disables submit unless
`selected === limit`, so a Pro user with **fewer than `FREE_PLAN_MONITOR_LIMIT`**
monitors can never submit.

- **`DowngradesController#new`**: branch on `current_user.must_choose_downgrade?`
  (i.e. over the cap). Over cap → render the choose-N picker as today. At/under the
  cap → render a plain **confirm** view (no checkboxes, no `choose-five` controller)
  whose submit posts `keep_ids: []` to `#create`. `User::Downgrade#to_free!`
  already accepts the empty selection when not over cap (it skips the count check).
- **`choose_five_controller.js`** stays as-is for the over-cap picker.

### WU-6 · Involuntary downgrade → real choose-N lock  *(M5)*

Today an involuntary drop-to-Free auto-suspends the **newest** over-cap monitors,
so `over_free_cap_by` hits 0 and `must_choose_downgrade?` never fires — the user
can't re-pick which to keep, contradicting `User::Downgrade`'s own docstring and
PRD §5.6.

- **`User::Subscription#sync_plan_from_subscription!`**: when dropping to Free
  **over the cap**, set `awaiting_downgrade_choice = true` and suspend all over-cap
  monitors **keeping the oldest N** (unchanged safety default: stop billing/free
  monitoring immediately). Below/at the cap → ensure the flag is `false`.
- **`must_choose_downgrade?`** becomes `free? && awaiting_downgrade_choice?` (a
  real flag, not derived from suspended-count).
- **`DowngradesController#new`** in the awaiting state lists **all** the user's
  monitors (active **and** the involuntarily-suspended ones) so the user re-picks
  which N to keep active; `#create` reactivates the chosen, keeps the rest
  suspended, and clears `awaiting_downgrade_choice`.
- Returning to Pro (`restore_suspended_monitors!`) also clears the flag.
- Update the `User::Downgrade` docstring to match the shipped semantics.

### WU-7 · Livemode detection tolerant of restricted keys  *(M6)*

`Stablemate.stripe_livemode?` infers mode from an `sk_live_` prefix; a live
**restricted** key (`rk_live_…`) reads as test-mode, so every real event fails the
`event.livemode == stripe_livemode?` check and is silently dropped — customers pay
and stay Free.

- Broaden the check: `key.start_with?("sk_live_", "rk_live_")`. Keep the
  secret-key-prefix source (no new config) but cover both key classes. Document the
  `rk_test_`/`rk_live_` cases inline.

### WU-8 · Gem ping result handling + rotation resilience  *(M2, M3)*

- **`Stablemate::Client#ping`** (`gem/lib/stablemate/client.rb`): inspect the
  response instead of unconditionally returning `true`. `2xx` → `true`; any non-2xx
  → `log_warn("ping rejected: #{code}")` and `false`. A `404`/`410` (rotated or
  unknown token) is logged distinctly since it means the cached ping URL is dead.
- **Rotation resilience** (`Stablemate::Execution::Subscriber` / `Registration`):
  on a `404`/`410` from a ping, mark that ping URL stale and trigger a re-sync
  (bounded — at most once per interval) so a rotated token self-heals rather than
  silently ending monitoring. Alternatively (document the trade-off) keep the old
  token valid for a short grace window server-side; the gem-side re-sync is
  preferred as it needs no server change.

### WU-9 · Rate-limit the API and registration  *(M7)*

Sessions and password-reset are throttled; the bearer API and signup are not.

- **`Api::V1::BaseController`**: add `rate_limit` keyed on the API key (fallback IP)
  — a generous ceiling that never throttles a healthy gem sync cadence but bounds a
  compromised/buggy key hammering `sync`. Over-limit → the same opaque `401`/`429`
  shape (no enumeration signal).
- **`RegistrationsController#create`**: `rate_limit to: 10, within: 3.minutes`
  (mirroring `SessionsController`) — signup enqueues a verification email to a
  caller-supplied address, so an unthrottled endpoint is an email-bomb vector.

### WU-10 · Rollup can't score pre-first-ping / paused windows as up  *(M8)*

Backfill that runs after a status change can freeze never-pinged or paused days as
100 % up. Use the new `first_ping_at` (2.2) as a hard floor.

- **`Monitoring::Monitor::CheckIn`**: on the first successful ping (when
  `first_ping_at` is null), set `first_ping_at = received_at` in the same save.
- **`Monitoring::Monitor::UptimeRollup#measured_seconds`**: clamp `window_start` to
  `max(created_at, first_ping_at, day_start)`. A day entirely before the first ping
  → zero measured seconds → no-data (never `up`), regardless of the monitor's
  current status when the backfill runs.

### WU-11 · Low-severity cleanup batch  *(L)*

Small, independent fixes; ship together.

1. **Blank-password reset** (`PasswordsController#update`): require `password`
   presence before treating the update as a reset. A blank password currently
   passes `allow_nil`, returns `true`, destroys sessions, and shows "Password has
   been reset" while the old password still works. Reject blank → re-render the
   edit form with an error.
2. **Email verification GET → POST** (`EmailVerificationsController`): the verify
   link mutates state on `GET`, so link prefetchers auto-verify. Render a
   confirm page on `GET` and mutate on `POST` (a one-button form). Low impact
   today (verification is non-blocking) but correct.
3. **`down` email "expected by" snapshot** (`MonitorMailer#down`): capture the
   outage's due time on the `Incident`/`Notification` at detection and render that,
   so a recovery before the async send doesn't rewrite the line to the
   post-recovery schedule.
4. **Broadcast only on real state change** (`Monitor#broadcast_status_update` /
   `CheckIn`): gate the Turbo broadcast on an actual status transition so `up→up`
   and paused/suspended pings don't emit no-op re-renders — matching the method's
   own stated contract.
5. **Pin day math to one zone** (`UptimeRollup` UTC windows vs `Date.current`
   read-side): introduce a single `Stablemate` day-boundary helper (or assert UTC)
   used by both sides, so uncommenting `config.time_zone` can't produce off-by-one
   day stats.
6. **`app:` sync param**: either wire it through `User::MonitorSync` (scope keys
   per app) or drop it from the controller/gem contract — no silently-ignored
   field.
7. **Gem dispatcher drain** (`Execution::Subscriber`): drain in-flight `Thread.new`
   ping threads on shutdown (or offer a synchronous dispatcher) so the last ping
   before SIGTERM/deploy isn't lost. Documented trade-off acceptable.
8. **Cosmetic**: drop the redundant `secure_compare` (or fix its comment) in
   `ApiKey::Authentication`; set `secure: Rails.env.production?` explicitly on the
   session cookie; use `@monitor.open_incident` in `monitors/show.html.erb` instead
   of re-expressing the query.
9. **Idempotency transaction scope** (`Billing::ProcessedEvent.record_once`):
   minimise external Stripe/Pay I/O inside the claiming transaction — claim the
   event id in a short transaction, then run handlers, preserving the
   rollback-on-raise retry semantics.

---

## 4 · Test plan (write these first)

### WU-1 — locking / transitions
1. `[job]` Monitor `up`, overdue at query time; a ping commits (`up`, `next_due_at`
   advanced) before `flag_missed!` runs → **no** transition to `down`, **no**
   incident, **no** email. (Simulate by advancing state between load and call.)
2. `[job]` Genuinely overdue monitor still flips to `down`, opens one incident,
   sends one `down` email (regression guard).
3. `[model]` Two recovery `check_in!`s on a `down` monitor resolve the incident
   **once** and create exactly **one** `recovered` notification (index 2.1 holds;
   the second is a rescued no-op).
4. `[model]` Down-side concurrency still produces exactly one incident/`down` row.

### WU-2 — incident reconciliation
5. `[model]` Pause a `down` monitor → its open incident is resolved; `open_incident`
   is nil; `status == "paused"`.
6. `[model]` Suspend a `down` monitor → incident resolved; excluded from cap.
7. `[model]` down → pause → ping (while paused) → resume → monitor is `up` with
   **no** open incident (the previously-stranded case).
8. `[job]/[unit]` A day where the monitor was paused-while-down accrues **no** down
   seconds (no-data, not 100 % down) — the `raw_down_seconds` regression.

### WU-3 — cap races
9. `[request]` N concurrent `POST /monitors` for a user at `limit-1` create at most
   one; the rest fail the cap validation. (Thread/transactional harness.)
10. `[unit]` Concurrent `sync_monitors` runs for the same user never exceed
    `remaining_monitor_slots`.

### WU-4 — checkout guard
11. `[request]` A Pro user `POST /billing/checkout` → redirected with "already on
    Pro", **no** Stripe session created (assert the Pay/Stripe call is not made).
12. `[request]` A Free user checkout still starts a session (regression).

### WU-5 — downgrade UX
13. `[system]` Pro user with **fewer than** `FREE_PLAN_MONITOR_LIMIT` monitors:
    the downgrade page shows a plain confirm (no picker) and downgrading succeeds.
14. `[system]` Pro user **over** the Free cap still gets the choose-N picker,
    submit enabled only at exactly N.

### WU-6 — involuntary choose-N lock
15. `[model]` Webhook drop-to-Free while over cap → `awaiting_downgrade_choice` is
    true, over-cap monitors suspended (oldest N kept), `must_choose_downgrade?`
    true.
16. `[system]` In the awaiting state the picker lists **all** monitors (incl.
    suspended); confirming reactivates the chosen N, clears the flag, leaves the
    rest suspended.
17. `[model]` Re-upgrade to Pro clears `awaiting_downgrade_choice` and restores
    suspended monitors up to the Pro cap.

### WU-7 — livemode
18. `[unit]` `stripe_livemode?` is true for `sk_live_…` **and** `rk_live_…`, false
    for `sk_test_…`/`rk_test_…`.
19. `[request]` A live-mode event is processed when the instance uses a live
    restricted key (previously dropped).

### WU-8 — gem ping/rotation `[gem]`
20. `Client#ping` returns `false` and logs on `404`/`429`/`5xx`; `true` on `2xx`.
21. A `404` from a ping marks the URL stale and triggers a (bounded) re-sync.

### WU-9 — rate limits
22. `[request]` Over-limit API requests are throttled with the opaque shape; a
    healthy sync cadence is never throttled.
23. `[request]` `POST /registrations` beyond the window is throttled.

### WU-10 — rollup floor
24. `[job]` Monitor created day 1, first ping day 3; backfilling days 1–2 **after**
    it is `up` records them as **no-data**, not 100 % up.
25. `[model]` `CheckIn` sets `first_ping_at` on the first ping only (idempotent
    thereafter).

### WU-11 — cleanup
26. `[request]` Blank-password reset re-renders with an error; the old password
    still authenticates; sessions are **not** destroyed.
27. `[system]` Email verification requires the POST confirmation click; a bare GET
    (prefetch) does **not** verify.
28. `[mailer]` The `down` email's "expected by" reflects the outage's captured due
    time even when sent after a recovery.
29. `[unit]` No Turbo broadcast is emitted for an `up→up` or paused ping.
30. `[unit]` Rollup and read-side agree on "yesterday"/"today" under a non-UTC
    `Time.zone` (day-boundary helper).

### Required system tests (must ship) — browser-driven, Definition-of-Done gate
- **S-DR1 — Stranded-incident recovery (WU-2).** down monitor → pause (via the UI
  pause button) → drive a ping → resume → the badge returns to **Up** and the
  detail page shows **no** active-incident banner and no lingering "down" segment.
- **S-DR2 — Downgrade for a small Pro account (WU-5).** A Pro user with < N
  monitors visits Billing → Downgrade → sees a confirm (no picker) → downgrades →
  lands back on Billing as Free.
- **S-DR3 — Involuntary choose-N lock (WU-6).** After a simulated over-cap
  drop-to-Free, the Billing page shows the choose-N lock; the picker lists all
  monitors; confirming N leaves exactly N active and the rest suspended.
- **S-DR4 — Already-Pro checkout guard (WU-4).** A Pro user who reaches the
  checkout action is bounced back with the "already on Pro" notice and no Stripe
  redirect.

---

## 5 · Acceptance criteria

- [ ] **Invariant holds:** a monitor is `down` iff it has exactly one open incident;
      no path (detection race, pause/resume, concurrent recovery) can break it.
- [ ] A monitor pinged at the grace boundary never receives a false `down` (and thus
      no spurious `recovered`) email.
- [ ] Exactly one `down` and one `recovered` email per incident, under concurrency.
- [ ] The per-user monitor cap cannot be exceeded by concurrent UI creates or gem
      syncs.
- [ ] An already-Pro user cannot start a second subscription.
- [ ] Every Pro user can complete a downgrade through the UI; an involuntary
      over-cap drop leaves the account in a re-pickable choose-N state.
- [ ] A live restricted key processes live webhooks (no silently-dropped events).
- [ ] The gem reports a rejected ping as failed and self-heals after a token
      rotation.
- [ ] Rollup never scores a pre-first-ping or not-measured window as `up`.
- [ ] The WU-11 batch is closed (blank-password reset, GET-verification,
      expected-by snapshot, broadcast-on-change, day-zone, `app:` param, dispatcher
      drain, cosmetics, txn scope).
- [ ] **Required system tests S-DR1…S-DR4 pass** (`bin/rails test:system` green).
- [ ] All Test Plan scenarios pass; `bin/ci` (rubocop, brakeman/bundle-audit,
      `test`, `test:system`) green.

---

## 6 · Out of scope / guardrails

- No `lock_version` column (pessimistic `with_lock` chosen to keep the ping hot
  path free of `StaleObjectError`); no DB counter-cache for the cap (advisory only).
- No status-history table — WU-10 uses the cheaper `first_ping_at` clamp.
- No new billing product surface, no webhook job-queue rework beyond txn scoping.
- No gem transport rewrite — WU-8 is response-handling + bounded re-sync only.
- Caps stay config-gated (README §2); the choose-N count stays keyed off
  `FREE_PLAN_MONITOR_LIMIT`, never hard-coded.

---

## 7 · Suggested landing order (each commit green on its own)

1. **WU-1** (+ index 2.1) — the keystone; unblocks the monitor-path invariant.
2. **WU-2**, **WU-3** — finish the invariant and close the cap races.
3. **WU-4** — one-line billing guard.
4. **WU-10** (+ column 2.2) — rollup floor.
5. **WU-6** (+ column 2.3), **WU-5** — downgrade semantics + UX.
6. **WU-7**, **WU-9** — livemode + rate limits.
7. **WU-8** — gem reliability.
8. **WU-11** — the low-severity batch.
