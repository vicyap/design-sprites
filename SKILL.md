---
name: design-sprites
description: Run a design interview as a standalone website on a Fly Sprite when a coding agent needs a human's judgment before building. One sprite hosts one Project: an append-only verbatim record, a chat + question-card web UI, and a deterministic state machine — with NO built-in AI. The interviewer is an external agent (Muse or Claude Code) driving the sprite over MCP: mapping the decision space privately, predicting every answer, asking only the frontier as question cards (single, multi, or preview — sandboxed HTML-snippet variants with slider dials), judging each provisional score, and re-deriving a living decision model (model.md) from the verbatim record. v4 adds the design surface: the driver authors versioned standalone HTML artifacts the human reviews in a full-canvas layout mode and annotates element-by-element with the Agentation inspector (annotations land in the record; the driver reads, replies, and resolves them over MCP). Design work starts with structure — layout and hierarchy in grayscale — before any colour. When the deterministic sharpness gate passes, the driver declares the model sharp; the human presses Commit, which freezes the deliverable (model + record + transcript, exportable as a bundle) read-only. Use when a design or implementation choice has load-bearing ambiguity, the human's time is scarce and fragmented, or a chat back-and-forth would lose the evolving picture. Ships with the full Next.js + TypeScript template app (v4).
---

# Design Sprites (v4)

A design sprite is a small, standalone website that runs one design interview. It lives on a Fly Sprite (Fly.io's persistent sandbox with its own URL) — one sprite, one **Project**. `brief.md` in this repo is the founding brief (v1, kept verbatim for the record); this file is the current system. Where they differ, this file wins.

**The v3 change that matters most: the sprite has no AI in it.** The sprite is only three things — the append-only verbatim **record**, the **web UI**, and a **deterministic state machine** with an **MCP server**. All intelligence lives in an external **driver**: Muse or Claude Code, connected over MCP. With no driver attached, human messages and answers are still recorded immediately and simply wait — the UI says so honestly — the banner shows "Waiting for a driver — no AI is present" only while no driver is attached (v3.7 presence, below). Nothing replies on its own. (v2's built-in AI, its `conn:anthropic` gateway label, its REST/MCP parity, and its one-Driver lock are all gone in v3. The design surface returns in v4 — below — rebuilt on this architecture: driver-authored artifacts plus the Agentation inspector, with the record still the only state.)

**v3.5 adds exactly two things** (everything else in v3 is unchanged):

1. **Preview questions** — a third question type, `preview`, alongside `single`/`multi`: 2–4 small self-contained HTML-snippet **variants** the human picks between, plus optional question-level slider **dials**. Variants render sandboxed and script-free; dials are answer data, never scored. Snippets live and die inside the question entry — this is not the v4 design surface (no artifacts, no file versions for variants, no inspector).
**v3.5.1 (mobile hotfix, 2026-11-13):** on phones the answer pane is a fixed overlay sheet (its positioning lives in CSS classes, never an inline style, and its height is `100dvh` so browser chrome / the on-screen keyboard shrink it instead of pushing its footer off-screen); a question card's eyebrow also carries a status word once answered (**Answered / Skipped / Struck**) — status only, never the answer content, which stays in the pane and its answer entry.

2. **Dark/light follows the system, always.** The app renders in the OS/browser `prefers-color-scheme` scheme via theme tokens. There is **no toggle, no setting, no persisted choice** — never build one.

**v3.6 adds five things on top of v3.5** (the record, gates, turn protocol, preview questions, and system-follow dark/light are unchanged):

1. **Batch-answering flow** — the answer pane carries a **Next open question** control that moves the pane to the next still-open question in thread order, and the project header shows **"N of M answered"** (answered + skipped vs total; counts only, no answer content). Advancing is always the human's tap: saving never auto-closes the pane and never auto-advances it. When no open question remains, the control says so plainly ("All questions answered").
2. **Jump-to-question navigator** — the navigator (desktop sidebar / mobile drawer) gains a **Questions** section listing every question with its status word only (**Open / Answered / Skipped / Struck**) — status only, never answer content. Tapping a question opens it in the answer pane (the same action as tapping its card); on mobile, tapping also closes the drawer, which is the drawer's own navigation action.
3. **Sticky chat composer** — the chat thread's message composer is docked to the bottom of the chat column (iMessage-style): the thread scrolls, the composer stays anchored to the column — not the full window — at both desktop and mobile widths.
4. **Mobile round 2** — inside the answer pane, the Save answer / Skip actions sit in a bar stuck to the pane's bottom edge, reachable without scrolling; preview-question dial/slider touch targets are at least **44px** tall.
5. **Optional driver wake-up (ds-wake)** — `template/tools/ds-wake/` ships a local stdio bridge that can push a Claude Code Channels event into a running driver session when a human entry lands. It is an optional, driver-side enhancement only: the sprite is unchanged, `wait_for_input` remains fully functional and is the fallback, and no `conn:*` labels or built-in AI are involved. See the Channels note under "Driving a sprite over MCP" and `template/tools/ds-wake/README.md`.

**v3.7 adds five things on top of v3.6** (the record, gates, turn protocol, preview questions, and system-follow dark/light are unchanged):

1. **Driver-presence banner** — the header banner reflects real driver presence, updated on the UI's existing 4s poll with no refresh. Presence is runtime state only (its own store record, never an entry in the verbatim record): every authenticated MCP request stamps it, a driver blocked in `wait_for_input` keeps it fresh, and a registered ds-wake bridge stamps it via its poll header (`x-ds-wake: 1`). Fresh (within 10 minutes) the banner reads "A driver is attached — it will be woken by your activity" — honest to the turn-based model, never a claim that an AI is watching live; stale or absent, it falls back to the waiting text.
2. **Answered questions stay editable** — the answer pane renders the full form for answered questions too (all choices with the current selection marked, the Other option + its text, the comment, dial values), prefilled from the current answer. Changing and saving goes through the normal answer path (the record stays append-only underneath) and the question returns to a provisional score until the driver judges it again. The pane only — thread cards remain status-only.
3. **Sidebar: files + export only** — the v3.6 Questions section is removed from the navigator (desktop sidebar and mobile drawer). The sidebar shows the project header/status, the files list, Download export, and the Commit control. Moving between questions lives in the thread cards and the pane's Next open question flow.
4. **Question-card outline = status colour** — thread question cards carry a coloured outline by status: blue = open / not yet answered, green = answered; skipped/struck keep a muted neutral border. The status word stays (colour is an addition, never the only signal). The "currently open in the pane" highlight is a background tint + shadow, not the blue outline.
5. **Chat restyle: bubbles + widget cards** — regular messages render as chat bubbles modelled on the Muse chat interface (human right-aligned on a soft tint, driver left-aligned on a muted surface, each with a sender label + time meta — authorship is never colour alone; system entries stay a quiet centred note). Question entries render as generative-UI-style widget cards inline in the stream: header row (Question eyebrow, load-bearing chip, status), prompt body, and the driver's recommendation (when given) as a sub-panel inside the card — still status-only, never answer content. Answering still happens in the pane; inline answering inside the widget is a v4 design-surface question, not v3.7.

**v4 adds the design surface** (the interview, record, gates, turn protocol, preview questions, and system-follow dark/light are unchanged):

1. **Artifacts** — `post_artifact` / `patch_artifact` are a first-class authoring surface: a standalone HTML page the driver writes in full, versioned on every write (old versions stay viewable, verbatim). An artifact write may carry a `title` and a `kind` — `generated` (default; a page the driver authored) or `snapshot` (a static capture of an existing page) — inherited by later versions when not restated. The thread shows **one widget card per version write**; tapping it enters **layout mode** (`/artifact/<path>?v=N`): the page rendered full-canvas with a version switcher. Artifacts are **script-free, enforced at `end_turn`** by a page gate: no `<script>`, no inline `on*=` handlers, no `javascript:` URIs; `generated` artifacts additionally load **no external resources at all** (inline styles/SVG, `data:image` and `#fragment` CSS `url()` only); `snapshot` artifacts may reference external assets but the driver strips scripts at capture. Cap: **200,000 chars** (`MAX_ARTIFACT_CHARS`). **Stable element ids are enforced**: `id="..."` values in an artifact must be unique, and a rewrite must keep every previous version's ids — annotations anchor to them.
2. **Structure before colour (locked rule).** All design work starts with layout, structure, and hierarchy — a grayscale structure pass. Colour enters only after the structure is approved. The layout-mode chrome itself follows this: neutral surfaces and hierarchy first.
3. **The inspector annotator is Agentation (locked rule: always Agentation).** Layout mode mounts the **Agentation** toolbar: the human clicks any element of the artifact (it renders in a same-origin frame, which Agentation's picking supports) and attaches a note. The note lands in the record as an **annotation** entry carrying the element identity (element path, stable element id, element text), the artifact path + version it was made against, and the verbatim comment. The driver reads annotations with `list_annotations` (they are also in `get_state`), responds with `reply_annotation`, and closes them with `resolve_annotation` — resolution is a new record entry, never a mutation, and is reflected back into the toolbar so its markers clear. Annotations render as cards in the thread and in layout mode's annotations panel, attached to the version they were made against; open and resolved read distinctly. Wiring: the `agentation` React package in the app (layout mode only), syncing through a same-origin `/agentation-sync` path to an `agentation-mcp` service running on the sprite on loopback port 4747 (never publicly exposed; its store lives at `~/.agentation/` on the sprite disk). Annotations reach the record two ways into one deduped intake: the page mirrors each note the moment it is made, and agentation-mcp's action webhook delivers the batch when the human sends annotations.
4. **Navigation model.** The **thread is home**: artifacts appear inline as widget cards, expanding a card enters layout mode, annotations flow back into the thread as entries. The project header is the constant anchor. There is no separate dashboard.
5. **Licence.** Agentation is **PolyForm Shield 1.0.0 (© 2026 Benji Taylor)** — free for individuals and companies for internal use. The integration depends on the published npm packages (`agentation`, `agentation-mcp`); their code is never vendored or forked, and the licence text + copyright notice ship with the template (`template/THIRD-PARTY-NOTICES.md`). Redistributing Agentation as part of a product you **sell** requires a commercial licence from Agentation — see the P1 note in the v4 build record and `template/DEPLOY.md`.

The interview still runs the way an optometrist runs an eye exam: "Better, 1 or 2?" The driver arrives with a predicted decision model, posts question cards only where its guess is weak, judges every prediction the moment an answer lands, and keeps re-deriving the model from the verbatim record. The interview ends when the deterministic **sharpness gate** passes and the driver declares the model **sharp**; the human presses **Commit**. What the human walks away with is the deliverable: `model.md`, the verbatim record, and the transcript — frozen and exportable as one bundle.

## When to use one

- The work ahead contains decisions only the human can make, and guessing silently would produce work they reject.
- The human's attention comes in minutes, often on a phone, between other work. A page that holds state — drafts autosaved, answers landed in any order — beats a chat thread they must scroll and re-explain.
- The decision will keep generating follow-on questions during implementation. A list of answers runs out; a model of how the person decides extends to questions nobody anticipated.

Do not use one for mechanical work (typo fixes, obvious renames, a bug the human already diagnosed), or when the facts are discoverable by reading — finding facts is the agent's job; choosing between them is the human's.

## The shape

- **One Project per sprite.** The driver creates the Project from the human's want via MCP (`create_project`); everything else follows from it.
- **One chat thread.** Chat sits centered; when a right pane opens (a question to answer, a file to view), chat shifts left and the pane takes the right. A left navigator shows the project header/status, the files list, Download export, and the Commit control (v3.7: files + export only — no question list). On a phone the navigator is a drawer and the pane a sheet. The chat composer is sticky to the bottom of the chat column. Question cards are themselves clickable — the whole card opens the question in the pane; the card face shows only an eyebrow ("Question"), the prompt, and — once answered — a status word (Answered / Skipped / Struck): status only, never answer content. Answering does not auto-close the pane and never auto-advances it; the human closes it explicitly, or taps **Next open question** to move to the next open question (Escape also closes the drawer, then the pane). The project header shows "N of M answered" (counts only).
- **Artifacts live in the thread; layout mode is the canvas (v4).** Each artifact version write renders as a widget card in the thread (Artifact eyebrow, title, version — never the page content). Opening a card enters **layout mode**: the artifact page full-canvas, a version switcher, the Agentation annotator toolbar, and an annotations panel for that version. Returning to the thread restores the reader's scroll position. On a phone, layout mode is a readable full-width view (the annotations panel is desktop-width; annotating is desktop-first).
- **Colour scheme follows the system.** All colours are theme tokens; the dark token set applies by `prefers-color-scheme` media query alone. No toggle, no setting, no persisted choice, no JS theme class.
- **The record is append-only.** Every human utterance is stored verbatim the moment it is sent; nothing ever overwrites a submitted word. A correction is a new entry, never an edit. The only mutable things are per-question **drafts** — half-answers autosave on every tap and keystroke and survive reloads, with no driver present.
- **No permission system, no driver lock.** Anyone with the URL can view and answer. Drivers coordinate through the turn protocol's stale-head rejection (below), not a lease: two drivers racing is resolved by the record, not by a lock.

## The interview process

You, the driver, run this loop. The sprite enforces the mechanics; the judgement is yours.

1. **Map the decision space.** Before the first question, privately enumerate the decisions the Project involves and the plausible answers to each. Treat them as independent axes unless one answer removes another axis. Order axes by partition power — how much settling each one shrinks the remaining space. **Predict an answer for every axis and note your confidence.** Axes you can already predict with high confidence are not questions; they are the first entries in the decision model. The map itself stays private — never present it or narrate the ordering.
2. **Ask only the frontier.** Post question cards for unsettled axes whose prerequisites are settled — independent ones batched in one turn, dependent ones sequenced across turns. Do not pad with questions you can already predict. There is no submit button and no round boundary: answers land inline, in any order, whenever the human gives them, and each answer is recorded immediately.
3. **Question cards.** `single` (pick one), `multi` (pick any), and `preview` (pick a rendered variant, set dials). For design decisions that need a real page rather than a snippet, author an **artifact** instead (v4 design surface, above): structure pass first, then let the human annotate it in layout mode and read the annotations back over MCP. Pass at most **9 named options**; the app automatically adds an **Other** free-text option **inside the option group** as the 10th — never include Other in the options you pass. Every card also carries an optional per-question **comment** field in the UI. Pass your prediction explicitly (`prediction`: an option value, or an array of values for `multi`); optionally pass `recommended` when your house recommendation differs from your prediction.
   - **`preview` questions.** Pass `variants`: 2–4 entries of `{id, label, html}` — `id` is stable and unique, `html` is a **small self-contained snippet** (inline styles and inline SVG allowed; **max 20,000 chars**). You may omit `options` (they are derived from the variant ids) or pass them explicitly (then the values must cover the variant ids exactly). Optionally pass question-level `dials`: `[{id, label, min, max, step, default, unit?}]` — sliders the human sets; ranges must be sane (`min < max`, `step > 0`, `default` in range). `prediction` names the expected **variant id**. The answer is the chosen variant id (optional when the question is dial-only) plus the dial values verbatim, with Other (inside the group) and the per-question comment exactly as for other types; drafts autosave the same way. In the pane, variants render **stacked vertically, full-width**, each in a sandboxed iframe (`srcDoc`, `sandbox=""`) so snippet CSS cannot leak into the app chrome and the snippet follows the system colour scheme.
   - **Snippet safety is gated at `end_turn`** (rejection leaves the turn open with structured errors): `<script>` tags; forbidden embedding/form/meta tags (`iframe`, `object`, `embed`, `link`, `base`, `form`, `meta`); inline event handlers (`on*=`); `src=` / `srcset=` attributes; `href` values that are not in-snippet `#fragment`s; `poster=` and `background=` attributes; `javascript:`/`vbscript:` URIs; CSS `@import`; and CSS `url()` — an **allowlist**: only embedded `data:image/…` targets and `#fragment` references pass. Oversized snippets reject as `snippet_too_large`; wrong variant counts / duplicate ids as `bad_variant_count` / `bad_variant`; bad dial ranges as `bad_dial_range`. Write snippets that pass first time: inline styles/SVG, `data:image` or `#fragment` CSS references only, nothing external, nothing executable.
4. **Load-bearing is the default.** Mark a question `load_bearing: false` only for a minor preference whose answer would not change the build in a material way. Load-bearing questions are what the sharpness gate counts.
5. **Infer tradeoff posture from concrete answers** (simplicity vs flexibility, speed vs ceremony, build vs buy…). Never ask explicit tradeoff questions.

### Scoring

Scoring is split: deterministic code computes a **provisional** score the moment an answer lands; you **judge** every provisional on your next turn with `score_answer`. A turn that leaves a provisional unjudged cannot commit — `end_turn` rejects it (`provisional_unjudged`) and leaves the turn open.

- An exact prediction match is provisionally a **hit**; any other named choice is provisionally a **miss**; an **Other** answer is always a **miss** (the typed text *is* the answer).
- **Preview** scores exactly like `single`: the chosen variant id vs the predicted variant id. **Dial values are data, never scored** — they ride along in the answer verbatim and are never a hit or a miss.
- **Judging a provisional:** confirm it (`hit` / `miss`), or override it. A non-empty **comment** is the usual reason to look twice: "a, but…" means the *but*. If the comment changes the build, judge it a **miss** with reason `build_changing_comment`. If it merely qualifies the choice, confirm the provisional result. Prose never substitutes for the judgement — stage the `score_answer` call.
- **Skip** (the human skips, or says use your prediction / decide for me): judge `skip` — the prediction stands as the model's answer and is finalised as *not* a hit; it never counts toward sharpness hits. A skipped load-bearing question also blocks the sharpness gate until it is answered.
- **Strike** (the human says the axis is out of scope, irrelevant, the wrong question): judge `strike` — the axis is removed, terminal for that question. A struck axis never returns under a new key or a reworded axis.

### The model

- The decision model lives in a file, **`model.md`**, among the Project files: settled decisions, how the human decides (short bullets, each traceable to the answer it came from), open axes, and the goal in one line — specific enough to settle questions the interview never asked.
- After answers arrive, re-derive the model from the previous model plus the new verbatim entries — **never from a summary of the record** — and stage it with `write_model` (every write is a new version). Your own context is likewise rebuilt from the verbatim record (`get_record`), never from a summary.
- Announce in prose only questions that actually land as cards in the same committed turn.

### Sharpness and Commit

- **Sharpness gate (deterministic, in code):** at least 3 answered load-bearing questions, the 3 most recent load-bearing scores all **final** (judged, non-provisional) **hits**, and no load-bearing question open or skipped. You propose; the gate disposes. `declare_sharp` checks the gate when staged and again at `end_turn`; a failing declaration is rejected with structured errors, never recorded.
- When the gate passes and the unasked axes feel equally predictable, declare sharp and stop asking. The human may ask you to keep asking, or press **Commit**.
- **Commit is a deliberate human press in the web UI. It is one-way.** It freezes the Project read-only for design content — enforced in the store, so no surface (web, MCP) can write design content afterwards; attempts fail with `commit_freeze` (HTTP 409 on the web paths). The record, the files, and the export stay readable.

### Govern implementation with the model

After Commit, the implementing agent works from the exported bundle. When implementation uncovers a question the interview never reached: if the model predicts the answer at sharp-level confidence, decide and note the decision (and the model bullet it followed) in your own project records; if not — or the decision sits inside a boundary the human reserved — that is a new Project on a new sprite, not a reopening of the committed one. When a "how you decide" bullet recurs across Projects, propose it as a durable rule in your summary — never write it into the human's standing instructions unilaterally.

## Files and the deliverable

One exportable set, one definition — the web explorer, the MCP file tools, and the bundle all serve exactly it:

- `model.md` — every version (written by the driver).
- **Artifacts (v4)** — any file the driver writes with `post_artifact` / `patch_artifact`: versioned standalone HTML pages, rendered in layout mode and annotatable (see the v4 notes above). When a v2 sprite is migrated forward, its artifact versions are imported verbatim as preserved files: stored, listed in the explorer, and included in the bundle.
- `record.json` — the structured record: project, verbatim entries, derived question views, scores, file index.
- `transcript.md` — a readable projection of the record.

The **bundle** (MCP `export_bundle`, or the zip from `GET /api/export` / the UI's download button) contains the latest revision of every file at its natural path, plus every version under `history/<path>.v<N>`, plus `record.json` and `transcript.md`. Nothing else — no database, no tokens.

## Driving a sprite over MCP

MCP is the only driver surface (no REST parity). Transport: **Streamable HTTP** at **`https://<sprite>-<orgsuffix>.sprites.app/mcp`**, stateless, gated by the sprite's **admin Bearer token** — the same token that gates the admin API. The token is generated on the sprite at first boot into `data/admin.token` (mode 0600); read it from inside the sprite (`sprite exec -s <sprite> -- cat /home/sprite/app/data/admin.token`). Never commit a token, never log one, never put one in a URL.

### Connect a driver

**Claude Code** (proven pattern):

```
claude mcp add --transport http <name> https://<sprite>-<orgsuffix>.sprites.app/mcp --header "Authorization: Bearer <token>"
claude mcp list   # expect: <name> … ✔ Connected
```

The `--header` is required: the sprite uses a static Bearer token, not OAuth — without it, connection fails (Dynamic Client Registration is not offered). **Muse** connects to the same `/mcp` URL with the same Bearer header through its MCP client configuration.

**Claude Code channels (preview, optional) — the ds-wake bridge:** an MCP server can also push events into a running Claude Code session, so a new human entry can wake the session instead of the driver polling. The template ships the proven shape in `template/tools/ds-wake/`: a **local stdio** MCP server (`bridge.mjs`) that runs on the driver machine next to Claude Code and polls the sprite's `GET /api/entries`, emitting a `notifications/claude/channel` event for each new human entry. A channel must be a local stdio server — the sprite's remote HTTP MCP cannot be one — so the sprite itself needs no change. Channels is a research preview: custom channels load via `--dangerously-load-development-channels` until allowlisted, and events arrive only while the session is open. This is an optional enhancement only; `wait_for_input` (below) is the mechanism that always works — for Muse, and as the fallback wherever channels are not enabled or not running. Setup and proof notes: `template/tools/ds-wake/README.md`.

### The turn protocol

Granular tools stage actions into **one open turn**; `end_turn` commits them atomically. **Nothing staged is visible in the record or the UI before `end_turn` commits.**

Staging tools:

- `create_project` — set the want (and optional title) on the sprite's single Project. Refused once a want exists (`project_exists`).
- `post_message` — stage a driver chat message (`body`).
- `post_question` — stage a question card (`key`, `type`: `single` | `multi` | `preview`, `prompt`, `options` [{value, label}] — at most 9 named, Other is added automatically inside the group, `prediction`, optional `recommended`, optional `load_bearing`). For `preview`: `variants` [{id, label, html}] (2–4, html ≤ 20,000 chars, self-contained and script-free per the snippet gate above; `options` may be omitted and are derived from the variant ids), optional `dials` [{id, label, min, max, step, default, unit?}], and `prediction` = the expected variant id.
- `write_model` — stage a full write of `model.md` (a new file version at commit).
- `post_artifact` / `patch_artifact` — stage a full-content write of a design artifact (a new file version at commit; `patch_artifact` requires an existing path). Optional `title` and `kind` (`generated` | `snapshot`), inherited by later versions when not restated. The `end_turn` page gate applies: script-free for both kinds, no external resources for `generated`, stable element ids unique and preserved across rewrites, 200,000-char cap.
- `reply_annotation` — stage a reply to an annotation (`annotation_entry_id`, `body`).
- `resolve_annotation` — stage an annotation's resolution (`annotation_entry_id`, optional `summary`); the gate rejects unknown targets and double resolutions.
- `score_answer` — stage a judgement of a provisional score (`question_key`, `judgement`: `hit` | `miss` | `skip` | `strike`, optional `reason` — use `build_changing_comment` for a build-changing comment).
- `declare_sharp` — stage a sharpness declaration (gate-checked at stage time and again at `end_turn`).

Commit / discard:

- `end_turn` — commit atomically. Gates run here: stale head, Commit freeze, question validation (including Other + ≤9 named options; for preview: variant count/uniqueness, snippet safety + 20,000-char cap, dial ranges), artifact page safety + stable-id preservation, annotation target validity, provisional-judgement completeness, sharpness. A rejection returns structured errors and **leaves the turn open** — fix the staged actions (staging appends to the open turn) or `discard_turn` and restage.
- `discard_turn` — drop the open turn and all its staged actions.

Reads:

- `get_state` — head, project status, questions with states and scores, sharpness-gate status, open turn, files, artifacts, annotations.
- `get_record` — verbatim entries with id greater than `since` (default 0 = all).
- `list_annotations` — the human's element annotations with element identity, status, replies, and resolutions (optional `status` filter: `open` | `resolved`).
- `list_files` / `get_file` — the exportable set and one file's content (latest version unless `version` is given).
- `export_bundle` — the whole Project as one object: project, verbatim entries, latest file contents, transcript markdown.
- `wait_for_input` — blocking long-poll: returns new **human** entries (answers, messages) since a given head as soon as any arrive, or times out cleanly (`{timed_out: true}`) so you can re-call. Default timeout 20s, max 50s.

**Stale head:** each staged turn records the record head it was staged against. If a human entry (or another driver) moves the head before `end_turn`, the commit is rejected with `stale_head` and the turn stays open: re-read with `get_record`, reconcile, and restage. There are no locks and no merging — this rejection *is* the concurrency model.

**A normal driver loop:**

1. `get_state` / `get_record` — rebuild context from the verbatim record.
2. Stage the turn: judge any unjudged provisionals (`score_answer`), `write_model` if answers changed the model, `post_question` for the frontier, `post_message` for anything the human should read.
3. `end_turn`. On rejection, read the structured errors, fix, retry (or `discard_turn`).
4. `wait_for_input` on the new head. When it returns entries, go to 1. On timeout, re-call or yield, depending on your host.

**No-driver posture:** if you disconnect, nothing breaks and nothing is faked. Human answers keep landing in the record with deterministic provisional scores; the UI shows the waiting-for-driver state. When a driver returns, `wait_for_input` / `get_record` since the last head it saw hands it everything it missed.

## Creating a v4 sprite from `template/`

Full runbook: `template/DEPLOY.md`. The shape:

1. **Build on Node 24.** The template pins `better-sqlite3` 11.10, which builds on Node 24 (Node 26 cannot). From `template/`: `npm install`, `npm run typecheck`, `npm test`, `npm run build` (Next.js standalone output).
2. **Create the sprite with NO labels.** `sprite create <name> --skip-console` — and no `--label` flags at all. **Sprites need NO `conn:*` labels**: the app makes no AI calls and uses no gateway connection. Do not add `conn:anthropic` out of v2 habit. Then make the URL public: `sprite url update -s <name> --auth public` (the page is the human's front door, no login; MCP and the admin API stay behind the Bearer token).
3. **Package the standalone build** — copy `.next/standalone/.` into a staging dir, add `.next/static` under `.next/static/`, add `run.sh` — then **remove any `data/` directory from the staging dir and verify the tarball contains no `./data/` path before uploading.** `next build` creates a `data/app.db` in the build tree (the DB module runs at build-time import) and the standalone copy carries it; shipping it would overwrite the sprite's live record. This has happened once; the deploy scripts in the wild carry an abort guard for exactly this. **Never ship a tarball containing `data/`.**
4. **Upload and extract** as the app dir: `sprite exec -s <name> --file <pkg>.tgz:/tmp/<pkg>.tgz -- sh -c "cd /home/sprite/app && tar -xzf /tmp/<pkg>.tgz"`. On a redeploy this preserves the sprite's existing `data/` — the tarball has no data dir in it.
5. **Register the app service:** `sprite-env services create app --cmd /home/sprite/app/run.sh --dir /home/sprite/app --http-port 8080`. Note: `--cmd` takes **one executable path** — `--cmd 'sh /home/sprite/app/run.sh'` is treated as a single filename and fails. `run.sh` runs the standalone server on port 8080 with `DATA_DIR=/home/sprite/app/data` on the persistent disk.
6. **Register the annotator service (v4):** build the `agentation-mcp` bundle on the build host (its `better-sqlite3` must match the sprite runtime — build where the app is built), upload it to `/home/sprite/agentation/`, and register a second service: `sprite-env services create agentation --cmd /home/sprite/agentation/run.sh --dir /home/sprite/agentation --env AGENTATION_CORS_ORIGINS=https://<name>-<orgsuffix>.sprites.app,AGENTATION_WEBHOOK_URL=http://127.0.0.1:8080/api/agentation`, where `run.sh` execs `node /home/sprite/agentation/node_modules/agentation-mcp/dist/cli.js server --port 4747`. The service binds loopback only and is never publicly exposed; the app reaches it through the `/agentation-sync` rewrite. Exact commands: `template/DEPLOY.md`.
7. **Admin token:** the app generates it on first boot at `/home/sprite/app/data/admin.token` (mode 0600) and never overwrites an existing one. Read it back via `sprite exec` and store it safely (0600). It gates `/mcp` and `/api/admin/*`. It is never in the repo, the tarball, or the logs.
8. **Verify:** `GET https://<name>-<orgsuffix>.sprites.app/health` → `{"ok":true,"app":"design_sprite","version":"4.0.0-p5","db":"ok","entries":<n>}` — the health check performs a real DB round trip (`SELECT COUNT(*)` against SQLite); `GET /agentation-sync/health` through the app returns the annotator's `{"status":"ok",...}`. The public page shows the waiting-for-driver state until a driver creates the Project. Then run the mobile-viewport check from Hard rules before calling it done.

### Runtime surface (for reference; MCP is the driver surface)

- `GET /` — the Project UI (public). `GET /health` — no auth, real DB round trip.
- Human paths (same-origin, no token — the UI must work with no driver or credentials present): `POST /api/entries` (message or answer — stored immediately, with a deterministic provisional score for answers), `GET /api/entries`, `GET /api/state`, `GET|POST|DELETE /api/drafts` (autosave), `POST /api/commit` (the human's Commit press), `GET /api/files`, `GET /api/export` (bundle zip), `POST /api/agentation` (annotation intake: the layout page's mirror + the agentation-mcp action webhook; deduped), `GET /artifact/<path>` (layout mode).
- Admin path: `POST /api/admin/entries` (Bearer token).
- MCP: `POST|GET|DELETE /mcp` (Bearer token), 19 tools: the staging tools, reads, and `wait_for_input` above — including `post_artifact` / `patch_artifact` (the v4 design surface) and `list_annotations` / `reply_annotation` / `resolve_annotation`.

## Stack

**Next.js 15 (App Router) + React 19 + TypeScript, Drizzle + SQLite (`better-sqlite3`) on the sprite's own persistent disk.** Tailwind 4 with shadcn-style theme tokens (all colours are CSS variables; the dark set applies by `prefers-color-scheme` media query — the app always follows the system scheme, with no toggle or setting), Phosphor icons. Preview snippets render in sandboxed iframes (`srcDoc`, `sandbox=""`) with an in-frame `color-scheme` declaration so unstyled snippets stay readable in both schemes. Artifacts render in layout mode in a **same-origin** `srcDoc` iframe (deliberately unsandboxed: Agentation's picking works inside same-origin frames; safety lives at the write gate — artifacts are script-free, enforced at `end_turn`). The annotator is **Agentation**: the `agentation` React package mounted in layout mode, plus `agentation-mcp` as a second `sprite-env` service on loopback 4747 (store at `~/.agentation/` on the sprite disk), reached only through the app's same-origin `/agentation-sync` rewrite and its action webhook. The MCP server uses the official `@modelcontextprotocol/sdk` (Streamable HTTP transport). Per-sprite state lives in `/home/sprite/app/data/` (SQLite `app.db` in WAL mode, `admin.token` 0600). One public hostname routes to port 8080; the app runs as a `sprite-env` service, not systemd. Logs are one structured JSON emit interface with closed result/reason vocabularies; entry content and tokens are never logged. Reach for something heavier (Postgres, a separate host) only when shared access or real concurrency outgrows the sprite's disk.

## Ops routes

- **Sprites CLI** (`sprite`): create/destroy sprites, `sprite exec -s <name>` to run commands inside, `sprite-env services` inside the sprite for the app service. This is the primary route — script deploys and repairs through it.
- **Fly's remote MCP server** at `https://fly.io/mcp` (OAuth) covers Sprites and Machines as an alternative ops surface. Note: reading a sprite's runtime state through it may wake a sleeping sprite.

## Hard rules

- **The record is append-only and verbatim.** Nothing overwrites a submitted word — not a later answer, not a redeploy, not a migration. Corrections are new entries. Drafts are the only mutable state, and autosave includes clears.
- **No built-in AI, ever.** The sprite makes no model calls and needs no `conn:*` labels. If a change would let the sprite reply on its own, the change is wrong for this design.
- **Structure before colour.** Design artifacts start as grayscale structure passes — layout, structure, hierarchy. Colour enters only after the structure is approved; a colour-first artifact is sent back to structure.
- **Always Agentation for annotation.** The inspector annotator is Agentation, integrated through its published npm packages — never vendored, forked, or replaced with a home-grown annotator. Its PolyForm Shield licence and copyright notice ship with the template (`template/THIRD-PARTY-NOTICES.md`) wherever the integration ships.
- **Artifacts stay script-free.** The `end_turn` page gate is never weakened: no scripts or inline handlers in any artifact, no external resources in `generated` artifacts, snapshots are static captures with scripts stripped at capture, and stable element ids are never dropped by a rewrite.
- **Dark/light follows the system only.** Never add a theme toggle, setting, or persisted colour-scheme choice. Scheme differences are theme-token differences, driven by `prefers-color-scheme`.
- **Question cards and the navigator show status only.** A card face and a navigator Questions row carry the prompt/key and a status word (Open / Answered / Skipped / Struck) — never answer content, dial values, or comments. Answer content lives only in the answer entry and the pane.
- **The answer pane never auto-closes or auto-advances on save.** Saving or skipping leaves the pane open on the same question; moving on is the human's explicit tap on **Next open question**, and closing is the human's explicit action.
- **Preview snippets stay sandboxed and script-free.** Variants render only in `sandbox=""` srcDoc iframes, and the `end_turn` snippet gate (no scripts, no external resources, CSS `url()` allowlist, 20,000-char cap) is never weakened — a snippet that cannot pass the gate is rewritten, not exempted.
- **Mobile browser testing is part of every iteration.** Before an iteration on a design sprite (new sprite, redeploy, any UI change) is called done, check it in a mobile browser viewport: open a question, open the answer pane, save an answer, and confirm the layout holds at phone width. A manual pass or an emulated device profile (e.g. Playwright) counts — automation is not required. Desktop-only verification is not done: the v3.5.1 thread-squeeze bug (answer pane crushing the thread to ~31px) shipped exactly that way.
- **Never ship `data/` in a deploy tarball.** The packaged staging dir's `data/` is removed and the tarball listing is checked before upload, every time.
- **Every question carries its escape hatches:** the app-added **Other** option inside the group (the typed text *is* the answer when selected) **plus a free-text comment** per question (a named choice + comment means the comment qualifies the choice). At most 9 named options, so Other always fits as the 10th. Never include Other yourself, never remove the comment.
- **One canonical template.** Per-sprite differences are the sprite name + its on-sprite admin token only — never fork the app for one sprite. Template changes land in `template/`, then redeploy.
- **Edit sprites in place by default.** Redeploy over the existing app dir, preserving `data/`, and verify the record is intact (entry count, question/score tallies, file versions) before and after. Snapshot first (`export_bundle` / `GET /api/export` + `GET /api/state`). Destroy-and-recreate is only the fallback for a sprite wedged beyond repair; throwaway sprites are destroyed with `sprite destroy -s <name> --force` (never without `--force` — the prompt hangs in non-interactive shells), and a sprite marked frozen is never interacted with at all.
- **The gate disposes.** Never weaken, bypass, or hand-edit the sharpness gate, question validation, or the Commit freeze to make a turn land. Fix the staged turn instead.
- **The model is the deliverable.** Answers without an updated `model.md` is a half-finished turn; the committed bundle — model, record, transcript — is what the human walks away with.
