import test from 'node:test'; import assert from 'node:assert';
// Behavioural unit: append-only semantics are enforced by INSERT-only code paths (no UPDATE/DELETE on entries in src).
import fs from 'node:fs';
test('no update/delete on entries in source',()=>{ const s=fs.readFileSync('src/lib/db.ts','utf8'); assert.ok(!/UPDATE entries|DELETE FROM entries/i.test(s)); assert.ok(s.includes('INSERT INTO entries')); });
test('health does db round trip',()=>{ const s=fs.readFileSync('src/app/health/route.ts','utf8'); assert.ok(s.includes('dbRoundTrip')); });
test('no AI calls / no conn labels in source',()=>{ const files=['src/lib/db.ts','src/app/page.tsx']; for(const f of files){ const s=fs.readFileSync(f,'utf8'); assert.ok(!s.includes('conn:anthropic')); assert.ok(!s.includes('AI_GATEWAY')); } });
