import { NextResponse } from 'next/server';
import { commitProject } from '@/lib/store';
import { emit } from '@/lib/observe';
export const dynamic = 'force-dynamic';
// Commit (human press): freezes design content read-only, enforced
// server-side in the store for messages, answers, drafts and driver turns.
export async function POST() {
  const r = commitProject();
  emit('project.commit', 'succeeded', 'ok', {});
  return NextResponse.json({ ok: true, already: r.already, project: r.project }, { status: 200 });
}
