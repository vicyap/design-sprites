import { NextResponse } from 'next/server';
import { listEntries } from '@/lib/db';
import { addHumanAnswer, addHumanMessage } from '@/lib/store';
import { emit } from '@/lib/observe';
export const dynamic = 'force-dynamic';
export async function GET() { const e = listEntries(); emit('entries.list', 'succeeded', 'ok', { count: e.length }); return NextResponse.json({ entries: e }); }
export async function POST(req: Request) {
  // Human UI path: same-origin browser posts need no token (the human UI must
  // work with no driver/credentials present). Human entries are stored
  // immediately, verbatim, and never wait for a driver. After Commit the
  // store rejects writes server-side with a structured commit_freeze error.
  let body: any; try { body = await req.json(); } catch { return NextResponse.json({ error: 'validation' }, { status: 400 }); }
  if (body?.kind === 'answer') {
    if (typeof body?.question_key !== 'string' || !body.question_key) { emit('entries.answer', 'failed', 'validation'); return NextResponse.json({ error: 'question_key required' }, { status: 400 }); }
    const dialValues = body.dial_values && typeof body.dial_values === 'object' && !Array.isArray(body.dial_values) ? body.dial_values : null;
    const r = addHumanAnswer({ question_key: body.question_key, choice: body.choice ?? null, choices: body.choices ?? null, other_text: body.other_text || '', comment: body.comment || '', skipped: !!body.skipped, dial_values: dialValues });
    if (!r.ok) {
      emit('entries.answer', 'failed', 'validation');
      const frozen = r.errors.some((e) => e.code === 'commit_freeze');
      return NextResponse.json({ errors: r.errors, error: r.errors[0]?.code }, { status: frozen ? 409 : 422 });
    }
    return NextResponse.json({ answer: r.answer, score: r.score }, { status: 201 });
  }
  const text = typeof body?.body === 'string' ? body.body.trim() : ''; if (!text || text.length > 8000) { emit('entries.create', 'failed', 'validation'); return NextResponse.json({ error: 'body required (1-8000 chars)' }, { status: 400 }); }
  const r = addHumanMessage(body.body);
  if (!r.ok) { emit('entries.create', 'failed', 'validation'); return NextResponse.json({ errors: r.errors, error: r.errors[0]?.code }, { status: 409 }); }
  return NextResponse.json({ entry: r.entry }, { status: 201 });
}
