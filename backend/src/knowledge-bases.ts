import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { AppError } from "./types.js";

export interface KnowledgeBase { id: string; userId: string; name: string; enabled: boolean; createdAt: string; updatedAt: string; documentIds: string[] }
interface Data { users: Record<string, KnowledgeBase[]> }
export class KnowledgeBaseStore {
  private queue: Promise<unknown> = Promise.resolve();
  constructor(private file = process.env.KNOWLEDGE_BASES_FILE ?? join(process.cwd(), "data", "knowledge-bases.json")) {}
  private key(userId: string) { return createHash("sha256").update(userId).digest("hex"); }
  private async read(): Promise<Data> { try { return JSON.parse(await readFile(this.file, "utf8")) as Data; } catch (e) { if ((e as NodeJS.ErrnoException).code === "ENOENT") return { users: {} }; throw e; } }
  private async mutate<T>(fn: (data: Data) => T): Promise<T> { let result!: T; const job = this.queue.then(async () => { const data = await this.read(); result = fn(data); await mkdir(dirname(this.file), { recursive: true }); const tmp = `${this.file}.${process.pid}.tmp`; await writeFile(tmp, JSON.stringify(data)); await rename(tmp, this.file); }); this.queue = job.catch(() => undefined); await job; return result; }
  async list(userId: string) { return (await this.read()).users[this.key(userId)] ?? []; }
  async get(userId: string, id: string) { const kb = (await this.list(userId)).find(x => x.id === id); if (!kb) throw new AppError("not_found", "Knowledge base not found", 404); return kb; }
  async create(userId: string, name: string) { if (!name.trim() || name.length > 120) throw new AppError("invalid_knowledge_base", "Invalid knowledge base name"); const now = new Date().toISOString(); return this.mutate(data => { const key = this.key(userId); const kb: KnowledgeBase = { id: randomUUID(), userId, name: name.trim(), enabled: true, createdAt: now, updatedAt: now, documentIds: [] }; (data.users[key] ??= []).push(kb); return kb; }); }
  async patch(userId: string, id: string, patch: { name?: string; enabled?: boolean }) { if (patch.name !== undefined && (!patch.name.trim() || patch.name.length > 120)) throw new AppError("invalid_knowledge_base", "Invalid knowledge base name"); return this.mutate(data => { const kb = (data.users[this.key(userId)] ?? []).find(x => x.id === id); if (!kb) throw new AppError("not_found", "Knowledge base not found", 404); if (patch.name !== undefined) kb.name = patch.name.trim(); if (patch.enabled !== undefined) kb.enabled = patch.enabled; kb.updatedAt = new Date().toISOString(); return kb; }); }
  async attach(userId: string, id: string, documentId: string) { return this.mutate(data => { const kb = (data.users[this.key(userId)] ?? []).find(x => x.id === id); if (!kb) throw new AppError("not_found", "Knowledge base not found", 404); if (!kb.documentIds.includes(documentId)) kb.documentIds.push(documentId); kb.updatedAt = new Date().toISOString(); return kb; }); }
  async detachDocument(userId: string, documentId: string) { await this.mutate(data => { for (const kb of data.users[this.key(userId)] ?? []) { const before = kb.documentIds.length; kb.documentIds = kb.documentIds.filter(id => id !== documentId); if (kb.documentIds.length !== before) kb.updatedAt = new Date().toISOString(); } }); }
}
