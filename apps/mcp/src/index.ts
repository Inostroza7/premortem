// PREMORTEM · servidor MCP (stdio). Reutiliza la API HTTP con la sesión de un usuario; nunca usa credenciales
// de servidor. Logs a stderr: stdout es el canal del protocolo.
//   Autenticación: PREMORTEM_EMAIL + PREMORTEM_PASSWORD (refresco automático) o PREMORTEM_ACCESS_TOKEN.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { loadEnv, requireEnv } from "@premortem/config";

loadEnv();
const API = process.env.PREMORTEM_API_URL ?? "http://localhost:3000";
const log = (...a: unknown[]) => console.error("[premortem-mcp]", ...a);

const supabase = createClient(requireEnv("NEXT_PUBLIC_SUPABASE_URL"), requireEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY"), {
  auth: { persistSession: false, autoRefreshToken: true },
});
let signedIn = false;
async function token(): Promise<string> {
  if (process.env.PREMORTEM_ACCESS_TOKEN) return process.env.PREMORTEM_ACCESS_TOKEN;
  if (!signedIn) {
    const { error } = await supabase.auth.signInWithPassword({ email: requireEnv("PREMORTEM_EMAIL"), password: requireEnv("PREMORTEM_PASSWORD") });
    if (error) throw new Error(`No se pudo iniciar sesión en PREMORTEM: ${error.message}`);
    signedIn = true;
  }
  const { data } = await supabase.auth.getSession();
  if (!data.session) throw new Error("Sesión de PREMORTEM no disponible");
  return data.session.access_token;
}

async function api(method: string, path: string, body?: unknown) {
  const r = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${await token()}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const j = (await r.json().catch(() => null)) as any;
  if (!r.ok) throw new Error(`${r.status} ${j?.error?.code ?? "ERROR"}: ${j?.error?.message ?? ""}${j?.error?.detail ? ` (${j.error.detail})` : ""}`);
  return j;
}

const text = (t: string) => ({ content: [{ type: "text" as const, text: t }] });
const LABEL: Record<string, string> = { passed: "✅ aprobado", safe_stop: "🛑 detención correcta", failed: "❌ fallo", inconclusive: "⚠️ inconcluso" };

const server = new McpServer({ name: "premortem", version: "0.1.0" });

server.registerTool("premortem_catalog", {
  title: "Catálogo de PREMORTEM",
  description: "Lista paquetes de dominio con sus escenarios, casos de prueba, versiones de agente y saldo de unidades. Úsalo primero.",
  inputSchema: {},
}, async () => {
  const [me, packs, cases, agents] = await Promise.all([api("GET", "/api/me"), api("GET", "/api/domain-packs"), api("GET", "/api/cases"), api("GET", "/api/agent-versions")]);
  const lines = [
    `Saldo: ${me.wallet.available_units} unidades disponibles (1 unidad = 1 mundo).`,
    "", "Paquetes:",
    ...packs.domain_packs.map((p: any) => `- ${p.pack_id}@${p.version}: escenarios ${Object.entries(p.manifest.scenarios).map(([id, s]: any) => `${id} (${s.label})`).join(", ")}`),
    "", "Casos:",
    ...cases.cases.map((c: any) => `- ${c.id} · ${c.label} [${c.domain_pack_versions.pack_id}]`),
    "", "Versiones de agente:",
    ...agents.agent_versions.map((a: any) => `- ${a.id} · ${a.label} · ${a.driver}${a.model_id ? ` (${a.model_id})` : ""}`),
  ];
  return text(lines.join("\n"));
});

server.registerTool("premortem_create_agent", {
  title: "Registrar versión de agente",
  description: "Registra una versión inmutable de un agente definido por su prompt de sistema. Devuelve su id para evaluarla. El prompt se guarda cifrado.",
  inputSchema: {
    label: z.string().min(1).max(120),
    systemPrompt: z.string().min(1).max(20000),
    model: z.string().optional().describe("Modelo de Claude; por defecto el configurado en el servidor"),
    parentAgentVersionId: z.string().uuid().optional().describe("Versión de la que deriva, para el historial"),
  },
}, async (a) => {
  const r = await api("POST", "/api/agent-versions", { driver: "anthropic", ...a });
  return text(`Versión registrada: ${r.id} (modelo ${r.model}).`);
});

server.registerTool("premortem_evaluate", {
  title: "Evaluar agente en mundos adversos",
  description: "Cotiza y lanza una evaluación. Requiere maxUnits: si la evaluación cuesta más, no se lanza. No compra unidades.",
  inputSchema: {
    caseVersionId: z.string().uuid(),
    agentVersionId: z.string().uuid(),
    scenarioIds: z.array(z.string()).optional().describe("Por defecto, todos los escenarios del paquete"),
    repetitions: z.number().int().min(1).max(3).optional(),
    maxUnits: z.number().int().min(1).describe("Máximo de unidades que autorizas gastar"),
  },
}, async (a) => {
  let scenarioIds = a.scenarioIds;
  if (!scenarioIds?.length) {
    const cases = await api("GET", "/api/cases");
    const c = cases.cases.find((x: any) => x.id === a.caseVersionId);
    const packs = await api("GET", "/api/domain-packs");
    const pack = packs.domain_packs.find((p: any) => p.id === c?.domain_pack_version_id);
    scenarioIds = Object.keys(pack?.manifest?.scenarios ?? {});
  }
  const body = { caseVersionId: a.caseVersionId, agentVersionId: a.agentVersionId, scenarioIds, repetitions: a.repetitions ?? 1 };
  const q = await api("POST", "/api/run-quotes", body);
  if (q.units_required > a.maxUnits) return text(`No lanzado: cuesta ${q.units_required} unidades y autorizaste ${a.maxUnits}.`);
  if (!q.affordable) return text(`No lanzado: cuesta ${q.units_required} unidades y hay ${q.units_available} disponibles.`);
  const r = await api("POST", "/api/runs", { ...body, seed: 7 });
  return text(`Evaluación lanzada: run ${r.run_id} · ${r.jobs_total} mundos · ${q.units_required} unidades reservadas. Usa premortem_report con wait=true.`);
});

server.registerTool("premortem_report", {
  title: "Reporte de evaluación",
  description: "Estado y resultados de un run: veredicto por mundo, reglas violadas con explicación y evidencia. Con wait=true espera hasta 3 minutos a que termine.",
  inputSchema: { runId: z.string().uuid(), wait: z.boolean().optional() },
}, async ({ runId, wait }) => {
  let r = await api("GET", `/api/runs/${runId}`);
  const t0 = Date.now();
  const done = (x: any) => x.run.status === "completed" || (x.run.status === "cancelled" && x.jobs.every((j: any) => !["queued", "running"].includes(j.status)));
  while (wait && !done(r) && Date.now() - t0 < 180_000) { await new Promise((s) => setTimeout(s, 2000)); r = await api("GET", `/api/runs/${runId}`); }
  const scen = r.run.manifest?.scenarios ?? {};
  const lines = [
    `Run ${runId} · ${r.run.status} · ${r.run.jobs_terminal}/${r.run.jobs_total} mundos`,
    `Aprobados ${r.run.jobs_passed} · detenciones correctas ${r.run.jobs_safe_stop} · fallos ${r.run.jobs_failed} · inconclusos ${r.run.jobs_inconclusive}`, "",
  ];
  for (const j of r.jobs) {
    lines.push(`${LABEL[j.verdict] ?? j.status} · ${scen[j.scenario_id]?.label ?? j.scenario_id}`);
    if (j.active_attempt_id && (j.verdict === "failed" || j.verdict === "inconclusive")) {
      const at = await api("GET", `/api/attempts/${j.active_attempt_id}`);
      for (const v of at.rule_results.filter((x: any) => x.status === "violation")) {
        lines.push(`   ✗ ${v.rule_id}: ${v.explanation} Esperado ${JSON.stringify(v.expected)} · observado ${JSON.stringify(v.observed)}`);
      }
      if (at.attempt.termination !== "finished") lines.push(`   motivo de cierre: ${at.attempt.termination}`);
    }
  }
  return text(lines.join("\n"));
});

server.registerTool("premortem_suggest_fix", {
  title: "Proponer corrección del prompt",
  description: "A partir de los fallos de un run, propone un prompt corregido con reglas generales y su diff. No crea la versión: revisa y usa premortem_create_agent.",
  inputSchema: { agentVersionId: z.string().uuid(), runId: z.string().uuid() },
}, async ({ agentVersionId, runId }) => {
  const r = await api("POST", `/api/agent-versions/${agentVersionId}/improve`, { runId });
  if (!r.proposal) return text(r.message ?? "Sin fallos que corregir.");
  const diff = r.diff.filter((d: any) => d.op !== "=").map((d: any) => `${d.op} ${d.line}`).join("\n");
  return text([
    `Cambios propuestos (${r.based_on.failed_jobs} mundos con fallo):`,
    ...r.proposal.changes.map((c: any) => `- [${c.rule_id}] ${c.scenario}: ${c.change}`),
    ...(r.proposal.overfittingWarnings.length ? ["", "Avisos de sobreajuste:", ...r.proposal.overfittingWarnings.map((w: string) => `- ${w}`)] : []),
    "", "Diff:", diff, "", "Prompt propuesto completo:", r.proposal.systemPrompt,
  ].join("\n"));
});

server.registerTool("premortem_compare", {
  title: "Comparar dos evaluaciones",
  description: "Compara dos runs mundo a mundo e indica si la comparación es válida (solo cambió el agente).",
  inputSchema: { runA: z.string().uuid(), runB: z.string().uuid() },
}, async ({ runA, runB }) => {
  const r = await api("GET", `/api/compare?a=${runA}&b=${runB}`);
  return text([
    r.comparable ? "Comparación válida: solo cambió el agente." : `Comparación NO controlada: difieren ${r.differences.join(", ")}.`,
    `A: ${JSON.stringify(r.a.summary)} · B: ${JSON.stringify(r.b.summary)}`, "",
    ...r.matrix.map((m: any) => `${m.label}: ${LABEL[m.a] ?? m.a} → ${LABEL[m.b] ?? m.b} (${m.change})`),
  ].join("\n"));
});

await server.connect(new StdioServerTransport());
log(`conectado a ${API}`);
