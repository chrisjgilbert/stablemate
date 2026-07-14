# Projects — first-class grouping for monitors

Status: **pressure-tested; findings resolved — ready to build (see §13 resolution
note)**. Author: Claude (session), 2026-07-14. Owner: @chrisjgilbert. Supersedes nothing; extends the
V1 data model in [`README.md`](README.md) and **amends locked decision #6** (see §3.3).
Follow the architecture rulebook in [`../../CLAUDE.md`](../../CLAUDE.md).

> This is a **design spec, not a build spec.** It proposes the shape, names the
> reuse boundaries, walks every surface the change touches, and enumerates the edge
> cases and assumptions. The §12 decisions are now **resolved** — the spec reflects
> those choices (project-scoped API keys, drop `monitors.user_id`, no default
> project, per-project key management).

---

## 1 · Motivation

Today a monitor belongs directly to a user (`Monitoring::Monitor belongs_to :user`,
`app/models/monitoring/monitor.rb:31`), and the whole app is tenanted on `user_id`.
There is **no grouping entity** — confirmed absent from the data model, the uptime
spec, and the API. A user monitoring three Rails apps sees one flat, unlabelled
list.

Three problems, in priority order:

1. **A latent data-integrity bug (the real driver).** Monitor identity for gem
   sync is the partial unique index `(user_id, registration_key) WHERE
   registration_key IS NOT NULL` (`README.md:159`), and `registration_key` is the
   `recurring.yml` task key (locked #6). Two apps under one account that share a
   task key (both have a `daily_digest` task, or both auto-register a
   `HeartbeatJob`) **collide**: the second app's sync silently updates/hijacks the
   first app's monitor. The gem already sends a free-text `app` string on sync
   (`api.md:112`) that *could* disambiguate them, but the server discards it. This
   is silent corruption for a legitimate multi-app customer.
2. **No organisation.** No way to group, label, filter, or navigate monitors by
   the app/service they belong to.
3. **No seam for what's next.** Public status pages, per-project API keys, and
   project-scoped team access (all on the horizon) each want a Project to hang off.
   Without it they'd each re-derive grouping ad hoc.

A first-class `Project` (a user has many projects; a project has many monitors)
fixes #1 structurally — the uniqueness key becomes `(project_id,
registration_key)`, so two apps are two projects with independent `registration_key`
namespaces — and delivers #2 and #3.

### The core comparison

| | Today | With Projects |
|---|---|---|
| Ownership | `monitor.user_id` | `monitor.project_id` → `project.user_id` |
| Uniqueness key | `(user_id, registration_key)` | `(project_id, registration_key)` |
| Two apps, same task key | **Collide** (silent hijack) | Two projects, no collision |
| Tenancy in controllers | `current_user.monitors` | `current_project.monitors` (API) / `current_user.monitors` through projects (web) |
| Gem identity of "which app" | free-text `app`, **discarded** | the project-scoped **API key** (§5) |
| Dashboard | one flat list | grouped by project |
| Cap | per user | **per user, unchanged** (§7) |

---

## Assumptions (state them plainly, per the ask)

- **A1 — one user, one plan, one cap, many projects.** Projects are an
  *organisational* layer, **not** a billing boundary. The monitor cap stays
  per-user and is shared across all a user's projects (§7). Per-project caps are a
  possible future lever, explicitly out of scope here.
- **A2 — the API exists for the gem.** The `/api/v1` surface is consumed by the
  companion gem (per-app), not by a cross-account dashboard client. This is what
  makes **project-scoped API keys** (§5, Design B) the natural fit — a key is "the
  credential for one app."
- **A3 — projects are all equal; there is no special/default project.** New users
  land on an empty state that prompts creating their first project; monitors and API
  keys always live under a project the user explicitly created. A user may have zero
  projects (clean empty state). No project is auto-created.
- **A4 — no production data (pre-launch).** The app is unlaunched (DECIDED §12-I), so
  the migration is **destructive with no backfill** (§8) and there are no existing gem
  installs to keep working — the phased-rollout and re-home concerns the earlier draft
  carried are moot.
- **A5 — alerts stay user-level in V1.** `down`/`recovered` emails go to the
  project's owner. Per-project notification routing is future (§12-G).
- **A6 — the public ping hot path and detection are untouched.** They key on
  `ping_token` (globally unique) and global status scopes, neither of which gains a
  project dimension (§2).

---

## 2 · The core reuse insight

**Most of the system does not move.** The change is surgical to the *ownership and
identity* layer; the operational machinery is untouched:

**Untouched:**
- **Ping hot path** — `match "/ping/:ping_token"` (`config/routes.rb:66`) resolves
  by the globally-unique `ping_token`; it never needed a user and doesn't need a
  project. Zero change.
- **Detection sweep** — `Monitoring::Monitor.overdue` / `detectable`
  (`monitor/heartbeat_states.rb:24-33`) are global scopes over `status` +
  `next_due_at`. Zero change.
- **Uptime rollup, incidents, notifications, ping events** — all keyed on
  `monitor_id` (`ping_events`, `incidents`, `notifications`, `uptime_day_stats` FKs,
  `schema.rb:227-237`). They hang off the monitor and follow it wherever it lives.
  The "at most one open incident per monitor" partial unique index and
  `(monitor_id, day)` uniqueness are unaffected.
- **Status vocabulary & the cap scope** — `STATUSES` and `counting_toward_cap`
  (`monitor/heartbeat_states.rb:15,41`) are unchanged; the cap still excludes only
  `suspended` (§7).

**What moves:**
- The **ownership FK**: `monitor.user_id` → `monitor.project_id`.
- The **uniqueness key**: `(user_id, registration_key)` → `(project_id,
  registration_key)`.
- **Tenancy scoping**: `current_user.monitors` (web, unchanged via a `through`
  association) and a new `current_project.monitors` (API, keyed off the API key).
- **API-key scope**: `api_key.user_id` → `api_key.project_id` (Design B, §5).

---

## 3 · Data model changes

### 3.1 New table: `Project`

```
### `Project`
`id`, `user_id`, `name`, timestamps.

- **No `slug` in V1** (§13-S3): under Design B the gem identity is the API key, not a
  slug, and status pages are V2 — a slug identifies nothing today, and deriving it from
  `name` breaks creation on colliding/emoji names. Add it in the V2 status-page spec
  if/when public URLs need it.
- **No "default" flag — projects are all equal** (§12-C). New users create their first
  project explicitly.
- Indexes: `(user_id, name)` unique; `user_id`.
```

### 3.2 `Monitor` (changes)

- **Add** `project_id` (bigint, FK to `projects`, `NOT NULL` from the start — no prod
  data to backfill, §8).
- **Drop** `user_id` and its FK (ownership flows `monitor → project → user`; DECIDED
  §12-B).
- **Swap** the unique index to `(project_id, registration_key) WHERE registration_key
  IS NOT NULL` (same partial-index shape, project anchor). This is the collision fix.
- ⊕ **Add** `last_synced_app` (string, null) — advisory metadata: the free-text `app`
  the gem sends on sync. On a sync UPDATE where the stored value differs from the
  incoming one, flag the monitor ("synced by two apps under one project key"). This is
  the shared-key detection the collision fix otherwise lacks (§13-B3).
- Keep everything else (`ping_token` unique, `next_due_at`, `(status, next_due_at)`).

### 3.3 Amend locked decision #6

Decision #6 (`README.md:25`) currently reads: *"`registration_key` = the
`recurring.yml` task key … "*, with uniqueness `(user_id, registration_key)`.
`registration_key` **keeps its meaning** — it is still the task key. What changes is
the *scope of its uniqueness*: `(project_id, registration_key)`. This spec is the
deviation note (per CLAUDE.md "deviate, but say so"); when built, update
`README.md` §1 #6 and the `Monitor` data-model block (`README.md:148-159`) to the
project-scoped index.

### 3.4 `ApiKey` (changes — Design B)

- **Add** `project_id` (FK, `NOT NULL` from the start — no prod data, §8); **drop**
  `user_id` and its FK.
- `belongs_to :project`; `user` delegates through the project.
- `token_digest` stays globally unique (`README.md:145`); auth still resolves a raw
  `sm_live_…` token to one key row (`api_key/authentication.rb:24-34`) — that key now
  yields a **project**, not a user. See §5. `ApiKey.issue(project:, name:)` replaces
  `issue(user:)`, and the standalone `settings/api_keys` **create** action is removed —
  issuance is reachable only from a `projects/:id` context (§13-S9).

### 3.5 Migration sketch (one destructive migration — no prod data, §8)

The app is unlaunched, so there is **no production data to preserve** (DECIDED §12-I).
This is ONE destructive migration that installs the target schema directly — no
nullable-then-enforce, no backfill, no dual-write, no `CONCURRENTLY`. It runs against
empty tables (dev DBs are reset; CI loads the schema), so `null: false` references are
safe. `db/seeds.rb` is rewritten to seed a project.

```ruby
create_table :projects do |t|
  t.references :user, null: false, foreign_key: true
  t.string :name, null: false
  t.timestamps
end
add_index :projects, [ :user_id, :name ], unique: true    # no slug in V1 (§3.1)

# Monitors + keys belong to a project from the start; user_id is gone.
add_reference :monitors, :project, null: false, foreign_key: true
add_reference :api_keys,  :project, null: false, foreign_key: true
remove_reference :monitors, :user, foreign_key: true
remove_reference :api_keys,  :user, foreign_key: true
add_column :monitors, :last_synced_app, :string           # advisory (§3.2, §13-B3)

# Collision fix: uniqueness is project-scoped.
remove_index :monitors, name: "index_monitors_on_user_and_registration_key"
add_index :monitors, [ :project_id, :registration_key ], unique: true,
          where: "registration_key IS NOT NULL",
          name: "index_monitors_on_project_and_registration_key"
```

Intentionally **not reversible** — fine pre-launch.

---

## 4 · Domain design (architecture-compliant)

Target tree (CLAUDE.md decision table: a grouping noun is a model; complex
operations are entity-scoped operation objects; no `app/services/`):

```
app/models/
  project.rb                     # the entity: name, associations
  project/
    monitor_sync.rb              # operation: bulk upsert (MOVED from user/)
  user.rb                        # has_many :projects; :monitors through projects
  user/
    plan.rb                      # cap: counts monitors across projects (§7)
    downgrade.rb                 # choose-5 spans projects (§7)
  monitoring/
    monitor.rb                   # belongs_to :project (was :user)
    monitor/
      transfer.rb                # operation: move a monitor between projects (§6)
  api_key.rb                     # belongs_to :project (Design B)
```

### 4.1 `Project`

```ruby
class Project < ApplicationRecord
  belongs_to :user
  has_many :monitors, class_name: "Monitoring::Monitor", dependent: :destroy
  has_many :api_keys, dependent: :destroy

  validates :name, presence: true, uniqueness: { scope: :user_id }

  def sync_monitors(entries:) = MonitorSync.new(self).call(entries:)
  # …rename helper…
end
```

- No `slug` (§3.1). `name` is the only identifier and is unique per user.
- `dependent: :destroy` on `:monitors` reuses the monitor's existing cascade
  (`monitor.rb:32-35` already destroys ping_events/incidents/notifications/
  uptime_day_stats). So `project.destroy` → monitors → their children, and
  `user.destroy` → projects → monitors → children — which also cleanly serves the
  **account-deletion** launch blocker. (For high-volume children, prefer a DB-level
  `ON DELETE CASCADE` or batched purge over Rails `dependent: :destroy` — §13-S10.)

### 4.2 `Monitoring::Monitor` (changes)

- `belongs_to :project` replaces `belongs_to :user`. Add `delegate :user, to:
  :project, allow_nil: true` so `monitor.user` (used by `within_monitor_cap`, mailers,
  broadcasts) keeps working — `allow_nil` avoids a `NoMethodError` on a monitor built
  before its project is set (§13 minor).
- `within_monitor_cap` (`monitor.rb:102-107`) references `user` → now
  `project.user`; the cap check itself is unchanged (§7).
- Creation moves to project scope: `@project.monitors.new(...)` (see §6, §5).

### 4.3 `Project::MonitorSync` (moved from `User::MonitorSync`)

The upsert operation moves onto the noun that now owns the monitors and the
`registration_key` namespace. It is a near-verbatim relocation of
`app/models/user/monitor_sync.rb`:

- Lookup/create against `project.monitors` instead of `user.monitors`
  (`monitor_sync.rb:63,117`).
- **The row lock stays on the USER, not the project** — the cap is per-user across
  projects, so concurrent syncs of *different* projects of the same user must
  serialise on `project.user` to keep slot accounting atomic
  (`monitor_sync.rb:56-57`; the WU-3 guard). This is a subtle but critical edge.
- Cap budgeting reads `project.user.remaining_monitor_slots` (still per-user).
- The `Entry` mass-assignment whitelist, `RecordNotUnique` rescue (now off the new
  index), partial-atomicity, and skip reasons (`limit_reached`/`invalid`) all carry
  over unchanged.
- **Interaction with the uptime spec:** `uptime-monitor.md:310-314` also extends
  this operation's `Entry` whitelist (`monitor_type`, `url`). The two changes
  compose — this spec changes the *receiver* (User→Project) and lookup scope; that
  one grows the *whitelist*. Land whichever first; the other rebases trivially.

### 4.4 Onboarding (no auto-provisioned project)

There is no special/default project (§12-C) and no backfill (§8 — no prod data). A
brand-new user lands on an empty-state dashboard prompting "Create your first project"
(§6, §13-S6); monitor creation and API-key generation both require a project, so the
empty state routes into project creation. Nothing auto-creates a project on signup, and
there is no default to maintain.

### 4.5 `User` (changes)

```ruby
has_many :projects, dependent: :destroy
has_many :monitors, through: :projects, source: :monitors   # cross-project reads
has_many :api_keys, through: :projects
```

`has_many :through` keeps every existing **read** call site working unchanged:
`current_user.monitors.order(:created_at)` (`monitors_controller.rb:5`),
`user.monitors.counting_toward_cap.count` (`plan.rb:61`),
`@user.monitors.where(id:)` (`downgrade.rb`). What a `through` association **cannot**
do is `.new`/`.build`/`.create`/`.create!`/`find_or_create_by!` — it *raises*. So
**every** build/create site must move to project scope — and the pressure test
(§13-B2) found that is **four app sites** (`MonitorsController#new` *and* `#create`,
`Project::MonitorSync`, `ApiKey::Issuance`) plus ~20 test sites and `db/seeds.rb`,
**not "two."** Converting them all is a Phase-2 work item; otherwise `bin/ci` goes
red the instant the association flips.

---

## 5 · Identity & the gem/sync protocol — the headline decision

**Question:** when the gem syncs, how does the server know which project the
monitors belong to? This forks the design (§12-A). Recommended answer: **Design B —
the project-scoped API key.**

### Design B (recommended): the key is the project identity

The API key gains `project_id` (§3.4). The gem authenticates with a **per-project
key**; the key *is* the answer to "which app." Sync and read both scope to
`current_api_key.project`. Concretely, `Api::V1::BaseController`
(`base_controller.rb:32-53`) changes from resolving key→user to key→**project**:

```ruby
@current_api_key = ApiKey.authenticating(bearer_token)
@current_project = @current_api_key&.project           # was: &.user
render_unauthorized unless @current_project
# find_monitor / index / sync all scope to current_project.monitors
```

Why B is the right foundation:

- **Fixes both the write AND the read collision, for free.** Sync upserts into
  `current_project.monitors` (write scoped). Crucially, `GET /api/v1/monitors`
  (`monitors_controller.rb:5`) — used by the gem's `refresh_ping_urls!`
  (`register_on_boot: false`) and the stale-ping resync — returns only the key's
  project. Without this, the gem caches `registration_key → ping_url`
  (`registration.rb:50-58`) across projects and, now that keys can repeat across
  projects, **collides on read** (wrong ping URL wins). B scopes the read path with
  no extra parameter.
- **Zero gem code change; fully backward-compatible.** The gem already sends only a
  bearer key on both sync and GET (`client.rb:22-46`). Old gems keep sending their
  now-ignored top-level `app` string — the server just ignores it. Existing installs
  keep working because their migrated key is scoped to the Default project that
  holds their existing monitors (§8) — **no re-home, no duplicate monitors**.
- **Real isolation.** A leaked key touches one project, not the whole account.
- **Guides correct usage.** The natural workflow — create project → generate its
  key → drop it in that app — yields one key per app, which is exactly the isolation
  that prevents the collision.

Gem changes under B: **none required.** Optional/cosmetic: stop sending the ignored
`app` field and add a doc note ("generate one API key per project"). Version bump
optional.

### Design A (documented alternative): resolve a project from a name the gem sends

Keep API keys user-scoped; on sync, `find_or_create` a project from a name string
and upsert within it. Rejected as the primary because:

- The **read path** (`GET /monitors`) sends no project identifier today
  (`client.rb:39-46`), so A requires a *gem protocol change* to scope reads —
  otherwise the read-cache collision above persists.
- The gem's current app string is **unstable** (derived from the Rails module name,
  `"app"` fallback, `registration.rb:60-68`), so A also wants a new stable
  `config.project` — another gem change and a version-coordination matrix.
- **Migration re-home problem:** the server can't predict the app string at backfill
  time (A4), so the first post-migration sync creates a *new* per-app project and
  leaves the legacy monitors orphaned in Default — duplicates for every existing gem
  user. B has none of this.

See §12-A for the decision.

---

## 6 · UI / UX (Hotwire-first, server-driven)

- **Nav** (`layouts/application.html.erb:21-32`): add a **Projects** entry; the "API
  keys" nav link now points at `projects#index` (keys are per-project — §13-S9).
- **First run / zero projects** (§13-S6): a new user has no projects, so the dashboard
  shows a **create-first-project** empty state (not today's monitor-centric one). Both
  "add a monitor" and "connect the gem" route through project creation first, and the
  gem copy changes from "your jobs register themselves, no setup" to "create a project,
  copy its API key into your app" — under Design B a key is required before the gem does
  anything.
- **Dashboard** (`monitors/index.html.erb`): with ≥1 project, group monitor rows **by
  project** (headed sections), reusing `_row.html.erb`. Keep the active/suspended split
  within each group. Cap display (`count / current_user.monitor_limit`,
  `index.html.erb:8-9`) stays **user-level** (§7). If a project has monitors skipped at
  the cap, show a per-project "N skipped — account at cap" banner (§13-S5) — the
  `limit_reached` signal must live in the UI, not only the gem log.
- **Project CRUD** — standard REST (`resources :projects`). `show` = the project's
  monitor list + its API keys.
  - **Rename** updates `name` (the only identifier; no slug in V1).
  - **Delete** cascades the project's monitors + all ping/uptime history + keys.
    Irreversible, so require a **strong confirmation** (type the project name), not a
    bare dialog (§13-S4). A user may delete down to zero projects → empty state.
- **Create a monitor** (`monitors_controller.rb:24-37`): the form gains a **project
  selector** (pre-selected to the user's most-recent project by `created_at`; if none,
  route to create one first). Create via `@project.monitors.new(...)`; `params.permit`
  adds `:project_id` scoped to `current_user.projects` (no cross-tenant assignment). A
  per-project "New monitor" button pre-fills the project.
- **Move a monitor** — a sub-resource, not a custom verb (CLAUDE.md rule 4):
  `resource :project, only: :update, module: :monitors` → `Monitors::ProjectsController
  #update` → `Monitoring::Monitor::Transfer`. **Only `source: "manual"` monitors are
  movable** (DECIDED §12-I): a gem monitor belongs to whichever project its key syncs
  into, so the UI blocks moving it (a moved gem monitor would just be re-created in the
  key's project on the next sync). To reorganize gem monitors, re-point the app's key at
  the target project's key. A transfer that would collide on `(project_id,
  registration_key)` in the target is rejected with a clear error, not a 500.
- **API keys** live under the project (Design B): the project `show` page lists masked
  keys + "Generate key" (shown-once modal), issued via `ApiKey.issue(project:)`. The
  standalone `settings/api_keys` **create** action is removed (§13-S9).

Every user-facing flow above ships a **browser-driven system test** (CLAUDE.md; §10).

---

## 7 · Caps, billing & downgrade interactions

The cap stays **per-user, across all projects** (A1). Plan is a `users` column
(`schema.rb:214`); `User#monitor_limit/at_monitor_cap?/remaining_monitor_slots/
over_free_cap_by` (`plan.rb:26-56`) all count `user.monitors.counting_toward_cap`
— which, via the new `has_many :through`, now transparently sums across the user's
projects. **No cap logic changes**; only the association path underneath it does.

- `within_monitor_cap` (`monitor.rb:102-107`) now reads `project.user.at_monitor_cap?`.
- **Sync budgeting**: `Project::MonitorSync` reads `project.user.remaining_monitor_slots`
  and locks the **user** row (§4.3) so two apps of one user syncing concurrently can't
  both consume the last slot. (The lock serializes sync-vs-sync; the pre-existing
  web-create-vs-sync check-then-act TOCTOU is unchanged, not worsened — §13 minor.)
  Edge: if app A's monitors fill the user's cap, app B's new monitors come back
  `skipped: limit_reached` — correct per-user behaviour; **surface it as a per-project
  banner in the UI** (§6, §13-S5), not only in the gem log.
- **Voluntary downgrade "choose your 5"** (`user/downgrade.rb`): keep-count is still
  `FREE_PLAN_MONITOR_LIMIT` and `active_scope` is `@user.monitors.counting_toward_cap`
  (`downgrade.rb:79-80`) — now spanning projects. The **choose-5 picker UI groups
  candidates by project** (preload `.includes(:project)` to avoid N+1). Suspended
  monitors stay in their project. `resolve_choice!` needs no logic change.
- **Involuntary downgrade** (card failure) — DECIDED §12-J, Option 1 (simplest):
  `enforce_free_cap!` keeps the *oldest* over-cap monitors across projects as a
  **temporary default** (no logic change), and the existing `awaiting_downgrade_choice`
  flag forces the user into the project-grouped picker to make the real selection.
  Accept the transient window (card-fail → next login, in which a newer project may be
  fully suspended) as inherent to any auto-suspend, bounded by dunning emails.
- **Subscription** (`user/subscription.rb`): `restore_suspended_monitors!` reactivates
  `user.monitors.where(status: "suspended")` up to remaining slots — works unchanged
  across projects.

Per-project caps (e.g. as a paid lever) are explicitly **out of scope** (§12-F).

---

## 8 · Migration (destructive — pre-launch, no production data)

**DECIDED (§12-I): the app is unlaunched, so there is no production data to preserve —
the migration is a single destructive schema change, not a phased backward-compatible
rollout.** This collapses the phased-rollout hazards the pressure test raised (§13-B1,
S1, S2, S7): they existed only to protect a live, populated table.

- **One migration** (§3.5): create `projects`, add `project_id NOT NULL` to `monitors`
  and `api_keys`, drop `user_id`, install the project-scoped unique index, add
  `last_synced_app`. No nullable-then-enforce, no backfill, no `CONCURRENTLY`, no
  dual-write, no straggler re-backfill — the tables are empty at migration time.
- **Dev/staging DBs are reset** (`bin/rails db:reset`), not migrated. `db/seeds.rb` is
  rewritten to create a `Project` and seed `project.monitors.create!` (§13-H1).
- **No "Default"/backfill ceremony** — there are no existing rows to re-home and no
  existing gem installs, so the earlier transition edge cases (already-collided users,
  legacy shared keys, re-home duplicates) are all moot.
- The real work is **not** the migration; it's the **call-site + test conversion**
  (§13-B2): the 4 app build sites, ~20 test sites, and `db/seeds.rb` all move to
  `project.monitors` / `project.api_keys` in the same PR. `bin/ci` is green at the
  **end** of that PR — there is no intermediate phase to keep green (§11).

> The **shared-key collision** (§13-B3) is a *runtime*, not a migration, concern: a
> future user who copies one API key into two apps still collides within that project.
> `last_synced_app` (§3.2) detects and flags it. That fix ships with the feature.

---

## 9 · API surface

- **Auth/scoping (Design B):** `Api::V1::BaseController` resolves the key to a
  **project**; `find_monitor`/`index`/`sync` scope to `current_project.monitors`
  (`base_controller.rb:32-53`). The opaque-404 cross-tenant guarantee
  (`README.md:124`, `base_controller.rb:55-57`) becomes cross-**project**, and gains
  a new test (§10).
- **Sync** (`POST /api/v1/monitors/sync`, `syncs_controller.rb`): drop the reliance
  on `params[:app]` (still accept-and-ignore it for old-gem back-compat), delegate to
  `current_project.sync_monitors(entries:)`. Request/response envelope unchanged
  (`api.md:99-136`) so old gems keep working.
- **Read** (`GET /api/v1/monitors`, `:id`): unchanged shape, now project-scoped by
  the key. Optionally add `"project": {id, name}` to `monitor_json`
  (`base_controller.rb:74-88`) for API consumers — the gem ignores it.
- **Rotate** (`POST /api/v1/monitors/:id/rotate`): unchanged, now project-scoped.
- **Key management**: `ApiKey.issue(project:, name:)` replaces `issue(user:, name:)`
  (`api_key/issuance.rb`); web routes move under the project (§6, §12-E).
- **No account-wide API key** exists under B (a key sees one project). If a
  cross-project/account key is ever needed (a user's own reporting script), that's a
  separate future key type (§12-A note).

---

## 10 · Testing plan (system tests non-negotiable — CLAUDE.md)

New **fixtures** (establishing precedent — today only `users.yml` + `monitors.yml`
exist): `test/fixtures/projects.yml` (one project per fixture user, e.g.
`alices_default`, `bobs_default`, loaded before `monitors.yml`); `monitors.yml`
references `project: alices_default` and **drops** `user:` (fixtures insert via raw
SQL; since the destructive migration removes `monitors.user_id` in the same PR, there
is no `user_id` to set — no dual-phase fixture juggling, §13-S7 is moot under §8). API
keys stay minted in-test, now via `ApiKey.issue(project:, name:)`.

- **[model] Project** — `(user_id, name)` uniqueness, `dependent: :destroy` cascade to
  monitors→children, deletable down to zero.
- **[model] Project::MonitorSync** — port every scenario from
  `monitor_sync_test.rb:11-163` to project scope; **add**: same `registration_key`
  in two projects of one user coexists (the collision-fix proof); the user-row lock
  serialises concurrent syncs of two projects (cap-accounting atomicity).
- **[model] User::Plan / Downgrade** — cap counts across projects; choose-5 spans
  projects and suspends the right ones; `over_free_cap_by` across projects.
- **[request] api/v1** — sync upserts into the **key's project**; a key cannot see
  another project's monitors (cross-project 404, mirroring
  `monitors_controller_test.rb:52-77`); GET is project-scoped; back-compat: a request
  still carrying a top-level `app` string succeeds and ignores it.
- **[request] web** — monitor create honours `project_id` and rejects a foreign
  project id; move-monitor sub-resource; project CRUD tenant scoping.
- **[gem]** — no protocol change under B; keep the existing gem suite green. (If any
  optional `app`-drop lands, assert old-and-new payloads both sync.)
- **[system]** (browser-driven, the required layer):
  - create a project → it appears in the nav/list;
  - dashboard groups monitors by project;
  - create a monitor into a chosen project;
  - move a monitor between projects (Turbo);
  - generate a project-scoped API key (shown-once modal);
  - delete a project (confirmation; may delete down to zero → empty state);
  - regression: the existing S3/S4/S5/S7/S8/S17/S18 monitor flows
    (`system/monitors_test.rb`, `monitor_edit_delete_test.rb`) still pass with a
    project present.

The **non-negotiable, unbudgeted test work** (§13-B2): the ~20 `user.monitors
.create!/.build` sites across ~16 files, the 6 `ApiKey.issue(user:)` callers, and
`db/seeds.rb` all convert to project scope in the same PR as the association flip.

---

## 11 · Rollout (one PR — no phasing, no prod data)

Because the migration is destructive and there is no live data to protect (§8),
there is **no phased, independently-deployable rollout** and no "green at every phase"
constraint — the whole change lands in **one PR**, `bin/ci` green at its end. Split
into review-sized commits for readability, not for deployability:

1. **Schema + models.** The destructive migration (§3.5); `Project` + associations;
   `User has_many :through`; `Monitor belongs_to :project` + `delegate :user`;
   `ApiKey belongs_to :project`; `Project::MonitorSync` (moved).
2. **Cutover.** API base controller resolves key→project; **every** build/create site
   (4 app + ~20 test + `db/seeds.rb`, §13-B2) moves to project scope; fixtures gain
   `projects.yml` and drop `user:`.
3. **UI.** Projects nav, first-run/zero-project empty state, grouped dashboard, project
   CRUD (+ strong delete confirm), monitor-create project selector, move-monitor
   sub-resource (manual-only), per-project API keys, cap-skip banner. System test per
   flow.
4. **Docs.** Update `README.md` #6 + the data-model block (§3.3); gem README "one key
   per project."

---

## 12 · Decisions (resolved)

Resolved with the owner, 2026-07-14 — the four material choices plus the deferred/minor ones.

- **A · Identity/auth model. DECIDED: B — project-scoped API keys.** Each key belongs
  to one project; the key *is* the app identity. Scopes both the write and *read* path
  with zero gem change, fully backward-compatible, no migration re-home/duplicate
  problem. Gives up an *account-wide* API key (a key sees one project) — acceptable
  (A2), addable later as a distinct key type.
- **B · `monitors.user_id`. DECIDED: drop it.** Single source of truth
  (`monitor → project → user`); `has_many :through` covers every read; `delegate :user`
  covers `monitor.user`. The larger, more careful migration is worth the correctness.
- **C · A special/default project? DECIDED: no.** Projects are all equal — no
  `default`/`is_default` flag, no one-per-user index, no delete-guard. New users create
  their first project via empty-state onboarding; manual-create pre-selects the user's
  most-recent project (by `created_at`); a user may delete down to zero projects. No
  backfill exists (§8 — no prod data).
- **D · Signup provisioning. DECIDED: none** (consequent to C). Nothing auto-creates a
  project on signup; the empty state routes the user into creating their first project
  when they add a monitor or key.
- **E · API-key management location. DECIDED: per-project** (under `projects/:id`) —
  matches "a key is for one app"; keep a redirect from the old `settings/api_keys`.
- **F · Per-project caps. DECIDED: out of scope for V1** (the cap stays per-user).
- **G · Per-project alert routing. DECIDED: out of scope for V1** (alerts go to the
  project owner).
- **H · `Project` namespacing. DECIDED: top-level `Project`** (no stdlib collision; an
  account-level entity that also owns API keys).
- **I · Reorganizing gem-synced monitors + the migration. DECIDED.** Two parts:
  (1) *migration* — the app is unlaunched, so **be destructive**: no prod data to
  preserve, no backfill, one destructive migration (§8, §3.5). (2) *runtime* — gem
  monitors are **not movable** in V1: a gem monitor belongs to whichever project its
  API key syncs into; the UI blocks moving it and tells the user to re-point the app's
  key (§6). Only `source: "manual"` monitors move between projects. (A history-
  preserving "adopt + rebind key" flow can come later if demand appears.)
- **J · Involuntary-downgrade project-awareness. DECIDED: Option 1 (simplest).** Keep
  the age-based auto-suspend (oldest over-cap across projects) as a *temporary default*;
  the existing `awaiting_downgrade_choice` project-grouped picker is the real selection
  (§7). Accept the transient window; no per-project fairness logic.

---

## 13 · Pressure-test findings (must resolve before this is a build spec)

Five adversarial reviews — migration safety, auth/identity, `has_many :through` blast
radius, UX/gem edges, completeness — 2026-07-14, each grounded in file:line evidence.
The **core data-model shape survived** (see *Held*, end); the failures clustered in
migration mechanics, the `through`-association blast radius, and edges the draft waved
off with "document it." Ranked.

> **Resolution status (owner decisions folded in, 2026-07-14).** The findings below are
> the *original* reports; here is what happened to each:
> - **Resolved by "destroy & rebuild, no prod data" (§8/§11):** B1, B4-migration, S1,
>   S2, S7 — the phased-rollout hazards are gone (one destructive migration).
> - **Folded into the spec:** B2 (§4.5 count corrected + §10/§11 conversion work item),
>   B3 (`last_synced_app` advisory flag, §3.2), B4-runtime (gem monitors non-movable,
>   §6/§12-I), S3 (slug dropped, §3.1), S4 (strong delete confirm, §6), S5 (cap-skip UI
>   banner, §6/§7), S6 (first-run empty state + gem copy, §6), S8/§12-J (Option 1), S9
>   (settings/api_keys create removed, §3.4/§6), S10 (cascade note, §4.1), S11 (uptime
>   composition, §4.3), and the minors (`allow_nil`, most-recent-by-`created_at`).
> - **Remaining as build-time work (not spec gaps):** the ~26 build-site conversions
>   (§13-B2) and the `uptime-monitor.md` reconciliation if that ships in the same window.

### Blocking (a real deploy or the headline use case breaks)

- **B1 · Migration phasing leaves `project_id` NULL → Phase 4 `NOT NULL` crashes the
  deploy.** Rows created during the rollout window, and new signups between Phase 1
  and Phase 2, are written by the old `user.monitors`/`user.api_keys` path (no
  `project_id`). Fix: **dual-write `project_id` before the backfill** (move creation-to-
  project and `ApiKey.issue(project:)` into the same deploy that adds the nullable
  column), **re-backfill stragglers inside the enforce migration**, and guard with
  `CHECK (project_id IS NOT NULL) NOT VALID` → `VALIDATE`. [migration]
- **B2 · `has_many :through` cannot `build`/`create`/`create!`/`find_or_create_by!` —
  the "two creation sites" is wrong.** Real count: **4 app sites** (`MonitorsController
  #new` — the form GET 500s — and `#create`, `Project::MonitorSync`, `ApiKey::Issuance
  #call`) + ~20 test sites across ~16 files + `db/seeds.rb:13`. All raise the instant
  §11 Phase 2 flips the association, so "CI green at every phase" is false unless every
  site is converted to project scope **in** Phase 2. Fix: §4.5 wording (done) + a
  Phase-2 conversion work item. [architecture, tests]
- **B3 · The shared-key case reintroduces the exact silent corruption the feature
  exists to kill — and Design B discards the signal that could catch it.** Copying a
  gem initializer into a second app (the natural path) reuses the key → one project →
  same-`registration_key` collision → one app's pings mask the other's death. Nothing
  surfaces it, so the draft's "visible misconfiguration" is unsupported. Fix: persist
  the gem's `app` string as advisory metadata (nullable `Monitoring::Monitor
  #last_synced_app`); on a sync *update* where the recorded app differs, raise a
  dashboard flag. Additive, no gem change. [auth, data]
- **B4 · No history-preserving way to reorganize gem-synced monitors** — the feature's
  headline journey. See §12-I. **Decision needed.** [ux, data]

### Should-fix

- **S1 · Migration lock/concurrency cost.** Phase 4 (change_column_null + a
  non-`CONCURRENTLY` unique index + column drops) in one transaction takes
  `ACCESS EXCLUSIVE` on `monitors`. Split migrations, `disable_ddl_transaction!`,
  `algorithm: :concurrently`, batch the backfill, set `lock_timeout`. [migration]
- **S2 · Migration idempotency/reversibility.** Backfill `create!` fails on retry → use
  `find_or_create_by!`; typeless `remove_column` is `IrreversibleMigration`; don't
  couple the data migration to live models; shadow-keep `user_id` one release before
  the final drop. [migration]
- **S3 · `slug` is vestigial under Design B and its name-derivation breaks creation.**
  The key (not slug) is the gem identity; status pages are V2. "My App"/"My App!"
  collide; emoji/non-ASCII names → blank slug → uncreatable. Fix: **drop `slug` from
  V1** (recommended), or de-dup + fallback; correct the "gem identity" rationale in
  §3.1. [data, ux]
- **S4 · Deleted project/key → a running gem goes silently dark** (401s swallowed, no
  down alerts because the monitors were deleted). Log the deleted-key 401 distinctly;
  require a strong (type-the-name) delete confirmation; consider soft-delete/export
  given the cascade nukes all history. [ux]
- **S5 · Cap-skip (`limit_reached`) is invisible in the UI** — returned only to the gem
  (which logs). Surface a per-project "N monitors skipped — account at cap" indicator.
  [ux]
- **S6 · Zero-project first-run is under-specified and contradicts the "zero-config
  gem" pitch.** Today's empty state is monitor-centric; under B a new user must create
  project → key first. Design the create-first-project screen, fix the gem-install
  copy, and specify the `new_monitor`→`new_project` redirect + return. [ux]
- **S7 · Fixtures must set BOTH `user:` and `project:` during Phases 1–3** (`user_id`
  stays `NOT NULL` until Phase 4); `projects.yml` loads first. §10 describes only the
  end state. [tests]
- **S8 · Involuntary downgrade is project-blind** — see §12-J. **Decision needed.**
  [billing]
- **S9 · `settings/api_keys` create has no project to target** (no default project).
  Remove the settings create action (issuance only from a `projects/:id` context);
  point the nav "API keys" link at `projects#index` or drop it. [ux, architecture]
- **S10 · Account-deletion cascade is O(rows).** `dependent: :destroy` instantiates
  every monitor + child; for `ping_events`/`uptime_day_stats` use DB-level
  `ON DELETE CASCADE` or a batched purge. [migration, perf]
- **S11 · uptime-monitor.md composition is not "trivial."** Both specs rewrite
  `SyncsController#create`/`sync_params` and `monitor_json`; uptime needs URL/type
  validation inside the *moved* `Project::MonitorSync`. Reconcile explicitly whichever
  lands second. [architecture]

### Minor

- `delegate :user, to: :project` needs `allow_nil: true` (crashes on a null-project
  monitor mid-migration).
- "Most-recently-used project" pre-selection (§6) has no backing column — define it
  (project of the newest monitor) or add one.
- Rate-limit budget is now per-key/per-project, not per-user — note it in §9.
- An existing single key silently narrows to Default once the user adds a 2nd project
  — add an upgrade note.
- Don't manufacture empty "Default" projects for users with zero monitors/keys.

### Held (survived the attack — do not re-litigate)

Project-scoped read **and** write collision fix (one gem process = one key = one
project); cross-project isolation & opaque 404 (dangling key → 401, moved monitor →
404, no existence leak); auth mechanics unchanged by the `belongs_to` swap; back-compat
of ignoring `app`; cascade correctness & FK ordering; `ping_token` global uniqueness;
`has_many :through` for **reads**; the `monitor.user` delegate covering mailers/
broadcasts/`within_monitor_cap` (no scalar `user_id` landmines); all jobs global;
`RecordNotUnique` rescue index-name-agnostic; `update_all` callback-skip safe here; the
new `(project_id, registration_key)` index inherits uniqueness cleanly; `Project::
MonitorSync` is architecture-compliant.
