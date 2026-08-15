# Stablemate API reference

Two surfaces, and two credentials:

- **The check-in endpoint** — `POST /api/v1/monitors/:registration_key/pings`,
  authenticated with a **ping key**, the hot path your jobs hit.
- **`/api/v1` management** — a small JSON API authenticated with an **API key**,
  which the companion gem uses to register and read monitors.

The two keys are separate on purpose: a ping key can only check in, so a key
sitting in every one of your app's containers cannot read your monitors or
register new ones. See [`integrating.md`](integrating.md) for how to issue both.

Base URL in production: `https://stablemate.dev`.

---

## 1 · Check-in endpoint

```
POST /api/v1/monitors/:registration_key/pings
Authorization: Bearer sm_ping_...
```

The `registration_key` is your task's own name — the key from `recurring.yml` or
`c.monitors`. It is **not** a secret: the credential is the ping key in the
`Authorization` header, which keeps it out of request logs (Rails logs paths
verbatim and filters only query strings).

**`POST` only.** A check-in advances the monitor's clock and, on a monitor that
is down, resolves the incident and sends a "recovered" email — so anything that
merely follows a link (chat previews, mail prefetch, scanners) must not be able
to fire one.

Task names containing dots (`reports.daily`) and spaces are supported; URL-encode
the segment.

### Body params

Form-encoded or JSON.

| Param | Type | Meaning |
|---|---|---|
| `status` (alias `s`) | string | Optional exit code. Blank/absent/`0` = success; **anything else = failure**. `status` wins if both spellings are sent. |
| `message` (alias `m`) | string | Optional error text. Recorded only on failures; truncated to 1,000 chars. Ignored on success check-ins. |
| `duration_ms` | integer | Optional run latency, recorded on the check-in. Non-numeric and out-of-range values are ignored. |

A failure check-in (`status` non-zero) is an **error notice**: it flips a live
monitor `down` immediately — no grace wait — and the down email carries the
`message` (or `exited with status <n>` when no message is sent). A failure
while the monitor is already down is recorded but never re-alerts. See
[`integrating.md`](integrating.md) §2 for the cron pattern.

### Responses

| Status | Body | When |
|---|---|---|
| `200` | `{"ok":true}` | Known key and task. Records the check-in; transitions `pending→up` / `down→up`, or `→down` on a failure. |
| `401` | `{"error":"unauthorized"}` | Missing, unknown or revoked ping key. **Opaque** — identical for all three. |
| `404` | `{"error":"not_found"}` | Authenticated, but no such task in that key's project. **Opaque** — never reveals whether a monitor exists. |
| `429` | `{"error":"rate_limited"}` | Over the rate limit (see below). |

### Rate limiting

Two layers, so one noisy task cannot consume another's budget — generous enough
that **no real cron cadence is ever throttled** (the tightest sane schedule is
once a minute):

- **Per monitor:** 30 check-ins / minute, counted per key *and* task.
- **Per IP:** 300 requests / minute, applied to every attempt including
  unauthenticated ones. This bounds scanning, and is silent: an unknown key
  always returns the opaque `401`.

---

## 1a · Verify endpoint

```
GET /api/v1/verify
Authorization: Bearer sm_ping_...
```

Proves a ping key works without recording a check-in — what `stablemate:install`
uses to fail fast on a bad credential. `200 {"ok":true}` for a valid ping key;
an opaque `401` for an API key, a bad key, or no key. Bounded by its own per-IP
limit.

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
    { "registration_key": "daily_digest", "status": "pending" }
  ],
  "skipped": [
    { "registration_key": "nightly_report", "reason": "limit_reached" }
  ],
  "orphaned": [ "old_report" ],
  "retired": [],
  "ping_key_last4": [ "ab12", "cd34" ]
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

Three more informational keys ride along, all safe to ignore:

| Key | Meaning |
|---|---|
| `orphaned` | `registration_key`s this project holds that matched no entry in *this app's* payload — a renamed or removed task. Reported only; nothing is deleted. |
| `retired` | The subset actually retired, on a request carrying `prune: true` **and** a `declared_keys` list. Retiring is reversible: state and history are kept, and the next sync that includes the key revives the monitor. A prune request without `declared_keys` retires nothing. |
| `ping_key_last4` | The last four characters of every **live** ping key in this project. A client holding both credentials can compare its configured ping key against this set and warn when the two keys name different projects — an array, because rotation keeps two keys live at once. Empty means the project has no ping key at all. |

### Rotating the check-in credential

There is no per-monitor rotation endpoint. The check-in credential is a
**project-scoped ping key**, not a per-monitor token, so rotation happens on the
project's page: issue a new ping key, roll it out, then revoke the old one.
Both stay live in the meantime, which is what makes a zero-downtime rotation
possible — and why `ping_key_last4` above is an array.

---

## 3 · Accounts & the launch waitlist

New sign-ups are capped at the launch account limit (`SIGNUP_ACCOUNT_CAP`). When
the cap is reached the sign-up screen switches to **waitlist mode**: it captures an
email only (no account, no password) and the cap re-opens manually when the limit
is raised. This affects the web UI only; there is no public account-creation API.
