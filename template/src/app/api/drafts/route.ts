import { NextResponse } from 'next/server';
import { listDrafts, getDraft, saveDraft, deleteDraft } from '@/lib/store';
import { emit } from '@/lib/observe';
export const dynamic = 'force-dynamic';
// Answer drafts autosave (P3): the answer pane persists on every change so
// human typing survives reloads with no driver present. Content is never
// logged — only the operation outcome.
export async function GET(req: Request) {
  const key = new URL(req.url).searchParams.get('question_key');
  if (key) {
    const d = getDraft(key);
    return NextResponse.json({ draft: d });
  }
  return NextResponse.json({ drafts: listDrafts() });
}
export async function POST(req: Request) {
  let body: any;
  try { body = await req.json(); } catch { return NextResponse.json({ error: 'validation' }, { status: 400 }); }
  if (typeof body?.question_key !== 'string' || !body.question_key) { emit('drafts.save', 'failed', 'validation'); return NextResponse.json({ error: 'question_key required' }, { status: 400 }); }
  const dialValues = body.dial_values && typeof body.dial_values === 'object' && !Array.isArray(body.dial_values) ? body.dial_values : null;
  const r = saveDraft(body.question_key, { choice: body.choice ?? null, choices: body.choices ?? null, other_text: body.other_text || '', comment: body.comment || '', dial_values: dialValues });
  if (!r.ok) { emit('drafts.save', 'failed', 'validation'); return NextResponse.json({ errors: r.errors, error: r.errors[0]?.code }, { status: 409 }); }
  return NextResponse.json({ draft: r.draft }, { status: 200 });
}
export async function DELETE(req: Request) {
  const key = new URL(req.url).searchParams.get('question_key');
  if (!key) return NextResponse.json({ error: 'question_key required' }, { status: 400 });
  deleteDraft(key);
  emit('drafts.delete', 'succeeded', 'ok', {});
  return NextResponse.json({ ok: true });
}
