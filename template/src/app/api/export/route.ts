import { buildExportZip } from '@/lib/store';
import { emit } from '@/lib/observe';
export const dynamic = 'force-dynamic';
// Human zip download of the export bundle: latest files at natural paths,
// every file version under history/, plus record.json + transcript.md.
export async function GET() {
  const { buffer, files } = buildExportZip();
  emit('export.download', 'succeeded', 'ok', { files: files.length });
  return new Response(new Uint8Array(buffer), {
    status: 200,
    headers: {
      'content-type': 'application/zip',
      'content-disposition': 'attachment; filename="design-sprite-export.zip"',
      'content-length': String(buffer.length),
    },
  });
}
