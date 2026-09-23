import { AppError, type TaskDraft } from "./types.js";

export interface DeepSeekOptions { apiKey?: string; baseUrl?: string; maxAttempts?: number; fetchImpl?: typeof fetch }

export class DeepSeekClient {
  private fetcher: typeof fetch;
  constructor(private options: DeepSeekOptions = {}) { this.fetcher = options.fetchImpl ?? fetch; }
  private key(): string { const key = this.options.apiKey ?? process.env.DEEPSEEK_API_KEY; if (!key) throw new AppError("deepseek_not_configured", "DEEPSEEK_API_KEY is not configured", 503); return key; }
  async request(body: unknown, userId: string, signal?: AbortSignal, baseUrl?: string): Promise<Response> {
    const attempts = this.options.maxAttempts ?? 3; const key = this.key(); const requestId = crypto.randomUUID();
    const timeout = AbortSignal.timeout(600_000);
    const requestSignal = signal ? AbortSignal.any([signal, timeout]) : timeout;
    for (let attempt = 0; ; attempt++) {
      let response: Response;
      try { const root = (baseUrl ?? this.options.baseUrl ?? process.env.DEEPSEEK_BASE_URL ?? "https://api.deepseek.com").replace(/\/+$/, ""); response = await this.fetcher(`${root}/chat/completions`, { method: "POST", headers: { authorization: `Bearer ${key}`, "content-type": "application/json", "x-request-id": requestId }, body: JSON.stringify({ ...(body as object), user_id: userId }), signal: requestSignal }); }
      catch (e) { if (attempt + 1 >= attempts) throw e; await delay(backoff(attempt)); continue; }
      if (![429, 500, 502, 503, 504].includes(response.status) || attempt + 1 >= attempts) return response;
      await response.body?.cancel(); await delay(backoff(attempt));
    }
  }
  async completeText(prompt: string, model: string, userId: string): Promise<string> {
    const response = await this.request({ model, stream: false, messages: [{ role: "user", content: prompt }] }, userId);
    if (!response.ok) throw new AppError("deepseek_error", `DeepSeek returned ${response.status}`, response.status, response.status === 429 || response.status >= 500);
    const json = await response.json() as { choices?: Array<{ message?: { content?: string } }> };
    return json.choices?.[0]?.message?.content ?? "";
  }
  async parseTask(text: string, userId: string): Promise<TaskDraft> {
    const schema = { type: "object", additionalProperties: false, required: ["title", "kind", "schedule", "prompt", "tools", "notify"], properties: { title: { type: "string" }, kind: { type: "string", enum: ["one_off", "recurring", "monitor"] }, schedule: { type: "object", additionalProperties: false, required: ["type", "expression", "timezone"], properties: { type: { type: "string", enum: ["once", "rrule", "cron"] }, expression: { type: "string" }, timezone: { type: "string" } } }, prompt: { type: "string" }, tools: { type: "array", items: { type: "string", enum: ["none", "web_search", "web_fetch"] } }, notify: { type: "boolean" } } };
    const response = await this.request({ model: process.env.DEEPSEEK_TASK_MODEL ?? "deepseek-flash", stream: false, thinking: { type: "disabled" }, reasoning_effort: "none", messages: [{ role: "system", content: "Convert the user's request to a scheduled task. Return tool arguments only. Use an IANA timezone. Prefer five-field cron for recurring wall-clock schedules and RRULE for interval schedules." }, { role: "user", content: text }], tools: [{ type: "function", function: { name: "create_task_draft", description: "Create a task draft for confirmation", strict: true, parameters: schema } }], tool_choice: { type: "function", function: { name: "create_task_draft" } } }, userId, undefined, process.env.DEEPSEEK_BETA_BASE_URL ?? "https://api.deepseek.com/beta");
    if (!response.ok) throw new AppError("deepseek_error", `DeepSeek returned ${response.status}`, response.status, response.status === 429 || response.status >= 500);
    const json = await response.json() as { choices?: Array<{ message?: { tool_calls?: Array<{ function?: { arguments?: string } }> } }> };
    const args = json.choices?.[0]?.message?.tool_calls?.[0]?.function?.arguments; if (!args) throw new AppError("invalid_model_output", "Model did not return task arguments", 502);
    try { return JSON.parse(args) as TaskDraft; } catch { throw new AppError("invalid_model_output", "Model returned invalid JSON", 502); }
  }
}

export function backoff(attempt: number, random = Math.random): number { return Math.min(8_000, 500 * 2 ** attempt) * (0.75 + random() * 0.5); }
const delay = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
