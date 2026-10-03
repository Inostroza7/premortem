import { authed, json, must, preflight } from "@/lib/server/api";
import { RUN_COLUMNS } from "@/lib/server/runs";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const GET = authed(async (ctx, p) => {
  const { data: run } = await ctx.sb.from("runs").select(`${RUN_COLUMNS}, manifest, limits`).eq("id", p.id!).maybeSingle();
  must(run, "Run");
  const { data: jobs } = await ctx.sb.from("world_jobs")
    .select("id, ordinal, scenario_id, repetition, status, verdict, active_attempt_id, recovery_count, terminal_reason, started_at, ended_at")
    .eq("run_id", p.id!).order("ordinal");
  return json(ctx.req, { run, jobs });
});
