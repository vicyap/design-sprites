# Deploying the design-sprite v3.5 template to a Fly Sprite

One Next.js app (`design_sprite`, version 3.5.1-p1), deployed unchanged to
any number of sprites. The only per-sprite state is the admin token, which
the app generates on the sprite itself. There is no seed file and no
per-sprite config file: the Project is created by an external driver over
MCP (`create_project`) once the sprite is up.

v3.5 notes: dark/light always follows the OS/browser
`prefers-color-scheme` (theme tokens only — there is no toggle, setting,
or env var for it), and the app serves the `preview` question type
(sandboxed HTML-snippet variants + dials) alongside `single`/`multi`.
Neither changes deployment: no new env, no new labels, no new services.

## There is no built-in AI — and no gateway label

The sprite makes **no AI calls**. The interviewer is an external agent
(Muse / Claude Code) driving over MCP. Therefore:

- Create the sprite with **no `--label` flags at all**. v3.5 needs **NO
  `conn:*` labels** — do NOT add `conn:anthropic` (that was v2).
- No API keys or gateway URLs exist anywhere in this app.

## Build host: Node 24

The app pins `better-sqlite3` 11.10, which builds on **Node 24** (the
sprite runtime is Node 24). Node 26 cannot build it. Build with a Node 24
toolchain:

```
npm install
npm run typecheck   # tsc --noEmit
npm test            # 35 tests: node --test + tsx --test
npm run build       # Next.js standalone output (.next/standalone)
```

## Packaging — the data/ hard rule

`next build` executes the DB module at build-time import, which creates
`./data/app.db` in the build tree, and the standalone copy carries it.
**Shipping that `data/` in the deploy tarball overwrites the sprite's live
record.** It happened once (2026-11-13, on a scratch sprite). Therefore:

1. Stage the package: copy `.next/standalone/.` into a staging dir, copy
   `.next/static/.` into `<staging>/.next/static/`, copy `run.sh` in.
2. `rm -rf <staging>/data` — always.
3. Tar it, then **abort if `tar -tzf <pkg>.tgz` lists any `./data/` path**.
   Verify the count is 0 before uploading. No exceptions.

The tarball then contains the app only; extracting it over the sprite's
app dir preserves the sprite's own `data/` untouched.

## Per-sprite deploy steps

1. Create the sprite — no labels:

   ```
   sprite create <name> --skip-console
   sprite url update -s <name> --auth public
   ```

   The page is the human's front door (no login); `/mcp` and
   `/api/admin/*` stay behind the Bearer token.

2. Upload + extract the package as the app dir:

   ```
   sprite exec -s <name> --file <pkg>.tgz:/tmp/<pkg>.tgz -- sh -c "cd /home/sprite/app && tar -xzf /tmp/<pkg>.tgz"
   ```

3. Register the service (first deploy). `sprite-env`'s `--cmd` takes ONE
   executable path — `--cmd 'sh /home/sprite/app/run.sh'` is treated as a
   single filename and fails:

   ```
   sprite-env services create app --cmd /home/sprite/app/run.sh --dir /home/sprite/app --http-port 8080
   ```

   Later deploys: `sprite exec -s <name> -- sh -c "sprite-env services restart app"`.

   `run.sh` sets `DATA_DIR=/home/sprite/app/data`, `PORT=8080`, and execs
   the standalone server (`node server.js`).

4. Admin token: generated on first boot at
   `/home/sprite/app/data/admin.token` (mode 0600, never overwritten).
   Read it back from inside the sprite and store it safely (0600):

   ```
   sprite exec -s <name> -- cat /home/sprite/app/data/admin.token
   ```

5. Verify:

   - `GET https://<name>-<orgsuffix>.sprites.app/health` →
     `{"ok":true,"app":"design_sprite","version":"3.5.1-p1","db":"ok","entries":<n>}`
     (the health check does a real DB round trip).
   - The public page loads and shows the honest waiting-for-driver state.
   - An MCP client with the Bearer token can call `get_state` at
     `https://<name>-<orgsuffix>.sprites.app/mcp`; without the token it
     gets 401.

## Redeploying (edit in place)

Redeploy the new package over the existing app dir, preserving `data/` —
never destroy-and-recreate a live sprite as the first resort. Snapshot
first (MCP `export_bundle`, or `GET /api/export` + `GET /api/state`) and
verify after the redeploy that the entry count, question/score tallies,
and file versions are unchanged. A sprite marked frozen is never
interacted with at all. Throwaway sprites are destroyed with
`sprite destroy -s <name> --force` (the prompt hangs without `--force`
in non-interactive shells).

## Runtime contracts

- Data dir: `/home/sprite/app/data` on the sprite's persistent disk —
  SQLite `app.db` (WAL) + `admin.token` (0600). Nothing else is state.
- Env: `DATA_DIR`, `PORT` (8080). No AI env, no gateway env.
- HTTP: `GET /health` (no auth, DB round trip). Human UI paths are
  same-origin without a token (`POST /api/entries`, `GET /api/state`,
  drafts, `POST /api/commit`, `GET /api/files`, `GET /api/export`).
  `POST /api/admin/entries` requires the Bearer token.
- MCP: Streamable HTTP at `/mcp`, Bearer-token gated, 16 tools — the
  staged turn protocol (`create_project`, `post_message`, `post_question`,
  `write_model`, `score_answer`, `declare_sharp`, `end_turn`,
  `discard_turn`), reads (`get_state`, `get_record`, `list_files`,
  `get_file`, `export_bundle`), `wait_for_input`, plus `post_artifact` /
  `patch_artifact`, which exist only for carrying v2 files forward as
  preserved files during migration — not a v3.5 authoring surface.
  `post_question` accepts type `preview` with `variants` + optional
  `dials`; the `end_turn` gate enforces snippet safety (script-free, no
  external resources, CSS `url()` allowlist) and the 20,000-char snippet
  cap (`MAX_SNIPPET_CHARS`).
- After Commit the Project is read-only for design content on every
  surface (web writes get HTTP 409 `commit_freeze`; MCP staging is
  rejected with the same structured error). Reads and export keep working.
