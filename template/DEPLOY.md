# Deploying the design-sprite v2 template to a Fly Sprite

One Phoenix app (`design_sprite`, version 2.0.0), deployed unchanged to
any number of sprites. The only per-sprite inputs are an optional admin
token and a `data/.env` config file. There is no seed file in v2: the
Project is created from the opening text box ("What do you want to
design?") or via `POST /api/project`.

## The built-in AI needs the Anthropic gateway connection

The sprite's own AI drives through the Sprites gateway's Anthropic
connection — the gateway injects the credentials; no API keys ever live
in the sprite.

- Label the sprite `conn:anthropic` at create time, or in ONE
  `sprite config update` call (that command REPLACES the whole label
  set — always pass the sprite's complete label set):
  `sprite config update -s <sprite> --label conn:anthropic`
- The app discovers the connection's base URL from inside the sprite at
  first use (`GET https://api.sprites.dev/v1/gateway/list`); pin it with
  `AI_GATEWAY_URL` in `data/.env` only if discovery is unavailable.
- The model defaults to `claude-fable-5-2`; override with `AI_MODEL`.

If the gateway AI is unreachable, the Project stays fully usable as a
record (chat, files, answering, manual question posting via the API) and
the failure is visible in the UI and the log — a failed AI turn never
writes to the record.

## Artifact

`release.tar.gz` (built with `MIX_ENV=prod mix release --overwrite < /dev/null`,
ERTS bundled) contains the release at its root plus `run.sh`:

```
bin/design_sprite   the release executable
lib/  releases/  erts-*/   release contents
run.sh              the service command (see below)
```

## Per-sprite deploy steps

1. Create / choose the sprite (in your Sprites org), with the
   `conn:anthropic` label (above). Do not reuse another project's sprite.
2. Copy the artifact onto the sprite and extract it as the app dir, e.g.
   `/home/sprite/app`:
   - `sprite exec` / sftp the tarball up, then
     `tar xzf release.tar.gz -C /home/sprite/app`
3. Set up the sprite's data dir (all state lives in `<app dir>/data`):
   - To pin the admin token, pre-place it at
     `/home/sprite/app/data/.admin_token` (mode 0600). Neither `run.sh`
     nor the app ever overwrites an existing token. If absent, the app
     generates one on first boot; read it back from that file after
     first boot and store it somewhere safe (mode 0600).
   - Write `data/.env` (0600) — the only per-sprite configuration
     surface besides the token:
     ```
     PHX_HOST=<sprite>-<suffix>.sprites.app
     SPRITE_NAME=<sprite>
     # optional: AI_MODEL=<gateway model id>
     # optional: AI_GATEWAY_URL=<gateway base URL>
     # optional: COMMIT_WEBHOOK_URL=<url>
     # optional: COMMIT_WEBHOOK_TOKEN=<bearer token>
     ```
     The Commit webhook, when configured, receives one POST on Commit
     carrying ids and a timestamp only (Bearer token when set). A
     webhook failure never blocks the Commit.
4. Register the service (services `--cmd` takes ONE executable; that is
   `run.sh`, which performs secret generation + migrate + start):
   ```
   sprite-env services create app --cmd /home/sprite/app/run.sh --dir /home/sprite/app --http-port 8080
   ```
   `run.sh` guarantees:
   - `data/` exists; `data/.secret_key_base` generated once (0600,
     python3 `secrets`, no shell pipelines) and reused after;
   - exports `PORT=8080`, `DATABASE_PATH=$APP_DIR/data/app.db`,
     `DATA_DIR`, `ADMIN_TOKEN_FILE=$APP_DIR/data/.admin_token`,
     `PHX_SERVER=true`;
   - runs `bin/design_sprite eval "DesignSprite.Release.migrate()"`
     (idempotent DDL) before `exec bin/design_sprite start`.
5. Make the URL public (url-auth: public) — the page is the human's
   front door, no login; the API routes stay behind the Bearer token.
6. Verify:
   - `GET https://<sprite>.sprites.app/health` →
     `{"ok":true,"app":"design_sprite","version":"2.0.0","project":…}`
     (the health check performs a real DB write+read probe; `project`
     is null until the Project is created).
   - The public page shows the opening text box (or the live Project).
   - `GET /api/state` with `Authorization: Bearer <token>` returns the
     Project state (project, entries, tally, files, driver holder).

## Redeploying (edit in place)

Redeploy the new release over the existing app dir, preserving `data/`
— never destroy-and-recreate a live sprite as the first resort.
Snapshot the state first (`GET /api/state` + `GET /api/export` with the
Bearer token) and verify after the redeploy that entries, tally, and
files are unchanged. A sprite marked frozen is never interacted with
at all.

## Runtime contracts

- Data dir: `<app dir>/data` (SQLite `app.db`, versioned Project files
  under `files/`, `.admin_token`, `.secret_key_base`, `.env` — secrets
  are 0600 where the app creates them).
- Env: `DATABASE_PATH`, `DATA_DIR`, `ADMIN_TOKEN_FILE`,
  `SECRET_KEY_BASE`, `PORT` (8080 on sprites), `PHX_SERVER=true`,
  `PHX_HOST`, `SPRITE_NAME`, optional `AI_MODEL`, `AI_GATEWAY_URL`,
  `COMMIT_WEBHOOK_URL`, `COMMIT_WEBHOOK_TOKEN`.
- HTTP: `GET /health` (no auth). Bearer token for everything under
  `/api/*` and `/mcp`; mutations additionally require holding the
  Driver lease (`driver_id`, explicit acquire, 10-minute TTL refreshed
  by mutating calls). Reads: `GET /api/state`, `GET /api/files`,
  `GET /api/files/content`, `GET /api/export`. Mutations:
  `POST /api/project`, `POST /api/driver/acquire|heartbeat|release`,
  `POST /api/messages`, `POST /api/questions`,
  `POST /api/questions/:key/answer|skip|strike|score`,
  `POST /api/decisions`, `POST /api/artifacts`,
  `POST /api/artifacts/snapshot`, `POST /api/artifacts/:name/patch`,
  `POST /api/model`, `POST /api/sharp`, `POST /api/resume`,
  `POST /api/commit`. MCP: `POST /mcp` (JSON-RPC 2.0, 22 tools mirroring
  the REST surface).
- Public read-only routes: `GET /` (the Project page), `GET /export`
  (the bundle zip), `GET /files/raw`, `GET /artifact/:name`,
  `GET /artifact/:name/v/:version`.
- After Commit the Project is read-only for design content on every
  surface (attempts return 409 `committed`); `POST /api/decisions`
  (the Decided-for-you log) is the one write that survives.
