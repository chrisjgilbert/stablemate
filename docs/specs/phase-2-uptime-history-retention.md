# Phase 2 — Uptime History (authenticated) + Retention

**Goal:** the monitor detail page shows real 90-day uptime history (the
`UptimeBar`) plus recent ping events, owner-only. Daily rollups make this cheap;
raw pings are pruned after 90 days.

PRD refs: §3.4 (PingEvent retention), §3.6 (UptimeDayStat), §3.8 (retention
summary), §5.4, §7 Phase 2, §9 (why owner-only, no public page).
Design refs: [`design-system.md`](design-system.md) — `UptimeBar`, `MiniTicks`,
detail "Uptime — last 90 days" panel + recent events.
Architecture: [`../../CLAUDE.md`](../../CLAUDE.md) +
[`architecture.md`](architecture.md) — jobs orchestrate, records do the work.

---

## 1 · Scope & dependencies

**In:**
- `UptimeDayStat` table + a **daily rollup job** aggregating each monitor's
  up/down seconds and ping count per day.
- Monitor detail **uptime panel**: 90-day `UptimeBar` + overall %, and a recent
  ping/events list (mono timestamps + durations).
- Dashboard-row `MiniTicks` (last-16 checks) + uptime %.
- A **pruning job** deleting raw `PingEvent`s older than `PING_RETENTION` (90d).
- Active-incident detail state (red banner: expected-by, grace elapsed, "down for
  Xh Ym"; **no Acknowledge**) — uses incidents from Phase 1.

**Out:** public/shareable status pages (V2); response-time charts (V2 — though
`duration_ms` is captured, it's not a V1 surface); user-configurable retention.

**Dependencies:** Phase 1 (monitors, incidents, pings, detail page shell).
Can be built in parallel with Phase 3.

---

## 2 · Data model / migrations

- New table **`UptimeDayStat`** (README §4): `monitor_id`, `day` (date),
  `up_seconds`, `down_seconds`, `ping_count`, unique `(monitor_id, day)`.
- No changes to existing tables.

---

## 3 · Behaviour & contracts

### 3.1 Daily rollup job (`RollupUptimeJob`, recurring, daily)
The job **orchestrates only** — it iterates monitors and calls
`monitor.roll_up_uptime(day)` (the `Monitor::UptimeRollup` operation object; the
`Monitor::Uptime` concern reads the results). For each monitor, for the day(s) not
yet rolled up, `roll_up_uptime`:
- Compute `up_seconds` / `down_seconds` for the day from `Incident` intervals
  (a day is "down" for the seconds it overlapped an open/!resolved or
  resolved-that-day incident; "up" otherwise — `paused`/`pending` windows count
  as no-data, not down).
- `ping_count` = `PingEvent`s received that day.
- **Idempotent upsert** by `(monitor_id, day)` so re-running a day overwrites,
  never duplicates. This matters because pruning removes raw pings — the rollup
  must run **before** the pruning horizon and be safe to re-run.
- Runs daily (e.g. `every day at 00:10` in `recurring.yml`), rolling up the
  previous complete day. Backfill: the job handles a range so a missed day
  recovers on next run.

### 3.2 Uptime presentation
- **90-day bar**: build a 90-element array (oldest→newest) of per-day status:
  `up` (green), `partial` (amber — any down-window that day), `down` (red — fully
  down), `no_data` (grey — before monitor existed / fully paused). Derive from
  `UptimeDayStat`; the current (incomplete) day is computed live from today's
  pings/incident. Feed `UptimeBar(days:)`.
- **Overall %** = `sum(up_seconds) / sum(up_seconds + down_seconds)` over the
  window, no-data excluded from the denominator.
- **MiniTicks** (dashboard): last 16 `PingEvent`s mapped to up/down ticks +
  uptime %. Down ticks correspond to detection-missed windows.
- **Recent events list** (detail): most-recent pings and incident open/resolve
  events, mono timestamps, `duration_ms` shown when present. Active incidents
  lead the list with the down event.

### 3.3 Pruning job (`PrunePingEventsJob`, recurring, daily)
- Delegates to a `PingEvent.prunable` scope + batched delete (the job is iteration
  only; the rule lives on the record): deletes `PingEvent` rows with
  `received_at < now - PING_RETENTION`.
- Deletes in batches (`in_batches`) to avoid long locks.
- **Ordering guarantee:** rollups for a day must be complete before that day's
  raw pings are pruned. Since pruning only touches rows older than 90d and rollup
  runs nightly on day-old data, this holds — but the pruning job asserts the
  day has a `UptimeDayStat` before deleting its pings (a safety check, logged if
  missing rather than deleting blind).

### 3.4 Active-incident detail banner
- When the monitor has an open incident: red banner with "Monitor is down — no
  ping received", `Expected by <next_due_at + grace>`, `grace <X> elapsed`,
  `down for <now - incident.started_at>`. Header badge = Down with pulsing dot.
  **No Acknowledge button.** Resolves visually once a ping recovers it.

---

## 4 · Test plan (write these first)

### Rollup job `[job]`
1. `freeze_time`; a monitor up all day → `UptimeDayStat` with
   `down_seconds == 0`, `up_seconds == 86400` (or the active window), correct
   `ping_count`.
2. A monitor with an incident from 10:00–12:00 → that day's `down_seconds ==
   7200`, rest up.
3. A day fully paused/before-creation → no-data (not counted as down); overall %
   denominator excludes it.
4. Re-running the job for the same day **overwrites** the row (no duplicate;
   unique `(monitor_id, day)` holds).
5. A missed run day is backfilled on the next run.

### Uptime presentation `[unit]`/`[system]`
6. The 90-day array has 90 elements, oldest→newest, with correct status per day
   incl. a live current-day bucket.
7. Overall % = up / (up + down), no-data excluded; matches a hand-computed
   fixture.
8. `[system]` detail page renders the `UptimeBar` (90 bars) + overall % + recent
   events list with mono timestamps.
9. `[system]` dashboard row renders `MiniTicks` (16) + uptime %.
10. `[system]` recent events list shows `duration_ms` when present.

### Pruning job `[job]`
11. Pings older than 90d are deleted; pings within 90d are retained.
12. Pruning a day that has **no** `UptimeDayStat` skips deletion and logs (safety
    check) rather than destroying un-rolled data.
13. Pruning runs in batches (assert it doesn't load all rows at once — e.g. via a
    query-count or `in_batches` stub).

### Active-incident banner `[system]`
14. A monitor with an open incident shows the red banner with expected-by, grace
    elapsed, and "down for …" — and **no Acknowledge button**.
15. After a recovering ping, the banner clears and the badge returns to Up.

---

## 5 · Acceptance criteria (PRD Phase 2 Exit)

- [ ] The monitor detail page renders **real** 90-day uptime history from rollups
      (not raw scans), plus recent ping events.
- [ ] Old raw `PingEvent`s (>90d) are pruned; rollups survive indefinitely.
- [ ] Uptime % and the bar match hand-computed fixtures.
- [ ] No public/shareable page exists (owner-only).
- [ ] All Test Plan scenarios pass; suite + linter green.

---

## 6 · Out of scope / guardrails
- No public status page, no `slug`, no public toggle (V2).
- No response-time charts (V2); `duration_ms` is displayed in the events list but
  not charted.
- Retention is a global constant, not user-configurable.
