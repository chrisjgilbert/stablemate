# Coordinator playbook

For the agent coordinating implementation. **You don't write the app yourself —
you delegate each phase to a specialist sub-agent, review their work, and keep
`main` green and linear.** Everything you need is already in the repo.

## Read first (in order)
1. [`../../CLAUDE.md`](../../CLAUDE.md) — architecture (no `app/services/`),
   Hotwire-first, vanilla Rails, system-tests rule, CI gate, git hygiene.
2. [`README.md`](README.md) — locked decisions, reconciled data model, conventions,
   Definition of Done, phase map.
3. [`architecture.md`](architecture.md) — the normative object inventory.
4. [`design-system.md`](design-system.md) — tokens, components, screens.
5. The phase spec you're about to delegate.

## Sequencing
```
Phase 0 ──▶ Phase 1 ──▶ ┌─ Phase 2 ─┐──▶ Phase 4
                        └─ Phase 3 ─┘
```
- **0 → 1 → 2** are strictly sequential.
- **Phase 3 can run in parallel with Phase 2** once Phase 1 is merged (the API/gem
  need monitors + auth, not uptime history).
- **Phase 4 is last** (it hardens 1–3).

Start every phase only after its dependency is merged to `main`.

## How to delegate (per phase)
Spawn one specialist sub-agent (Agent tool) per phase — or split a phase into a
few parallel sub-agents along the spec's section seams (e.g. Phase 1: auth /
monitor-CRUD / detection+alerting) when that's cleaner. Give each sub-agent:
- the phase spec path + "follow CLAUDE.md and architecture.md; build to the named
  objects",
- the instruction to **TDD**: write the spec's Test Plan scenarios as failing
  tests first, then implement to green,
- the phase's **Required system tests (must ship)** list — non-negotiable,
- "run `/code-review` before pushing; `/security-review` if you touch auth, tokens,
  the ping endpoint, the API, or rate-limiting".

## Per-phase loop
1. Branch off `main` (e.g. `phase-0-walking-skeleton`).
2. Sub-agent TDDs the spec's Test Plan → green; adds the Required system tests.
3. `bin/ci` green locally (the pre-push hook enforces this anyway).
4. `/verify` or `/run` against the phase's **Acceptance Criteria** — observe real
   behaviour, not just green units (a ping flips `pending→up`; a stalled monitor
   emails `down`; recovery emails on the next ping; the dashboard renders).
5. Open a PR; keep history **linear** and **squash-merge** to `main`
   (see [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md)).
6. Confirm the phase's Definition of Done before moving on.

## Guardrails (reject sub-agent work that violates these)
- **No `app/services/`.** Operation objects / concerns / sub-resource controllers
  per `architecture.md`. Names are normative.
- **Hotwire-first, server-driven**; vanilla Rails; Rails generators over hand-rolling.
- **The locked decisions** (README §2) are settled — don't re-open them.
- **System tests ship with every user-facing flow** — a phase isn't done without
  its S-numbered tests.
- **Secrets** (`ping_token`, API keys): random, hashed, constant-time, shown once,
  opaque `404`/`401`.
- **Deviate, but say so** — any departure from convention needs a one-line note.

## Definition of Done (every phase)
All Test Plan scenarios pass · Required system tests pass · `bin/ci` green (incl.
`test:system`) · linter clean · migrations reversible · Acceptance Criteria
verified via `/verify`/`/run`.

## State of the repo right now
**Phases 0–4 are built and merged to `main`** — the Rails app, the companion gem,
and the test suite all exist. Licensing is set (server AGPLv3, gem MIT). Work now
proceeds as **follow-up issues**, not phases; the per-issue loop and guardrails
above still apply. The current batch (#16 caps config-gating, #17 self-host
packaging, #19 hosted billing) and how to coordinate it is in
[`followups-coordination.md`](followups-coordination.md).

**`main` is a protected branch** — direct pushes are rejected. Every change lands
via **push-to-branch → PR → squash-merge**. The pre-push hook still runs `bin/ci`.
