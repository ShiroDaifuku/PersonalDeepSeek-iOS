import { createHash } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { DocumentRecord } from "./documents.js";

export interface KnowledgeChunk { id: string; knowledgeBaseId: string; documentId: string; documentName: string; index: number; text: string; embedding: number[] }
interface KnowledgeData { users: Record<string, KnowledgeChunk[]> }

export function chunkText(text: string, size = 800, overlap = 120): string[] {
  const normalized = text.replace(/\r\n/g, "\n").trim(); if (!normalized) return [];
  const chunks: string[] = []; let start = 0;
  while (start < normalized.length) { let end = Math.min(start + size, normalized.length); if (end < normalized.length) { const boundary = normalized.lastIndexOf("\n", end); if (boundary > start + size / 2) end = boundary; } chunks.push(normalized.slice(start, end).trim()); if (end === normalized.length) break; start = Math.max(start + 1, end - overlap); }
  return chunks.filter(Boolean);
}

export function deterministicEmbedding(text: string, dimensions = 128): number[] {
  const normalized = text.toLocaleLowerCase();
  const tokens: string[] = [...(normalized.match(/[a-z0-9_]+/g) ?? [])];
  for (const sequence of normalized.match(/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]+/gu) ?? []) {
    const characters = [...sequence]; tokens.push(...characters);
    for (let index = 0; index + 1 < characters.length; index++) tokens.push(characters[index]! + characters[index + 1]!);
  }
  const vector = Array<number>(dimensions).fill(0);
  for (const token of tokens) { const digest = createHash("sha256").update(token).digest(); for (let i = 0; i < 8; i++) { const index = digest.readUInt16BE(i * 2) % dimensions; vector[index]! += digest[i + 16]! % 2 ? 1 : -1; } }
  const norm = Math.hypot(...vector) || 1; return vector.map(v => v / norm);
}
export interface EmbeddingProvider { embed(text: string): Promise<number[]> }
export class DeterministicEmbeddingProvider implements EmbeddingProvider { constructor(private dimensions = 128) {} async embed(text: string) { return deterministicEmbedding(text, this.dimensions); } }
const cosine = (a: number[], b: number[]) => a.reduce((sum, value, i) => sum + value * (b[i] ?? 0), 0);

export class KnowledgeStore {
  private queue: Promise<unknown> = Promise.resolve();
  constructor(private file = process.env.KNOWLEDGE_FILE ?? join(process.cwd(), "data", "knowledge.json"), private embeddings: EmbeddingProvider = new DeterministicEmbeddingProvider()) {}
  private key(userId: string) { return createHash("sha256").update(userId).digest("hex"); }
  private async read(): Promise<KnowledgeData> { try { return JSON.parse(await readFile(this.file, "utf8")) as KnowledgeData; } catch (e) { if ((e as NodeJS.ErrnoException).code === "ENOENT") return { users: {} }; throw e; } }
  private async mutate(fn: (data: KnowledgeData) => void) { const job = this.queue.then(async () => { const data = await this.read(); fn(data); await mkdir(dirname(this.file), { recursive: true }); const tmp = `${this.file}.${process.pid}.tmp`; await writeFile(tmp, JSON.stringify(data)); await rename(tmp, this.file); }); this.queue = job.catch(() => undefined); await job; }
  async index(userId: string, document: DocumentRecord, knowledgeBaseId = "default"): Promise<number> {
    const texts = chunkText(document.text); const vectors = await Promise.all(texts.map(text => this.embeddings.embed(text))); const chunks = texts.map((text, index): KnowledgeChunk => ({ id: `${document.id}:${index}`, knowledgeBaseId, documentId: document.id, documentName: document.name, index, text, embedding: vectors[index]! }));
    await this.mutate(data => { const key = this.key(userId); data.users[key] = [...(data.users[key] ?? []).filter(c => c.documentId !== document.id), ...chunks]; }); return chunks.length;
  }
  async remove(userId: string, documentId: string) { await this.mutate(data => { const key = this.key(userId); data.users[key] = (data.users[key] ?? []).filter(c => c.documentId !== documentId); }); }
  async search(userId: string, query: string, limit = 5, knowledgeBaseId?: string) { const target = await this.embeddings.embed(query); const minimum = Number(process.env.KNOWLEDGE_MIN_SCORE ?? 0.05); return ((await this.read()).users[this.key(userId)] ?? []).filter(c => !knowledgeBaseId || c.knowledgeBaseId === knowledgeBaseId).map(chunk => ({ ...chunk, score: cosine(target, chunk.embedding) })).filter(chunk => chunk.score >= minimum).sort((a, b) => b.score - a.score).slice(0, Math.min(Math.max(limit, 1), 20)).map(({ embedding: _embedding, ...result }) => result); }
}
