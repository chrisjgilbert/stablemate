# Projects — first-class grouping for monitors

Status: **draft for review**. Author: Claude (session), 2026-07-14. Owner: @chrisjgilbert.
Supersedes nothing; extends the V1 data model in [`README.md`](README.md) and
**amends locked decision #6** (see §3.3). Follow the architecture rulebook in
[`../../CLAUDE.md`](../../CLAUDE.md).

> This is a **design spec, not a build spec.** It proposes the shape, names the
> reuse boundaries, walks every surface the change touches, enumerates the edge
> cases and assumptions, and lists the decisions that need your sign-off (§12)
> before anyone writes a migration.

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
- **A3 — a user always has ≥1 project.** Signup provisions a default project; the
  last project cannot be deleted (§4.2, §6).
- **A4 — existing monitors' original app attribution is unknowable.** The `app`
  string was never persisted, so the backfill cannot reconstruct which app each
  legacy monitor came from — they all land in one **Default** project (§8). This is
  lossless (the old per-user uniqueness guaranteed no dupes within that set) and,
  under Design B, seamless for the gem.
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
`id`, `user_id`, `name`, `slug`, ⊕ `default` (bool, default false), timestamps.

- `slug` ≡ `name.parameterize`, set at creation and STABLE thereafter (it is the
  gem/status-page identity; renaming changes `name` only). Backfilled "Default".
- `default` marks the signup/auto-provisioned project — the home for manual
  monitors before a user makes a second project, and the scope legacy API keys
  migrate to (§8). Exactly one per user.
- Indexes: `(user_id, slug)` unique; `(user_id) WHERE default` unique (one default
  per user); `user_id`.
```

`slug` follows the app's established partial-unique-index idiom (`README.md:159`).
`(user_id, slug)` is a *full* unique index (slug is never null).

### 3.2 `Monitor` (changes)

- **Add** `project_id` (bigint, FK to `projects`, `null: false` after backfill).
- **Drop** `user_id` (ownership now flows `monitor → project → user`; see §12-B for
  the denormalised-keep alternative).
- **Swap** the unique index: drop `index_monitors_on_user_and_registration_key`,
  add `(project_id, registration_key) WHERE registration_key IS NOT NULL` (same
  partial-index shape, new anchor). This is the collision fix.
- Keep everything else (`ping_token` unique, `next_due_at`, `(status,
  next_due_at)`).

### 3.3 Amend locked decision #6

Decision #6 (`README.md:25`) currently reads: *"`registration_key` = the
`recurring.yml` task key … "*, with uniqueness `(user_id, registration_key)`.
`registration_key` **keeps its meaning** — it is still the task key. What changes is
the *scope of its uniqueness*: `(project_id, registration_key)`. This spec is the
deviation note (per CLAUDE.md "deviate, but say so"); when built, update
`README.md` §1 #6 and the `Monitor` data-model block (`README.md:148-159`) to the
project-scoped index.

### 3.4 `ApiKey` (changes — Design B)

- **Add** `project_id` (FK, `null: false` after backfill); **drop** `user_id`.
- `belongs_to :project`; `user` delegates through the project.
- `token_digest` stays globally unique (`README.md:145`); auth still resolves a raw
  `sm_live_…` token to one key row (`api_key/authentication.rb:24-34`) — that key
  now yields a **project**, not a user. See §5.

### 3.5 Migration sketch (phased — see §11 for ordering)

```ruby
# 1. Create projects.
create_table :projects do |t|
  t.references :user, null: false, foreign_key: true
  t.string :name, null: false
  t.string :slug, null: false
  t.boolean :default, null: false, default: false
  t.timestamps
end
add_index :projects, [ :user_id, :slug ], unique: true
add_index :projects, :user_id, unique: true, where: "\"default\"",
          name: "index_projects_one_default_per_user"

# 2. Add nullable project_id to monitors + api_keys.
add_reference :monitors, :project, foreign_key: true            # nullable for now
add_reference :api_keys, :project, foreign_key: true

# 3. Backfill (data migration): one Default project per user, then repoint.
User.find_each do |u|
  p = Project.create!(user: u, name: "Default", slug: "default", default: true)
  u.monitors.update_all(project_id: p.id)   # all legacy monitors → Default
  u.api_keys.update_all(project_id: p.id)   # all legacy keys → Default
end

# 4. Enforce + swap (separate migration, after code deploys — §11 Phase 4).
change_column_null :monitors, :project_id, false
change_column_null :api_keys, :project_id, false
remove_index :monitors, name: "index_monitors_on_user_and_registration_key"
add_index :monitors, [ :project_id, :registration_key ], unique: true,
          where: "registration_key IS NOT NULL",
          name: "index_monitors_on_project_and_registration_key"
remove_column :monitors, :user_id
remove_column :api_keys, :user_id
```

> `default` is a reserved-ish word; the partial-index predicate quotes it
> (`WHERE "default"`). Consider naming the column `is_default` to avoid the
> friction (§12-C).

---

## 4 · Domain design (architecture-compliant)

Target tree (CLAUDE.md decision table: a grouping noun is a model; complex
operations are entity-scoped operation objects; no `app/services/`):

```
app/models/
  project.rb                     # the entity: name, slug, associations
  project/
    monitor_sync.rb              # operation: bulk upsert (MOVED from user/)
    default_provisioning.rb      # operation: create a user's first project
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

  before_validation :set_slug, on: :create
  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :user_id }

  def sync_monitors(entries:) = MonitorSync.new(self).call(entries:)
  # …rename/default helpers…
end
```

- `dependent: :destroy` on `:monitors` reuses the monitor's existing cascade
  (`monitor.rb:32-35` already destroys ping_events/incidents/notifications/
  uptime_day_stats). So `project.destroy` → monitors → their children. And
  `user.destroy` → projects → monitors → children — which also cleanly serves the
  **account-deletion** blocker (see the launch work).
- `slug` set once (`set_slug`), immutable after create — it is the gem/status-page
  identity.

### 4.2 `Monitoring::Monitor` (changes)

- `belongs_to :project` replaces `belongs_to :user`. Add `delegate :user, to:
  :project` so `monitor.user` (used by `within_monitor_cap`, mailers, broadcasts)
  keeps working unchanged.
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

### 4.4 `Project::DefaultProvisioning` + signup

Every user must always have a project (A3). Provision the default in the same
transaction as user creation. Options (§12-D): a `User after_create` callback
(smallest, "sparingly" per conventions) vs. threading it through the registration
path. Either way the backfill (§3.5 step 3) provisions it for existing users.

### 4.5 `User` (changes)

```ruby
has_many :projects, dependent: :destroy
has_many :monitors, through: :projects, source: :monitors   # cross-project reads
has_many :api_keys, through: :projects
```

`has_many :through` keeps every existing **read** call site working unchanged:
`current_user.monitors.order(:created_at)` (`monitors_controller.rb:5`),
`user.monitors.counting_toward_cap.count` (`plan.rb:61`),
`@user.monitors.where(id:)` (`downgrade.rb`). The one thing a `through` association
**cannot** do is `.new`/`.build` — so the two **creation** sites move to project
scope (§4.2, §5); everything else is transparent.

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

- **Nav** (`layouts/application.html.erb:21-32`): add a **Projects** entry (or make
  the existing "Monitors" a project-aware view). Section-active logic already keys
  on `controller_path`.
- **Dashboard** (`monitors/index.html.erb`): group the monitor rows **by project**
  (headed sections), reusing `monitors/_row.html.erb` unchanged. Keep the existing
  active/suspended split within each project group. The cap display (`count /
  current_user.monitor_limit`, `index.html.erb:8-9`) stays **user-level** (§7) — the
  count sums across projects.
- **Project CRUD** — standard REST (`resources :projects`):
  `ProjectsController#index/show/new/create/edit/update/destroy`. `show` is the
  per-project monitor list + its API keys.
  - **Rename** updates `name` only; `slug` stays (status-page/gem identity).
  - **Delete** cascades the project's monitors (confirmation required — it destroys
    monitoring history). **Blocked** if it is the user's only project (A3) or the
    `default` project unless another is promoted (§12-C).
- **Create a monitor** (`monitors_controller.rb:24-37`): the form gains a
  **project selector** (pre-selected to the `default`/last-used project). Create via
  `@project.monitors.new(...)` — the `params.permit` list adds `:project_id` (scoped
  to `current_user.projects` to prevent cross-tenant assignment). A per-project
  "New monitor" button pre-fills the project.
- **Move a monitor between projects** — a sub-resource, not a custom verb (CLAUDE.md
  rule 4): `resource :project, only: :update, module: :monitors` →
  `Monitors::ProjectsController#update` → `Monitoring::Monitor::Transfer`. Edge: if
  the target project already has a monitor with the same `registration_key`, the new
  index rejects it — surface a clear error rather than a 500 (§ edge cases). Moving a
  **gem-synced** monitor out of the project its key syncs into means the next sync
  re-creates it in the key's project — so moving is meaningful mainly for **manual**
  monitors; document it.
- **API keys** move under the project (Design B): a project's `show` page lists its
  masked keys + "Generate key" (reusing the shown-once modal). The old
  `settings/api_keys` page (`api_keys_controller.rb`) either becomes a
  grouped-by-project view or is replaced by per-project management (§12-E).

Every user-facing flow above ships a **browser-driven system test** (CLAUDE.md;
§10).

---

## 7 · Caps, billing & downgrade interactions

The cap stays **per-user, across all projects** (A1). Plan is a `users` column
(`schema.rb:214`); `User#monitor_limit/at_monitor_cap?/remaining_monitor_slots/
over_free_cap_by` (`plan.rb:26-56`) all count `user.monitors.counting_toward_cap`
— which, via the new `has_many :through`, now transparently sums across the user's
projects. **No cap logic changes**; only the association path underneath it does.

- `within_monitor_cap` (`monitor.rb:102-107`) now reads `project.user.at_monitor_cap?`.
- **Sync budgeting**: `Project::MonitorSync` reads `project.user.remaining_monitor_slots`
  and locks the **user** row (§4.3) so two apps of one user syncing concurrently
  can't both consume the last slot. Edge: if app A's monitors already fill the
  user's cap, app B's new monitors come back `skipped: limit_reached` — correct
  per-user behaviour; document it so it isn't mistaken for a bug.
- **Downgrade "choose your 5"** (`user/downgrade.rb`): the keep-count is still
  `FREE_PLAN_MONITOR_LIMIT` and `active_scope` is `@user.monitors.counting_toward_cap`
  (`downgrade.rb:79-80`) — now spanning projects. The **choose-5 picker UI must group
  candidates by project** so the user can reason about what they're keeping.
  Suspended monitors stay in their own project. `resolve_choice!`/`enforce_free_cap!`
  operate on monitor instances and need no logic change.
- **Subscription** (`user/subscription.rb`): `restore_suspended_monitors!` reactivates
  `user.monitors.where(status: "suspended")` up to remaining slots — works unchanged
  across projects.

Per-project caps (e.g. as a paid lever) are explicitly **out of scope** (§12-F).

---

## 8 · Migration & backfill

The risky part; phased to keep `bin/ci` green at every step (§11).

1. **Provision Default projects** (one per user, `default: true`, slug `"default"`).
2. **Assign all legacy monitors** to their user's Default (`update_all`). Lossless:
   the old `(user_id, registration_key)` uniqueness guaranteed no dup keys within a
   user, so `(project_id=Default, registration_key)` is still unique — the new index
   builds cleanly.
3. **Assign all legacy API keys** to the Default project (Design B). Existing
   single-app installs are seamless: the key is scoped to Default, and all their
   monitors are in Default, so sync keeps matching and GET keeps returning the same
   set — **no re-home, no duplicates**.
4. **Enforce** `NOT NULL` + swap the unique index + drop `monitors.user_id` /
   `api_keys.user_id` — only *after* the code that reads `project_id` is deployed
   (§11 Phase 4).

### Transition edge cases

- **The already-collided multi-app user.** Someone syncing two apps into one account
  today has *already* lost data to the collision (one merged monitor per key). The
  backfill preserves that current state (all in Default). To separate them going
  forward they create a second project + key and point app B at it; app B's next
  sync creates fresh, correctly-namespaced monitors. We cannot retroactively
  un-merge history (A4) — document this in the release notes.
- **Legacy key + two apps still sharing it.** Under B a shared key ⇒ shared project
  ⇒ the collision persists *within that project*. This is now a visible
  misconfiguration ("two apps, one project key") rather than a silent cross-app
  hijack, and the fix is obvious (one key per app). Call it out in docs.
- **Empty-name / `"app"`-fallback apps.** Irrelevant under B (identity is the key,
  not the string). Under A they'd all collapse to one project — another mark against A.
- **Signup during rollout.** New users created between Phase 1 and Phase 2 must get a
  Default project too — wire `Project::DefaultProvisioning` in the same deploy as the
  backfill (§4.4).

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
  the key. Optionally add `"project": {slug, name}` to `monitor_json`
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
exist): `test/fixtures/projects.yml` (a Default per fixture user, e.g.
`alices_default`, `bobs_default`); update `monitors.yml` to reference
`project: alices_default` instead of `user: alice` (fixtures insert via raw SQL —
set `project_id`, and after the swap there is no `user_id` to set). API keys stay
minted in-test, now via `ApiKey.issue(project:, name:)`.

- **[model] Project** — slug generation/immutability, `(user_id, slug)` uniqueness,
  one-default-per-user, `dependent: :destroy` cascade to monitors→children, cannot
  delete last project.
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
  - delete a project (confirmation; blocked on the last one);
  - regression: the existing S3/S4/S5/S7/S8/S17/S18 monitor flows
    (`system/monitors_test.rb`, `monitor_edit_delete_test.rb`) still pass with a
    Default project present.

---

## 11 · Rollout / phasing

Each phase is independently deployable and keeps `bin/ci` (incl. `test:system`)
green.

1. **Schema + backfill (additive).** Create `projects`; add nullable
   `monitors.project_id` + `api_keys.project_id`; backfill Default projects and
   repoint; wire `Project::DefaultProvisioning` for new signups. `user_id` still
   present and authoritative. No behaviour change yet.
2. **Domain + API cutover.** `Project` model + associations; `User has_many :through`;
   `Project::MonitorSync` (moved); `Monitor belongs_to :project` with
   `delegate :user`; API base controller resolves key→project; creation sites move to
   project scope. Reads still identical to users.
3. **UI.** Projects nav, grouped dashboard, project CRUD, monitor-create project
   selector, move-monitor sub-resource, per-project API-key management. System tests
   per flow.
4. **Enforce + drop.** `NOT NULL` on `project_id`; swap the unique index to
   `(project_id, registration_key)`; drop `monitors.user_id` + `api_keys.user_id`.
   Update `README.md` #6 and the data-model block (§3.3).
5. **Gem (optional, back-compat).** Doc "one key per project"; optionally stop
   sending the ignored `app`; version bump. No forced upgrade.

---

## 12 · Open decisions — need your call

- **A · Identity/auth model — Design B (project-scoped keys) vs A (user-scoped keys +
  synced project name).** **Recommendation: B.** It scopes both the write and the
  *read* path with zero gem change, is fully backward-compatible, and avoids the
  migration re-home/duplicate problem; A needs gem protocol changes on both paths and
  a stable `config.project`. The only thing B gives up is an *account-wide* API key
  (a key sees one project) — acceptable given A2, and addable later as a distinct key
  type. **DECIDED: —** (awaiting your sign-off.)
- **B · Drop `monitors.user_id`, or keep it denormalised?** Recommendation: **drop
  it** (single source of truth: `monitor → project → user`; `has_many :through`
  covers every read; `delegate :user` covers `monitor.user`). Keeping a denormalised
  `user_id` avoids a JOIN on the hot cap-count and de-risks the migration, at the cost
  of a consistency invariant (`monitor.user_id == project.user_id`) you must enforce.
  Pick drop for correctness, keep for a smaller/safer diff.
- **C · The `default` project + its column.** Include a `default` (or `is_default`,
  to dodge the reserved word) boolean with one-per-user, used for signup, legacy-key
  scoping, and manual-create pre-selection? Recommendation: **yes, `is_default`** —
  it simplifies three things and gives the delete-guard a clean predicate. Deleting
  the default must promote another (or be blocked).
- **D · Where to provision the signup default** — `User after_create` callback
  (smallest) vs. the registration path/coordinator. Recommendation: **callback**,
  noted as a justified use of the "sparingly" allowance.
- **E · API-key management location** — per-project (under `projects/:id`) vs. a
  global keys page grouped by project. Recommendation: **per-project** (matches "a key
  is for one app"); keep a redirect from the old `settings/api_keys`.
- **F · Per-project caps.** Out of scope for V1 (cap stays per-user). Confirm you
  don't want a per-project limit now.
- **G · Per-project alert routing.** Out of scope for V1 (alerts go to the owner).
  Confirm.
- **H · `Project` namespacing.** Top-level `Project` (no stdlib collision; it's an
  account-level entity that also owns API keys) vs. `Monitoring::Project` (groups with
  `Monitoring::Monitor`). Recommendation: **top-level `Project`**.
