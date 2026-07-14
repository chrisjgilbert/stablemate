# Production readiness checklist

Goal: run Stablemate in production, prove alerting deliverability end-to-end, and
wire up a second Rails/Solid Queue app to check in via the companion gem.

Status legend: 🟢 code already exists · 🟡 code exists but needs ops/config ·
🔴 not built yet · ⚪ decision needed.

---

## Verdict on the three things you remembered

| You said… | Reality |
|---|---|
| Email needs confirming (SMTP Postmark setup) | 🟡 **Half true.** The email-*verification* feature is fully built and non-blocking (`UserMailer#verification`, signed token, `EmailVerificationsController`). What's missing is the **ops side**: a real transactional provider (Postmark) wired, a real `From` domain with SPF/DKIM/DMARC, and a delivered-to-inbox smoke test. The `From` today is a placeholder personal address with a `TODO`. |
| The gem needs publishing | 🔴 **True.** `stablemate` is at `0.1.0`, lives in `gem/`, has no RubyGems push metadata, and isn't on rubygems.org. `docs/integrating.md` tells users `gem "stablemate"`, which won't resolve until it's published (or pointed at a git source). |
| Add an option to turn off "auto-sync from Solid Queue config" | 🔴 **True — doesn't exist.** Boot sync (Layer 2) always runs when `api_key` is set and the env is allowed. The only way to stop it today is to withhold the API key (which also kills Layer 1 pings) or exclude the environment. There's no dedicated `register_on_boot`/`auto_sync` toggle. |

---

## A. Email deliverability 🟡

The feature code is done; this is provider + DNS + a real send.

- [ ] **Create a Postmark account** and a Server; grab the SMTP token. (Generic
      SMTP is already wired in `config/environments/production.rb:135-154` —
      Postmark works as a plain SMTP host, no gem/adapter change needed.)
- [ ] **Set SMTP env/credentials on the prod box** (managed instance stores these
      in Rails credentials; env wins if set):
      `SMTP_ADDRESS=smtp.postmarkapp.com`, `SMTP_PORT=587`,
      `SMTP_USERNAME`/`SMTP_PASSWORD` = the Postmark server token (Postmark uses
      the token for both), `SMTP_DOMAIN=stablemate.dev`.
- [ ] **Fix the `From`/`Reply-To`** — `app/mailers/application_mailer.rb:8-9` still
      defaults to `chris@chrisgilbert.dev` with a `TODO`. Set
      `STABLEMATE_MAIL_FROM="Stablemate <alerts@stablemate.dev>"` and
      `STABLEMATE_MAIL_REPLY_TO=support@stablemate.dev` (or update the mailer
      default and delete the TODO). Also check the similar TODO in
      `config/initializers/pay.rb:32`.
- [ ] **Publish DNS records** for the sending domain (values from Postmark;
      procedure already in `docs/runbook.md §2`): SPF TXT, DKIM CNAME/TXT, and a
      `p=none` DMARC to start.
- [ ] **Smoke-test a real send to a real inbox.** `raise_delivery_errors = false`
      in prod (`production.rb:64`) means a misconfigured SMTP **fails silently** —
      down-alerts just won't arrive. From a prod console:
      `MonitorMailer.down(Monitor.first).deliver_now` and confirm headers show
      `spf=pass; dkim=pass; dmarc=pass` and it's not in spam. This is the
      Phase 4 acceptance gate.
- [ ] (Optional) Verify the signup **verification** email actually lands, since
      the whole point of running in prod is real users.

---

## B. Publish the gem 🔴

Pick one path:

- [ ] **Path 1 — publish to RubyGems** (matches what `docs/integrating.md`
      promises: `gem "stablemate"`):
    - [ ] Add a `metadata` block to `gem/stablemate.gemspec` (source_code_uri,
          homepage, `allowed_push_host = "https://rubygems.org"`,
          `changelog_uri`). Consider setting `spec.authors`/`email` to real values.
    - [ ] Decide the versioning story for a gem-in-a-monorepo (tag as
          `gem-v0.1.0` or similar so it doesn't collide with app release tags).
    - [ ] `cd gem && gem build stablemate.gemspec && gem push stablemate-0.1.0.gem`
          with a rubygems.org account + API key (and ideally MFA on the account).
    - [ ] Bump to a real released version if `0.1.0` should signal something.
- [ ] **Path 2 — git source (faster, no publish)**: in the *consuming* app's
      Gemfile use `gem "stablemate", git: "https://github.com/chrisjgilbert/stablemate", glob: "gem/*.gemspec"`.
      Good enough to dog-food the second app now; publish later. If you take this
      path, add a note to `docs/integrating.md` so the `gem "stablemate"`
      instruction isn't misleading.

> Recommendation: Path 2 today to unblock the second app, Path 1 before you tell
> anyone else to install it.

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
- [ ] Put SMTP creds (from section A) into **production credentials**
      (`bin/rails credentials:edit`) or the box's env.
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

1. **C** (gem toggle) — small, self-contained code change; do it first so the
   gem you publish already has it.
2. **B** (publish / git source) — unblocks the second app.
3. **A + D** (email provider + deploy secrets) — the ops push to a live box.
4. **E** (wire the second app, verify end-to-end).
5. **F** (flip the caps / decide billing) when you're happy it all works.
