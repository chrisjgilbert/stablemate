# Stablemate — Developer Handoff

**Dead simple cron monitoring for Rails applications.** One promise: *a scheduled job stops
running, we email you.* Built around **[Solid Queue](https://github.com/rails/solid_queue)** recurring
jobs and a companion **gem** that auto-registers them.

This package hands off the V1 screen set (with key states) plus a small reusable component system,
ready to implement in a **server-rendered Rails app** using **Hotwire (Turbo + Stimulus)** and
**Tailwind CSS**.

> Renamed from "Checkmate" → **Stablemate** (domain `stablemate.dev`). Public/shareable status pages
> and the incident "Acknowledge" action were **cut from V1** (status pages deferred to V2 with HTTP
> uptime monitoring).

---

## 0 · Read this first

- The files in `design/` are **HTML design references** — prototypes that show the intended look and
  behavior. They are authored in a small browser-only component runtime (`*.dc.html` + `support.js`)
  **purely so they render in a browser**. They are **not production code to copy**.
- **Your job:** recreate these designs in the real codebase as ERB partials / ViewComponents +
  Tailwind utilities, following the host app's conventions. Do **not** port the runtime or the
  inline-style approach.
- **Fidelity: high.** Colors, type, spacing, radii, and interactions below are final. Match them.
- To preview: open `design/Stablemate.dc.html` in a browser. It's a pannable canvas holding every
  screen and state, each labelled (`data-screen-label`). `design/screenshots/` has flat PNGs.

### Files in this package
| Path | What it is |
|---|---|
| `README.md` | This document — design spec |
| `SOLID_QUEUE_INTEGRATION.md` | How the heartbeat ties into Solid Queue + the gem, with code |
| `design/Stablemate.dc.html` | All V1 screens + states (dashboard, detail, auth, API keys, new-monitor, dark) |
| `design/Stablemate Landing.dc.html` | Marketing landing page (matches the app system) |
| `design/Stablemate Logos.dc.html` | The 4 explored logo directions ("Keystone" chosen) |
| `design/UptimeBar.dc.html` | The 90-day uptime bar reference component |
| `design/screenshots/` | Flat PNGs of the canvas + key screens |

---

## 1 · What Stablemate does (product model)

A monitor is a **heartbeat**: a scheduled job sends a ping to a unique URL every time it runs. If no
ping arrives within the **expected interval + grace period**, the monitor flips to **down** and the
owner is emailed. Uptime history (90-day bar + recent events) lives **inside the authenticated app**.

There are **two ways monitors get created**, and the UI distinguishes them:
1. **Gem-managed (recommended):** the companion gem reads `config/recurring.yml` and auto-registers a
   monitor per recurring task — *zero per-job code*. These rows/headers carry a quiet **`gem` chip**.
2. **Manual:** the user creates a monitor by hand and pastes its ping URL into a job (curl / Net::HTTP).
   No chip.

The differentiator is path #1 — "the gem feels like magic that already happened." See
`SOLID_QUEUE_INTEGRATION.md` for the wiring; it's the spine of the product, not an afterthought.

### Suggested domain model
- `Monitor` — `name` (slug, mono), `status` (enum: `up`/`down`/`paused`/`pending`), `expected_interval`
  (seconds), `grace_period` (seconds), `ping_token` (UUID, rotatable), `last_pinged_at`,
  `source` (enum: `gem`/`manual`), `solid_queue_task_key` (nullable — links to a `recurring.yml` key).
- `Ping` (check-in) — `monitor_id`, `received_at`, `duration_ms`, `source_ip`.
- `Incident` — `monitor_id`, `started_at`, `resolved_at` (nullable). **Two states only: open / resolved.**
- `ApiKey` — `name`, `token_digest`, `last4`, `created_at`, `last_used_at`. Show full token **once**.
- Derive the 90-day bar and "last 16 checks" from `Ping`/`Incident` aggregates (one bucket per day;
  any down-window = red, partial = amber).

---

## 2 · Screens & states to build

All live in `design/Stablemate.dc.html`, each frame labelled.

### A. Monitors dashboard (`GET /monitors`) — logged-in home
- Top bar: Keystone logo + "Stablemate" wordmark, primary **New monitor** button, account avatar.
- Heading row: "Monitors" + count summary (`8 monitors · 1 down · 5 up · 1 paused · 1 pending`),
  search, status filter.
- Table, one row per monitor: status dot + **mono** name (+ quiet **`gem` chip** when gem-managed,
  tooltip "Registered from config/recurring.yml") · status **badge** · last-ping ("12 sec ago") ·
  interval (mono, "every 5m") · **last-16-checks** tick strip + uptime % · chevron.
- **Empty state** (new user): centered card — icon, "Monitor your first cron job", help line,
  **New monitor** + **Read the docs** buttons, and a **gem-first** path: a "Recommended — install the
  gem" label over a dark `config/recurring.yml` snippet + an "Install the gem →" affordance. Render as
  the table partial's empty branch.
- **Dark mode** variant shown (Tailwind `dark:` class strategy).

### B. Monitor detail (`GET /monitors/:id`)
- Breadcrumb (Monitors / mono name) in the top bar.
- Header: **mono** monitor name + status badge; gem-managed monitors also show a **"synced from gem"**
  chip. "last ping… next expected in…" line.
- **Ping URL card** — large copyable `https://stablemate.dev/ping/<token>` in a mono field, **Copy**
  button, `curl` snippet. Rotate-token action lives here.
- Settings (inline-editable): **expected interval**, **grace period**, **pause/resume** toggle.
  *(The public-status-page toggle was removed in V1.)*
- Uptime panel: 90-day bar + overall %, then a "recent pings/events" list (mono timestamps + durations).
- **Active-incident state:** red banner at top ("Monitor is down — no ping received", expected-by time,
  grace elapsed, "down for 2h 04m" — **no Acknowledge button**; open/resolved only), header badge =
  Down (pulsing dot) + "synced from gem" chip, uptime bar shows recent red days, events list leads with
  the down event.

### C. Auth — Sign up & Sign in (`GET /sign_up`, `GET /sign_in`)
- Minimal centered card on `#fbfbfc`: Keystone logo + wordmark, email + password, primary submit.
- Two near-identical screens cross-linked ("Already have an account? Sign in" / "New to Stablemate?…").
  Sign-in adds a "Forgot?" link by the password label. Boring and fast.

### D. API keys (`GET /settings/api_keys`) — the gem's front door
- Settings breadcrumb. Heading "API keys" + explainer ("the gem authenticates with these…") +
  **Generate key** button.
- Table: **Name** · **Key** (mono, masked `sm_live_••••a14c`) · **Created** · **Last used** · **Revoke**.
- **Generate-key result modal:** shows the **full key once** (`sm_live_…`, mono, on a dark field) +
  **Copy** + an amber "you won't be able to see this key again" warning + **Done**.
- **Empty state:** key icon, "No API keys yet", explainer, **Generate your first key**.

### E. New monitor / Edit form (`GET /monitors/new`, `GET /monitors/:id/edit`)
- Behind the **New monitor** CTA and the detail-page **Edit** button.
- Fields: **name**, **expected interval**, **grace period** (mono inputs for the numeric/interval
  values), each with a one-line helper. A subtle note points gem users to `recurring.yml` instead.
  **Cancel** + **Create monitor**.
- **Post-create state:** a green "Monitor created" confirmation, then reveal the **ping URL card**
  (mono URL + Copy + curl) — mirrors the detail page — and a **Go to monitor** button.

---

## 3 · Design tokens

### Typography
- **Sans (UI):** `Geist` → Tailwind `font-sans`, weights 400/500/600/700.
- **Mono:** `Geist Mono` → `font-mono`, weights 400/500/600. Used for **monitor names, ping URLs,
  API keys, intervals, durations, and all timestamps** — always.
- Headings: tight tracking (`tracking-tight`, -0.01 to -0.02em).
- Load via Google Fonts or self-host `@font-face` (`tailwind.config` → extend `fontFamily`).

| Use | Spec |
|---|---|
| Page title "Monitors" | 19px / 700 / tracking-tight |
| Detail H1 (mono name) | 21px / 700 / font-mono |
| Big status headline | 18px / 700 |
| Table cell | 12.5–13px / 500–600 |
| Section eyebrow | 11px / 600 / uppercase / tracking-[.06em] |
| Badge label | 11–12px / 600 |
| Caption / meta | 11.5–13px / 400–500 |

### Color — neutrals (light)
| Token | Hex | Use |
|---|---|---|
| App background | `#fbfbfc` | page behind cards |
| Surface | `#ffffff` | cards, top bar, table |
| Surface subtle | `#fafafb` / `#f7f7f9` | table header, input fill |
| Border | `#ececf1` | card borders |
| Hairline | `#f1f1f4` / `#f4f4f6` | dividers |
| Ink | `#1a1a1e` | headings, names |
| Text secondary | `#26262c` / `#62626c` | body, values |
| Text muted | `#80808c` | descriptions |
| Text faint | `#a0a0ac` / `#9a9aa6` | eyebrows, meta |

### Color — brand (indigo)
| Token | Hex | Use |
|---|---|---|
| Brand | `#5b53eb` | primary buttons, links, active toggles, logo |
| Brand border | `#4b43d8` | primary button border |
| Brand hover | `#4f47e0` | primary button hover |
| Brand tint | `#f3f2fd` | soft surfaces, gem chip bg |
| Brand light | `#8b7cf0` | gradients, avatar, gem-chip glyph |
| Gem chip text | `#6b62d6` | the `gem` / "synced from gem" chip label |

### Color — status language (consistent EVERYWHERE)
| Status | Dot | Badge bg | Badge text | Meaning |
|---|---|---|---|---|
| **Up** | `#1aa34a` | `#e7f6ec` | `#177a3d` | pinged on schedule |
| **Down** | `#e5484d` | `#fdeaea` | `#c0282d` | missed window past grace |
| **Paused** | `#a3a3ae` | `#f1f1f4` | `#6b6b76` | monitoring suspended |
| **Pending** | `#e0a000` | `#fdf4e3` | `#a96a00` | created, no ping yet |

Uptime fills: up `#22c55e` (ticks `#3ec06a`) · partial-day `#f59e0b` · down `#ef4444`/`#e5484d` · no-data `#e4e4e7`.
Incident surfaces: bg `#fef4f4`, border `#f6d6d6`, heading `#a01e23`, body `#bf5a5d`.
Warning (key modal): bg `#fdf4e3`, border `#f5e3bf`, text `#8a6310`.

### Color — dark mode (dashboard variant shown)
App `#0e0e12` · surface `#141418` · subtle `#17171c`/`#1a1a20` · border `#26262e` · hairline `#1f1f26` ·
text `#f3f3f6`/`#e8e8ee` → `#d4d4dc` → muted `#7a7a86` → faint `#6a6a76`. Gem chip — bg `#241f33` /
text `#a99cf5`. Badges — up: bg `#13301f` / text `#4ade80`; down: bg `#3a1417` / text+dot `#ff6369`;
paused: bg `#23232b` / text `#9a9aa6`; pending: bg `#33260a` / text `#fbbf24`.
Implement with Tailwind's `dark:` class strategy.

### Radius, shadow, spacing
- Radius: cards `rounded-xl` (12), inner panels `rounded-[11px]`, buttons/inputs `rounded-lg` (8),
  badges/chips `rounded-md` (6) / `rounded-[5px]`, logo tile `rounded-[7px]`.
- Shadow: card `0 1px 3px rgba(20,20,40,.06)`; primary button `0 1px 2px rgba(30,24,90,.22)`;
  modal `0 20px 50px -16px rgba(20,20,40,.32)`.
- Spacing: 8px base. Card padding 22–26px. Row padding `13px 18px`. Badge h21–22, button h32
  (h36–38 on CTAs), input h34–38.

---

## 4 · Reusable component system

Build these as ViewComponents (or partials) so every screen shares them.

**`StatusBadge(status:)`** — inline-flex pill, h21–22, `rounded-md`, leading dot + 600/11px label,
colors per the status table. **The down dot pulses** (CSS keyframe: expanding box-shadow ring in
`rgba(229,72,77,.55)`, 1.8s infinite). Pure CSS, no Stimulus.

**`GemChip(variant:)`** — quiet indigo chip marking gem-managed monitors. Compact form on dashboard
rows (`gem`, mono 9.5px, diamond glyph); fuller form in the detail header (`synced from gem`). bg
`#f3f2fd` / text `#6b62d6` (dark: `#241f33` / `#a99cf5`). `title="Registered from config/recurring.yml"`.
Only render when `monitor.source == :gem`.

**`UptimeBar(days:)`** — flex row of up-to-90 bars, `items-end`, 2px gap, each `flex-1 h-full
rounded-[2px]`, container ~34px tall. Fill per day status (see fills above). Each bar gets a `title`
tooltip ("today", "12d ago"). Server-rendered from a 90-element array; no JS. See `design/UptimeBar.dc.html`.

**`MiniTicks(checks:)`** — 16 bars, 5×16px, 2px gap, `rounded-[1.5px]`; up `#3ec06a`, down `#e5484d`,
muted `#e4e4e9`; followed by an uptime %. Dashboard-row sparkline.

**Buttons** — primary (`bg-[#5b53eb] text-white border-[#4b43d8]` + shadow), secondary
(`bg-white border-[#e3e3e9]`), ghost (`text-[#5b53eb]`), danger (`text-[#c0282d] border-[#f3d4d4]`).
All `h-8 rounded-lg text-[13px] font-semibold`.

**Inputs / toggles** — input `h-[34px] rounded-lg border-[#e3e3e9]`, **mono** value text. Toggle =
`w-10 h-[23px] rounded-full`, on = `bg-[#5b53eb]` knob-right, off = `bg-[#e3e3e9]` knob-left. A
Stimulus controller flips the toggle and submits via Turbo.

**Copyable token field** — mono value in a `bg-[#f7f7f9]` (or dark `#1c1c22` for keys/curl) field +
a Copy button. Used for ping URLs, the curl snippet, and the generate-key modal.

**Logo ("Keystone" — chosen direction)** — a dark rounded-square tile (`bg-[#1c1c22] rounded-[7px]`)
holding an indigo **keystone** glyph (the wedge stone of an arch):
`<path d="M8.4 4h7.2l3.4 16H5z" fill="#5b53eb">` (optional lighter inner facet `#8b7cf0` for depth at
large sizes). Nav 26px tile / 14px glyph. Dark-mode nav tile stays `#1c1c22` or `#26262e` with the
glyph in `#8b7cf0`. Favicon = tile + glyph, scales cleanly to 16px. No animation. All four explored
options are in `design/Stablemate Logos.dc.html` (Keystone, Spirit level, Steady pulse, Monogram).

---

## 5 · Hotwire / implementation notes

- **No SPA.** Everything server-renders; use Turbo Frames/Streams for partial updates and Stimulus for
  the few interactions (copy-to-clipboard, toggle submit, filter, modal).
- **Live status** (dashboard rows, detail header) is a great fit for **Turbo Streams over Solid Cable** —
  broadcast a row/badge replace when a ping lands or an incident opens/resolves. DOM stays the source of
  truth; no client polling.
- **Copy button**: a tiny Stimulus controller (`navigator.clipboard.writeText`) that swaps the label to
  "Copied" for ~1.6s. The reference shows the exact interaction.
- **Generate-key modal**: render server-side; the full token is shown **once** and never persisted in
  plaintext (store a digest + last4). Copy uses the same Stimulus controller.
- **Status filter / search**: form GET that re-renders the table partial; no JS framework.
- **Accessibility**: status is conveyed by dot **and** text label (never color alone). Hit targets ≥44px.
  Respect `prefers-reduced-motion` — gate the down-dot pulse behind it.
- **Responsive**: desktop-first; the table can collapse to stacked cards under ~720px.

See `SOLID_QUEUE_INTEGRATION.md` for the ping endpoint, recurring-task wiring, the gem's
auto-register/auto-pause hooks, and the API-key auth flow.
