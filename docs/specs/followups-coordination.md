# Follow-up coordination — #16, #17, #19

How to drive the current batch of follow-up issues with a coordinator + one
specialist sub-agent per issue. Read [`coordinator-playbook.md`](coordinator-playbook.md)
first — the per-issue loop, guardrails, and Definition of Done there all apply.
This file adds the **dependency graph**, a **driver prompt**, and a **brief per
issue**.

## Dependency graph

```
#16 (caps config-gated, default off) ──▶ #19 (billing; plan drives the cap)
#17 (self-host packaging) ──────────────  independent — run in parallel
```

- **#16 must merge before #19 starts.** They both touch `User`, `Monitor`,
  `MonitorsController`, routes and the cap logic; running them together conflicts,
  and #19's plan→cap wiring assumes #16's config gate exists.
- **#17 is independent** (Docker / compose / `docs/install.md` / env config). Run
  it in **parallel with #16**, in its own git **worktree** so the trees don't
  collide.
- Do **not** fan a single issue out across parallel sub-agents — these are coupled
  feature slices, not independent ones. #19 is large but internally *sequential*;
  handle it as a pipeline inside one agent (see its brief).

## House rules (all issues)
- `main` is **protected**: branch off `main` → TDD → `bin/ci` green → `/verify` →
  PR → **squash-merge**. Never push to `main` directly.
- Vanilla Rails per `CLAUDE.md` / `architecture.md`: **no `app/services/`** —
  operation objects, concerns, sub-resource controllers; names are normative.
- **System tests ship** with every user-facing flow. `/code-review` before every
  push; `/security-review` on auth/token/billing/ping surfaces.
- Each issue is one branch and one PR. Keep history linear.

---

## Driver prompt (paste into the coordinator session)

> You are the implementation coordinator for the Stablemate repo. Read
> `docs/specs/coordinator-playbook.md` and `docs/specs/followups-coordination.md`,
> then drive issues **#16, #17, #19** to merged on `main`, respecting the
> dependency graph in the coordination doc. You do **not** write the app
> yourself — you delegate each issue to one specialist sub-agent, review their
> PR against the issue's acceptance criteria and the playbook guardrails, and
> keep `main` green and linear.
>
> Sequence:
> 1. Kick off **#16** and **#17 in parallel** — #17 in its own git worktree.
>    Hand each sub-agent the matching brief from `followups-coordination.md`.
> 2. When a sub-agent's PR is green (`bin/ci`) and meets its acceptance criteria,
>    review it, then **squash-merge** to `main`. (`main` is protected — everything
>    is push-to-branch → PR → squash-merge.)
> 3. Start **#19 only after #16 is merged.** Hand off its brief; require
>    `/security-review` before its PR.
> 4. Report status after each merge; stop when all three are merged. If a sub-agent
>    is blocked on an open decision (e.g. the Pro £ price, §8 of the PRD), surface
>    it and move on to other ready work rather than guessing.

---

## Brief — #16 · Config-gate the monitor & signup caps

**Goal:** the per-user monitor cap and the global signup cap/waitlist become
config-driven and **default to OFF / unlimited**, so a self-hoster has no caps and
no waitlist; we switch them on only for the managed instance.

- **Spec:** issue #16; PRD §1 (scope decisions), §3.1, §11.
- **Touch points:** `User::Plan` (cap keyed off `plan`/config), monitor-creation
  enforcement in `MonitorsController` and `Api::V1::Monitors::SyncsController`, the
  sign-up flow (`Signup` / `RegistrationsController`) and its waitlist branch.
- **Shape:** read both limits from env/config (e.g. unset/`0` ⇒ unlimited / always
  open). When off, the at-limit UI states and the waitlist sign-up mode must not
  appear; the gem `sync` `skipped: limit_reached` path only applies when a cap is
  set.
- **TDD + tests:** cover **both modes** (caps on and off) at model, request, and
  system level.
- **Done when:** fresh instance with no cap config → unlimited monitors, sign-ups
  always open, no waitlist reachable; with caps configured → today's behaviour.
  `bin/ci` green; `/code-review` clean.

## Brief — #17 · First-class self-hosting (Docker, compose, install guide)

**Goal:** a developer can stand up their own instance with minimal ops.

- **Spec:** issue #17; PRD Goal 6, §11.
- **Deliver:** a production **Docker image** that runs standalone (verify the
  existing `Dockerfile` isn't Kamal-only); a **`docker-compose.yml`** (app +
  PostgreSQL) that comes up with one command; **env-based config** for DB, secret
  key base, SMTP, base URL, and the cap toggles from #16 (no reliance on
  in-repo Rails credentials); a tested **`docs/install.md`** walkthrough. Confirm
  the gem's `endpoint` cleanly targets a self-hosted base URL.
- **Isolation:** run in its **own worktree** (parallel with #16).
- **Done when:** a clean Docker host can follow `docs/install.md` to sign up,
  create a monitor, receive a ping, and get a down email; ping URLs + gem endpoint
  resolve to the operator's domain; no deps beyond outbound SMTP.

## Brief — #19 · Hosted-tier billing (Stripe self-serve) — *after #16*

**Goal:** the managed tier's revenue layer — hosted-only, config-gated, dormant
unless Stripe keys are set. **Run `/security-review` before the PR.**

- **Spec:** issue #19; PRD §12, §5.6, §4, §3.3, §3.1b, Phase 5.
- **Architecture (vanilla Rails):** `User::Plan` + `User::Subscription` concerns;
  `Billing::CheckoutsController` / `Billing::PortalSessionsController` /
  `Billing::WebhooksController` sub-resources; a `Monitor::Suspension` operation
  for suspend/reactivate. No `BillingService`. Use the **Pay gem** (Stripe backend)
  — don't hand-roll subscription state.
- **Internal pipeline (sequential — one agent, staged):**
  1. plan/cap wiring on #16's gate + the `suspended` monitor state (§3.3, §4);
  2. Pay + Stripe Checkout / Customer Portal / Stripe Tax;
  3. signature-verified, idempotent **webhooks** → `User.plan` (plan changes only
     via webhook — never trust the client);
  4. billing UI, the at-limit "Upgrade to Pro" prompt, and the **gated
     "choose your 5" downgrade** flow (§5.6);
  5. `/security-review`.
- **Config gate:** one `billing_enabled?` (Stripe keys present). Off ⇒ routes/UI
  hidden, caps unlimited, no `suspended` monitors. This is the self-host path.
- **Blocked-on (don't guess — surface to the coordinator):** PRD §8 Q9 (Pro £
  price / annual), Q10 (suspended-monitor retention).
- **Done when:** Stripe-keyed instance — upgrade via Checkout → webhook flips
  `plan` to `pro` → cap rises to 100; downgrade with >5 monitors forces choosing 5,
  the rest go `suspended`. Keyless instance — no billing, everyone Free, unlimited.
  `bin/ci` + system tests green; `/security-review` addressed.
