# Stablemate API reference

Two surfaces:

- **The ping endpoint** — public, token-authenticated, the hot path your jobs hit.
- **`/api/v1`** — a small JSON API (Bearer-authed with an API key) the companion
  gem uses to register and read monitors.

Base URL in production: `https://stablemate.dev`.

---

## 1 · Ping endpoint (public)

```
GET  /ping/:ping_token
POST /ping/:ping_token
```

The `ping_token` **is** the credential — there is no API key or header on this
path. `GET` and `POST` behave identically (a bare `curl` works).

### Query params

| Param | Type | Meaning |
|---|---|---|
| `status` (alias `s`) | string | Optional exit code. Blank/absent/`0` = success; **anything else = failure**. `status` wins if both spellings are sent. |
| `message` (alias `m`) | string | Optional error text. Recorded only on failures; truncated to 1,000 chars. Ignored on success pings. |
| `duration_ms` | integer | Optional run latency, recorded on the ping. Non-numeric values are ignored. |

A failure ping (`status` non-zero) is an **error notice**: it flips a live
monitor `down` immediately — no grace wait — and the down email carries the
`message` (or `exited with status <n>` when no message is sent). A failure
while the monitor is already down is recorded but never re-alerts. See
[`integrating.md`](integrating.md) §2 for the cron pattern.

### Responses

| Status | Body | When |
|---|---|---|
| `200` | `{"ok":true}` | Known token. Records the ping; transitions `pending→up` / `down→up`, or `→down` on a failure ping. |
| `404` | — | Unknown token. **Opaque** — never reveals whether a token/monitor exists. |
| `429` | — | Over the rate limit (see below). |

### Rate limiting

The endpoint is rate-limited so a misconfigured tight loop or a token scan can't
overwhelm it — but generously enough that **no real cron cadence is ever
throttled** (the tightest sane schedule is once a minute):

- **Per token:** 30 pings / minute. Over-limit → `429`.
- **Per IP:** 300 requests / minute, applied to all ping attempts (including
  unknown tokens). This bounds token-enumeration scanning. It is silent: an
  unknown token always returns the opaque `404`, never a signal that distinguishes
  a real token from a fake one.

---

## 2 · `/api/v1` (Bearer-authed)

Used by the gem. Authenticate with an API key:

```
Authorization: Bearer sm_live_xxxxxxxxxxxxxxxxxxxx
```

Generate a key on a **project's page** (Projects → the project → *Generate key*).
The raw key is shown exactly once, at creation; only its digest and last 4 chars
are stored, so a lost key is replaced, never recovered. Revoke takes effect
immediately.

A key belongs to **one project** and *is* that app's identity, so every endpoint
is **project-scoped**: it sees only that project's monitors. Another project of
the same account is as invisible as another account's — an id from it is the same
opaque `404`. (The monitor cap itself stays per-account, across all your
projects.) Auth failures and cross-project access are opaque:

| Status | When |
|---|---|
| `401 {"error":"unauthorized"}` | Missing / malformed / invalid / revoked key. |
| `404 {"error":"not_found"}` | Unknown **or foreign** monitor id (no existence leak). |
| `429 {"error":"rate_limited"}` | Over a rate limit (see below). |

### Rate limiting

Two layers, both generous enough never to throttle a healthy gem cadence, and
both answering `429 {"error":"rate_limited"}`:

- **Per key:** 120 requests / minute for one bearer token.
- **Per IP:** 300 requests / minute for one client, whatever token it presents.
  This is the layer that bounds enumeration, since the token is caller-supplied;
  it applies before authentication, so `401`s count towards it too.

Unlike the ping endpoint, the `429` here is plain: every auth failure already
answers with an identical `401` whether or not the token exists, so a throttle
response gives away nothing about a token — and a client sharing an egress IP
needs an honest `429` to back off on.

### List monitors

```
GET /api/v1/monitors
```

```json
{
  "monitors": [
    {
      "id": 1,
      "name": "daily_digest",
      "status": "up",
      "registration_key": "daily_digest",
      "ping_url": "https://stablemate.dev/ping/<token>",
      "last_ping_at": "2026-06-28T09:00:01Z",
      "next_due_at": "2026-06-29T09:00:00Z"
    }
  ]
}
```

### Show a monitor

```
GET /api/v1/monitors/:id
```

Returns the list fields plus `source`, `expected_interval_seconds`,
`grace_period_seconds`, and `uptime_percent`.

### Sync (bulk upsert)

```
POST /api/v1/monitors/sync
```

Idempotent upsert keyed on `(project, registration_key)` — the project is the one
the key belongs to, so the same `registration_key` in two of your projects is two
separate monitors. Monitors created this way get `source: "gem"`; an entry
matching an existing monitor updates its name/interval/grace instead.

The call is always a **graceful partial**: a bad or over-cap entry never fails the
request or half-applies the payload. Entries the sync could not register come back
under `skipped`, and monitors absent from the payload are left alone (nothing is
auto-deleted).

Request:

```json
{
  "app": "my-app",
  "monitors": [
    {
      "registration_key": "daily_digest",
      "name": "daily_digest",
      "expected_interval_seconds": 86400,
      "grace_period_seconds": 3600
    }
  ]
}
```

Response:

```json
{
  "monitors": [
    { "registration_key": "daily_digest",
      "ping_url": "https://stablemate.dev/ping/<token>",
      "status": "pending" }
  ],
  "skipped": [
    { "registration_key": "nightly_report", "reason": "limit_reached" }
  ]
}
```

`monitors` lists every entry that was registered (created **or** updated).
`skipped` lists the rest, one object per entry, each with the entry's
`registration_key` and a `reason`:

| `reason` | Meaning |
|---|---|
| `limit_reached` | Your account is at its monitor cap and this would have been a *new* monitor. Updates to monitors that already exist are always applied, even at the cap. |
| `invalid` | The entry itself was rejected — its `expected_interval_seconds` / `grace_period_seconds` are missing or out of range, or the monitor failed to save. |

Treat the vocabulary as open: log an unrecognised `reason` rather than matching
exhaustively. An entry with no `registration_key` is ignored entirely — there is
nothing to report it under — so always send one.

### Rotate a ping token

```
POST /api/v1/monitors/:id/rotate
```

Generates a new `ping_token` and invalidates the old ping URL immediately.

---

## 3 · Accounts & the launch waitlist

New sign-ups are capped at the launch account limit (`SIGNUP_ACCOUNT_CAP`). When
the cap is reached the sign-up screen switches to **waitlist mode**: it captures an
email only (no account, no password) and the cap re-opens manually when the limit
is raised. This affects the web UI only; there is no public account-creation API.
