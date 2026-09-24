import { describe, expect, it } from "vitest";
import { nextRun, validateDraft } from "../src/domain";

const recurring = { title:"Hourly report", kind:"recurring", schedule:{type:"cron",expression:"0 * * * *",timezone:"Asia/Hong_Kong"}, prompt:"Summarize updates", tools:["none"], notify:true, knowledge_base_ids:[] } as const;

describe("task validation",()=>{
  it("accepts an hourly task and computes its next wall-clock run",()=>{
    const task=validateDraft(recurring,new Date("2026-01-01T00:01:00Z"));
    expect(nextRun(task,new Date("2026-01-01T00:01:00Z"))).toBe("2026-01-01T01:00:00.000Z");
  });
  it("rejects schedules more frequent than hourly",()=>{
    expect(()=>validateDraft({...recurring,schedule:{...recurring.schedule,expression:"*/30 * * * *"}})).toThrow(/at least one hour/);
  });
  it("rejects unknown fields under the strict contract",()=>{
    expect(()=>validateDraft({...recurring,unexpected:true})).toThrow(/Unknown task field/);
  });
  it("accepts selected synced knowledge bases",()=>{
    expect(validateDraft({...recurring,knowledge_base_ids:["base-1"]}).knowledge_base_ids).toEqual(["base-1"]);
  });
  it("rejects duplicate knowledge bases",()=>{
    expect(()=>validateDraft({...recurring,knowledge_base_ids:["base-1","base-1"]})).toThrow(/knowledge_base_ids/);
  });
});
