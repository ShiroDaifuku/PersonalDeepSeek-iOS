import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { ScheduledTask, StoreData, TaskRun } from "./types.js";

export interface TaskRepository {
  listTasks(userId: string): Promise<ScheduledTask[]>;
  getTask(userId: string, id: string): Promise<ScheduledTask | undefined>;
  saveTask(task: ScheduledTask): Promise<void>;
  deleteTask(userId: string, id: string): Promise<boolean>;
  listDue(now: Date): Promise<ScheduledTask[]>;
  addRun(run: TaskRun): Promise<void>;
  listRuns(userId: string, taskId?: string): Promise<TaskRun[]>;
  markRunRead(userId: string, taskId: string, runId: string): Promise<boolean>;
}

export class JsonTaskRepository implements TaskRepository {
  private queue: Promise<unknown> = Promise.resolve();
  constructor(private file: string) {}
  private async read(): Promise<StoreData> {
    try { return JSON.parse(await readFile(this.file, "utf8")) as StoreData; }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return { tasks: [], runs: [] }; throw error; }
  }
  private async mutate(fn: (data: StoreData) => void): Promise<void> {
    const job = this.queue.then(async () => {
      const data = await this.read(); fn(data);
      await mkdir(dirname(this.file), { recursive: true });
      const temp = `${this.file}.${process.pid}.tmp`;
      await writeFile(temp, JSON.stringify(data, null, 2)); await rename(temp, this.file);
    });
    this.queue = job.catch(() => undefined); await job;
  }
  async listTasks(userId: string) { return (await this.read()).tasks.filter(t => t.userId === userId); }
  async getTask(userId: string, id: string) { return (await this.read()).tasks.find(t => t.userId === userId && t.id === id); }
  async saveTask(task: ScheduledTask) { await this.mutate(d => { const i = d.tasks.findIndex(t => t.id === task.id); if (i < 0) d.tasks.push(task); else d.tasks[i] = task; }); }
  async deleteTask(userId: string, id: string) { let removed = false; await this.mutate(d => { const n = d.tasks.length; d.tasks = d.tasks.filter(t => !(t.userId === userId && t.id === id)); removed = d.tasks.length !== n; }); return removed; }
  async listDue(now: Date) { return (await this.read()).tasks.filter(t => t.enabled && t.nextRunAt !== null && Date.parse(t.nextRunAt) <= now.getTime()); }
  async addRun(run: TaskRun) { await this.mutate(d => { d.runs.push(run); }); }
  async listRuns(userId: string, taskId?: string) { return (await this.read()).runs.filter(r => r.userId === userId && (!taskId || r.taskId === taskId)); }
  async markRunRead(userId: string, taskId: string, runId: string) { let changed = false; await this.mutate(d => { const run = d.runs.find(r => r.userId === userId && r.taskId === taskId && r.id === runId); if (run) { run.read = true; changed = true; } }); return changed; }
}

export class MemoryTaskRepository implements TaskRepository {
  data: StoreData = { tasks: [], runs: [] };
  async listTasks(userId: string) { return this.data.tasks.filter(t => t.userId === userId); }
  async getTask(userId: string, id: string) { return this.data.tasks.find(t => t.userId === userId && t.id === id); }
  async saveTask(task: ScheduledTask) { const i = this.data.tasks.findIndex(t => t.id === task.id); if (i < 0) this.data.tasks.push(task); else this.data.tasks[i] = task; }
  async deleteTask(userId: string, id: string) { const n = this.data.tasks.length; this.data.tasks = this.data.tasks.filter(t => !(t.userId === userId && t.id === id)); return n !== this.data.tasks.length; }
  async listDue(now: Date) { return this.data.tasks.filter(t => t.enabled && t.nextRunAt !== null && Date.parse(t.nextRunAt) <= now.getTime()); }
  async addRun(run: TaskRun) { this.data.runs.push(run); }
  async listRuns(userId: string, taskId?: string) { return this.data.runs.filter(r => r.userId === userId && (!taskId || r.taskId === taskId)); }
  async markRunRead(userId: string, taskId: string, runId: string) { const run = this.data.runs.find(r => r.userId === userId && r.taskId === taskId && r.id === runId); if (!run) return false; run.read = true; return true; }
}
