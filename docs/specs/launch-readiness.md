# SaaS launch readiness — the road to open sign-ups

Status: **PROPOSED — pressure-tested** (adversarial review pass folded in,
2026-08-01; see the review note below). Author: Claude (session), 2026-08-01.
Owner: @chrisjgilbert. Extends nothing in the data model; this is a
**launch punch list spec** — it enumerates what stands between today's `main`
and taking real customers on the managed instance, and specifies the shape of
each piece of work. No new product features. Follow the architecture rulebook in
[`../../CLAUDE.md`](../../CLAUDE.md).

> Scope note: "launch" here means the managed instance at `stablemate.dev`
> accepting open sign-ups and real Stripe payments. Self-hosting is already
> shipped and unaffected except where noted.

---

## 0 · Execution ledger — **the state file; read this first**

This section is the single source of truth for what is done and what is next.
It is committed, so it survives a container restart: to resume, read this table,
find the first chunk that isn't `MERGED`, and continue from its unchecked boxes.

**Each chunk ships the same way:** TDD → adversarial code review with fixes
applied → `/simplify` pass → `/verify` pass against the running app → full
`bin/ci` → PR → merge to `main` only when GitHub Actions is green → tick the
boxes here → next chunk.

| # | Chunk | Covers | Status | PR |
|---|-------|--------|--------|-----|
| 0 | Launch-readiness spec + verification campaign + 27 bug fixes | — | **MERGED** | #62 |
| 0 | Billing dependency upgrade | WS-A | **MERGED** | #63 |
| 1 | Account page — deletion + password change | WS-D | **MERGED** | #64 |
| 2 | Legal pages — Terms + Privacy + consent | WS-C | **MERGED** | #65 |
| 3 | Findings follow-ups + Honeybadger secret move | launch-findings tail | **MERGED** | #67 |
| 4 | Dependabot backlog | WS-B | **NOT STARTED** | — |

Deliberately **not** in these chunks: WS-E (publishing the gem needs an
MFA'd RubyGems account — owner action, though the repo-side prep can ride in a
chunk), WS-F (ops, entirely off-repo), and WS-G (the launch switch, which must
be last and needs D6).

### Chunk 1 — Account page (WS-D) — **MERGED (#64)**
- [x] `resource :account` → `AccountsController#show/destroy` + nested password sub-resource
- [x] `User::Closure` operation (`close_account!`) — the `pay_customers` cascade ended up
      declared on the association instead, so it holds for *every* deletion path
- [x] Stripe-failure policy: abort cleanly, delete nothing
- [x] Signed-in password change (current password required; this session survives, others die)
- [x] Webhook tolerates an event for a deleted customer — it already did; now pinned
- [x] `enforce_downgrade_fallback!`'s `reload` survives a user deleted mid-batch
- [x] Browser-driven system test for deletion **and** password change
- [x] Review → `/simplify` → `/verify` → CI → PR → merge

Three defects the gates caught that a green suite would not have:
1. **Security, also on `main`:** the password guard read the raw param but wrote the
   permitted one, so `password[]=x` reported success with the password unchanged —
   in both the signed-in change and the unauthenticated reset.
2. **Correctness, introduced here:** closing an account cascades away all of a
   user's monitors, and a vanished row aborted the whole detection sweep (a real
   overdue monitor was left `up`). Fixed at the iteration layer for all sweeps.
3. **Production:** deletion cascaded ping events row-by-row inside the request —
   ~65s for a Free account, 20+ min and ~650MB for a Pro one. Now bulk deletes.

Carried forward: **`waitlist_signups` survives account closure** — a deleted
user's email persists there, which contradicts the "delete every trace" framing.
A retention decision, settled with the privacy policy in chunk 2.

### Chunk 2 — Legal pages (WS-C) — **MERGED (#65)**
- [x] `/terms` and `/privacy` on the marketing layout, public
- [x] Footer links + sign-up consent line (D3: linked text, no checkbox — the
      waitlist branch gets its own wording, since joining binds nobody to Terms)
- [x] Privacy content matches what the code actually collects/retains, with the
      content tests driven off the constants so a behaviour change breaks the
      page describing it
- [x] Request tests + footer-link assertions
- [x] Waitlist rows now deleted with the account, so erasure is true not aspirational
- [x] Review → `/simplify` → `/verify` (27/27) → CI → PR → merge

**Writing the policy exposed two credential leaks to a third party**, both fixed
here: the ping token reached Honeybadger twice (in `notice.url` *and* in the
breadcrumb trail, since `request.filtered_path` filters only the query string),
and both session cookies left raw in `HTTP_COOKIE` — `session_id` resumes a
signed-in session for anyone holding it. Root cause: Honeybadger does not
inherit Rails' `filter_parameters`. Also corrected the Terms claiming the
companion gem is AGPL when it is **MIT**.

**⚠️ OWNER ACTIONS before these pages can go live:**
- [ ] **Operating entity** — registered name/address (+ ICO number if required).
      The only remaining placeholder; a test pins it at exactly one per page so
      it cannot ship by accident.
- [ ] **Confirm Postmark** when SMTP is configured (WS-F) — it is named on D2,
      not on anything the repo can prove.
- [ ] Review the invented defaults: liability cap (12 months' fees or £100),
      30-day notice for price/terms changes, minimum age 16.
- [ ] Confirm the unverifiable claims: transfer safeguards, server-log retention,
      production-access limits, and whether Cloudflare sets its own cookies —
      that last one is load-bearing for the "two cookies, so no banner" reasoning.
- [ ] Enter the Terms/Privacy URLs into Stripe Checkout's branding settings.

### Chunk 3 — Follow-ups + secret hygiene
- [x] Honeybadger key out of `config/honeybadger.yml` into ENV/credentials
      (**rotation itself is owner action — the key is in git history forever**)
- [x] `release_downgrade_lock_if_within_cap!` wired into monitor destroy — on the
      record, so project destroy and console deletes get it too
- [x] `past_due` user no longer shown an "Upgrade to Pro" button that bounces —
      one `billed_for_pro?` question now answers all four upgrade CTAs
- [x] `live_today_stat` memoized; `broadcast_status_update` after commit
- [x] `Signup` builds the user before taking the advisory lock (bcrypt outside)
- [x] `status_before_suspension` — **decided: no backfill.** Nothing in the schema
      records whether a suspended monitor had been paused, so a migration could
      only guess, and guessing "paused" would silently stop monitoring live jobs —
      worse than the un-pause it would prevent. The cohort is empty in production
      (`suspend!` is reachable only behind the Stripe gate, which has never been
      live). Documented at `Suspension#reactivate!` and pinned by a test.
- [x] System test for the new grace-banner / downgrade-page states
- [x] `docs/integrating.md` drift (API-keys location, F2 precedence rule)
- [x] Review → `/simplify` → `/verify` → CI → PR → merge

Two things worth remembering from this chunk:
1. **The committed Honeybadger key was a self-hosting privacy problem**, not just
   repo hygiene — every self-hosted instance was reporting *its* exceptions, with
   its own users' data, into the owner's Honeybadger project. That stops here.
2. **A `past_due` customer was in a dead end**: their plan reads Free while Stripe
   dunned them, so the billing page offered an Upgrade the controller refuses
   *while hiding* the Manage-card link that would have fixed the payment.

### Chunk 4 — Dependabot backlog (WS-B)
- [ ] solid_queue 1.5.0 (#61) — eye the recurring-task changelog
- [ ] solid_cable 4.0.2 (#59), thruster 0.1.23 (#58), honeybadger 6.9.1 (#57)
- [ ] selenium-webdriver 4.46 (#40), image_processing 2.0.2 (#6)
- [ ] actions/checkout v7 (#5), setup-chrome v2 (#4), ssh-agent 0.10 (#35)
- [ ] Watch one auto-deploy complete after the Actions bumps land
- [ ] Review → `/simplify` → `/verify` → CI → PR → merge

> **Review note (2026-08-01).** An adversarial pressure-test pass verified every
> file/behaviour claim in this spec against the code and the installed gems.
> Material corrections it forced, now folded in: Pay declares **no**
> `dependent:` option on `pay_customers`, so WS-D must destroy them explicitly
> and handle Pay's destroy-time Stripe callback; a Stripe-portal cancellation is
> **not** `cancel_now!` (WS-C's billing terms and WS-F's portal config both
> corrected); Stripe Tax, the live portal configuration, the webhook event list
> and Pay's default customer emails were missing from WS-F; a live Honeybadger
> API key is committed in `config/honeybadger.yml` and must be rotated; the
> waitlist's "we'll email you an invite" promise had no owner; and a signed-in
> user can neither change their password nor their email (now WS-D scope / D8).

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

> **Addendum (2026-08-01):** a full pre-launch verification campaign (six
> adversarial subsystem reviews + live browser verification) confirmed 13
> major edge-case bugs and 17 minors against this baseline. Their fixes are a
> **prerequisite workstream ahead of WS-G**, tracked with evidence and status
> in [`launch-findings.md`](launch-findings.md).

What's left is seven workstreams, four of them code:

| WS | What | Kind | Launch-blocking? |
|----|------|------|------------------|
| A | ~~Billing dependency security upgrade (`pay` 8→11, `stripe` 13→19, drop the CI ignore)~~ **DONE** | code | ~~Yes~~ shipped |
| B | Dependabot backlog (9 small bumps) | code | Should-do |
| C | Legal pages: Terms + Privacy | code + copy | **Yes** — paid product, EU users |
| D | Account page: deletion + password change | code | **Yes** — GDPR-adjacent, cheap now, awkward later |
| E | Publish the companion gem to RubyGems | release ops | **Yes** — onboarding friction until done |
| F | Ops pre-launch checklist (runbook §0 + Stripe live config) | ops (owner) | **Yes** |
| G | Launch-day switch (badge removal + open the cap) | code + config | The launch itself |

---

## 2 · WS-A: billing dependency security upgrade — **DONE (2026-08-01)**

> Shipped: `pay` 8.3.0 → **11.7.0**, `stripe` 13.5.1 → **19.4.0**, Pay's
> `AddObjectToPayModels` migration installed, and the `--ignore` removed from
> `bin/ci` — bundle-audit now reports **"No vulnerabilities found"** with an
> empty ignore list, and the dead `config/bundler-audit.yml` placeholder is
> gone. Issue #39 closed. Breaking changes that actually bit: the 11.0
> association rename (`owner.subscriptions` → `pay_subscriptions`, test-side
> only — app code goes through `payment_processor.subscriptions`, which
> `Pay::Customer` still exposes) and the post-2025-03-31 Stripe invoice shape
> Pay 11 reads. Re-verified at boot with keys set: automount still suppressed
> (0 `/pay` routes), emails off, Stripe-only processor, key bridging intact.
> The API-version requirement this surfaced is now an ops item in §7.

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
     `app/models/billing/webhook.rb`), the `Billing::ProcessedEvent`
     idempotency, and the livemode rejection (enforced by the *controller*,
     not `ProcessedEvent`),
   - Pay's own migrations — a major Pay bump usually ships schema changes; run
     `bin/rails pay:install:migrations` (or whatever 11.x prescribes) and keep
     the migration reversible per CI convention.
3. Remove `--ignore GHSA-mjgf-xj26-9qf9` from `bin/ci` (both invocation arms).
   bundle-audit must pass **clean** — no ignores left. Also delete the dead
   placeholder ignore in `config/bundler-audit.yml` (`bin/ci` never passes
   `--config`, so the file is inert — remove the decoy rather than leave it).
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
- `image_processing` (#6) updates a gem nothing uses: no model declares an
  attachment, so Active Storage — and `deploy.yml`'s storage volume — is dead
  config today. Merging is harmless; just don't read the volume/backup advice
  as load-bearing.

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
    (`PrunePingEventsJob`); uptime day stats for as long as the monitor exists
    (they cascade with it — the earlier "kept indefinitely" here was wrong, and
    the published policy states the accurate version); sessions until
    sign-out/deletion.
  - Waitlist: `WaitlistSignup` stores email addresses indefinitely, and
    `WaitlistSignup::SlackAlert` posts each one to the team Slack — D4 covers
    *both* Slack alert paths, not just sign-ups.
  - Cookies: strictly necessary first-party cookies only, plural — the signed
    permanent `session_id` and Rails' `_stablemate_session` (return-to, flash,
    CSRF). No analytics, no tracking pixels.
  - Subprocessors: Hetzner (hosting), Cloudflare (proxy/TLS), Stripe (payments
    — card data never touches our servers), the SMTP provider (owner to name —
    D2), Honeybadger (error reports), Slack (internal ops alerts).
  - ⚠️ `User::SignupAlert` (via `NotifySignupJob`) posts each **new user's email
    address** to the team Slack webhook. Either the policy discloses this
    processor for that purpose, or we redact the address from the Slack message
    — owner decision **D4**.
- **ToS content:** service description; acceptable use; plans + billing terms
  that match the code — and the code has **two cancellation paths**: the
  in-app downgrade is immediate with no pro-rata refund (`cancel_now!` via
  `User::Downgrade`), while a Stripe-*portal* cancel arrives by webhook and
  takes effect per the portal's live configuration, typically period-end —
  WS-F pins that configuration deliberately; the 7-day involuntary-downgrade
  grace; no-SLA availability disclaimer; the
  AGPLv3 self-host distinction; termination; liability limitation; governing
  law (jurisdiction is owner decision **D2**).
- **Drafts, not legal advice.** The PR ships complete plain-language drafts;
  the owner signs off, and a professional review before launch is recommended.

**Tests.** Request tests for both pages (200, landing layout, key headings) and
extend `test/system/landing_page_test.rb` with footer-link assertions. No
dedicated system test — a static page is not a *flow*; this is a justified
deviation from the system-test rule, noted here per `CLAUDE.md`.

Optional, same PR: `public/robots.txt` is the empty Rails default and there is
no sitemap. Not launch-blocking, but the marketing-page work is the natural
moment for the SEO basics.

---

## 5 · WS-D: the account page — deletion + password change

**Why.** There is no way to delete an account (`resources :registrations,
only: %i[new create]` — no destroy anywhere). GDPR Art. 17-adjacent, and a
Stripe subscription must never outlive its account. Far cheaper to ship before
there are real customers than after. Two adjacent gaps surfaced in review and
join this workstream: a signed-in user cannot change their **password** except
via the "forgot" email round-trip (`PasswordsController` is token-reset only,
fully unauthenticated), and cannot change their **email address** at all —
password change ships here; email change is an explicit deferral (**D8**), not
an oversight.

**Shape** (per the decision table in `CLAUDE.md`):

- **Route/controller:** `resource :account, only: %i[show destroy]` →
  `AccountsController`, plus a nested
  `resource :password, only: :update, module: :accounts` for the signed-in
  password change — a sub-resource, not a custom verb (rule 4), and distinct
  from the unauthenticated reset flow in `PasswordsController`. `#show` is a
  minimal account page: email address, verified badge, change-password form
  (current password required), a link to `billing_subscription_path` when
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
  2. **Explicitly destroy `pay_customers`.** Pay declares **no** `dependent:`
     option on the association (`pay/attributes.rb` — verified in both the
     installed 8.3.0 and the 11.6.2 upgrade target), so a bare user
     `destroy!` would orphan every `pay_*` row with a nil owner — and an
     orphaned `Pay::Customer` is a live hazard: Pay's webhook handlers call
     `pay_customer.email`, which delegates to the (now nil) owner and raises.
     Each `Pay::Customer` does cascade to its own subscriptions / charges /
     payment methods, so destroying the customers is sufficient. The request
     test must assert the `pay_*` rows are actually gone.
  3. `destroy!` the user. The app-side cascade chain is fully declared
     (verified): `sessions`; `projects` → monitors → ping events / incidents /
     uptime stats / notifications, and API keys.
- **Confirmation UX:** re-enter current password
  (`user.authenticate(params[:current_password])`). Wrong password → 422
  re-render with a generic error. Success → `close_account!`,
  `terminate_session`, redirect to root with a plain confirmation notice.
- **Stripe-failure policy:** `cancel_now!` makes a live Stripe API call and
  raises `Pay::Stripe::Error` on an outage or on local/Stripe drift (active
  locally, already cancelled at Stripe). Policy: **abort cleanly, delete
  nothing** — rescue, re-render with "we couldn't cancel your subscription;
  try again or email support". Never half-delete. Second hazard: Pay itself
  installs `after_commit :cancel_active_pay_subscriptions!, on: [:destroy]`,
  which would fire a live Stripe call *after* the user row is already gone —
  cancelling first (step 1) makes that callback a no-op, and destroying the
  `pay_customers` inside the same transaction keeps the rows consistent.
- **Webhook race:** an in-flight Stripe webhook for a just-deleted customer
  must be swallowed (2xx, skip), never 500 — Stripe retries 500s for days.
  With the explicit `pay_customers` destroy above, "customer no longer
  resolves" becomes a real state the controller must tolerate — and today
  `Billing::WebhooksController` rescues only signature/JSON errors, while
  Pay's own handlers (e.g. the `invoice.payment_failed` mailer) raise on a
  missing/ownerless customer. Add the request test for an event referencing a
  deleted customer; harden the controller if it raises.

**Edge cases.** Deleting while `awaiting_downgrade_choice` → rows gone, lock
irrelevant. Open incident at deletion → cascaded away; the next detection sweep
sees nothing (no orphan alerting). Project API keys die with their projects —
the gem gets opaque 401s afterwards, which is the correct signal.

**Tests.** `[unit]` `User::Closure` — billing on: cancels, destroys
`pay_customers`, destroys the user (stub at the Pay seam; cover the drift case
— active locally, already cancelled at Stripe → clean abort); billing off:
destroy only. `[request]` wrong password; success (cascade assertions incl.
`pay_*`); webhook-after-delete; password change (wrong current password → 422,
success re-authenticates). `[system]`
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
  endpoint `https://stablemate.dev/billing/webhook` registered. Plus three
  items that will break live billing even with all of that set:
  - **Stripe Tax:** checkout runs with `automatic_tax: { enabled: true }`
    (`billing/checkouts_controller.rb`) — a live Checkout Session fails until
    Stripe Tax is configured (origin address + registrations) in the live
    dashboard.
  - **Customer Portal configuration:** live portal-session creation errors
    until a default portal configuration is saved — and that configuration
    decides portal-cancellation timing (see WS-C's ToS terms; choose
    period-end deliberately, and make the ToS say what the portal does).
  - **Webhook event list + Pay's stock emails:** register a deliberate event
    list — `Billing::Webhook#pay_process!` hands *any* subscribed event to
    Pay's handlers. (Pay's customer-facing emails are now **off**; D9 resolved.)
  - **⚠️ Webhook endpoint API version ≥ `2025-03-31`.** Stripe sends each
    endpoint the payload shape of *its* pinned API version, and Pay 11 reads
    the post-2025-03-31 shape — e.g. its `invoice.payment_failed` handler reads
    `invoice.parent.subscription_details.subscription`, which simply does not
    exist on an older invoice. An endpoint pinned to an old version therefore
    raises `NoMethodError` inside `Pay::Webhooks.instrument`, 500s our webhook,
    rolls the `ProcessedEvent` claim back, and has Stripe retry forever — and
    disabling Pay's emails does *not* avoid it, because the crash happens
    before the send decision. A newly-created endpoint defaults to a current
    version; verify it rather than assume, and re-check after any Pay upgrade.

  A live-mode test purchase + refund is the only true end-to-end — owner call
  (**D5**).
- **Honeybadger — ⚠️ rotate the committed key:** `config/honeybadger.yml`
  carries a hardcoded, git-tracked API key in a publicly distributed repo
  (it's in history regardless of any future removal). Rotate it in the
  Honeybadger dashboard, move the new one to ENV/credentials per the house
  pattern (`CLAUDE.md` third-party-secrets rule; the `stripe_secret_key`
  shape), strip it from the YAML — a small code change, ride along with
  WS-A/WS-B — then confirm a deliberate test exception arrives in production.
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

**Tell the waitlist (D7):** the sign-up page has been promising *"we'll email
you an invite"* (`registrations_controller.rb:38`), and no invite mailer
exists anywhere. When the cap opens, email the accumulated `WaitlistSignup`
rows that sign-ups are open — a one-off owner task (BCC from a mail client is
fine at this scale) or a tiny mailer driven from the console. Deciding
*against* notifying means changing the promise copy before launch; the promise
can't just be dropped on the floor.

**Sequence on the day:** WS-A–F all done → merge the switch commit → auto-deploy
→ smoke test production as a stranger: sign up fresh, create a monitor, ping
it, watch it go `up`; confirm a checkout per D5 — then send the waitlist
email (D7).

---

## 9 · Ordering & effort

```
WS-A (billing deps)  ──►  WS-B (backlog)      code, ~0.5–1.5d + ~0.5d
WS-C (legal pages)   ──►  WS-D (account page)  code, ~0.5–1d + ~1–1.5d
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
| D4 | Slack alerts (`User::SignupAlert` **and** `WaitlistSignup::SlackAlert`) post email addresses | Disclose in the privacy policy **or** redact the address |
| D5 | Live-mode Stripe test purchase before launch | Yes — one purchase + refund |
| D6 | Launch cap value for `STABLEMATE_SIGNUP_ACCOUNT_CAP` | e.g. 100 with waitlist re-arm; owner's call |
| D7 | Waitlist invite when the cap opens | Email the accumulated sign-ups (one-off owner task); deciding against means changing the promise copy |
| D8 | Email-address change for signed-in users | Defer post-launch (needs re-verification plumbing); password change ships in WS-D |
| D9 | Pay's stock customer emails (receipts, payment-failed) | Disable at launch (`Pay.send_emails = false`) unless deliberately branded + reviewed |

## 11 · Definition of done (the whole spec)

- Issue #39 closed; `bundle-audit` clean with **no ignores** (and the inert
  `config/bundler-audit.yml` removed); dependabot queue empty; full CI green.
- The committed Honeybadger key rotated, served from ENV/credentials, and no
  secret of any kind tracked in the repo.
- `/terms` and `/privacy` live, linked from footer + sign-up, copy approved.
- The account page shipped — deletion (with the explicit `pay_customers`
  destroy and clean Stripe-failure abort) + password change — with unit +
  request + **system** coverage and a `/security-review` pass.
- `gem "stablemate"` installs from RubyGems; `integrating.md` updated;
  production dog-foods the published gem.
- Every runbook §0 box actually checked, plus Stripe live-mode verified end to
  end: Tax configured, portal configuration saved (cancellation timing matches
  the ToS), a deliberate webhook event list, Pay's emails decided (D9).
- Badge gone, cap open, the waitlist emailed (D7), and a stranger can complete
  the full loop on production: sign up → install gem → monitor `up` → break
  the job → `down` email → fix → `recovered` email.
