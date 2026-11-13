import test, { before } from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Fresh isolated DB for this suite: DATA_DIR must be set before db.ts loads.
process.env.DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'dsv3-p3-test-'));

let store: any; let dbmod: any; let protocol: any; let zip: any;
before(async () => {
  dbmod = await import('../src/lib/db.ts');
  store = await import('../src/lib/store.ts');
  protocol = await import('../src/lib/protocol.ts');
  zip = await import('../src/lib/zip.ts');
  dbmod.ensureProject();
  // Seed one single + one multi question through the real turn protocol.
  store.stageAction('post_question', { key: 'p3_single', type: 'single', prompt: 'Pick a colour?', load_bearing: true, options: [{ value: 'red', label: 'Red' }, { value: 'blue', label: 'Blue' }], prediction: 'red' });
  store.stageAction('post_question', { key: 'p3_multi', type: 'multi', prompt: 'Pick toppings?', load_bearing: false, options: [{ value: 'a', label: 'A' }, { value: 'b', label: 'B' }, { value: 'c', label: 'C' }], prediction: ['a', 'b'] });
  assert.equal(store.endTurn().ok, true);
});

test('multi provisional scoring: exact set hits, other chosen misses', () => {
  const q = { key: 'm', type: 'multi', prompt: '?', options: [], prediction: ['a', 'b'] };
  assert.equal(protocol.provisionalScore(q, { question_key: 'm', choices: ['b', 'a'] }).result, 'hit');
  const other = protocol.provisionalScore(q, { question_key: 'm', choices: ['a', 'other'] });
  assert.equal(other.result, 'miss'); assert.equal(other.reason, 'other_chosen');
  assert.equal(protocol.provisionalScore(q, { question_key: 'm', choices: ['a'] }).result, 'miss');
});

test('drafts persist verbatim and survive a re-fetch (reload)', () => {
  const draft = { choice: 'other', choices: null, other_text: 'teal — draft wording 123', comment: 'draft comment verbatim' };
  const r = store.saveDraft('p3_single', draft);
  assert.equal(r.ok, true);
  const back = store.getDraft('p3_single');
  assert.equal(back.choice, 'other');
  assert.equal(back.other_text, 'teal — draft wording 123');
  assert.equal(back.comment, 'draft comment verbatim');
  assert.ok(store.listDrafts().some((d: any) => d.question_key === 'p3_single'));
});

test('submitting an answer clears its draft in the same flow', () => {
  const a = store.addHumanAnswer({ question_key: 'p3_single', choice: 'other', other_text: 'teal — draft wording 123', comment: 'draft comment verbatim' });
  assert.equal(a.ok, true);
  assert.equal(a.answer.payload.other_text, 'teal — draft wording 123');
  assert.equal(a.score.payload.result, 'miss'); assert.equal(a.score.payload.reason, 'other_chosen');
  assert.equal(store.getDraft('p3_single'), null);
});

test('multi-select answer stores multiple choices verbatim', () => {
  const a = store.addHumanAnswer({ question_key: 'p3_multi', choices: ['a', 'c'], comment: 'multi comment' });
  assert.equal(a.ok, true);
  assert.deepEqual(a.answer.payload.choices, ['a', 'c']);
  assert.equal(a.score.payload.result, 'miss'); assert.equal(a.score.payload.reason, 'choice_mismatch');
});

test('explorer lists model.md + generated files and reads versions', () => {
  store.stageAction('write_model', { content: '# Model P3\n\nfirst version' });
  assert.equal(store.endTurn().ok, false); // provisional scores above are unjudged — gate blocks; judge them first
  store.stageAction('score_answer', { question_key: 'p3_single', judgement: 'miss', reason: 'other_chosen' });
  store.stageAction('score_answer', { question_key: 'p3_multi', judgement: 'miss', reason: 'choice_mismatch' });
  assert.equal(store.endTurn().ok, true);
  store.stageAction('write_model', { content: '# Model P3\n\nsecond version verbatim' });
  assert.equal(store.endTurn().ok, true);
  const files = store.explorerFiles();
  assert.ok(files.some((f: any) => f.path === 'model.md' && f.version === 2));
  assert.ok(files.some((f: any) => f.path === 'record.json'));
  assert.ok(files.some((f: any) => f.path === 'transcript.md'));
  const f = store.explorerFileContent('model.md');
  assert.ok(f.content.includes('second version verbatim'));
});

test('export zip contains record.json, transcript.md, model.md and history/', () => {
  const { buffer, files } = store.buildExportZip();
  const names = zip.zipEntryNames(buffer);
  assert.deepEqual([...names].sort(), [...files].sort());
  assert.ok(names.includes('record.json'), names.join(','));
  assert.ok(names.includes('transcript.md'), names.join(','));
  assert.ok(names.includes('model.md'), names.join(','));
  assert.ok(names.includes('history/model.md.v1'), names.join(','));
  assert.ok(names.includes('history/model.md.v2'), names.join(','));
  const record = JSON.parse(zip.zipEntryContent(buffer, 'record.json'));
  assert.ok(record.entries.length >= 6);
  assert.ok(zip.zipEntryContent(buffer, 'model.md').includes('second version verbatim'));
  assert.ok(zip.zipEntryContent(buffer, 'transcript.md').includes('p3_single'));
});

test('commit freeze is enforced server-side for messages, answers and drafts', () => {
  const before = store.listEntries().length;
  const c = store.commitProject();
  assert.equal(c.ok, true); assert.equal(c.already, false);
  const m = store.addHumanMessage('post-commit message must reject');
  assert.equal(m.ok, false); assert.ok(m.errors.some((e: any) => e.code === 'commit_freeze'));
  const a = store.addHumanAnswer({ question_key: 'p3_multi', choices: ['a'] });
  assert.equal(a.ok, false); assert.ok(a.errors.some((e: any) => e.code === 'commit_freeze'));
  const d = store.saveDraft('p3_multi', { comment: 'post-commit draft must reject' });
  assert.equal(d.ok, false); assert.ok(d.errors.some((e: any) => e.code === 'commit_freeze'));
  const s = store.stageAction('post_message', { body: 'driver write must reject too' });
  assert.equal(s.ok, false); assert.ok(s.errors.some((e: any) => e.code === 'commit_freeze'));
  // Only the commit entry itself was added; reads still work.
  assert.equal(store.listEntries().length, before + 1);
  assert.equal(store.commitProject().already, true);
  assert.ok(store.buildExportZip().files.includes('record.json'));
});
