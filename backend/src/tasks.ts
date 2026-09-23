import { randomUUID } from "node:crypto";
import type { TaskRepository } from "./repository.js";
import { AppError, type ScheduledTask, type TaskDraft, type TaskRun } from "./types.js";
import type { DeepSeekClient } from "./deepseek.js";

const kinds = new Set(["one_off", "recurring", "monitor"]);
const scheduleTypes = new Set(["once", "rrule", "cron"]);
const tools = new Set(["none", "web_search", "web_fetch"]);

export function validTimezone(timezone: string): boolean {
  try { new Intl.DateTimeFormat("en", { timeZone: timezone }); return true; } catch { return false; }
}

export function validateDraft(input: unknown, now = new Date()): TaskDraft {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new AppError("invalid_task", "Task must be an object");
  const x = input as Record<string, unknown>;
  const allowed = new Set(["title", "kind", "schedule", "prompt", "tools", "notify"]);
  if (Object.keys(x).some(k => !allowed.has(k))) throw new AppError("invalid_task", "Unknown task field");
  if (typeof x.title !== "string" || !x.title.trim() || x.title.length > 120) throw new AppError("invalid_task", "Invalid title");
  if (typeof x.kind !== "string" || !kinds.has(x.kind)) throw new AppError("invalid_task", "Invalid task kind");
  if (!x.schedule || typeof x.schedule !== "object" || Array.isArray(x.schedule)) throw new AppError("invalid_task", "Invalid schedule");
  const s = x.schedule as Record<string, unknown>;
  if (Object.keys(s).some(k => !["type", "expression", "timezone"].includes(k))) throw new AppError("invalid_task", "Unknown schedule field");
  if (typeof s.type !== "string" || !scheduleTypes.has(s.type) || typeof s.expression !== "string" || !s.expression || s.expression.length > 500 || typeof s.timezone !== "string" || !validTimezone(s.timezone)) throw new AppError("invalid_task", "Invalid schedule fields");
  if (typeof x.prompt !== "string" || !x.prompt || x.prompt.length > 20_000) throw new AppError("invalid_task", "Invalid prompt");
  if (!Array.isArray(x.tools) || x.tools.length > 3 || new Set(x.tools).size !== x.tools.length || x.tools.some(t => typeof t !== "string" || !tools.has(t))) throw new AppError("invalid_task", "Invalid tools");
  if (typeof x.notify !== "boolean") throw new AppError("invalid_task", "Invalid notify");
  if (x.kind === "one_off" && s.type !== "once") throw new AppError("invalid_task", "One-off tasks require once schedule");
  if (x.kind !== "one_off" && s.type === "once") throw new AppError("invalid_task", "Recurring tasks require cron or rrule");
  if (s.type === "once") { const time = Date.parse(s.expression); if (!Number.isFinite(time) || time <= now.getTime()) throw new AppError("invalid_task", "One-off time must be in the future"); }
  if (s.type === "cron") {
    const cron = parseCron(s.expression);
    if (cronValues(cron[0], 0, 59).length > 1) throw new AppError("interval_too_short", "Recurring interval must be at least one hour");
  }
  if (s.type === "rrule" && minimumRRuleMinutes(s.expression) < 60) throw new AppError("interval_too_short", "Recurring interval must be at least one hour");
  return input as TaskDraft;
}

type CronParts = [string, string, string, string, string];

function parseCron(expression: string): CronParts {
  const fields = expression.trim().split(/\s+/);
  if (fields.length !== 5) throw new AppError("invalid_schedule", "Cron must have five fields");
  const parts = fields as CronParts;
  cronValues(parts[0], 0, 59); cronValues(parts[1], 0, 23); cronValues(parts[2], 1, 31); cronValues(parts[3], 1, 12); cronValues(parts[4], 0, 7, true);
  return parts;
}

function cronValues(expression: string, min: number, max: number, sundayAlias = false): number[] {
  const values = new Set<number>();
  const add = (raw: number) => {
    const value = sundayAlias && raw === 7 ? 0 : raw;
    if (!Number.isInteger(raw) || raw < min || raw > max) throw new AppError("invalid_schedule", `Invalid cron field: ${expression}`);
    values.add(value);
  };
  for (const item of expression.split(",")) {
    const [rangeText, stepText] = item.split("/", 2);
    const step = stepText === undefined ? 1 : Number(stepText);
    if (!Number.isInteger(step) || step < 1) throw new AppError("invalid_schedule", `Invalid cron field: ${expression}`);
    let start: number, end: number;
    if (rangeText === "*") { start = min; end = max; }
    else if (rangeText?.includes("-")) {
      const pair = rangeText.split("-", 2).map(Number); start = pair[0]!; end = pair[1]!;
      if (start > end) throw new AppError("invalid_schedule", `Invalid cron field: ${expression}`);
    } else { start = Number(rangeText); end = start; if (stepText !== undefined) throw new AppError("invalid_schedule", `Invalid cron field: ${expression}`); }
    for (let value = start; value <= end; value += step) add(value);
  }
  if (!values.size) throw new AppError("invalid_schedule", `Invalid cron field: ${expression}`);
  return [...values].sort((a, b) => a - b);
}

function zonedParts(date: Date, timezone: string) {
  const formatter = new Intl.DateTimeFormat("en-US-u-ca-gregory", { timeZone: timezone, year: "numeric", month: "numeric", day: "numeric", hour: "numeric", minute: "numeric", hourCycle: "h23" });
  const fields = Object.fromEntries(formatter.formatToParts(date).filter(p => p.type !== "literal").map(p => [p.type, Number(p.value)]));
  const year = fields.year!, month = fields.month!, day = fields.day!;
  return { minute: fields.minute!, hour: fields.hour!, day, month, weekday: new Date(Date.UTC(year, month - 1, day)).getUTCDay() };
}

function cronMatches(parts: CronParts, date: Date, timezone: string): boolean {
  const local = zonedParts(date, timezone);
  const minute = cronValues(parts[0], 0, 59).includes(local.minute);
  const hour = cronValues(parts[1], 0, 23).includes(local.hour);
  const month = cronValues(parts[3], 1, 12).includes(local.month);
  const dom = cronValues(parts[2], 1, 31).includes(local.day);
  const dow = cronValues(parts[4], 0, 7, true).includes(local.weekday);
  const dayMatches = parts[2] !== "*" && parts[4] !== "*" ? dom || dow : dom && dow;
  return minute && hour && month && dayMatches;
}

function minimumRRuleMinutes(expression: string): number {
  const fields = Object.fromEntries(expression.replace(/^RRULE:/i, "").split(";").map(v => v.split("=", 2)));
  const interval = Number(fields.INTERVAL ?? "1");
  if (!Number.isInteger(interval) || interval < 1) throw new AppError("invalid_schedule", "Invalid RRULE interval");
  if (fields.FREQ === "MINUTELY") return interval;
  if (fields.FREQ === "HOURLY") return interval * 60;
  if (["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].includes(fields.FREQ ?? "")) return 1440;
  throw new AppError("invalid_schedule", "Unsupported RRULE frequency");
}

export function nextRun(draft: TaskDraft, after = new Date()): string | null {
  if (draft.schedule.type === "once") return new Date(draft.schedule.expression).toISOString();
  if (draft.schedule.type === "cron") {
    const parts = parseCron(draft.schedule.expression);
    const d = new Date(after.getTime() + 60_000); d.setUTCSeconds(0, 0);
    for (let i = 0; i < 1_054_080; i++, d.setUTCMinutes(d.getUTCMinutes() + 1)) {
      if (cronMatches(parts, d, draft.schedule.timezone)) return d.toISOString();
    }
    throw new AppError("invalid_schedule", "Could not determine next cron run");
  }
  const minutes = minimumRRuleMinutes(draft.schedule.expression);
  return new Date(after.getTime() + minutes * 60_000).toISOString();
}

export interface Limits { dailyRuns: number; unreadPause: number; monthlyBudgetMicros: number; fallbackModel: string; defaultModel: string }
export interface TaskToolRunner { augment(prompt: string, tools: string[]): Promise<string> }
export interface TaskNotifier { notifyTask(task: ScheduledTask, run: TaskRun): Promise<NonNullable<TaskRun["notificationStatus"]>> }

export class TaskService {
  private running = new Set<string>();
  constructor(private repo: TaskRepository, private llm: DeepSeekClient, private limits: Limits, private toolRunner?: TaskToolRunner, private notifier?: TaskNotifier) {}
  async create(userId: string, raw: unknown): Promise<ScheduledTask> {
    const draft = validateDraft(raw); const now = new Date().toISOString();
    const task: ScheduledTask = { ...draft, id: randomUUID(), userId, enabled: true, createdAt: now, updatedAt: now, nextRunAt: nextRun(draft), consecutiveUnread: 0 };
    await this.repo.saveTask(task); return task;
  }
  async patch(userId: string, id: string, patch: Record<string, unknown>): Promise<ScheduledTask> {
    const old = await this.repo.getTask(userId, id); if (!old) throw new AppError("not_found", "Task not found", 404);
    const enabled = typeof patch.enabled === "boolean" ? patch.enabled : old.enabled;
    const draft = validateDraft({ title: patch.title ?? old.title, kind: patch.kind ?? old.kind, schedule: patch.schedule ?? old.schedule, prompt: patch.prompt ?? old.prompt, tools: patch.tools ?? old.tools, notify: patch.notify ?? old.notify });
    const task = { ...old, ...draft, enabled, updatedAt: new Date().toISOString(), nextRunAt: enabled ? nextRun(draft) : old.nextRunAt };
    await this.repo.saveTask(task); return task;
  }
  async runDue(now = new Date()): Promise<TaskRun[]> {
    const completed: TaskRun[] = [];
    for (const task of await this.repo.listDue(now)) {
      if (this.running.has(task.id)) continue;
      this.running.add(task.id);
      try { completed.push(await this.runOne(task, now)); }
      finally { this.running.delete(task.id); }
    }
    return completed;
  }
  async markRunRead(userId: string, taskId: string, runId: string): Promise<void> {
    if (!await this.repo.markRunRead(userId, taskId, runId)) throw new AppError("not_found", "Task run not found", 404);
    const task = await this.repo.getTask(userId, taskId);
    if (task) { task.consecutiveUnread = 0; task.updatedAt = new Date().toISOString(); await this.repo.saveTask(task); }
  }
  private async runOne(task: ScheduledTask, now: Date): Promise<TaskRun> {
    const runs = await this.repo.listRuns(task.userId);
    const month = now.toISOString().slice(0, 7); const day = now.toISOString().slice(0, 10);
    const daily = runs.filter(r => r.startedAt.startsWith(day)).length;
    const spent = runs.filter(r => r.startedAt.startsWith(month)).reduce((n, r) => n + r.costMicros, 0);
    let status: TaskRun["status"] = "succeeded", output: string | undefined, error: string | undefined, model = this.limits.defaultModel;
    let promptTokens = 0, completionTokens = 0, costMicros = 0;
    if (daily >= this.limits.dailyRuns) { status = "blocked"; error = "daily_quota_exceeded"; }
    if (spent >= this.limits.monthlyBudgetMicros) model = this.limits.fallbackModel;
    if (spent >= this.limits.monthlyBudgetMicros * 1.2) { status = "blocked"; error = "monthly_budget_exceeded"; }
    if (status === "succeeded") { try {
      const selectedTools = task.tools.filter(t => t !== "none");
      if (selectedTools.length && !this.toolRunner) throw new AppError("tools_not_configured", "Task tools are not configured", 503);
      const prompt = selectedTools.length ? await this.toolRunner!.augment(task.prompt, selectedTools) : task.prompt;
      output = await this.llm.completeText(prompt, model, task.userId);
      // The non-streaming convenience response is intentionally provider-neutral.
      // These conservative estimates make the local budget guard effective even
      // when a provider omits usage; rates can be adjusted without code changes.
      promptTokens = Math.ceil(task.prompt.length / 4); completionTokens = Math.ceil(output.length / 4);
      const inputRate = Number(process.env.INPUT_COST_MICROS_PER_MILLION ?? 280_000);
      const outputRate = Number(process.env.OUTPUT_COST_MICROS_PER_MILLION ?? 420_000);
      costMicros = Math.ceil((promptTokens * inputRate + completionTokens * outputRate) / 1_000_000);
    } catch (e) { status = "failed"; error = e instanceof Error ? e.message : "unknown"; } }
    const done = new Date().toISOString();
    const run: TaskRun = { id: randomUUID(), taskId: task.id, userId: task.userId, startedAt: now.toISOString(), completedAt: done, status, model, promptTokens, completionTokens, costMicros, read: false, notificationStatus: task.notify ? "not_configured" : "not_requested", ...(output === undefined ? {} : { output }), ...(error === undefined ? {} : { error }) };
    if (task.notify && this.notifier) { try { run.notificationStatus = await this.notifier.notifyTask(task, run); } catch { run.notificationStatus = "failed"; } }
    await this.repo.addRun(run);
    task.consecutiveUnread += status === "succeeded" ? 1 : 0;
    if (task.consecutiveUnread >= this.limits.unreadPause) task.enabled = false;
    if (task.kind === "one_off") task.enabled = false;
    task.nextRunAt = task.enabled ? nextRun(task, now) : null; task.updatedAt = done; await this.repo.saveTask(task);
    return run;
  }
}
