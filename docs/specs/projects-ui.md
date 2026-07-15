# Projects — UI spec (Phase 4 build guide)

Companion to [`projects.md`](projects.md) §6. This is the **per-screen build guide** for
the Projects UI, grounded in the **existing** authenticated design system
(`app/assets/tailwind/application.css` `@theme` tokens + the shipped partials). It adds
**no new visual language** — every screen extends patterns already in `app/views`. Each
user-facing flow ships a browser-driven system test (CLAUDE.md); `data-testid` hooks are
named per screen.

Utilitarian treatment on purpose: this is a spec for building, not a mockup.

---

## 0 · Design-system quick-reference (reuse, don't reinvent)

**Tokens** (`@theme`): grounds `bg-app #F1ECDF` / `bg-surface #FBF8F1` /
`bg-surface-subtle` / `border-hairline` / `border-border`; ink `text-ink #211E1A` /
`text-secondary` / `text-muted` / `text-faint`; accent `bg-brand #C5361F` /
`hover:bg-brand-hover` / `bg-brand-tint`; status pairs `up|down|paused|pending-*`
(dot/bg/text) — **`suspended` reuses the `paused-*` muted treatment**.

**Type**: `font-display` (Zilla Slab) for headings, `font-mono` (IBM Plex Mono) for
labels/counts/metadata, `font-sans` for prose.

**Existing partials to reuse verbatim**: `monitors/_row`, `shared/status_badge`,
`shared/gem_chip`, `shared/mini_ticks`, `monitors/next_check`, and the shown-once
API-key modal from `settings/api_keys`.

**Reusable patterns** (copy the classes):
- Page header — `flex items-center justify-between mb-6`; `h1.font-display.text-xl.font-bold.tracking-tight`; a `font-mono text-[13px] text-muted` count beside it.
- Primary action — `inline-flex items-center h-8 px-3 rounded-lg bg-brand text-white text-[13px] font-semibold hover:bg-brand-hover`.
- Disabled/at-limit chip — `... bg-hairline text-muted cursor-not-allowed` with a `title`.
- Monitor row — `relative flex items-center justify-between px-[18px] py-[13px] hover:bg-surface-subtle` inside a `bg-surface` bordered card.

**Hotwire order** (CLAUDE.md): server-rendered ERB → Turbo Frames → Turbo Streams →
a *small* Stimulus controller only for genuinely client-side bits (the two below).

---

## 1 · Information architecture

Nav (`layouts/application.html.erb`): **Monitors · Projects · Billing · Sign out**. The
old "API keys" item is **removed** — keys now live inside each project. "Monitors" is the
grouped dashboard (default landing); "Projects" is management + keys.

---

## 2 · Monitors dashboard — grouped by project *(default authed screen)*

Purpose: scan every monitor across every app at a glance, grouped by project.

- **Header**: "Monitors" + user-level count `N / limit` (`data-testid=monitor-count`,
  unchanged from today) + "New monitor" primary button (or the at-limit chip).
- **Body**: one **project group** per project (`data-testid=project-group`), each with:
  - a group header — project name as a link to its show page
    (`font-display text-[15px] font-bold`, `data-testid=project-name`), a `font-mono
    text-[12px] text-muted` per-project count, and a small per-project "New monitor →".
  - the project's monitor rows via `render "monitors/row"` (unchanged), active first;
    a collapsed **"Suspended (n)"** subsection reusing the existing suspended treatment.
  - a **cap-skip banner** (§8) if that project has monitors waiting at the cap.
- **States**: zero projects → the first-run screen (§3); a project with zero monitors →
  an inline "No monitors yet — connect the gem or add one" hint inside the group.
- **Live status**: unchanged — each row still `turbo_stream_from monitor`; grouping is
  server-rendered, so broadcasts replace a single row in place regardless of group.

## 3 · First-run / zero-project empty state *(replaces the monitor-centric one)*

Purpose: a brand-new user has no projects; route them to create one before anything else.

- Centered `bg-surface` card (`data-testid=zero-projects-empty`): a one-line "A **project**
  is one app you're monitoring" explainer, an inline **name field + "Create project"**
  (`data-testid=create-first-project`), then a two-step hint: "① create a project ②
  copy its API key into your app — your recurring jobs register themselves."
- **Rewrite the gem-connect copy**: today's `monitors/_empty_state` promises "your jobs
  register themselves — no setup." Under project-scoped keys that's only true *after* a
  project + key exist, so the copy becomes "create a project, copy its key, then your
  jobs register themselves." (§13-S6.)

## 4 · Projects index *(management)*

- **Header**: "Projects" + "New project" primary button.
- **List**: each project a `bg-surface` row — name (link to show), `font-mono
  text-[12px] text-muted` monitor + key counts, created-ago. `data-testid=project-row`.
- Empty → same first-run card as §3.

## 5 · Project show *(monitors + keys for one project)*

- **Header**: project name (`font-display text-xl`), a `⋯`/inline **Rename** and
  **Delete** (§7), and a project-scoped "New monitor".
- **Monitors section**: the project's rows (reuse `_row`), active/suspended.
- **API keys section** (`data-testid=project-keys`): masked key list (name · `sm_live_…4`
  · last-used) with **Revoke**, and a **"Generate key"** button opening the existing
  shown-once modal — now issuing via `ApiKey.issue(project:)`. Copy: "This key syncs
  this app's jobs into **{project}**. One key per app."

## 6 · Project form (new / edit)

- Single `name` field, `Create` / `Save`. Rename changes the display name only.
  Validation: name required, unique per user → inline error "You already have a project
  called that." `data-testid=project-form`.

## 7 · Project delete *(strong confirmation — a genuine Stimulus case)*

- Irreversible cascade (monitors + all ping/uptime history + keys), so a **type-the-name**
  confirm, not a bare dialog. A small Stimulus controller (`confirm-phrase`) keeps the
  destructive button **disabled until the typed value === the project name**.
- Copy states the blast radius: "This deletes **{project}**, its **{n} monitors**, all
  their history, and **{k} API keys**. This cannot be undone." `data-testid=delete-project`
  / `delete-confirm-input`. A user may delete their last project → lands on §3.

## 8 · Cap-skip banner *(the signal that must live in the UI, not the gem log)*

- When a project has monitors the sync returned as `limit_reached`, show a `bg-brand-tint`
  banner in that group / on the project show: "**{n} monitors from this project are
  waiting** — your account is at its {limit}-monitor limit. **Upgrade to Pro** for 100."
  Link → `billing_subscription_path`. `data-testid=cap-skip-banner`. (§13-S5.)

## 9 · Monitor create — project selector

- The existing new-monitor form gains a **Project** `<select>` (`data-testid=
  monitor-project-select`), pre-selected to the user's most-recent project. `params.permit`
  adds `:project_id`, scoped to `current_user.projects` server-side. Zero projects → the
  form redirects into §3 first, then returns.

## 10 · Move monitor *(manual-only)*

- On a **manual** monitor's show page, a "Move to project" `<select>` → the move
  sub-resource (`Monitors::ProjectsController#update`). `data-testid=move-monitor`.
- On a **gem** monitor, the control is **absent**, replaced by a muted note: "Synced by
  the gem — this monitor follows its API key's project. Re-point the app's key to move
  it." (§12-I.) A move that would collide on `(project_id, registration_key)` returns an
  inline error, never a 500.

## 11 · Downgrade grace banner + project-grouped picker

- **Banner** (app-wide chrome, shown while `awaiting_downgrade_choice`): a `bg-down-bg
  text-down-text` strip — "Your plan is now **Free** ({limit} monitors). You have **{n}**.
  **Choose which {limit} to keep by {deadline}** — nothing is suspended until then; after
  that we keep your oldest {limit}." CTA → the picker. `data-testid=downgrade-banner`.
  (Grace period per §7 / §12-J — the point is nothing goes dark mid-window.)
- **Picker** (`data-testid=downgrade-picker`): monitors **grouped by project** (so the
  user sees which app they'd lose), each with a keep checkbox (`data-testid=keep-checkbox`).
  A small Stimulus controller enforces **exactly {limit} selected** and enables submit
  only then, with a live "{k} / {limit} kept" counter. Submitting calls `resolve_choice!`.

---

## Testing (system layer, browser-driven)

One robust Capybara test per flow, asserting on what the user sees (the `data-testid`s
above), driving real Turbo/Stimulus: create-first-project (§3); dashboard groups by
project (§2); create a monitor into a chosen project (§9); move a manual monitor, and the
control is absent on a gem monitor (§10); generate a project-scoped key via the modal
(§5); delete a project behind the type-the-name gate, down to zero (§7); the cap-skip
banner appears when at the limit (§8); the downgrade banner + picker keep exactly {limit}
with nothing suspended during the window (§11). These compose with the existing
S3/S4/S5/S7/S8/S17/S18 monitor flows, which must stay green with a project present.
