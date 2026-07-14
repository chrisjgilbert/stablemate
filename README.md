# Stablemate

**Dead simple job monitoring for Rails applications.** One promise: *a scheduled
job stops running, we email you.*

Stablemate watches your Solid Queue recurring jobs (and any ActiveJob backend) via
a companion gem that auto-registers heartbeat monitors from `config/recurring.yml`
— no per-job code. If a job misses its expected window, you get an email.

- **Free and self-hostable** — run your own instance; it's open source (AGPLv3).
  See [`docs/install.md`](docs/install.md).
- **Or let us host it** — a paid managed version for teams who'd rather not run
  the ops.

## Documentation

- Locked decisions & data model: [`docs/specs/README.md`](docs/specs/README.md)
- Self-hosting (Docker / compose): [`docs/install.md`](docs/install.md)
- Integrating your jobs (gem + ping URLs): [`docs/integrating.md`](docs/integrating.md)
- Companion gem: [`gem/README.md`](gem/README.md)

## License

The Stablemate **server application** is licensed under the **GNU Affero General
Public License v3.0** (AGPL-3.0) — see [`LICENSE`](LICENSE).

The **companion gem** (in [`gem/`](gem/)) is licensed under the more permissive
**MIT License** — see [`gem/LICENSE`](gem/LICENSE) — so it can be embedded freely
in any Rails app, including closed-source ones.

Copyright (C) 2026 Chris Gilbert.
