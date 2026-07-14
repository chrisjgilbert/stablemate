# Contributing to Stablemate

Stablemate is a deliberately boring, idiomatic, vanilla Rails app. The full
engineering conventions live in [`CLAUDE.md`](CLAUDE.md) and the locked decisions
in [`docs/specs/README.md`](docs/specs/README.md). This file is the short version
for committers.

## Branch & history

We keep `main` a **clean, linear history**. No merge bubbles, no "wip" noise.

- **Branch off `main`**, do your work, open a PR.
- **Rebase, don't merge.** Keep up to date with `git pull --rebase` (set
  `git config pull.rebase true`). Never merge `main` into your branch.
- **Squash where possible.** Tidy your branch before merge so it reads as one or a
  few deliberate commits:
  ```sh
  git commit --fixup <sha>          # while iterating
  git rebase -i --autosquash main   # collapse fixups before review/merge
  ```
- **Merge style:** squash-merge (or fast-forward) so `main` stays linear. No merge
  commits.
- **Force-push only your own feature branch**, after a rebase. Never `main`.

## Commits

- Imperative subject (~50 chars), blank line, body explaining the *why*.
- Each commit builds and passes `bin/ci` on its own.

## Before you push

`git push` is gated: a hook runs **`bin/ci`** (rubocop, brakeman/bundle-audit,
`rails test`, and `rails test:system`) and **blocks the push if it's red**. The
same `bin/ci` runs in GitHub Actions. So: run `bin/ci` early and often.

- **System tests are non-negotiable.** Every key user-facing flow ships a
  browser-driven Capybara system test (see the rule in [`CLAUDE.md`](CLAUDE.md)).
  A PR adding a user-facing flow without its system test gets sent back.
- Run `/code-review` on your diff, and `/security-review` when touching auth,
  tokens, the ping endpoint, the API, or rate-limiting.

## Architecture in one line

Keep `app/` small, put logic on records, **no `app/services/`**. Use operation
objects / concerns / sub-resource controllers per the decision table in
[`CLAUDE.md`](CLAUDE.md). Deviate only with a one-line justification.
