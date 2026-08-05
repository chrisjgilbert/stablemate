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
| 1 | Adopt `minitest-mock`; retire the hand-rolled method/ENV stubs | #3 | **MERGED** | #77 |
| 2 | Finish the half-done extractions; kill `User.take` | #5, #6 | **MERGED** | #78 |
| 3 | Stop monkey-patching globals in the job tests | #4 | **MERGED** | #87 |
| 4 | Humble-Object the production env config; retire 8 boots | #2 | **MERGED** | #88 |
| 5 | Two owners: fixture-free tests get a fixture-free user | #1 | **MERGED** | #89 |
| 6 | `rubocop-minitest` to stop the regressions | #7 | **MERGED** | #90 |
| 7 | The system suite's load sensitivity — an Erratic Test | #8 | **MERGED** | #91 |
| 8 | Stop testing config and booting; test behaviour | #9 | **IN REVIEW** | #93 |

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

## Chunk 5 — Two owners, not one (finding #1)

**The plan changed once the numbers were in, and the original was wrong.**

The review said 44 `delete_all`/`destroy_all` calls existed only to demolish
`monitors.yml`, and proposed replacing the fixture with a Creation Method. But
23 files use those monitors *by name*, 81 times over — it is real reference data
for tests that want a ready-made monitor to act on, and 48 `projects.sole` calls
depend on the current shape. Deleting it would have been a large, risky rewrite
of working tests.

What was actually wrong: **one set of users served two opposite needs** — own
some monitors, own none — so half the suite had to undo the setup before it
could start (`# predictable count`, `# stay within the per-user cap`).

- [x] keep `users.yml` / `projects.yml` and the monitors fixture — all genuine
      shared reference data for the 23 files that use it
- [x] add **carol** and **dave**, who own no monitors and never will
- [x] point the count-sensitive tests at them and drop the demolition

| | before | after |
|---|---|---|
| `delete_all` / `destroy_all` | 44 | **30** |
| files doing it | 24 | **12** |

**The 7 that remain and are NOT this smell:** a sweep test (detection, prune,
rollup) asserts over every monitor there is, so an empty world is its premise
rather than an inconvenience. Verified by removing them — three tests fail, on
enqueued-job counts and the free-plan cap — so they stay. Worth keeping the
distinction straight: a *global* wipe in a sweep test is legitimate; a
*per-project* one to dodge a fixture is the smell.

**Left alone deliberately:** `monitors_controller_test` and
`projects_controller_test` both use the fixture monitors *and* demolish them,
per test. Converting those needs a per-test judgement rather than a setup swap.

## Chunk 6 — Stop the regressions (finding #7)

Every chunk above removed a shape rubocop could have refused. Nothing stopped
them coming back, because `rubocop-minitest` is not in omakase.

- [x] `rubocop-minitest` in the lint toolchain, with `NewCops: enable`
- [x] `uptime_test.rb` `assert(ticks.all? { … })` — held however the ticks were
      ordered, so it would have passed with the sparkline drawn backwards. Now
      asserts the sequence, and the two events outside the window are both
      failures so it also catches the wrong 16 being picked. Both mutations
      verified to fail.

`Minitest/UselessAssertion` catches the exact defect the review passes found
**twice** in tests written for this ledger. Verified by probe, not assumed:

| probe | result |
|---|---|
| a test with no assertions | `Minitest/NoAssertions` ✓ |
| `def tets_the_cap_is_enforced` (never runs) | `Minitest/TestMethodName` ✓ |
| `assert_equal x, x` | `Minitest/UselessAssertion` ✓ |
| `private def assert_something_custom` | left alone ✓ |

**`Minitest/NoAssertions` ships `Enabled: false` upstream**, not `pending`, so
`NewCops: enable` never reaches it — it has to be named. The config claimed to
catch assertion-free tests before that was actually true.

**Four cops are off**, each a style opinion fighting a convention chosen on
purpose rather than a cop that found something awkward: `MultipleAssertions`
(150 sites — system tests here are one robust test per flow),
`Assert/RefutePredicate` (228), `EmptyLineBeforeAssertionMethods` (381), and
`AssertTruthy`/`RefuteFalse` (where `assert_equal true, x` is deliberately
stricter — the boot tests read booleans back out of parsed JSON, and these are
the SSL and mail-delivery switches).

`TestMethodName` stays **on**: it autocorrected a custom assertion into a test
method that minitest then ran with no request behind it, but `private def` is
the cop's own answer and the pattern this suite already uses. The fix was the
helper, not the cop.

## Chunk 7 — The system suite's load sensitivity (finding #8)

Recorded in chunk 1 as "the suite is somewhat load-sensitive — worth knowing
before blaming a diff for it", which was letting it off. **"Passes unless the
machine is busy" is an Erratic Test**: the result depends on something that is
not the code under test.

Reproduced by shrinking Capybara's wait window rather than waiting for a loaded
runner — which turned an intermittent failure into a deterministic one, and
showed it was **two** bugs wearing one costume.

- [x] **A real race.** A node captured and then acted on goes stale when a Turbo
      render replaces it in between — Capybara says so by name
      (`Cuprite::ObsoleteNode`). `first(:link, …).click`,
      `find("select[aria-label=…]").select(…)` and `within all(".plan")[1]` all
      have this shape. The action helpers (`click_on`, `select`, `within` with a
      selector) re-find as part of acting, so they cannot go stale. **No wait
      time fixes this one.**
- [x] `enable_aria_label`, which is what lets `select "Hourly", from: "Expected
      interval preset"` resolve at all — those controls are labelled by
      aria-label, and without it a test must use the capture-then-act form.
- [x] `all(".plan")[1]` was doubly wrong: the markup already carries
      `.plan--pro`, so the test indexed by position into a list it could have
      named, and would have checked the wrong card if the plans were reordered.
- [x] **An ordinary timeout.** `default_max_wait_time` was Capybara's stock 2s,
      never configured. 5s costs nothing when things are fast — waiting
      assertions return as soon as the condition holds. Read with `.presence`,
      not `ENV.fetch`'s default: a workflow setting it from a step output it
      could not produce passes an EMPTY STRING, which `fetch` treats as present
      and `Float()` then rejects, killing the suite at file load. The first
      version of this chunk had that bug — twelve lines below the comment in the
      same file warning about it for `CHROMIUM_PATH`.

**Five capture-then-act sites remain, and are out of scope rather than missed.**
Capybara's action helpers only re-find for links, buttons and form fields
addressed by their accessible name. These five target a `<summary>`, a
`data-testid` on a non-button, and checkboxes selected by CSS attribute — none
of which `click_on` / `check` can locate — so `find(…).click` is the only form
available. The window is a single CDP round trip with no intervening render,
which is why they have never been seen to fail; the eight that were fixed all
spanned a Turbo re-render.

  billing_test.rb:72, design_review_fixes_test.rb:58 & :83,
  downgrade_grace_test.rb:44, monitors_test.rb:92

| wait window | before | after |
|---|---|---|
| 0.4s | `ObsoleteNode` + a timeout | only the Turbo Stream broadcast, which genuinely needs longer than 400ms for a job + cable round trip |
| 1s | — | green |
| 2s (the old stock default) | intermittent under load | green |
| 5s (the new default) | — | green |

---

## Where this leaves the suite

| | before | after |
|---|---|---|
| whole non-system suite | 15.9s | **9.0s** |
| the 4 boot-based files | 41.6s | **16.4s** |
| `define_singleton_method` in test helpers | 12 | **0** |
| `class_eval` / `alias_method` / `singleton_class` in `test/` | 6 | **0** |
| duplicate SQL-capture helpers | 4 | **1** |
| `delete_all` / `destroy_all` | 44 in 24 files | **30 in 12** |
| minitest lint cops | none | **on, with probes** |
| system suite at a 2s wait | intermittent under load | **green** |
| captured-node interactions, reducible | 8 | **0** |

Still open, and deliberately so: `monitors_controller_test` and
`projects_controller_test` both use the fixture monitors *and* demolish them per
test, which needs a per-test judgement rather than a setup swap.


## Chunk 8 — Stop testing config; test behaviour (finding #9)

Chunk 4 moved the env→config *derivation* into a plain object, and left two boot
tests behind on the reasoning that a boot still proves production "wires it in".
Pressed on why we test config at all, that reasoning does not survive.

**What production.rb does with the object is nine straight assignments** —
`config.force_ssl = deployment.ssl_enabled?`, and so on. Asserting `force_ssl ==
true` afterwards tests Rails' attribute writer. It was not a tautology before
chunk 4, because the assertions reached real branching; chunk 4 is what made it
one, by moving that branching somewhere it can be tested in 1.4s.

The deeper objection is that the survivors were **implementation, not
behaviour**: `::Stripe.api_key.present?` reads an SDK attribute, and
`pay_paths.empty?` reads the routing table. Nobody's experience changes because
a variable is set. Where a behaviour existed underneath, it is now asserted
directly; where none did, the assertion is gone.

- [x] `production_env_config_test.rb` — nine assignment tautologies, plus a
      "production boots" check the Dockerfile already performs at image build
      (`RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile`)
- [x] `billing_boot_test.rb` — one non-tautological assertion
      (`::Stripe.api_key.present?`), and it reads an SDK internal
- [x] `pay_automount_routes_test.rb` → `test/controllers/pay_engine_routes_test.rb`,
      which **requests the paths and asserts 404** instead of asking
      `routes.recognize_path`. Mutation-checked: deleting
      `Pay.automount_routes = false` turns `/pay/payments/1` from 404 into 302.
      This is the half that mattered — Pay draws it unconditionally, and the page
      embeds a PaymentIntent's `client_secret`.
- [x] `honeybadger_api_key_test.rb` → `honeybadger_secret_test.rb`, keeping only
      the assertion that needed no boot (no key committed to the repo — a plain
      YAML read). The env-vs-YAML precedence pair was testing Honeybadger's own
      resolution rules.

| | before | after |
|---|---|---|
| `test/config` wall time | ~16s | **1.6s** |
| boots in the suite | 7 | **0** |

**Then all of them went, boot helper included.** The standing preference is
against config and boot tests, and the last holdout did not need to be either.

`mail_from_test.rb` — deleted. `app_from` restated the `ENV.fetch` that set it,
and the other two protected Pay's from-address on emails Pay never sends
(`config.send_emails = false`). The live behaviour — an alert arriving from an
address the recipient's SPF/DKIM accepts — is now asserted on a **real delivered
alert** in `monitor_mailer_test.rb`, in-process.

`development_boot_test.rb` — deleted, and the thing it protected kept, by the
same move as chunk 4. Registering `NonProdMailGuard` outside production and test
is a **decision**; `NonProdMailGuard.guards?(env)` is now that decision as a
predicate, asked in-process, while the initializer is a one-line `if` nobody
tests. Mutation-checked: dropping development from the guarded set fails with
*"a dev box must not mail real people"*.

That is the shape the whole ledger converged on:

| | test it? |
|---|---|
| a **decision** with edge cases | yes — as a plain object, in-process |
| an **assignment** or a registration | no — a reader checks it in less time than a boot takes |

`boot_test_helper.rb` is gone with them.

| | before chunk 8 | after |
|---|---|---|
| `test/config` wall time | ~16s | **1.6s** |
| boots in the suite | 7 | **0** |

**What is deliberately not covered any more.** A Pay upgrade silently changing
how it resolves `STRIPE_PRIVATE_KEY` would no longer fail CI — the test
environment has no Stripe keys, so nothing else notices, and the first customer
to click Upgrade would find out. That belongs in a post-deploy smoke check
against the running instance (real keys, real config, real behaviour), not in a
suite that has to fake all three. Recorded here so the gap is a decision rather
than an oversight.