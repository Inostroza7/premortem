import { QuoteRunBody } from "@premortem/contracts";
import { authed, body, db, json, preflight } from "@/lib/server/api";
import { assertRunnable } from "@/lib/server/runs";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const POST = authed(async (ctx) => {
  const b = QuoteRunBody.parse(await body(ctx.req));
  await assertRunnable(ctx, b.caseVersionId, b.agentVersionId);
  const q = await db().quoteRun({
    workspaceId: ctx.workspaceId, userId: ctx.userId, projectId: b.projectId ?? ctx.projectId, caseVersionId: b.caseVersionId,
    agentVersionId: b.agentVersionId, scenarioIds: b.scenarioIds, repetitions: b.repetitions, limits: b.limits,
  });
  return json(ctx.req, {
    jobs_total: q.jobs_total, units_required: q.units_required, units_available: q.units_available, affordable: q.affordable,
    limits: q.limits, jobs: q.jobs.map((j: any) => ({ ordinal: j.ordinal, scenario_id: j.scenario_id, repetition: j.repetition })),
  });
});
