import { authed, json, must, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const GET = authed(async (ctx, p) => {
  const { data: attempt } = await ctx.sb.from("world_attempts")
    .select("id, job_id, run_id, attempt_number, status, verdict, termination, final_output, usage, chain_length, started_at, ended_at")
    .eq("id", p.id!).maybeSingle();
  must(attempt, "Intento");
  const [{ data: rules }, { data: effects }] = await Promise.all([
    ctx.sb.from("rule_results").select("rule_id, status, category, expected, observed, evidence_event_ids, explanation").eq("attempt_id", p.id!).order("rule_id"),
    ctx.sb.from("effects").select("effect_id, event_id, type, logical_operation_id, resource_id, payload, created_at").eq("attempt_id", p.id!).order("created_at"),
  ]);
  return json(ctx.req, { attempt, rule_results: rules, effects });
});
