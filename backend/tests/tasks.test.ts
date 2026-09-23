import test from "node:test";
import assert from "node:assert/strict";
import { MemoryTaskRepository } from "../src/repository.js";
import { nextRun, TaskService, validateDraft } from "../src/tasks.js";
import type { DeepSeekClient } from "../src/deepseek.js";

const future = () => new Date(Date.now() + 86_400_000).toISOString();
const base = () => ({ title: "提醒", kind: "one_off", schedule: { type: "once", expression: future(), timezone: "Asia/Hong_Kong" }, prompt: "总结", tools: ["none"], notify: true });

test("validates timezone and task kinds", () => {
  assert.equal(validateDraft(base()).kind, "one_off");
  assert.throws(() => validateDraft({ ...base(), schedule: { ...base().schedule, timezone: "Mars/Base" } }));
  assert.throws(() => validateDraft({ ...base(), kind: "recurring" }));
  assert.equal(validateDraft({ ...base(), kind: "monitor", schedule: { type: "rrule", expression: "FREQ=HOURLY;INTERVAL=2", timezone: "UTC" } }).kind, "monitor");
});

test("rejects recurring schedules under one hour", () => {
  assert.throws(() => validateDraft({ ...base(), kind: "recurring", schedule: { type: "cron", expression: "*/30 * * * *", timezone: "UTC" } }), /one hour/);
  assert.throws(() => validateDraft({ ...base(), kind: "monitor", schedule: { type: "rrule", expression: "FREQ=MINUTELY;INTERVAL=30", timezone: "UTC" } }), /one hour/);
});

test("cron validation rejects malformed fields and next run honors timezone", () => {
  assert.throws(() => validateDraft({ ...base(), kind: "recurring", schedule: { type: "cron", expression: "0 25 * * *", timezone: "UTC" } }), /Invalid cron/);
  assert.throws(() => validateDraft({ ...base(), kind: "recurring", schedule: { type: "cron", expression: "0,30 * * * *", timezone: "UTC" } }), /one hour/);
  const draft = validateDraft({ ...base(), kind: "recurring", schedule: { type: "cron", expression: "0 9 * * *", timezone: "Asia/Hong_Kong" } });
  assert.equal(nextRun(draft, new Date("2026-09-23T00:30:00.000Z")), "2026-09-23T01:00:00.000Z");
});

test("daily quota blocks execution", async () => {
  const repo = new MemoryTaskRepository(); const llm = { completeText: async () => "ok" } as unknown as DeepSeekClient;
  const service = new TaskService(repo, llm, { dailyRuns: 0, unreadPause: 5, monthlyBudgetMicros: 100, fallbackModel: "deepseek-flash", defaultModel: "deepseek-flash" });
  const t = await service.create("user_12345", base()); t.nextRunAt = new Date(0).toISOString(); await repo.saveTask(t);
  const [run] = await service.runDue(); assert.equal(run?.error, "daily_quota_exceeded");
});

test("unread results auto-pause", async () => {
  const repo = new MemoryTaskRepository(); const llm = { completeText: async () => "ok" } as unknown as DeepSeekClient;
  const service = new TaskService(repo, llm, { dailyRuns: 9, unreadPause: 1, monthlyBudgetMicros: 100, fallbackModel: "deepseek-flash", defaultModel: "deepseek-flash" });
  const raw = { ...base(), kind: "recurring", schedule: { type: "cron", expression: "0 * * * *", timezone: "UTC" } }; const t = await service.create("user_12345", raw); t.nextRunAt = new Date(0).toISOString(); await repo.saveTask(t);
  await service.runDue(); assert.equal((await repo.getTask("user_12345", t.id))?.enabled, false);
});

test("monthly budget falls back then blocks at hard threshold", async () => {
  const repo = new MemoryTaskRepository(); const models: string[] = []; const llm = { completeText: async (_: string, model: string) => { models.push(model); return "ok"; } } as unknown as DeepSeekClient;
  const service = new TaskService(repo, llm, { dailyRuns: 9, unreadPause: 9, monthlyBudgetMicros: 100, fallbackModel: "deepseek-flash", defaultModel: "deepseek-flash" });
  const userId = "user_12345", now = new Date();
  repo.data.runs.push({ id: "r", taskId: "x", userId, startedAt: now.toISOString(), completedAt: now.toISOString(), status: "succeeded", model: "x", promptTokens: 0, completionTokens: 0, costMicros: 110, read: true });
  const t = await service.create(userId, { ...base(), kind: "recurring", schedule: { type: "cron", expression: "0 * * * *", timezone: "UTC" } }); t.nextRunAt = new Date(0).toISOString(); await repo.saveTask(t);
  await service.runDue(now); assert.deepEqual(models, ["deepseek-flash"]);
  t.nextRunAt = new Date(0).toISOString(); t.enabled = true; await repo.saveTask(t); repo.data.runs[0]!.costMicros = 121;
  const latest = (await service.runDue(now)).at(-1); assert.equal(latest?.error, "monthly_budget_exceeded");
});

test("concurrent scheduler calls execute a due task once", async () => {
  const repo = new MemoryTaskRepository(); let calls = 0;
  const llm = { completeText: async () => { calls++; await new Promise(resolve => setTimeout(resolve, 20)); return "ok"; } } as unknown as DeepSeekClient;
  const service = new TaskService(repo, llm, { dailyRuns: 9, unreadPause: 9, monthlyBudgetMicros: 100, fallbackModel: "deepseek-flash", defaultModel: "deepseek-flash" });
  const task = await service.create("user_12345", { ...base(), kind: "recurring", schedule: { type: "cron", expression: "0 * * * *", timezone: "UTC" } });
  task.nextRunAt = new Date(0).toISOString(); await repo.saveTask(task);
  await Promise.all([service.runDue(), service.runDue()]);
  assert.equal(calls, 1); assert.equal((await repo.listRuns("user_12345", task.id)).length, 1);
});

test("reading a result resets unread pause counter", async () => {
  const repo = new MemoryTaskRepository(); const llm = { completeText: async () => "ok" } as unknown as DeepSeekClient;
  const service = new TaskService(repo, llm, { dailyRuns: 9, unreadPause: 5, monthlyBudgetMicros: 100, fallbackModel: "deepseek-flash", defaultModel: "deepseek-flash" });
  const task = await service.create("user_12345", { ...base(), kind: "recurring", schedule: { type: "cron", expression: "0 * * * *", timezone: "UTC" } });
  task.nextRunAt = new Date(0).toISOString(); await repo.saveTask(task);
  const [run] = await service.runDue(); assert.ok(run); assert.equal((await repo.getTask(task.userId, task.id))?.consecutiveUnread, 1);
  await service.markRunRead(task.userId, task.id, run.id);
  assert.equal((await repo.getTask(task.userId, task.id))?.consecutiveUnread, 0); assert.equal((await repo.listRuns(task.userId, task.id))[0]?.read, true);
});
