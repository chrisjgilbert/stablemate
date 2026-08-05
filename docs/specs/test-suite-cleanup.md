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
| 1 | Adopt `minitest-mock`; retire the hand-rolled method/ENV stubs | #3 | **IN REVIEW** | #77 |
| 2 | Finish the half-done extractions; kill `User.take` | #5, #6 | **IN REVIEW** | #78 |
| 3 | Stop monkey-patching globals in the job tests | #4 | **IN REVIEW** | #79 |
| 4 | Humble-Object the production env config; retire 8 boots | #2 | **IN REVIEW** | #81 |
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

- [x] `gem "minitest-mock"` in the test group
- [x] `Stablemate.stub_billing` / `stub_slack` / `stub_price_id_pro` → `Object#stub`
- [x] stop reopening the production `Stablemate` module to add test-only methods
      (the fake credentials moved to `TestCredentials` too)
- [x] `without_pay_stripe_network` → `Object#stub`
- [x] one shared `with_env` for the ENV gates (Cloudflare token, mail allowlist)
- [x] `stablemate_livemode_test` still hand-rolled the same pattern — caught by
      the review pass, now stubbed like the rest

**`test_helper.rb`: -105/+4 lines; `define_singleton_method` count 12 → 0.**

**What the gem brings with it.** `Object#stub` saves the original under a fixed
`__minitest_stub__<name>` alias, so stubbing the same method on the same object
twice corrupts the saved copy: the unwind raises `NameError` and leaves the
method UNDEFINED for the rest of that worker. The hand-rolled version nested
fine, so this constraint is new. Nothing nests today, and `#stub_gate` now
refuses it up front rather than leaving a `NameError` to be decoded later.

**A note on the system-suite flakiness seen while shipping this.** Two system
tests failed mid-chunk and briefly looked like a regression. They were not: the
runs had been executed concurrently with another full suite, and wall time had
doubled (30s → 60-70s) from CPU contention. Run sequentially, both `main` and
this branch are 5/5 green. The suite is somewhat load-sensitive — worth knowing
before blaming a diff for it.

**Keep, do not touch:** `stub_const` (36 sites) is Rails' own
`ActiveSupport::Testing::ConstantStubbing`, and the WebMock + `StripeApiStubs`
layer is the correct "stub at the real boundary" pattern.

## Chunk 2 — Finish the half-done extractions (findings #5, #6)

- [x] `sql_executed_during` — byte-identical in `pausing_test.rb` and
      `suspension_test.rb` → `QueryCountingTestHelper`
- [x] `monitors_controller_test.rb` hand-rolled the counter that
      `count_queries_matching` already provides (commit `a3eb26e` consolidated
      the others and missed this one)
- [x] a **fourth** copy, in `signup_test.rb`, found by the review pass — it also
      shadowed Rails' own `capture_sql` with different semantics
- [x] the two lock-ordering tests duplicated the *assertion* as well as the
      helper → `assert_sql_order`, a Custom Assertion that names the failure
- [x] `give_active_pro_subscription!` — 3 aliases of the shared
      `give_pro_subscription!`; two are gone, the third renamed after what it
      returns
- [x] `User.take` (3 sites) → `users(:alice)`; no `ORDER BY` means Postgres picks
      (the remaining `User.take` is in a mailer *preview*, where any user will do)

**All four SQL-capture copies now go through one helper.**

The rewired dashboard N+1 guard was mutation-checked: reintroducing a genuine
per-monitor query in `mini_ticks_for` fails it with its own message; the tree is
clean afterwards. The first mutation attempt (blanking `@mini_ticks`) did *not*
fail it — `_list.html.erb` passes `|| []`, and `[]` is truthy, so `kinds ||=`
never falls back. Worth knowing before trusting that guard's shape.

## Chunk 3 — Stop monkey-patching globals (finding #4)

- [x] `prune_ping_events_job_test.rb` patched `ActiveRecord::Relation#in_batches`
      **globally** to catch the call → now reads the SQL: past the batch size
      batching issues more than one delete, each bounded by an explicit id set
- [x] `detect_missed_pings_job_test.rb` aliased `Monitoring::Monitor.overdue` on
      the real singleton class → now hands over a pre-**loaded** relation via
      `Object#stub` (the chunk-1 seam, which restores in an `ensure`)
- [x] the guarantee itself belongs to `ApplicationJob#each_record`, which every
      sweep inherits → `application_job_test.rb` pins the contract, the detection
      test keeps pinning the wiring. Both earn their place: dropping either lets
      a real mutation through.
- [x] new coverage the move exposed: that the rescue stays **narrow**. Widening
      it to `StandardError` would turn a real bug into a silent no-op across
      every sweep, and now fails.

**No `class_eval` / `alias_method` / `singleton_class` left anywhere in `test/`.**

Every assertion in this chunk was mutation-checked: a bare `delete_all` instead
of `in_batches`, `find_each` instead of `each_record`, a removed rescue, and a
widened rescue each fail the test that claims to catch them.

A correction worth recording: the first version of this work claimed a real
scope could not reproduce a vanished record "by construction". That is wrong —
a *loaded* relation iterates its cached rows rather than re-querying, so it
yields the deleted record exactly as a real batch does. The review pass caught
it, and the tests now use a real relation instead of a hand-written stand-in.

## Chunk 4 — Humble-Object the production env config (finding #2)

The boot tests are a *symptom*. The cause is Hard-to-Test Code:
`config/environments/production.rb` does 12 inline `ENV[...]` reads with
coercion and no seam, so proving "blank `SMTP_PORT` falls back to 587" costs a
full production boot. Dropping `rails/all` in chunk 5 shaved only ~0.4s/boot —
you cannot optimise your way out from the boot side.

- [x] extract the env→config mapping to a PORO taking an env hash
      (`Stablemate::DeploymentConfig`)
- [x] the 8 production boots become in-process unit tests
- [x] keep **one** boot smoke test proving production boots and wires it in
      (two, in fact: configured to the hilt, and nothing set at all — the shape
      a self-hoster meets first)
- [x] `boot_test_helper.rb` `JSON.parse(out.lines.last)` — now takes the last
      line that IS the payload, and fails with the output attached when there
      is none

| | before | after |
|---|---|---|
| the 4 boot-based files | 41.6s | **16.4s** |
| `production_env_config_test.rb` | 34.4s (8 boots) | **9.4s** (2 boots) |
| the rules themselves | — | **1.4s** (19 in-process cases) |
| whole non-system suite | 15.9s | **9.0s** |

Coverage went **up** while the clock came down: 21 cases against 9.

`/security-review` was run on this chunk (it touches `force_ssl`, host
authorization and `trusted_proxies`, which feeds `remote_ip` → the ping rate
limiter and the session audit log). No findings at or above its bar; the
extraction was confirmed behaviour-preserving rule by rule. Verified
independently against real production boots: a blank `STABLEMATE_FORCE_SSL`
still forces SSL, and Rails' private proxy ranges are still prepended.

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
