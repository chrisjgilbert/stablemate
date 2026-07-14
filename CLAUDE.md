# Stablemate — engineering conventions

Read this before writing code. Stablemate follows a **strict, 37signals-inspired,
vanilla-Rails architecture**: keep `app/` small, put logic on records, and never
default to a generic service bucket. The full rationale and worked examples are
below; the locked product/architecture decisions are in
[`docs/specs/README.md`](docs/specs/README.md).

## The decision table — start here

| You have…                                          | Use…                                          |
|----------------------------------------------------|-----------------------------------------------|
| One aspect of an entity to group                   | a namespaced **concern** (`app/models/user/spending.rb`) |
| A complex one-shot operation owned by one entity   | an **operation object** — a noun, entity-scoped (`Monitor::CheckIn`) |
| Plain create/update with no extra meaning          | **association CRUD** straight from the controller |
| A custom controller verb                           | a **RESTful sub-resource controller** |
| A process spanning entities, owned by none         | a **top-level coordinator** — a noun (`Signup`), rare |
| A caller dispatching over interchangeable actions  | the **Command pattern**, narrow (`Notifications::Channel`) |

> If your instinct is "I'll make a `FooService`," stop and re-read the table. The
> answer is almost always another row.

## The hard rules

1. **There is no `app/services/` directory.** Don't create one. The absence is the
   guardrail — the first `app/services/foo_service.rb` in a diff is a conspicuous,
   reviewable decision, not a default. It will be sent back.
2. **Give the verb back to the noun.** A complex operation is a **noun-named class,
   namespaced under the entity it serves, reached through a method on that entity.**
   `Monitor::CheckIn` (file `app/models/monitor/check_in.rb`), called via
   `monitor.check_in!` — never `CheckInService`, never `MonitorCheckInService`.
   Operation objects are the **default** for any operation meaning more than a bare
   `create!`, not a last resort. An entity may have a fat *facade* of methods as
   long as each delegates to a tidy operation underneath.
3. **Slice fat models with concerns, don't extract satellites.** Group one aspect of
   an entity into a namespaced concern (`app/models/user/plan.rb`) that *is* the
   entity. The top-level model file stays a thin manifest of `include`s. Never move
   an entity's data into a `FooService` that takes the entity back as an argument.
4. **Kill custom controller verbs with sub-resources.** Find the noun hiding in the
   verb. `POST /monitors/:id/pause` becomes `resource :pause` →
   `Monitors::PausesController#create`. Plain one-line association CRUD
   (`@job.commitments.create!`) straight from a thin RESTful controller is fine; only
   reach for a model method when the operation means more than `create!`.
5. **Jobs orchestrate; records do the work.** A Solid Queue job iterates and calls
   record methods (`Monitor.overdue.find_each(&:flag_missed!)`). The behaviour lives
   on the record, not in the job.

## Use Rails, don't fight it

The architecture above is *how we organise our own code*. Equally important is
**not writing code Rails already gives us.** Stablemate is deliberately a boring,
idiomatic, vanilla Rails app — the value is in the product, not in clever plumbing.

1. **Run the latest stable Rails** (the 8.x line; track point releases). Generate
   the app with `rails new` and the default modern stack (PostgreSQL, Propshaft,
   Solid Queue/Cable/Cache, Hotwire, Tailwind). Don't pin to an old version or
   swap defaults without a justified note.
2. **Reach for a Rails command before hand-rolling.** `bin/rails generate
   authentication`, `generate migration`, `generate model`, `generate controller`,
   scaffolds, `generate mailer`, `generate job`, `generate stimulus`,
   `bin/rails db:*`, Kamal's generators — use them. Hand-writing what a generator
   produces (and drifting from the convention) is the anti-pattern. Review and
   trim generated output, but start from it.
3. **Hotwire-first; prefer server-driven reactivity.** Reach for tools in this
   order: plain server-rendered ERB → **Turbo Frames** → **Turbo Streams**
   (broadcast over Solid Cable for live status) → a **small Stimulus controller**
   only for genuinely client-side bits (copy-to-clipboard, toggle submit, modal).
   No SPA, no React/Vue, no client-side state store, no JSON-API-for-our-own-UI,
   no client polling. The DOM is the source of truth; the server drives change.
4. **Classic, vanilla patterns over bespoke abstractions.** Use Active Record
   associations, scopes, validations, callbacks (sparingly), enums, concerns,
   Action Mailer, Active Job, `has_secure_password`, signed/rotatable tokens
   (`has_secure_token` / `generates_token_for`), `rate_limit`, fixtures — the
   stuff in the Rails guides. If you're inventing a pattern, you're probably
   missing a built-in. Prefer the framework's seam to a gem to a hand-rolled one.
5. **Convention over configuration.** Standard REST routes, conventional names and
   file locations, `bin/` scripts, credentials for secrets. Surprising is bad.

(These compose with the architecture: an *operation object* is still plain Ruby on
a record; a *sub-resource controller* is still standard REST. We're not adding a
framework — we're using Rails as intended and keeping our own additions tiny.)

## The allowed exceptions (narrow, not loopholes)

- **Top-level coordinators.** A process spanning several entities and owned by none
  is itself a **noun-named model** (`Signup`, `Notifications::Dispatch`) that pushes
  every scrap of logic it can onto the records and keeps only the truly homeless
  orchestration.
- **The Command pattern.** A verb-named class with a uniform `call`/`deliver`
  interface is fine when a caller genuinely *dispatches over interchangeable
  actions* through one contract. Stablemate's alert **channel** layer
  (`Notifications::Channel` → `Notifications::EmailChannel`, with webhook channels
  additive in V2) is the example. The objection was never to the pattern — only to
  *defaulting* to it for ordinary one-shot operations that have an obvious owner.

## System tests are non-negotiable

Unit and request tests are necessary but not sufficient. **Every key end-to-end
user flow ships with a browser-driven Capybara system test** — the kind that
actually clicks through the rendered UI in a real (headless) browser. Agents
routinely skip this layer; here we don't.

- **Every user-facing flow gets one.** A browser-driven system test for the flow
  is part of its Definition of Done — a change is **not** done if it's missing,
  even with every unit/request test green. A PR that adds a user-facing flow
  without its system test gets sent back.
- **Browser-driven, not rack-test.** System tests drive a real headless Chromium
  via Capybara, exercising Turbo/Stimulus behaviour (live status updates, the
  copy button, the generate-key modal, the waitlist mode) — things rack-test
  can't see. Assert on what the user sees, not on internals.
- **Driver / environment.** Chromium is preinstalled at
  `$PLAYWRIGHT_BROWSERS_PATH` — **never run `playwright install`.** Prefer the
  Rails default `driven_by :selenium, using: :headless_chrome`; if the sandbox
  blocks Selenium Manager's driver download, fall back to **cuprite** (Ferrum)
  pointed at the preinstalled Chromium binary — it talks CDP directly, no
  chromedriver needed. Either way the system suite must run headless in CI and in
  web sessions.
- **Keep them about flows, not coverage theatre.** One robust test per key flow
  (sign-up → dashboard; create monitor → ping-URL card; outage → down email →
  recovery; generate API key modal; at-capacity → waitlist). Don't system-test
  every field permutation — that's what model/request tests are for.

## Development workflow (skills)

TDD is the loop; these skills are the checkpoints around it. Sub-agents should
invoke them at the right moments rather than improvising equivalents.

1. **TDD first.** For each scenario you're implementing: write the failing test
   → smallest change to green → refactor. Keep `bin/rails test`
   (+ system tests) and the linter green continuously.
2. **`/code-review` before pushing.** Run it on your working diff and address the
   findings before opening/updating a PR. It reviews for correctness bugs and
   reuse/simplification cleanups.
3. **`/security-review` on sensitive surfaces.** Run it whenever a change touches
   auth, sessions, `ping_token`/API-key handling, the public ping endpoint, the
   `/api/v1` surface, or rate-limiting — i.e. most of Phases 1, 3 and 4. Tokens
   are secrets; opaque `404`/`401`, constant-time compare, shown-once keys.
4. **`/verify` (and `/run`) for real behaviour.** Green unit tests aren't the
   whole story for a monitoring product — use `/verify`/`/run` to launch the app
   and observe the actual flow: a ping flips `pending→up`, a stalled monitor
   emails on `down`, recovery emails on the next ping, the dashboard renders.
   Especially before shipping a change to any of these core flows.
5. **`/init` to keep this file current.** As the codebase grows, use `/init` (or
   just edit) so `CLAUDE.md` keeps reflecting reality — stale conventions rot.
6. **SessionStart hook.** Web sessions auto-prepare the app (deps, DB, a quick
   test/lint sanity check) via `.claude/hooks/` — see
   [`docs/specs/README.md`](docs/specs/README.md) and the hook script. Don't
   duplicate that setup by hand each session.
7. **CI gate on push.** `bin/ci` is the single source of truth for "is this
   green?" — it runs rubocop, brakeman/bundle-audit, `bin/rails test` **and**
   `bin/rails test:system`. A PreToolUse hook (`.claude/hooks/pre-push-ci.sh`)
   runs `bin/ci` before every `git push` and **blocks the push if it fails**.
   Commits are not gated (fast TDD loop); push is the publish boundary. The same
   `bin/ci` runs in GitHub Actions (`.github/workflows/ci.yml`), so local green ==
   CI green. Don't push with a red suite, and don't bypass the hook.

## Git & commit hygiene

Keep `main` a **clean, linear history** — it should read top-to-bottom as a
sequence of deliberate changes, not a tangle of merge bubbles and "wip" commits.

- **Linear, no merge bubbles.** Rebase your branch onto `main`; don't merge `main`
  into your branch. Integrate with fast-forward or rebase, never a merge commit.
  (`git pull --rebase`; `git config pull.rebase true` locally.)
- **Squash where possible.** Collapse WIP/fixup commits into logical units before
  merge — often one PR is one well-described commit. Use
  `git commit --fixup <sha>` while iterating, then
  `git rebase -i --autosquash main` to tidy up. Don't merge a string of
  "fix typo", "address review", "oops" commits.
- **Each commit stands on its own.** It should build and pass `bin/ci`
  independently — no commit that knowingly leaves the suite red.
- **Messages: imperative subject, explain the *why*.** ~50-char subject, blank
  line, body if the change isn't obvious. Keep the `Co-Authored-By:` /
  `Claude-Session:` trailers we already use.
- **Force-push only your own feature branch** (after a rebase). Never force-push
  `main` or a shared branch.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the human-facing version and the PR
checklist.

## Deviate, but say so

This convention is a starting point, not dogma. When something genuinely doesn't
fit, you may break a rule — but you owe a one-line note in the PR description or an
in-code comment explaining why. **Silent deviation is the bug; justified deviation
is fine.**

## The payoff to aim for

You should be able to read the domain off the directory tree:

```
app/models/
  monitor.rb
  monitor/
    heartbeat_states.rb   # concern: status predicates + scopes
    check_in.rb           # operation: record a ping, transition, recover
    missed_ping.rb        # operation: flag down, open incident, alert
    uptime.rb             # concern: 90-day series + overall %
    uptime_rollup.rb      # operation: compute/upsert a day's stat
  user.rb
  user/
    plan.rb               # concern: monitor cap keyed off plan
    monitor_sync.rb       # operation: idempotent bulk upsert from the gem
  notifications/
    dispatch.rb           # coordinator (noun)
    channel.rb            # command contract
    email_channel.rb      # command
```

Every file's name tells you what it is and whose it is. There is no junk drawer to
grep, because there is no junk drawer.

---

## Project specifics

- **Stack:** latest stable Rails (8.x), PostgreSQL, Solid Queue / Solid Cable /
  Solid Cache, Hotwire (Turbo + Stimulus), Tailwind, Propshaft. Server-rendered,
  no SPA. Generated with `rails new` defaults; deploy via Kamal.
- **Auth:** Rails 8 built-in authentication generator (sessions +
  `has_secure_password`). No Devise, no OAuth.
- **Tests:** Minitest + fixtures + Capybara system tests (Rails 8 default). TDD —
  write the failing test first. Control time with `travel_to`/`freeze_time`.
- **System tests are non-negotiable.** Every key user-facing flow MUST have a
  passing **browser-driven** (Capybara) system test — see the rule below. This is
  the most-skipped layer and the one that proves the product actually works.
- **Locked decisions are binding:** the product/architecture decisions that
  govern this app are recorded in [`docs/specs/README.md`](docs/specs/README.md);
  follow them rather than re-deriving from scratch.
- **Secrets:** `ping_token` and API keys are secrets — random, hashed where the
  spec says, constant-time compare, shown raw once, opaque `404`/`401` on failure.
- **Third-party integration secrets (Stripe, Slack, etc.) live in Rails encrypted
  credentials, not Kamal.** Add them with `bin/rails credentials:edit` and read
  them via an `ENV["X"].presence || Rails.application.credentials.dig(...)`
  method on `Stablemate` (`config/initializers/stablemate.rb`) — see
  `stripe_secret_key` / `slack_webhook_url` for the pattern. Don't add these to
  `config/deploy.yml`'s `env:` or `.kamal/secrets`; that path is for
  infrastructure secrets the container itself needs to boot (`RAILS_MASTER_KEY`,
  registry credentials). Self-hosters may still set the `ENV` var directly
  (`.env.example`) since they have no credentials file — the env-first fallback
  is what makes both paths work without branching code.
