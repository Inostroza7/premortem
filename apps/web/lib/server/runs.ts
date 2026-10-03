import { getPack } from "@premortem/domain-registry";
import { HttpError, must, type Ctx } from "./api";

export const RUN_COLUMNS =
  "id, project_id, kind, status, created_at, started_at, ended_at, seed, repetitions, jobs_total, jobs_terminal, jobs_passed, jobs_safe_stop, jobs_failed, jobs_inconclusive, jobs_errored, jobs_cancelled, case_version_id, agent_version_id, domain_pack_version_id, parent_run_id";

/** Antes de cotizar o reservar: el paquete del caso debe estar instalado y debe implementar la política del agente. */
export async function assertRunnable(ctx: Ctx, caseVersionId: string, agentVersionId: string) {
  const { data: c } = await ctx.sb.from("case_versions").select("id, domain_pack_versions(pack_id, version)").eq("id", caseVersionId).maybeSingle();
  const caseRow = must(c, "Caso") as any;
  const { data: a } = await ctx.sb.from("agent_versions").select("id, driver, policy_id").eq("id", agentVersionId).maybeSingle();
  const agent = must(a, "Versión de agente") as any;
  const pack = getPack(caseRow.domain_pack_versions.pack_id, caseRow.domain_pack_versions.version);
  if (!pack) throw new HttpError(409, "PACK_NOT_INSTALLED", "El paquete del caso no está instalado en este despliegue");
  const missing = (pack.requiresEnv ?? []).filter((k) => !process.env[k]);
  if (missing.length) throw new HttpError(409, "SANDBOX_NOT_CONFIGURED", `El entorno ${pack.ref.id} necesita ${missing.join(", ")} en el servidor`);
  if (agent.driver === "anthropic") {
    if (!process.env.ANTHROPIC_API_KEY) throw new HttpError(409, "DRIVER_NOT_AVAILABLE", "El driver anthropic necesita ANTHROPIC_API_KEY en el servidor");
    return;
  }
  if (agent.driver !== "reference") throw new HttpError(409, "DRIVER_NOT_AVAILABLE", `El driver ${agent.driver} aún no está disponible`);
  if (!pack.referencePolicies[agent.policy_id]) {
    throw new HttpError(409, "POLICY_NOT_IN_PACK", `El paquete ${pack.ref.id} no implementa la política ${agent.policy_id}`);
  }
}
