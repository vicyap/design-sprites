import test from 'node:test';
import assert from 'node:assert';
import { artifactSafetyViolation, deriveArtifacts, deriveAnnotations, MAX_ARTIFACT_CHARS } from '../src/lib/protocol.ts';

const page = '<!doctype html><html><head><meta charset="utf-8"><style>body{margin:0}</style></head><body><main id="hero"><h1>Hi</h1></main></body></html>';

test('a plain self-contained page passes for generated', () => {
  assert.equal(artifactSafetyViolation(page, 'generated'), null);
});

test('scripts and inline handlers reject for BOTH kinds', () => {
  for (const kind of ['generated', 'snapshot'] as const) {
    assert.ok(artifactSafetyViolation('<html><body><script src="x.js"></script></body></html>', kind), kind);
    assert.ok(artifactSafetyViolation('<html><body><button onclick="go()">x</button></body></html>', kind), kind);
    assert.ok(artifactSafetyViolation('<html><body><a href="javascript:go()">x</a></body></html>', kind), kind);
  }
});

test('external resources reject for generated, pass for snapshot', () => {
  const withImg = '<html><body><img src="https://example.com/a.png"></body></html>';
  assert.ok(artifactSafetyViolation(withImg, 'generated'));
  assert.equal(artifactSafetyViolation(withImg, 'snapshot'), null);
  const withCss = '<html><head><link rel="stylesheet" href="https://example.com/a.css"></head><body></body></html>';
  assert.ok(artifactSafetyViolation(withCss, 'generated'));
  assert.equal(artifactSafetyViolation(withCss, 'snapshot'), null);
});

test('generated allows embedded data:image and #fragment references only', () => {
  assert.equal(artifactSafetyViolation('<html><head><style>.a{background:url(data:image/png;base64,AAA)}</style></head><body><a href="#top">t</a></body></html>', 'generated'), null);
  assert.ok(artifactSafetyViolation('<html><head><style>@import "x.css";</style></head><body></body></html>', 'generated'));
  assert.ok(artifactSafetyViolation('<html><head><style>.a{background:url(https://example.com/a.png)}</style></head><body></body></html>', 'generated'));
});

test('the artifact cap is a full-page cap, far above the snippet cap', () => {
  assert.ok(MAX_ARTIFACT_CHARS >= 100000);
});

test('deriveAnnotations: replies attach, resolve flips status once, order preserved', () => {
  const entries = [
    { id: 1, kind: 'annotation', body: 'Make the hero bigger', createdAt: 't1', payload: { artifact_path: 'a.html', artifact_version: 2, agentation_id: 'ag1', element_path: 'main > header', element_id: 'hero', element_text: 'Hi' } },
    { id: 2, kind: 'annotation', body: 'Footer wraps badly', createdAt: 't2', payload: { artifact_path: 'a.html', artifact_version: 2, agentation_id: 'ag2', element_path: 'footer', element_id: null, element_text: '' } },
    { id: 3, kind: 'annotation_reply', body: 'Doing it in v3', createdAt: 't3', payload: { annotation_entry_id: 1 } },
    { id: 4, kind: 'annotation_resolve', body: '', createdAt: 't4', payload: { annotation_entry_id: 1, summary: 'Hero enlarged in v3' } },
    { id: 5, kind: 'annotation_resolve', body: '', createdAt: 't5', payload: { annotation_entry_id: 1, summary: 'duplicate resolve ignored' } },
    { id: 6, kind: 'annotation_reply', body: 'orphan reply', createdAt: 't6', payload: { annotation_entry_id: 99 } },
  ] as any[];
  const anns = deriveAnnotations(entries);
  assert.equal(anns.length, 2);
  assert.equal(anns[0].status, 'resolved');
  assert.equal(anns[0].resolution?.summary, 'Hero enlarged in v3');
  assert.equal(anns[0].replies.length, 1);
  assert.equal(anns[0].element_id, 'hero');
  assert.equal(anns[1].status, 'open');
});

test('deriveArtifacts: latest entry wins for title/kind, versions counted', () => {
  const entries = [
    { id: 1, kind: 'artifact', payload: { path: 'a.html', version: 1, title: 'A', kind: 'generated' } },
    { id: 2, kind: 'message', payload: {} },
    { id: 3, kind: 'artifact', payload: { path: 'a.html', version: 2 } },
    { id: 4, kind: 'artifact', payload: { path: 'b.html', version: 1, kind: 'snapshot' } },
  ] as any[];
  const arts = deriveArtifacts(entries);
  assert.equal(arts.length, 2);
  const a = arts.find((x) => x.path === 'a.html')!;
  assert.equal(a.version, 2); assert.equal(a.versions, 2); assert.equal(a.title, 'A'); assert.equal(a.kind, 'generated'); assert.equal(a.lastEntryId, 3);
  const b = arts.find((x) => x.path === 'b.html')!;
  assert.equal(b.kind, 'snapshot'); assert.equal(b.title, 'b.html', 'title falls back to the path');
});
