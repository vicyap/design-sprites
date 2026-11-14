# ds-wake — optional driver wake-up via Claude Code Channels (F5)

Optional enhancement. The design sprite itself is unchanged: no sprite code,
no `conn:*` labels, no built-in AI. `wait_for_input` remains fully functional
and is the fallback whenever this bridge is not running.

## What it is

`bridge.mjs` is a local stdio MCP server that runs on the driver machine,
next to Claude Code (a Claude Code channel must be a local stdio server —
the sprite's remote HTTP MCP cannot be a channel). It polls the sprite's
`GET /api/entries` every 3 seconds and, for each new `role=human` entry,
emits a `notifications/claude/channel` event into the running Claude Code
session, so the driver learns of a human answer/message promptly instead of
only on its next `wait_for_input` poll. Events arrive only while the session
is open. Channels is a Claude Code research preview.

## Setup

The bridge uses `@modelcontextprotocol/sdk` from the app's own
`node_modules` — run it from a checkout of this app after installing the
app's dependencies, or point the command at a checkout that has them.

Add a `.mcp.json` on the driver machine:

```json
{
  "mcpServers": {
    "ds-channel": {
      "command": "node",
      "args": ["<path-to-app>/tools/ds-wake/bridge.mjs"],
      "env": {
        "DS_BASE": "https://<your-sprite>.sprites.app",
        "DS_POLL_MS": "3000"
      }
    }
  }
}
```

- `DS_BASE` (required in practice): the target sprite's base URL. The value
  compiled into `bridge.mjs` is only the proof sprite's URL.
- `DS_POLL_MS`: poll interval in milliseconds (default 3000).

## Run

Start an interactive Claude Code session with the development-channels
flag (custom channels are not allowlisted during the research preview):

```sh
claude --mcp-config .mcp.json --dangerously-load-development-channels server:ds-channel
```

The flag only registers the channel in an interactive session. If the
channel does not register, or an organisation policy blocks channels,
events are dropped silently — in that case the driver simply continues on
`wait_for_input`, unchanged.

## Proof

End-to-end proof passed on ds-v3-dev on 2026-11-14: a human message posted
via the sprite API arrived in an idle Claude Code session as a
`<channel source="ds-channel">` event ~2.8 s after the entry was created,
with no polling by the session. Evidence:
recorded in the v3.6 build workspace (2026-11-14).
