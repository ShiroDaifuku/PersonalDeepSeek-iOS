export type TaskKind = "one_off" | "recurring" | "monitor";
export type ScheduleType = "once" | "rrule" | "cron";
export type TaskTool = "none" | "web_search" | "web_fetch";

export interface TaskDraft {
  title: string;
  kind: TaskKind;
  schedule: { type: ScheduleType; expression: string; timezone: string };
  prompt: string;
  tools: TaskTool[];
  notify: boolean;
}

export interface ScheduledTask extends TaskDraft {
  id: string;
  userId: string;
  enabled: boolean;
  createdAt: string;
  updatedAt: string;
  nextRunAt: string | null;
  consecutiveUnread: number;
}

export interface TaskRun {
  id: string;
  taskId: string;
  userId: string;
  startedAt: string;
  completedAt: string;
  status: "succeeded" | "failed" | "blocked";
  model: string;
  output?: string;
  error?: string;
  promptTokens: number;
  completionTokens: number;
  costMicros: number;
  read: boolean;
  notificationStatus?: "not_requested" | "not_configured" | "no_devices" | "sent" | "failed";
}

export interface StoreData { tasks: ScheduledTask[]; runs: TaskRun[] }

export class AppError extends Error {
  constructor(public code: string, message: string, public status = 400, public retryable = false) { super(message); }
}
