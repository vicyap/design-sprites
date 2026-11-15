'use client';
import { useCallback, useEffect, useRef, useState, FormEvent, type CSSProperties } from 'react';
import { PaperPlaneTilt, HourglassMedium, X, List, FileText, DownloadSimple, LockKey, CheckCircle, SealCheck, ArrowRight, Broadcast } from '@phosphor-icons/react';

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
type UiState = { project: any; head: number; entries: Entry[]; questions: QState[]; sharpness: any; sharp_declared: boolean; files: any[]; drafts: any[]; presence?: { driver_present: boolean; label: string | null; source: string | null; last_seen: string | null } };
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
  if (s.result === 'struck') return 'Struck';
  // A skipped question's score carries result 'provisional' at BOTH stages:
  // deterministically the prediction is left standing, and a driver 'skip'
  // judgement confirms it. Name that in plain words — 'Provisional
  // (provisional)' / 'Provisional (final)' contradicted themselves (P5 audit).
  if (s.result === 'provisional') return s.provisional ? 'Prediction stands (provisional)' : 'Prediction stands (final)';
  return s.provisional ? `${cap(s.result)} (provisional)` : `${cap(s.result)} (final)`;
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
  // Overlay focus management (P5 accessibility audit): opening the drawer or
  // the pane moves focus to its close button; closing returns focus to the
  // element that opened it. Only the null->open and open->null transitions
  // act, so switching questions inside the pane never yanks focus.
  const paneRef = useRef<HTMLElement | null>(null);
  const drawerRef = useRef<HTMLElement | null>(null);
  const restoreFocusRef = useRef<Element | null>(null);
  const prevPaneRef = useRef<Pane>(null);
  const prevNavRef = useRef(false);
  useEffect(() => {
    const wasOpen = !!prevPaneRef.current || prevNavRef.current;
    const isOpen = !!pane || navOpen;
    if (isOpen && !wasOpen) {
      restoreFocusRef.current = document.activeElement;
      const root = pane ? paneRef.current : drawerRef.current;
      root?.querySelector<HTMLElement>('button[aria-label="Close pane"], button[aria-label="Close menu"]')?.focus();
    } else if (!isOpen && wasOpen) {
      (restoreFocusRef.current as HTMLElement | null)?.focus?.();
      restoreFocusRef.current = null;
    }
    prevPaneRef.current = pane;
    prevNavRef.current = navOpen;
  }, [pane, navOpen]);

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

  // v3.6 F1/F2: questions stay in thread order (deriveQuestions preserves
  // record order). Progress counts answered + skipped only; the navigator
  // and the batch control show status/counts only, never answer content.
  const questions = ui?.questions || [];
  const answeredCount = questions.filter((q) => q.state === 'answered' || q.state === 'skipped').length;
  const statusWord = (s: string) => (s === 'open' ? 'Open' : s === 'answered' ? 'Answered' : s === 'skipped' ? 'Skipped' : s === 'struck' ? 'Struck' : cap(s));
  function openQuestion(key: string) { setNotice(''); setPane({ type: 'question', key }); }
  // Next still-open question after `key` in thread order, wrapping to the
  // first open question before it; the current question itself never counts
  // as its own "next". Null when no other question is open.
  function nextOpenKeyAfter(key: string): string | null {
    const i = questions.findIndex((q) => q.key === key);
    if (i < 0) return questions.find((q) => q.state === 'open')?.key ?? null;
    const ordered = [...questions.slice(i + 1), ...questions.slice(0, i)];
    return ordered.find((q) => q.state === 'open')?.key ?? null;
  }
  const anyOpen = questions.some((q) => q.state === 'open');

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

  const paneNextKey = pane?.type === 'question' ? nextOpenKeyAfter(pane.key) : null;
  const paneIsQuestion = pane?.type === 'question' && qByKey.has(pane.key);

  const nav = ui && (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
      <div>
        <p style={eyebrow}>Project</p>
        <p style={{ fontSize: 17, fontWeight: 600, lineHeight: 1.3, margin: '6px 0', ...wrap }}>{ui.project.title || 'Untitled project'}</p>
        {ui.project.want && <p style={{ whiteSpace: 'pre-wrap', lineHeight: 1.55, fontSize: 14, ...wrap }}>{ui.project.want}</p>}
      </div>
      <div>
        <p style={eyebrow}>Status</p>
        <p style={{ fontSize: 14, marginTop: 6, lineHeight: 1.6 }}>
          {committed ? 'Committed — read-only' : 'Open'}
          <br />Sharpness: {ui.sharp_declared ? 'declared sharp' : ui.sharpness?.sharp ? 'gate passes' : 'not yet sharp'} ({ui.sharpness?.answered_load_bearing || 0} load-bearing answered)
        </p>
      </div>
      {/* v3.7 F3: the sidebar is files + export + Commit ONLY — the v3.6
          Questions navigator section is gone (Victor: the sidebar doesn't
          need every question listed). Moving between questions lives in
          the thread cards and the pane's Next-open-question flow. */}
      <div>
        <p style={eyebrow}>Files</p>
        <ul style={{ listStyle: 'none', margin: '6px 0 0', padding: 0, display: 'flex', flexDirection: 'column', gap: 2 }}>
          {explorer.map((f) => (
            <li key={f.path}>
              <button onClick={() => { openFile(f.path); setNavOpen(false); }} style={{ display: 'flex', gap: 8, alignItems: 'center', width: '100%', textAlign: 'left', minHeight: 44, padding: '6px 8px', borderRadius: 6, background: 'transparent', border: 'none', cursor: 'pointer', fontSize: 14 }}>
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
    <div style={{ display: 'flex', height: '100dvh', overflow: 'hidden' }}>
      {/* Left navigator — project structure (desktop) */}
      <aside className="hidden lg:block" style={{ width: 280, flexShrink: 0, borderRight: '1px solid var(--border)', padding: '20px 16px', height: '100%', overflowY: 'auto' }}>{nav}</aside>
      {/* Mobile drawer */}
      {navOpen && (
        <div style={{ position: 'fixed', inset: 0, zIndex: 40, background: 'var(--scrim)' }} onClick={() => setNavOpen(false)}>
          <aside ref={drawerRef} role="dialog" aria-modal="true" aria-label="Menu" className="lg:hidden" style={{ width: 280, maxWidth: '85vw', height: '100%', background: 'var(--background)', padding: '20px 16px', overflowY: 'auto' }} onClick={(e) => e.stopPropagation()}>
            <button aria-label="Close menu" onClick={() => setNavOpen(false)} style={{ minHeight: 44, minWidth: 44, background: 'transparent', border: 'none', cursor: 'pointer' }}><X size={22} /></button>
            {nav}
          </aside>
        </div>
      )}

      {/* Centre chat thread */}
      <main style={{ flex: 1, minWidth: 0, display: 'flex', justifyContent: 'center', height: '100%', overflow: 'hidden' }}>
        <div style={{ width: '100%', maxWidth: '65ch', display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0 }}>
          <div data-thread-scroll style={{ flex: 1, minHeight: 0, overflowY: 'auto', padding: '24px 16px 16px' }}>
          <header style={{ borderBottom: '1px solid var(--border)', paddingBottom: 16, marginBottom: 16 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <button aria-label="Open menu" className="lg:hidden" onClick={() => setNavOpen(true)} style={{ minHeight: 44, minWidth: 44, background: 'transparent', border: 'none', cursor: 'pointer' }}><List size={22} /></button>
              <p style={eyebrow}>Design Sprites v3</p>
            </div>
            <h1 style={{ fontSize: 28, lineHeight: 1.2, margin: '8px 0', ...wrap }}>{ui?.project?.title || 'Project stream'}</h1>
            {ui && <p data-progress style={{ fontSize: 14, color: 'var(--muted-foreground)', margin: '0 0 10px' }}>{answeredCount} of {questions.length} answered</p>}
            {committed ? (
              <div role="status" data-presence="committed" style={{ display: 'flex', gap: 8, alignItems: 'center', background: 'var(--warning-soft)', padding: '10px 12px', borderRadius: 8 }}>
                <LockKey size={20} /><span>Committed — this record is frozen read-only.</span>
              </div>
            ) : ui?.presence?.driver_present ? (
              // v3.7 F1: presence is honest to the turn-based driver model —
              // a driver is ATTACHED and will be woken by activity; this
              // never claims an AI is watching live.
              <div role="status" data-presence="driver" style={{ display: 'flex', gap: 8, alignItems: 'center', background: 'var(--success-soft)', padding: '10px 12px', borderRadius: 8 }}>
                <Broadcast size={20} /><span>A driver is attached — it will be woken by your activity. Your messages are stored immediately in the verbatim record.</span>
              </div>
            ) : (
              <div role="status" data-presence="waiting" style={{ display: 'flex', gap: 8, alignItems: 'center', background: 'var(--muted)', padding: '10px 12px', borderRadius: 8 }}>
                <HourglassMedium size={20} /><span>Waiting for a driver — no AI is present. Your messages are stored immediately in the verbatim record.</span>
              </div>
            )}
          </header>

          <section aria-label="Project stream" style={{ display: 'flex', flexDirection: 'column' }}>
            {!ui && <p>Loading the record…</p>}
            {ui && ui.entries.length === 0 && <p>No entries yet. Send the first message below — it will appear here verbatim.</p>}
            {ui?.entries.map((en) => (
              <ThreadEntry key={en.id} en={en} qByKey={qByKey} onOpenQuestion={openQuestion} onOpenFile={openFile} selectedKey={pane?.type === 'question' ? pane.key : null} />
            ))}
          </section>
          </div>

          <div data-chat-composer style={{ flexShrink: 0, borderTop: '1px solid var(--border)', background: 'var(--background)', padding: '12px 16px 16px' }}>
          <form onSubmit={send} style={{ display: 'flex', gap: 8 }}>
            <label style={{ flex: 1 }}>
              <span style={{ display: 'block', fontSize: 13, marginBottom: 6 }}>Message</span>
              <input aria-label="Message" value={text} disabled={!!committed} onChange={(e) => setText(e.target.value)} placeholder={committed ? 'Committed — read-only' : 'Type a message — stored verbatim'} style={{ width: '100%', minHeight: 48, padding: '10px 12px', border: '1px solid var(--border)', borderRadius: 8, background: 'var(--background)', color: 'var(--foreground)' }} />
            </label>
            <button type="submit" disabled={!!committed} style={{ minHeight: 48, minWidth: 48, padding: '0 16px', borderRadius: 8, background: 'var(--accent)', color: 'var(--accent-foreground)', display: 'flex', gap: 6, alignItems: 'center', border: 'none', cursor: 'pointer', alignSelf: 'flex-end', opacity: committed ? 0.5 : 1 }}>Send <PaperPlaneTilt size={18} /></button>
          </form>
          {err && <p role="alert" style={{ color: 'var(--destructive)', margin: '8px 0 0' }}>{err}</p>}
          </div>
        </div>
      </main>

      {/* Right pane — question answering / file viewing. Opens on demand; an
          answer NEVER closes it (Victor rule 2) — only the X does.
          POSITION MUST LIVE IN THE CLASSES, NOT the inline style: an inline
          `position: 'sticky'` silently overrode the max-lg:fixed class and
          left the pane in the flex row on mobile, squeezing the thread to
          a ~31px sliver (v3.5.1 hotfix, reproduced at a 390px viewport:
          pane sticky x=31 w=359, main w=31). Below lg the pane is a fixed
          overlay sheet; at lg it is the sticky side pane. Height is 100dvh
          so mobile browser chrome / the on-screen keyboard shrink the pane
          instead of pushing its footer off-screen. */}
      {pane && (
        <aside ref={paneRef} role="dialog" aria-modal="true" aria-label={pane.type === 'question' ? 'Question' : 'File'} style={{ width: 380, maxWidth: '92vw', flexShrink: 0, borderLeft: '1px solid var(--border)', height: '100dvh', overflow: 'hidden', background: 'var(--background)', display: 'flex', flexDirection: 'column' }} className="max-lg:fixed max-lg:right-0 max-lg:top-0 max-lg:z-30 max-lg:shadow-xl lg:sticky lg:top-0">
          <div style={{ display: 'flex', justifyContent: 'flex-end', flexShrink: 0, padding: '12px 16px 0' }}>
            <button aria-label="Close pane" onClick={() => setPane(null)} style={{ minHeight: 44, minWidth: 44, background: 'transparent', border: 'none', cursor: 'pointer' }}><X size={22} /></button>
          </div>
          <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
          {pane.type === 'question' && (() => { const qs = qByKey.get(pane.key); return qs ? (
            <QuestionPane key={pane.key} qs={qs} draft={ui?.drafts.find((d: any) => d.question_key === pane.key)} committed={!!committed} notice={notice} setNotice={setNotice} reload={load} />
          ) : <p>Question not found.</p>; })()}
          {pane.type === 'file' && (
            <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', padding: '4px 16px 20px' }}>
              <p style={eyebrow}>File{fileContent?.version ? ` · v${fileContent.version}` : ''}</p>
              <h2 style={{ fontSize: 17, margin: '6px 0 12px', wordBreak: 'break-all' }}>{pane.path}</h2>
              <pre style={{ whiteSpace: 'pre-wrap', wordBreak: 'break-word', lineHeight: 1.55, fontSize: 13, background: 'var(--muted)', padding: 12, borderRadius: 8 }}>{fileContent?.content ?? 'Loading…'}</pre>
            </div>
          )}
          </div>
          {/* v3.6 F1: batch flow footer. Advancing is ALWAYS the human's tap
              here — saving an answer never moves or closes the pane. When
              another question is open this is a button to it; when none is
              open the footer says so in plain words instead. */}
          {paneIsQuestion && (
            <div data-next-bar style={{ flexShrink: 0, borderTop: '1px solid var(--border)', background: 'var(--background)', padding: '12px 16px' }}>
              {paneNextKey ? (
                <button data-next-open={paneNextKey} onClick={() => openQuestion(paneNextKey)} style={{ width: '100%', minHeight: 48, padding: '0 14px', borderRadius: 8, background: 'var(--muted)', color: 'var(--foreground)', border: 'none', cursor: 'pointer', display: 'flex', gap: 8, alignItems: 'center', justifyContent: 'center', fontSize: 14 }}>Next open question <ArrowRight size={18} /></button>
              ) : anyOpen ? (
                <p role="status" style={{ fontSize: 14, margin: 0, textAlign: 'center', padding: '12px 0' }}>No other open questions</p>
              ) : (
                <p data-all-answered role="status" style={{ fontSize: 14, margin: 0, textAlign: 'center', padding: '12px 0' }}>All questions answered</p>
              )}
            </div>
          )}
        </aside>
      )}
    </div>
  );
}

function ThreadEntry({ en, qByKey, onOpenQuestion, onOpenFile, selectedKey }: { en: Entry; qByKey: Map<string, QState>; onOpenQuestion: (k: string) => void; onOpenFile: (p: string) => void; selectedKey?: string | null }) {
  if (en.kind === 'question') {
    // The card face is ONLY eyebrow + prompt, and the whole card is the
    // button (Victor rule 1). No answer button, no options/prediction meta.
    // v3.5.1 (Victor, 2026-11-13): the eyebrow also carries a STATUS word
    // once the question is answered/skipped, so the thread shows progress
    // at a glance — status only, never the answer content (the answer
    // itself stays in the pane and in its own answer entry below).
    // v3.7 F4: the card OUTLINE is the status colour — blue = open /
    // not yet answered, green = answered; skipped/struck keep the muted
    // neutral border. The status word stays (colour is an addition,
    // never the only signal). The "currently open in the pane" highlight
    // is a background tint + shadow, NOT the blue outline (blue is taken).
    const qs = qByKey.get(en.payload.key);
    const status = qs?.state === 'answered' ? 'Answered' : qs?.state === 'skipped' ? 'Skipped' : qs?.state === 'struck' ? 'Struck' : null;
    const outline = qs?.state === 'answered' ? '2px solid var(--success)' : qs?.state === 'open' ? '2px solid var(--info)' : '1px solid var(--border)';
    const isSelected = selectedKey === en.payload.key;
    // v3.7 F5: the question renders as a generative-UI-style WIDGET CARD in
    // the stream — a composed card (header row: QUESTION eyebrow +
    // load-bearing chip + status; prompt body; the recommendation, when
    // the driver gave one, as a distinct sub-panel inside the card). Still
    // status-only: never answer content. Whole card stays the button.
    return (
      <button data-card-status={qs?.state || 'open'} data-widget-card data-selected={isSelected || undefined} onClick={() => onOpenQuestion(en.payload.key)} style={{ textAlign: 'left', width: '100%', background: isSelected ? 'var(--accent-soft)' : 'var(--card)', border: outline, boxShadow: isSelected ? '0 2px 12px rgba(0,0,0,0.14)' : '0 1px 3px rgba(0,0,0,0.08)', borderRadius: 14, padding: '14px 16px', margin: '10px 0', cursor: 'pointer', minHeight: 48 }}>
        <span style={{ ...eyebrow, display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 8 }}>
          <span style={{ display: 'inline-flex', gap: 6, alignItems: 'center' }}>
            <span>Question</span>
            {en.payload.load_bearing && <span style={{ letterSpacing: '0.04em', fontSize: 11, padding: '2px 7px', borderRadius: 999, background: 'var(--warning-soft)', color: 'var(--warning)', border: '1px solid var(--border)' }}>Load-bearing</span>}
          </span>
          {status && <span style={{ display: 'inline-flex', gap: 4, alignItems: 'center', color: 'var(--foreground)' }}><CheckCircle size={14} /> {status}</span>}
        </span>
        <span style={{ display: 'block', fontSize: 16, lineHeight: 1.45, marginTop: 6, color: 'var(--card-foreground)', ...wrap }}>{en.payload.prompt || en.body}</span>
        {en.payload.recommended && (
          <span data-recommendation style={{ display: 'block', marginTop: 10, background: 'var(--muted)', borderRadius: 10, padding: '10px 12px' }}>
            <span style={{ ...eyebrow, fontSize: 11 }}>Recommendation</span>
            <span style={{ display: 'block', fontSize: 14, lineHeight: 1.5, marginTop: 4, color: 'var(--foreground)', ...wrap }}>{en.payload.recommended}</span>
          </span>
        )}
      </button>
    );
  }
  if (en.kind === 'answer') {
    const qs = qByKey.get(en.payload.question_key);
    const labels = (vals: string[]) => vals.map((v) => qs?.question?.options?.find((o: any) => o.value === v)?.label || v);
    const dialText = en.payload.dial_values ? Object.entries(en.payload.dial_values).map(([id, v]) => { const d = (qs?.question?.dials || []).find((x: any) => x.id === id); return `${d?.label || id}: ${v}${d?.unit ? ` ${d.unit}` : ''}`; }).join(' · ') : '';
    return (
      <article data-answer-card style={{ padding: '12px 14px', borderLeft: '3px solid var(--success)', background: 'var(--muted)', borderRadius: '4px 12px 12px 4px', margin: '8px 0' }}>
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
  // v3.7 F5: regular messages render as CHAT BUBBLES, modelled on the Muse
  // chat interface — human right-aligned on a soft tint, driver
  // left-aligned on a muted surface. Authorship is never colour alone:
  // every bubble carries a sender label + time meta above it. System
  // entries stay a quiet centred note (they are not conversation).
  if (en.role === 'system') {
    return (
      <p data-bubble="system" style={{ textAlign: 'center', fontSize: 13, color: 'var(--muted-foreground)', padding: '8px 12px', margin: '6px 0', ...wrap }}>{en.body}</p>
    );
  }
  const isHuman = en.role === 'human';
  const sender = en.kind === 'want' ? 'Want — You' : isHuman ? 'You' : 'Driver';
  const time = (() => { try { return new Date(en.createdAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }); } catch { return ''; } })();
  return (
    <div data-bubble={isHuman ? 'human' : 'driver'} style={{ display: 'flex', flexDirection: 'column', alignItems: isHuman ? 'flex-end' : 'flex-start', margin: '10px 0' }}>
      <p style={{ ...eyebrow, fontSize: 11, margin: '0 4px 4px' }}>{sender}{time ? ` · ${time}` : ''}</p>
      <div style={{ maxWidth: '85%', background: isHuman ? 'var(--accent-soft)' : 'var(--muted)', color: 'var(--foreground)', borderRadius: isHuman ? '18px 18px 4px 18px' : '18px 18px 18px 4px', padding: '10px 14px' }}>
        <p style={{ whiteSpace: 'pre-wrap', lineHeight: 1.55, margin: 0, ...wrap }}>{en.body}</p>
      </div>
    </div>
  );
}

function QuestionPane({ qs, draft, committed, notice, setNotice, reload }: { qs: QState; draft: any; committed: boolean; notice: string; setNotice: (s: string) => void; reload: () => Promise<void> }) {
  const q = qs.question;
  const isMulti = q.type === 'multi';
  const isPreview = q.type === 'preview';
  const variants: any[] = isPreview ? (q.variants || []) : [];
  const dials: any[] = isPreview ? (q.dials || []) : [];
  // v3.7 F2: the form ALWAYS renders, answered or not — prefilled from the
  // newest source: an in-progress draft (edits made since the answer) wins,
  // then the current answer itself, then empty. Nothing collapses away
  // after answering, so an answer can always be changed and re-saved.
  const ans = qs.answer;
  const [choice, setChoice] = useState<string>(draft?.choice || (ans && !ans.skipped ? (ans.choice || '') : ''));
  const [choices, setChoices] = useState<string[]>(draft?.choices || (ans && !ans.skipped ? (ans.choices || []) : []));
  const [otherText, setOtherText] = useState<string>(draft?.other_text || ans?.other_text || '');
  const [comment, setComment] = useState<string>(draft?.comment || ans?.comment || '');
  // Dial state starts from the saved draft, else the saved answer's dial
  // values, else each dial's declared default.
  const [dialValues, setDialValues] = useState<Record<string, number>>(() => {
    const init: Record<string, number> = {};
    for (const d of dials) init[d.id] = typeof draft?.dial_values?.[d.id] === 'number' ? draft.dial_values[d.id] : typeof ans?.dial_values?.[d.id] === 'number' ? ans.dial_values[d.id] : d.default;
    return init;
  });
  const [busy, setBusy] = useState(false);
  const [localErr, setLocalErr] = useState('');
  const saveTimer = useRef<any>(null);
  const firstRender = useRef(true);

  // Draft autosave: every change persists (debounced) so typing survives a
  // reload with no driver present. Skipped on first render (that state came
  // FROM the saved draft/draft-or-answer) and once the project is frozen.
  // v3.7 F2: edits to an ANSWERED question autosave as drafts too.
  useEffect(() => {
    if (firstRender.current) { firstRender.current = false; return; }
    if (committed) return;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => {
      fetch('/api/drafts', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ question_key: qs.key, choice: choice || null, choices: isMulti ? choices : null, other_text: otherText, comment, dial_values: isPreview ? dialValues : null }) }).catch(() => {});
    }, 400);
    return () => { if (saveTimer.current) clearTimeout(saveTimer.current); };
  }, [choice, choices, otherText, comment, dialValues, committed, qs.key, isMulti, isPreview]);

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
    const wasAnswered = !!qs.answer;
    setNotice(skipped ? 'Skip saved — the prediction stands. This pane stays open; close it with the X when you are done.' : `${wasAnswered ? 'Answer updated' : 'Answer saved'}. Provisional score: ${scoreLabel(j.score?.payload)}. This pane stays open; close it with the X when you are done.`);
    await reload();
  }

  const paneHeader = (
    <>
      <p style={eyebrow}>Question{qs.question.load_bearing ? ' · load-bearing' : ''}{isPreview ? ' · preview' : ''}</p>
      <h2 style={{ fontSize: 18, lineHeight: 1.35, margin: '8px 0 14px', ...wrap }}>{q.prompt}</h2>
      {/* v3.7 F2: an answered question keeps its full form below — this line
          states the current state and that editing is expected. A changed
          answer lands as a new provisional score until the driver judges
          it (existing scoring display rules). */}
      {qs.answer && (
        <div data-answered-note style={{ marginBottom: 14 }}>
          <p style={{ display: 'flex', gap: 8, alignItems: 'center', fontSize: 14, margin: '0 0 6px' }}><CheckCircle size={17} /> {qs.answer.skipped ? 'Skipped — pick an answer below to replace the skip.' : 'Answered — change anything below and save to update your answer.'}</p>
          {qs.score ? <p style={{ fontSize: 13, padding: '6px 10px', borderRadius: 6, background: 'var(--muted)', margin: 0 }}>Score: {scoreLabel(qs.score)} · {qs.score.reason} · {qs.score.source}</p> : null}
        </div>
      )}
    </>
  );

  return (
    <div style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0, height: '100%' }}>
        <form onSubmit={(e) => { e.preventDefault(); submit(false); }} style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0, height: '100%' }}>
          <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', padding: '4px 16px 16px' }}>
          {paneHeader}
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
                          style={{ width: 18, height: 18, flexShrink: 0 }}
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
                    style={{ marginTop: 3, width: 18, height: 18, flexShrink: 0 }}
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
                        style={{ marginTop: 3, width: 18, height: 18, flexShrink: 0 }}
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
                      style={{ width: '100%', height: 44, minHeight: 44, cursor: 'pointer' }}
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
          </div>
          <div data-save-bar style={{ flexShrink: 0, borderTop: '1px solid var(--border)', background: 'var(--background)', padding: '12px 16px' }}>
          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" disabled={busy || committed} style={{ flex: 1, minHeight: 48, padding: '0 14px', borderRadius: 8, background: 'var(--accent)', color: 'var(--accent-foreground)', border: 'none', cursor: 'pointer' }}>Save answer</button>
            <button type="button" disabled={busy || committed} onClick={() => submit(true)} style={{ minHeight: 48, padding: '0 14px', borderRadius: 8, background: 'var(--muted)', color: 'var(--foreground)', border: 'none', cursor: 'pointer' }}>Skip</button>
          </div>
          {localErr && <p role="alert" style={{ color: 'var(--destructive)', fontSize: 13 }}>{localErr}</p>}
          {notice ? <p role="status" style={{ fontSize: 13, marginTop: 10 }}>{notice}</p> : null}
          </div>
        </form>
    </div>
  );
}
