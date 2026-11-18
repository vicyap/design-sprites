'use client';
import { useCallback, useEffect, useState, type CSSProperties } from 'react';
import dynamic from 'next/dynamic';
import { ArrowLeft, CaretLeft, CaretRight } from '@phosphor-icons/react';

// v4 F2: the Agentation inspector annotator, layout mode only. It syncs
// through the same-origin /agentation-sync rewrite to the loopback
// agentation-mcp service (never publicly exposed). Element identity keys
// on the stable element id every artifact element carries; data-zone is
// captured too when a page carries it.
const Agentation = dynamic(() => import('agentation').then((m) => ({ default: m.Agentation })), { ssr: false });

// Design Sprites v4 — LAYOUT MODE. The thread is home; expanding an
// artifact card lands here: a full-canvas view of ONE artifact version
// with the annotator available (P3). Structure first (locked v4 rule):
// the chrome is layout / hierarchy / neutral surfaces; colour accents
// come only after the structure verifies.
//
// Rendering: the artifact HTML renders in a SAME-ORIGIN srcDoc iframe
// with NO sandbox attribute. That is deliberate: Agentation's embedded-
// page support picks elements inside same-origin frames, which a
// sandbox="" frame would make impossible. Safety lives at the write
// gate instead (artifacts are script-free, enforced at end_turn) — the
// same defence-in-depth split as the record itself: gates on write,
// freedom on read. The stored content stays verbatim; the only render
// wrapper is a color-scheme meta injected into <head> when the page
// does not declare one (an srcDoc document does not inherit the app's
// scheme — the P3.5 audit lesson), so unstyled pages follow the OS
// scheme exactly like the app chrome.

const eyebrow: CSSProperties = { letterSpacing: '0.08em', textTransform: 'uppercase', fontSize: 12, color: 'var(--muted-foreground)' };
const wrap: CSSProperties = { overflowWrap: 'anywhere' };

function srcDocForPage(html: string): string {
  if (/name\s*=\s*["']color-scheme["']/i.test(html)) return html;
  const meta = '<meta name="color-scheme" content="light dark">';
  const head = html.match(/<head[^>]*>/i);
  if (head && head.index !== undefined) return html.slice(0, head.index + head[0].length) + meta + html.slice(head.index + head[0].length);
  return meta + html;
}

export default function ArtifactPage({ params }: { params: Promise<{ path: string[] }> }) {
  const [artifactPath, setArtifactPath] = useState<string>('');
  const [version, setVersion] = useState<number>(1);
  const [versions, setVersions] = useState<number>(1);
  const [title, setTitle] = useState<string>('');
  const [kind, setKind] = useState<string>('generated');
  const [content, setContent] = useState<string | null>(null);
  const [error, setError] = useState<string>('');
  const [annotations, setAnnotations] = useState<any[]>([]);

  useEffect(() => {
    params.then((p) => {
      const path = (p.path || []).join('/');
      setArtifactPath(path);
      const v = Number(new URLSearchParams(window.location.search).get('v') || 0);
      if (v > 0) setVersion(v);
    });
  }, [params]);

  const load = useCallback(async () => {
    if (!artifactPath) return;
    const s = await fetch('/api/state', { cache: 'no-store' });
    if (!s.ok) { setError('Could not load the project state.'); return; }
    const state = await s.json();
    const art = (state.artifacts || []).find((a: any) => a.path === artifactPath);
    if (!art) { setError('This artifact is not in the record.'); return; }
    setVersions(art.version); // latest version number
    setTitle(art.title || art.path);
    setKind(art.kind || 'generated');
    const v = Math.min(Math.max(1, version), art.version);
    if (v !== version) setVersion(v);
    const f = await fetch(`/api/files?path=${encodeURIComponent(artifactPath)}&version=${v}`, { cache: 'no-store' });
    if (!f.ok) { setError('Could not load this version.'); return; }
    setContent((await f.json()).content ?? '');
    // Annotations for THIS version, derived server-side from the record
    // (annotation + reply + resolve entries): status, replies, resolution.
    const anns = (state.annotations || []).filter((a: any) => a.artifact_path === artifactPath && a.artifact_version === v);
    setAnnotations(anns);
  }, [artifactPath, version]);

  // Mirror each toolbar annotation into the record the moment it is made;
  // the agentation-mcp action webhook is the second path into the same
  // store function, deduped by the annotation's own id.
  const mirrorAnnotation = useCallback((annotation: any) => {
    fetch('/api/agentation', {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ annotation, artifact_path: artifactPath, artifact_version: version }),
    }).then(() => load()).catch(() => { /* the webhook path still lands it */ });
  }, [artifactPath, version, load]);

  useEffect(() => { load(); const t = setInterval(load, 4000); return () => clearInterval(t); }, [load]);

  function gotoVersion(v: number) {
    const nv = Math.min(Math.max(1, v), versions);
    setVersion(nv);
    try { const u = new URL(window.location.href); u.searchParams.set('v', String(nv)); window.history.replaceState(null, '', u.toString()); } catch {}
  }

  const isLatest = version >= versions;

  return (
    <div data-layout-mode style={{ display: 'flex', flexDirection: 'column', height: '100dvh', overflow: 'hidden', background: 'var(--background)', color: 'var(--foreground)' }}>
      <header style={{ flexShrink: 0, display: 'flex', alignItems: 'center', gap: 12, padding: '10px 16px', borderBottom: '1px solid var(--border)', flexWrap: 'wrap' }}>
        <a href="/" style={{ display: 'inline-flex', gap: 6, alignItems: 'center', minHeight: 44, padding: '0 10px', borderRadius: 8, border: '1px solid var(--border)', color: 'var(--foreground)', textDecoration: 'none', fontSize: 14 }}>
          <ArrowLeft size={17} /> Thread
        </a>
        <div className="flex-1 min-w-0 max-md:order-3 max-md:flex-none max-md:basis-full max-md:w-full">
          <p style={{ ...eyebrow, margin: 0 }}>Artifact{kind === 'snapshot' ? ' · snapshot' : ''}</p>
          <h1 style={{ fontSize: 17, lineHeight: 1.3, margin: '2px 0 0', ...wrap }}>{title}</h1>
          <p style={{ fontSize: 12, color: 'var(--muted-foreground)', margin: '2px 0 0', ...wrap }}>{artifactPath}</p>
        </div>
        <div data-version-switcher className="max-md:order-2 max-md:ml-auto" style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <button aria-label="Previous version" disabled={version <= 1} onClick={() => gotoVersion(version - 1)} style={{ minHeight: 44, minWidth: 44, borderRadius: 8, border: '1px solid var(--border)', background: 'transparent', color: 'var(--foreground)', cursor: version <= 1 ? 'default' : 'pointer', opacity: version <= 1 ? 0.4 : 1, display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}><CaretLeft size={18} /></button>
          <span style={{ fontSize: 14, minWidth: 86, textAlign: 'center' }}>v{version} of {versions}{isLatest ? ' · latest' : ''}</span>
          <button aria-label="Next version" disabled={isLatest} onClick={() => gotoVersion(version + 1)} style={{ minHeight: 44, minWidth: 44, borderRadius: 8, border: '1px solid var(--border)', background: 'transparent', color: 'var(--foreground)', cursor: isLatest ? 'default' : 'pointer', opacity: isLatest ? 0.4 : 1, display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}><CaretRight size={18} /></button>
        </div>
      </header>

      <div style={{ flex: 1, minHeight: 0, display: 'flex' }}>
        <main data-artifact-canvas style={{ flex: 1, minWidth: 0, height: '100%', background: 'var(--muted)' }}>
          {error ? (
            <p role="alert" style={{ padding: 20, color: 'var(--destructive)' }}>{error}</p>
          ) : content === null ? (
            <p style={{ padding: 20 }}>Loading this version…</p>
          ) : (
            <iframe
              key={`${artifactPath}@${version}`}
              title={`Artifact: ${title} (v${version})`}
              srcDoc={srcDocForPage(content)}
              style={{ display: 'block', width: '100%', height: '100%', border: 'none', background: 'var(--background)', colorScheme: 'light dark' }}
            />
          )}
        </main>
        <aside data-annotations-panel className="max-lg:hidden" style={{ width: 300, flexShrink: 0, borderLeft: '1px solid var(--border)', overflowY: 'auto', padding: '16px 14px' }}>
          <p style={eyebrow}>Annotations — v{version}</p>
          {annotations.length === 0 ? (
            <p style={{ fontSize: 14, color: 'var(--muted-foreground)', lineHeight: 1.55 }}>No annotations on this version yet. Annotations you add with the annotator appear here and in the record.</p>
          ) : (
            <ul style={{ listStyle: 'none', margin: '10px 0 0', padding: 0, display: 'flex', flexDirection: 'column', gap: 10 }}>
              {annotations.map((a) => (
                <li key={a.entry_id} data-annotation-entry={a.entry_id} style={{ border: '1px solid var(--border)', borderRadius: 10, padding: '10px 12px', opacity: a.status === 'resolved' ? 0.75 : 1 }}>
                  <p style={{ fontSize: 12, color: 'var(--muted-foreground)', margin: '0 0 4px', display: 'flex', justifyContent: 'space-between', gap: 8 }}>
                    <span style={{ ...wrap }}>{a.element_id ? `#${a.element_id}` : (a.element_path || 'Page')}</span>
                    <span style={{ flexShrink: 0, fontWeight: 600, color: a.status === 'resolved' ? 'var(--muted-foreground)' : 'var(--foreground)' }}>{a.status === 'resolved' ? 'Resolved' : 'Open'}</span>
                  </p>
                  {a.element_text ? <p style={{ fontSize: 12, color: 'var(--muted-foreground)', margin: '0 0 4px', ...wrap }}>“{a.element_text}”</p> : null}
                  <p style={{ fontSize: 14, lineHeight: 1.5, margin: 0, ...wrap }}>{a.comment}</p>
                  {(a.replies || []).map((r: any) => (
                    <p key={r.entry_id} style={{ fontSize: 13, lineHeight: 1.5, margin: '8px 0 0', paddingLeft: 10, borderLeft: '2px solid var(--border)', ...wrap }}><span style={{ color: 'var(--muted-foreground)' }}>Driver: </span>{r.body}</p>
                  ))}
                  {a.resolution ? <p style={{ fontSize: 13, lineHeight: 1.5, margin: '8px 0 0', color: 'var(--muted-foreground)', ...wrap }}>Resolved{a.resolution.summary ? ` — ${a.resolution.summary}` : ''}</p> : null}
                </li>
              ))}
            </ul>
          )}
        </aside>
      </div>
      <Agentation endpoint="/agentation-sync" identifyingAttributes={['id', 'data-zone']} onAnnotationAdd={mirrorAnnotation} />
    </div>
  );
}
