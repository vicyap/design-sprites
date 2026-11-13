# design-sprites

A design sprite is a standalone web app (Elixir + Phoenix + Ash) that hosts one design Project: the sprite's own AI interviews the human in a single chat thread — predicting every answer, asking only where its guess is weak, scoring each prediction hit or miss, and re-deriving a living decision model (`model.md`) from the verbatim record — while generating and patching a versioned HTML design artifact in the same stream. When recent predictions on load-bearing questions all hit, the AI declares the model sharp; the human presses Commit, and the deliverable (model, artifacts, transcript) freezes as an exportable bundle.

**The skill is [SKILL.md](SKILL.md)** — read it, or hand it to any coding agent: `Read vicyap/design-sprites/SKILL.md`.

Layout:
- `SKILL.md` — the canonical skill (v2; copy-paste ready).
- `brief.md` — the founding brief (v1, 2026-11-11), kept verbatim for the record; where it describes rounds, submit, or email, SKILL.md (v2) supersedes it.
- `template/` — the v2 sprite app template (Phoenix LiveView + Ash + SQLite; app `design_sprite`), including its `DEPLOY.md` runbook and synced `AGENTS.md` usage rules.
- `.claude/skills/design-sprites/SKILL.md` — a symlink to the root `SKILL.md`, so Claude Code sessions mounting this repo discover the skill automatically. One canonical file; the link never drifts.
