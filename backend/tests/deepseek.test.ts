import test from "node:test";
import assert from "node:assert/strict";
import { backoff, DeepSeekClient } from "../src/deepseek.js";

test("backoff is bounded and jittered", () => { assert.equal(backoff(0, () => 0), 375); assert.equal(backoff(10, () => 1), 10000); });
test("missing key is typed configuration error", async () => {
  const old = process.env.DEEPSEEK_API_KEY; delete process.env.DEEPSEEK_API_KEY;
  try { await assert.rejects(() => new DeepSeekClient().completeText("x", "m", "user_12345"), (e: unknown) => (e as { code?: string }).code === "deepseek_not_configured"); }
  finally { if (old) process.env.DEEPSEEK_API_KEY = old; }
});
test("retries 429 before returning success", async () => {
  let calls = 0; const requestIds: string[] = []; const bodies: Array<Record<string, unknown>> = []; const fake = async (_: unknown, init?: RequestInit) => { calls++; requestIds.push(new Headers(init?.headers).get("x-request-id") ?? ""); bodies.push(JSON.parse(String(init?.body)) as Record<string, unknown>); return calls === 1 ? new Response("busy", { status: 429 }) : Response.json({ choices: [{ message: { content: "ok" } }] }); };
  const result = await new DeepSeekClient({ apiKey: "test-placeholder", fetchImpl: fake as typeof fetch }).completeText("x", "m", "user_12345");
  assert.equal(result, "ok"); assert.equal(calls, 2); assert.ok(requestIds[0]); assert.equal(requestIds[0], requestIds[1]); assert.equal(bodies[0]?.user_id, "user_12345"); assert.equal(bodies[0]?.user, undefined);
});

test("task parser disables thinking for forced strict tool choice", async () => {
  let captured: Record<string, unknown> | undefined;
  const fake = async (url: string | URL | Request, init?: RequestInit) => {
    captured = JSON.parse(String(init?.body)) as Record<string, unknown>;
    assert.match(String(url), /\/beta\/chat\/completions$/);
    return Response.json({ choices: [{ message: { tool_calls: [{ function: { arguments: JSON.stringify({ title: "x", kind: "one_off", schedule: { type: "once", expression: "2099-01-01T00:00:00Z", timezone: "UTC" }, prompt: "x", tools: ["none"], notify: false }) } }] } }] });
  };
  await new DeepSeekClient({ apiKey: "test-placeholder", fetchImpl: fake as typeof fetch }).parseTask("tomorrow", "user_12345");
  assert.deepEqual(captured?.thinking, { type: "disabled" });
  assert.equal(captured?.reasoning_effort, "none");
});
