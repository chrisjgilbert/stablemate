# Phase 0 — Walking Skeleton (end-to-end ping)

**Goal:** one real ping travels end-to-end in production before any feature
breadth is added. This phase is deliberately thin — it proves the loop and the
deploy pipeline, nothing more.

PRD refs: §7 Phase 0, §6.3 (ping), §3.1/§3.3/§3.4 (User/Monitor/PingEvent).
Architecture: follow [`../../CLAUDE.md`](../../CLAUDE.md) +
[`architecture.md`](architecture.md) — no `app/services/`; logic on records.

---

## 1 · Scope & dependencies

**In:**
- New Rails 8 app: PostgreSQL, Solid Queue, Solid Cable, Solid Cache, Hotwire,
  Tailwind, Propshaft.
- Migrations for `User`, `Monitor` (heartbeat), `PingEvent` — full reconciled
  columns from [`README.md` §4](README.md#4--reconciled-data-model-authoritative)
  so later phases don't re-migrate.
- A seeded user + one heartbeat monitor.
- `GET|POST /ping/:ping_token` endpoint that records a `PingEvent` and updates
  the monitor's `last_ping_at` / `next_due_at`.
- A bare status read (JSON is fine) proving the loop.
- CI green; Kamal deploy to Hetzner working.

**Out (deferred to later phases):** auth, monitor CRUD UI, detection/alerting,
incidents, uptime history, API keys, the gem. **No state machine yet** beyond
"a ping moves the timestamp" — `pending → up` transition is allowed here as the
simplest correct behaviour, but `down` detection is Phase 1.

**Dependencies:** none (greenfield).

---

## 2 · Data model / migrations

Create the three tables with the **full** reconciled columns (README §4). Even
though Phase 0 only exercises a few, ship them all now:

- `users` — incl. `plan` default `"free"`, `verified_at` null, `password_digest`.
- `monitors` — incl. `monitor_type` default `"heartbeat"`, `source` default
  `"manual"`, `status` default `"pending"`, `ping_token` unique, `registration_key`
  null, `expected_interval_seconds`, `grace_period_seconds`, `last_ping_at`,
  `next_due_at`. All README §4 indexes.
- `ping_events` — `monitor_id`, `received_at`, `kind` default `"success"`,
  `source_ip`, `duration_ms`, `created_at`.

`Monitor` generates a random unguessable `ping_token` on create (e.g.
`SecureRandom.uuid` or `SecureRandom.alphanumeric(32)`) via a `before_validation`
+ `validates :ping_token, presence: true, uniqueness: true`.

---

## 3 · Behaviour & contracts

### Ping endpoint
```
GET|POST /ping/:ping_token  →  200 {"ok": true}
```
`PingsController#create` stays thin and delegates to `monitor.check_in!` (the
first form of the `Monitor::CheckIn` operation object — see
[`architecture.md` §2](architecture.md#2--monitor--the-centre-of-gravity)). On a
valid token, `check_in!`:
1. Creates a `PingEvent` (`received_at = now`, `kind = "success"`, `source_ip`
   from request, optional `duration_ms` from query/body param).
2. Sets `monitor.last_ping_at = now`, `monitor.next_due_at = now + expected_interval_seconds`.
3. If `status == "pending"` → sets `status = "up"`. (Other transitions are Phase 1.)
4. The controller responds `200 {"ok": true}`.

`Monitor` generates its `ping_token` via a `Monitor::PingToken` concern (not inline
controller code).

On an unknown token → **`404`**, opaque body (no tenant leakage, no "monitor not
found" detail).

The endpoint is unauthenticated (the token *is* the credential) and CSRF-exempt
(it's a machine endpoint). Idempotent enough for `curl` — both GET and POST work.

### Status read (proof of loop)
```
GET /monitors/:id.json  →  200 { id, name, status, last_ping_at, next_due_at }
```
No auth in Phase 0 (auth arrives Phase 1; this read is replaced then). Purpose is
purely to observe the timestamp move.

---

## 4 · Test plan (write these first)

### Ping endpoint `[request]`
1. **Given** a monitor with a known `ping_token`, **when** `GET /ping/:token`,
   **then** responds `200 {"ok":true}` and a `PingEvent` row is created for that
   monitor.
2. **Given** a monitor, **when** pinged, **then** `last_ping_at` is set to now and
   `next_due_at == last_ping_at + expected_interval_seconds`. *(Use `freeze_time`.)*
3. **Given** a `pending` monitor, **when** pinged, **then** `status` becomes `"up"`.
4. **Given** a ping with `?duration_ms=1234`, **when** received, **then** the
   `PingEvent.duration_ms == 1234`.
5. **Given** an unknown token, **when** pinged, **then** responds `404` and no
   `PingEvent` is created.
6. **When** pinged via `POST` (not just GET), **then** it behaves identically
   (both verbs accepted).
7. **Then** the ping endpoint sets `source_ip` from the request.

### Monitor model `[model]`
8. **When** a `Monitor` is created without a `ping_token`, **then** one is
   generated and is unique.
9. **Then** two monitors cannot share a `ping_token` (db + model uniqueness).

### Status read `[request]`
10. **Given** a monitor, **when** `GET /monitors/:id.json`, **then** the JSON
    reflects current `status`, `last_ping_at`, `next_due_at`.

### Smoke `[system]`
11. A minimal system/integration test that seeds a user + monitor, pings the URL,
    and asserts the status read shows the moved timestamp — the "walking skeleton"
    proof in one test.

---

## 5 · Acceptance criteria

- [ ] `curl https://<deployed-host>/ping/<ping_token>` in **production** returns
      `200 {"ok":true}`, a `PingEvent` row persists, and `last_ping_at` moves.
- [ ] CI is green; Kamal deploy to Hetzner succeeds; `bin/rails db:migrate` runs
      clean on a fresh DB.
- [ ] Solid Queue, Solid Cable, Solid Cache are installed and boot (even if
      unused this phase).
- [ ] All Test Plan scenarios pass.

---

## 6 · Notes for the next phase
- Do **not** add `down` detection or incidents here — Phase 1 owns the full state
  machine and will build on `next_due_at`.
- The `GET /monitors/:id.json` read is a throwaway probe; Phase 1 replaces it with
  the authenticated dashboard/detail.
