import { NextResponse } from 'next/server';
import { explorerFiles, explorerFileContent, getFileVersion } from '@/lib/store';
import { emit } from '@/lib/observe';
export const dynamic = 'force-dynamic';
// File explorer over exactly the exportable set: versioned files (model.md
// and any preserved files) + record.json + transcript.md. v4: an optional
// ?version=N reads a specific version of a versioned file (layout mode's
// version switcher); generated files have no versions and ignore it.
export async function GET(req: Request) {
  const url = new URL(req.url);
  const path = url.searchParams.get('path');
  if (!path) return NextResponse.json({ files: explorerFiles() });
  const versionParam = url.searchParams.get('version');
  if (versionParam && path !== 'record.json' && path !== 'transcript.md') {
    const v = Number(versionParam);
    const f = Number.isInteger(v) && v > 0 ? getFileVersion(path, v) : null;
    if (!f) { emit('files.get', 'failed', 'not_found'); return NextResponse.json({ error: 'not_found' }, { status: 404 }); }
    emit('files.get', 'succeeded', 'ok', {});
    return NextResponse.json(f);
  }
  const f = explorerFileContent(path);
  if (!f) { emit('files.get', 'failed', 'not_found'); return NextResponse.json({ error: 'not_found' }, { status: 404 }); }
  emit('files.get', 'succeeded', 'ok', {});
  return NextResponse.json(f);
}
