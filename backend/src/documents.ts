import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { basename, extname, join, resolve, sep } from "node:path";
import { AppError } from "./types.js";
import { TextDecoder } from "node:util";

export interface DocumentRecord { id: string; userId: string; name: string; mediaType: string; size: number; createdAt: string; text: string }

const allowedTypes = new Set(["text/plain", "text/markdown", "text/csv", "application/json", "application/xml", "text/xml"]);
const idPattern = /^[0-9a-f-]{36}$/i;

export class DocumentStore {
  constructor(private root = process.env.DOCUMENTS_DIR ?? join(process.cwd(), "data", "documents"), private maxBytes = Number(process.env.MAX_DOCUMENT_BYTES ?? 5_000_000)) {}
  private userKey(userId: string) { return createHash("sha256").update(userId).digest("hex"); }
  private dir(userId: string) { return join(this.root, this.userKey(userId)); }
  private path(userId: string, id: string) {
    if (!idPattern.test(id)) throw new AppError("not_found", "Document not found", 404);
    const root = resolve(this.dir(userId)); const result = resolve(root, `${id}.json`);
    if (!result.startsWith(`${root}${sep}`)) throw new AppError("invalid_path", "Invalid document path");
    return result;
  }
  async create(userId: string, input: unknown): Promise<DocumentRecord> {
    if (!input || typeof input !== "object" || Array.isArray(input)) throw new AppError("invalid_document", "Document body is required");
    const body = input as Record<string, unknown>;
    const name = typeof body.name === "string" ? basename(body.name).trim() : "";
    const mediaType = typeof body.mediaType === "string" ? body.mediaType.toLowerCase().split(";")[0]! : "";
    if (!name || name.length > 255 || name === "." || name === "..") throw new AppError("invalid_document", "A safe document name is required");
    if (!allowedTypes.has(mediaType)) throw new AppError("unsupported_media_type", "Only plain text, Markdown, CSV, JSON and XML are supported", 415);
    let bytes: Buffer;
    if (typeof body.contentBase64 === "string") { const encoded = body.contentBase64.replace(/\s/g, ""); if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) throw new AppError("invalid_document", "Invalid base64 content"); bytes = Buffer.from(encoded, "base64"); if (bytes.toString("base64") !== encoded) throw new AppError("invalid_document", "Invalid base64 content"); }
    else if (typeof body.text === "string") bytes = Buffer.from(body.text, "utf8");
    else throw new AppError("invalid_document", "text or contentBase64 is required");
    if (bytes.length > this.maxBytes) throw new AppError("document_too_large", "Document is too large", 413);
    if (bytes.includes(0)) throw new AppError("unsupported_document", "Binary documents are not supported", 415);
    let text: string; try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes).replace(/^\uFEFF/, ""); } catch { throw new AppError("unsupported_document", "Document must contain valid UTF-8 text", 415); }
    const record: DocumentRecord = { id: randomUUID(), userId, name, mediaType, size: bytes.length, createdAt: new Date().toISOString(), text };
    await mkdir(this.dir(userId), { recursive: true }); await writeFile(this.path(userId, record.id), JSON.stringify(record));
    return record;
  }
  async list(userId: string): Promise<Array<Omit<DocumentRecord, "text" | "userId">>> {
    let names: string[]; try { names = await readdir(this.dir(userId)); } catch (e) { if ((e as NodeJS.ErrnoException).code === "ENOENT") return []; throw e; }
    const records = await Promise.all(names.filter(n => extname(n) === ".json").map(async n => JSON.parse(await readFile(join(this.dir(userId), n), "utf8")) as DocumentRecord));
    return records.map(({ userId: _user, text: _text, ...metadata }) => metadata).sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }
  async get(userId: string, id: string): Promise<DocumentRecord> { try { return JSON.parse(await readFile(this.path(userId, id), "utf8")) as DocumentRecord; } catch (e) { if ((e as NodeJS.ErrnoException).code === "ENOENT") throw new AppError("not_found", "Document not found", 404); throw e; } }
  async delete(userId: string, id: string): Promise<void> { try { await rm(this.path(userId, id)); } catch (e) { if ((e as NodeJS.ErrnoException).code === "ENOENT") throw new AppError("not_found", "Document not found", 404); throw e; } }
}
