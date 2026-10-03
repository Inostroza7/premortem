import { allPacks } from "@premortem/domain-registry";
import { buildManifest } from "@premortem/engine";
import { hashJson } from "@premortem/evidence";
import { authed, db, HttpError, json, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
/** Crea en el workspace actual los casos de demo de cada paquete y las dos versiones de agente de referencia. Idempotente. */
export const POST = authed(async (ctx) => {
  const { data: registered } = await ctx.sb.from("domain_pack_versions").select("id, pack_id, version, content_hash").eq("status", "active");
  const created = { cases: [] as string[], agent_versions: [] as string[] };
  for (const pack of allPacks) {
    const reg = (registered ?? []).find((r: any) => r.pack_id === pack.ref.id && r.version === pack.ref.version);
    if (!reg) throw new HttpError(409, "PACKS_NOT_REGISTERED", `El paquete ${pack.ref.id}@${pack.ref.version} no está registrado. Ejecuta pnpm packs:register.`);
    if (String(reg.content_hash).replace(/^\\x/, "") !== buildManifest(pack).contentHash) {
      throw new HttpError(409, "PACK_HASH_MISMATCH", `El paquete ${pack.ref.id}@${pack.ref.version} registrado no coincide con el código desplegado.`);
    }
    for (const demo of pack.demoCases) {
      const { data: existing } = await ctx.sb.from("case_versions").select("id").eq("workspace_id", ctx.workspaceId)
        .eq("project_id", ctx.projectId).eq("domain_pack_version_id", reg.id).eq("label", demo.label).limit(1);
      if (existing?.length) continue;
      const id = await db().createCaseVersion({
        workspaceId: ctx.workspaceId, userId: ctx.userId, projectId: ctx.projectId, packVersionId: reg.id, label: demo.label,
        fixtureVersion: demo.fixtureVersion, task: demo.task, publicContext: demo.publicContext, fixture: demo.fixture, oracle: demo.oracle,
        contentHashHex: hashJson({ pack: pack.ref, ...demo }),
      });
      created.cases.push(id);
    }
  }
  const policies = new Map<string, string>();
  for (const pack of allPacks) for (const p of Object.values(pack.referencePolicies)) policies.set(p.id, p.label);
  for (const [policyId, label] of policies) {
    const { data: existing } = await ctx.sb.from("agent_versions").select("id").eq("workspace_id", ctx.workspaceId).eq("policy_id", policyId).eq("label", label).limit(1);
    if (existing?.length) continue;
    const id = await db().createAgentVersion({
      workspaceId: ctx.workspaceId, userId: ctx.userId, label, driver: "reference", driverVersion: "1.0.0", policyId, modelId: null,
      config: {}, contentHashHex: hashJson({ driver: "reference", policy: policyId, config: {} }),
    });
    created.agent_versions.push(id);
  }
  return json(ctx.req, { created }, 201);
});
