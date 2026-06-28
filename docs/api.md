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
| `duration_ms` | integer | Optional run latency, recorded on the ping. Non-numeric values are ignored. |

### Responses

| Status | Body | When |
|---|---|---|
| `200` | `{"ok":true}` | Known token. Records the ping; transitions `pending→up` / `down→up`. |
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

Generate a key in **Settings → API keys** (shown once). All endpoints are
**tenant-scoped** to the key's owner. Auth failures and cross-tenant access are
opaque:

| Status | When |
|---|---|
| `401 {"error":"unauthorized"}` | Missing / malformed / invalid / revoked key. |
| `404 {"error":"not_found"}` | Unknown **or foreign** monitor id (no existence leak). |

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

Idempotent upsert keyed on `(owner, registration_key)`. Monitors created this way
get `source: "gem"`. Respects the per-account monitor cap: entries over the cap are
returned in `skipped`, not an error.

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
  "skipped": []
}
```

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
