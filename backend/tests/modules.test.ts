import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { DocumentStore } from "../src/documents.js";
import { KnowledgeStore, chunkText, deterministicEmbedding } from "../src/knowledge.js";
import { assertSafeUrl, isPublicAddress, safeFetchText } from "../src/web-tools.js";
import { PushStore } from "../src/push.js";
import { ApnsSender } from "../src/push.js";
import { FilesApiClient } from "../src/files-api.js";
import { MemoryTaskRepository } from "../src/repository.js";
import { TaskService } from "../src/tasks.js";
import type { DeepSeekClient } from "../src/deepseek.js";

test("documents use opaque ids and reject traversal and binary content", async () => {
  const root = await mkdtemp(join(tmpdir(), "daifuku-docs-")); const store = new DocumentStore(root);
  try {
    const doc = await store.create("user_12345", { name: "../notes.md", mediaType: "text/markdown", text: "# hello" });
    assert.equal(doc.name, "notes.md"); assert.equal((await store.list("user_12345"))[0]?.id, doc.id);
    await assert.rejects(store.get("user_12345", "../../secret"), /not found/i);
    await assert.rejects(store.create("user_12345", { name: "x.txt", mediaType: "text/plain", contentBase64: Buffer.from([0]).toString("base64") }), /Binary/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("knowledge embeddings and retrieval are deterministic and user isolated", async () => {
  assert.deepEqual(deterministicEmbedding("same text"), deterministicEmbedding("same text")); assert.ok(chunkText("a".repeat(2000)).length > 1);
  const root = await mkdtemp(join(tmpdir(), "daifuku-kb-")); const store = new KnowledgeStore(join(root, "knowledge.json"));
  try { await store.index("user_12345", { id: "doc", userId: "user_12345", name: "fruit.txt", mediaType: "text/plain", size: 12, createdAt: new Date().toISOString(), text: "apple banana fruit" }, "kb"); assert.equal((await store.search("user_12345", "apple", 5, "kb"))[0]?.documentId, "doc"); assert.deepEqual(await store.search("user_99999", "apple"), []); }
  finally { await rm(root, { recursive: true, force: true }); }
});

test("local knowledge retrieval supports basic Chinese overlap and filters unrelated text", async () => {
  const root = await mkdtemp(join(tmpdir(), "daifuku-kb-zh-")); const store = new KnowledgeStore(join(root, "knowledge.json"));
  try {
    await store.index("user_12345", { id: "zh", userId: "user_12345", name: "水果.txt", mediaType: "text/plain", size: 18, createdAt: new Date().toISOString(), text: "苹果香蕉属于水果" }, "kb");
    assert.equal((await store.search("user_12345", "苹果", 5, "kb"))[0]?.documentId, "zh");
    assert.deepEqual(await store.search("user_12345", "量子火箭", 5, "kb"), []);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("documents reject invalid UTF-8", async () => {
  const root = await mkdtemp(join(tmpdir(), "daifuku-docs-utf8-")); const store = new DocumentStore(root);
  try { await assert.rejects(store.create("user_12345", { name: "bad.txt", mediaType: "text/plain", contentBase64: Buffer.from([0xc3, 0x28]).toString("base64") }), /UTF-8/); }
  finally { await rm(root, { recursive: true, force: true }); }
});

test("SSRF guard rejects local ranges and validates redirect destinations", async () => {
  assert.equal(isPublicAddress("127.0.0.1"), false); assert.equal(isPublicAddress("10.0.0.1"), false); assert.equal(isPublicAddress("8.8.8.8"), true);
  await assert.rejects(assertSafeUrl("http://127.0.0.1/admin"), /Private network/);
  const fake = async () => new Response(null, { status: 302, headers: { location: "http://127.0.0.1/secret" } });
  await assert.rejects(safeFetchText("https://example.com", fake as typeof fetch), /Private network/);
});

test("push token registration is idempotent", async () => {
  const root = await mkdtemp(join(tmpdir(), "daifuku-push-")); const store = new PushStore(join(root, "push.json"));
  try { const token = "ab".repeat(32); await store.register("user_12345", { token, environment: "sandbox", platform: "ios" }); await store.register("user_12345", { token, environment: "sandbox" }); assert.equal((await store.list("user_12345")).length, 1); }
  finally { await rm(root, { recursive: true, force: true }); }
});

test("push registration rejects an unknown APNs environment", async () => {
  const root = await mkdtemp(join(tmpdir(), "daifuku-push-env-")); const store = new PushStore(join(root, "push.json"));
  try { await assert.rejects(store.register("user_12345", { token: "ab".repeat(32), environment: "staging" }), /sandbox or production/); }
  finally { await rm(root, { recursive: true, force: true }); }
});

test("push token unregister is user scoped", async () => {
  const root = await mkdtemp(join(tmpdir(), "daifuku-push-remove-")); const store = new PushStore(join(root, "push.json")); const token = "cd".repeat(32);
  try { await store.register("user_12345", { token }); await store.register("user_99999", { token }); assert.equal(await store.unregister("user_12345", { token }, "device"), true); assert.equal((await store.list("user_12345")).length, 0); assert.equal((await store.list("user_99999")).length, 1); }
  finally { await rm(root, { recursive: true, force: true }); }
});

test("image upload enforces MIME, canonical base64 and expiration", async () => {
  const previous = process.env.DEEPSEEK_API_KEY; process.env.DEEPSEEK_API_KEY = "test"; let form: FormData | undefined;
  const client = new FilesApiClient(async (_url, init) => { form = init?.body as FormData; return Response.json({ id: "file_1" }); });
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).toString("base64");
  try {
    await assert.rejects(client.upload({ name: "x.svg", mediaType: "image/svg+xml", contentBase64: "eA==" }), /JPEG/);
    await assert.rejects(client.upload({ name: "x.png", mediaType: "image/png", contentBase64: "%%%" }), /base64/i);
    await assert.rejects(client.upload({ name: "x.png", mediaType: "image/png", contentBase64: png, expiresAfterSeconds: 30 }), /3600/);
    await client.upload({ name: "x.png", mediaType: "image/png", contentBase64: png, expiresAfterSeconds: 3600 }); assert.equal(form?.get("purpose"), "user_data"); assert.equal(form?.get("expires_after[anchor]"), "created_at"); assert.equal(form?.get("expires_after[seconds]"), "3600");
  } finally { if (previous === undefined) delete process.env.DEEPSEEK_API_KEY; else process.env.DEEPSEEK_API_KEY = previous; }
});

test("task notification records not_configured instead of failing the run", async () => {
  const root = await mkdtemp(join(tmpdir(), "daifuku-apns-")); const push = new PushStore(join(root, "push.json")); await push.register("user_12345", { token: "ab".repeat(32) });
  const repo = new MemoryTaskRepository(); const service = new TaskService(repo, { completeText: async () => "done" } as unknown as DeepSeekClient, { dailyRuns: 5, unreadPause: 5, monthlyBudgetMicros: 9999, fallbackModel: "x", defaultModel: "x" }, undefined, new ApnsSender(push));
  try { const task = await service.create("user_12345", { title: "test", kind: "one_off", schedule: { type: "once", expression: new Date(Date.now() + 60_000).toISOString(), timezone: "UTC" }, prompt: "hello", tools: ["none"], notify: true }); task.nextRunAt = new Date(0).toISOString(); await repo.saveTask(task); const [run] = await service.runDue(); assert.equal(run?.status, "succeeded"); assert.equal(run?.notificationStatus, "not_configured"); }
  finally { await rm(root, { recursive: true, force: true }); }
});
