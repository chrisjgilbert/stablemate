# Roadmap — deferred / post-launch

The canonical list of everything deliberately **out of V1**, with the rationale
and the source of truth for *why*. V1 is shipped. This doc is the durable
backlog; **GitHub issues are created per item only when work on it actually
starts**, and linked back here.

(The original PRD and per-phase build specs that these items were carved out of
have been archived out of the repo; the section citations below — "PRD §2.2",
"Phase 3 §7", etc. — are retained as historical provenance, not live links.)

> The architecture was built with seams so these land as *additive* code, not
> refactors: the channel-agnostic alerting layer (`Notifications::Channel`), the
> gem's `Registrars::Registrar` interface, and the channel-agnostic
> `Notification` audit log.

> **Pre-launch / ops tasks** (set SMTP creds, deliverability check, dog-food the
> deploy) are not V2 features — they live in the
> [operations runbook](runbook.md#0--pre-launch-checklist).

---

## V2 — committed direction

### Monitoring breadth
- **HTTP / uptime monitoring** — poll URLs, response-time charts, TLS-expiry
  checks. The anchor V2 feature. _(PRD §2.2)_
- **Response-time charts** — `duration_ms` is already captured on `PingEvent`
  but not charted; ships with HTTP monitoring. _(Phase 2 §1; PRD)_

### Public surface
- **Public / shareable status pages** — shareable `slug`, custom domains /
  CNAMEs, aggregated multi-monitor status sites. Bundled with HTTP monitoring (a
  *public service* status page is the coherent story; internal cron jobs have no
  external audience). _(PRD §2.2, §9; Phase 2 §6; design-system "removed from V1")_

### Alerting
- **Webhook / Slack alert channels** — architected for, not built. Add as new
  `Notifications::Channel` commands behind the existing contract; the
  `Notification` audit log is already channel-agnostic. _(PRD §2.2; architecture §5)_
- **Periodic "still down" reminder emails** — V1 is transition-only (one `down`,
  one `recovered`). Marked **fast-follow**. _(README §2 decision #2; PRD §2.2)_
- **Weekly digest email** — health summary of all a user's monitors (Dead Man's
  Snitch playbook). _(PRD §"Deferred to V2")_

### Richer run-state (the `/fail` story)
- **`/fail` check-in + error context** — a sibling
  `GET|POST /ping/:ping_token/fail` (Dead Man's Snitch pattern) capturing the
  failure's **error class + message** and surfacing it as alert context. The
  exception is already in the ActiveJob `perform.active_job` payload the gem
  subscribes to. **Keep full backtraces out** — that's an error tracker's /
  Mission Control's job (§10). _(PRD §6, §10; Phase 3 §7)_

### Companion gem
- **More registrar adapters** — `SidekiqCron` (`sidekiq-cron`), `GoodJobCron`
  (`good_job.cron`), `Whenever` (`config/schedule.rb`). The
  `Stablemate::Registrars::Registrar` seam exists so each is a new class, not a
  refactor. _(PRD §6.6; Phase 3 §1/§7)_
- **`prune` / reconciliation deletes** — a sync option to remove monitors absent
  from the payload (V1 never auto-deletes). _(Phase 3 §3.3, §7; PRD)_

### Operations / UX
- **Scheduled pause / maintenance windows** — mute a monitor over a known
  deploy/downtime window. _(PRD §"Deferred to V2")_
- **Incident acknowledgement** — explicitly cut from V1 (no `acknowledged_at`;
  incidents are open/resolved only); revisit on demand. _(design-system; PRD)_
- **User-configurable retention** — V1 retention is a global constant
  (`PING_RETENTION = 90.days`). _(Phase 2 §6)_

### API hardening
- **HMAC / request signing** for `/api/v1` — V1 is bearer-token-over-TLS only.
  _(PRD §6; Phase 3 §7)_

---

## Later / not committed

Listed for completeness; not on the V2 line.

- **Teams, organisations, shared ownership, roles/permissions.** _(PRD §2.2)_
- **Payment / checkout / metered billing / paid tiers.** V1 is one Free plan +
  a fixed cap; explicitly not planned. _(PRD §2.2; Phase 4 §6)_
- **Cron-expression schedule parsing/validation** (V1 uses a simple
  expected-interval model). _(PRD §2.2)_
- **SMS / phone / PagerDuty escalation, on-call rotations.** _(PRD §2.2)_

---

_Positioning guardrail (PRD §10): Stablemate detects the **silence** — runs that
didn't happen — and carries *just enough* error context to be actionable, linking
out to Mission Control / error trackers for the rest. Keep scope from drifting
into a neighbour's lane._
