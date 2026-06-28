# Operations runbook

For the production Stablemate deployment (Kamal → Hetzner, PostgreSQL on the box).
Covers database backup/restore, redeploys, and email deliverability (SPF/DKIM).

---

## 0 · Pre-launch checklist

Do these before opening sign-ups. (Feature backlog beyond V1 lives in
[`roadmap.md`](roadmap.md), not here.)

- [ ] **SMTP credentials set** — `bin/rails credentials:edit` (`smtp.address`,
      `port`, `user_name`, `password`). Production fails loud at first send if
      unset (no silent fallback). See §2.
- [ ] **Deliverability verified** — SPF/DKIM/DMARC published and a real `down`
      email lands in an inbox (not spam). See §2 "Verify".
- [ ] **Backups running** — the nightly `pg_dump` cron is installed and a restore
      has been rehearsed once. See §1.
- [ ] **Dog-fooding on** — Stablemate is monitoring its own recurring jobs via
      the gem. See §3.
- [ ] **Rate limiter (optional)** — the ping limiter uses a per-process
      `MemoryStore` (coarse bound, kept off the hot path). If a precise *global*
      limit is wanted, move it to Solid Cache (accepting a per-ping cache round
      trip). Documented in `app/controllers/pings_controller.rb`.

---

## 1 · PostgreSQL backup & restore

PostgreSQL runs as a container on the Hetzner host (managed by Kamal accessories).
Data lives on a host-mounted volume. Backups are logical dumps with `pg_dump`.

### 1.1 Backup cadence

- **Nightly** full logical dump, retained 14 days.
- **Weekly** dump copied off-box to object storage, retained 8 weeks.

Cron on the host (adjust container name / db name to your Kamal config):

```sh
# /etc/cron.d/stablemate-backup  — nightly at 03:15 UTC
15 3 * * * root /usr/local/bin/stablemate-pg-backup.sh
```

```sh
#!/usr/bin/env bash
# /usr/local/bin/stablemate-pg-backup.sh
set -euo pipefail
ts="$(date -u +%Y%m%dT%H%M%SZ)"
dir="/var/backups/stablemate"; mkdir -p "$dir"

# Dump from inside the db accessory container.
docker exec stablemate-db \
  pg_dump -U stablemate -Fc stablemate_production \
  > "$dir/stablemate-$ts.dump"

# Prune local dumps older than 14 days.
find "$dir" -name 'stablemate-*.dump' -mtime +14 -delete

# Weekly off-box copy (Sundays).
if [ "$(date -u +%u)" = "7" ]; then
  rclone copy "$dir/stablemate-$ts.dump" remote:stablemate-backups/
fi
```

`-Fc` (custom format) is compressed and restorable selectively with `pg_restore`.

### 1.2 Restore

```sh
# 1. Stop the app so nothing writes during restore (keep the db running).
kamal app stop

# 2. Copy the chosen dump into the db container.
docker cp /var/backups/stablemate/stablemate-<ts>.dump stablemate-db:/tmp/restore.dump

# 3. Drop & recreate the database, then restore.
docker exec stablemate-db dropdb   -U stablemate --if-exists stablemate_production
docker exec stablemate-db createdb -U stablemate stablemate_production
docker exec stablemate-db pg_restore -U stablemate -d stablemate_production /tmp/restore.dump

# 4. Bring the app back and verify health.
kamal app start
curl -fsS https://stablemate.dev/up    # expect 200
```

> Solid Queue / Cable / Cache tables live in the same database (Rails 8 defaults),
> so a single restore brings back jobs, recurring schedule state and cache. After
> a restore the recurring scheduler resumes on the next boot.

### 1.3 Redeploy (Kamal)

```sh
kamal deploy                 # build, push, roll out, run migrations
kamal app logs -f            # watch boot
curl -fsS https://stablemate.dev/up
```

Rollback to the previous release:

```sh
kamal rollback
```

---

## 2 · Email deliverability (SPF / DKIM / DMARC)

Alert emails (`down` / `recovered` / verification) are sent over SMTP from
`alerts@stablemate.dev` (reply-to `support@stablemate.dev`), configured in
`config/environments/production.rb` with credentials from
`bin/rails credentials:edit` (`smtp.address`, `port`, `user_name`, `password`).

For a `down` email to land in the inbox rather than spam, the sending domain must
publish these DNS records (values come from your SMTP provider's dashboard):

### SPF (TXT on `stablemate.dev`)

```
v=spf1 include:<provider-spf-domain> -all
```

### DKIM (CNAME or TXT, per the provider)

The provider gives you one or more selector records, e.g.:

```
<selector>._domainkey.stablemate.dev  CNAME  <selector>.dkim.<provider>.com
```

### DMARC (TXT on `_dmarc.stablemate.dev`)

Start in monitoring mode, tighten once SPF+DKIM align:

```
v=DMARC1; p=none; rua=mailto:dmarc@stablemate.dev; fo=1
```

### Verify

1. Send a test `down` email to an inbox you control (trigger an outage on a test
   monitor, or `MonitorMailer.down(monitor).deliver_now` from a console).
2. Check the received headers: `spf=pass`, `dkim=pass`, `dmarc=pass`.
3. Confirm it's in the inbox, not spam. Use a tool like mail-tester.com for a score.

The mailer's links use the host from `config.action_mailer.default_url_options`
(`stablemate.dev`), **not** the request — so detail links work in every email
regardless of where the mail was generated.

---

## 3 · Dog-fooding

Stablemate monitors its own recurring jobs (`DetectMissedPingsJob`,
`RollupUptimeJob`, `PrunePingEventsJob`) via the gem, so a failure in the
monitoring pipeline surfaces as a `down` alert on Stablemate itself.
