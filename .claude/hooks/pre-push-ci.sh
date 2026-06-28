#!/bin/bash
# PreToolUse hook: gate `git push` on a green CI run.
#
# Wired to the Bash tool. It inspects the command Claude is about to run; if it's
# a `git push`, it runs bin/ci first and BLOCKS the push (exit 2) when CI fails.
# Every other command passes straight through. Commits are intentionally NOT
# gated — they stay fast during the TDD loop; push is the publish boundary.
#
# Exit codes (PreToolUse contract): 0 = allow, 2 = block (stderr shown to Claude).
set -uo pipefail

input=$(cat)

# Pull tool name + command out of the hook JSON without assuming jq is present.
read -r tool_name command <<EOF
$(printf '%s' "$input" | ruby -rjson -e '
  d = JSON.parse(STDIN.read) rescue {}
  ti = d["tool_input"] || {}
  puts "#{d["tool_name"]}\t#{(ti["command"] || "").gsub(/\s+/, " ").strip}"
' 2>/dev/null)
EOF

# Only care about Bash `git push` invocations.
case "$tool_name" in
  Bash) ;;
  *) exit 0 ;;
esac
# Match `git push` only when `push` is the git SUBCOMMAND at a command position —
# command start or right after a shell separator (; && || | &  or an opening
# paren). This avoids false positives like `git config push.default`, `git help
# push`, or `echo "git push"`, which must not trigger a CI run / block.
# (Trade-off: rare global-option forms such as `git -C dir push` are not gated.)
if ! printf '%s' "$command" | grep -Eq '(^|[;&|(])[[:space:]]*git[[:space:]]+push([[:space:];&|)]|$)'; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

# No CI to run yet (app not scaffolded) → don't block.
if [ ! -x bin/ci ]; then
  exit 0
fi

echo "[pre-push-ci] git push detected — running bin/ci before allowing the push…" >&2
if bin/ci >&2; then
  echo "[pre-push-ci] CI passed — allowing push." >&2
  exit 0
else
  echo "" >&2
  echo "[pre-push-ci] ✗ CI FAILED — push blocked. Fix the failing tests/linter (run bin/ci) and try again." >&2
  exit 2
fi
