import { CreateAgentVersionBody } from "@premortem/contracts";
import { allPacks } from "@premortem/domain-registry";
import { hashJson } from "@premortem/evidence";
import { authed, body, db, HttpError, json, preflight } from "@/lib/server/api";
import { sealPrompt } from "@/lib/server/prompts";

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
  if (b.driver === "reference") {
    if (!allPacks.some((p) => p.referencePolicies[b.policyId])) {
      throw new HttpError(400, "POLICY_UNKNOWN", `Ningún paquete instalado implementa la política ${b.policyId}`);
    }
    const id = await db().createAgentVersion({
      workspaceId: ctx.workspaceId, userId: ctx.userId, label: b.label, driver: "reference", driverVersion: "1.0.0",
      policyId: b.policyId, modelId: null, config: b.config, contentHashHex: hashJson({ driver: "reference", policy: b.policyId, config: b.config }),
    });
    return json(ctx.req, { id }, 201);
  }
  const model = b.model ?? process.env.ANTHROPIC_MODEL;
  if (!model) throw new HttpError(400, "MODEL_REQUIRED", "Indica model o configura ANTHROPIC_MODEL en el servidor");
  const config = { ...b.config, ...(b.parentAgentVersionId ? { parent_agent_version_id: b.parentAgentVersionId } : {}) };
  const sealed = await sealPrompt(ctx.workspaceId, ctx.userId, b.systemPrompt);
  const id = await db().createAgentVersion({
    workspaceId: ctx.workspaceId, userId: ctx.userId, label: b.label, driver: "anthropic", driverVersion: "1.0.0",
    policyId: null, modelId: model, config, contentHashHex: hashJson({ driver: "anthropic", model, config, prompt_hmac: sealed.promptHmac.toString("hex") }),
    promptHmac: sealed.promptHmac, promptPayload: sealed.promptPayload,
  });
  return json(ctx.req, { id, model }, 201);
});
