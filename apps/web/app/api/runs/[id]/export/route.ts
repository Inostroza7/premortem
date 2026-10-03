import { verifyChain, EVIDENCE_FORMAT_VERSION, type StoredEvent } from "@premortem/evidence";
import { authed, hexOf, json, must, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const GET = authed(async (ctx, p) => {
  const { data: run } = await ctx.sb.from("runs").select("*").eq("id", p.id!).maybeSingle();
  must(run, "Run");
  const { data: jobs } = await ctx.sb.from("world_jobs").select("*").eq("run_id", p.id!).order("ordinal");
  const { data: attempts } = await ctx.sb.from("world_attempts").select("*").eq("run_id", p.id!).order("started_at");
  const ids = (attempts ?? []).map((a: any) => a.id);
  const [{ data: events }, { data: effects }, { data: rules }] = await Promise.all([
    ctx.sb.from("attempt_events").select("event_id, workspace_id, run_id, job_id, attempt_id, seq, format, type, audience, public_payload, public_payload_hash, private_blob_hash, prev_hash, event_hash, created_at").in("attempt_id", ids).order("seq").limit(10000),
    ctx.sb.from("effects").select("*").in("attempt_id", ids),
    ctx.sb.from("rule_results").select("*").in("attempt_id", ids),
  ]);
  const norm = (events ?? []).map((e: any) => ({ ...e, public_payload_hash: hexOf(e.public_payload_hash), private_blob_hash: hexOf(e.private_blob_hash), prev_hash: hexOf(e.prev_hash), event_hash: hexOf(e.event_hash) }));
  const verification = Object.fromEntries(ids.map((id: string) => [id, verifyChain(norm.filter((e: any) => e.attempt_id === id) as StoredEvent[])]));
  const body = {
    schema_version: 1,
    evidence_format_version: EVIDENCE_FORMAT_VERSION,
    exported_at: new Date().toISOString(),
    trust_note: "La verificación comprueba consistencia interna de cada cadena (secuencia, payload, envelope y enlace). No demuestra autenticidad frente a quien pueda reescribir todas las cadenas; para eso hace falta un checkpoint firmado fuera de su control (P1).",
    run: { ...run, manifest_hash: hexOf(run!.manifest_hash), request_hash: hexOf(run!.request_hash) },
    jobs, attempts: (attempts ?? []).map((a: any) => ({ ...a, chain_head: hexOf(a.chain_head) })),
    events: norm, effects, rule_results: rules, verification,
  };
  return json(ctx.req, body, 200, { "Content-Disposition": `attachment; filename="premortem-run-${p.id}.json"` });
});
