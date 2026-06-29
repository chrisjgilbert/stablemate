# Stablemate

**Dead simple cron monitoring for Rails applications.** One promise: *a scheduled
job stops running, we email you.*

Stablemate watches your Solid Queue recurring jobs (and any ActiveJob backend) via
a companion gem that auto-registers heartbeat monitors from `config/recurring.yml`
— no per-job code. If a job misses its expected window, you get an email.

- **Free and self-hostable** — run your own instance; it's open source (AGPLv3).
  See [`docs/install.md`](docs/install.md).
- **Or let us host it** — a paid managed version for teams who'd rather not run
  the ops.

## Documentation

- Product spec: [`docs/PRD.md`](docs/PRD.md)
- Roadmap: [`docs/roadmap.md`](docs/roadmap.md)
- Self-hosting / install: [`docs/install.md`](docs/install.md)
- Companion gem: [`gem/README.md`](gem/README.md)

## License

The Stablemate **server application** is licensed under the **GNU Affero General
Public License v3.0** (AGPL-3.0) — see [`LICENSE`](LICENSE).

The **companion gem** (in [`gem/`](gem/)) is licensed under the more permissive
**MIT License** — see [`gem/LICENSE`](gem/LICENSE) — so it can be embedded freely
in any Rails app, including closed-source ones.

Copyright (C) 2026 Chris Gilbert.
