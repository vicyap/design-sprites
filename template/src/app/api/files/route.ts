import { NextResponse } from 'next/server';
import { explorerFiles, explorerFileContent } from '@/lib/store';
import { emit } from '@/lib/observe';
export const dynamic = 'force-dynamic';
// File explorer over exactly the exportable set: versioned files (model.md
// and any preserved files) + record.json + transcript.md.
export async function GET(req: Request) {
  const path = new URL(req.url).searchParams.get('path');
  if (!path) return NextResponse.json({ files: explorerFiles() });
  const f = explorerFileContent(path);
  if (!f) { emit('files.get', 'failed', 'not_found'); return NextResponse.json({ error: 'not_found' }, { status: 404 }); }
  emit('files.get', 'succeeded', 'ok', {});
  return NextResponse.json(f);
}
