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

# --- Ruby gems -------------------------------------------------------------
if [ -f Gemfile ]; then
  if command -v bundle >/dev/null 2>&1; then
    log "Installing gems (bundle install)…"
    # bundle install (not 'ci') so the cached container layer is reused.
    bundle install --jobs 4 --retry 3
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
