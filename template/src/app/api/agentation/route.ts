import { NextResponse } from 'next/server';
import { addAnnotation } from '@/lib/store';
import { emit } from '@/lib/observe';
export const dynamic = 'force-dynamic';

// v4 F2 annotation intake. Two senders, one store function (deduped by
// agentation_id, so overlaps and retries are harmless):
//  1. The layout-mode page mirrors each annotation the moment the toolbar
//     creates it (body: { annotation, artifact_path, artifact_version }).
//  2. agentation-mcp posts its action webhook here when the human sends a
//     session's output (body: { sessionId, annotations: [...], output }) —
//     artifact context is then parsed from each annotation's page URL.
// Human-path semantics like /api/entries: no token; the store enforces the
// Commit freeze.
function fromAnnotation(a: any, explicit?: { artifact_path?: string; artifact_version?: number }) {
  let artifactPath = explicit?.artifact_path || '';
  let artifactVersion = explicit?.artifact_version || 0;
  if (!artifactPath && typeof a?.url === 'string') {
    try {
      const u = new URL(a.url);
      const m = u.pathname.match(/^\/artifact\/(.+)$/);
      if (m) { artifactPath = decodeURIComponent(m[1]); artifactVersion = Number(u.searchParams.get('v') || 0); }
    } catch { /* url is context only */ }
  }
  const attrs = (a?.attributes && typeof a.attributes === 'object') ? a.attributes : {};
  const elementPath = String(a?.elementPath || (typeof a?.element === 'string' ? a.element : '') || '');
  // Element identity: the picked element's own id attribute wins; otherwise
  // the deepest #id segment of the element path (the nearest identified
  // ancestor, e.g. "main > #hero > h1" -> "hero") — artifacts enforce
  // stable ids, so that segment is a durable anchor.
  let elementId = (typeof attrs.id === 'string' && attrs.id) || (typeof attrs['data-zone'] === 'string' && attrs['data-zone']) || null;
  if (!elementId) {
    const ids = [...elementPath.matchAll(/#([A-Za-z][\w-]*)/g)].map((m) => m[1]);
    if (ids.length) elementId = ids[ids.length - 1];
  }
  return {
    artifact_path: artifactPath,
    artifact_version: artifactVersion,
    agentation_id: a?.id != null ? String(a.id) : null,
    element_path: elementPath,
    element_id: elementId,
    element_text: String(a?.selectedText || a?.nearbyText || ''),
    comment: String(a?.comment || ''),
  };
}

export async function POST(req: Request) {
  let body: any; try { body = await req.json(); } catch { return NextResponse.json({ error: 'validation' }, { status: 400 }); }
  // Webhook shape (agentation-mcp action request).
  if (Array.isArray(body?.annotations)) {
    let added = 0, deduped = 0, skipped = 0;
    for (const a of body.annotations) {
      const input = fromAnnotation(a);
      if (!input.artifact_path || !input.comment) { skipped++; continue; }
      const r = addAnnotation(input);
      if (r.ok) { if (r.deduped) deduped++; else added++; } else skipped++;
    }
    emit('annotation.webhook', 'succeeded', 'ok', { added, deduped, skipped });
    return NextResponse.json({ ok: true, added, deduped, skipped });
  }
  // Client mirror shape (or a bare annotation object).
  const a = body?.annotation ?? body;
  const input = fromAnnotation(a, { artifact_path: body?.artifact_path, artifact_version: body?.artifact_version });
  if (!input.artifact_path) { emit('annotation.mirror', 'failed', 'validation'); return NextResponse.json({ error: 'artifact_path required' }, { status: 400 }); }
  const r = addAnnotation(input);
  if (!r.ok) {
    emit('annotation.mirror', 'failed', 'validation');
    const frozen = r.errors.some((e) => e.code === 'commit_freeze');
    return NextResponse.json({ errors: r.errors, error: r.errors[0]?.code }, { status: frozen ? 409 : 422 });
  }
  return NextResponse.json({ entry: r.entry, deduped: r.deduped }, { status: 201 });
}
