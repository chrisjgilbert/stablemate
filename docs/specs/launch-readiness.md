# SaaS launch readiness — the road to open sign-ups

Status: **PROPOSED** (pressure-test review pending). Author: Claude (session),
2026-08-01. Owner: @chrisjgilbert. Extends nothing in the data model; this is a
**launch punch list spec** — it enumerates what stands between today's `main`
and taking real customers on the managed instance, and specifies the shape of
each piece of work. No new product features. Follow the architecture rulebook in
[`../../CLAUDE.md`](../../CLAUDE.md).

> Scope note: "launch" here means the managed instance at `stablemate.dev`
> accepting open sign-ups and real Stripe payments. Self-hosting is already
> shipped and unaffected except where noted.

---

## 1 · Where we are

The product is done and healthy:

- **V1 + Projects + Billing are shipped.** Monitors, ping endpoint, 30s
  detection sweep, down/recovered email, 90-day uptime, projects with
  project-scoped API keys and gem sync, Stripe billing end-to-end (checkout,
  portal, webhooks, involuntary-downgrade grace + backstop job), pricing page.
- **Full `bin/ci` is green** as of 2026-08-01 on `main` (rubocop, brakeman,
  bundle-audit, unit/request suite, 57-run browser system suite, gem suite).
- **Production is already deployed** (Kamal → Hetzner behind Cloudflare,
  auto-deploy on every green push to `main` via the `deploy` job in
  `.github/workflows/ci.yml`) — but in **pre-launch posture**:
  `STABLEMATE_SIGNUP_ACCOUNT_CAP: 1` in `config/deploy.yml` keeps the waitlist
  on, and every page wears a "Coming soon" badge.

What's left is seven workstreams, four of them code:

| WS | What | Kind | Launch-blocking? |
|----|------|------|------------------|
| A | Billing dependency security upgrade (`pay` 8→11, `stripe` 13→19, drop the CI ignore) | code | **Yes** — before real money moves |
| B | Dependabot backlog (9 small bumps) | code | Should-do |
| C | Legal pages: Terms + Privacy | code + copy | **Yes** — paid product, EU users |
| D | Account deletion | code | **Yes** — GDPR-adjacent, cheap now, awkward later |
| E | Publish the companion gem to RubyGems | release ops | **Yes** — onboarding friction until done |
| F | Ops pre-launch checklist (runbook §0 + Stripe live config) | ops (owner) | **Yes** |
| G | Launch-day switch (badge removal + open the cap) | code + config | The launch itself |

---

## 2 · WS-A: billing dependency security upgrade

**Why.** `pay` is pinned at 8.3.0, which carries GHSA-mjgf-xj26-9qf9 (a
non-constant-time HMAC compare in Pay's *Paddle* webhook verifier). `bin/ci`
currently `--ignore`s it with a documented justification (we're Stripe-only, the
Paddle path never loads — see the comment block in `bin/ci`). The justification
is sound, but launch is the moment to stop carrying an ignored advisory on the
billing path. This is open **issue #39**. Dependabot has the two majors queued:
**PR #41** (`pay` → 11.6.2) and **PR #56** (`stripe` → 19.3.1).

**Plan.**

1. One branch, both gems together — Pay 11 requires a modern `stripe` gem, so
   the two majors are a single logical change. Either merge the dependabot PRs
   into the branch or bump by hand; close #41/#56 as superseded if by hand.
2. Read Pay's upgrade guides for 9.x, 10.x and 11.x before touching code, and
   re-verify **our entire Pay integration surface** against them:
   - `pay_customer` macro + `Pay.setup` config in `config/initializers/pay.rb`
     (including the `enabled_processors` config-gate and the `require_relative`
     load-order dance noted at `config/initializers/stablemate.rb:20`),
   - `payment_processor` / `set_payment_processor(:stripe)`,
     `subscribed?(name:)`, `subscriptions.active.find_by(name:)`,
     `cancel_now!` (all in `app/models/user/subscription.rb`),
   - Checkout + Portal session creation
     (`app/controllers/billing/checkouts_controller.rb`,
     `portal_sessions_controller.rb`),
   - webhook verification + dispatch (`app/controllers/billing/webhooks_controller.rb`,
     `app/models/billing/webhook.rb`) and the `Billing::ProcessedEvent`
     idempotency + livemode-rejection behaviour,
   - Pay's own migrations — a major Pay bump usually ships schema changes; run
     `bin/rails pay:install:migrations` (or whatever 11.x prescribes) and keep
     the migration reversible per CI convention.
3. Remove `--ignore GHSA-mjgf-xj26-9qf9` from `bin/ci` (both invocation arms).
   bundle-audit must pass **clean** — no ignores left.
4. **Tests.** Full `bin/ci`; the regression net for behaviour is
   `test/system/billing_test.rb` + `test/system/downgrade_grace_test.rb` plus
   the `test/controllers/billing/` suite. Add coverage only where a Pay API we
   rely on changed shape.
5. **Manual verification** (`/verify`): against a running app with Stripe
   **test-mode** keys — checkout → webhook → plan flips to `pro`; portal cancel
   → involuntary-downgrade grace opens; re-upgrade restores suspended monitors.

**DoD.** Issue #39 closed; no bundle-audit ignores anywhere; full CI green;
the test-mode webhook round-trip observed working, not just unit-tested.

---

## 3 · WS-B: dependabot backlog

Nine open PRs, all small: solid_queue 1.5.0 (#61), solid_cable 4.0.2 (#59),
thruster 0.1.23 (#58), honeybadger 6.9.1 (#57), selenium-webdriver 4.46 (#40),
image_processing 2.0.2 (#6), actions/checkout v4→v7 (#5),
browser-actions/setup-chrome v1→v2 (#4), webfactory/ssh-agent 0.9→0.10 (#35).

- Land them one at a time on a green check, rebase-merge (linear history per
  `CLAUDE.md`). solid_queue is the only one touching a core runtime path — eye
  its changelog for recurring-task changes (our detection sweep is an
  `every: "30s"` recurring task).
- The three GitHub-Actions bumps modify `ci.yml`, including the **deploy job**
  (`webfactory/ssh-agent`). They only take effect on `main`, so after merging,
  watch one auto-deploy complete rather than assuming.

Not strictly launch-blocking, but a clean queue means dependabot noise never
masks a real security PR later.

---

## 4 · WS-C: legal pages (Terms + Privacy)

**Why.** There are no terms-of-service or privacy-policy pages anywhere in the
app (grep-confirmed). A paid product with EU users needs both; Stripe checkout
and the sign-up form should reference them.

**Shape.**

- Two static pages on the marketing (`.lp`) design system, exactly like
  `pages#pricing` (issue #45 pattern): `PagesController#terms` / `#privacy`,
  `get "terms"` / `get "privacy"` routes, views under `app/views/pages/`,
  rendered by `layouts/landing`, public to everyone regardless of auth or the
  billing gate.
- **Links.** Add a "Legal" pair to the `_colophon` footer (both marketing pages
  get them for free); a consent line on the sign-up form — *"By creating an
  account you agree to the Terms of Service and Privacy Policy"* — as linked
  text above the submit button (no checkbox; the standard SaaS pattern — D3).
- **Privacy-policy content inventory** (keep the document honest — this is what
  the code actually does):
  - Collected: account email + password digest; session IP + user agent
    (`sessions` table); ping source IP, duration and reported error text
    (`PingEvent`, error truncated to `ERROR_MESSAGE_LIMIT` = 1 000 chars);
    incident error copies (deliberately outlive ping pruning); monitor/project
    names.
  - Retention: ping events pruned after `PING_RETENTION` = 90 days
    (`PrunePingEventsJob`); uptime day stats kept indefinitely; sessions until
    sign-out/deletion.
  - Cookies: the session cookie only. No analytics, no tracking pixels.
  - Subprocessors: Hetzner (hosting), Cloudflare (proxy/TLS), Stripe (payments
    — card data never touches our servers), the SMTP provider (owner to name —
    D2), Honeybadger (error reports), Slack (internal ops alerts).
  - ⚠️ `User::SignupAlert` (via `NotifySignupJob`) posts each **new user's email
    address** to the team Slack webhook. Either the policy discloses this
    processor for that purpose, or we redact the address from the Slack message
    — owner decision **D4**.
- **ToS content:** service description; acceptable use; plans + billing terms
  that match the code (monthly, cancel any time via the Stripe portal,
  immediate cancellation with no pro-rata refund — that's `cancel_now!`; the
  7-day involuntary-downgrade grace); no-SLA availability disclaimer; the
  AGPLv3 self-host distinction; termination; liability limitation; governing
  law (jurisdiction is owner decision **D2**).
- **Drafts, not legal advice.** The PR ships complete plain-language drafts;
  the owner signs off, and a professional review before launch is recommended.

**Tests.** Request tests for both pages (200, landing layout, key headings) and
extend `test/system/landing_page_test.rb` with footer-link assertions. No
dedicated system test — a static page is not a *flow*; this is a justified
deviation from the system-test rule, noted here per `CLAUDE.md`.

---

## 5 · WS-D: account deletion

**Why.** There is no way to delete an account (`resources :registrations,
only: %i[new create]` — no destroy anywhere). GDPR Art. 17-adjacent, and a
Stripe subscription must never outlive its account. Far cheaper to ship before
there are real customers than after.

**Shape** (per the decision table in `CLAUDE.md`):

- **Route/controller:** `resource :account, only: %i[show destroy]` →
  `AccountsController`. `#show` is a minimal account page: email address,
  verified badge, a link to `billing_subscription_path` when
  `Stablemate.billing_enabled?`, and a danger zone with the delete form. Add an
  "Account" link to the authed header nav in `layouts/application`.
- **Operation object:** deletion means more than `destroy!` (Stripe must be
  cancelled first), so it's `User::Closure`
  (`app/models/user/closure.rb`), facade `user.close_account!` delegating to
  `Closure.new(self).close_account!` — the operation's public method carries
  the facade's verb, never `#call` (rule 2). Steps:
  1. `cancel_pro_subscription!` when billing is enabled — reuses the existing
     Pay coupling in `User::Subscription`; `cancel_now!` semantics (immediate,
     no pro-rata refund) are stated in the danger-zone copy.
  2. `destroy!` the user. Cascades: `sessions` (dependent: :destroy),
     `projects` (dependent: :destroy) → monitors → ping events / incidents /
     uptime stats / notifications / API keys, **and Pay's `pay_customers`**.
     Pay declares its own dependent option — the test must *assert* the
     `pay_*` rows are gone, not assume.
- **Confirmation UX:** re-enter current password
  (`user.authenticate(params[:current_password])`). Wrong password → 422
  re-render with a generic error. Success → `close_account!`,
  `terminate_session`, redirect to root with a plain confirmation notice.
- **Webhook race:** an in-flight Stripe webhook for a just-deleted customer
  must be swallowed (2xx, skip), never 500 — Stripe retries 500s for days.
  Verify `Billing::WebhooksController`'s current behaviour for an event whose
  customer no longer resolves; add the request test; fix if it raises.

**Edge cases.** Deleting while `awaiting_downgrade_choice` → rows gone, lock
irrelevant. Open incident at deletion → cascaded away; the next detection sweep
sees nothing (no orphan alerting). Project API keys die with their projects —
the gem gets opaque 401s afterwards, which is the correct signal.

**Tests.** `[unit]` `User::Closure` — billing on: cancels then destroys (stub
at the Pay seam); billing off: destroy only. `[request]` wrong password;
success (cascade assertions incl. `pay_*`); webhook-after-delete. `[system]`
**required** — destructive, user-facing flow: sign in → Account → delete with
password → back on the marketing page → old credentials can't sign in.

Run **`/security-review`** on this diff before pushing (auth surface — workflow
rule 3).

---

## 6 · WS-E: publish the companion gem

The gem is finished (own green suite, gated in `bin/ci`) but unpublished —
`docs/integrating.md` ships a `git:`+`glob:` install block and promises "once
the gem is published to RubyGems this collapses to `gem "stablemate"`".

1. **D1 first:** confirm the name `stablemate` is free on rubygems.org at
   publish time. If squatted, pick the fallback (e.g. `stablemate-monitor`) —
   gemspec, docs and landing snippets all change, so decide before tagging.
2. Gemspec metadata polish: `spec.metadata` with
   `"rubygems_mfa_required" => "true"`, `source_code_uri`, `changelog_uri`
   (add a minimal `gem/CHANGELOG.md` for 0.1.0).
3. Tag `gem-v0.1.0` on the release SHA (the tag format `integrating.md`
   already anticipates).
4. Owner action: `cd gem && gem build stablemate.gemspec && gem push …` from an
   MFA-enabled RubyGems account. No API keys in repo or CI; automated releases
   (trusted publishing) are a post-launch nicety, not a launch item.
5. Docs: collapse `integrating.md` §1.1 to `gem "stablemate"`, keeping the
   git/fork block as the self-host alternative; sweep README and the landing
   page for any git-install snippet.

**DoD.** `gem install stablemate` works from a clean machine; dog-fooding
(WS-F) reinstalls from RubyGems rather than git, proving the packaged gem.

---

## 7 · WS-F: ops pre-launch checklist (owner, off-repo)

Mirrors runbook §0 with concrete verifications, plus the Stripe-live items the
runbook predates. Nothing here is verifiable from the repo — it's owner
calendar time.

- **SMTP + deliverability:** credentials set (`bin/rails credentials:edit` →
  `smtp.*`); SPF/DKIM/DMARC published; a real `down` email lands in an inbox
  with `spf=pass dkim=pass dmarc=pass` and a decent mail-tester score
  (runbook §2). For an alerting product this is the existential item.
- **Backups:** nightly `pg_dump` cron installed **and one restore rehearsed**
  (runbook §1) — `/up` returns 200 afterwards.
- **Dog-fooding:** stablemate.dev's own recurring jobs monitored via the gem
  (runbook §3), reinstalled from RubyGems after WS-E.
- **Stripe live mode:** Pro product + monthly price created live;
  `STRIPE_PRICE_ID_PRO` + live keys + live webhook signing secret in
  credentials (all same-mode — the code rejects cross-mode events); webhook
  endpoint `https://stablemate.dev/billing/webhook` registered. A live-mode
  test purchase + refund is the only true end-to-end — owner call (**D5**).
- **Honeybadger:** production API key set; a deliberate test exception arrives.
- **Mailboxes:** `support@` (reply-to) and `dmarc@` (aggregate reports) exist
  and are read; `alerts@` is authorised to send.
- **Cloudflare posture re-check:** orange cloud, SSL "Full (strict)", origin
  firewall locked to Cloudflare ranges (docs/install.md) —
  `STABLEMATE_BEHIND_CLOUDFLARE=true` is already set in `deploy.yml`.

---

## 8 · WS-G: the launch-day switch

Deliberately last and deliberately tiny — one small commit plus one config
change, both reversible.

**Code (one commit):**

- Remove `shared/_coming_soon_badge` and its two renders
  (`layouts/application`, `shared/_auth_logo`); remove the `.lp` badge markup
  in `pages/_nav` and the `.badge-soon` rules in `landing.css`.
- Update the tests that assert the badge: `test/system/landing_page_test.rb`,
  `pricing_page_test.rb`, `authentication_test.rb`, `password_reset_test.rb`,
  and the `PagesControllerTest` "never sees sign-up CTAs" coverage referenced
  from the partial's comment.
- Fix in passing: `config/deploy.yml`'s comment points at
  `.github/workflows/deploy.yml`; the deploy job actually lives in `ci.yml`.

**Config:**

- Raise `STABLEMATE_SIGNUP_ACCOUNT_CAP` in `config/deploy.yml` from `1` to the
  launch value (**D6** — e.g. `100`, or delete the line for fully open;
  locked decision #7: the waitlist re-arms itself if the cap fills, and
  re-opens manually by raising the value). This is a tracked-file change, so
  it rides the same commit and auto-deploys.

**Sequence on the day:** WS-A–F all done → merge the switch commit → auto-deploy
→ smoke test production as a stranger: sign up fresh, create a monitor, ping
it, watch it go `up`; and confirm a checkout with a real/test card per D5.

---

## 9 · Ordering & effort

```
WS-A (billing deps)  ──►  WS-B (backlog)      code, ~0.5–1.5d + ~0.5d
WS-C (legal pages)   ──►  WS-D (deletion)     code, ~0.5–1d each
WS-E (publish gem)   ──►  WS-F dog-food item  ~0.5d + owner time
WS-F (ops checklist)      owner, parallel throughout; DNS/restore ≈ 0.5d
WS-G (switch)             last, ~0.25d
```

A is first (majors bite; do it while there are zero customers). C/D can run in
parallel with A. F starts now and runs throughout. G strictly last. Total code
effort ≈ **3–4 focused days**; the calendar is dominated by F (DNS propagation,
deliverability verification, legal sign-off).

## 10 · Decisions needed (owner)

| # | Decision | Default/recommendation |
|---|----------|------------------------|
| D1 | Gem name fallback if `stablemate` is taken on RubyGems | Check first; `stablemate-monitor` if needed |
| D2 | Legal drafts: jurisdiction + professional review? | Review recommended; name the SMTP provider in the policy |
| D3 | Sign-up consent UX | Linked text line, no checkbox (SaaS standard) |
| D4 | Slack signup alert includes the new user's email | Disclose in the privacy policy **or** redact the address |
| D5 | Live-mode Stripe test purchase before launch | Yes — one purchase + refund |
| D6 | Launch cap value for `STABLEMATE_SIGNUP_ACCOUNT_CAP` | e.g. 100 with waitlist re-arm; owner's call |

## 11 · Definition of done (the whole spec)

- Issue #39 closed; `bundle-audit` clean with **no ignores**; dependabot queue
  empty; full CI green.
- `/terms` and `/privacy` live, linked from footer + sign-up, copy approved.
- Account deletion shipped with unit + request + **system** coverage and a
  `/security-review` pass.
- `gem "stablemate"` installs from RubyGems; `integrating.md` updated;
  production dog-foods the published gem.
- Every runbook §0 box actually checked, plus Stripe live-mode verified.
- Badge gone, cap open, and a stranger can complete the full loop on
  production: sign up → install gem → monitor `up` → break the job → `down`
  email → fix → `recovered` email.
