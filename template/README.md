# Design Sprites v3.7 — template app

Next.js 15 + React 19 + TypeScript, Drizzle/SQLite, append-only verbatim
record, chat + question-card UI (single / multi / preview questions —
preview variants are sandboxed, script-free HTML snippets with slider
dials), deterministic state machine, MCP server (Streamable HTTP at
`/mcp`). v3.6 UI: batch-answering flow (Next open question + "N of M
answered" header progress; the pane never auto-closes or auto-advances
on save), a sticky chat composer docked to the chat column, and mobile
round 2 (sticky Save bar in the answer pane; dial touch targets at
least 44px). v3.7 UI: a driver-presence banner (runtime heartbeat from
MCP activity / the ds-wake bridge; "a driver is attached — it will be
woken by your activity" while fresh, the waiting text otherwise),
answered questions stay fully editable in the pane (full form prefilled;
a changed answer returns to a provisional score), the sidebar is files
+ export only (no Questions section), question cards carry a
status-coloured outline (blue = open, green = answered; status word
stays), and the thread is a chat — messages as sender-labelled bubbles,
questions as widget cards with the recommendation inside the card. Dark/light always follows the system `prefers-color-scheme`
(theme tokens only; no toggle or setting). **No AI calls and no `conn:*`
labels** — the interviewer is an external driver (Muse / Claude Code)
connected over MCP. `tools/ds-wake/` is an optional driver-side Channels
bridge (local stdio; `wait_for_input` remains the fallback).

- Develop: `npm install && npm run dev` (port 8080)
- Verify: `npm run typecheck && npm test && npm run build` (Node 24)
- Deploy to a Fly Sprite: see `DEPLOY.md` — including the hard rule to
  never ship a tarball containing `data/`.
- Drive it: see `../SKILL.md`.
