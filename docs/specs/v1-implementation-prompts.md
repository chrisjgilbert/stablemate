# V1 implementation prompts

Copy-paste briefs for the agents implementing V1, one per §8.1 phase. Run the
phases **sequentially, in order, one fresh session each** — the ordering is the
safety mechanism, and phase 2 has a hard gate (a verified real check-in) before
phase 3 may start.

**Precondition for all three:** PR #75 (the spec) is merged, so
`docs/specs/v1-proposal.md` and `docs/specs/v1-scope.md` are on `main`.

---

## Phase 1 prompt

You are implementing **Phase 1 of Stablemate's V1 redesign** — the additive,
server-only phase of a three-phase cutover. The design is settled and has been
hardened by eleven adversarial review rounds; your job is disciplined
execution, not redesign.

**Read first, in this order:**

1. `docs/specs/v1-proposal.md` — the whole plan in 1,100 words. Orientation.
2. `docs/specs/v1-scope.md` §8.1 — your exact scope is the **Phase 1** bullet.
   Everything else is out of scope: the entire `gem/` directory is phase 2,
   all deletions are phase 3, and the old ping path must keep working
   untouched — its existing tests stay green and unmodified.
3. Before writing code for each surface, read its reference section **in
   full**: §4 (credential model), §5.1–§5.5 (route, controller, rate
   limiting, responses, verify endpoint), §6.1's server half (orphans,
   `retired`, `declared_keys`/prune), §8 (the `registration_key` backfill),
   §11 (pinned decisions — never guess anything answered there), §12 (your
   required tests). Every paragraph in that document guards against a mistake
   that was actually made during review.
4. `CLAUDE.md` is binding: the architecture rules (no `app/services/`,
   operation objects on records, sub-resource controllers, Hotwire-first),
   TDD, browser-driven system tests via cuprite, commit hygiene.

**What phase 1 ships** (§8.1's list, expanded):

- **`PingKey`**: model mirroring `ApiKey` exactly except where §11 states
  otherwise, issuance operation, project-page UI (shown once, masked
  afterwards, revoke), migration. More than one live key per project.
- **The check-in endpoint**: `POST /api/v1/monitors/:registration_key/pings` —
  standalone route per §5.1 (constraint + `format: false`), controller per
  §5.2 (must **not** inherit `Api::V1::BaseController`; assert that in a
  test), both rate-limit layers in §5.3's order with a **rendering** `with:`.
- **The verify endpoint** per §5.5: its own sibling controller, its own
  per-IP declaration.
- **The `registration_key` backfill** per §8/§8.1: `manual-<id>` namespace,
  collision guard, backfill and any constraint in one migration.
- **The server half of prune** per §6.1: `retired` in the status vocabulary
  and *every* site it touches (cap scope, **both** ping arms —
  `CheckIn` *and* `FailureReport` — resolve-incident-at-retire,
  `status_before_retirement`, the revive rules including refusal at the cap,
  the live-today stat, dashboard partition, choose-N picker exclusion);
  `declared_keys`/`prune` handling in the sync path; `orphaned:`/`retired:`
  in the response envelope; the `schedule` column stored and deliberately
  unused.
- **Inert until spoken to**: a pre-0.2.0 sync payload (no `declared_keys`, no
  `prune`, no `schedule`) must behave exactly as today.

**Non-negotiables:**

- TDD — failing test first. §12's bullets for these surfaces are your
  acceptance tests; implement every one that touches phase-1 code, including
  the adversarial ones (two task names must not share a rate-limit counter;
  assert the 429 *body*, not just the status; the controller class-graph
  assertion; a *failure* ping to a retired monitor resurrects nothing).
- `/security-review` before opening the PR — this phase is tokens, a public
  endpoint, and rate limiting, the exact surfaces `CLAUDE.md` flags.
  `/code-review` as well. `bin/ci` fully green, system tests included.
- §11's decisions are settled; if you disagree with one, §11 likely records
  why your alternative was already rejected. But where the **spec contradicts
  the code's reality** (a moved line, a changed mechanism), trust reality,
  make the smallest consistent choice, and record it in one line per
  `CLAUDE.md`'s "Deviate, but say so" — never silently diverge.
- Commit hygiene per `CLAUDE.md`: imperative subjects, the *why* in the body,
  WIP squashed before the PR, every commit passes `bin/ci`.

**Definition of done:** all phase-1 §12 tests pass; full `bin/ci` green; the
old ping endpoint's behaviour is unchanged (its tests untouched and green); a
legacy sync payload round-trips identically to before; review skills run and
findings addressed; branch pushed and a PR opened using the repo's PR
template, with any spec deviations listed one line each. Do **not** merge —
a human reviews. Work autonomously on reversible steps; stop and ask only at
a genuine fork the spec does not answer.

---

## Phase 2 prompt

You are implementing **Phase 2 of Stablemate's V1 redesign**: gem 0.2.0 and
the onboarding surface. Phase 1 is merged and deployed; the server already
answers header-authenticated check-ins, verify, and prune — all inert until
your work speaks to them.

Read `docs/specs/v1-proposal.md`, then `v1-scope.md` §8.1 (Phase 2), then in
full before coding each part: §3.1–§3.2 (config-as-code, header check-ins),
§6.1–§6.6 (the command, environments, reportable tasks, the client, boot, the
install command), §7 (setup panel and milestone ladder), §11, §12.

Ships: the gem's deletions (§3.2's table) and additions — header-auth
check-ins via `ERB::Util.url_encode` (require `"erb"`; require `"set"` where
§6.3 says — the gem's floor is Ruby 3.1 and nothing 3.2+ merely autoloads may
be used unrequired), `c.overrides` with §3.1's validation and ordering,
`declared_keys`/`PRUNE=1`, the schedule string in tuples, the §6.1 output
contract (exit codes; **no credential ever in sync output** — grep the output
in a test), `stablemate:install` per §6.6 (dry-run, production-section
preview, both verifications, hook writing, `.env` handling), the §7 setup
panel with the `MonitorSync` commit broadcast, `register_on_boot` as a
deprecated no-op, and the boot snippet per §6.5. Add the gem's CI Ruby matrix
(3.1 through current) — §12 requires the 3.1 boot test to run on 3.1.

Same non-negotiables as phase 1. The cutover gate belongs to the human:
after this merges and deploys, **a real check-in must be verified on the new
path** before phase 3 begins — say so in your PR body.

---

## Phase 3 prompt

You are implementing **Phase 3 of Stablemate's V1 redesign**: the subtractive
phase. Phases 1–2 are merged, deployed, and a real check-in has been verified
on the new path (confirm this with the human before deleting anything).

Read `docs/specs/v1-proposal.md`, then `v1-scope.md` §8.1 (Phase 3), then §3.3
(what leaves the web interface, including the edit path and `source`'s
survival), §8 (the deletion inventory and test blast radius), §9.1 (the
never-checked-in alert and close-the-loop emails — they ship in this phase,
notification-only per the recorded decision), §10 (free cap 5 → 10), §11
(including the docs list — the doc rewrite is in scope, not follow-up), §12.

Ships: deletion of the old ping endpoint, `ping_token` and both rotation
controllers, `ping_url` from every payload (410 for rotate), monitor
creation *and* editing surfaces (`_move.html.erb` handled by structure, not
line numbers), the arbitration machinery (`gem_may_write?`, three columns —
`last_synced_app` **stays**), the never-checked-in alert with its
`created_at` anchor and first-sweep bound, the over-cap banner + email, the
free-cap change, and the full docs rewrite §11 lists. The eight Capybara
check-in call sites must be consciously rehomed per §8.

Same non-negotiables. This phase has the largest test blast radius (§8
measures it) — expect to spend most of your time in the test suite, and treat
every deleted test as a decision, not a casualty.
