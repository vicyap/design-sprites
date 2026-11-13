#!/bin/sh
set -e
cd /home/sprite/app
export DATA_DIR=/home/sprite/app/data
export PORT=8080 HOSTNAME=0.0.0.0
mkdir -p /home/sprite/app/data
# v3 sprites need NO conn:* labels - no AI calls are made by this app. Do NOT add conn:anthropic.
exec node server.js
