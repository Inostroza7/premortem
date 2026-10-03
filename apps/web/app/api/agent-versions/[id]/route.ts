import { authed, json, must, preflight } from "@/lib/server/api";
import { readPrompt } from "@/lib/server/prompts";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
/** Metadatos de la versión y, para drivers con modelo, su prompt descifrado (queda registro de acceso). */
export const GET = authed(async (ctx, p) => {
  const { data } = await ctx.sb.from("agent_versions").select("id, label, driver, driver_version, policy_id, model_id, config, created_at").eq("id", p.id!).maybeSingle();
  const agent = must(data, "Versión de agente") as any;
  const systemPrompt = agent.driver === "reference" ? null : await readPrompt(ctx.workspaceId, ctx.userId, agent.id, "view");
  return json(ctx.req, { agent_version: agent, system_prompt: systemPrompt });
});
