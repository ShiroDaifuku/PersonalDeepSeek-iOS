import test from "node:test";
import assert from "node:assert/strict";
import { SSEParser } from "../src/sse.js";

test("parses fragmented CRLF, blank lines, comments, reasoning, content, usage and done", () => {
  const p = new SSEParser(); const events = [];
  events.push(...p.push(": keep-alive\r\n\r\nda"));
  events.push(...p.push("ta: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"}}]}\r\n\r\n"));
  events.push(...p.push("\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"answer\"}}],\"usage\":{\"total_tokens\":7}}\n\n"));
  events.push(...p.push("data: [DO")); events.push(...p.push("NE]\n\n")); events.push(...p.finish());
  assert.deepEqual(events, [
    { type: "reasoning", text: "think" }, { type: "content", text: "answer" },
    { type: "usage", usage: { total_tokens: 7 } }, { type: "done" }
  ]);
});

test("ignores malformed data", () => { const p = new SSEParser(); assert.deepEqual(p.push("data: nope\n\n"), []); });

test("preserves multibyte UTF-8 split across byte chunks", () => {
  const encoded = new TextEncoder().encode('data: {"choices":[{"delta":{"content":"中文"}}]}\n\n');
  const marker = encoded.indexOf(0xe4);
  const p = new SSEParser();
  assert.deepEqual(p.push(encoded.slice(0, marker + 1)), []);
  assert.deepEqual(p.push(encoded.slice(marker + 1)), [{ type: "content", text: "中文" }]);
});
