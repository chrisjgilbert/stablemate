# GitHub auth — "Continue with GitHub" sign-in / sign-up

Status: **design spec — exploration, awaiting owner review; not yet ready to
build**. Author: Claude (session), 2026-07-15. Owner: @chrisjgilbert. Extends the
V1 auth model in [`README.md`](README.md) and **amends the locked stack decision
"No Devise, no OAuth"** (see §2). Follow the architecture rulebook in
[`../../CLAUDE.md`](../../CLAUDE.md).

> This is a **design spec, not a build spec.** It proposes the shape, names the
> reuse boundaries, walks every surface the change touches, and enumerates the
> edge cases and security traps. §12 lists the decisions the owner must resolve
> (each with a recommendation) before this is buildable.

---

## 1 · Motivation

Stablemate's audience is Rails developers wiring a companion gem into their apps
— people who, to a first approximation, all have a GitHub account and are signed
into it in their working browser. Today the only way in is email + password
(Rails 8 auth generator). Adding **GitHub as a social sign-in** does three
things:

1. **Cuts sign-up friction to one click** for exactly our audience. No password
   to invent, no verification email to wait on (GitHub has already verified the
   address — §6.3).
2. **Cuts sign-in friction** for returning users on new devices.
3. **Signals product fit.** A dev-tools product whose sign-in page offers
   GitHub reads as native to the audience; one that doesn't reads as generic.

Explicit non-goals (V1 of this feature):

- **Not replacing password auth.** Email + password stays fully supported and is
  the only path on a keyless self-host instance (§4).
- **No other providers** (Google, GitLab…). One provider, minimal surface. The
  data model deliberately leaves a seam (§5) but we don't build it.
- **No GitHub API usage beyond identity.** No repo access, no org reads, no
  webhooks. Scope is `user:email` and nothing else. We do not store the OAuth
  access token at all (§8).
- **No connected-accounts management UI** in V1 (link/unlink buttons in
  settings) — deferred, see §12.4.

## 2 · The locked decision this amends

[`README.md`](README.md) §2 (Stack) locks: *"Rails 8 built-in authentication
generator (sessions + `has_secure_password`). No Devise, no OAuth."*

The spirit of that decision — **no auth framework, no Devise, sessions and
passwords stay vanilla Rails** — is preserved untouched. This spec amends only
the "no OAuth" clause:

> **Amended:** Rails 8 built-in authentication generator (sessions +
> `has_secure_password`) remains the substrate. **GitHub OAuth (via OmniAuth) is
> the single social sign-in**, additive and config-gated: it only produces a
> `User` + `Session` through the same `start_new_session_for` path, and it is
> invisible (opaque 404) unless GitHub OAuth keys are configured.

On merge of the build PR, edit `README.md` §2 accordingly (same procedure as
projects.md amending locked decision #6).

## 3 · Library choice: OmniAuth, not hand-rolled

CLAUDE.md's ordering is *framework seam → gem → hand-rolled*. Rails has no OAuth
client seam, so the choice is between the standard gem and ~100 hand-rolled
lines.

**Choose the gem trio:**

```ruby
gem "omniauth"
gem "omniauth-github"
gem "omniauth-rails_csrf_protection"   # non-negotiable — CVE-2015-9284
```

- OmniAuth is the boring, classic, community-standard answer — exactly the
  "classic vanilla patterns" rule. It handles the `state` parameter, the token
  exchange, the failure modes, and normalises the payload to one `auth` hash.
- `omniauth-rails_csrf_protection` makes the request phase **POST-only and
  authenticity-token-verified**. Without it, `GET /auth/github` is a
  login-CSRF vector. The sign-in buttons are `button_to` (POST), never links.
- Hand-rolling was considered and rejected: the flow itself is simple, but the
  `state`/CSRF handling is precisely the security plumbing we shouldn't
  reinvent, and OmniAuth's test mode (§10) is what makes browser-driven system
  tests possible under WebMock without stubbing GitHub by hand.
- **No Devise.** OmniAuth is middleware + one callback controller; it does not
  own users, sessions, or views. The generator's code keeps doing all of that.

## 4 · Config gate (the billing pattern)

GitHub OAuth requires an OAuth app registration, so it is inherently
per-instance. Follow the exact `billing_enabled?` pattern — env-first, then
credentials, feature invisible when keyless:

```ruby
# config/initializers/stablemate.rb
def self.github_client_id
  ENV["GITHUB_CLIENT_ID"].presence ||
    Rails.application.credentials.dig(:github, :client_id)
end

def self.github_client_secret
  ENV["GITHUB_CLIENT_SECRET"].presence ||
    Rails.application.credentials.dig(:github, :client_secret)
end

def self.github_auth_enabled?
  github_client_id.present? && github_client_secret.present?
end
```

- Managed instance: keys in Rails encrypted credentials (per CLAUDE.md's
  third-party-secrets rule — **not** `deploy.yml` env / `.kamal/secrets`).
- Self-hosters: `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` env vars, documented
  in `.env.example` with a pointer to GitHub's "New OAuth App" page (callback
  URL: `https://<host>/auth/github/callback`). Optional — a keyless instance
  simply has no GitHub surface.
- The OmniAuth middleware `provider :github, ...` line is registered only when
  `github_auth_enabled?` (initializer, boot-time — same restart-to-enable
  semantics as billing). The callback controller additionally guards with an
  opaque `404` (`Billing::BaseController` precedent) so nothing is probeable
  when disabled, and the sign-in/sign-up views render the button only when
  enabled.

## 5 · Data model

Two nullable columns on `users` — no identities table:

```ruby
add_column :users, :github_uid, :string        # GitHub's immutable numeric user id, as string
add_column :users, :github_username, :string   # login/nickname, display only, mutable
add_index  :users, :github_uid, unique: true, where: "github_uid IS NOT NULL"
```

- `github_uid` is the identity key (GitHub logins can be renamed; the numeric id
  cannot). Unique partial index = one Stablemate account per GitHub account.
- `github_username` is cosmetic (settings chip, future support/debugging).
  Refreshed on every GitHub sign-in; never used for lookup.
- **Why not an `identities` table?** One provider is planned, and the locked
  architecture prizes the smallest shape that fits. If a second provider ever
  lands, migrating two columns into a `User::Identity` record is a mechanical
  refactor — that's the seam, and we don't pre-build it.

### Passwords stay NOT NULL — GitHub-created users get a random one

`users.password_digest` remains `NOT NULL` and `has_secure_password` remains
unconditional. A user created via GitHub gets
`password: SecureRandom.base58(32)` — unguessable, unknown even to us, and
**never shown**. Consequences, all intentional:

- Zero schema/validation branching: no nullable digest, no
  `BCrypt::Errors::InvalidHash` risk in `authenticate_by`, no conditional
  presence validations threaded through the model.
- A GitHub-only user who later wants a password uses the **existing
  password-reset flow** (they own the email — GitHub verified it, §6.3). No new
  "set a password" surface needed.
- The alternative (nullable digest + conditional validations) was rejected: it
  touches every password code path to support a state — "passwordless user" —
  that the random password represents for free.

### README.md data-model update (on build)

`User` row gains: `github_uid` (null, unique where not null),
`github_username` (null).

## 6 · The flow and the matching policy

### 6.1 · Request phase

`button_to "Continue with GitHub", "/auth/github", method: :post` (authenticity
token verified by `omniauth-rails_csrf_protection`; OmniAuth generates and
stores `state`). Scope: `user:email` only.

### 6.2 · Callback phase — `GET /auth/github/callback`

OmniAuth validates `state`, exchanges the code, fetches the user + emails, and
hands the controller one `request.env["omniauth.auth"]` hash. The controller
stays thin (§7): it asks the coordinator to identify the user, then branches on
the returned record's class — the exact `RegistrationsController#create`
pattern.

### 6.3 · Matching policy (the security-critical part, in order)

Let `uid = auth.uid`, `email = the **verified primary** email from GitHub`
(normalised through the existing `EmailNormalization` rules before matching).

1. **`User.find_by(github_uid: uid)` exists → sign in.** Refresh
   `github_username`. Do **not** touch `email_address` even if the GitHub email
   changed — GitHub is an identity here, not an email-sync source.
2. **No uid match, but `email` is GitHub-verified and matches an existing user →
   link + sign in.** Set `github_uid`/`github_username` on that user; also set
   `verified_at ||= Time.current` (ownership of the address is now proven, so
   our non-blocking verification is satisfied). Linking by email is safe **only
   because GitHub attests the email is verified** — see §8.
   - Sub-case: that user already has a *different* `github_uid` → **refuse**
     (alert: "That email belongs to an account linked to a different GitHub
     user."). No relinking through the front door.
3. **No match at all → sign-up**, subject to the signup cap exactly like the
   password path:
   - `Signup.at_capacity?` → **waitlist the email** (find-or-create
     `WaitlistSignup`, same friendly no-op semantics, same
     `NotifyWaitlistSignupJob`). No user, no session.
   - Otherwise create the user: verified email, random password (§5),
     `verified_at: Time.current`, **no verification email** (nothing to
     verify), and the same `NotifySignupJob` Slack alert.
4. **GitHub returns no verified email** (rare; unverified-email GitHub accounts
   exist) → fail with a friendly alert: "Verify your email address on GitHub
   first, or sign up with email and password." Never trust an unverified email
   (§8).

New-user sign-up and email-link both count as authentication events; all
successful branches end in the existing `start_new_session_for(user)` +
`redirect_to after_authentication_url` (return-to preserved).

## 7 · Architecture mapping (the decision table, applied)

| Piece | Row of the table | Name |
|---|---|---|
| Identify-or-create from a GitHub payload (spans `User` + `WaitlistSignup`, owned by neither) | **top-level coordinator** (noun) | `Github::Identification` — `app/models/github/identification.rb` |
| The callback endpoint (creates a `Session`) | **RESTful sub-resource controller** | `Sessions::OmniauthsController#create` |
| Waitlist find-or-create (now needed by two coordinators) | operation on the record it creates | `WaitlistSignup.join(email)` — extracted from `Signup#join_waitlist`, reused by both |

```ruby
# app/models/github/identification.rb — top-level coordinator (noun).
# Public method carries the verb — no #call (CLAUDE.md rule 2).
class Github::Identification
  def initialize(auth) ... end

  # Returns a User (matched, linked, or created), a WaitlistSignup (at capacity),
  # or nil (no verified email / refused link). The controller branches on class.
  def identify ... end
end
```

```ruby
# app/controllers/sessions/omniauths_controller.rb — thin, RegistrationsController-shaped.
class Sessions::OmniauthsController < ApplicationController
  allow_unauthenticated_access only: %i[create failure]
  # Opaque 404 when the feature is keyless — Billing::BaseController precedent.
  before_action :ensure_github_auth_enabled
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { ... }  # parity with SessionsController

  def create
    case record = Github::Identification.new(request.env["omniauth.auth"]).identify
    when User            then start_new_session_for(record); redirect_to after_authentication_url
    when WaitlistSignup  then redirect_to sign_up_path, notice: "You're on the list — ..."
    else                      redirect_to sign_in_path, alert: "..."   # no verified email / refused link
    end
  end

  def failure  # OmniAuth's user-denied / provider-error exit
    redirect_to sign_in_path, alert: "GitHub sign-in was cancelled or failed."
  end
end
```

Routes (the request-phase `POST /auth/github` is middleware — no route needed):

```ruby
get "/auth/github/callback", to: "sessions/omniauths#create"
get "/auth/failure",         to: "sessions/omniauths#failure"
```

What deliberately does **not** change: `Authentication` concern, `Session`
model, `SessionsController`, `PasswordsController`, the API/bearer surface —
GitHub auth is a third door into `start_new_session_for`, nothing more.

## 8 · Security review checklist (run `/security-review` on the build PR)

This touches auth + sessions, so the skill run is mandatory per CLAUDE.md. The
traps this design already closes — verify each survives implementation:

1. **Login CSRF on the request phase** → POST-only + authenticity token
   (`omniauth-rails_csrf_protection`). No `GET /auth/github` anywhere, ever.
2. **Callback forgery / code injection** → OmniAuth `state` validation (on by
   default; do not disable).
3. **Account takeover via unverified email** — *the* classic OmniAuth vuln.
   Attacker registers a GitHub account with the victim's address, doesn't
   verify, signs into Stablemate → must NOT link. Closed by §6.3: only the
   **verified** primary email links, and no-verified-email fails outright.
   This exact case gets a request test.
4. **Access-token exposure** → we never persist `auth.credentials`; the token
   dies with the request. Nothing to encrypt, rotate, or leak.
5. **Log hygiene** → add `:code` to `config.filter_parameters` (the OAuth
   authorization code transits our callback URL/params).
6. **Probe surface when disabled** → opaque `404` from the callback controller
   and no middleware provider registered; parity with the keyless billing
   namespace.
7. **Relink refusal** (§6.3.2) → email match never overwrites an existing,
   different `github_uid`.
8. **Rate limiting** → callback carries the same `rate_limit` as
   `sessions#create`; the request phase is gated upstream by GitHub itself.
9. **Waitlist enumeration** → GitHub-at-capacity reuses the find-or-create
   no-op semantics; a duplicate is a success, never an oracle (matches the
   existing `Signup` guarantee).

## 9 · UI

- **Sign-in page** (`sessions/new`): "Continue with GitHub" `button_to` above
  the email/password form with an "— or —" divider. Rendered only when
  `Stablemate.github_auth_enabled?`.
- **Sign-up page** (`registrations/new`), open mode: same button/divider.
  **Waitlist mode: no GitHub button** — at capacity the only action is leaving
  an email, and the button would just round-trip through GitHub to the same
  waitlist message. (The coordinator still handles the at-capacity race
  correctly if someone hits the endpoint directly — §6.3.3.)
- Standard GitHub mark + "Continue with GitHub" wording per GitHub's brand
  guidance; Tailwind-styled like the existing submit buttons. No Stimulus
  needed — it's a plain form POST.
- No settings/connected-accounts UI in V1 (§12.4).

## 10 · Testing plan (system tests non-negotiable)

OmniAuth **test mode** (`OmniAuth.config.test_mode = true` +
`mock_auth[:github]`) short-circuits both phases — the POST to `/auth/github`
redirects straight to the callback with a canned auth hash. No real HTTP, so it
composes cleanly with WebMock's block-all policy, **including in browser-driven
system tests** (the mock lives in the shared server process). Add a small test
helper to build a GitHub auth hash (uid / nickname / verified primary email).

- `[system]` — the flows (browser-driven Capybara, per the non-negotiable rule):
  1. New visitor clicks **Continue with GitHub** on sign-up → lands on
     dashboard, account exists, `verified_at` set, no verification email sent.
  2. Existing password user (fixture) signs in via GitHub with a matching
     verified email → linked (`github_uid` set) → dashboard.
  3. At capacity (cap constants, never hard-coded numbers): GitHub sign-up →
     waitlist notice, no session, `WaitlistSignup` row exists.
  4. GitHub account with no verified email → back on sign-in with the friendly
     alert, no account created.
  5. Keyless instance: no GitHub button on sign-in or sign-up.
- `[request]` — callback branches: uid match, email link, refused relink
  (different uid), waitlist race, unverified email, disabled → opaque 404,
  `/auth/failure`, rate limit.
- `[unit]` — `Github::Identification` matching-policy table; `WaitlistSignup.join`
  extraction keeps `Signup`'s existing tests green.
- `/verify` before shipping: click through the real flow in dev with OmniAuth's
  developer/test shim.

## 11 · Build plan (one PR, reviewable in order)

1. Gems + initializer (config gate, middleware registration) + `.env.example`.
2. Migration (two columns + partial unique index; reversible).
3. `WaitlistSignup.join` extraction (pure refactor, existing suite green).
4. `Github::Identification` + unit tests (TDD).
5. Routes + `Sessions::OmniauthsController` + request tests.
6. Views (buttons, divider, gating) + system tests.
7. `/code-review`, `/security-review` (§8), `/verify`; update
   `README.md` §2 (amended lock) + §3 (User columns).

## 12 · Open decisions (owner) — each with a recommendation

1. **Ship at all?** This spec exists to explore; the counter-argument is that
   email+password shipped and works, and every added door is auth surface.
   **Recommendation: ship** — audience fit (§1) is unusually strong and the
   surface is one provider, config-gated, token-discarding.
2. **Auto-link by verified email (§6.3.2) vs. always-create-separate-account.**
   Auto-link is the smooth path for the common case (user signed up with
   password, later clicks GitHub). **Recommendation: auto-link** — GitHub's
   email verification makes it sound, and the refusal rule covers the edge.
3. **Waitlist-mode sign-up page hides the button (§9)** vs. showing it and
   letting the coordinator waitlist. **Recommendation: hide** — one honest CTA
   at capacity.
4. **Connected-accounts settings UI (link/unlink) now or later?**
   **Recommendation: later.** Auto-link covers linking; unlinking a GitHub-only
   user is a lockout footgun (their password is random) that deserves its own
   small spec (likely: unlink requires a usable password first). Note the
   `github_username` chip could ship read-only in Settings for cheap.
5. **Also offer "Sign in with GitHub" on the managed instance's marketing
   nav?** Out of scope here; the nav already routes to sign-in.

---

*Once §12 is resolved, re-stamp this spec "ready to build" and follow §11.*
