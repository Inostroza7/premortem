import { CreateAgentVersionBody } from "@premortem/contracts";
import { allPacks } from "@premortem/domain-registry";
import { hashJson } from "@premortem/evidence";
import { authed, body, db, HttpError, json, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const GET = authed(async (ctx) => {
  const { data, error } = await ctx.sb.from("agent_versions").select("id, label, driver, driver_version, policy_id, model_id, config, created_at")
    .eq("workspace_id", ctx.workspaceId).order("created_at", { ascending: false });
  if (error) throw error;
  return json(ctx.req, { agent_versions: data });
});
export const POST = authed(async (ctx) => {
  const b = CreateAgentVersionBody.parse(await body(ctx.req));
  if (!allPacks.some((p) => p.referencePolicies[b.policyId])) {
    throw new HttpError(400, "POLICY_UNKNOWN", `Ningún paquete instalado implementa la política ${b.policyId}`);
  }
  const id = await db().createAgentVersion({
    workspaceId: ctx.workspaceId, userId: ctx.userId, label: b.label, driver: "reference", driverVersion: "1.0.0",
    policyId: b.policyId, modelId: null, config: b.config, contentHashHex: hashJson({ driver: "reference", policy: b.policyId, config: b.config }),
  });
  return json(ctx.req, { id }, 201);
});
