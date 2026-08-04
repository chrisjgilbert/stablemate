# Test suite cleanup — retiring the smells

Status: **IN PROGRESS**. Author: Claude (session), 2026-08-04. Owner: @chrisjgilbert.
No product change; this is a **test-quality punch list**. It removes the smells
found in the 2026-08-04 review of `test/`, using the catalog from Gerard
Meszaros' *xUnit Test Patterns*, thoughtbot's *Let's Not* and Sandi Metz's
*Magic Tricks of Testing*. Follow the architecture rulebook in
[`../../CLAUDE.md`](../../CLAUDE.md).

> Scope note: production code changes only where a test smell is caused by
> **Hard-to-Test Code** (chunk 4's env-config extraction). Everything else is
> confined to `test/`.

---

## 0 · Execution ledger — **the state file; read this first**

Single source of truth for what is done and what is next. Committed, so it
survives a container restart: to resume, read this table, find the first chunk
that isn't `MERGED`, and continue from its unchecked boxes.

**Each chunk ships the same way:** TDD → `/code-review --fix` → `/verify`
against the running app → full `bin/ci` → PR → merge to `main` only when GitHub
Actions is green → tick the boxes here → next chunk.

| # | Chunk | Finding | Status | PR |
|---|-------|---------|--------|-----|
| 1 | Adopt `minitest-mock`; retire the hand-rolled method/ENV stubs | #3 | **TODO** | — |
| 2 | Finish the half-done extractions; kill `User.take` | #5, #6 | **TODO** | — |
| 3 | Stop monkey-patching globals in the job tests | #4 | **TODO** | — |
| 4 | Humble-Object the production env config; retire 8 boots | #2 | **TODO** | — |
| 5 | Shrink the monitors General Fixture | #1 | **TODO** | — |
| 6 | `rubocop-minitest` to stop the regressions | #7 | **TODO** | — |

### The measurements this work is against (taken on `b2b3fbb`)

| Metric | Baseline |
|---|---|
| 537 non-boot, non-system tests | 6.2s |
| the 18 boot-based tests | 41.6s (**6.7×** the other 537) |
| `production_env_config_test.rb` alone | 34.4s (8 production boots) |
| `delete_all`/`destroy_all` in tests | 44 occurrences across 24 of 88 files |
| `define_singleton_method` in `test_helper.rb` | 12 |
| assertions carrying a failure message | 368 / 1693 (22%) |
| conditional test logic | 0 — already clean, keep it that way |

---

## Chunk 1 — Adopt `minitest-mock` (finding #3)

`test_helper.rb` hand-rolls ~40 lines of `define_singleton_method` save/restore
because minitest 6 dropped `Object#stub`. It did — but it was **extracted**, not
deleted (`minitest-6.0.6/History.rdoc:69`), to the `minitest-mock` gem: 5.27.0,
by minitest's own author, **zero runtime dependencies**, installs alongside
minitest 6.

The pattern is also spreading: chunk 5 of launch-readiness added a third family
(`with_cloudflare_analytics_token`, an ENV save/restore) before this review
landed, and `non_prod_mail_guard_test.rb` already had its own copy.

- [ ] `gem "minitest-mock"` in the test group
- [ ] `Stablemate.stub_billing` / `stub_slack` / `stub_price_id_pro` → `Object#stub`
- [ ] stop reopening the production `Stablemate` module to add test-only methods
- [ ] `without_pay_stripe_network` → `Object#stub`
- [ ] one shared `with_env` for the ENV gates (Cloudflare token, mail allowlist)

**Keep, do not touch:** `stub_const` (36 sites) is Rails' own
`ActiveSupport::Testing::ConstantStubbing`, and the WebMock + `StripeApiStubs`
layer is the correct "stub at the real boundary" pattern.

## Chunk 2 — Finish the half-done extractions (findings #5, #6)

- [ ] `sql_executed_during` — byte-identical in `pausing_test.rb:124` and
      `suspension_test.rb:204` → `QueryCountingTestHelper`
- [ ] `monitors_controller_test.rb:41` hand-rolls the counter that
      `count_queries_matching` already provides (commit `a3eb26e` consolidated
      the others and missed this one)
- [ ] `give_active_pro_subscription!` — 3 aliases of the shared
      `give_pro_subscription!`, two of which add no meaning
- [ ] `User.take` (3 sites) → `users(:alice)`; no `ORDER BY` means Postgres picks

## Chunk 3 — Stop monkey-patching globals (finding #4)

- [ ] `prune_ping_events_job_test.rb:93` patches `ActiveRecord::Relation#in_batches`
      **globally** to assert an implementation detail → assert the behaviour
- [ ] `detect_missed_pings_job_test.rb:88` aliases `Monitoring::Monitor.overdue`
      on the real singleton class → use the plain-array shape already proven in
      `enforce_overdue_downgrades_job_test.rb:114`

## Chunk 4 — Humble-Object the production env config (finding #2)

The boot tests are a *symptom*. The cause is Hard-to-Test Code:
`config/environments/production.rb` does 12 inline `ENV[...]` reads with
coercion and no seam, so proving "blank `SMTP_PORT` falls back to 587" costs a
full production boot. Dropping `rails/all` in chunk 5 shaved only ~0.4s/boot —
you cannot optimise your way out from the boot side.

- [ ] extract the env→config mapping to a PORO taking an env hash
- [ ] the 8 production boots become in-process unit tests
- [ ] keep **one** boot smoke test proving production boots and wires it in
- [ ] `boot_test_helper.rb:29` `JSON.parse(out.lines.last)` — fail with a useful
      message when an initializer logs to stdout

## Chunk 5 — Shrink the monitors General Fixture (finding #1)

44 `delete_all`/`destroy_all` calls exist only to demolish `monitors.yml` before
a test can start. The comments are the tell: `# predictable count`,
`# stay within the per-user cap`.

- [ ] keep `users.yml` / `projects.yml` (genuine immutable reference data)
- [ ] monitors → a Creation Method called from the tests that need one
- [ ] keep the couple of fixture monitors the tenant-isolation tests genuinely share

## Chunk 6 — Stop the regressions (finding #7)

- [ ] `rubocop-minitest` in the lint toolchain
- [ ] `uptime_test.rb:291` `assert(ticks.all? { … })` — bare and near-tautological
