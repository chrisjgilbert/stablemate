# Stablemate — Design Change Request (round 2)

Context for the designer. The first handoff (the "Checkmate" UI system) is strong
and we're keeping it as the visual foundation — Geist / Geist Mono, indigo-on-
neutral, the status-colour language, the component system (StatusBadge, UptimeBar,
MiniTicks), and the server-rendered Rails + Hotwire + Tailwind target are all
approved. This document lists what changed since those comps and what we need
back. Everything else stays as designed.

---

## 0 · Headline changes since the last handoff

1. **The product is renamed `Checkmate` → `Stablemate`** (domain `stablemate.dev`).
2. **Public/shareable status pages are cut from V1** (deferred to V2). Uptime
   history stays, but owner-only inside the authenticated app.
3. **Incident "Acknowledge" is cut from V1.**
4. **The companion gem is now the explicit hero** of the product story, and it
   needs UI it didn't have before (API keys + an "auto-registered" treatment).
5. **New screens needed:** auth (sign up / in), API keys, and the new-monitor /
   edit form.

Positioning to design against: **"dead simple cron monitoring for Rails
applications."** One promise — *a scheduled job stops running, we email you.*
Keep everything calm, minimal, and developer-native.

---

## 1 · Rename: Checkmate → Stablemate

- Wordmark everywhere becomes **Stablemate**.
- Domain in all URLs becomes **stablemate.dev** — e.g. ping URLs are now
  `https://stablemate.dev/ping/<token>`.
- **Logo:** the previous "Ping" mark (dark round tile + check-blue tick + radiating
  indigo rings) was chosen for a name meaning "checkmate." The name no longer
  implies a checkmark. Please **explore 3–4 fresh logo directions for "Stablemate"**
  — the name evokes *stability / steadiness / a reliable companion* (and faintly
  the "stable/mate" pairing). Keep the same indigo brand and the round-tile app-
  icon format so it drops into the existing nav, but the tick is no longer
  mandated. Show each as app tile + horizontal lockup + favicon, light and dark.
- Keep "Powered by Stablemate" wording reserved for V2 (see §3).

## 2 · Cut public status pages (V1)

- **Remove both public status-page screens** (`Public status (operational)` and
  `Public status (incident)`) from the V1 set. They return in V2 alongside HTTP
  uptime monitoring.
- The uptime data-viz you built (90-day UptimeBar, incident timeline, "All systems
  operational / Active incident" blocks) is **not wasted** — we want that same
  visual language *inside the authenticated monitor detail page*. Specifically:
  - The 90-day uptime bar + overall % stays on the detail page (already there).
  - The "recent pings / events" list stays (already there).
- **Remove from the monitor detail settings panel:** the **"Public status page"
  toggle**. There is no public page in V1, so the toggle has nothing to control.
- Net: the detail page loses one toggle; nothing else about it changes.

## 3 · Cut incident "Acknowledge" (V1)

- On the **monitor detail incident banner**, remove the **Acknowledge** button.
  An incident has two states only: open (down) and resolved (recovered) — no
  acknowledged state. The banner keeps the diagnostic line we loved
  ("Expected by … · grace … elapsed · down for 2h 04m") and the status badge;
  just drop the action button.
- No `acknowledged_at` concept anywhere in the UI.

## 4 · Fix the onboarding snippet (important — positioning bug)

The empty-state dashboard currently shows a **`whenever`-gem** snippet:

```
# add to config/schedule.rb
every 1.hour do
  rake "digest:send"
end
```

That's the wrong ecosystem. Stablemate is for **Solid Queue** developers and the
gem reads **`config/recurring.yml`**. Please replace the empty-state code block
with the Solid Queue idiom, roughly:

```yaml
# config/recurring.yml
daily_digest:
  class: DailyDigestJob
  schedule: every day at 9am
```

…and a one-line caption that reinforces the magic: *"Add the gem and your
recurring jobs register themselves — no per-job code."* The two CTAs
(**New monitor**, **Read the docs**) stay.

## 5 · New screens to design

Same system, same tokens. Desktop-first, with the existing light/dark treatment.

### 5a. Auth — Sign up & Sign in
- Minimal centered-card auth, Stablemate logo, email + password.
- Sign up and sign in as two near-identical screens (link between them).
- Keep it boring and fast; this is not a moment to be clever.

### 5b. API keys (this is the gem's front door)
- A settings screen listing the user's API keys: **name**, **last-4** (mono),
  **created**, **last used**, and a **Revoke** action.
- A **"Generate key"** flow whose result modal shows the **full key once**
  (`sm_live_…`, mono, with a Copy button) and a clear "you won't see this again"
  note.
- Empty state: a short explainer + "Generate your first key", since this is where
  a gem user starts.

### 5c. New monitor / Edit monitor form
- The form behind the **New monitor** CTA and the detail-page **Edit** button.
- Fields: **name**, **expected interval**, **grace period**. Mono inputs for the
  numeric/interval values, consistent with the detail settings panel.
- On create, land on (or reveal) the **ping URL + curl snippet** so the user can
  wire it up immediately — mirror the detail page's Ping URL card.

## 6 · The gem story in the UI (the differentiator)

Right now every designed flow is the *manual* "copy this ping URL into a curl"
path. That's the commodity story. Our differentiation is **zero-config auto-
registration via the companion gem**, and the UI should show it. Please add:

- **A "synced from gem" treatment on auto-registered monitors.** On the dashboard
  row and/or detail header, a small, quiet badge/affordance — e.g. a `gem` or
  `auto` chip with a tooltip "Registered from config/recurring.yml" — so users can
  tell at a glance which monitors are managed by the gem vs. created by hand.
  Manual monitors show nothing extra.
- **A gem path in the dashboard empty state.** Alongside the manual `recurring.yml`
  snippet from §4, make it clear the recommended path is *install the gem → jobs
  appear automatically*. A second small "Install the gem" affordance pointing at
  docs is enough; don't over-build it.
- Keep it subtle — "dead simple" means the gem feels like magic that already
  happened, not a wizard with steps.

---

## 7 · Summary of the V1 screen set after this round

| Screen | Status |
|---|---|
| Dashboard (happy / empty / dark) | Keep; empty state snippet fixed (§4); gem affordances added (§6) |
| Monitor detail (healthy / incident) | Keep; drop Public-status toggle (§2) + Acknowledge button (§3); add "synced from gem" treatment (§6) |
| Sign up / Sign in | **New** (§5a) |
| API keys + generate-key modal | **New** (§5b) |
| New monitor / Edit form | **New** (§5c) |
| Public status (operational / incident) | **Removed from V1** → V2 |
| Logo set | **Re-explore for "Stablemate"** (§1) |

Unchanged and still approved: the design tokens, the StatusBadge / UptimeBar /
MiniTicks components, the status-colour language, dark-mode tokens, and the
Hotwire/Tailwind implementation notes from the original handoff.

---

# Round 3 addendum — Free plan, monitor cap, launch waitlist

Your round-2 set is accepted as-is; everything above stands. This addendum covers
three small additions from a pricing/launch decision. They affect **two existing
screens** (sign-up, new-monitor) — no new screens.

## R3.1 · One fix to the sign-up screen (required)
The sign-up subtitle currently reads **"Three monitors free, forever."** That
implied a plan we hadn't decided. We've now decided: **V1 is a single Free plan
capped at 5 monitors per user, no payment.** Please update the subtitle to reflect
**5** (e.g. *"Free — up to 5 monitors"* or *"5 monitors free while in beta"*).
Keep it to one quiet line; no pricing table, no tiers — there is only one plan.

## R3.2 · New state: sign-up at capacity → waitlist
At launch we cap total sign-ups (cost protection). When the cap is hit, the
**sign-up screen becomes a waitlist**:
- Same centered-card layout and logo as the normal sign-up.
- Headline like *"We're at capacity right now"*; one line explaining we're letting
  people in gradually.
- **Email field + "Join the waitlist"** button (no password field — no account is
  created).
- Success state: a calm *"You're on the list — we'll email you an invite."*
- This is a *mode* of the sign-up screen, not a separate destination.

## R3.3 · New state: monitor limit reached
A Free user who already has 5 monitors can't create a 6th. Please design the
**at-limit treatment**:
- The **New monitor** action shows an at-limit state — e.g. the button is disabled
  (or still clickable but) with an inline note: *"You're at the 5-monitor limit
  for the Free plan."*
- Keep the tone matter-of-fact and forward-looking (a paid tier is coming, but
  **do not** design upgrade/pricing UI now — there's nothing to link to yet).
- If easy, show the count somewhere unobtrusive on the dashboard (e.g. "4 / 5
  monitors") so the limit isn't a surprise.

## R3 screen impact
| Screen | Change |
|---|---|
| Sign up | Fix subtitle to "5" (R3.1); add at-capacity **waitlist** mode (R3.2) |
| New monitor / dashboard | Add **at-limit** state + optional "n / 5" count (R3.3) |

Still **not** wanted in V1: pricing tables, plan-comparison UI, checkout, or any
"upgrade" flow. One Free plan, one cap, one waitlist gate — nothing more.

---

# Round 3 addendum (cont.) — new-monitor interval presets

One small UX request for the **new-monitor / edit form** (R2 §5c), borrowed from
Dead Man's Snitch: don't make people type raw seconds. Offer **human-friendly
interval presets** — e.g. a segmented control or select with *Every 5 min /
Hourly / Daily / Weekly* and a "Custom…" escape hatch for an arbitrary value.
Same for the grace period (sensible presets + custom). Keep the mono styling for
the resulting value. Gem-managed monitors derive their interval from
`recurring.yml` automatically, so this is specifically to make **manual** monitor
creation feel dead simple. Low priority, but it's a cheap, on-brand polish.
