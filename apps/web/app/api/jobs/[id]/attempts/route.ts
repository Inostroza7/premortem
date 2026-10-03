import { authed, json, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const GET = authed(async (ctx, p) => {
  const { data, error } = await ctx.sb.from("world_attempts")
    .select("id, job_id, run_id, attempt_number, status, verdict, termination, final_output, usage, chain_length, started_at, ended_at")
    .eq("job_id", p.id!).order("attempt_number");
  if (error) throw error;
  return json(ctx.req, { attempts: data });
});
