# design-sprites

A design sprite is a standalone web app (Elixir + Phoenix + Ash) that runs a design interview like an eye exam: it arrives with a predicted decision model, asks only where its guess is weak, and sharpens the model round by round until the human says they can see clearly. The output is a prescription — the finished decision model — plus a versioned design deliverable a coding agent can implement.

**The skill is [SKILL.md](SKILL.md)** — read it, or hand it to any coding agent: `Read vicyap/design-sprites/SKILL.md`.

Layout:
- `SKILL.md` — the canonical skill (copy-paste ready).
- `brief.md` — the original design brief the skill was built from.
- `template/` — the sprite app template (Phoenix LiveView + Ash + SQLite).
- `.claude/skills/design-sprites/SKILL.md` — a byte-identical copy of `SKILL.md` so Claude Code sessions mounting this repo discover the skill automatically. Regenerate it whenever `SKILL.md` changes (`cp SKILL.md .claude/skills/design-sprites/SKILL.md`).
