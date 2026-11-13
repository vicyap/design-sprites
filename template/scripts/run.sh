#!/usr/bin/env bash
# run.sh — the design-sprite v2 release as a Sprite service.
#
# Layout contract:
#   APP_DIR  = the directory containing this script (the extracted release)
#   DATA_DIR = $APP_DIR/data  (persistent on the sprite disk)
#     data/app.db            SQLite database (DATABASE_PATH)
#     data/files/            the Project's versioned files + .history/
#     data/.admin_token      admin bearer token, 0600 — if a deploy
#                            pre-places it, that value wins and is never
#                            overwritten; otherwise generated on first boot
#     data/.secret_key_base  Phoenix secret, 0600, generated on first boot
#     data/.env              optional per-sprite deploy config (below)
#
# sprite-env services create app --cmd <abs path to run.sh> --dir <app dir> --http-port 8080
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# When run.sh sits at the release root (tarball layout), APP_DIR is its own dir.
if [ -x "$APP_DIR/bin/design_sprite" ]; then
  :
elif [ -x "$(dirname "${BASH_SOURCE[0]}")/bin/design_sprite" ]; then
  APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

DATA_DIR="$APP_DIR/data"
mkdir -p "$DATA_DIR"

# Optional per-sprite deploy config (KEY=VALUE lines, written by the
# deploy step — never by the template build): PHX_HOST (the sprite's
# public *.sprites.app hostname), SPRITE_NAME, AI_MODEL,
# AI_GATEWAY_URL, COMMIT_WEBHOOK_URL, COMMIT_WEBHOOK_TOKEN.
# This is the ONLY per-sprite configuration surface besides the admin
# token — code is identical across the fleet.
ENV_FILE="$DATA_DIR/.env"
if [ -s "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

SECRET_FILE="$DATA_DIR/.secret_key_base"
if [ ! -s "$SECRET_FILE" ]; then
  # python3 secrets: no shell pipeline, so this cannot die by SIGPIPE.
  python3 -c "import secrets, base64; print(base64.b64encode(secrets.token_bytes(64)).decode())" > "$SECRET_FILE.tmp"
  chmod 600 "$SECRET_FILE.tmp"
  mv "$SECRET_FILE.tmp" "$SECRET_FILE"
fi
export SECRET_KEY_BASE="$(cat "$SECRET_FILE")"

# Admin token: a pre-placed data/.admin_token wins; the app generates one
# on first boot (0600) when the file is absent. Never overwrite here.
export ADMIN_TOKEN_FILE="$DATA_DIR/.admin_token"

export PORT="${PORT:-8080}"
export DATABASE_PATH="$DATA_DIR/app.db"
export DATA_DIR
export MIX_ENV="prod"

# Migrate (idempotent DDL) before serving.
# PHX_SERVER=false for the eval boot so it never binds the port.
PHX_SERVER="false" "$APP_DIR/bin/design_sprite" eval "DesignSprite.Release.migrate()"

export PHX_SERVER="true"
exec "$APP_DIR/bin/design_sprite" start
