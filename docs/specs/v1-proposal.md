# Stablemate V1 — the proposal

**One promise: a scheduled job stops running, we email you.** This document is
the forward-facing proposal — what V1 is, the architecture, and the plan, in
reading order, with no history. The engineering reference behind it is
[`v1-scope.md`](v1-scope.md): every edge case, trap, and required test,
hardened across eleven review rounds. Read this to decide; implementers go
there, per section, to build.

## Why change anything

A failed network call at boot once disabled every ping — silently and
permanently. The gem fetched its ping URLs from the server at startup, cached
them, and had no recovery path when the fetch failed. Rather than hardening
that path, V1 removes its preconditions: **nothing happens at boot, and
nothing is fetched.** The gem derives everything it needs locally.

The same change simplifies the product to one way in and one way to check in.
Monitors are declared in the repo and registered by a command; the web
interface becomes a dashboard.

## The architecture, in ten decisions

1. **Registration is a command.** `bin/rails stablemate:sync` reads
   `config/recurring.yml` — plus non-Rails monitors declared in
   `Stablemate.configure` — and registers everything, running from the
   post-deploy hook. Boot attaches a listener and does nothing else.

2. **Check-ins are addressed by task key and authenticated by header.**
   `POST /api/v1/monitors/{task_key}/pings` with `Authorization: Bearer
   sm_ping_…`. The gem already knows the task name, so nothing is fetched and
   nothing is cached — the incident's failure class is deleted, along with
   ~100 lines of the gem's hardest thread-safety code. The credential leaves
   the URL (and therefore the logs), and `GET` stops being able to trigger
   side effects.

3. **Two credentials, because one dominates the other.** The **ping key**
   (`sm_ping_…`) rides the hot path and can check in and prove itself —
   nothing else. The **API key** (`sm_live_…`) keeps the management surface.
   Both hashed, constant-time compared, shown exactly once. Separate tables,
   so a ping key authenticating the management API is impossible rather than
   discouraged.

4. **Monitor config is code, with exactly one writer.** Schedules derive from
   `recurring.yml`; interval overrides and non-Rails monitors are declared
   beside them in the initializer; the sync writes all of it, unconditionally.
   The UI never edits monitor config — it is a dashboard plus the two
   operational acts a human decides in the moment: pause and delete. The
   general rule, which also settles future questions: **job facts live in the
   repo; team facts (alert routing — V2) live in the UI; now-facts (pause)
   live in the UI.** One writer per fact means the old sync-vs-UI arbitration
   machinery is deleted, not improved.

5. **The CLI is the management surface, so its output is product.** Every
   registration prints its derived interval *and where it came from*
   (`weekday_report  every 72h  (derived from '0 9 * * 1-5')`), skips carry
   reasons, orphans are named with remedies, and exit codes mean something:
   registering nothing exits non-zero. Onboarding is
   `bin/rails stablemate:install` — dry-run by design: it writes config and
   the deploy hook, previews what production will register, and verifies both
   credentials end-to-end. Two pastes, two minutes, no deploy, and nothing
   faked — a synthetic "test check-in" would assert a job ran when it never
   has, so the dashboard renders honest waiting states instead and the first
   real ping is the demo.

6. **The sync can fully converge, safely.** `PRUNE=1` retires monitors whose
   tasks have left the config. Retire, never delete: history kept, cap slot
   freed, revived automatically if the task returns. Only tasks absent from
   the file *entirely* are prunable — a present-but-broken task entry is
   protected and reported, so a YAML typo can never turn monitoring off. Bake
   `PRUNE=1` into the deploy hook and "provision exactly what is declared"
   becomes policy committed to the repo.

7. **The schedule string rides the wire from day one.** V1 detection is
   interval-based — a weekday-only cron gets an honest, documented trade
   (a 72-hour window, or a tighter override that false-alarms at weekends) —
   but the raw cron expression is stored with each monitor, unused. Cron-aware
   detection, the real fix, is a **decided fast-follow** — and because the data
   already flows, it is a server-only upgrade: no gem release, no wire
   migration.

8. **Alerting: email in V1, Slack immediately after** — before any push for
   users. The never-checked-in alert ships *with* V1, because a registered job
   that never runs is the most important failure a job monitor can catch; it
   creates a notification, not an incident, and two small emails close its
   loops ("started checking in", and the project's first-ever check-in).
   Going over the plan's monitor cap is a persistent dashboard banner plus one
   email — never just a line in a deploy log.

9. **Free tier: 10 monitors.** Enough for a typical app's `recurring.yml`
   with headroom. Pro pricing is the one deliberately open product decision.

10. **Cutover in three phases, because server and gem ship separately.**
    Phase 1 is additive and server-only (new endpoint, keys, statuses — all
    inert until the new gem speaks). Phase 2 cuts the host over and *verifies
    a real check-in landed*. Phase 3 deletes the old surface. The old ping
    path keeps working until the new one is proven.

## What V1 deletes

The point of the architecture is what it makes unnecessary:

- The gem's URL cache, re-fetch throttle, resync mutex, and boot-time sync —
  the incident's entire habitat.
- `gem_may_write?` and the three settings-memory columns — the referee between
  two config writers, unnecessary once there is one writer.
- Monitor creation *and editing* in the web interface, the manual-monitor
  path, and the per-monitor `ping_token` with its rotation surface.
- The docs that taught any of the above.

## The plan

| Phase | Ships | Safe because |
|---|---|---|
| 1 | Server, additive: `PingKey`, check-in + verify endpoints, rate limits, `registration_key` backfill, `retired` status, sync-payload handling | Inert until a new gem speaks; old endpoint untouched |
| 2 | Gem 0.2.0: header auth, install command, overrides, prune; host cuts over | Old path still works; phase gate is a verified real check-in |
| 3 | Server, subtractive: old ping endpoint, tokens, rotation, UI forms deleted | Nothing depends on them once phase 2 is verified |

Each phase is one implementation effort with its tests specified in
[`v1-scope.md`](v1-scope.md) §12 and its details in §§5–8. Conventions are
[`CLAUDE.md`](../../CLAUDE.md): TDD, browser-driven system tests,
`/security-review` on the credential surfaces.

## Open

- **Pro pricing** (`v1-scope.md` §10) — the one undecided product question.
  It does not block phase 1.
- **Two decided fast-follows land after V1 and before any user-acquisition
  push:** the Slack channel, then cron-aware detection — the stored schedule
  strings get their algorithm, turning the weekday-job trade into a solved
  problem. Slack first: it is smaller and improves every alert; cron-aware
  second, since it carries one open design item (the schedule's timezone) and
  a deliberate behaviour change to communicate.

## For the agent picking this up

Implement **one phase at a time, in order**. Your brief is: *"Implement phase
N per `docs/specs/v1-scope.md` §8.1; required tests are in §12; follow
CLAUDE.md."* The reference doc is long because every paragraph guards against
a mistake that was actually made in review — when your implementation
contradicts it, say so in one line rather than silently deviating.
