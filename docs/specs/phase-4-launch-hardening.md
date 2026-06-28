# Phase 4 — Launch Hardening & Polish

**Goal:** make Stablemate safe and pleasant to launch publicly — bound hosting
cost with a signup cap + waitlist, protect the ping endpoint, ensure email
deliverability, and ship docs. Dog-food it on Stablemate's own jobs.

PRD refs: §1 (caps/waitlist), §3.1a (WaitlistSignup), §5.1, §6.5 (rate-limit),
§7 Phase 4. Design refs: [`design-system.md`](design-system.md) — sign-up
at-capacity waitlist mode, at-limit monitor state, landing page.

---

## 1 · Scope & dependencies

**In:**
- **Launch signup cap + waitlist:** `SIGNUP_ACCOUNT_CAP` (100), `WaitlistSignup`
  model, and the sign-up screen's at-capacity mode.
- **Ping rate-limiting** per token (absorb misconfiguration/abuse).
- Abuse / opaque-error review (no tenant leakage anywhere).
- **Email deliverability:** SPF/DKIM setup docs + runbook; sane `from`/reply-to;
  verification-email polish.
- Dashboards/empty states polish; the marketing **landing page**.
- **Docs:** install guide (gem + manual), API reference, backup/restore runbook
  for the Hetzner box.

**Out:** payment/checkout/tiers (never in V1); anything from the V2 deferred list.

**Dependencies:** Phases 1–3 (this hardens what they built). The waitlist gate
sits in front of Phase 1's sign-up flow.

---

## 2 · Data model / migrations

- New table **`WaitlistSignup`** (README §4): `email_address` (unique),
  `created_at`. No login, no account.

---

## 3 · Behaviour & contracts

### 3.1 Signup cap → waitlist (PRD §3.1a, §5.1)
- When `User.count >= SIGNUP_ACCOUNT_CAP`, the sign-up flow switches to
  **waitlist mode**: the form captures an email into `WaitlistSignup` (unique;
  duplicate email is a friendly no-op success), **creates no User**, no password
  field, and shows "You're on the list — we'll email you an invite."
- Below the cap, normal sign-up proceeds (Phase 1).
- The cap is a config constant; raising it re-opens sign-ups **manually**
  (decision #7). No auto re-open.
- This is a **mode of the sign-up screen**, not a separate route.

### 3.2 Monitor at-limit treatment (PRD R3.3)
- The model cap is already enforced (Phase 1). Phase 4 polishes the UI: the New
  monitor action shows the at-limit state with an inline, matter-of-fact note
  ("You're at the 5-monitor limit for the Free plan"), and the dashboard shows
  "n / 5". **No upgrade/pricing UI** (nothing to link to).

### 3.3 Ping rate-limiting (PRD §6.5)
- Rate-limit `/ping/:ping_token` per token (e.g. Rails 8
  `rate_limit` / `Rack::Attack`), generous enough never to throttle legitimate
  cron cadence but bounding a misconfigured tight loop. Over-limit → `429`.
- Unknown token still → `404` (opaque), and is also rate-limited per IP to avoid
  token-enumeration scanning.

### 3.4 Deliverability & abuse review
- Configure SMTP `from`, SPF, DKIM (documented in the runbook); verify a `down`
  email lands in a real inbox (not spam) during dog-fooding.
- Audit every error path for tenant leakage: unknown ping token, foreign monitor
  id, invalid API key all return opaque `404`/`401` with no identifying detail.

### 3.5 Docs & runbook
- Install guide: gem path (initializer, API key, `recurring.yml`, `stablemate:sync`)
  and the manual `curl`/`Net::HTTP` path.
- API reference for `/api/v1` + the ping contract.
- Backup/restore runbook for the Hetzner PostgreSQL (pg_dump cadence, restore
  steps, Kamal redeploy).

---

## 4 · Test plan (write these first)

### Waitlist `[request]`/`[model]`/`[system]`
1. `freeze`/stub count at the cap: sign-up renders **waitlist mode** (email only,
   no password).
2. Submitting in waitlist mode creates a `WaitlistSignup`, **no `User`**, and
   shows the "on the list" success.
3. A duplicate waitlist email is a friendly success, not an error (unique index
   respected).
4. Below the cap, sign-up creates a `User` as normal (Phase 1 behaviour intact).
5. Raising `SIGNUP_ACCOUNT_CAP` re-opens normal sign-up.

### At-limit UI `[system]`
6. A user at 5 monitors sees the at-limit note on New monitor and "5 / 5" on the
   dashboard; no upgrade/pricing UI is present.

### Rate-limiting `[request]`
7. Pinging a token faster than the limit returns `429` after the threshold;
   normal cron cadence is never throttled.
8. Repeated unknown-token requests are rate-limited per IP and always return
   `404` (no leak, no enumeration signal).

### Abuse / opacity `[request]`
9. Unknown ping token → `404`; foreign monitor id → `404`; invalid API key →
   `401` — none reveal tenant/monitor existence.

### Deliverability `[mailer]`
10. `down`/`recovered` emails set a configured `from` and render a working detail
    link (host from config, not request).

---

## 5 · Acceptance criteria (PRD Phase 4 Exit)

- [ ] With the cap set low, the Nth+1 sign-up lands on the **waitlist** (no
      account created); raising the cap re-opens sign-ups.
- [ ] Ping endpoint is rate-limited; abuse paths are opaque.
- [ ] A real `down` email is delivered to a real inbox during dog-fooding (not
      spam); SPF/DKIM documented.
- [ ] Install guide, API reference, and backup/restore runbook exist.
- [ ] Stablemate is dog-fooded monitoring its own recurring jobs.
- [ ] All Test Plan scenarios pass; suite + linter green.

---

## 6 · Out of scope / guardrails
- No pricing tables, plan comparison, checkout, or upgrade flow — one Free plan,
  one cap, one waitlist gate.
- Nothing from the V2 deferred list (HTTP monitoring, public status pages, other
  registrar adapters, webhooks, teams, reminders, acknowledge, `/fail`).
