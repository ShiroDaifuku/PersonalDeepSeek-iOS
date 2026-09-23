export type DeepSeekEvent =
  | { type: "reasoning"; text: string }
  | { type: "content"; text: string }
  | { type: "usage"; usage: Record<string, number> }
  | { type: "done" };

export class SSEParser {
  private buffer = "";
  private data: string[] = [];
  private decoder = new TextDecoder();

  push(chunk: Uint8Array | string): DeepSeekEvent[] {
    this.buffer += typeof chunk === "string" ? chunk : this.decoder.decode(chunk, { stream: true });
    const out: DeepSeekEvent[] = [];
    for (;;) {
      const match = this.buffer.match(/\r?\n/);
      if (!match || match.index === undefined) break;
      const line = this.buffer.slice(0, match.index);
      this.buffer = this.buffer.slice(match.index + match[0].length);
      this.consumeLine(line, out);
    }
    return out;
  }

  finish(): DeepSeekEvent[] {
    const out: DeepSeekEvent[] = [];
    this.buffer += this.decoder.decode();
    if (this.buffer) this.consumeLine(this.buffer, out);
    this.buffer = "";
    this.flush(out);
    return out;
  }

  private consumeLine(line: string, out: DeepSeekEvent[]): void {
    if (line === "") { this.flush(out); return; }
    if (line.startsWith(":")) return;
    if (line.startsWith("data:")) this.data.push(line.slice(5).trimStart());
  }

  private flush(out: DeepSeekEvent[]): void {
    if (!this.data.length) return;
    const raw = this.data.join("\n");
    this.data = [];
    if (raw === "[DONE]") { out.push({ type: "done" }); return; }
    let value: unknown;
    try { value = JSON.parse(raw); } catch { return; }
    if (!value || typeof value !== "object") return;
    const body = value as { choices?: Array<{ delta?: { reasoning_content?: unknown; content?: unknown } }>; usage?: unknown };
    const delta = body.choices?.[0]?.delta;
    if (typeof delta?.reasoning_content === "string" && delta.reasoning_content) out.push({ type: "reasoning", text: delta.reasoning_content });
    if (typeof delta?.content === "string" && delta.content) out.push({ type: "content", text: delta.content });
    if (body.usage && typeof body.usage === "object") out.push({ type: "usage", usage: body.usage as Record<string, number> });
  }
}
