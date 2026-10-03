// PREMORTEM · prueba de punta a punta por HTTP, como la usará un front.
// Requiere API (pnpm dev) y al menos un worker (pnpm worker) apuntando al mismo entorno.
// Uso: PREMORTEM_ENV=local pnpm test:e2e      (crea usuarios de prueba; usar solo en local o staging)
import { randomUUID } from "node:crypto";
import { loadEnv, requireEnv } from "@premortem/config";

loadEnv();
const API = process.env.PREMORTEM_API_URL ?? "http://localhost:3000";
const SB = requireEnv("NEXT_PUBLIC_SUPABASE_URL");
const KEY = requireEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY");

let failures = 0;
const check = (cond: unknown, label: string, extra?: unknown) => {
  console.log(`${cond ? "  ✓" : "  ✗"} ${label}${!cond && extra !== undefined ? ` → ${JSON.stringify(extra).slice(0, 300)}` : ""}`);
  if (!cond) failures++;
};

async function signup(tag: string) {
  const email = `e2e-${tag}-${Date.now()}@example.test`;
  const r = await fetch(`${SB}/auth/v1/signup`, {
    method: "POST", headers: { apikey: KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password: randomUUID() }),
  });
  const j = (await r.json()) as any;
  if (!j.access_token) throw new Error(`signup ${tag}: ${JSON.stringify(j).slice(0, 200)}`);
  return j.access_token as string;
}

const api = async (token: string, method: string, path: string, body?: unknown, headers: Record<string, string> = {}) => {
  const r = await fetch(`${API}${path}`, {
    method, headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: r.status, body: (await r.json().catch(() => null)) as any };
};

async function waitRun(token: string, runId: string, timeoutMs = 120_000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const r = await api(token, "GET", `/api/runs/${runId}`);
    // Un run cancelado puede tener jobs en curso que se cierran en su siguiente llamada: esperar a que todos sean terminales.
    const allTerminal = (r.body?.jobs ?? []).every((j: any) => !["queued", "running"].includes(j.status));
    if (r.body?.run?.status === "completed" || (r.body?.run?.status === "cancelled" && allTerminal)) return r.body;
    await new Promise((res) => setTimeout(res, 1000));
  }
  throw new Error(`run ${runId} no terminó en ${timeoutMs} ms`);
}

const EXPECT: Record<string, Record<string, string>> = {
  "naive-v1": { baseline: "passed", duplicate_identity: "failed", commit_ack_lost: "failed", permission_revoked: "failed" },
  "guarded-v1": { baseline: "passed", duplicate_identity: "passed", commit_ack_lost: "passed", permission_revoked: "safe_stop" },
};
const SCENARIOS = ["baseline", "duplicate_identity", "commit_ack_lost", "permission_revoked"];

async function main() {
  console.log(`API ${API}`);
  const health = await fetch(`${API}/api/health`).then((r) => r.json() as Promise<any>);
  check(health.ok === true, "health ok");
  const unauth = await fetch(`${API}/api/me`);
  check(unauth.status === 401, "sin token → 401");

  const users: Record<string, string> = { A: await signup("a"), B: await signup("b") };
  const runsByUser: Record<string, string[]> = { A: [], B: [] };
  const packFor: Record<string, string> = { A: "refunds", B: "calendar" };

  for (const [u, token] of Object.entries(users)) {
    console.log(`\nUsuario ${u} · paquete ${packFor[u]}`);
    const me = await api(token, "GET", "/api/me");
    check(me.status === 200 && me.body.wallet.available_units === 8, "workspace personal con 8 unidades de prueba", me.body);
    const boot = await api(token, "POST", "/api/bootstrap");
    const packsN = (await api(token, "GET", "/api/domain-packs")).body.domain_packs.length;
    check(boot.status === 201 && boot.body.created.cases.length === packsN && boot.body.created.agent_versions.length === 2, `bootstrap crea ${packsN} casos y 2 agentes`, boot.body);
    const boot2 = await api(token, "POST", "/api/bootstrap");
    check(boot2.body.created.cases.length === 0, "bootstrap idempotente");
    const packs = await api(token, "GET", "/api/domain-packs");
    check(packs.body.domain_packs.length >= 2, "catálogo con refunds y calendar");
    const cases = await api(token, "GET", "/api/cases");
    const kase = cases.body.cases.find((c: any) => c.domain_pack_versions.pack_id === packFor[u]);
    check(!!kase, `caso de ${packFor[u]} visible`);
    const agents = (await api(token, "GET", "/api/agent-versions")).body.agent_versions;

    const quote = await api(token, "POST", "/api/run-quotes", { caseVersionId: kase.id, agentVersionId: agents[0].id, scenarioIds: SCENARIOS });
    check(quote.status === 200 && quote.body.units_required === 4 && quote.body.affordable, "cotización: 4 unidades", quote.body);
    const bad = await api(token, "POST", "/api/run-quotes", { caseVersionId: kase.id, agentVersionId: agents[0].id, scenarioIds: ["no_existe"] });
    check(bad.status === 400 && bad.body.error.code === "SCENARIO_NOT_IN_PACK", "escenario inexistente → 400", bad.body);

    for (const policy of ["naive-v1", "guarded-v1"]) {
      const agent = agents.find((a: any) => a.policy_id === policy);
      const key = randomUUID();
      const payload = { caseVersionId: kase.id, agentVersionId: agent.id, scenarioIds: SCENARIOS, seed: 7 };
      const r1 = await api(token, "POST", "/api/runs", payload, { "Idempotency-Key": key });
      check(r1.status === 202 && r1.body.jobs_total === 4, `${policy}: run creado (202)`, r1.body);
      const r2 = await api(token, "POST", "/api/runs", { seed: 7, scenarioIds: SCENARIOS, agentVersionId: agent.id, caseVersionId: kase.id }, { "Idempotency-Key": key });
      check(r2.status === 200 && r2.body.run_id === r1.body.run_id && r2.body.reused, `${policy}: misma Idempotency-Key y cuerpo reordenado → mismo run`);
      const r3 = await api(token, "POST", "/api/runs", { ...payload, seed: 8 }, { "Idempotency-Key": key });
      check(r3.status === 409, `${policy}: misma clave con otro cuerpo → 409`, r3.body);
      runsByUser[u]!.push(r1.body.run_id);
    }

    for (const [i, runId] of runsByUser[u]!.entries()) {
      const policy = i === 0 ? "naive-v1" : "guarded-v1";
      const done = await waitRun(token, runId);
      check(done.run.status === "completed" && done.run.jobs_terminal === 4, `${policy}: run completado`, done.run);
      for (const job of done.jobs) {
        check(job.verdict === EXPECT[policy]![job.scenario_id], `${policy} × ${job.scenario_id} → ${job.verdict}`, job);
      }
      const exp = await api(token, "GET", `/api/runs/${runId}/export`);
      const ver = Object.values(exp.body.verification) as any[];
      check(ver.length === 4 && ver.every((v) => v.ok), `${policy}: export con 4 cadenas verificadas`, exp.body.verification);
    }

    // Detalle de un fallo: respuesta perdida con la política ingenua
    const naiveRun = await api(token, "GET", `/api/runs/${runsByUser[u]![0]}`);
    const lost = naiveRun.body.jobs.find((j: any) => j.scenario_id === "commit_ack_lost");
    const attempts = await api(token, "GET", `/api/jobs/${lost.id}/attempts`);
    const att = attempts.body.attempts[0];
    const detail = await api(token, "GET", `/api/attempts/${att.id}`);
    check(detail.body.effects.length === 2, "respuesta perdida: 2 efectos en el ledger", detail.body.effects);
    const once = detail.body.rule_results.find((r: any) => r.status === "violation" && r.category === "safety");
    check(!!once, "regla de seguridad violada con evidencia", detail.body.rule_results);
    const evs = await api(token, "GET", `/api/attempts/${att.id}/events?after_seq=0&limit=500`);
    const types = evs.body.events.map((e: any) => e.type);
    check(types[0] === "attempt.genesis" && types.includes("gateway.response_dropped") && types.at(-1) === "attempt.evaluated", "traza: génesis → respuesta perdida → evaluación", types);
    const agentView = await api(token, "GET", `/api/attempts/${att.id}/events?audience=agent`);
    check(agentView.body.events.some((e: any) => e.public_payload?.result?.error?.code === "TIMEOUT_UNKNOWN"), "el agente vio TIMEOUT_UNKNOWN");
    const page = await api(token, "GET", `/api/attempts/${att.id}/events?after_seq=3&limit=2`);
    check(page.body.events.length === 2 && page.body.events[0].seq === 4 && page.body.has_more, "paginación after_seq/limit");

    const wallet = await api(token, "GET", "/api/wallet");
    check(wallet.body.available_units === 0 && wallet.body.reserved_units === 0, "wallet: 8 unidades consumidas, 0 reservadas", wallet.body);
    const broke = await api(token, "POST", "/api/runs", { caseVersionId: kase.id, agentVersionId: agents[0].id, scenarioIds: ["baseline"] });
    check(broke.status === 402 && broke.body.error.code === "CREDITS_REQUIRED", "sin saldo → 402 CREDITS_REQUIRED", broke.body);
  }

  console.log("\nAislamiento entre workspaces");
  const foreign = await api(users.B!, "GET", `/api/runs/${runsByUser.A![0]}`);
  check(foreign.status === 404, "B no ve el run de A (404)");
  const foreignCancel = await api(users.B!, "POST", `/api/runs/${runsByUser.A![0]}/cancel`);
  check(foreignCancel.status === 404, "B no puede cancelar el run de A (404)", foreignCancel.body);
  const badId = await api(users.B!, "GET", "/api/runs/no-es-un-uuid");
  check(badId.status === 404, "ID mal formado → 404", badId.body);
  const foreignWs = await api(users.B!, "GET", "/api/me", undefined, { "X-Workspace-Id": randomUUID() });
  check(foreignWs.status === 404, "workspace ajeno en cabecera → 404");

  console.log("\nCancelación");
  const C = await signup("c");
  await api(C, "POST", "/api/bootstrap");
  const kc = (await api(C, "GET", "/api/cases")).body.cases.find((c: any) => c.domain_pack_versions.pack_id === "refunds");
  const ac = (await api(C, "GET", "/api/agent-versions")).body.agent_versions[0];
  const rc = await api(C, "POST", "/api/runs", { caseVersionId: kc.id, agentVersionId: ac.id, scenarioIds: SCENARIOS });
  const cancel = await api(C, "POST", `/api/runs/${rc.body.run_id}/cancel`);
  check(cancel.status === 200 && cancel.body.status === "cancelled", "cancelación aceptada", cancel.body);
  const fin = await waitRun(C, rc.body.run_id);
  const w = (await api(C, "GET", "/api/wallet")).body;
  const consumed = fin.jobs.filter((j: any) => j.status === "completed").length;
  check(fin.run.status === "cancelled" && w.reserved_units === 0 && w.available_units === 8 - consumed, `wallet coherente tras cancelar (consumidas ${consumed})`, { w, jobs: fin.jobs.map((j: any) => j.status) });

  console.log(failures === 0 ? "\nOK · prueba de punta a punta superada" : `\nFALLÓ · ${failures} comprobaciones`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(1); });
