---
name: design-sprites
description: Run a design interview as a standalone website on a Fly Sprite when a coding agent needs a human's judgment before building. One sprite hosts one Project: the sprite's own AI interviews the human in a single realtime chat thread — mapping the decision space privately, predicting every answer, asking only the frontier as question cards, scoring each prediction hit or miss, and re-deriving a living decision model (model.md) from the verbatim record — while generating and patching a versioned HTML design artifact in the same stream. When recent predictions on load-bearing questions all hit, the AI declares the model sharp; the human presses Commit, which freezes the deliverable (files + model + transcript, exportable as a bundle) and locks the Project read-only. External agents can drive instead of the built-in AI through full REST/MCP parity under a one-Driver lock. Use when a design or implementation choice has load-bearing ambiguity, the human's time is scarce and fragmented, or a chat back-and-forth would lose the evolving picture. Ships with the full Elixir + Phoenix + Ash template app (v2).
---

# Design Sprites

A design sprite is a small, standalone website that runs one design interview. It lives on a Fly Sprite (Fly.io's persistent sandbox with its own URL) — one sprite, one **Project**. `brief.md` in this repo is the founding brief (v1, kept verbatim for the record); this file is the current system. Where they differ — and v2 differs a lot: no rounds, no submit button, no email — this file wins.

The interview still runs the way an optometrist runs an eye exam: "Better, 1 or 2?" But there are no rounds any more. The sprite's own AI works in **one continuous chat thread**: it arrives with a predicted decision model, posts question cards only where its guess is weak, scores every prediction the moment an answer lands, and keeps re-deriving the model from the answers. Design happens in the same stream — the AI generates a standalone HTML artifact, the human clicks elements in it to attach feedback, and the AI patches the artifact into a new version. The interview ends when the AI declares the model **sharp** (its recent predictions on load-bearing questions all hit) and the human presses **Commit**. What the human walks away with is the deliverable: the Project's files — `model.md`, the artifacts, the verbatim transcript — frozen and exportable as one bundle.

## When to use one

- The work ahead contains decisions only the human can make, and guessing silently would produce work they reject.
- The human's attention comes in minutes, often on a phone, between other work. A page that holds state — drafts autosaved, answers landed in any order — beats a chat thread they must scroll and re-explain.
- The decision will keep generating follow-on questions during implementation. A list of answers runs out; a model of how the person decides extends to questions nobody anticipated.
- There is something designable — a page, a screen, a flow — whose shape should be settled by looking at it, not by describing it.

Do not use one for mechanical work (typo fixes, obvious renames, a bug the human already diagnosed), or when the facts are discoverable by reading — finding facts is the agent's job; choosing between them is the human's.

## The shape

- **One Project per sprite.** The opening screen is one text box — "What do you want to design?" That want creates the Project; everything else follows from it.
- **One chat thread, no modes, no side threads.** Chat sits centered; when a right pane opens (a question to answer, the artifact, a file), chat shifts left and the pane takes the right. A left navigator shows the project structure (model, artifacts, files). On a phone the navigator is a drawer and the pane a sheet.
- **The record is append-only.** Every human utterance is stored verbatim; nothing ever overwrites a submitted word. A correction is a new entry (a superseding answer, a superseding score, a later message), never an edit. The only mutable things are per-question **drafts** — half-answers persist as drafts and autosave on every tap and keystroke, clears included: clearing a field saves as cleared.
- **Anyone can view or drive — no permission system.** Exactly one **Driver** at a time (see the lock below); everyone else watches live.

## The interview process

The built-in AI runs this loop; an external agent driving over the API follows the same rules.

1. **Map the decision space.** Before the first question, privately enumerate the decisions the Project involves and the plausible answers to each. Treat them as independent axes unless one answer removes another axis. Order axes by partition power — how much settling each one shrinks the remaining space. **Predict an answer for every axis and note your confidence.** Axes you can already predict with high confidence are not questions; they are the first entries in the decision model. The map itself stays private — never present it or narrate the ordering.
2. **Ask only the frontier.** Post question cards for unsettled axes whose prerequisites are settled — at most **4 cards per turn**, independent ones batched, dependent ones sequenced. Do not pad with questions you can already predict. There is no submit button and no round boundary: answers land inline, in any order, whenever the human gives them, and each answer kicks the next AI turn.
3. **Question cards (Claude Code's types).** `single` (pick one), `multi` (pick any), `preview` (pick one of 2–4 options, each carrying a small HTML mockup; the pane renders them stacked vertically, one full-width card per option, so mocks stay legible and untruncated). A preview question carries a dial — a slider plus a verbatim dialed-value field — **only when all its stops are numeric**; a non-dial preview renders no dial at all. Every card has **2–4 options**. The UI automatically adds an **Other** free-text option and an optional **comment** field to every card — never include Other in the options yourself.
4. **The prediction is the first option, untagged.** Every card's predicted answer is its first option. When your house recommendation differs from your prediction, append `(Recommended)` to the recommended option's label. Position carries the prediction; the tag carries a divergent recommendation.
5. **Load-bearing is the default.** Mark a question `load_bearing: false` only for a minor preference whose answer would not change the build in a material way. Load-bearing questions are what the sharpness gate counts.
6. **Infer tradeoff posture from concrete answers** (simplicity vs flexibility, speed vs ceremony, build vs buy…). Never ask explicit tradeoff questions.

### Scoring

Scoring is deterministic code, not vibes — the app records it the moment an answer lands:

- An exact prediction match is a **hit**; any other named choice is a **miss**; an **Other** answer is always a **miss**.
- **Re-answering (while the Project is open):** an answered question can be answered again — from the card's "Change answer" in the web UI, or the same answer endpoint over REST/MCP. The re-answer appends a **superseding** answer entry and a new deterministic score entry; the originals stay in the record as history, and tallies, the sharpness gate, and every derived view count **only the latest** answer and score. A comment on a re-answer makes the new score provisional, judged as usual. After **Commit**, re-answering is refused (`committed`) like every other design-content write.
- A non-empty **comment** makes the score **provisional**: the AI must judge it on its next turn — confirming the result (`comment_reviewed`) when the comment doesn't change the build, or appending a **superseding miss** (`comment`) when it does. "a, but…" means the *but*. Prose never substitutes for the judgement entry; a turn that leaves a provisional unjudged is corrected within the turn, and still-unjudged provisionals make the turn visibly degraded.
- **Skip** (the human says skip it, use your prediction, decide for me, not now): the prediction stands as the model's answer, **unscored** — neither hit nor miss — and the question may still be answered later.
- **Strike** (the human says the axis is out of scope, irrelevant, the wrong question): the axis is removed from the map, terminal for that question. A struck axis never returns under a new key or a reworded axis.
- Skip and strike also work from free chat: the human names the question in ordinary words ("skip the fulfilment question for now") and the AI interprets it — validated deterministically (the action's evidence must be an exact quote from that message) and recorded as the human's own entry, with their full utterance as the note.

### The model

- The decision model lives in a file, **`model.md`**, among the Project files: settled decisions, how the human decides (short bullets, each traceable to the answer it came from), open axes, and the goal in one line — specific enough to settle questions the interview never asked.
- After answers arrive, the model is **re-derived from the previous model plus the new verbatim entries — never from a summary of the record**. AI context is likewise rebuilt from the verbatim record every turn. Nothing is ever summarized into the record's place.
- Question intent is checkable: the AI declares how many questions its reply posts, the app cross-checks it against what actually landed, and dropped questions are counted by kind. Announce in prose only questions that actually land as cards.

### Sharpness and Commit

- **Sharpness gate (deterministic):** at least 3 answered load-bearing questions, the 3 most recent load-bearing scores all final (non-provisional) hits, and no load-bearing question open or skipped. The AI proposes; the gate disposes — a sharp declaration that fails the gate is stripped, never recorded.
- When the gate passes and the unasked axes feel equally predictable, the AI declares the model sharp in chat and stops asking. The human may say **"keep asking"** to reopen the frontier, or press **Commit**.
- **Commit is a deliberate human press. It is one-way.** It freezes the deliverable and locks the Project read-only for design content — enforced at the record layer *and* the storage layer, so no surface (web, REST, MCP, driver) can write design content afterwards; attempts get `409 committed`. Two things survive Commit: the read-only Project itself, and the **Decided-for-you log**, which stays appendable by the implementing agent via the API.
- An optional **webhook** fires on Commit (a POST carrying ids and a timestamp only, Bearer token when configured). Notification is never email, and a webhook failure never blocks the Commit.

### Govern implementation with the model

After Commit, the implementing agent works from the exported bundle. When implementation uncovers a question the interview never reached: if the model predicts the answer at sharp-level confidence, decide, and log it in the Decided-for-you log with the model bullet it followed; if not — or the decision sits inside a boundary the human reserved — that is a new Project on a new sprite, not a reopening of the committed one. When a "how you decide" bullet recurs across Projects, propose it as a durable rule in your summary — never write it into the human's standing instructions unilaterally.

## Design in the same stream

- The AI generates a **standalone HTML artifact** (one self-contained file) as a versioned Project file. **Stable element ids are enforced at write time**, not requested: a non-trivial artifact whose meaningful elements lack ids (floor: at least 1 in 4, above a small triviality bound) is rejected whole and never reaches the record. Put an id on every header, main, section, heading, link, button, and form control.
- **Existing pages enter as snapshots — version 0** — via the web pane ("+ Add a page snapshot") or the API. Snapshots are exempt from the id rule (they capture pages that already exist); their first edit is version 1 by the ordinary patch path.
- **Inspector:** clicking an element in the served artifact attaches it to the chat composer as a chip (identity: the element's own id, else a CSS path; plus its text and snippet). The next chat message carries the attachments, and the AI can see what the human pointed at. The bridge script is injected at serve time only — stored bytes of every version stay pristine.
- **Patch, don't regenerate.** Feedback — above all a message with attached elements — is answered with a **patch**: one find/replace pair whose `find` is an exact substring of the artifact's current bytes occurring exactly once, validated by dry-run before anything in the turn is written. An invalid patch is dropped whole while the rest of the turn lands. A full artifact in a reply is only for first generation or an explicitly requested new direction, and it supersedes a same-turn patch for that name.
- Every version stays servable (`/artifact/:name/v/:version`); viewing an old version notes that feedback patches the latest.

## Files and the deliverable

One exportable set, one definition — the web explorer, the REST API, the MCP tools, and the bundle all serve exactly it:

- `transcript.md` — a live projection of the record, regenerated on every read (the record itself is its history).
- `record.json` — the structured record: project, verbatim entries, derived question views, tally, file index.
- `model.md` and `artifacts/*.html` — every version.

The **bundle** is a zip: the latest revision of every file at its natural path, plus every version under `history/<path>/v<n>`. Nothing else — no database, no tokens.

## Who drives: the built-in AI, or you

- **Built-in AI (default).** The sprite's own AI drives via the Sprites gateway's Anthropic connection (`conn:anthropic` label; the gateway injects credentials — no keys ever live in the sprite). Calls are streaming structured-output turns with bounded, visible retries; the turn cap is a last-resort bound, not a latency budget.
- **External agents (full parity).** Muse, Claude Code, Codex — any agent can drive instead, over REST or MCP. Both are thin skins over one API module, so the surfaces cannot drift: every capability the web UI and the built-in AI have exists on both. If you are driving, the built-in AI stays out of the way for your mutations.
- **The one-Driver lock.** On the web, the lock is Phoenix Presence: the first visitor auto-claims a free seat; anyone can explicitly take or release it after; the lock dies with the Driver's presence, and Viewers are never blocked from watching. Over the API, the lock is a **lease**: an explicit `acquire` with a caller-chosen `driver_id`, a 10-minute idle TTL refreshed by mutating calls (or `heartbeat`). Every mutation requires holding the lease; reads are open to any Bearer-token holder.
- **Actor semantics.** A mutation performed as the **human** (a relayed message or answer) kicks the built-in AI, exactly like the web UI. A mutation performed as the **agent** means you are driving — the built-in AI does not follow it with a turn.

## Failure posture

If the gateway AI call fails mid-interview, the Project stays fully usable as a record — chat, files, answering, manual question posting via the API all keep working — and the failure is visible in the UI (an in-chat banner; state is saved, send a message to retry) and in the structured log. **A failed AI turn never writes to the record.** An empty reply object is a failed call, never a successful no-op turn. Nothing stalls silently.

## Stack

**Elixir + Phoenix LiveView + Ash, with SQLite on the sprite's own persistent disk. This is the strong default** — the template in `template/` is exactly this (app name `design_sprite`, version 2.0.0), and new design sprites are created from it, not rewritten. Bandit serves HTTP; Req is the HTTP client; ReqLLM provides structured LLM calls; JSON is Elixir's built-in module. Per-sprite state lives in `<app dir>/data/` (SQLite `app.db`, versioned files under `files/`, `.admin_token`, `.secret_key_base` — secrets generated on first boot into 0600 files). The template ships its synced `AGENTS.md` (Ash/Phoenix/Elixir usage rules), so any agent working in the app inherits them. Reach for something heavier (Postgres, a separate host) only when shared access or real concurrency outgrows the sprite's disk.

## Creating a sprite from `template/`

Full runbook: `template/DEPLOY.md`. The shape:

1. **Build the release once** from `template/`: `MIX_ENV=prod mix release --overwrite < /dev/null` (ERTS bundled), packaged with `scripts/run.sh` at the release root. The same artifact deploys to every sprite, unchanged.
2. **Create the sprite** with its gateway label set in the create call — or in ONE `sprite config update` call, because that command *replaces* the whole label set: the sprite needs `conn:anthropic` for the built-in AI. Make the URL public (url-auth: public) — the page is the human's front door, no login; the API routes stay behind the Bearer token.
3. **Extract the artifact** as the app dir, e.g. `/home/sprite/app`. There is no seed file in v2: the Project is created from the opening text box (or `POST /api/project`).
4. **Admin token:** to pin it, pre-place `data/.admin_token` (mode 0600) before first boot; otherwise the app generates one on first boot — read it back from that file and store it safely.
5. **Configure** `data/.env` (0600) — the only per-sprite configuration surface besides the token:
   ```
   PHX_HOST=<sprite>-<suffix>.sprites.app
   SPRITE_NAME=<sprite>
   # optional: AI_MODEL=<gateway model id>            (default claude-fable-5-2)
   # optional: AI_GATEWAY_URL=<gateway base URL>      (default: discovered in-sprite)
   # optional: COMMIT_WEBHOOK_URL=<url>               (Commit notification)
   # optional: COMMIT_WEBHOOK_TOKEN=<bearer token>
   ```
6. **Register the service:** `sprite-env services create app --cmd /home/sprite/app/run.sh --dir /home/sprite/app --http-port 8080`. `run.sh` generates `data/.secret_key_base` once (0600, python3 `secrets`, no shell pipelines), migrates, and starts the release.
7. **Verify:** `GET /health` returns `{"ok":true,"app":"design_sprite","version":"2.0.0","project":…}` after a real DB round trip; `GET /api/state` with the Bearer token returns the Project state; the public page shows the opening text box (or the live Project).

### Runtime API (Bearer admin token unless noted)

REST — reads need only the token; **every mutation additionally requires holding the Driver lease** (`driver_id` in the body). Errors map to 401/404/409/422 and never echo content.

- `GET /health` — no auth; real DB write+read probe, plus the Project's status.
- `GET /api/state` — full state: project, verbatim entries, question views with scores, tally, file index, driver holder, sharpness status.
- `GET /api/files`, `GET /api/files/content?path=…&version=…` — the exportable set and one file's bytes.
- `GET /api/export` — the bundle zip. (Public read-only equivalents: `GET /export`, `GET /files/raw`, `GET /artifact/:name`, `GET /artifact/:name/v/:version`.)
- `POST /api/project` — create the Project from the opening want (only when none exists).
- `GET /api/driver`; `POST /api/driver/acquire` · `/heartbeat` · `/release` — the lease.
- `POST /api/messages` — post a chat message (`actor`: `human` kicks the built-in AI; `agent` is you driving; `elements`: inspector attachments).
- `POST /api/questions` — post a question card (same validation as the built-in AI's cards).
- `POST /api/questions/:key/answer` · `/skip` · `/strike` · `/score` — answer (choice / choices / other_text / dialed_value verbatim / comment; answering an already-answered question re-answers it with a superseding entry while open, `409 committed` after Commit), skip, strike, or append a superseding score judgement for a provisional.
- `POST /api/decisions` — append to the Decided-for-you log (the one write that survives Commit).
- `POST /api/artifacts` — write a full artifact version; `POST /api/artifacts/snapshot` — enter a page as version 0; `POST /api/artifacts/:name/patch` — patch into a new version (find must occur exactly once).
- `POST /api/model` — write a new `model.md` version.
- `POST /api/sharp` — declare sharp (lands only when the deterministic gate passes); `POST /api/resume` — the human's "keep asking".
- `POST /api/commit` — Commit: freeze the deliverable, lock the Project read-only.

MCP — `POST /mcp`, a single JSON-RPC 2.0 endpoint with 22 tools mirroring the REST surface one-for-one: `get_state`, `list_files`, `read_file`, `export_bundle`, `acquire_driver`, `heartbeat_driver`, `release_driver`, `create_project`, `post_message`, `post_question`, `answer_question`, `skip_question`, `strike_question`, `judge_score`, `append_decision`, `write_artifact`, `patch_artifact`, `snapshot_artifact`, `write_model`, `declare_sharp`, `resume`, `commit_project`.

## Design language

The look is Impeccable "Observability": light paper, kinpaku gold and patina accents, Albert Sans, eyebrow labels, hairline rules — an exam room, quiet, precise, unhurried, one thing in front of you at a time. Take the eye-exam metaphor from its rhythm and optics (focus, paired choices, sharpening), never from costume: no eyeballs, no glasses clip art, no medical branding. Not a chatbot, not a survey, not a dashboard.

- **Progress is clarity, never completion.** No progress bar, no percent, no "step 3 of 10" — there is no fixed number of questions. The model sharpens; the tally of hits and misses is the visible score of the AI's understanding.
- **The chat column holds a 65ch measure**; question options are rows with 44px+ targets. Commit is the only high-stakes button, and it says what happens. The chat composer is contained to the same column — same 65ch width and inset as the transcript, centered when no pane is open and aligned with the shifted column when one is — never spanning the full window width.
- **States are designed,** not defaulted: empty (the opening text box), loading (an AI-thinking indicator), error (the AI-failure banner — the record is intact, retry by sending a message), partial (drafts persist).

## Ops routes

- **Sprites CLI** (`sprite`, run from a host with Sprites access): create/destroy sprites, `sprite exec -s <name>` to run commands inside, `sprite config update` for gateway labels (complete set, one call), `sprite-env services` inside the sprite for the app service. This is the primary route — script deploys and repairs through it.
- **Fly's remote MCP server** at `https://fly.io/mcp` (OAuth) covers Sprites and Machines as an alternative ops surface. Note: reading a sprite's runtime state through it may wake a sleeping sprite.

## Hard rules

- **The record is append-only and verbatim.** Nothing overwrites a submitted word — not a later answer, not a redeploy, not a migration. Corrections are new entries. Drafts are the only mutable state, and autosave includes clears.
- **Every question carries its escape hatches:** the UI-added **Other** option (the typed text *is* the answer when selected) **plus a free-text comment** (a named choice + comment means the comment qualifies the choice). Never fold them into the options list, never remove them.
- **One canonical template.** Per-sprite differences are `data/.env` + admin token + sprite name only — never fork the app for one sprite. Template changes land in the template, then redeploy.
- **Edit sprites in place by default.** Redeploy the release over the existing app dir, preserving `data/`, and verify the record is intact (entries, tally, files) before and after. Destroy-and-recreate is only the fallback for a sprite wedged beyond repair; throwaway sprites are destroyed with `--force`, and a sprite someone has marked frozen is never interacted with at all.
- **Contract 11 holds throughout:** an AI failure never writes to the record. If a change would let a failed, empty, or partial AI turn land as if it succeeded, the change is wrong.
- **The model is the deliverable.** Answers without the updated `model.md` is a half-finished turn; the committed bundle — model, artifacts, transcript — is what the human walks away with.
