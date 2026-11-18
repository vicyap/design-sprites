// Design Sprites v3 — turn protocol: pure, deterministic logic.
// No DB, no IO imports: everything here is testable in isolation.
// Scoring split (per model): deterministic code computes the PROVISIONAL score
// at answer time (choice vs prediction, Other = miss); the driver JUDGES each
// provisional via score_answer (hit / miss / skip / strike). A build-changing
// comment is a driver judgement: the driver passes judgement "miss" with
// reason "build_changing_comment" — code cannot detect it, so it is not
// encoded here beyond carrying the reason through verbatim.
//
// v3.5 preview type: variants are SMALL SELF-CONTAINED HTML snippets
// ({id, label, html}) rendered sandboxed + script-free in the UI; dials are
// question-level slider controls ({id, label, min, max, step, default, unit?}).
// An answer carries the chosen variant id in `choice` (exactly like single)
// plus `dial_values` verbatim. Dial values are data, never scored.

export type QuestionType = 'single' | 'multi' | 'preview';
export type ScoreResult = 'hit' | 'miss' | 'provisional' | 'struck';

export interface QOption { value: string; label: string }
export interface Variant { id: string; label: string; html: string }
export interface Dial { id: string; label: string; min: number; max: number; step: number; default: number; unit?: string }
export interface QuestionPayload {
  key: string;
  type: QuestionType;
  prompt: string;
  load_bearing?: boolean;
  options: QOption[];
  prediction?: string | string[] | null;
  recommended?: string | null;
  variants?: Variant[];
  dials?: Dial[];
}
export interface AnswerPayload {
  question_key: string;
  choice?: string | null;
  choices?: string[] | null;
  other_text?: string;
  comment?: string;
  skipped?: boolean;
  dial_values?: Record<string, number> | null;
}
export interface ScorePayload {
  question_key: string;
  result: ScoreResult;
  provisional: boolean;
  reason: string;
  source: 'deterministic' | 'driver';
}
export interface GateError { code: string; message: string; question_key?: string }

export const OTHER_OPTION: QOption = { value: 'other', label: 'Other' };
export const MAX_NAMED_OPTIONS = 9;
// Snippets are SMALL by spec (a variant is a swatch, not a page). The cap is
// enforced at the gate (P3.5 audit: a 120,000-char snippet passed before it).
export const MAX_SNIPPET_CHARS = 20000;

// The Other option lives INSIDE the option group. Staging never includes it;
// commit appends it automatically so it can never be forgotten or duplicated.
export function withOther(options: QOption[]): QOption[] {
  if (options.some((o) => o.value === 'other')) return options;
  return [...options, { ...OTHER_OPTION }];
}

// Preview questions may omit `options`: the selectable group IS the variant
// list, so options are derived from the variants (value = variant id,
// label = variant label). When options ARE passed they must cover the
// variant ids exactly (the v3 contract, kept).
export function previewOptions(q: any): QOption[] {
  if (Array.isArray(q?.options) && q.options.length) return q.options;
  const variants: any[] = Array.isArray(q?.variants) ? q.variants : [];
  return variants.filter((v) => v && typeof v.id === 'string' && v.id).map((v) => ({ value: v.id, label: typeof v.label === 'string' && v.label ? v.label : v.id }));
}

// Snippet safety gate for preview variant html. A snippet must be a small
// self-contained fragment: inline styles and inline SVG are fine; anything
// that can execute script or load an external resource is rejected.
// Returns a human-actionable reason string, or null when the snippet is safe.
export function snippetSafetyViolation(html: string): string | null {
  const s = html;
  if (/<script\b/i.test(s)) return 'contains a <script> tag';
  if (/<(iframe|object|embed|link|base|form|meta)\b/i.test(s)) return 'contains a forbidden embedding/form/meta tag';
  if (/\son\w+\s*=/i.test(s)) return 'contains an inline event-handler attribute (on*=)';
  if (/\bsrcset\s*=/i.test(s)) return 'contains a srcset attribute (external resources are not allowed)';
  if (/\bsrc\s*=/i.test(s)) return 'contains a src attribute (external resources are not allowed; use inline SVG or CSS instead)';
  const hrefRe = /\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi;
  let m: RegExpExecArray | null;
  while ((m = hrefRe.exec(s)) !== null) {
    const v = (m[1] ?? m[2] ?? m[3] ?? '').trim();
    if (!v.startsWith('#')) return `contains an href that is not an in-snippet fragment: "${v.slice(0, 60)}"`;
  }
  if (/\bposter\s*=/i.test(s)) return 'contains a poster attribute (external resources are not allowed)';
  if (/\bbackground\s*=/i.test(s)) return 'contains a background attribute (external resources are not allowed)';
  if (/(javascript|vbscript)\s*:/i.test(s)) return 'contains a javascript:/vbscript: URI';
  // CSS url(): allowlist, not denylist. Only an embedded data:image or an
  // in-snippet #fragment reference may appear; everything else (http(s),
  // protocol-relative, backslash-obfuscated schemes like url(https:\\…),
  // data:text/html, …) loads an external or active resource. (P3.5 audit:
  // the old (https?:)?// pattern let both of those bypasses through.)
  const urlRe = /url\(\s*([^)]*)\)/gi;
  let u: RegExpExecArray | null;
  while ((u = urlRe.exec(s)) !== null) {
    const target = u[1].trim().replace(/^["']|["']$/g, '').trim();
    if (target.startsWith('#') || /^data:image\//i.test(target)) continue;
    return `contains a CSS url() that is not an embedded image or fragment: "${target.slice(0, 60)}"`;
  }
  if (/@import/i.test(s)) return 'contains a CSS @import (external resources are not allowed)';
  return null;
}

export function validateDial(d: any, seen: Set<string>): GateError[] {
  const errs: GateError[] = [];
  const id = typeof d?.id === 'string' ? d.id : '';
  if (!id) { errs.push({ code: 'bad_dial', message: 'every dial needs a non-empty id' }); return errs; }
  if (seen.has(id)) errs.push({ code: 'bad_dial', message: `dial ids must be unique, duplicate: ${id}` });
  seen.add(id);
  if (typeof d?.label !== 'string' || !d.label) errs.push({ code: 'bad_dial', message: `dial ${id} needs a non-empty label` });
  for (const f of ['min', 'max', 'step', 'default'] as const) {
    if (typeof d?.[f] !== 'number' || !Number.isFinite(d[f])) errs.push({ code: 'bad_dial', message: `dial ${id} needs a finite numeric ${f}` });
  }
  if (errs.length) return errs;
  if (!(d.min < d.max)) errs.push({ code: 'bad_dial_range', message: `dial ${id} needs min < max, got min=${d.min} max=${d.max}` });
  if (!(d.step > 0)) errs.push({ code: 'bad_dial_range', message: `dial ${id} needs step > 0, got ${d.step}` });
  if (d.default < d.min || d.default > d.max) errs.push({ code: 'bad_dial_range', message: `dial ${id} default ${d.default} is outside [${d.min}, ${d.max}]` });
  return errs;
}

export function validateQuestion(q: any, existingKeys: Set<string>): GateError[] {
  const errs: GateError[] = [];
  const key = typeof q?.key === 'string' ? q.key : '';
  if (!key) { errs.push({ code: 'missing_key', message: 'question key is required' }); return errs; }
  if (existingKeys.has(key)) errs.push({ code: 'duplicate_question_key', message: `question key already exists: ${key}`, question_key: key });
  if (!['single', 'multi', 'preview'].includes(q?.type)) errs.push({ code: 'bad_type', message: `type must be single|multi|preview, got: ${String(q?.type)}`, question_key: key });
  if (typeof q?.prompt !== 'string' || !q.prompt.trim()) errs.push({ code: 'missing_prompt', message: 'prompt is required', question_key: key });
  const isPreview = q?.type === 'preview';
  // For preview, options may be omitted and are derived from the variants.
  const opts: any[] = isPreview ? previewOptions(q) : (Array.isArray(q?.options) ? q.options : []);
  const named = opts.filter((o) => o && o.value !== 'other');
  if (!isPreview || Array.isArray(q?.options)) {
    if (named.length < 1) errs.push({ code: 'no_options', message: 'at least one named option is required', question_key: key });
  }
  if (named.length > MAX_NAMED_OPTIONS) errs.push({ code: 'too_many_options', message: `${named.length} named options exceeds the max of ${MAX_NAMED_OPTIONS} (Other is added automatically as the 10th)`, question_key: key });
  const values = named.map((o) => o?.value);
  if (new Set(values).size !== values.length) errs.push({ code: 'duplicate_option', message: 'option values must be unique', question_key: key });
  for (const o of named) {
    if (typeof o?.value !== 'string' || !o.value || typeof o?.label !== 'string' || !o.label) {
      errs.push({ code: 'bad_option', message: 'every option needs a non-empty value and label', question_key: key }); break;
    }
  }
  // Prediction must reference named options (for preview: the variant ids).
  const pred = q?.prediction;
  if (pred !== undefined && pred !== null) {
    if (q.type === 'multi') {
      if (!Array.isArray(pred) || pred.length === 0 || pred.some((p: any) => !values.includes(p)))
        errs.push({ code: 'bad_prediction', message: 'multi prediction must be a non-empty subset of option values', question_key: key });
    } else if (typeof pred !== 'string' || !values.includes(pred)) {
      errs.push({ code: 'bad_prediction', message: isPreview ? 'prediction must be one of the variant ids' : 'prediction must be one of the option values', question_key: key });
    }
  }
  // Dials are a preview-only concept.
  const dials: any[] = Array.isArray(q?.dials) ? q.dials : [];
  if (q?.dials !== undefined && !Array.isArray(q.dials)) errs.push({ code: 'bad_dial', message: 'dials must be an array', question_key: key });
  if (dials.length && !isPreview) errs.push({ code: 'bad_dial', message: 'dials are only valid on preview questions', question_key: key });
  if (isPreview) {
    // Preview: 2-4 variants {id, label, html}, unique stable ids, safe snippets.
    const variants: any[] = Array.isArray(q?.variants) ? q.variants : [];
    if (variants.length < 2 || variants.length > 4)
      errs.push({ code: 'bad_variant_count', message: `preview questions need 2-4 variants, got ${variants.length}`, question_key: key });
    const vids = variants.map((v) => v?.id);
    if (vids.some((v) => typeof v !== 'string' || !v) || new Set(vids).size !== vids.length)
      errs.push({ code: 'bad_variant', message: 'every variant needs a unique non-empty id', question_key: key });
    for (const v of variants) {
      if (typeof v?.label !== 'string' || !v.label) errs.push({ code: 'bad_variant', message: `variant ${v?.id || '?'} needs a non-empty label`, question_key: key });
      if (typeof v?.html !== 'string' || !v.html.trim()) errs.push({ code: 'bad_variant', message: `variant ${v?.id || '?'} needs a non-empty html snippet`, question_key: key });
      else if (v.html.length > MAX_SNIPPET_CHARS) errs.push({ code: 'snippet_too_large', message: `variant ${v.id} html is ${v.html.length} chars; snippets must be small (max ${MAX_SNIPPET_CHARS} chars)`, question_key: key });
      else {
        const violation = snippetSafetyViolation(v.html);
        if (violation) errs.push({ code: 'unsafe_snippet', message: `variant ${v.id} html is not a safe self-contained snippet: ${violation}`, question_key: key });
      }
    }
    // When options were passed explicitly, they must cover variant ids exactly.
    if (Array.isArray(q?.options)) {
      const optSet = new Set(values); const varSet = new Set(vids);
      const missing = vids.filter((v) => !optSet.has(v)); const extra = values.filter((v: string) => !varSet.has(v));
      if (missing.length || extra.length)
        errs.push({ code: 'variant_coverage', message: `preview option values must cover variant ids exactly; missing options for: [${missing.join(', ')}], options without variants: [${extra.join(', ')}]`, question_key: key });
    }
    const seenDials = new Set<string>();
    for (const d of dials) for (const e of validateDial(d, seenDials)) errs.push({ ...e, question_key: key });
  }
  return errs;
}

// Deterministic provisional score for a fresh answer. Always provisional:
// the driver must judge it before any turn can commit (end_turn gate).
// Preview scores exactly like single: the chosen variant id vs the predicted
// variant id. Dial values are data and never scored.
export function provisionalScore(q: QuestionPayload, a: AnswerPayload): ScorePayload {
  const base = { question_key: q.key, provisional: true, source: 'deterministic' as const };
  if (a.skipped) return { ...base, result: 'provisional', reason: 'skip_prediction_stands' };
  const pred = q.prediction;
  if (pred === undefined || pred === null) return { ...base, result: 'provisional', reason: 'no_prediction' };
  if (q.type === 'multi') {
    const got = new Set(a.choices || []);
    // Other chosen in a multi-select is a miss, same as single (model rule).
    if (got.has('other')) return { ...base, result: 'miss', reason: 'other_chosen' };
    const want = new Set(pred as string[]);
    const eq = got.size === want.size && [...want].every((v) => got.has(v));
    return { ...base, result: eq ? 'hit' : 'miss', reason: eq ? 'choice_match' : 'choice_mismatch' };
  }
  if (a.choice === 'other') return { ...base, result: 'miss', reason: 'other_chosen' };
  const hit = a.choice === pred;
  return { ...base, result: hit ? 'hit' : 'miss', reason: hit ? 'choice_match' : 'choice_mismatch' };
}

// Driver judgement -> final score entry. skip = prediction stands (result
// stays "provisional" in value but is FINAL: provisional=false — it is not a
// hit and never counts toward sharpness hits). strike removes the axis.
export function judgementScore(judgement: string, reason: string | undefined, answer: AnswerPayload | undefined): ScorePayload | GateError {
  const key = answer?.question_key || '';
  switch (judgement) {
    case 'hit': return { question_key: key, result: 'hit', provisional: false, reason: reason || 'driver_judgement', source: 'driver' };
    case 'miss': return { question_key: key, result: 'miss', provisional: false, reason: reason || 'driver_judgement', source: 'driver' };
    case 'skip':
      if (!answer?.skipped) return { code: 'bad_judgement', message: 'skip judgement requires a skipped answer', question_key: key };
      return { question_key: key, result: 'provisional', provisional: false, reason: 'skip_prediction_stands', source: 'driver' };
    case 'strike': return { question_key: key, result: 'struck', provisional: false, reason: reason || 'axis_struck', source: 'driver' };
    default: return { code: 'bad_judgement', message: `judgement must be hit|miss|skip|strike, got: ${judgement}`, question_key: key };
  }
}

export interface EntryLike { id: number; kind: string; payload: any; body?: string; createdAt?: string }
export interface QuestionState {
  key: string; question: QuestionPayload; askedId: number;
  answer?: AnswerPayload; answerId?: number;
  score?: ScorePayload; scoreId?: number;
  state: 'open' | 'answered' | 'skipped' | 'struck';
}

// Derive per-question state from the append-only record (latest answer and
// latest score per key win; entries are never edited).
export function deriveQuestions(entries: EntryLike[]): QuestionState[] {
  const byKey = new Map<string, QuestionState>();
  const order: QuestionState[] = [];
  for (const e of entries) {
    if (e.kind === 'question' && e.payload?.key) {
      if (!byKey.has(e.payload.key)) { const qs: QuestionState = { key: e.payload.key, question: e.payload, askedId: e.id, state: 'open' }; byKey.set(e.payload.key, qs); order.push(qs); }
    } else if (e.kind === 'answer' && e.payload?.question_key) {
      const qs = byKey.get(e.payload.question_key); if (qs) { qs.answer = e.payload; qs.answerId = e.id; }
    } else if (e.kind === 'score' && e.payload?.question_key) {
      const qs = byKey.get(e.payload.question_key); if (qs) { qs.score = e.payload; qs.scoreId = e.id; }
    }
  }
  for (const qs of order) {
    if (qs.score?.result === 'struck') qs.state = 'struck';
    else if (qs.answer?.skipped) qs.state = 'skipped';
    else if (qs.answer) qs.state = 'answered';
    else qs.state = 'open';
  }
  return order;
}

export interface Sharpness { sharp: boolean; answered_load_bearing: number; recent_scores: ScorePayload[]; errors: GateError[] }

// Deterministic sharpness gate: >=3 answered load-bearing, the 3 most recent
// load-bearing scores all FINAL hits, no load-bearing question open or skipped.
export function sharpnessGate(questions: QuestionState[]): Sharpness {
  const errors: GateError[] = [];
  const lb = questions.filter((q) => q.question.load_bearing);
  const answered = lb.filter((q) => q.state === 'answered');
  if (answered.length < 3) errors.push({ code: 'sharp_min_answered', message: `sharpness needs >=3 answered load-bearing questions, got ${answered.length}` });
  const openOrSkipped = lb.filter((q) => q.state === 'open' || q.state === 'skipped');
  if (openOrSkipped.length) errors.push({ code: 'sharp_open_or_skipped', message: `load-bearing questions open or skipped: ${openOrSkipped.map((q) => q.key).join(', ')}` });
  const scored = answered.filter((q) => q.score).sort((a, b) => (a.scoreId || 0) - (b.scoreId || 0));
  const recent = scored.slice(-3).map((q) => q.score as ScorePayload);
  if (recent.length < 3 || recent.some((s) => !(s.result === 'hit' && s.provisional === false)))
    errors.push({ code: 'sharp_recent_hits', message: 'the 3 most recent load-bearing scores must all be final (non-provisional) hits' });
  return { sharp: errors.length === 0, answered_load_bearing: answered.length, recent_scores: recent, errors };
}

// --- v4 design surface: artifacts -----------------------------------------
// An artifact is a full standalone HTML page (not a snippet): the driver
// generates it (kind 'generated') or captures an existing page as a static
// visual record (kind 'snapshot'). Every write is a new version of a
// versioned file; the artifact ENTRY in the record carries {path, version,
// title, kind}. Artifacts are script-free — enforced here at the gate,
// exactly like snippets, because layout mode renders them same-origin so
// the Agentation toolbar can pick elements inside the frame (a scripted
// page could fight the host chrome; a design surface never needs scripts
// to be annotated). Snapshots may reference their captured external assets
// (images/CSS) — a captured page without them is not a snapshot of
// anything — but scripts and inline handlers are still rejected: the
// driver strips them at capture time.
export type ArtifactKind = 'generated' | 'snapshot';
export interface ArtifactPayload { path: string; version: number; title?: string; kind?: ArtifactKind }
export interface ArtifactState { path: string; title: string; kind: ArtifactKind; version: number; versions: number; lastEntryId: number }

// Artifacts are full pages, so the cap is far above the 20,000-char snippet
// cap — but still a cap: the record is not a file host.
export const MAX_ARTIFACT_CHARS = 200000;

export function artifactSafetyViolation(html: string, kind: ArtifactKind): string | null {
  if (/<script\b/i.test(html)) return 'contains a <script> tag (artifacts are script-free)';
  if (/\son\w+\s*=/i.test(html)) return 'contains an inline event-handler attribute (on*=)';
  if (/(javascript|vbscript)\s*:/i.test(html)) return 'contains a javascript:/vbscript: URI';
  if (/<(iframe|object|embed|base)\b/i.test(html)) return 'contains a forbidden embedding tag (iframe/object/embed/base)';
  if (kind === 'snapshot') return null; // external assets allowed; scripts/handlers already rejected above
  // kind 'generated': fully self-contained — nothing external may load.
  if (/<(link|form)\b/i.test(html)) return 'contains a <link> or <form> tag (generated artifacts are self-contained)';
  if (/\bsrcset\s*=/i.test(html)) return 'contains a srcset attribute (external resources are not allowed)';
  if (/\bsrc\s*=/i.test(html)) return 'contains a src attribute (external resources are not allowed; use inline SVG or CSS instead)';
  const hrefRe = /\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi;
  let m: RegExpExecArray | null;
  while ((m = hrefRe.exec(html)) !== null) {
    const v = (m[1] ?? m[2] ?? m[3] ?? '').trim();
    if (!v.startsWith('#')) return `contains an href that is not an in-page fragment: "${v.slice(0, 60)}"`;
  }
  if (/\bposter\s*=/i.test(html)) return 'contains a poster attribute (external resources are not allowed)';
  if (/\bbackground\s*=/i.test(html)) return 'contains a background attribute (external resources are not allowed)';
  const urlRe = /url\(\s*([^)]*)\)/gi;
  let u: RegExpExecArray | null;
  while ((u = urlRe.exec(html)) !== null) {
    const target = u[1].trim().replace(/^["']|["']$/g, '').trim();
    if (target.startsWith('#') || /^data:image\//i.test(target)) continue;
    return `contains a CSS url() that is not an embedded image or fragment: "${target.slice(0, 60)}"`;
  }
  if (/@import/i.test(html)) return 'contains a CSS @import (external resources are not allowed)';
  return null;
}

// Derive per-artifact state from the record: latest artifact entry per path
// wins for title/kind/version; versions counts the artifact entries.
// v4 F2 annotations: an annotation entry (human, from the Agentation
// toolbar via the mirror/webhook) plus driver annotation_reply /
// annotation_resolve entries derive one state per annotation. The record
// stays append-only; resolution is a later entry, never a mutation.
export type AnnotationState = {
  entry_id: number; agentation_id: string | null; artifact_path: string; artifact_version: number;
  element_path: string; element_id: string | null; element_text: string; comment: string;
  status: 'open' | 'resolved';
  replies: { entry_id: number; body: string; at: string }[];
  resolution: { entry_id: number; summary: string; at: string } | null;
  created_at: string;
};
export function deriveAnnotations(entries: EntryLike[]): AnnotationState[] {
  const byId = new Map<number, AnnotationState>();
  const order: AnnotationState[] = [];
  for (const e of entries) {
    const p = (e.payload ?? {}) as any;
    if (e.kind === 'annotation') {
      const a: AnnotationState = {
        entry_id: e.id, agentation_id: typeof p.agentation_id === 'string' ? p.agentation_id : null,
        artifact_path: String(p.artifact_path ?? ''), artifact_version: Number(p.artifact_version ?? 0),
        element_path: String(p.element_path ?? ''), element_id: typeof p.element_id === 'string' ? p.element_id : null,
        element_text: String(p.element_text ?? ''), comment: e.body ?? '',
        status: 'open', replies: [], resolution: null, created_at: e.createdAt ?? '',
      };
      byId.set(e.id, a); order.push(a);
    } else if (e.kind === 'annotation_reply') {
      const a = byId.get(Number(p.annotation_entry_id)); if (a) a.replies.push({ entry_id: e.id, body: e.body ?? '', at: e.createdAt ?? '' });
    } else if (e.kind === 'annotation_resolve') {
      const a = byId.get(Number(p.annotation_entry_id));
      if (a && !a.resolution) { a.status = 'resolved'; a.resolution = { entry_id: e.id, summary: String(p.summary ?? ''), at: e.createdAt ?? '' }; }
    }
  }
  return order;
}

export function deriveArtifacts(entries: EntryLike[]): ArtifactState[] {
  const byPath = new Map<string, ArtifactState>();
  const order: ArtifactState[] = [];
  for (const e of entries) {
    if (e.kind !== 'artifact' || !e.payload?.path) continue;
    const p = e.payload as ArtifactPayload;
    let a = byPath.get(p.path);
    if (!a) { a = { path: p.path, title: p.title || p.path, kind: p.kind || 'generated', version: p.version || 1, versions: 0, lastEntryId: e.id }; byPath.set(p.path, a); order.push(a); }
    a.versions += 1;
    a.version = p.version || a.version;
    if (p.title) a.title = p.title;
    if (p.kind) a.kind = p.kind;
    a.lastEntryId = e.id;
  }
  return order;
}

// Stable element ids for artifacts: ids are id="..." attributes in HTML.
export function extractElementIds(content: string): string[] {
  const ids: string[] = []; const re = /\bid="([^"]+)"/g; let m: RegExpExecArray | null;
  while ((m = re.exec(content)) !== null) ids.push(m[1]);
  return ids;
}
export function validateArtifactIds(path: string, content: string, previousIds: string[] | null): GateError[] {
  const errs: GateError[] = [];
  if (!content.includes('<')) return errs; // non-HTML artifact: no element ids to enforce
  const ids = extractElementIds(content);
  if (new Set(ids).size !== ids.length) errs.push({ code: 'duplicate_element_id', message: `artifact ${path} has duplicate element ids` });
  if (previousIds && previousIds.length) {
    const have = new Set(ids); const lost = previousIds.filter((id) => !have.has(id));
    if (lost.length) errs.push({ code: 'element_ids_lost', message: `artifact ${path} rewrite drops stable element ids: ${lost.join(', ')}` });
  }
  return errs;
}
