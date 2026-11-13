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
  store.stageAction('post_question', { key: 'prev1', type: 'preview', prompt: 'Which variant?', options: [{ value: 'v1', label: 'V1' }, { value: 'v2', label: 'V2' }], prediction: 'v1', variants: [{ id: 'v1' }, { id: 'v2' }, { id: 'v3' }] });
  const r = store.endTurn();
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'variant_coverage'), JSON.stringify(r.errors));
  assert.ok(store.getOpenTurn()); store.discardTurn();
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

test('commit freeze: driver writes reject once the project is committed', () => {
  dbmod.sqlite.prepare("UPDATE projects SET status='committed', committed_at=? WHERE id='proj_default'").run(new Date().toISOString());
  const r = store.stageAction('post_message', { body: 'should reject' });
  assert.equal(r.ok, false); assert.ok(r.errors.some((e: any) => e.code === 'commit_freeze'), JSON.stringify(r.errors));
});
