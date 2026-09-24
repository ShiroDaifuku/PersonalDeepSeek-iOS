export type TaskKind = "one_off" | "recurring" | "monitor";
export type ScheduleType = "once" | "rrule" | "cron";
export interface TaskSchedule { type: ScheduleType; expression: string; timezone: string }
export interface TaskDraft { title: string; kind: TaskKind; schedule: TaskSchedule; prompt: string; tools: string[]; notify: boolean }

export class AppError extends Error {
  constructor(public code: string, message: string, public status = 400, public retryable = false) { super(message); }
}

const allowedKinds = new Set(["one_off", "recurring", "monitor"]);
const allowedTypes = new Set(["once", "rrule", "cron"]);
const allowedTools = new Set(["none", "web_search", "web_fetch"]);

export function validTimezone(value: string): boolean {
  try { new Intl.DateTimeFormat("en", { timeZone: value }); return true; } catch { return false; }
}

export function validateDraft(value: unknown, now = new Date()): TaskDraft {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new AppError("invalid_task", "Task must be an object");
  const x = value as Record<string, unknown>;
  if (Object.keys(x).some(k => !["title", "kind", "schedule", "prompt", "tools", "notify"].includes(k))) throw new AppError("invalid_task", "Unknown task field");
  if (typeof x.title !== "string" || !x.title.trim() || x.title.length > 120) throw new AppError("invalid_task", "Invalid title");
  if (typeof x.kind !== "string" || !allowedKinds.has(x.kind)) throw new AppError("invalid_task", "Invalid task kind");
  if (!x.schedule || typeof x.schedule !== "object" || Array.isArray(x.schedule)) throw new AppError("invalid_task", "Invalid schedule");
  const s = x.schedule as Record<string, unknown>;
  if (Object.keys(s).some(k => !["type", "expression", "timezone"].includes(k)) || typeof s.type !== "string" || !allowedTypes.has(s.type) || typeof s.expression !== "string" || !s.expression || s.expression.length > 500 || typeof s.timezone !== "string" || !validTimezone(s.timezone)) throw new AppError("invalid_task", "Invalid schedule fields");
  if (typeof x.prompt !== "string" || !x.prompt || x.prompt.length > 20_000) throw new AppError("invalid_task", "Invalid prompt");
  if (!Array.isArray(x.tools) || x.tools.length > 3 || new Set(x.tools).size !== x.tools.length || x.tools.some(t => typeof t !== "string" || !allowedTools.has(t))) throw new AppError("invalid_task", "Invalid tools");
  if (typeof x.notify !== "boolean") throw new AppError("invalid_task", "Invalid notify");
  if (x.kind === "one_off" && s.type !== "once") throw new AppError("invalid_task", "One-off tasks require once schedule");
  if (x.kind !== "one_off" && s.type === "once") throw new AppError("invalid_task", "Recurring tasks require cron or rrule");
  if (s.type === "once") { const t = Date.parse(s.expression); if (!Number.isFinite(t) || t <= now.getTime()) throw new AppError("invalid_task", "One-off time must be in the future"); }
  if (s.type === "cron" && cronValues(parseCron(s.expression)[0], 0, 59).length > 1) throw new AppError("interval_too_short", "Recurring interval must be at least one hour");
  if (s.type === "rrule" && rruleMinutes(s.expression) < 60) throw new AppError("interval_too_short", "Recurring interval must be at least one hour");
  return value as TaskDraft;
}

type Cron = [string, string, string, string, string];
function parseCron(value: string): Cron { const f = value.trim().split(/\s+/); if (f.length !== 5) throw new AppError("invalid_schedule", "Cron must have five fields"); const p = f as Cron; cronValues(p[0],0,59); cronValues(p[1],0,23); cronValues(p[2],1,31); cronValues(p[3],1,12); cronValues(p[4],0,7,true); return p; }
function cronValues(expression: string, min: number, max: number, sunday = false): number[] {
  const out = new Set<number>();
  for (const item of expression.split(",")) { const [range, stepRaw] = item.split("/", 2); const step = stepRaw === undefined ? 1 : Number(stepRaw); if (!Number.isInteger(step) || step < 1) throw new AppError("invalid_schedule", `Invalid cron field: ${expression}`); let start: number, end: number; if (range === "*") { start=min; end=max; } else if (range?.includes("-")) { [start,end] = range.split("-",2).map(Number) as [number,number]; } else { start=Number(range); end=start; if (stepRaw !== undefined) throw new AppError("invalid_schedule", `Invalid cron field: ${expression}`); } if (!Number.isInteger(start) || !Number.isInteger(end) || start < min || end > max || start > end) throw new AppError("invalid_schedule", `Invalid cron field: ${expression}`); for (let n=start;n<=end;n+=step) out.add(sunday && n === 7 ? 0 : n); }
  return [...out].sort((a,b)=>a-b);
}
function zoned(date: Date, timezone: string) { const f = new Intl.DateTimeFormat("en-US-u-ca-gregory", {timeZone:timezone,year:"numeric",month:"numeric",day:"numeric",hour:"numeric",minute:"numeric",hourCycle:"h23"}); const p=Object.fromEntries(f.formatToParts(date).filter(x=>x.type!=="literal").map(x=>[x.type,Number(x.value)])); return {minute:p.minute!,hour:p.hour!,day:p.day!,month:p.month!,weekday:new Date(Date.UTC(p.year!,p.month!-1,p.day!)).getUTCDay()}; }
function cronMatches(p:Cron,date:Date,tz:string) { const z=zoned(date,tz); const dom=cronValues(p[2],1,31).includes(z.day), dow=cronValues(p[4],0,7,true).includes(z.weekday); return cronValues(p[0],0,59).includes(z.minute)&&cronValues(p[1],0,23).includes(z.hour)&&cronValues(p[3],1,12).includes(z.month)&&(p[2]!=="*"&&p[4]!=="*"?dom||dow:dom&&dow); }
function rruleMinutes(value:string) { const f=Object.fromEntries(value.replace(/^RRULE:/i,"").split(";").map(v=>v.split("=",2))); const interval=Number(f.INTERVAL??"1"); if(!Number.isInteger(interval)||interval<1) throw new AppError("invalid_schedule","Invalid RRULE interval"); if(f.FREQ==="MINUTELY")return interval;if(f.FREQ==="HOURLY")return interval*60;if(["DAILY","WEEKLY","MONTHLY","YEARLY"].includes(f.FREQ??""))return 1440;throw new AppError("invalid_schedule","Unsupported RRULE frequency"); }
export function nextRun(draft:TaskDraft,after=new Date()):string|null { if(draft.schedule.type==="once")return new Date(draft.schedule.expression).toISOString();if(draft.schedule.type==="rrule")return new Date(after.getTime()+rruleMinutes(draft.schedule.expression)*60000).toISOString();const p=parseCron(draft.schedule.expression);const d=new Date(after.getTime()+60000);d.setUTCSeconds(0,0);for(let i=0;i<1054080;i++,d.setUTCMinutes(d.getUTCMinutes()+1))if(cronMatches(p,d,draft.schedule.timezone))return d.toISOString();throw new AppError("invalid_schedule","Could not determine next cron run"); }
