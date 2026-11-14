# design-sprites

A design sprite is a standalone web app (Next.js + TypeScript) that hosts one design Project: an append-only verbatim record, a chat + question-card UI, and a deterministic state machine with an MCP server — and **no built-in AI**. The interviewer is an external agent (Muse or Claude Code) driving the sprite over MCP: predicting every answer, asking only where its guess is weak, judging each prediction hit or miss, and re-deriving a living decision model (`model.md`) from the verbatim record. When the deterministic sharpness gate passes, the driver declares the model sharp; the human presses Commit, and the deliverable (model, record, transcript) freezes as an exportable bundle.

v3.5 adds a `preview` question type (2–4 sandboxed, script-free HTML-snippet variants plus slider dials, driven through the same MCP turn protocol) and makes dark/light always follow the OS/browser `prefers-color-scheme` — theme tokens only, no toggle or setting.

**The skill is [SKILL.md](SKILL.md)** — read it, or hand it to any coding agent: `Read vicyap/design-sprites/SKILL.md`.

Layout:

- `SKILL.md` — the canonical skill (v3.5; copy-paste ready).
- `brief.md` — the founding brief (v1, 2026-11-11), kept verbatim for the record; where it describes rounds, submit, or email, SKILL.md (v3.5) supersedes it.
- `template/` — the v3.5 sprite app template (Next.js 15 + React 19 + TypeScript; Drizzle + SQLite on the sprite disk; MCP over Streamable HTTP; app `design_sprite`, version 3.5.1-p1), including its `DEPLOY.md` runbook. v3.5 sprites need **no `conn:*` labels** — the app makes no AI calls.
- `.claude/skills/design-sprites/SKILL.md` — a symlink to the root `SKILL.md`, so Claude Code sessions mounting this repo discover the skill automatically. One canonical file; the link never drifts.

History: v2 (Elixir + Phoenix + Ash, built-in AI via the Sprites gateway) was published from this repo at commit `5a094fb`; the v2 template is preserved in git history. v3 (commit `49df7f5`) superseded it: the design-artifact surface moves to a future v4, and v2 sprites migrate to v3 in place with their artifact versions carried forward as preserved files. v3.5 supersedes v3 with the preview question type and system-follow dark/light; v3 sprites upgrade to v3.5 by app-only redeploy, records untouched. v3.5.1 (mobile hotfix) fixes the phone layout — the answer pane is a fixed overlay sheet on small screens instead of squeezing the thread — and question cards now show an Answered/Skipped status word (status only, no answer content).
