# Stablemate — engineering conventions

Read this before writing code. Stablemate follows a **strict, 37signals-inspired,
vanilla-Rails architecture**: keep `app/` small, put logic on records, and never
default to a generic service bucket. The full rationale and worked examples are
below; the **per-phase object inventory** lives in
[`docs/specs/architecture.md`](docs/specs/architecture.md) and the build contract
in [`docs/specs/`](docs/specs/).

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

- **Stack:** Rails 8, PostgreSQL, Solid Queue / Solid Cable / Solid Cache, Hotwire
  (Turbo + Stimulus), Tailwind, Propshaft. Server-rendered, no SPA. Deploy via Kamal.
- **Auth:** Rails 8 built-in authentication generator (sessions +
  `has_secure_password`). No Devise, no OAuth.
- **Tests:** Minitest + fixtures + Capybara system tests (Rails 8 default). TDD —
  write the failing test from the phase spec's Test Plan first. Control time with
  `travel_to`/`freeze_time`.
- **Specs are the build contract:** follow [`docs/specs/`](docs/specs/), not a
  re-reading of the PRD. The locked decisions are in
  [`docs/specs/README.md`](docs/specs/README.md).
- **Secrets:** `ping_token` and API keys are secrets — random, hashed where the
  spec says, constant-time compare, shown raw once, opaque `404`/`401` on failure.
