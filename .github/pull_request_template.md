## What & why

<!-- One or two sentences: what this changes and the reason. Link the phase spec
     (docs/specs/) or issue. -->

## History hygiene

- [ ] Rebased on latest `main` — **linear history, no merge commits**
- [ ] WIP/fixup commits **squashed** into deliberate, self-contained commits
- [ ] This PR will be **squash-merged** (or fast-forwarded) to keep `main` linear

## Checks

- [ ] `bin/ci` is green locally (rubocop, brakeman/bundle-audit, `rails test`, `rails test:system`)
- [ ] **Browser-driven system tests** added/updated for any new user-facing flow
      (see the phase spec's "Required system tests")
- [ ] `/code-review` run on the diff; `/security-review` run if this touches auth,
      tokens, the ping endpoint, the API, or rate-limiting
- [ ] Any deviation from `CLAUDE.md` conventions has a one-line justification
