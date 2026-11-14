import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js';
import { z } from 'zod';
import { checkToken, entriesSince, getHead } from '@/lib/db';
import * as store from '@/lib/store';
import { emit } from '@/lib/observe';
import { APP_VERSION } from '@/lib/version';

export const dynamic = 'force-dynamic';

// Design Sprites v3 MCP server — the ONLY driver surface. Streamable HTTP,
// stateless, gated by the same admin Bearer token as the admin API.
// Staging tools append to one open turn; end_turn commits atomically.
// Nothing staged is visible in the record or UI before end_turn commits.

function ok(data: any) { return { content: [{ type: 'text' as const, text: JSON.stringify(data, null, 1) }] }; }
function err(errors: any) { return { isError: true, content: [{ type: 'text' as const, text: JSON.stringify({ ok: false, errors }, null, 1) }] }; }
function stage(tool: string, args: any) {
  const r = store.stageAction(tool, args);
  return r.ok ? ok(r) : err(r.errors);
}

function buildServer() {
  const server = new McpServer({ name: 'design-sprite-v3', version: APP_VERSION });

  server.tool('create_project', 'Stage project creation: set the want (and optional title) on this sprite\u2019s single project. Commits at end_turn.', {
    want: z.string().min(1), title: z.string().optional(),
  }, async (a) => stage('create_project', a));

  server.tool('post_message', 'Stage a driver message into the open turn. Visible only after end_turn commits.', {
    body: z.string().min(1),
  }, async (a) => stage('post_message', a));

  server.tool('post_question', 'Stage a question card. Other is added automatically INSIDE the option group at commit; pass at most 9 named options. Types: single, multi, preview. Preview (v3.5): 2-4 variants, each {id, label, html} where html is a SMALL SELF-CONTAINED snippet (max 20000 chars; inline styles/SVG and embedded data:image or #fragment CSS url() only — no scripts, no external src/href/poster/background, no other CSS url(); the end_turn gate rejects unsafe or oversized snippets). Options may be omitted for preview (derived from variant ids) or passed explicitly (then values must cover variant ids exactly). Optional question-level dials: [{id, label, min, max, step, default, unit?}] — slider values the human sets; dial values are answer data, never scored. prediction is your predicted answer (option value / variant id, or array for multi).', {
    key: z.string().min(1),
    type: z.enum(['single', 'multi', 'preview']),
    prompt: z.string().min(1),
    load_bearing: z.boolean().optional(),
    options: z.array(z.object({ value: z.string().min(1), label: z.string().min(1) })).optional(),
    prediction: z.union([z.string(), z.array(z.string())]).nullable().optional(),
    recommended: z.string().nullable().optional(),
    variants: z.array(z.object({ id: z.string().min(1), label: z.string().min(1), html: z.string().min(1) })).optional(),
    dials: z.array(z.object({ id: z.string().min(1), label: z.string().min(1), min: z.number(), max: z.number(), step: z.number(), default: z.number(), unit: z.string().optional() })).optional(),
  }, async (a) => stage('post_question', a));

  server.tool('post_artifact', 'Stage a new versioned artifact file (full content). Stable element ids (id="...") in HTML must be unique, and a rewrite of an existing path must keep all previous element ids.', {
    path: z.string().min(1), content: z.string(),
  }, async (a) => stage('post_artifact', a));

  server.tool('patch_artifact', 'Stage a new version of an existing artifact file (full content; patch-only is dropped in v3, but stable element ids are still enforced).', {
    path: z.string().min(1), content: z.string(),
  }, async (a) => stage('patch_artifact', a));

  server.tool('write_model', 'Stage a full write of model.md (re-derived from the verbatim record, never a summary). Commits as a new file version at end_turn.', {
    content: z.string().min(1),
  }, async (a) => stage('write_model', a));

  server.tool('score_answer', 'Stage a judgement of a provisional score. judgement: hit | miss | skip (prediction stands, not a hit; requires a skipped answer) | strike (removes the axis). A build-changing comment is a miss: pass judgement "miss" with reason "build_changing_comment". Other-chosen answers are deterministic misses.', {
    question_key: z.string().min(1),
    judgement: z.enum(['hit', 'miss', 'skip', 'strike']),
    reason: z.string().optional(),
  }, async (a) => stage('score_answer', a));

  server.tool('declare_sharp', 'Declare the model sharp. The deterministic gate (>=3 answered load-bearing, 3 most recent load-bearing scores all final hits, no load-bearing open or skipped) is checked immediately and again at end_turn; a failing declaration is rejected with structured errors.', {}, async () => stage('declare_sharp', {}));

  server.tool('end_turn', 'Commit the open turn atomically. Gates: stale head, Commit freeze, question validation, provisional judgement completeness, sharpness. A rejection returns structured errors and leaves the turn OPEN for restaging.', {}, async () => {
    const r = store.endTurn();
    return r.ok ? ok(r) : err(r.errors);
  });

  server.tool('discard_turn', 'Discard the open turn and all its staged actions without committing.', {}, async () => ok(store.discardTurn()));

  server.tool('get_state', 'Current project state: head, questions with states and scores, sharpness gate status, open turn, files.', {}, async () => ok(store.getState()));

  server.tool('get_record', 'Record entries (verbatim, append-only) with id greater than `since` (default 0 = all).', {
    since: z.number().int().min(0).optional(),
  }, async (a) => ok({ head: getHead(), entries: entriesSince(a.since ?? 0) }));

  server.tool('list_files', 'List versioned files (artifacts + model.md) with latest version numbers.', {}, async () => ok({ files: store.listFiles() }));

  server.tool('get_file', 'Read a versioned file (latest version unless `version` is given).', {
    path: z.string().min(1), version: z.number().int().positive().optional(),
  }, async (a) => {
    const f = store.getFileVersion(a.path, a.version);
    return f ? ok(f) : err([{ code: 'not_found', message: `no file at ${a.path}` }]);
  });

  server.tool('export_bundle', 'Export the whole project as a bundle object: project, verbatim entries, latest file contents, transcript markdown.', {}, async () => ok(store.exportBundle()));

  server.tool('wait_for_input', 'Blocking long-poll: returns new HUMAN entries (answers, messages) since `since` head as soon as any arrive, or times out cleanly ({timed_out:true}) so you can re-call. Default timeout 20000ms, max 50000ms.', {
    since: z.number().int().min(0),
    timeout_ms: z.number().int().min(0).max(50000).optional(),
  }, async (a) => {
    const deadline = Date.now() + (a.timeout_ms ?? 20000);
    for (;;) {
      const fresh = entriesSince(a.since).filter((e: any) => e.role === 'human');
      if (fresh.length) { emit('mcp.wait_for_input', 'succeeded', 'ok', { count: fresh.length }); return ok({ timed_out: false, head: getHead(), entries: fresh }); }
      if (Date.now() >= deadline) { emit('mcp.wait_for_input', 'succeeded', 'ok', { count: 0 }); return ok({ timed_out: true, head: getHead(), entries: [] }); }
      await new Promise((r) => setTimeout(r, 500));
    }
  });

  return server;
}

async function handle(req: Request) {
  if (!checkToken(req)) { emit('mcp.request', 'failed', 'auth_failed'); return Response.json({ error: 'unauthorized' }, { status: 401 }); }
  const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  const server = buildServer();
  await server.connect(transport);
  return transport.handleRequest(req);
}

export async function POST(req: Request) { return handle(req); }
export async function GET(req: Request) { return handle(req); }
export async function DELETE(req: Request) { return handle(req); }
