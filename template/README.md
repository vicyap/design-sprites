# Design Sprites v3.5 — template app

Next.js 15 + React 19 + TypeScript, Drizzle/SQLite, append-only verbatim
record, chat + question-card UI (single / multi / preview questions —
preview variants are sandboxed, script-free HTML snippets with slider
dials), deterministic state machine, MCP server (Streamable HTTP at
`/mcp`). Dark/light always follows the system `prefers-color-scheme`
(theme tokens only; no toggle or setting). **No AI calls and no `conn:*`
labels** — the interviewer is an external driver (Muse / Claude Code)
connected over MCP.

- Develop: `npm install && npm run dev` (port 8080)
- Verify: `npm run typecheck && npm test && npm run build` (Node 24)
- Deploy to a Fly Sprite: see `DEPLOY.md` — including the hard rule to
  never ship a tarball containing `data/`.
- Drive it: see `../SKILL.md`.
