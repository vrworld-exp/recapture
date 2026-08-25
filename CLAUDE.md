# CLAUDE.md

The conventions and project-context for this repo live in **[AGENTS.md](./AGENTS.md)**.

That file is the single source of truth for both codebases (the Flutter client at
the repo root and the Node/TS backend in `recapture-api/`): stack decisions,
folder layout, the API response envelope, config/secrets rules, the data-layer
and rate-limiting patterns, PII/logging rules, the analytics seam, client
foundations, and testing conventions.

**Read [AGENTS.md](./AGENTS.md) first.** When a task prompt disagrees with a
foundational convention, AGENTS.md wins. Keep it updated when conventions change.
