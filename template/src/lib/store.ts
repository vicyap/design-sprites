// Design Sprites v3 — record store + staged turn protocol (DB layer).
// Invariants: entries are append-only and verbatim; staged actions are
// invisible until end_turn commits them atomically in one transaction;
// end_turn gates run inside that transaction and any rejection rolls back
// with the turn left OPEN for restaging. No locks, no merging: a turn whose
// base_head no longer equals the record head is rejected as stale.
import crypto from 'node:crypto';
import { sqlite, ensureProject, getProject, getHead, insertEntry, listEntries, safeParse } from './db';
import { validateQuestion, withOther, provisionalScore, judgementScore, deriveQuestions, sharpnessGate, validateArtifactIds, extractElementIds, type GateError, type QuestionPayload } from './protocol';
import { buildZip, type ZipEntry } from './zip';
import { emit } from './observe';

export const COMMIT_FREEZE_ERROR: GateError = { code: 'commit_freeze', message: 'project is committed; design content is frozen read-only' };
export function isCommitted(): boolean { return getProject().status === 'committed'; }

export { getProject, getHead, listEntries };

const DRIVER_WRITE_TOOLS = ['post_message', 'post_question', 'post_artifact', 'patch_artifact', 'write_model', 'score_answer', 'declare_sharp', 'create_project'];

export interface Turn { id: string; projectId: string; baseHead: number; status: string; createdAt: string }
interface StagedAction { id: number; turnId: string; seq: number; tool: string; args: any }

export function getOpenTurn(): (Turn & { actions: StagedAction[] }) | null {
  const pid = ensureProject();
  const t = sqlite.prepare("SELECT id,project_id as projectId,base_head as baseHead,status,created_at as createdAt FROM staged_turns WHERE project_id=? AND status='open' ORDER BY created_at ASC LIMIT 1").get(pid) as any;
  if (!t) return null;
  const actions = (sqlite.prepare("SELECT id,turn_id as turnId,seq,tool,args FROM staged_actions WHERE turn_id=? ORDER BY seq ASC").all(t.id) as any[]).map((a) => ({ ...a, args: safeParse(a.args) }));
  return { ...t, actions };
}

// Decided-for-you (P2): the first staging call opens the turn against the
// current head; while a turn is open, further staging calls append to it
// (one open turn per project — ordering comes from stale-head rejection at
// end_turn, not from locks).
export function stageAction(tool: string, args: any): { ok: true; turn_id: string; base_head: number; staged_count: number } | { ok: false; errors: GateError[] } {
  const pid = ensureProject();
  const project = getProject();
  if (project.status === 'committed' && DRIVER_WRITE_TOOLS.includes(tool)) {
    return { ok: false, errors: [{ code: 'commit_freeze', message: 'project is committed; design content is frozen read-only' }] };
  }
  if (tool === 'declare_sharp') {
    // declare_sharp disposes at stage time too: evaluate the gate against the
    // committed record plus scores already staged in the open turn. A failing
    // declaration is rejected with structured errors and is NOT staged;
    // end_turn re-checks the gate regardless.
    const entriesNow = listEntries() as any[];
    const vQuestions = deriveQuestions(entriesNow);
    const vByKey = new Map(vQuestions.map((q) => [q.key, q]));
    const open = getOpenTurn();
    if (open) for (const a of open.actions) {
      if (a.tool === 'score_answer') { const vq = vByKey.get(a.args?.question_key); const base = vByKey.get(a.args?.question_key); if (vq && base) { const j: any = judgementScore(a.args.judgement, a.args.reason, base.answer); if (!('code' in j)) vq.score = j; } }
      if (a.tool === 'post_question') vQuestions.push({ key: a.args.key, question: a.args, askedId: 0, state: 'open' });
    }
    for (const vq of vQuestions) { if (vq.score?.result === 'struck') vq.state = 'struck'; else if (vq.answer?.skipped) vq.state = 'skipped'; else if (vq.answer) vq.state = 'answered'; else vq.state = 'open'; }
    const gate = sharpnessGate(vQuestions);
    if (!gate.sharp) return { ok: false, errors: gate.errors };
  }
  let turn = getOpenTurn();
  if (!turn) {
    const id = 'turn_' + crypto.randomBytes(6).toString('hex');
    sqlite.prepare("INSERT INTO staged_turns(id,project_id,base_head,status,created_at) VALUES(?,?,?,?,?)").run(id, pid, getHead(), 'open', new Date().toISOString());
    turn = getOpenTurn();
    if (!turn) return { ok: false, errors: [{ code: 'unknown', message: 'could not open a turn' }] };
  }
  const seq = (turn.actions.length ? Math.max(...turn.actions.map((a) => a.seq)) : 0) + 1;
  sqlite.prepare("INSERT INTO staged_actions(turn_id,seq,tool,args,created_at) VALUES(?,?,?,?,?)").run(turn.id, seq, tool, JSON.stringify(args ?? {}), new Date().toISOString());
  emit('mcp.stage', 'succeeded', 'ok', { tool, turn: turn.id });
  return { ok: true, turn_id: turn.id, base_head: turn.baseHead, staged_count: turn.actions.length + 1 };
}

export function discardTurn(): { ok: boolean; discarded?: string } {
  const turn = getOpenTurn();
  if (!turn) return { ok: false };
  const tx = sqlite.transaction(() => {
    sqlite.prepare("DELETE FROM staged_actions WHERE turn_id=?").run(turn.id);
    sqlite.prepare("UPDATE staged_turns SET status='discarded' WHERE id=?").run(turn.id);
  });
  tx();
  emit('mcp.discard_turn', 'succeeded', 'ok', { turn: turn.id });
  return { ok: true, discarded: turn.id };
}

// Latest file version helpers (artifacts and model.md are versioned files).
export function latestFile(path: string): { path: string; version: number; content: string; createdAt: string } | null {
  const pid = ensureProject();
  const r = sqlite.prepare("SELECT path,version,content,created_at as createdAt FROM file_versions WHERE project_id=? AND path=? ORDER BY version DESC LIMIT 1").get(pid, path) as any;
  return r || null;
}
export function listFiles() {
  const pid = ensureProject();
  const rows = sqlite.prepare("SELECT path, MAX(version) as version, COUNT(*) as versions FROM file_versions WHERE project_id=? GROUP BY path ORDER BY path ASC").all(pid) as any[];
  return rows.map((r) => ({ path: r.path, version: r.version, versions: r.versions, bytes: (latestFile(r.path)?.content || '').length }));
}
export function getFileVersion(path: string, version?: number): { path: string; version: number; content: string; createdAt: string } | null {
  const pid = ensureProject();
  const r = version
    ? sqlite.prepare("SELECT path,version,content,created_at as createdAt FROM file_versions WHERE project_id=? AND path=? AND version=?").get(pid, path, version) as any
    : (latestFile(path) as any);
  return r || null;
}
function writeFileVersion(projectId: string, path: string, content: string): number {
  const cur = sqlite.prepare("SELECT COALESCE(MAX(version),0) as v FROM file_versions WHERE project_id=? AND path=?").get(projectId, path) as { v: number };
  const v = cur.v + 1;
  sqlite.prepare("INSERT INTO file_versions(project_id,path,version,content,created_at) VALUES(?,?,?,?,?)").run(projectId, path, v, content, new Date().toISOString());
  return v;
}

// --- Drafts (P3): answer drafts autosave like v2 — human typing survives
// reloads with no driver present. One draft per question; saving overwrites
// the draft only (the record itself stays append-only). Draft edits are
// design content: frozen after Commit.
export interface DraftPayload { choice?: string | null; choices?: string[] | null; other_text?: string; comment?: string }
export function saveDraft(questionKey: string, draft: DraftPayload) {
  if (isCommitted()) return { ok: false as const, errors: [COMMIT_FREEZE_ERROR] };
  const pid = ensureProject();
  const payload = { choice: draft.choice ?? null, choices: draft.choices ?? null, other_text: draft.other_text || '', comment: draft.comment || '' };
  const now = new Date().toISOString();
  sqlite.prepare("INSERT INTO drafts(project_id,question_key,payload,updated_at) VALUES(?,?,?,?) ON CONFLICT(project_id,question_key) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at").run(pid, questionKey, JSON.stringify(payload), now);
  emit('drafts.save', 'succeeded', 'ok', {});
  return { ok: true as const, draft: { question_key: questionKey, ...payload, updated_at: now } };
}
export function listDrafts(): { question_key: string; choice: string | null; choices: string[] | null; other_text: string; comment: string; updated_at: string }[] {
  const pid = ensureProject();
  const rows = sqlite.prepare("SELECT question_key,payload,updated_at FROM drafts WHERE project_id=? ORDER BY question_key ASC").all(pid) as any[];
  return rows.map((r) => ({ question_key: r.question_key, ...safeParse(r.payload), updated_at: r.updated_at }));
}
export function getDraft(questionKey: string) { return listDrafts().find((d) => d.question_key === questionKey) || null; }
export function deleteDraft(questionKey: string) {
  const pid = ensureProject();
  sqlite.prepare("DELETE FROM drafts WHERE project_id=? AND question_key=?").run(pid, questionKey);
}

// Human message path with the Commit freeze enforced server-side (the UI
// hiding the composer is not the enforcement — this is).
export function addHumanMessage(body: string) {
  if (isCommitted()) return { ok: false as const, errors: [COMMIT_FREEZE_ERROR] };
  const pid = ensureProject();
  const entry = insertEntry(pid, 'message', 'human', body, {});
  emit('entries.create', 'succeeded', 'ok', { id: entry.id });
  return { ok: true as const, entry };
}

// Commit (human press): freezes design content read-only. Idempotent —
// pressing again reports the existing freeze instead of erroring.
export function commitProject() {
  const pid = ensureProject();
  const project = getProject();
  if (project.status === 'committed') return { ok: true as const, already: true, project };
  const now = new Date().toISOString();
  let entry: any;
  const tx = sqlite.transaction(() => {
    sqlite.prepare("UPDATE projects SET status='committed', committed_at=? WHERE id=?").run(now, pid);
    entry = insertEntry(pid, 'commit', 'human', 'Project committed — design content is now read-only.', {});
  });
  tx();
  emit('project.commit', 'succeeded', 'ok', { id: entry.id });
  return { ok: true as const, already: false, project: getProject(), entry };
}

// Human path: an answer is stored IMMEDIATELY (never waits for a driver),
// together with its deterministic provisional score, in one transaction.
export function addHumanAnswer(args: { question_key: string; choice?: string | null; choices?: string[] | null; other_text?: string; comment?: string; skipped?: boolean }) {
  if (isCommitted()) return { ok: false as const, errors: [COMMIT_FREEZE_ERROR] };
  const pid = ensureProject();
  const questions = deriveQuestions(listEntries() as any);
  const qs = questions.find((q) => q.key === args.question_key);
  if (!qs) return { ok: false as const, errors: [{ code: 'unknown_question', message: `no question with key ${args.question_key}` }] };
  const answerPayload = { question_key: args.question_key, choice: args.choice ?? null, choices: args.choices ?? null, other_text: args.other_text || '', comment: args.comment || '', skipped: !!args.skipped, superseding: false };
  let answer: any; let score: any;
  const tx = sqlite.transaction(() => {
    answer = insertEntry(pid, 'answer', 'human', '', answerPayload);
    const prov = provisionalScore(qs.question, answerPayload);
    score = insertEntry(pid, 'score', 'system', '', { ...prov, superseding: false });
    // A submitted answer consumes its draft (same transaction).
    sqlite.prepare("DELETE FROM drafts WHERE project_id=? AND question_key=?").run(pid, args.question_key);
  });
  tx();
  emit('entries.answer', 'succeeded', 'ok', { id: answer.id });
  return { ok: true as const, answer, score };
}

export function endTurn(): { ok: boolean; errors?: GateError[]; head?: number; turn_id?: string; committed?: { tool: string; entry_id?: number }[] } {
  const pid = ensureProject();
  const turn = getOpenTurn();
  if (!turn) return { ok: false, errors: [{ code: 'no_open_turn', message: 'no open turn to commit; stage an action first' }] };
  const errors: GateError[] = [];
  const committed: { tool: string; entry_id?: number }[] = [];
  let newHead = getHead();
  try {
    const tx = sqlite.transaction(() => {
      // Gate 1: stale head — the record moved since this turn was staged.
      const headNow = getHead();
      if (turn.baseHead !== headNow) throw { gate: [{ code: 'stale_head', message: `turn was staged against head ${turn.baseHead} but record head is now ${headNow}; re-read and restage`, }] as GateError[] };
      // Gate 2: Commit freeze.
      const project = getProject();
      if (project.status === 'committed') throw { gate: [{ code: 'commit_freeze', message: 'project is committed; design content is frozen read-only' }] as GateError[] };

      const entriesNow = listEntries() as any[];
      const questionsNow = deriveQuestions(entriesNow);
      const byKey = new Map(questionsNow.map((q) => [q.key, q]));

      // Virtual state: staged scores applied over committed state, so a turn
      // that judges provisionals and declares sharp in one go is judged fairly.
      const virtualScores = new Map<string, any>();
      for (const q of questionsNow) if (q.score) virtualScores.set(q.key, q.score);

      // Gate 3: per-action validation.
      const stagedKeys = new Set<string>();
      for (const a of turn.actions) {
        if (a.tool === 'post_question') {
          const errs = validateQuestion(a.args, new Set([...byKey.keys(), ...stagedKeys]));
          errors.push(...errs); if (!errs.length) stagedKeys.add(a.args.key);
        } else if (a.tool === 'score_answer') {
          const q = byKey.get(a.args?.question_key);
          if (!q) errors.push({ code: 'unknown_question', message: `score_answer references unknown question ${a.args?.question_key}`, question_key: a.args?.question_key });
          else if (!q.answer && a.args?.judgement !== 'strike') errors.push({ code: 'no_answer', message: `question ${q.key} has no answer to judge`, question_key: q.key });
          else {
            const judged = judgementScore(a.args?.judgement, a.args?.reason, q.answer);
            if ('code' in judged) errors.push(judged as GateError); else virtualScores.set(q.key, judged);
          }
        } else if (a.tool === 'post_artifact' || a.tool === 'patch_artifact') {
          const prev = latestFile(a.args?.path || '');
          if (a.tool === 'patch_artifact' && !prev) errors.push({ code: 'not_found', message: `patch_artifact: no existing file at ${a.args?.path}` });
          if (typeof a.args?.content !== 'string') errors.push({ code: 'validation', message: 'artifact content (string) is required' });
          else errors.push(...validateArtifactIds(a.args.path, a.args.content, prev ? extractElementIds(prev.content) : null));
        } else if (a.tool === 'write_model') {
          if (typeof a.args?.content !== 'string' || !a.args.content.trim()) errors.push({ code: 'validation', message: 'write_model content is required' });
        } else if (a.tool === 'post_message') {
          if (typeof a.args?.body !== 'string' || !a.args.body.trim()) errors.push({ code: 'validation', message: 'post_message body is required' });
        } else if (a.tool === 'create_project') {
          if (project.want) errors.push({ code: 'project_exists', message: 'project already has a want; one project per sprite' });
          if (typeof a.args?.want !== 'string' || !a.args.want.trim()) errors.push({ code: 'validation', message: 'create_project want is required' });
        }
      }
      if (errors.length) throw { gate: errors };

      // Gate 4: provisional-score judgement completeness — every question
      // whose current (virtual) score is still provisional blocks the commit.
      const unjudged: string[] = [];
      for (const q of questionsNow) {
        const s = virtualScores.get(q.key);
        if (s && s.provisional === true) unjudged.push(q.key);
      }
      if (unjudged.length) throw { gate: unjudged.map((k) => ({ code: 'provisional_unjudged', message: `provisional score for ${k} must be judged via score_answer before end_turn`, question_key: k })) as GateError[] };

      // Gate 5: sharpness — evaluated on virtual state (committed record +
      // this turn's staged scores and questions applied).
      if (turn.actions.some((a) => a.tool === 'declare_sharp')) {
        const virtualQuestions = deriveQuestions(entriesNow as any);
        const vByKey = new Map(virtualQuestions.map((q) => [q.key, q]));
        for (const [k, s] of virtualScores) { const vq = vByKey.get(k); if (vq) vq.score = s; }
        for (const a of turn.actions) if (a.tool === 'post_question') {
          virtualQuestions.push({ key: a.args.key, question: a.args, askedId: 0, state: 'open' });
        }
        // Recompute states after virtual score application.
        for (const vq of virtualQuestions) {
          if (vq.score?.result === 'struck') vq.state = 'struck';
          else if (vq.answer?.skipped) vq.state = 'skipped';
          else if (vq.answer) vq.state = 'answered';
          else vq.state = 'open';
        }
        const gate = sharpnessGate(virtualQuestions);
        if (!gate.sharp) throw { gate: gate.errors };
      }

      // All gates passed: apply staged actions atomically, in staged order.
      for (const a of turn.actions) {
        if (a.tool === 'create_project') {
          sqlite.prepare("UPDATE projects SET want=?, title=COALESCE(?,title) WHERE id=?").run(a.args.want, a.args.title ?? null, pid);
          const e = insertEntry(pid, 'want', 'human', a.args.want, {});
          committed.push({ tool: a.tool, entry_id: e.id });
        } else if (a.tool === 'post_message') {
          const e = insertEntry(pid, 'message', 'driver', a.args.body, {});
          committed.push({ tool: a.tool, entry_id: e.id });
        } else if (a.tool === 'post_question') {
          const payload: QuestionPayload = { ...a.args, options: withOther(a.args.options) };
          const e = insertEntry(pid, 'question', 'driver', a.args.prompt, payload);
          committed.push({ tool: a.tool, entry_id: e.id });
        } else if (a.tool === 'score_answer') {
          const q = byKey.get(a.args.question_key);
          const judged: any = judgementScore(a.args.judgement, a.args.reason, q?.answer);
          const e = insertEntry(pid, 'score', 'driver', '', { ...judged, question_key: a.args.question_key, superseding: false });
          committed.push({ tool: a.tool, entry_id: e.id });
        } else if (a.tool === 'post_artifact' || a.tool === 'patch_artifact') {
          const v = writeFileVersion(pid, a.args.path, a.args.content);
          const e = insertEntry(pid, 'artifact', 'driver', '', { path: a.args.path, version: v });
          committed.push({ tool: a.tool, entry_id: e.id });
        } else if (a.tool === 'write_model') {
          const v = writeFileVersion(pid, 'model.md', a.args.content);
          const e = insertEntry(pid, 'model', 'driver', '', { path: 'model.md', version: v });
          committed.push({ tool: a.tool, entry_id: e.id });
        } else if (a.tool === 'declare_sharp') {
          const e = insertEntry(pid, 'sharp', 'driver', '', { event: 'sharp' });
          committed.push({ tool: a.tool, entry_id: e.id });
        }
      }
      sqlite.prepare("UPDATE staged_turns SET status='committed', committed_at=? WHERE id=?").run(new Date().toISOString(), turn.id);
      sqlite.prepare("DELETE FROM staged_actions WHERE turn_id=?").run(turn.id);
      newHead = getHead();
    });
    tx();
  } catch (err: any) {
    if (err && err.gate) {
      emit('mcp.end_turn', 'failed', 'validation', { turn: turn.id, errors: (err.gate as GateError[]).length });
      return { ok: false, errors: err.gate as GateError[], turn_id: turn.id, head: getHead() };
    }
    throw err;
  }
  emit('mcp.end_turn', 'succeeded', 'ok', { turn: turn.id, head: newHead, actions: committed.length });
  return { ok: true, turn_id: turn.id, head: newHead, committed };
}

export function getState() {
  const entries = listEntries() as any[];
  const questions = deriveQuestions(entries);
  const gate = sharpnessGate(questions);
  const project = getProject();
  const turn = getOpenTurn();
  return {
    project: { id: project.id, title: project.title, want: project.want, status: project.status, committed_at: project.committedAt },
    head: getHead(),
    entries: entries.length,
    sharp_declared: entries.some((e) => e.kind === 'sharp'),
    sharpness: { sharp: gate.sharp, answered_load_bearing: gate.answered_load_bearing, errors: gate.errors.map((e) => e.code) },
    questions: questions.map((q) => ({ key: q.key, type: q.question.type, load_bearing: !!q.question.load_bearing, state: q.state, score: q.score ? { result: q.score.result, provisional: q.score.provisional, reason: q.score.reason } : null })),
    open_turn: turn ? { id: turn.id, base_head: turn.baseHead, staged: turn.actions.map((a) => a.tool) } : null,
    files: listFiles(),
  };
}

export function listAllFileVersions(): { path: string; version: number; content: string; createdAt: string }[] {
  const pid = ensureProject();
  return sqlite.prepare("SELECT path,version,content,created_at as createdAt FROM file_versions WHERE project_id=? ORDER BY path ASC, version ASC").all(pid) as any[];
}

// Full UI state for the human surface: verbatim entries, full question
// payloads with answers + scores, files, drafts, sharpness. Read-only.
export function getUiState() {
  const entries = listEntries() as any[];
  const questions = deriveQuestions(entries);
  const gate = sharpnessGate(questions);
  const project = getProject();
  return {
    project: { id: project.id, title: project.title, want: project.want, status: project.status, committed_at: project.committedAt },
    head: getHead(),
    entries,
    questions,
    sharpness: { sharp: gate.sharp, answered_load_bearing: gate.answered_load_bearing, errors: gate.errors },
    sharp_declared: entries.some((e) => e.kind === 'sharp'),
    files: listFiles(),
    drafts: listDrafts(),
  };
}

export function recordJson(): string {
  const entries = listEntries() as any[];
  return JSON.stringify({ format: 'design-sprite-project', version: 3, exported_at: new Date().toISOString(), project: getProject(), head: getHead(), entries }, null, 1);
}
export function transcriptMd(): string { return exportBundle().transcript_md; }

// The exportable set for the explorer: versioned files (model.md + any
// preserved files) plus the two generated members of every bundle.
export function explorerFiles(): { path: string; kind: 'file' | 'generated'; version?: number; versions?: number }[] {
  const files = listFiles().map((f) => ({ path: f.path, kind: 'file' as const, version: f.version, versions: f.versions }));
  return [...files, { path: 'record.json', kind: 'generated' as const }, { path: 'transcript.md', kind: 'generated' as const }];
}
export function explorerFileContent(path: string): { path: string; content: string; version?: number } | null {
  if (path === 'record.json') return { path, content: recordJson() };
  if (path === 'transcript.md') return { path, content: transcriptMd() };
  const f = latestFile(path);
  return f ? { path, content: f.content, version: f.version } : null;
}

// Zip bundle (P3 human download surface): latest files at natural paths,
// every version under history/<path>.v<N>, plus record.json + transcript.md.
export function buildExportZip(): { buffer: Buffer; files: string[] } {
  const entries: ZipEntry[] = [];
  const versions = listAllFileVersions();
  const paths = [...new Set(versions.map((v) => v.path))].sort();
  for (const p of paths) {
    const latest = versions.filter((v) => v.path === p).sort((a, b) => b.version - a.version)[0];
    entries.push({ name: p, content: latest.content });
  }
  for (const v of versions) entries.push({ name: `history/${v.path}.v${v.version}`, content: v.content });
  entries.push({ name: 'record.json', content: recordJson() });
  entries.push({ name: 'transcript.md', content: transcriptMd() });
  const buffer = buildZip(entries);
  return { buffer, files: entries.map((e) => e.name) };
}

export function exportBundle() {
  const entries = listEntries() as any[];
  const files = listFiles().map((f) => { const latest = latestFile(f.path); return { path: f.path, version: f.version, versions: f.versions, content: latest?.content ?? '' }; });
  const transcript = entries.map((e) => {
    const body = e.body && e.body.trim() ? e.body : JSON.stringify(e.payload);
    return `## ${e.id} · ${e.role} · ${e.kind} · ${e.createdAt}\n\n${body}\n`;
  }).join('\n');
  return { format: 'design-sprite-project', version: 3, exported_at: new Date().toISOString(), project: getProject(), head: getHead(), entries, files, transcript_md: transcript };
}
