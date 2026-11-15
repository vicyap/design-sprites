// Design Sprites channel bridge (P3/F5 proof) — LOCAL stdio MCP server.
// Runs on the driver machine next to Claude Code. Polls the sprite's public
// entries API and pushes notifications/claude/channel for new HUMAN entries.
// The sprite itself is unchanged; wait_for_input remains the fallback.
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';

const BASE = process.env.DS_BASE || 'https://ds-v3-dev-c7hp.sprites.app';
const POLL_MS = Number(process.env.DS_POLL_MS || 3000);
const log = (...a) => console.error('[ds-channel]', new Date().toISOString(), ...a);

const mcp = new Server(
  { name: 'ds-channel', version: '0.1.0' },
  {
    capabilities: { experimental: { 'claude/channel': {} } },
    instructions:
      'Design Sprite wake-up channel. When a <channel source="ds-channel"> event arrives, a human has added an entry (answer or message) on the design sprite. Fetch the new entries with the design-sprite MCP tools (get_record / wait_for_input) and continue driving. Events only arrive while this session is open.',
  },
);

let seen = -1; // max entry id already known; -1 = not yet initialised

async function tick() {
  try {
    // v3.7 F1: identify as the wake bridge so the sprite stamps driver
    // presence from these polls (the bridge runs only while a driver
    // session is open, so the heartbeat is honest).
    const r = await fetch(`${BASE}/api/entries`, { headers: { 'x-ds-wake': '1' } });
    if (!r.ok) { log('poll http', r.status); return; }
    const { entries } = await r.json();
    if (seen < 0) {
      seen = entries.reduce((m, e) => Math.max(m, e.id), 0);
      log('initialised at head', seen);
      return;
    }
    for (const e of entries) {
      if (e.id <= seen) continue;
      seen = e.id;
      if (e.role !== 'human') continue;
      const body = String(e.body || '').slice(0, 500);
      log('pushing channel event for entry', e.id, e.kind);
      await mcp.notification({
        method: 'notifications/claude/channel',
        params: {
          content: `New human ${e.kind} (entry ${e.id}) on the design sprite: ${body}`,
          meta: { entry_id: String(e.id), kind: String(e.kind || 'entry') },
        },
      });
    }
  } catch (err) {
    log('poll error', String(err && err.message || err));
  }
}

await mcp.connect(new StdioServerTransport());
log('connected, polling', BASE, 'every', POLL_MS, 'ms');
setInterval(tick, POLL_MS);
tick();
