import { NextResponse } from 'next/server';
import { getUiState } from '@/lib/store';
import { emit } from '@/lib/observe';
export const dynamic = 'force-dynamic';
// Human UI read surface: everything the page renders comes from here
// (verbatim entries, questions with answers/scores, files, drafts).
export async function GET() {
  const s = getUiState();
  emit('state.get', 'succeeded', 'ok', { head: s.head });
  return NextResponse.json(s);
}
