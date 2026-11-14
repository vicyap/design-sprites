'use client';
import { useCallback, useEffect, useRef, useState, FormEvent, type CSSProperties } from 'react';
import { PaperPlaneTilt, HourglassMedium, X, List, FileText, DownloadSimple, LockKey, CheckCircle, SealCheck } from '@phosphor-icons/react';

// Design Sprites v3 — full UI (P3, descoped per Amendment 2: chat + decisions
// only; NO artifact pane or inspector). v3.5 P2 adds the preview question
// type: variants (sandboxed HTML snippets) + question-level dials.
// Layout: left navigator = project structure, centre chat thread, right pane
// opens for question answering / file viewing (chat shifts left); on mobile
// the navigator is a drawer and the pane is a sheet.
// Victor's UI rules (2026-11-13): (1) question cards are themselves clickable
// — the whole card opens the question; there is NO explicit answer button and
// NO meta line on the card face (eyebrow + prompt only). (2) Answering in the
// right pane does NOT auto-close the pane — it stays open so a comment can be
// added; the human closes it explicitly with the X.

type Entry = { id: number; kind: string; role: string; body: string; payload: any; createdAt: string };
type QState = { key: string; question: any; answer?: any; answerId?: number; score?: any; state: string };
type UiState = { project: any; head: number; entries: Entry[]; questions: QState[]; sharpness: any; sharp_declared: boolean; files: any[]; drafts: any[] };
type Pane = { type: 'question'; key: string } | { type: 'file'; path: string } | null;

const eyebrow: CSSProperties = { letterSpacing: '0.08em', textTransform: 'uppercase', fontSize: 12, color: 'var(--muted-foreground)' };
// Entered content (wants, messages, prompts, labels, comments, file paths)
// can contain unbreakable strings — long URLs, tokens, paths with no spaces.
// overflowWrap:'anywhere' lets them wrap instead of blowing out the layout
// (P3.5 audit: up to 3,806px of horizontal overflow at 320px before this).
const wrap: CSSProperties = { overflowWrap: 'anywhere' };
// A srcDoc document does NOT inherit the app's colour scheme (measured in
// the P3.5 audit: computed color-scheme inside the frame stays "normal" and
// unstyled snippet text renders black even in dark mode, 1.06:1 on the dark
// background). Declaring the scheme inside the frame makes the snippet UA
// follow the OS exactly like the app does. The stored snippet stays
// verbatim — this meta is a rendering wrapper, like the sandbox itself,
// and snippets can never contain their own <meta> (the gate rejects it).
const srcDocFor = (html: string) => `<meta name="color-scheme" content="light dark">${html}`;

function scoreLabel(s: any): string {
  if (!s) return '';
  const state = s.result === 'struck' ? 'Struck' : s.provisional ? `${cap(s.result)} (provisional)` : `${cap(s.result)} (final)`;
  return state;
}
function cap(s: string) { return s ? s[0].toUpperCase() + s.slice(1) : s; }

export default function Page() {
  const [ui, setUi] = useState<UiState | null>(null);
  const [explorer, setExplorer] = useState<any[]>([]);
  const [pane, setPane] = useState<Pane>(null);
  const [navOpen, setNavOpen] = useState(false);
  const [text, setText] = useState('');
  const [err, setErr] = useState('');
  const [fileContent, setFileContent] = useState<{ path: string; content: string; version?: number } | null>(null);
  const [confirmCommit, setConfirmCommit] = useState(false);
  const [notice, setNotice] = useState('');

  const load = useCallback(async () => {
    const r = await fetch('/api/state', { cache: 'no-store' });
    if (r.ok) setUi(await r.json());
    const f = await fetch('/api/files', { cache: 'no-store' });
    if (f.ok) setExplorer((await f.json()).files || []);
  }, []);
  useEffect(() => { load(); const t = setInterval(load, 4000); return () => clearInterval(t); }, [load]);

  // Escape closes the topmost overlay (mobile drawer first, then the pane) —
  // keyboard parity with the X buttons (P3.5 accessibility audit: neither
  // overlay responded to Escape before this).
  useEffect(() => {
    if (!pane && !navOpen) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') { if (navOpen) setNavOpen(false); else setPane(null); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [pane, navOpen]);

  const committed = ui?.project?.status === 'committed';
  const qByKey = new Map((ui?.questions || []).map((q) => [q.key, q]));

  async function send(e: FormEvent) {
    e.preventDefault();
    if (!text.trim() || committed) return;
    const r = await fetch('/api/entries', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ body: text }) });
    if (!r.ok) { const j = await r.json().catch(() => ({})); setErr(j?.error === 'commit_freeze' ? 'This project is committed — the record is read-only.' : 'Could not save — try again.'); return; }
    setText(''); setErr(''); await load();
  }

  async function openFile(path: string) {
    setPane({ type: 'file', path });
    const r = await fetch(`/api/files?path=${encodeURIComponent(path)}`, { cache: 'no-store' });
    if (r.ok) setFileContent(await r.json()); else setFileContent({ path, content: 'Could not load this file.' });
  }

  async function doCommit() {
    if (!confirmCommit) { setConfirmCommit(true); return; }
    const r = await fetch('/api/commit', { method: 'POST' });
    if (r.ok) { setConfirmCommit(false); await load(); }
  }

  const nav = ui && (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      <div>
        <p style={eyebrow}>Project</p>
        <h2 style={{ fontSize: 17, lineHeight: 1.3, margin: '6px 0', ...wrap }}>{ui.project.title || 'Untitled project'}</h2>
        {ui.project.want && <p style={{ whiteSpace: 'pre-wrap', lineHeight: 1.55, fontSize: 14, ...wrap }}>{ui.project.want}</p>}
      </div>
      <div>
        <p style={eyebrow}>Status</p>
        <p style={{ fontSize: 14, marginTop: 6, lineHeight: 1.6 }}>
          {committed ? 'Committed — read-only' : 'Open'}
          <br />Sharpness: {ui.sharp_declared ? 'declared sharp' : ui.sharpness?.sharp ? 'gate passes' : 'not yet sharp'} ({ui.sharpness?.answered_load_bearing || 0} load-bearing answered)
        </p>
      </div>
      <div>
        <p style={eyebrow}>Files</p>
        <ul style={{ listStyle: 'none', margin: '6px 0 0', padding: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
          {explorer.map((f) => (
            <li key={f.path}>
              <button onClick={() => { openFile(f.path); setNavOpen(false); }} style={{ display: 'flex', gap: 8, alignItems: 'center', width: '100%', textAlign: 'left', minHeight: 40, padding: '6px 8px', borderRadius: 6, background: 'transparent', border: 'none', cursor: 'pointer', fontSize: 14 }}>
                <FileText size={17} /> <span style={{ ...wrap, minWidth: 0 }}>{f.path}</span>{f.version ? <span style={{ color: 'var(--muted-foreground)', fontSize: 12 }}>v{f.version}</span> : null}
              </button>
            </li>
          ))}
          {explorer.length === 0 && <li style={{ fontSize: 14, color: 'var(--muted-foreground)' }}>No files yet. Files the driver adds will appear here.</li>}
        </ul>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        <a href="/api/export" download style={{ display: 'flex', gap: 8, alignItems: 'center', justifyContent: 'center', minHeight: 48, padding: '0 14px', borderRadius: 8, border: '1px solid var(--border)', color: 'var(--foreground)', textDecoration: 'none', fontSize: 14 }}>
          <DownloadSimple size={18} /> Download export (.zip)
        </a>
        {!committed && (
          <button onClick={doCommit} style={{ display: 'flex', gap: 8, alignItems: 'center', justifyContent: 'center', minHeight: 48, padding: '0 14px', borderRadius: 8, background: confirmCommit ? 'var(--destructive)' : 'var(--muted)', color: confirmCommit ? 'var(--destructive-foreground)' : 'var(--foreground)', border: 'none', cursor: 'pointer', fontSize: 14 }}>
            <LockKey size={18} /> {confirmCommit ? 'Press again to freeze read-only' : 'Commit — freeze read-only'}
          </button>
        )}
        {committed && <p style={{ fontSize: 13, color: 'var(--muted-foreground)', display: 'flex', gap: 6, alignItems: 'center' }}><LockKey size={15} /> Frozen at {ui.project.committed_at || ''}</p>}
      </div>
    </div>
  );

  return (
    <div style={{ display: 'flex', minHeight: '100vh' }}>
      {/* Left navigator — project structure (desktop) */}
      <aside className="hidden lg:block" style={{ width: 280, flexShrink: 0, borderRight: '1px solid var(--border)', padding: '20px 16px', position: 'sticky', top: 0, height: '100vh', overflowY: 'auto' }}>{nav}</aside>
      {/* Mobile drawer */}
      {navOpen && (
        <div style={{ position: 'fixed', inset: 0, zIndex: 40, background: 'var(--scrim)' }} onClick={() => setNavOpen(false)}>
          <aside className="lg:hidden" style={{ width: 280, maxWidth: '85vw', height: '100%', background: 'var(--background)', padding: '20px 16px', overflowY: 'auto' }} onClick={(e) => e.stopPropagation()}>
            <button aria-label="Close menu" onClick={() => setNavOpen(false)} style={{ minHeight: 44, minWidth: 44, background: 'transparent', border: 'none', cursor: 'pointer' }}><X size={22} /></button>
            {nav}
          </aside>
        </div>
      )}

      {/* Centre chat thread */}
      <main style={{ flex: 1, minWidth: 0, display: 'flex', justifyContent: 'center' }}>
        <div style={{ width: '100%', maxWidth: '65ch', padding: '24px 16px 48px' }}>
          <header style={{ borderBottom: '1px solid var(--border)', paddingBottom: 16, marginBottom: 16 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <button aria-label="Open menu" className="lg:hidden" onClick={() => setNavOpen(true)} style={{ minHeight: 44, minWidth: 44, background: 'transparent', border: 'none', cursor: 'pointer' }}><List size={22} /></button>
              <p style={eyebrow}>Design Sprites v3</p>
            </div>
            <h1 style={{ fontSize: 28, lineHeight: 1.2, margin: '8px 0', ...wrap }}>{ui?.project?.title || 'Project stream'}</h1>
            {committed ? (
              <div role="status" style={{ display: 'flex', gap: 8, alignItems: 'center', background: 'var(--warning-soft)', padding: '10px 12px', borderRadius: 8 }}>
                <LockKey size={20} /><span>Committed — this record is frozen read-only.</span>
              </div>
            ) : (
              <div role="status" style={{ display: 'flex', gap: 8, alignItems: 'center', background: 'var(--muted)', padding: '10px 12px', borderRadius: 8 }}>
                <HourglassMedium size={20} /><span>Waiting for a driver — no AI is present. Your messages are stored immediately in the verbatim record.</span>
              </div>
            )}
          </header>

          <section aria-label="Project stream" style={{ display: 'flex', flexDirection: 'column' }}>
            {!ui && <p>Loading the record…</p>}
            {ui && ui.entries.length === 0 && <p>No entries yet. Send the first message below — it will appear here verbatim.</p>}
            {ui?.entries.map((en) => (
              <ThreadEntry key={en.id} en={en} qByKey={qByKey} onOpenQuestion={(key) => { setNotice(''); setPane({ type: 'question', key }); }} onOpenFile={openFile} />
            ))}
          </section>

          <form onSubmit={send} style={{ marginTop: 20, display: 'flex', gap: 8 }}>
            <label style={{ flex: 1 }}>
              <span style={{ display: 'block', fontSize: 13, marginBottom: 6 }}>Message</span>
              <input aria-label="Message" value={text} disabled={!!committed} onChange={(e) => setText(e.target.value)} placeholder={committed ? 'Committed — read-only' : 'Type a message — stored verbatim'} style={{ width: '100%', minHeight: 48, padding: '10px 12px', border: '1px solid var(--border)', borderRadius: 8, background: 'var(--background)', color: 'var(--foreground)' }} />
            </label>
            <button type="submit" disabled={!!committed} style={{ minHeight: 48, minWidth: 48, padding: '0 16px', borderRadius: 8, background: 'var(--accent)', color: 'var(--accent-foreground)', display: 'flex', gap: 6, alignItems: 'center', border: 'none', cursor: 'pointer', alignSelf: 'flex-end', opacity: committed ? 0.5 : 1 }}>Send <PaperPlaneTilt size={18} /></button>
          </form>
          {err && <p role="alert" style={{ color: 'var(--destructive)' }}>{err}</p>}
        </div>
      </main>

      {/* Right pane — question answering / file viewing. Opens on demand; an
          answer NEVER closes it (Victor rule 2) — only the X does. */}
      {pane && (
        <aside style={{ width: 380, maxWidth: '92vw', flexShrink: 0, borderLeft: '1px solid var(--border)', padding: '20px 16px', position: 'sticky', top: 0, height: '100vh', overflowY: 'auto', background: 'var(--background)' }} className="max-lg:fixed max-lg:right-0 max-lg:top-0 max-lg:z-30 max-lg:shadow-xl">
          <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
            <button aria-label="Close pane" onClick={() => setPane(null)} style={{ minHeight: 44, minWidth: 44, background: 'transparent', border: 'none', cursor: 'pointer' }}><X size={22} /></button>
          </div>
          {pane.type === 'question' && (() => { const qs = qByKey.get(pane.key); return qs ? (
            <QuestionPane key={pane.key} qs={qs} draft={ui?.drafts.find((d: any) => d.question_key === pane.key)} committed={!!committed} notice={notice} setNotice={setNotice} reload={load} />
          ) : <p>Question not found.</p>; })()}
          {pane.type === 'file' && (
            <div>
              <p style={eyebrow}>File{fileContent?.version ? ` · v${fileContent.version}` : ''}</p>
              <h2 style={{ fontSize: 17, margin: '6px 0 12px', wordBreak: 'break-all' }}>{pane.path}</h2>
              <pre style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-word', lineHeight: 1.55, fontSize: 13, background: 'var(--muted)', padding: 12, borderRadius: 8 }}>{fileContent?.content ?? 'Loading…'}</pre>
            </div>
          )}
        </aside>
      )}
    </div>
  );
}

function ThreadEntry({ en, qByKey, onOpenQuestion, onOpenFile }: { en: Entry; qByKey: Map<string, QState>; onOpenQuestion: (k: string) => void; onOpenFile: (p: string) => void }) {
  if (en.kind === 'question') {
    // The card face is ONLY eyebrow + prompt, and the whole card is the
    // button (Victor rule 1). No answer button, no options/prediction meta.
    return (
      <button onClick={() => onOpenQuestion(en.payload.key)} style={{ textAlign: 'left', width: '100%', background: 'var(--card)', border: '1px solid var(--border)', borderRadius: 10, padding: '14px 16px', margin: '8px 0', cursor: 'pointer', minHeight: 48 }}>
        <span style={{ ...eyebrow, display: 'block' }}>Question</span>
        <span style={{ display: 'block', fontSize: 16, lineHeight: 1.45, marginTop: 6, color: 'var(--card-foreground)', ...wrap }}>{en.payload.prompt || en.body}</span>
      </button>
    );
  }
  if (en.kind === 'answer') {
    const qs = qByKey.get(en.payload.question_key);
    const labels = (vals: string[]) => vals.map((v) => qs?.question?.options?.find((o: any) => o.value === v)?.label || v);
    const dialText = en.payload.dial_values ? Object.entries(en.payload.dial_values).map(([id, v]) => { const d = (qs?.question?.dials || []).find((x: any) => x.id === id); return `${d?.label || id}: ${v}${d?.unit ? ` ${d.unit}` : ''}`; }).join(' · ') : '';
    return (
      <article style={{ padding: '10px 0 10px 14px', borderLeft: '3px solid var(--accent)', margin: '6px 0' }}>
        <p style={eyebrow}>Answer — {en.payload.question_key}</p>
        {en.payload.skipped ? <p style={{ lineHeight: 1.55 }}>Skipped — prediction stands.</p> : (
          <p style={{ lineHeight: 1.55, ...wrap }}>
            {qs?.question?.type === 'multi' ? labels(en.payload.choices || []).join(', ') : labels([en.payload.choice].filter(Boolean)).join(', ') || ''}
            {en.payload.choice === 'other' || (en.payload.choices || []).includes('other') ? (en.payload.other_text ? `: ${en.payload.other_text}` : '') : ''}
          </p>
        )}
        {dialText ? <p style={{ lineHeight: 1.55, ...wrap }}>Dials — {dialText}</p> : null}
        {en.payload.comment ? <p style={{ lineHeight: 1.55, color: 'var(--muted-foreground)', ...wrap }}>Comment: {en.payload.comment}</p> : null}
      </article>
    );
  }
  if (en.kind === 'score') {
    const s = en.payload;
    return (
      <p style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 13, padding: '6px 10px', margin: '4px 0', borderRadius: 6, background: s.result === 'hit' ? 'var(--success-soft)' : s.result === 'miss' ? 'var(--warning-soft)' : 'var(--muted)', color: 'var(--foreground)' }}>
        {s.result === 'hit' ? <SealCheck size={16} /> : <CheckCircle size={16} />}
        <span style={{ ...wrap, minWidth: 0 }}>Score — {s.question_key}: {scoreLabel(s)} · {s.reason} · {s.source}</span>
      </p>
    );
  }
  if (en.kind === 'model') {
    return (
      <button onClick={() => onOpenFile('model.md')} style={{ textAlign: 'left', background: 'transparent', border: 'none', cursor: 'pointer', padding: '10px 0', fontSize: 14, color: 'var(--foreground)' }}>
        <span style={eyebrow}>Model</span><br />model.md updated to v{en.payload.version} — open in the explorer
      </button>
    );
  }
  if (en.kind === 'commit') {
    return <p style={{ display: 'flex', gap: 8, alignItems: 'center', padding: '10px 0', fontSize: 14 }}><LockKey size={17} /> {en.body}</p>;
  }
  if (en.kind === 'sharp') {
    return <p style={{ display: 'flex', gap: 8, alignItems: 'center', padding: '10px 0', fontSize: 14 }}><SealCheck size={17} /> Model declared sharp.</p>;
  }
  return (
    <article style={{ padding: '12px 0', borderBottom: '1px solid var(--border)' }}>
      <p style={eyebrow}>{en.role} · {en.kind}</p>
      <p style={{ whiteSpace: 'pre-wrap', lineHeight: 1.55, ...wrap }}>{en.body}</p>
    </article>
  );
}

function QuestionPane({ qs, draft, committed, notice, setNotice, reload }: { qs: QState; draft: any; committed: boolean; notice: string; setNotice: (s: string) => void; reload: () => Promise<void> }) {
  const q = qs.question;
  const isMulti = q.type === 'multi';
  const isPreview = q.type === 'preview';
  const variants: any[] = isPreview ? (q.variants || []) : [];
  const dials: any[] = isPreview ? (q.dials || []) : [];
  const [choice, setChoice] = useState<string>(draft?.choice || '');
  const [choices, setChoices] = useState<string[]>(draft?.choices || []);
  const [otherText, setOtherText] = useState<string>(draft?.other_text || '');
  const [comment, setComment] = useState<string>(draft?.comment || '');
  // Dial state starts from the saved draft, else each dial's declared default.
  const [dialValues, setDialValues] = useState<Record<string, number>>(() => {
    const init: Record<string, number> = {};
    for (const d of dials) init[d.id] = typeof draft?.dial_values?.[d.id] === 'number' ? draft.dial_values[d.id] : d.default;
    return init;
  });
  const [busy, setBusy] = useState(false);
  const [localErr, setLocalErr] = useState('');
  const saveTimer = useRef<any>(null);
  const firstRender = useRef(true);

  // Draft autosave: every change persists (debounced) so typing survives a
  // reload with no driver present. Skipped on first render (that state came
  // FROM the saved draft) and once the question is answered or frozen.
  useEffect(() => {
    if (firstRender.current) { firstRender.current = false; return; }
    if (qs.answer || committed) return;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => {
      fetch('/api/drafts', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ question_key: qs.key, choice: choice || null, choices: isMulti ? choices : null, other_text: otherText, comment, dial_values: isPreview ? dialValues : null }) }).catch(() => {});
    }, 400);
    return () => { if (saveTimer.current) clearTimeout(saveTimer.current); };
  }, [choice, choices, otherText, comment, dialValues, qs.answer, committed, qs.key, isMulti, isPreview]);

  const otherSelected = isMulti ? choices.includes('other') : choice === 'other';

  async function submit(skipped: boolean) {
    if (busy || committed) return;
    setBusy(true); setLocalErr('');
    const body: any = { kind: 'answer', question_key: qs.key, skipped };
    if (!skipped) {
      if (isMulti) body.choices = choices; else body.choice = choice || null;
      body.other_text = otherSelected ? otherText : '';
      body.comment = comment;
      if (isPreview) body.dial_values = dialValues;
    }
    const r = await fetch('/api/entries', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
    const j = await r.json().catch(() => ({}));
    setBusy(false);
    if (!r.ok) { setLocalErr(j?.error === 'commit_freeze' ? 'This project is committed — the record is read-only.' : 'Could not save — try again.'); return; }
    // Victor rule 2: the pane STAYS OPEN after the answer lands (so a comment
    // can be added / the result reviewed). Only the X closes it. There is
    // deliberately no close call here.
    setNotice(skipped ? 'Skip saved — the prediction stands. This pane stays open; close it with the X when you are done.' : `Answer saved. Provisional score: ${scoreLabel(j.score?.payload)}. This pane stays open; close it with the X when you are done.`);
    await reload();
  }

  const answeredDialText = qs.answer?.dial_values ? Object.entries(qs.answer.dial_values).map(([id, v]) => { const d = dials.find((x: any) => x.id === id); return `${d?.label || id}: ${v}${d?.unit ? ` ${d.unit}` : ''}`; }).join(' · ') : '';

  return (
    <div>
      <p style={eyebrow}>Question{qs.question.load_bearing ? ' · load-bearing' : ''}{isPreview ? ' · preview' : ''}</p>
      <h2 style={{ fontSize: 18, lineHeight: 1.35, margin: '8px 0 14px', ...wrap }}>{q.prompt}</h2>

      {qs.answer ? (
        <div>
          <p style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 14 }}><CheckCircle size={17} /> Answered</p>
          <p style={{ lineHeight: 1.6, fontSize: 14, ...wrap }}>
            {qs.answer.skipped ? 'Skipped — prediction stands.' : (isMulti ? (qs.answer.choices || []).join(', ') : qs.answer.choice || '')}
            {qs.answer.other_text ? `: ${qs.answer.other_text}` : ''}
          </p>
          {answeredDialText ? <p style={{ lineHeight: 1.6, fontSize: 14, ...wrap }}>Dials — {answeredDialText}</p> : null}
          {qs.answer.comment ? <p style={{ lineHeight: 1.6, fontSize: 14, color: 'var(--muted-foreground)', ...wrap }}>Comment: {qs.answer.comment}</p> : null}
          {qs.score ? <p style={{ fontSize: 13, padding: '6px 10px', borderRadius: 6, background: 'var(--muted)' }}>Score: {scoreLabel(qs.score)} · {qs.score.reason} · {qs.score.source}</p> : null}
          {notice ? <p role="status" style={{ fontSize: 13, marginTop: 10 }}>{notice}</p> : null}
        </div>
      ) : (
        <form onSubmit={(e) => { e.preventDefault(); submit(false); }}>
          {isPreview ? (
            <fieldset style={{ border: 'none', margin: 0, padding: 0 }}>
              <legend style={{ fontSize: 13, marginBottom: 8 }}>Choose one preview</legend>
              {/* Variants stack VERTICALLY, full-width (v2 lesson: horizontal
                  rows squeeze/clip). Each snippet renders in a sandboxed
                  iframe (sandbox="" — no scripts, no same-origin access) via
                  srcDoc, so snippet CSS can never leak into the app chrome.
                  A snippet with no colours of its own must follow the OS
                  scheme like the app: srcDocFor declares the scheme inside
                  the frame (an srcDoc document does not inherit it — P3.5
                  audit measured unstyled snippet text at 1.06:1 in dark
                  mode before this). */}
              <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
                {variants.map((v: any) => {
                  const selected = choice === v.id;
                  return (
                    <div key={v.id} style={{ border: '1px solid var(--border)', borderRadius: 8, overflow: 'hidden', background: selected ? 'var(--accent-soft)' : 'var(--background)' }}>
                      <label style={{ display: 'flex', gap: 10, alignItems: 'center', minHeight: 48, padding: '10px 12px', cursor: committed ? 'default' : 'pointer' }}>
                        <input
                          type="radio"
                          name={`q-${qs.key}`}
                          value={v.id}
                          disabled={committed}
                          checked={selected}
                          onChange={() => setChoice(v.id)}
                          style={{ width: 18, height: 18 }}
                        />
                        <span style={{ lineHeight: 1.45, ...wrap, minWidth: 0 }}>{v.label}</span>
                      </label>
                      <iframe
                        title={`Preview variant: ${v.label}`}
                        sandbox=""
                        srcDoc={srcDocFor(v.html)}
                        style={{ display: 'block', width: '100%', height: 180, border: 'none', borderTop: '1px solid var(--border)', background: 'var(--background)', colorScheme: 'light dark' }}
                      />
                    </div>
                  );
                })}
                {/* Other lives INSIDE the group, after the variants (v3 rule). */}
                <label style={{ display: 'flex', gap: 10, alignItems: 'flex-start', minHeight: 48, padding: '10px 12px', border: '1px solid var(--border)', borderRadius: 8, cursor: committed ? 'default' : 'pointer', background: choice === 'other' ? 'var(--accent-soft)' : 'var(--background)' }}>
                  <input
                    type="radio"
                    name={`q-${qs.key}`}
                    value="other"
                    disabled={committed}
                    checked={choice === 'other'}
                    onChange={() => setChoice('other')}
                    style={{ marginTop: 3, width: 18, height: 18 }}
                  />
                  <span style={{ lineHeight: 1.45 }}>Other</span>
                </label>
              </div>
            </fieldset>
          ) : (
            <fieldset style={{ border: 'none', margin: 0, padding: 0 }}>
              <legend style={{ fontSize: 13, marginBottom: 8 }}>{isMulti ? 'Choose any that apply' : 'Choose one'}</legend>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                {(q.options || []).map((o: any) => {
                  const selected = isMulti ? choices.includes(o.value) : choice === o.value;
                  return (
                    <label key={o.value} style={{ display: 'flex', gap: 10, alignItems: 'flex-start', minHeight: 48, padding: '10px 12px', border: '1px solid var(--border)', borderRadius: 8, cursor: committed ? 'default' : 'pointer', background: selected ? 'var(--accent-soft)' : 'var(--background)' }}>
                      <input
                        type={isMulti ? 'checkbox' : 'radio'}
                        name={`q-${qs.key}`}
                        value={o.value}
                        disabled={committed}
                        checked={selected}
                        onChange={() => { if (isMulti) setChoices(selected ? choices.filter((c) => c !== o.value) : [...choices, o.value]); else setChoice(o.value); }}
                        style={{ marginTop: 3, width: 18, height: 18 }}
                      />
                      <span style={{ lineHeight: 1.45, ...wrap, minWidth: 0 }}>{o.label}</span>
                    </label>
                  );
                })}
              </div>
            </fieldset>
          )}
          {isPreview && dials.length > 0 && (
            <fieldset style={{ border: 'none', margin: '16px 0 0', padding: 0 }}>
              <legend style={{ fontSize: 13, marginBottom: 8 }}>Dials</legend>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
                {dials.map((d: any) => (
                  <label key={d.id} style={{ display: 'block' }}>
                    <span style={{ display: 'flex', justifyContent: 'space-between', gap: 8, fontSize: 13, marginBottom: 6 }}>
                      <span style={{ ...wrap, minWidth: 0 }}>{d.label}</span>
                      <span style={{ ...wrap, minWidth: 0, textAlign: 'right' }}>{dialValues[d.id]}{d.unit ? ` ${d.unit}` : ''}</span>
                    </span>
                    <input
                      type="range"
                      aria-label={d.label}
                      min={d.min}
                      max={d.max}
                      step={d.step}
                      value={dialValues[d.id] ?? d.default}
                      disabled={committed}
                      onChange={(e) => setDialValues({ ...dialValues, [d.id]: Number(e.target.value) })}
                      style={{ width: '100%', minHeight: 32 }}
                    />
                  </label>
                ))}
              </div>
            </fieldset>
          )}
          {otherSelected && (
            <label style={{ display: 'block', marginTop: 12 }}>
              <span style={{ display: 'block', fontSize: 13, marginBottom: 6 }}>Your other answer</span>
              <input aria-label="Other answer text" value={otherText} disabled={committed} onChange={(e) => setOtherText(e.target.value)} style={{ width: '100%', minHeight: 48, padding: '10px 12px', border: '1px solid var(--border)', borderRadius: 8, background: 'var(--background)', color: 'var(--foreground)' }} />
            </label>
          )}
          <label style={{ display: 'block', marginTop: 12 }}>
            <span style={{ display: 'block', fontSize: 13, marginBottom: 6 }}>Comment (optional)</span>
            <textarea aria-label="Comment" value={comment} disabled={committed} onChange={(e) => setComment(e.target.value)} rows={3} style={{ width: '100%', padding: '10px 12px', border: '1px solid var(--border)', borderRadius: 8, background: 'var(--background)', color: 'var(--foreground)', lineHeight: 1.5 }} />
          </label>
          <p style={{ fontSize: 12, color: 'var(--muted-foreground)', marginTop: 8 }}>Drafts save automatically as you type.</p>
          <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
            <button type="submit" disabled={busy || committed} style={{ flex: 1, minHeight: 48, padding: '0 14px', borderRadius: 8, background: 'var(--accent)', color: 'var(--accent-foreground)', border: 'none', cursor: 'pointer' }}>Save answer</button>
            <button type="button" disabled={busy || committed} onClick={() => submit(true)} style={{ minHeight: 48, padding: '0 14px', borderRadius: 8, background: 'var(--muted)', color: 'var(--foreground)', border: 'none', cursor: 'pointer' }}>Skip</button>
          </div>
          {localErr && <p role="alert" style={{ color: 'var(--destructive)', fontSize: 13 }}>{localErr}</p>}
          {notice ? <p role="status" style={{ fontSize: 13, marginTop: 10 }}>{notice}</p> : null}
        </form>
      )}
    </div>
  );
}
