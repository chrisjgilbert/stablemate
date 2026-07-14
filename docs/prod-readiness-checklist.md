# Production readiness checklist

Goal: run Stablemate in production, prove alerting deliverability end-to-end, and
wire up a second Rails/Solid Queue app to check in via the companion gem.

Status legend: 🟢 code already exists · 🟡 code exists but needs ops/config ·
🔴 not built yet · ⚪ decision needed · ✅ done.

> **Progress (2026-07-14):** git-source install path built, verified, and
> documented (**B/Path 2 ✅**). Postmark SMTP wired and confirmed reaching
> Postmark from prod — sends are currently **held pending Postmark account
> approval** (seen in the Activity feed), so DNS + inbox smoke-test are the
> remaining email work. **C** (gem toggle), **Path 1** publish, **D/E/F** still
> open.

---

## Verdict on the three things you remembered

| You said… | Reality |
|---|---|
| Email needs confirming (SMTP Postmark setup) | 🟡 **In progress.** The email-*verification* feature was already built and non-blocking (`UserMailer#verification`, signed token, `EmailVerificationsController`). Postmark SMTP is now **wired and reaching Postmark** from prod (confirmed via the Activity feed), and `From`/`Reply-To` are set to `alerts@`/`support@stablemate.dev` via env. Remaining: **Postmark account approval** (currently blocking real sends), DNS (SPF/DKIM/DMARC), and a delivered-to-inbox smoke test. |
| The gem needs publishing | 🟡 **Unblocked via git source.** `stablemate` is still at `0.1.0` and not on RubyGems, but the interim **git-source install is set up, verified, and documented** (`docs/integrating.md`, `gem/README.md`) — a second app can install it today. Publishing to RubyGems (Path 1) is still optional/open. |
| Add an option to turn off "auto-sync from Solid Queue config" | 🔴 **True — doesn't exist.** Boot sync (Layer 2) always runs when `api_key` is set and the env is allowed. The only way to stop it today is to withhold the API key (which also kills Layer 1 pings) or exclude the environment. There's no dedicated `register_on_boot`/`auto_sync` toggle. |

---

## A. Email deliverability 🟡

The feature code is done and SMTP is wired; what's left is Postmark approval,
DNS, and a real delivered send.

- [x] **Create a Postmark account** and a Server; grab the SMTP token. ✅
- [x] **Set SMTP env/credentials on the prod box.** Wired and confirmed — a test
      send from the prod console reaches Postmark (visible in the Activity feed).
      (`SMTP_ADDRESS=smtp.postmarkapp.com`, port `587`, Postmark server token as
      both `SMTP_USERNAME`/`SMTP_PASSWORD`.) ✅
- [x] **Set `From`/`Reply-To`.** Now `Stablemate <alerts@stablemate.dev>` /
      `support@stablemate.dev` via `STABLEMATE_MAIL_FROM`/`_REPLY_TO`. ✅
      - [ ] *Cleanup:* the mailer's hardcoded default still reads
            `chris@chrisgilbert.dev` with a `TODO` (`app/mailers/application_mailer.rb:8-9`,
            and the matching one in `config/initializers/pay.rb:32`). The env vars
            override it, so this is cosmetic — tidy the default + drop the TODO.
- [ ] **Get the Postmark account approved.** ← *current blocker.* Sends are held
      pending approval (confirmed in the Activity feed): a pending account can only
      send to addresses on its **own** verified domain, so alerts to
      `chris@chrisgilbert.dev` (a different domain than `stablemate.dev`) are
      blocked. Request approval in Postmark; meanwhile you can test by sending to a
      `@stablemate.dev` address.
- [ ] **Publish DNS records** for `stablemate.dev` (values from Postmark;
      procedure in `docs/runbook.md §2`): DKIM, the custom Return-Path CNAME (for
      SPF alignment), and a `p=none` DMARC to start. Add them in Cloudflare as
      **DNS-only** (grey cloud).
- [ ] **Smoke-test a real send to a real inbox** *(unblocks once approved + DNS
      live)*. Note `raise_delivery_errors = false` in prod (`production.rb:64`)
      means SMTP failures are **silent** — so verify via the inbox *and* the
      Postmark Activity feed, not the console return value. Confirm headers show
      `spf=pass; dkim=pass; dmarc=pass` and it's not in spam. Phase 4 acceptance gate.
- [ ] (Optional) Verify the signup **verification** email actually lands.

---

## B. Publish the gem 🟡

- [x] **Path 2 — git source (done ✅).** The interim install is set up, verified,
      and documented. The consuming app's Gemfile uses:
      ```ruby
      gem "stablemate", git: "https://github.com/chrisjgilbert/stablemate", glob: "gem/*.gemspec"
      ```
      Verified against the repo as a real git source: bundler finds the subdir
      gemspec via `glob:` and resolves `stablemate (0.1.0)` + `fugit`. Documented
      in `docs/integrating.md §1.1` and `gem/README.md` (with a `ref:`/`tag:` pin
      note). Good enough to wire the second app now.
    - [ ] *Optional pin:* push a `gem-v0.1.0` tag so apps can pin `tag:` instead of
          a commit SHA. Created locally but **this session's git policy blocks tag
          pushes** (branch pushes are fine) — push it yourself:
          `git tag -a gem-v0.1.0 919c0f2 -m "…" && git push origin gem-v0.1.0`.
- [ ] **Path 1 — publish to RubyGems** (optional; collapses the install back to
      `gem "stablemate"` and is what you'd want before telling *others* to install):
    - [ ] Add a `metadata` block to `gem/stablemate.gemspec` (source_code_uri,
          homepage, `allowed_push_host = "https://rubygems.org"`,
          `changelog_uri`). Consider setting `spec.authors`/`email` to real values.
    - [ ] Decide the versioning story for a gem-in-a-monorepo (tag as
          `gem-v0.1.0` or similar so it doesn't collide with app release tags).
    - [ ] `cd gem && gem build stablemate.gemspec && gem push stablemate-0.1.0.gem`
          with a rubygems.org account + API key (and ideally MFA on the account).
    - [ ] Bump to a real released version if `0.1.0` should signal something.
    - [ ] Then update `docs/integrating.md` / `gem/README.md` back to
          `gem "stablemate"`.

---

## C. Gem: add an "auto-sync off" toggle 🔴

Today the railtie (`gem/lib/stablemate/railtie.rb:28-44`) always runs boot
registration + attaches the subscriber whenever `api_key` is set and the env is
allowed. Add a dedicated switch so an app can keep Layer 1 pinging (or nothing)
without registering from `recurring.yml` on every boot.

- [ ] Add `attr_accessor :register_on_boot` to
      `gem/lib/stablemate/configuration.rb`, default `true`. (Name it for what it
      gates — boot registration — not the vaguer "auto_sync".)
- [ ] In the railtie, gate only the **Layer 2** call on it, e.g.
      `registration.sync! if Stablemate.config.register_on_boot`, and still build
      `class_to_keys` / attach the Layer 1 subscriber. Decide whether the
      subscriber should also respect the flag or only `ping_on_success`.
- [ ] Keep `rails stablemate:sync` as the manual registration path (it already
      ignores the env gate).
- [ ] Tests: `configuration_test.rb` for the default; a railtie/registration test
      that `register_on_boot = false` skips the boot `sync!` but leaves the
      subscriber wired.
- [ ] Document the flag in `gem/README.md`'s config table and `docs/integrating.md`.

> Design note to confirm ⚪: do you want the toggle to mean "don't register on
> boot, but I'll run `stablemate:sync` in my deploy" (most common), or a full
> "don't touch anything, Layer 1 only against manually-created monitors"? The
> first is one boolean; the second is two (`register_on_boot` + relying on
> `ping_on_success`).

---

## D. Deploy / infra secrets 🟡

Mechanics are all in place (`config/deploy.yml`, `.kamal/secrets`,
`.github/workflows/`); this is making sure the actual secret *values* exist.

- [ ] Set the three deploy vars: `KAMAL_REGISTRY_USER`, `STABLEMATE_SERVER_IP`,
      `STABLEMATE_HOST` (locally for a manual deploy, or as repo Variables for CI).
- [ ] Provision secrets consumed by `.kamal/secrets`: `KAMAL_REGISTRY_PASSWORD`,
      `RAILS_MASTER_KEY`, `STABLEMATE_DATABASE_PASSWORD`, and the Cloudflare Origin
      Cert PEMs (`STABLEMATE_SSL_CERT`/`_KEY`).
- [x] Put SMTP creds (from section A) into **production credentials**
      (`bin/rails credentials:edit`) or the box's env. ✅ (confirmed reaching
      Postmark)
- [ ] Confirm Cloudflare SSL/TLS mode is **Full (strict)** and the firewall is
      locked to Cloudflare ranges (per `docs/install.md`).
- [ ] `bin/kamal setup` (first time) then `bin/kamal deploy`; watch
      `bin/kamal logs`.

---

## E. Dog-food + prove the second-app flow 🟡

Phase 4 acceptance says "Stablemate is dog-fooded monitoring its own recurring
jobs," and your actual goal is a second app checking in.

- [ ] **Second app** (the real goal): add the gem (Path 1 or 2), drop in
      `config/initializers/stablemate.rb` with an API key generated from
      **Settings → API keys**, deploy, and confirm its `recurring.yml` tasks
      appear as monitors and flip `pending → up` on the next successful run.
      Then stop a job and confirm a `down` email arrives.
- [ ] **(Optional) dog-food Stablemate itself**: the app does **not** currently
      include its own gem (`Gemfile` has no `gem "stablemate"`). Adding it would
      monitor `detect_missed_pings`, `rollup_uptime`, etc. Only worth it if you
      want the acceptance box literally ticked.
- [ ] Run `/verify` / `/run` against the deployed instance for the core loop:
      ping flips `pending→up`, a stalled monitor emails `down`, next ping recovers.

---

## F. Decisions before you open the doors ⚪

- [ ] **Signup cap.** `config/deploy.yml` sets `STABLEMATE_SIGNUP_ACCOUNT_CAP: 1`
      — signups are effectively closed after the first account. Raise it (or set
      `0` = unlimited) when you're ready for real users; keep it low while testing.
- [ ] **Billing scope.** The app has grown a full Stripe/Pay "Pro plan" surface
      (`pay`/`stripe` gems, `Billing::*` controllers, `User::Subscription`) — this
      is **beyond the original V1 spec** (which said no payments). It's **off by
      default** (`billing_enabled?` needs the full Stripe key set), so it won't
      break a prod boot. Decide: leave billing dark for this prod test, or wire
      Stripe keys + `STRIPE_PRICE_ID_PRO` and test checkout too.
- [ ] **`raise_delivery_errors`.** Consider whether a silent-failure mail path is
      acceptable for a product whose value *is* the alert email — at minimum keep
      the section-A smoke test in your deploy runbook.

---

## Suggested order

Done: **B/Path 2** (git-source install) and the SMTP wiring in **A/D**.

1. **A** — get the Postmark account **approved** (the current email blocker), then
   publish DNS (DKIM / Return-Path / DMARC) and run the real inbox smoke-test.
2. **C** (gem toggle) — small, self-contained code change; land it before wiring
   the second app so you can choose boot-sync vs. manual `stablemate:sync`.
3. **E** — wire the second app via the git-source gem and verify end-to-end
   (monitors appear → `pending→up` on a real run → stop a job → `down` email).
4. **D** — finish any outstanding deploy secrets/checks.
5. **F** (flip the caps / decide billing) when you're happy it all works.
6. **B/Path 1** (RubyGems publish) — optional, before inviting other installers.
