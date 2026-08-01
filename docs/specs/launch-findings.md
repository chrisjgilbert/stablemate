# Pre-launch verification findings — fix tracker

Status: **IN PROGRESS**. Source: the 2026-08-01 pre-launch verification
campaign (6 adversarial subsystem reviews with probe reproduction + live
browser verification) run against `main` @ `2dea079` with full `bin/ci` green.
Companion to [`launch-readiness.md`](launch-readiness.md) — these fixes are an
implicit workstream ahead of that spec's WS-G launch switch. Each fix follows
TDD (failing test first), keeps `bin/ci` green, and gets a `/verify` pass
observing the real behaviour before its box is ticked.

Severity: **F1–F13** are the confirmed majors (fix before launch: F1–F9;
fix-soon races: F10–F13). **M-series** are minors — triaged below into
fix-now (batched with the majors), decision-needed, and backlog.

## Progress

**Wave 1 merged and verified (2026-08-01).** Batches A, B and D are on the
branch: **F1, F6, F7, F8, F10, F11, F12** plus **M9, M11, M12, M13** are fixed,
full `bin/ci` green (rubocop, brakeman, bundle-audit, unit/request, 57 system
tests, gem suite), and each fix passed a `/verify` pass observing the real
behaviour — browser-driven where user-visible (the interval edit driven through
the actual Stimulus preset field; the uptime panel rendering 98.35% instead of a
stale 100.00%), runner-driven against the live dev database where not (the
after-commit dispatch semantics, the suspend/reactivate memory, the rollup and
prune guards). Remaining: wave 2 — batches C, E, F.

Follow-ups raised during review (not yet findings, no owner):
- `Monitoring::Monitor::Suspension#reactivate!` still runs unlocked, so a
  `reactivate!` racing a `suspend!` is theoretically interleavable (F11 covered
  only `pause!`/`suspend!`).
- Display rounding can still make a very short outage today show an amber bar
  beside "100.00%" at 2 dp — a product call on flooring, not staleness.
- F7 interacts with E's F2: a gem sync that changes the interval now also moves
  `next_due_at`; read the two together when E lands.

## Fix batches (disjoint file sets; A–D + F parallel, E after A)

| Batch | Findings | Files owned |
|-------|----------|-------------|
| A — ping/state machine | F6, F7, F11, F12, M9 | `app/controllers/pings_controller.rb`, `app/models/monitoring/monitor.rb`, `monitor/{check_in,failure_report,pausing,suspension,heartbeat_states,ping_token}.rb` + their tests |
| B — alert delivery | F1, F10 | `config/environments/production.rb`, `app/models/notifications/*`, `app/mailers/*`, new initializer + tests |
| C — billing | F4, F5, F13, M3, M4, M5, M6 | `config/initializers/pay.rb`, `app/controllers/billing/*`, `app/models/billing/*`, `app/models/user/{subscription,downgrade}.rb`, `app/views/shared/_downgrade_grace_banner.html.erb` + tests |
| D — uptime/retention | F8, M11, M12, M13 | `app/models/monitoring/monitor/{uptime,uptime_rollup}.rb`, `app/models/ping_event.rb` + tests |
| E — gem & sync (after A) | F2, F3, F9, M7, M8 | `gem/**`, `app/models/project/monitor_sync.rb`, `app/controllers/monitors_controller.rb`, migration if needed + tests |
| F — auth/API/docs | M1, M2, M10, M15, M16 | `app/models/signup.rb`, `app/controllers/{registrations,projects}_controller.rb`, `app/controllers/api/v1/base_controller.rb`, `docs/api.md`, `docs/specs/README.md` + tests |

## Major findings

### F1 · Transient SMTP failure silently discards an alert — no retry layer exists
`config/environments/production.rb:63-64` sets `raise_delivery_errors = false`
with a comment claiming "alerting is retried by the job layer"; no `retry_on`
exists anywhere, the swallowed exception makes the delivery job *succeed*, and
`Notification.delivered_at` was stamped at enqueue. One SMTP hiccup = a lost
down/recovered email, invisibly. **Fix:** raise delivery errors so the mail
job fails, add retries to `ActionMailer::MailDeliveryJob` (bounded, backoff);
correct the comment; keep tolerating *unconfigured* SMTP per the documented
self-host intent. — [x] fixed · [x] verified

### F2 · Re-sync clobbers user-tightened interval/grace/name on every deploy
`app/models/project/monitor_sync.rb:113-123` unconditionally overwrites
`name`, `expected_interval_seconds`, `grace_period_seconds` from the gem
payload; the railtie re-syncs on every boot. Violates locked decision #5
("user can tighten via UI override") and `docs/integrating.md:116`. Probe:
tighten + rename → one re-sync reverted all three. **Fix:** preserve
user-modified values (e.g. only apply a gem value when the stored value still
equals the *previously gem-sent* value, or stamp overrides). — [ ] fixed · [ ] verified

### F3 · Weekday-restricted crons derive an interval that misses the weekend → false down every weekend
`gem/lib/stablemate/registrars/solid_queue_recurring.rb:29,125-135` samples 50
consecutive occurrences from boot time; for `*/15 9-17 * * 1-5` that never
spans Fri→Mon (derived 54,900s vs true 227,700s; `0 * * * 1-5` → 3,600s vs
176,400s — probed with real fugit). Weekly false alarms + false recoveries.
**Fix:** sample a horizon covering ≥ a full week (e.g. ≥ 8 days of
occurrences), not a fixed 50. — [ ] fixed · [ ] verified

### F4 · Pay automounts an ungated second Stripe webhook + an unauthenticated payments page
Pay 8.3 `automount_routes` defaults true and `config/initializers/pay.rb`
never disables it → live `POST /pay/webhooks/stripe` (verifies against the
same secret, bypasses `Billing::ProcessedEvent` idempotency, the livemode
gate, and plan sync — "customer paid but stayed Free" if Stripe points there)
and `GET /pay/payments/:id` (unauthenticated, embeds any PaymentIntent's
client_secret). **Fix:** `Pay.automount_routes = false` before initializers;
route test asserting `/pay/*` is gone. — [ ] fixed · [ ] verified

### F5 · `past_due` subscription allows a second checkout → double billing
`billing/checkouts_controller.rb:12` guards with `subscribed_to_pro?`, which
uses Pay's `active`-only scope; a `past_due` sub (plan already dropped to Free
by design) is invisible, so the user can subscribe again and the old sub's
dunning retry later succeeds → two live Pro subscriptions.
`pro_subscription` (`user/subscription.rb:163`) has the same blindness, so the
in-app downgrade can't cancel it either. **Fix:** guard on any non-terminal
Pro subscription (exclude only `canceled`/`incomplete_expired`), both places.
— [ ] fixed · [ ] verified

### F6 · Out-of-range `duration_ms` 500s the ping endpoint and discards the contact
`pings_controller.rb:82` guards non-numeric but not magnitude; int4 column →
`ActiveModel::RangeError` inside `CheckIn`'s transaction; PingEvent AND
`register_contact` roll back. A client always sending it loses every ping →
permanent false down that can never recover. Probe-confirmed. **Fix:** clamp
to int4 range (out-of-range → nil), same for negatives (M9). — [x] fixed · [x] verified

### F7 · Editing `expected_interval_seconds` never recomputes `next_due_at`
`next_due_at` is written only by `register_contact`; an interval edit leaves
the old cadence driving detection — loosening hourly→daily guarantees a false
down ~1h later (probed); tightening leaves detection blind up to the old
interval. Grace edits apply instantly (scope reads live column) — the
asymmetry is the trap. **Fix:** recompute `next_due_at` from `last_ping_at` +
new interval when the interval changes (model-side, so every write path gets
it). — [x] fixed · [x] verified

### F8 · `uptime_percent` ignores today's live incidents — stale 100.00% next to an amber bar
`monitor/uptime.rb:76-87` sums persisted `UptimeDayStat` rows only; today has
no row until the 00:10 rollup. Commit 88f8b1a fixed the *bar* half of #51
only; the API serves the same stale number. Probe: resolved 3h outage today →
`series.last == :partial`, `uptime_percent == 100.0`. **Fix:** blend today's
live up/down seconds (the bar's existing live computation) into the percent.
— [x] fixed · [x] verified

### F9 · The gem silently discards the sync response's `skipped` list
`gem/lib/stablemate/registration.rb:26-28` never reads `response["skipped"]`;
a cap-skipped job is unmonitored with zero gem-side signal, against the
registrar's own "a silently-unmonitored job is visible to the operator"
principle (and projects.md §7's assumption that the gem logs it). **Fix:**
`log_warn` per skipped entry with key + reason. — [ ] fixed · [ ] verified

### F10 · Alert mailer jobs enqueue inside an open DB transaction on reactivation paths
Webhook/choose-N paths (`ProcessedEvent.record_once` transaction →
`restore_suspended_monitors!`/`resolve_choice!` → `flag_missed!` →
`Dispatch#deliver` → `deliver_later`) enqueue to the *separate* queue DB while
the app transaction is open: a worker can deserialize before commit →
permanent `DeserializationError` (no retries), or the job is orphaned on the
designed Stripe-retry rollback. `enqueue_after_transaction_commit` is false in
Rails 8.1. Probe-confirmed mechanism. **Fix:** defer the dispatch to after
commit (e.g. `ActiveRecord.after_all_transactions_commit` in the channel, or
enqueue-after-commit config), keeping `delivered_at` semantics honest.
— [x] fixed · [x] verified

### F11 · `pause!`/`suspend!` read the open incident before taking the row lock
`monitor/pausing.rb:13-18`, `suspension.rb:22-27`: the incident SELECT runs
unlocked; racing the sweep leaves `status: paused` **with an open incident**
and a down email the user just tried to silence (probe-reproduced on two
connections), and the un-resolved incident later corrupts rollups
retroactively. **Fix:** take `with_lock` before reading, mirroring every
ping-path operation. — [x] fixed · [x] verified

### F12 · Suspension has no memory of `paused` — re-upgrade un-pauses silenced monitors
`suspension.rb:21-27` suspends paused monitors (callers include them via
`counting_toward_cap`, locked #8) and `restore_suspended_monitors!` →
`reactivate_heartbeat!` only knows pending/up/down → a paused monitor comes
back `up` or `down`+alert after a downgrade→re-upgrade cycle
(probe-confirmed), contradicting the code's own guard comment. **Fix:**
remember the pre-suspension status (column or restore-to-paused rule) so
restore returns paused monitors to `paused`. — [x] fixed · [x] verified

### F13 · The downgrade backstop never re-checks state before suspending
`user/subscription.rb:113-116` has no `must_choose_downgrade?` guard and
`over_free_cap_by` is plan-blind; the daily job's batch is loaded once, so a
re-upgrade committing mid-batch → a *paying* Pro user's monitors suspended
until the next webhook (probe: a pro-flagged user lost 3 monitors).
**Fix:** re-check `must_choose_downgrade?` on a reloaded record inside
`enforce_downgrade_fallback!`. — [ ] fixed · [ ] verified

## Minor findings

Fix-now (batched above):
- **M1** · Signup cap TOCTOU race — no serialization on the last slot
  (`signup.rb:22-26,43-55`); mirror the locked monitor-create path. *(F)*
- **M2** · Concurrent duplicate signup / duplicate project name → unrescued
  `RecordNotUnique` 500 (`signup.rb:43`, `projects_controller.rb:26`). *(F)*
- **M3** · Voluntary choose-N downgrade races its own cancel webhook →
  spurious involuntary-grace lock; `release_downgrade_lock_if_within_cap!`
  counts `monitors.count` instead of `counting_toward_cap`
  (`user/subscription.rb:126`), deepening the trap. *(C)*
- **M4** · Lock release runs only on billing page loads → stale nonsense
  banner after deleting monitors mid-grace; wire release into monitor
  destroy and fix the banner/confirm copy for the already-cancelled case. *(C)*
- **M5** · Pay's `payment_failed` email is `deliver_now` inside the webhook
  idempotency transaction (SMTP failure 500s the webhook; Stripe retries
  re-send it); Pay's stock customer emails are on and unreviewed → disable
  (`Pay.send_emails = false`) per launch-readiness D9's recommendation, noted
  as reversible. *(C)*
- **M6** · `ProcessedEvent.record_once` rescues `RecordNotUnique` around the
  whole block, not just the claim insert (`processed_event.rb:16-24`). *(C)*
- **M7** · Duplicate `registration_key` within one sync payload → doubled
  response entries (`monitor_sync.rb:64-79`). *(E)*
- **M8** · Entry with nil `grace_period_seconds` at cap misreported
  `limit_reached` instead of `invalid` (`monitor_sync.rb:98-101` —
  `nil.to_i == 0` passes the shape check). *(E)*
- **M9** · Negative `duration_ms` stored and rendered as negative latency. *(A)*
- **M10** · `/api/v1` rate limiter keyed on the attacker-controlled
  Authorization header — add a per-IP layer (`api/v1/base_controller.rb:24-27`). *(F)*
- **M11** · Prune/rollup deadlock: never-rolled days older than the 90-day
  horizon can never be pruned; warn-logs forever (`uptime.rb:46-49`,
  `ping_event.rb:24-35`). *(D)*
- **M12** · `roll_up_uptime(Date.current)` writes a corrupted permanent row
  for the incomplete day — add a today/future guard (`uptime_rollup.rb:33-45`). *(D)*
- **M13** · `mini_ticks_for` depends on unspecified SQL row ordering — add an
  explicit outer `ORDER BY` (`uptime.rb:22-37`). *(D)*
- **M15** · `docs/api.md` stale: "Settings → API keys" screen is gone,
  "(owner, registration_key)" identity predates Design B, 429/`skipped`
  vocabulary undocumented. *(F)*
- **M16** · Spec security bullet overclaims `ping_token` is hashed/shown-once
  (`docs/specs/README.md:122-124`) — it's plaintext by design and re-served by
  the API; scope the hashed/shown-once claims to `ApiKey`. *(F)*

Decision-needed (owner — not dispatched):
- **M17** · Sessions never expire server-side (stock Rails 8; revocation
  works). Decide idle/absolute timeout or accept.
- **M18** · Alert-notification crash window: a committed `Notification` with
  `delivered_at: nil` is never reconciled — accept (tiny window) or add a
  reconciliation sweep.
- **M19** · Renamed `recurring.yml` task key leaves a zombie monitor (one
  false down email, then permanently down, eating a cap slot) — product
  decision (`last_seen_in_sync_at` staleness flag is the cheap seam).

Backlog (post-launch fine):
- **M20** · `restore_suspended_monitors!` "oldest first" is actually PK order
  (`find_each` discards `order`) — behavioural nit, equal in practice.
- **M21** · `billing_processed_events` grows unboundedly — add pruning like
  the other ledgers.

## Definition of done

Every F-item fixed + `/verify`-passed; fix-now M-items fixed; decision items
answered by the owner; full `bin/ci` green; the fixes reviewed and merged as
standalone commits on the launch-readiness branch.
