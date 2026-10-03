import { authed, HttpError, json, must, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;

const COLS = "id, status, case_version_id, agent_version_id, domain_pack_version_id, seed, repetitions, limits, manifest, created_at, jobs_passed, jobs_safe_stop, jobs_failed, jobs_inconclusive";
const same = (x: unknown, y: unknown) => JSON.stringify(x) === JSON.stringify(y);

/** Compara dos runs. Solo es una mejora controlada si cambia únicamente la versión de agente (spec v2 §14). */
export const GET = authed(async (ctx) => {
  const u = new URL(ctx.req.url);
  const a = u.searchParams.get("a"), b = u.searchParams.get("b");
  if (!a || !b) throw new HttpError(400, "VALIDATION_ERROR", "Indica ?a=<run_id>&b=<run_id>");
  const [{ data: ra }, { data: rb }] = await Promise.all([ctx.sb.from("runs").select(COLS).eq("id", a).maybeSingle(), ctx.sb.from("runs").select(COLS).eq("id", b).maybeSingle()]);
  const A = must(ra, "Run a") as any, B = must(rb, "Run b") as any;
  const differences: string[] = [];
  if (A.case_version_id !== B.case_version_id) differences.push("caso");
  if (A.domain_pack_version_id !== B.domain_pack_version_id) differences.push("versión del paquete");
  if (A.seed !== B.seed) differences.push("semilla");
  if (A.repetitions !== B.repetitions) differences.push("repeticiones");
  if (!same(A.limits, B.limits)) differences.push("límites");
  if (!same(Object.keys(A.manifest?.scenarios ?? {}).sort(), Object.keys(B.manifest?.scenarios ?? {}).sort())) differences.push("escenarios");
  if (!same(A.manifest?.rules, B.manifest?.rules)) differences.push("reglas");
  if (A.manifest?.engine_version !== B.manifest?.engine_version) differences.push("versión del motor");
  const agentChanges: string[] = [];
  if (A.agent_version_id !== B.agent_version_id) agentChanges.push("versión de agente");
  if (A.manifest?.agent?.model_id !== B.manifest?.agent?.model_id) agentChanges.push("modelo");

  const [{ data: ja }, { data: jb }] = await Promise.all([
    ctx.sb.from("world_jobs").select("scenario_id, repetition, verdict, status").eq("run_id", a).order("ordinal"),
    ctx.sb.from("world_jobs").select("scenario_id, repetition, verdict, status").eq("run_id", b).order("ordinal"),
  ]);
  const key = (j: any) => `${j.scenario_id}#${j.repetition}`;
  const mb = new Map((jb ?? []).map((j: any) => [key(j), j]));
  const rank: Record<string, number> = { failed: 0, inconclusive: 1, safe_stop: 2, passed: 2 };
  const matrix = (ja ?? []).map((j: any) => {
    const other: any = mb.get(key(j));
    const change = !other?.verdict || !j.verdict ? "n/a" : rank[other.verdict]! > rank[j.verdict]! ? "mejoró" : rank[other.verdict]! < rank[j.verdict]! ? "empeoró" : "igual";
    return { scenario_id: j.scenario_id, label: A.manifest?.scenarios?.[j.scenario_id]?.label ?? j.scenario_id, repetition: j.repetition, a: j.verdict, b: other?.verdict ?? null, change };
  });
  const summary = (r: any) => ({ passed: r.jobs_passed, safe_stop: r.jobs_safe_stop, failed: r.jobs_failed, inconclusive: r.jobs_inconclusive });
  return json(ctx.req, {
    comparable: differences.length === 0,
    differences,
    agent_changes: agentChanges,
    note: differences.length === 0
      ? "Mismo caso, paquete, escenarios, reglas, semilla y límites: la diferencia se atribuye al cambio de agente."
      : "Los runs difieren en más que el agente: es otro experimento, no una mejora controlada.",
    a: { run_id: A.id, agent_version_id: A.agent_version_id, model: A.manifest?.agent?.model_id ?? null, summary: summary(A) },
    b: { run_id: B.id, agent_version_id: B.agent_version_id, model: B.manifest?.agent?.model_id ?? null, summary: summary(B) },
    matrix,
  });
});
