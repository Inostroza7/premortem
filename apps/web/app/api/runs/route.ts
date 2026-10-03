import { CreateRunBody } from "@premortem/contracts";
import { ENGINE_VERSION } from "@premortem/engine";
import { authed, body, db, json, preflight } from "@/lib/server/api";
import { assertRunnable, RUN_COLUMNS } from "@/lib/server/runs";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const GET = authed(async (ctx) => {
  const u = new URL(ctx.req.url);
  const limit = Math.min(Number(u.searchParams.get("limit") ?? 20) || 20, 100);
  let q = ctx.sb.from("runs").select(RUN_COLUMNS).eq("workspace_id", ctx.workspaceId).eq("project_id", u.searchParams.get("project_id") ?? ctx.projectId)
    .order("created_at", { ascending: false }).limit(limit);
  const before = u.searchParams.get("before");
  if (before) q = q.lt("created_at", before);
  const { data, error } = await q;
  if (error) throw error;
  return json(ctx.req, { runs: data });
});
export const POST = authed(async (ctx) => {
  const raw = await body(ctx.req);
  const b = CreateRunBody.parse(raw);
  await assertRunnable(ctx, b.caseVersionId, b.agentVersionId);
  const key = ctx.req.headers.get("idempotency-key");
  const r = await db().createRun({
    workspaceId: ctx.workspaceId, userId: ctx.userId, projectId: b.projectId ?? ctx.projectId, caseVersionId: b.caseVersionId,
    agentVersionId: b.agentVersionId, scenarioIds: b.scenarioIds, repetitions: b.repetitions, seed: b.seed, limits: b.limits,
    idempotencyKey: key, requestBody: key ? (raw as object) : null, engineVersion: ENGINE_VERSION,
  });
  return json(ctx.req, { run_id: r.run_id, status: r.status, jobs_total: r.jobs_total, reused: r.reused, report_url: `/api/runs/${r.run_id}` }, r.reused ? 200 : 202);
});
