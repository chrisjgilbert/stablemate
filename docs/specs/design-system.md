# Design System & UI Spec

Distilled from the Claude Design handoff
([`../design/design_handoff_stablemate/`](../design/design_handoff_stablemate/)) and
`docs/design-change-request.md`. **Fidelity is high — colours, type, spacing,
radii and interactions below are final.** The handoff's `*.dc.html` files (under `../design/`) are
browser-only references; recreate them as ERB partials / ViewComponents +
Tailwind, following Rails conventions. Do **not** port the runtime or inline
styles.

The chosen logo direction is **"Keystone"** (the wedge stone of an arch).

---

## 1 · Tokens → `tailwind.config`

### Fonts
- Sans (UI): **Geist** → `font-sans`, weights 400/500/600/700.
- Mono: **Geist Mono** → `font-mono`, weights 400/500/600. **Mono is used for:
  monitor names, ping URLs, API keys, intervals, durations, and all
  timestamps — always.**
- Headings: `tracking-tight` (-0.01 to -0.02em).
- Load via self-hosted `@font-face` (preferred for offline/Kamal) or Google Fonts.

### Colour — light neutrals
| Token | Hex |
|---|---|
| App background | `#fbfbfc` |
| Surface | `#ffffff` |
| Surface subtle | `#fafafb` / `#f7f7f9` |
| Border | `#ececf1` |
| Hairline | `#f1f1f4` / `#f4f4f6` |
| Ink (headings/names) | `#1a1a1e` |
| Text secondary | `#26262c` / `#62626c` |
| Text muted | `#80808c` |
| Text faint | `#a0a0ac` / `#9a9aa6` |

### Colour — brand (indigo)
| Token | Hex |
|---|---|
| Brand | `#5b53eb` |
| Brand border | `#4b43d8` |
| Brand hover | `#4f47e0` |
| Brand tint | `#f3f2fd` |
| Brand light | `#8b7cf0` |
| Gem chip text | `#6b62d6` |

### Colour — status language (consistent EVERYWHERE)
| Status | Dot | Badge bg | Badge text |
|---|---|---|---|
| Up | `#1aa34a` | `#e7f6ec` | `#177a3d` |
| Down | `#e5484d` | `#fdeaea` | `#c0282d` |
| Paused | `#a3a3ae` | `#f1f1f4` | `#6b6b76` |
| Pending | `#e0a000` | `#fdf4e3` | `#a96a00` |

Uptime fills: up `#22c55e` (ticks `#3ec06a`) · partial-day `#f59e0b` · down
`#ef4444`/`#e5484d` · no-data `#e4e4e7`.
Incident surfaces: bg `#fef4f4`, border `#f6d6d6`, heading `#a01e23`, body `#bf5a5d`.
Warning (key modal): bg `#fdf4e3`, border `#f5e3bf`, text `#8a6310`.

### Colour — dark mode (Tailwind `dark:` class strategy)
App `#0e0e12` · surface `#141418` · subtle `#17171c`/`#1a1a20` · border `#26262e`
· hairline `#1f1f26` · text `#f3f3f6`→`#d4d4dc`→muted `#7a7a86`→faint `#6a6a76`.
Gem chip: bg `#241f33` / text `#a99cf5`. Badges — up: `#13301f`/`#4ade80`; down:
`#3a1417`/`#ff6369`; paused: `#23232b`/`#9a9aa6`; pending: `#33260a`/`#fbbf24`.

### Radius / shadow / spacing
- Radius: cards `rounded-xl` (12), inner `rounded-[11px]`, buttons/inputs
  `rounded-lg` (8), badges/chips `rounded-md`/`rounded-[5px]`, logo tile
  `rounded-[7px]`.
- Shadow: card `0 1px 3px rgba(20,20,40,.06)`; primary button
  `0 1px 2px rgba(30,24,90,.22)`; modal `0 20px 50px -16px rgba(20,20,40,.32)`.
- Spacing: 8px base. Card padding 22–26px. Row padding `13px 18px`. Badge h21–22,
  button h32 (h36–38 CTAs), input h34–38.

---

## 2 · Reusable components (build as ViewComponents or partials)

These are shared across phases. Build them **once, in Phase 1** (the first phase
with real screens), with their own component tests, and reuse thereafter.

| Component | Spec | Test focus `[unit]`/`[system]` |
|---|---|---|
| `StatusBadge(status:)` | inline pill h21–22 `rounded-md`, leading dot + 600/11px label, colours per status table. **Down dot pulses** (CSS keyframe, expanding box-shadow ring `rgba(229,72,77,.55)` 1.8s). Pure CSS. | Renders correct colour/label per status; pulse class only on `down`; pulse gated behind `prefers-reduced-motion`. |
| `GemChip(variant:)` | quiet indigo chip. Compact (`gem`, mono 9.5px, diamond glyph) on rows; full (`synced from gem`) in detail header. `title="Registered from config/recurring.yml"`. **Renders only when `monitor.source == "gem"`.** | Present iff source gem; correct variant per context. |
| `UptimeBar(days:)` | flex row up to 90 bars, `items-end`, 2px gap, each `flex-1 h-full rounded-[2px]`, container ~34px. Fill per day status. Each bar a `title` tooltip ("today", "12d ago"). Server-rendered from a 90-element array; no JS. | Given a 90-element status array → 90 bars with correct fills + tooltips. |
| `MiniTicks(checks:)` | 16 bars, 5×16px, 2px gap `rounded-[1.5px]`; up `#3ec06a`, down `#e5484d`, muted `#e4e4e9`; trailed by uptime %. Dashboard sparkline. | 16 ticks, last-16 ordering, % matches input. |
| Buttons | primary / secondary / ghost / danger, all `h-8 rounded-lg text-[13px] font-semibold`. | — |
| Inputs / toggle | input `h-[34px] rounded-lg`, **mono** value text. Toggle `w-10 h-[23px] rounded-full`, on=`bg-[#5b53eb]` knob-right. Stimulus flips + submits via Turbo. | Toggle submits, optimistic flip. |
| Copyable token field | mono value in `bg-[#f7f7f9]` (dark `#1c1c22` for keys/curl) + Copy button (Stimulus `navigator.clipboard.writeText`, swaps label to "Copied" ~1.6s). | Copy controller writes clipboard + label swap. |
| Logo (Keystone) | dark tile `bg-[#1c1c22] rounded-[7px]` + indigo keystone glyph `<path d="M8.4 4h7.2l3.4 16H5z" fill="#5b53eb">`. Nav 26px tile / 14px glyph. Favicon scales to 16px. No animation. | — |

---

## 3 · Screen inventory (which phase builds each)

| Screen | Route | Phase | Key states |
|---|---|---|---|
| Sign up / Sign in | `GET /sign_up`, `/sign_in` | 1 | normal; sign-up **subtitle "Free — up to 5 monitors"**; sign-up **at-capacity → waitlist mode** (Phase 4) |
| Monitors dashboard | `GET /monitors` | 1 | happy (table); **empty state** (gem-first snippet + CTAs); dark; **"n / 5" count**; gem chip on rows |
| New / Edit monitor | `GET /monitors/new`, `/:id/edit` | 1 | form (name, interval, grace, **human presets + Custom**); **post-create ping-URL card + curl**; **at-limit state** (Phase 4 wires cap) |
| Monitor detail | `GET /monitors/:id` | 1 (history panel in 2) | healthy; **active-incident** (red banner, pulsing down dot, "down for 2h 04m", **no Acknowledge**); ping-URL card + rotate; inline settings (interval/grace/pause); **"synced from gem" chip**; **90-day uptime bar + recent events (Phase 2)** |
| API keys | `GET /settings/api_keys` | 3 | table (name/key masked/created/last-used/revoke); **generate-key modal (full key once + amber warning)**; empty state |
| Landing (marketing) | `GET /` | 4 (polish) | hero per `Stablemate Landing.dc.html` |

### Empty-state dashboard (Phase 1, important — positioning)
Centered card: icon, "Monitor your first cron job", help line, **New monitor** +
**Read the docs** buttons, **and a gem-first path**: a "Recommended — install the
gem" label over a dark `config/recurring.yml` snippet, plus an "Install the gem →"
affordance. The snippet is the **Solid Queue idiom** (not `whenever`):
```yaml
# config/recurring.yml
daily_digest:
  class: DailyDigestJob
  schedule: every day at 9am
```
Caption: *"Add the gem and your recurring jobs register themselves — no per-job code."*

### Things explicitly removed from V1 UI
- Public/shareable status-page screens (→ V2).
- The "Public status page" toggle on the detail settings panel.
- The incident **Acknowledge** button. Incidents are **open / resolved only**.
- No `acknowledged_at` anywhere.
- No pricing/tier/upgrade/checkout UI.

---

## 4 · Hotwire / a11y notes (apply across phases)
- No SPA. Server-render; Turbo Frames/Streams for partial updates, Stimulus for
  the few interactions (copy, toggle-submit, filter, modal).
- **Live status** (dashboard rows, detail header): Turbo Streams over Solid
  Cable — broadcast a row/badge replace when a ping lands or an incident
  opens/resolves. No client polling. *(Wire in Phase 1 for status; it composes
  with detection in Phase 1 and pings in Phase 0/1.)*
- Status conveyed by **dot AND text** (never colour alone). Hit targets ≥44px.
  Respect `prefers-reduced-motion` (gate the down-dot pulse).
- Desktop-first; table collapses to stacked cards under ~720px.
- A system test per screen asserts: renders, dark-mode class toggles, and the
  key interaction works.
