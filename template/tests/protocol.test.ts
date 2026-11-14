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

const pv = (id: string) => ({ id, label: 'Variant ' + id, html: `<div style="padding:8px">${id}</div>` });

test('preview variant coverage rejects when incomplete', () => {
  const q = { key: 'p1', type: 'preview', prompt: 'Which?', options: [{ value: 'v1', label: 'V1' }, { value: 'v2', label: 'V2' }], prediction: 'v1', variants: [pv('v1'), pv('v2'), pv('v3')] };
  const errs = validateQuestion(q, new Set());
  assert.ok(errs.some((e) => e.code === 'variant_coverage'), JSON.stringify(errs));
  const okQ = { ...q, options: [...q.options, { value: 'v3', label: 'V3' }] };
  assert.deepEqual(validateQuestion(okQ, new Set()), []);
  const tooMany = { ...okQ, variants: [pv('a'), pv('b'), pv('c'), pv('d'), pv('e')] };
  assert.ok(validateQuestion(tooMany, new Set()).some((e) => e.code === 'bad_variant_count'));
  const tooFew = { key: 'p2', type: 'preview', prompt: 'Which?', prediction: 'v1', variants: [pv('v1')] };
  assert.ok(validateQuestion(tooFew, new Set()).some((e) => e.code === 'bad_variant_count'));
  const dup = { key: 'p3', type: 'preview', prompt: 'Which?', prediction: 'v1', variants: [pv('v1'), pv('v1')] };
  assert.ok(validateQuestion(dup, new Set()).some((e) => e.code === 'bad_variant'));
});

test('preview without options derives the group from variants and validates', () => {
  const q = { key: 'p4', type: 'preview', prompt: 'Which?', prediction: 'v2', variants: [pv('v1'), pv('v2')], dials: [{ id: 'gap', label: 'Gap', min: 0, max: 40, step: 2, default: 12, unit: 'px' }] };
  assert.deepEqual(validateQuestion(q, new Set()), []);
  const badPred = { ...q, prediction: 'nope' };
  assert.ok(validateQuestion(badPred, new Set()).some((e) => e.code === 'bad_prediction'));
});

test('preview snippet safety: scripts and external resources reject', () => {
  const mk = (html: string) => ({ key: 's1', type: 'preview', prompt: 'Which?', prediction: 'v1', variants: [{ id: 'v1', label: 'V1', html }, pv('v2')] });
  for (const [label, html] of [
    ['script tag', '<div>ok</div><script>alert(1)</script>'],
    ['external img src', '<img src="https://evil.example/x.png">'],
    ['protocol-relative src', '<img src="//evil.example/x.png">'],
    ['external href', '<a href="https://evil.example/">x</a>'],
    ['event handler', '<div onclick="alert(1)">x</div>'],
    ['css external url', '<div style="background:url(https://evil.example/x.png)">x</div>'],
    // P3.5 audit bypasses (all passed the gate before the fix):
    ['video poster', '<video poster="https://evil.example/x.png"></video>'],
    ['background attribute', '<table background="https://evil.example/x.png"><tr><td>x</td></tr></table>'],
    ['css url backslash scheme', '<div style="background:url(https:\\\\evil.example/x.png)">x</div>'],
    ['css url data:text/html', '<div style="background:url(data:text/html;base64,PHNjcmlwdD4=)">x</div>'],
    ['css url protocol-relative', '<div style="background:url(//evil.example/x.png)">x</div>'],
  ] as const) {
    const errs = validateQuestion(mk(html), new Set());
    assert.ok(errs.some((e) => e.code === 'unsafe_snippet'), `${label}: ${JSON.stringify(errs)}`);
  }
  // Safe snippets pass: inline styles, inline SVG, fragment links, embedded
  // data:image CSS, and #fragment CSS url() (SVG paint servers).
  assert.deepEqual(validateQuestion(mk('<div style="color:red"><svg width="10" height="10"><rect width="10" height="10"/></svg><a href="#top">top</a></div>'), new Set()), []);
  assert.deepEqual(validateQuestion(mk('<div style="background:url(data:image/png;base64,iVBORw0KGgo=)">x</div>'), new Set()), []);
  assert.deepEqual(validateQuestion(mk('<svg width="10" height="10"><defs><linearGradient id="g"><stop offset="0" stop-color="#fff"/></linearGradient></defs><rect width="10" height="10" fill="url(#g)"/></svg>'), new Set()), []);
});

test('preview snippet size cap: oversized snippets reject as snippet_too_large', () => {
  const mk = (html: string) => ({ key: 's2', type: 'preview', prompt: 'Which?', prediction: 'v1', variants: [{ id: 'v1', label: 'V1', html }, pv('v2')] });
  const big = '<div>' + 'x'.repeat(20000) + '</div>';
  const errs = validateQuestion(mk(big), new Set());
  assert.ok(errs.some((e) => e.code === 'snippet_too_large'), JSON.stringify(errs));
  assert.deepEqual(validateQuestion(mk('<div>small</div>'), new Set()), []);
});

test('preview dial validation: ranges must be sane', () => {
  const mk = (dial: any) => ({ key: 'd1', type: 'preview', prompt: 'Which?', prediction: 'v1', variants: [pv('v1'), pv('v2')], dials: [dial] });
  assert.ok(validateQuestion(mk({ id: 'g', label: 'Gap', min: 40, max: 40, step: 1, default: 40 }), new Set()).some((e) => e.code === 'bad_dial_range'));
  assert.ok(validateQuestion(mk({ id: 'g', label: 'Gap', min: 0, max: 40, step: 1, default: 99 }), new Set()).some((e) => e.code === 'bad_dial_range'));
  assert.ok(validateQuestion(mk({ id: 'g', label: 'Gap', min: 0, max: 40, step: 0, default: 4 }), new Set()).some((e) => e.code === 'bad_dial_range'));
  assert.deepEqual(validateQuestion(mk({ id: 'g', label: 'Gap', min: 0, max: 40, step: 2, default: 12 }), new Set()), []);
  const dupDials = { key: 'd2', type: 'preview', prompt: 'Which?', prediction: 'v1', variants: [pv('v1'), pv('v2')], dials: [{ id: 'g', label: 'Gap', min: 0, max: 4, step: 1, default: 1 }, { id: 'g', label: 'Gap 2', min: 0, max: 4, step: 1, default: 1 }] };
  assert.ok(validateQuestion(dupDials, new Set()).some((e) => e.code === 'bad_dial'));
});

test('preview provisional scoring scores the variant, never the dials', () => {
  const q: any = { key: 'pv1', type: 'preview', prompt: '?', options: [], prediction: 'v2', variants: [pv('v1'), pv('v2')], dials: [{ id: 'gap', label: 'Gap', min: 0, max: 40, step: 2, default: 12 }] };
  assert.equal(provisionalScore(q, { question_key: 'pv1', choice: 'v2', dial_values: { gap: 38 } }).result, 'hit');
  assert.equal(provisionalScore(q, { question_key: 'pv1', choice: 'v1', dial_values: { gap: 12 } }).result, 'miss');
  assert.equal(provisionalScore(q, { question_key: 'pv1', choice: 'other', dial_values: { gap: 12 } }).reason, 'other_chosen');
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
