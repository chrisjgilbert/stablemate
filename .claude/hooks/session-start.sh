#!/bin/bash
# SessionStart hook for Claude Code on the web.
# Prepares the Stablemate Rails app so tests and linters work immediately:
# installs gems and prepares the database. Defensive by design — the repo starts
# as docs only (no app scaffolded yet), so every step is guarded and the hook
# never fails a session just because the app isn't there yet.
set -euo pipefail

# Only run in the remote (web) environment; local devs manage their own setup.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

log() { echo "[session-start] $*"; }

# --- PostgreSQL helpers ----------------------------------------------------
# The web container ships a Postgres cluster but may leave it stopped, and the
# default config/database.yml connects over the socket as the OS user (no
# username set), so a matching login role must exist. These bring both up so
# db:prepare — and the pre-push bin/ci hook — work without manual steps. All
# steps are best-effort: a failure warns and the session continues.

# Run psql as the postgres superuser. Bootstrap path: the OS user has no role
# yet, so we can't connect as ourselves until ensure_db_role has run.
pg_admin() {
  if command -v sudo >/dev/null 2>&1; then
    sudo -u postgres psql "$@"
  else
    su -s /bin/sh -c "psql $*" postgres
  fi
}

pg_ready() { pg_isready -q >/dev/null 2>&1; }

ensure_postgres_running() {
  command -v pg_isready >/dev/null 2>&1 || return 0

  if pg_ready; then
    log "PostgreSQL already running."
    return 0
  fi

  log "PostgreSQL not running — starting it…"
  if command -v pg_lsclusters >/dev/null 2>&1 && command -v pg_ctlcluster >/dev/null 2>&1; then
    # Debian/Ubuntu packaging: start every stopped cluster (pg_ctlcluster VER NAME).
    pg_lsclusters 2>/dev/null | awk 'NR>1 && $4 ~ /down/ { print $1, $2 }' | \
      while read -r ver name; do
        pg_ctlcluster "$ver" "$name" start >/dev/null 2>&1 || true
      done
  elif command -v service >/dev/null 2>&1; then
    service postgresql start >/dev/null 2>&1 || true
  fi

  # Bounded wait for the socket to accept connections.
  for _ in $(seq 1 15); do
    pg_ready && break
    sleep 1
  done

  if pg_ready; then
    log "PostgreSQL is up."
  else
    log "WARNING: could not start PostgreSQL; db:prepare may fail."
  fi
}

ensure_db_role() {
  pg_ready || return 0
  # Peer/socket auth maps the OS user to a same-named role; create it (superuser,
  # so db:create/migrate work) if absent. Idempotent.
  local role="${PGUSER:-$(id -un)}"
  if pg_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname = '${role}'" 2>/dev/null | grep -q 1; then
    return 0
  fi
  log "Creating PostgreSQL login role '${role}'…"
  pg_admin -c "CREATE ROLE \"${role}\" WITH LOGIN SUPERUSER;" >/dev/null 2>&1 \
    || log "WARNING: could not create role '${role}'; db:prepare may fail."
}

# --- Ruby gems -------------------------------------------------------------
if [ -f Gemfile ]; then
  if command -v bundle >/dev/null 2>&1; then
    log "Installing gems (bundle install)…"
    # bundle install (not 'ci') so the cached container layer is reused.
    # Non-fatal (consistent with db:prepare below): a transient failure warns
    # rather than aborting the whole session-start hook.
    bundle install --jobs 4 --retry 3 || log "WARNING: bundle install failed; continuing."
  else
    log "Gemfile present but bundler not found; skipping gem install."
  fi
else
  log "No Gemfile yet — app not scaffolded. Skipping Ruby setup."
fi

# --- JS deps (only if the app uses a node toolchain) -----------------------
if [ -f package.json ] && command -v npm >/dev/null 2>&1; then
  log "Installing JS deps (npm install)…"
  npm install --no-audit --no-fund
fi

# --- Database --------------------------------------------------------------
# Prepare the dev + test DBs so the suite can run. Non-fatal: if Postgres isn't
# reachable in this environment, we warn rather than break the session.
if [ -f bin/rails ] && [ -f config/database.yml ]; then
  # Make sure the server is up and a login role exists before db:prepare.
  if command -v psql >/dev/null 2>&1; then
    ensure_postgres_running
    ensure_db_role
  fi

  log "Preparing databases (bin/rails db:prepare)…"
  if ! bin/rails db:prepare; then
    log "WARNING: db:prepare failed (is PostgreSQL running?). Continuing."
  fi
  if ! RAILS_ENV=test bin/rails db:prepare; then
    log "WARNING: test db:prepare failed. Continuing."
  fi
else
  log "No bin/rails yet — skipping database preparation."
fi

# --- Browser for system tests ---------------------------------------------
# Browser-driven Capybara system tests are mandatory (see CLAUDE.md). Chromium is
# preinstalled via Playwright — surface its presence; never run 'playwright install'.
if [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ] && [ -d "${PLAYWRIGHT_BROWSERS_PATH}" ]; then
  log "Chromium available at \$PLAYWRIGHT_BROWSERS_PATH for system tests."
else
  log "NOTE: \$PLAYWRIGHT_BROWSERS_PATH not set; ensure a headless browser exists for system tests."
fi

log "Done."
