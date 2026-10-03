import { z } from "zod";
import { anthropicClientFromEnv, lineDiff, proposeImprovement, type Finding } from "@premortem/agents";
import { authed, body, HttpError, json, must, preflight } from "@/lib/server/api";
import { readPrompt } from "@/lib/server/prompts";

export const dynamic = "force-dynamic";
export const maxDuration = 120;
export const OPTIONS = preflight;

const Body = z.object({ runId: z.string().uuid() }).strict();
const AGENT_EVENTS = new Set(["tool.call", "tool.result", "agent.finish"]);

/** Tokens del caso que no deberían aparecer en un prompt general: IDs, emails, nombres propios, referencias. */
function caseTokens(values: unknown[]): string[] {
  const out = new Set<string>();
  const walk = (v: unknown) => {
    if (typeof v === "string") {
      if (/@|\d|_/.test(v) || /^\p{Lu}\p{L}+ \p{Lu}\p{L}+$/u.test(v)) if (v.length >= 4 && v.length <= 80) out.add(v);
    } else if (Array.isArray(v)) v.forEach(walk);
    else if (v && typeof v === "object") Object.values(v).forEach(walk);
  };
  values.forEach(walk);
  return [...out];
}

/**
 * Propone una versión corregida del prompt a partir de la evidencia de un run. No crea la versión:
 * el usuario revisa el diff y la crea con POST /api/agent-versions (parentAgentVersionId).
 * El modelo propone; nunca decide veredictos.
 */
export const POST = authed(async (ctx, p) => {
  const { runId } = Body.parse(await body(ctx.req));
  const { data: agentRow } = await ctx.sb.from("agent_versions").select("id, driver, model_id, label").eq("id", p.id!).maybeSingle();
  const agent = must(agentRow, "Versión de agente") as any;
  if (agent.driver === "reference") throw new HttpError(409, "DRIVER_NOT_EDITABLE", "Las políticas de referencia son código; no tienen prompt que mejorar");
  const { data: runRow } = await ctx.sb.from("runs").select("id, agent_version_id, case_version_id, manifest, status").eq("id", runId).maybeSingle();
  const run = must(runRow, "Run") as any;
  if (run.agent_version_id !== agent.id) throw new HttpError(409, "RUN_AGENT_MISMATCH", "El run no se ejecutó con esta versión de agente");
  if (run.status !== "completed") throw new HttpError(409, "RUN_NOT_COMPLETED", "Espera a que el run termine");

  const client = anthropicClientFromEnv();
  if (!client) throw new HttpError(503, "MODEL_NOT_CONFIGURED", "Falta ANTHROPIC_API_KEY en el servidor");

  const { data: jobs } = await ctx.sb.from("world_jobs").select("id, scenario_id, verdict, active_attempt_id").eq("run_id", runId).order("ordinal");
  const failing = (jobs ?? []).filter((j: any) => j.verdict === "failed" || j.verdict === "inconclusive");
  const currentPrompt = (await readPrompt(ctx.workspaceId, ctx.userId, agent.id, "improve")) ?? "";
  if (failing.length === 0) {
    return json(ctx.req, { current_prompt: currentPrompt, proposal: null, diff: [], based_on: { run_id: runId, failed_jobs: 0 }, message: "No hay fallos que corregir en este run." });
  }

  const scenarios = run.manifest?.scenarios ?? {};
  const findings: Finding[] = [];
  const traceValues: unknown[] = [];
  for (const j of failing) {
    const [{ data: rules }, { data: events }] = await Promise.all([
      ctx.sb.from("rule_results").select("rule_id, status, category, expected, observed, explanation").eq("attempt_id", j.active_attempt_id).eq("status", "violation"),
      ctx.sb.from("attempt_events").select("seq, type, audience, public_payload").eq("attempt_id", j.active_attempt_id).eq("audience", "agent").order("seq"),
    ]);
    const agentTrace = (events ?? []).filter((e: any) => AGENT_EVENTS.has(e.type)).map((e: any) => ({ seq: e.seq, type: e.type, payload: e.public_payload }));
    traceValues.push(agentTrace.map((t) => t.payload));
    findings.push({
      scenario: scenarios[j.scenario_id]?.label ?? j.scenario_id,
      verdict: j.verdict,
      violations: (rules ?? []).map((r: any) => ({ rule_id: r.rule_id, category: r.category, explanation: r.explanation, expected: r.expected, observed: r.observed })),
      agentTrace,
    });
  }
  const { data: kase } = await ctx.sb.from("case_versions").select("task, public_context").eq("id", run.case_version_id).maybeSingle();
  const tokens = caseTokens([kase?.public_context, ...traceValues]);

  const proposal = await proposeImprovement({
    client, model: process.env.PREMORTEM_COACH_MODEL ?? agent.model_id ?? process.env.ANTHROPIC_MODEL!,
    currentPrompt, findings, caseTokens: tokens,
  });
  return json(ctx.req, {
    current_prompt: currentPrompt,
    proposal,
    diff: lineDiff(currentPrompt, proposal.systemPrompt),
    based_on: { run_id: runId, failed_jobs: failing.length, scenarios: failing.map((j: any) => j.scenario_id) },
  });
});
