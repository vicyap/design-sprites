import test from 'node:test';
import assert from 'node:assert';
import { validateQuestion, withOther, provisionalScore, judgementScore, sharpnessGate, deriveQuestions, validateArtifactIds } from '../src/lib/protocol.ts';

const baseQ = { key: 'q1', type: 'single', prompt: 'Pick one?', load_bearing: true, options: [{ value: 'a', label: 'A' }, { value: 'b', label: 'B' }], prediction: 'a' };

test('valid question passes validation', () => {
  assert.deepEqual(validateQuestion(baseQ, new Set()), []);
});

test('more than 9 named options rejects', () => {
  const opts = Array.from({ length: 10 }, (_, i) => ({ value: 'v' + i, label: 'L' + i }));
  const errs = validateQuestion({ ...baseQ, options: opts, prediction: 'v0' }, new Set());
  assert.ok(errs.some((e) => e.code === 'too_many_options'), JSON.stringify(errs));
});

test('Other is added inside the group exactly once', () => {
  const out = withOther(baseQ.options);
  assert.equal(out.length, 3); assert.equal(out[2].value, 'other');
  assert.equal(withOther(out).length, 3);
});

test('preview variant coverage rejects when incomplete', () => {
  const q = { key: 'p1', type: 'preview', prompt: 'Which?', options: [{ value: 'v1', label: 'V1' }, { value: 'v2', label: 'V2' }], prediction: 'v1', variants: [{ id: 'v1' }, { id: 'v2' }, { id: 'v3' }] };
  const errs = validateQuestion(q, new Set());
  assert.ok(errs.some((e) => e.code === 'variant_coverage'), JSON.stringify(errs));
  const okQ = { ...q, options: [...q.options, { value: 'v3', label: 'V3' }] };
  assert.deepEqual(validateQuestion(okQ, new Set()), []);
  const tooMany = { ...okQ, variants: [{ id: 'a' }, { id: 'b' }, { id: 'c' }, { id: 'd' }, { id: 'e' }] };
  assert.ok(validateQuestion(tooMany, new Set()).some((e) => e.code === 'bad_variant_count'));
});

test('provisional scoring is deterministic', () => {
  assert.deepEqual(provisionalScore(baseQ as any, { question_key: 'q1', choice: 'a' }), { question_key: 'q1', result: 'hit', provisional: true, reason: 'choice_match', source: 'deterministic' });
  assert.equal(provisionalScore(baseQ as any, { question_key: 'q1', choice: 'b' }).result, 'miss');
  const other = provisionalScore(baseQ as any, { question_key: 'q1', choice: 'other' });
  assert.equal(other.result, 'miss'); assert.equal(other.reason, 'other_chosen');
  const skip = provisionalScore(baseQ as any, { question_key: 'q1', skipped: true });
  assert.equal(skip.result, 'provisional'); assert.equal(skip.reason, 'skip_prediction_stands');
});

test('judgement semantics: skip stands (not a hit), strike removes the axis', () => {
  const skipFinal: any = judgementScore('skip', undefined, { question_key: 'q1', skipped: true });
  assert.equal(skipFinal.result, 'provisional'); assert.equal(skipFinal.provisional, false);
  const badSkip: any = judgementScore('skip', undefined, { question_key: 'q1', skipped: false });
  assert.equal(badSkip.code, 'bad_judgement');
  const strike: any = judgementScore('strike', undefined, { question_key: 'q1' });
  assert.equal(strike.result, 'struck'); assert.equal(strike.provisional, false);
});

test('sharpness gate: minimal case rejects, 3 final LB hits pass', () => {
  const empty = sharpnessGate([]);
  assert.equal(empty.sharp, false); assert.ok(empty.errors.some((e) => e.code === 'sharp_min_answered'));
  const mk = (key: string, id: number) => ({ id, kind: 'question', payload: { key, type: 'single', prompt: '?', load_bearing: true, options: [], prediction: 'a' } });
  const ans = (key: string, id: number) => ({ id, kind: 'answer', payload: { question_key: key, choice: 'a' } });
  const score = (key: string, id: number, result = 'hit', provisional = false) => ({ id, kind: 'score', payload: { question_key: key, result, provisional, reason: 'choice_match', source: 'driver' } });
  const entries: any[] = [];
  ['a', 'b', 'c'].forEach((k, i) => { entries.push(mk(k, i * 3 + 1), ans(k, i * 3 + 2), score(k, i * 3 + 3)); });
  assert.equal(sharpnessGate(deriveQuestions(entries)).sharp, true);
  const withOpen = [...entries, mk('d', 10)];
  assert.equal(sharpnessGate(deriveQuestions(withOpen)).sharp, false);
  const provEntries = entries.map((e) => e.kind === 'score' && e.payload.question_key === 'c' ? score('c', 9, 'hit', true) : e);
  assert.equal(sharpnessGate(deriveQuestions(provEntries)).sharp, false);
});

test('artifact element ids: duplicates and lost ids reject', () => {
  assert.ok(validateArtifactIds('a.html', '<div id="x"></div><div id="x"></div>', null).some((e) => e.code === 'duplicate_element_id'));
  assert.ok(validateArtifactIds('a.html', '<div id="x"></div>', ['x', 'y']).some((e) => e.code === 'element_ids_lost'));
  assert.deepEqual(validateArtifactIds('a.html', '<div id="x"></div><p id="y"></p>', ['x', 'y']), []);
});
