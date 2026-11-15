import Database from 'better-sqlite3';
import { drizzle } from 'drizzle-orm/better-sqlite3';
import { sqliteTable, text, integer } from 'drizzle-orm/sqlite-core';
import fs from 'node:fs'; import path from 'node:path'; import crypto from 'node:crypto';

export const projects = sqliteTable('projects', { id: text('id').primaryKey(), title: text('title'), want: text('want'), status: text('status').notNull().default('open'), createdAt: text('created_at').notNull(), committedAt: text('committed_at') });
export const entries = sqliteTable('entries', { id: integer('id').primaryKey({ autoIncrement: true }), projectId: text('project_id').notNull(), kind: text('kind').notNull(), role: text('role').notNull(), body: text('body').notNull(), payload: text('payload').notNull().default('{}'), createdAt: text('created_at').notNull() });
export const drafts = sqliteTable('drafts', { projectId: text('project_id').notNull(), questionKey: text('question_key').notNull(), payload: text('payload').notNull().default('{}'), updatedAt: text('updated_at').notNull() });

const dataDir = process.env.DATA_DIR || path.join(process.cwd(), 'data');
fs.mkdirSync(dataDir, { recursive: true });
const dbPath = path.join(dataDir, 'app.db');
const sqlite = new Database(dbPath);
sqlite.pragma('journal_mode = WAL');
sqlite.exec(`CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY,title TEXT,status TEXT NOT NULL DEFAULT 'open',created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS entries(id INTEGER PRIMARY KEY AUTOINCREMENT,project_id TEXT NOT NULL,kind TEXT NOT NULL,role TEXT NOT NULL,body TEXT NOT NULL,created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS staged_turns(id TEXT PRIMARY KEY,project_id TEXT NOT NULL,base_head INTEGER NOT NULL,status TEXT NOT NULL DEFAULT 'open',created_at TEXT NOT NULL,committed_at TEXT);
CREATE TABLE IF NOT EXISTS staged_actions(id INTEGER PRIMARY KEY AUTOINCREMENT,turn_id TEXT NOT NULL,seq INTEGER NOT NULL,tool TEXT NOT NULL,args TEXT NOT NULL,created_at TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS file_versions(id INTEGER PRIMARY KEY AUTOINCREMENT,project_id TEXT NOT NULL,path TEXT NOT NULL,version INTEGER NOT NULL,content TEXT NOT NULL,created_at TEXT NOT NULL,UNIQUE(project_id,path,version));
CREATE TABLE IF NOT EXISTS drafts(project_id TEXT NOT NULL,question_key TEXT NOT NULL,payload TEXT NOT NULL DEFAULT '{}',updated_at TEXT NOT NULL,PRIMARY KEY(project_id,question_key));
CREATE TABLE IF NOT EXISTS presence(id INTEGER PRIMARY KEY CHECK(id=1),label TEXT,source TEXT,last_seen TEXT NOT NULL);`);
// Additive migrations for P1-era databases (append-only tables are never rewritten).
function addColumn(table: string, col: string, ddl: string) {
  const cols = sqlite.prepare(`PRAGMA table_info(${table})`).all() as { name: string }[];
  if (!cols.some((c) => c.name === col)) sqlite.exec(`ALTER TABLE ${table} ADD COLUMN ${ddl}`);
}
addColumn('entries', 'payload', "payload TEXT NOT NULL DEFAULT '{}'");
addColumn('projects', 'want', 'want TEXT');
addColumn('projects', 'committed_at', 'committed_at TEXT');

export const db = drizzle(sqlite, { schema: { projects, entries, drafts } });
export { sqlite };

export function dbRoundTrip() { const r = sqlite.prepare("SELECT COUNT(*) as c FROM entries").get() as { c: number }; return { ok: true, entries: r.c }; }
export function ensureProject() {
  const row = sqlite.prepare("SELECT id FROM projects LIMIT 1").get() as { id: string } | undefined;
  if (row) return row.id;
  const id = 'proj_default';
  sqlite.prepare("INSERT INTO projects(id,title,status,created_at) VALUES(?,?,?,?)").run(id, 'Design Sprite v3 — P1', 'open', new Date().toISOString());
  sqlite.prepare("INSERT INTO entries(project_id,kind,role,body,created_at) VALUES(?,?,?,?,?)").run(id, 'message', 'system', 'Welcome — this is the verbatim record. Human messages are stored immediately, even with no driver attached.', new Date().toISOString());
  return id;
}
export function getProject() {
  const pid = ensureProject();
  const p = sqlite.prepare("SELECT id,title,want,status,created_at as createdAt,committed_at as committedAt FROM projects WHERE id=?").get(pid) as any;
  return p;
}
export function getHead(): number {
  ensureProject();
  const r = sqlite.prepare("SELECT COALESCE(MAX(id),0) as h FROM entries").get() as { h: number };
  return r.h;
}
export function insertEntry(projectId: string, kind: string, role: string, body: string, payload: any = {}) {
  const now = new Date().toISOString();
  const info = sqlite.prepare("INSERT INTO entries(project_id,kind,role,body,payload,created_at) VALUES(?,?,?,?,?,?)").run(projectId, kind, role, body ?? '', JSON.stringify(payload ?? {}), now);
  return { id: Number(info.lastInsertRowid), projectId, kind, role, body: body ?? '', payload: payload ?? {}, createdAt: now };
}
export function listEntries() {
  ensureProject();
  const rows = sqlite.prepare("SELECT id,project_id as projectId,kind,role,body,payload,created_at as createdAt FROM entries ORDER BY id ASC").all() as any[];
  return rows.map((r) => ({ ...r, payload: safeParse(r.payload) }));
}
export function entriesSince(since: number) { return listEntries().filter((e) => e.id > since); }
export function safeParse(s: string) { try { return JSON.parse(s || '{}'); } catch { return {}; } }
export function addEntry(body: string) { const pid = ensureProject(); return insertEntry(pid, 'message', 'human', body, {}); }
export function tokenPath() { return path.join(dataDir, 'admin.token'); }
export function ensureToken() {
  const p = tokenPath();
  if (fs.existsSync(p)) return fs.readFileSync(p, 'utf8').trim();
  const t = crypto.randomBytes(32).toString('hex'); fs.writeFileSync(p, t, { mode: 0o600 }); try { fs.chmodSync(p, 0o600); } catch {} return t;
}
export function checkToken(req: Request) { const h = req.headers.get('authorization') || ''; const exp = ensureToken(); return h === `Bearer ${exp}`; }
export function checkTokenValue(v: string | null | undefined) { if (!v) return false; return v === ensureToken(); }
