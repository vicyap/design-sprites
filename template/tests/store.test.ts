import test, { before } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Fresh isolated DB for this suite: DATA_DIR must be set before db.ts loads.
process.env.DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'dsv3-store-test-'));

let store: any; let dbmod: any;
before(async () => {
  dbmod = await import('../src/lib/db.ts');
  store = await import('../src/lib/store.ts');
  dbmod.ensureProject();
});

const Q = (key: string, extra: any = {}) => ({ key, type: 'single', prompt: `Question ${key}?`, load_bearing: true, options: [{ value: 'a', label: 'A' }, { value: 'b', label: 'B' }], prediction: 'a', ...extra });

test('declare_sharp rejects before the gate passes (minimal case)', () => {
  const r = store.stageAction('declare_sharp', {});
  assert.equal(r.ok, false);
  assert.ok(r.errors.some((e: any) => e.code === 'sharp_min_answered'), JSON.stringify(r.errors));
  assert.equal(store.getOpenTurn(), null); // rejected declaration is not staged
});

test('valid question: staged content is invisible before end_turn, Other added at commit', () => {
  const s = store.stageAction('post_question', Q('alpha'));
  assert.equal(s.ok, true);
  assert.ok(!store.listEntries().some((e: any) => e.kind === 'question' && e.payload.key === 'alpha'), 'staged question must not be in the record yet');
  const r = store.endTurn();
  assert.equal(r.ok, true, JSON.stringify(r));
  const q = store.listEntries().find((e: any) => e.kind === 'question' && e.payload.key === 'alpha');
  assert.ok(q); assert.equal(q.payload.options.length, 3); assert.equal(q.payload.options[2].value, 'other');
});

test('gate: more than 9 named options rejects and leaves the turn open', () => {
  const opts = Array.from({ length: 10 }, (_, i) => ({ value: 'v' + i, label: 'L' + i }));
  store.stageAction('post_question', Q('toomany', { options: opts, prediction: 'v0' }));
  const r = store.endTurn();
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'too_many_options'), JSON.stringify(r.errors));
  assert.ok(store.getOpenTurn(), 'rejected end_turn leaves the turn open');
  store.discardTurn(); assert.equal(store.getOpenTurn(), null);
});

test('gate: preview variant coverage rejects when incomplete', () => {
  const pvx = (id: string) => ({ id, label: 'Variant ' + id, html: `<div>${id}</div>` });
  store.stageAction('post_question', { key: 'prev1', type: 'preview', prompt: 'Which variant?', options: [{ value: 'v1', label: 'V1' }, { value: 'v2', label: 'V2' }], prediction: 'v1', variants: [pvx('v1'), pvx('v2'), pvx('v3')] });
  const r = store.endTurn();
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'variant_coverage'), JSON.stringify(r.errors));
  assert.ok(store.getOpenTurn()); store.discardTurn();
});

test('gate: preview unsafe snippet and bad dial reject at end_turn, turn stays open', () => {
  const pvx = (id: string, html?: string) => ({ id, label: 'Variant ' + id, html: html ?? `<div>${id}</div>` });
  store.stageAction('post_question', { key: 'prev_script', type: 'preview', prompt: 'Which?', prediction: 'v1', variants: [pvx('v1', '<div>x</div><script>alert(1)</script>'), pvx('v2')] });
  let r = store.endTurn();
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'unsafe_snippet'), JSON.stringify(r.errors));
  assert.ok(store.getOpenTurn(), 'turn stays open after unsafe rejection');
  assert.ok(!store.listEntries().some((e: any) => e.kind === 'question' && e.payload.key === 'prev_script'), 'rejected question never enters the record');
  store.discardTurn();
  store.stageAction('post_question', { key: 'prev_dial', type: 'preview', prompt: 'Which?', prediction: 'v1', variants: [pvx('v1'), pvx('v2')], dials: [{ id: 'gap', label: 'Gap', min: 40, max: 40, step: 1, default: 40 }] });
  r = store.endTurn();
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'bad_dial_range'), JSON.stringify(r.errors));
  assert.ok(store.getOpenTurn()); store.discardTurn();
});

test('preview happy path: variants + dials commit, answer stores dial values verbatim, variant scored', () => {
  const pvx = (id: string) => ({ id, label: 'Variant ' + id, html: `<div style="padding:8px">${id}</div>` });
  store.stageAction('post_question', { key: 'prev_ok', type: 'preview', prompt: 'Which layout?', load_bearing: false, prediction: 'v2', variants: [pvx('v1'), pvx('v2'), pvx('v3')], dials: [{ id: 'gap', label: 'Gap', min: 0, max: 40, step: 2, default: 12, unit: 'px' }] });
  const r = store.endTurn();
  assert.equal(r.ok, true, JSON.stringify(r));
  const q = store.listEntries().find((e: any) => e.kind === 'question' && e.payload.key === 'prev_ok');
  assert.ok(q); assert.equal(q.payload.options.length, 4); assert.equal(q.payload.options[3].value, 'other'); // derived options + Other
  assert.equal(q.payload.variants.length, 3); assert.equal(q.payload.dials[0].id, 'gap');
  const a = store.addHumanAnswer({ question_key: 'prev_ok', choice: 'v2', dial_values: { gap: 26 }, comment: 'wider gap reads better' });
  assert.equal(a.ok, true, JSON.stringify(a));
  assert.equal(a.answer.payload.choice, 'v2'); assert.deepEqual(a.answer.payload.dial_values, { gap: 26 });
  assert.equal(a.score.payload.result, 'hit'); assert.equal(a.score.payload.provisional, true);
  // Judge the provisional so later end_turns are not blocked by gate 4.
  store.stageAction('score_answer', { question_key: 'prev_ok', judgement: 'hit' });
  assert.equal(store.endTurn().ok, true);
});

test('gate: stale head rejects end_turn and the turn stays open', () => {
  store.stageAction('post_message', { body: 'staged before a human write' });
  const turn = store.getOpenTurn(); assert.ok(turn);
  dbmod.addEntry('human write that moves the head'); // record head advances past base_head
  const r = store.endTurn();
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'stale_head'), JSON.stringify(r.errors));
  assert.ok(store.getOpenTurn(), 'turn stays open after stale rejection');
  store.discardTurn();
});

test('sharpness happy path: LB answers judged as final hits, declare_sharp commits', () => {
  // 'alpha' from an earlier test is load-bearing and open; sharpness rightly
  // refuses while any LB question is open, so it is answered and judged too.
  for (const k of ['s1', 's2', 's3']) store.stageAction('post_question', Q(k));
  assert.equal(store.endTurn().ok, true);
  for (const k of ['alpha', 's1', 's2', 's3']) {
    const a = store.addHumanAnswer({ question_key: k, choice: 'a' });
    assert.equal(a.ok, true); assert.equal(a.score.payload.result, 'hit'); assert.equal(a.score.payload.provisional, true);
  }
  for (const k of ['alpha', 's1', 's2', 's3']) store.stageAction('score_answer', { question_key: k, judgement: 'hit' });
  const d = store.stageAction('declare_sharp', {});
  assert.equal(d.ok, true, JSON.stringify(d));
  const r = store.endTurn();
  assert.equal(r.ok, true, JSON.stringify(r));
  const st = store.getState();
  assert.equal(st.sharp_declared, true); assert.equal(st.sharpness.sharp, true);
});

test('gate: unjudged provisional rejects end_turn until judged', () => {
  store.stageAction('post_question', Q('late1'));
  assert.equal(store.endTurn().ok, true);
  const a = store.addHumanAnswer({ question_key: 'late1', choice: 'b' }); // miss, provisional
  assert.equal(a.score.payload.provisional, true);
  store.stageAction('post_message', { body: 'turn that forgets to judge' });
  const r = store.endTurn();
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'provisional_unjudged' && e.question_key === 'late1'), JSON.stringify(r.errors));
  assert.ok(store.getOpenTurn(), 'turn stays open for restaging');
  store.stageAction('score_answer', { question_key: 'late1', judgement: 'miss', reason: 'choice_mismatch' });
  const r2 = store.endTurn();
  assert.equal(r2.ok, true, JSON.stringify(r2));
});

test('artifacts: stable element ids enforced across versions', () => {
  store.stageAction('post_artifact', { path: 'art.html', content: '<div id="hero"></div><p id="note"></p>' });
  assert.equal(store.endTurn().ok, true);
  assert.equal(store.latestFile('art.html').version, 1);
  store.stageAction('patch_artifact', { path: 'art.html', content: '<div id="hero"></div>' });
  const r = store.endTurn();
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'element_ids_lost'), JSON.stringify(r.errors));
  store.discardTurn();
  store.stageAction('patch_artifact', { path: 'art.html', content: '<div id="hero"></div><p id="note">v2</p>' });
  assert.equal(store.endTurn().ok, true);
  assert.equal(store.latestFile('art.html').version, 2);
});

test('write_model versions model.md as a file', () => {
  store.stageAction('write_model', { content: '# Model\n\nv1 content' });
  assert.equal(store.endTurn().ok, true);
  const f = store.getFileVersion('model.md');
  assert.equal(f.version, 1); assert.ok(f.content.includes('v1 content'));
});

test('presence (v3.7 F1): absent before any touch, fresh after touch, stale past the threshold, never an entry', () => {
  const before = store.getPresence();
  assert.equal(before.driver_present, false);
  const headBefore = store.getHead();
  store.touchPresence('driver', 'mcp');
  const fresh = store.getPresence();
  assert.equal(fresh.driver_present, true);
  assert.equal(fresh.source, 'mcp');
  assert.ok(fresh.last_seen);
  assert.equal(store.getHead(), headBefore, 'presence writes must not enter the verbatim record');
  // Backdate beyond the staleness threshold: presence falls away.
  dbmod.sqlite.prepare("UPDATE presence SET last_seen=? WHERE id=1").run(new Date(Date.now() - store.PRESENCE_STALE_MS - 1000).toISOString());
  assert.equal(store.getPresence().driver_present, false);
  // UI + driver state both carry presence.
  assert.equal(store.getUiState().presence.driver_present, false);
  store.touchPresence('driver', 'ds-wake');
  assert.equal(store.getState().presence.driver_present, true);
  assert.equal(store.getState().presence.source, 'ds-wake');
});

test('v4 artifacts: post_artifact versions content and carries title + kind; patch inherits both', () => {
  const page = (n: number) => `<!doctype html><html><head><title>T</title></head><body><main id="hero"><h1>Hi ${n}</h1></main></body></html>`;
  let s = store.stageAction('post_artifact', { path: 'design/home.html', title: 'Home page', content: page(1) });
  assert.equal(s.ok, true, JSON.stringify(s));
  assert.equal(store.endTurn().ok, true);
  let art = store.getUiState().artifacts.find((a: any) => a.path === 'design/home.html');
  assert.ok(art); assert.equal(art.version, 1); assert.equal(art.title, 'Home page'); assert.equal(art.kind, 'generated'); assert.equal(art.versions, 1);
  s = store.stageAction('patch_artifact', { path: 'design/home.html', content: page(2) });
  assert.equal(s.ok, true);
  assert.equal(store.endTurn().ok, true);
  art = store.getUiState().artifacts.find((a: any) => a.path === 'design/home.html');
  assert.equal(art.version, 2); assert.equal(art.title, 'Home page', 'title inherits across versions'); assert.equal(art.kind, 'generated');
  assert.equal(store.getFileVersion('design/home.html', 1).content, page(1), 'old versions stay viewable verbatim');
});

test('v4 artifacts: the script-free page gate rejects at end_turn and leaves the turn open', () => {
  store.stageAction('post_artifact', { path: 'design/bad.html', content: '<html><body><script>alert(1)</script></body></html>' });
  let r = store.endTurn();
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'unsafe_artifact'), JSON.stringify(r.errors));
  store.discardTurn();
  store.stageAction('post_artifact', { path: 'design/bad2.html', content: '<html><body><img src="https://example.com/x.png"></body></html>' });
  r = store.endTurn();
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'unsafe_artifact'), 'generated artifacts may not load external resources');
  store.discardTurn();
  // The same external image is fine in a snapshot (captured assets), scripts still are not.
  const s = store.stageAction('post_artifact', { path: 'design/snap.html', kind: 'snapshot', title: 'Captured', content: '<html><body><img src="https://example.com/x.png"></body></html>' });
  assert.equal(s.ok, true);
  assert.equal(store.endTurn().ok, true);
  const art = store.getUiState().artifacts.find((a: any) => a.path === 'design/snap.html');
  assert.equal(art.kind, 'snapshot');
});

test('v4 annotations: addAnnotation validates, dedupes by agentation_id, clamps version', () => {
  const bad = store.addAnnotation({ artifact_path: 'design/nope.html', artifact_version: 1, comment: 'hi' });
  assert.equal(bad.ok, false); assert.equal((bad as any).errors[0].code, 'unknown_artifact');
  const a1 = store.addAnnotation({ artifact_path: 'design/home.html', artifact_version: 99, agentation_id: 'ag-test-1', element_path: 'main > header', element_id: 'hero', element_text: 'Hi 2', comment: 'Hero headline wraps oddly' });
  assert.equal(a1.ok, true);
  if (a1.ok) assert.equal((a1.entry.payload as any).artifact_version, 2, 'version clamped to the latest existing version');
  const dup = store.addAnnotation({ artifact_path: 'design/home.html', artifact_version: 2, agentation_id: 'ag-test-1', comment: 'Hero headline wraps oddly' });
  assert.equal(dup.ok, true); if (dup.ok) assert.equal((dup as any).deduped, true);
  const anns = store.getUiState().annotations.filter((x: any) => x.agentation_id === 'ag-test-1');
  assert.equal(anns.length, 1); assert.equal(anns[0].status, 'open');
});

test('v4 annotations: the webhook path (different agentation id, same content) dedupes against the mirror entry', () => {
  const again = store.addAnnotation({ artifact_path: 'design/home.html', artifact_version: 2, agentation_id: 'server-side-id-9', element_path: 'main > header', element_id: 'hero', element_text: 'Hi 2', comment: 'Hero headline wraps oddly' });
  assert.equal(again.ok, true); if (again.ok) assert.equal((again as any).deduped, true, 'content identity converges the two intake paths');
  const anns = store.getUiState().annotations.filter((x: any) => x.comment === 'Hero headline wraps oddly');
  assert.equal(anns.length, 1);
});

test('v4 annotations: driver reply + resolve flow through end_turn; double resolve rejects', () => {
  const ann = store.getUiState().annotations.find((x: any) => x.agentation_id === 'ag-test-1');
  assert.ok(ann);
  let s = store.stageAction('reply_annotation', { annotation_entry_id: 99999, body: 'orphan' });
  assert.equal(s.ok, true); // staging is permissive; the gate judges
  let r = store.endTurn();
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'unknown_annotation'), JSON.stringify(r.errors));
  store.discardTurn();
  s = store.stageAction('reply_annotation', { annotation_entry_id: ann.entry_id, body: 'Fixed in the next version.' });
  assert.equal(s.ok, true);
  s = store.stageAction('resolve_annotation', { annotation_entry_id: ann.entry_id, summary: 'Headline no longer wraps' });
  assert.equal(s.ok, true);
  r = store.endTurn();
  assert.equal(r.ok, true, JSON.stringify(r));
  const after = store.getUiState().annotations.find((x: any) => x.entry_id === ann.entry_id);
  assert.equal(after.status, 'resolved'); assert.equal(after.replies.length, 1); assert.equal(after.resolution?.summary, 'Headline no longer wraps');
  store.stageAction('resolve_annotation', { annotation_entry_id: ann.entry_id });
  r = store.endTurn();
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'already_resolved'));
  store.discardTurn();
});

test('commit freeze: driver writes reject once the project is committed', () => {
  dbmod.sqlite.prepare("UPDATE projects SET status='committed', committed_at=? WHERE id='proj_default'").run(new Date().toISOString());
  const r = store.stageAction('post_message', { body: 'should reject' });
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'commit_freeze'), JSON.stringify(r.errors));
});
