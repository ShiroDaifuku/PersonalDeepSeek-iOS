import test from "node:test";
import assert from "node:assert/strict";
import type { AddressInfo } from "node:net";
import { createApp, insertKnowledgeContext } from "../src/server.js";
import { MemoryTaskRepository } from "../src/repository.js";
import { DeepSeekClient } from "../src/deepseek.js";

test("health stays public while app token protects user routes", async () => {
  const previous = process.env.APP_ACCESS_TOKEN; process.env.APP_ACCESS_TOKEN = "local-test-access-token";
  const app = createApp({ repo: new MemoryTaskRepository(), llm: new DeepSeekClient({ apiKey: "placeholder", fetchImpl: async () => new Response("{}", { status: 500 }) }) });
  await new Promise<void>(resolve => app.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${(app.address() as AddressInfo).port}`;
  try {
    assert.equal((await fetch(`${base}/health`)).status, 200);
    assert.equal((await fetch(`${base}/v1/tasks`, { headers: { "x-user-id": "user_12345" } })).status, 401);
    for (const [path, method] of [
      ["/v1/files", "GET"], ["/v1/documents", "GET"], ["/v1/knowledge-bases", "GET"],
      ["/v1/knowledge/query", "POST"], ["/v1/web/search", "POST"], ["/v1/web/fetch", "POST"],
      ["/v1/devices", "POST"], ["/v1/live-activities/tokens", "POST"], ["/v1/live-activities/test/update", "POST"],
    ] as const) {
      assert.equal((await fetch(`${base}${path}`, { method, headers: { "x-user-id": "user_12345" } })).status, 401, `${method} ${path} must require app access token`);
    }
    const response = await fetch(`${base}/v1/tasks`, { headers: { "x-user-id": "user_12345", authorization: "Bearer local-test-access-token" } });
    assert.equal(response.status, 200); assert.deepEqual(await response.json(), { tasks: [] });
  } finally {
    await new Promise<void>((resolve, reject) => app.close(error => error ? reject(error) : resolve()));
    if (previous === undefined) delete process.env.APP_ACCESS_TOKEN; else process.env.APP_ACCESS_TOKEN = previous;
  }
});

test("knowledge context preserves the stable system and history prefix", () => {
  const messages = [{ role: "system", content: "stable" }, { role: "user", content: "old" }, { role: "assistant", content: "answer" }, { role: "user", content: "new" }];
  const result = insertKnowledgeContext(messages, "reference");
  assert.deepEqual(result.slice(0, 3), messages.slice(0, 3));
  assert.equal(result[3]?.role, "system"); assert.equal(result[4], messages[3]);
});
