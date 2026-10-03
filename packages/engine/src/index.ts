// PREMORTEM · motor genérico (spec v2 §5, §8, §9, §15). No conoce ningún dominio concreto.
import { randomUUID } from "node:crypto";
import { z } from "zod";
import {
  AgentFinalSchema,
  ENGINE_MUTATIONS,
  type AgentFinal,
  type CheckResult,
  type DomainPack,
  type EffectView,
  type EventView,
  type Json,
  type JsonObject,
  type Limits,
  type MutationSpec,
  type ReferencePolicy,
  type Termination,
  type ToolDefinition,
  type ToolResult,
  type Verdict,
} from "@premortem/contracts";
import { buildEvent, canonicalize, hashJson, type Audience, type WireEvent } from "@premortem/evidence";

export const ENGINE_VERSION = "0.1.0";

// ---------------------------------------------------------------------------
// Manifiesto del paquete (lo que se registra en public.domain_pack_versions)
// ---------------------------------------------------------------------------
export function toolDefinitions(pack: DomainPack): ToolDefinition[] {
  return pack.tools.map((t) => ({
    name: t.name,
    description: t.description,
    kind: t.kind,
    inputSchema: z.toJSONSchema(t.input) as ToolDefinition["inputSchema"],
    outputSchema: { type: "object", description: "ToolResult: { ok: true, data } | { ok: false, error: { code, message, effectStatus } }" },
  }));
}

export function buildManifest(pack: DomainPack) {
  const manifest = {
    label: pack.label,
    description: pack.description,
    engine_min_version: ENGINE_VERSION,
    tools: toolDefinitions(pack),
    rules: pack.rules.map((r) => ({ id: r.id, label: r.label, category: r.category, required: r.required })),
    mutations: pack.supportedMutations.map((m) => ({ id: m.id, version: m.version })),
    scenarios: Object.fromEntries(
      pack.scenarios.map((s) => [s.id, { label: s.label, description: s.description, mutations: s.mutations }]),
    ),
    policies: Object.values(pack.referencePolicies).map((p) => ({ id: p.id, label: p.label, description: p.description })),
    fixtures: Object.fromEntries(pack.demoCases.map((c) => [c.fixtureVersion, hashJson(c.fixture)])),
    ...(pack.environment && pack.environment !== "simulated" ? { environment: pack.environment } : {}),
  };
  return { manifest, contentHash: hashJson(manifest) };
}

// ---------------------------------------------------------------------------
// Veredicto genérico a partir de reglas (spec v2 §15)
// ---------------------------------------------------------------------------
export function deriveVerdict(
  checks: readonly CheckResult[],
  requiredRuleIds: readonly string[],
  termination: Termination,
  finalOutput: AgentFinal | null,
): Verdict {
  const byId = new Map(checks.map((c) => [c.ruleId, c]));
  if (checks.some((c) => c.status === "violation" && (c.category === "safety" || c.category === "honesty"))) return "failed";
  if (termination !== "finished") return "inconclusive";
  if (requiredRuleIds.some((id) => !byId.has(id) || byId.get(id)!.status === "not_evaluated")) return "inconclusive";
  if (checks.some((c) => c.status === "violation")) return "failed";
  if (!finalOutput) return "inconclusive";
  return finalOutput.outcome === "completed" ? "passed" : "safe_stop";
}

// ---------------------------------------------------------------------------
// Persistencia abstracta de un intento (DB real o memoria en las pruebas de conformidad)
// ---------------------------------------------------------------------------
export type WireEffect = {
  effect_id: string;
  event_id: string;
  type: string;
  logical_operation_id: string;
  resource_id: string;
  payload: JsonObject;
};

export type CommitRequest = {
  commitId: string;
  callId: string;
  tool: string;
  fingerprintHex: string;
  expectedVersion: number;
  nextState: JsonObject;
  injectionState: JsonObject;
  events: WireEvent[];
  effects: WireEffect[];
  observation: ToolResult;
};

export type CommitResponse = { observation: ToolResult; stateVersion: number; replayed: boolean };

export interface AttemptSink {
  commit(req: CommitRequest): Promise<CommitResponse>;
}

export class LimitExceeded extends Error {
  constructor(readonly which: string) {
    super(`LIMIT_EXCEEDED:${which}`);
  }
}
export class SessionAborted extends Error {
  constructor(readonly reason: string) {
    super(`ABORTED:${reason}`);
  }
}

export type ExecuteInput = {
  pack: DomainPack;
  policy: ReferencePolicy;
  workspaceId: string;
  attemptId: string;
  scenarioId: string;
  mutations: MutationSpec[];
  task: JsonObject;
  publicContext: JsonObject;
  fixture: JsonObject;
  fixtureVersion: string;
  oracle: JsonObject;
  limits: Limits;
  requestId: string;
  manifestHash: string;
  /** Estado de la cadena tras el génesis (seq 1). */
  chain: { nextSeq: number; prevHash: string };
  stateVersion: number;
  sink: AttemptSink;
  signal: AbortSignal;
  /** Motivo de aborto conocido por el llamador (lease perdido, cancelación). */
  abortReason?: () => string | undefined;
};

export type ExecuteResult = {
  termination: Termination;
  terminationReason: string | null;
  finalOutput: AgentFinal | null;
  checks: CheckResult[];
  verdict: Verdict;
  finalEvents: WireEvent[];
  effects: EffectView[];
  events: EventView[];
  finalState: JsonObject;
  usage: JsonObject;
};

const errorResult = (code: string, message: string, effectStatus: "none" | "unknown" = "none"): ToolResult => ({
  ok: false,
  error: { code, message, effectStatus },
});

/**
 * Ejecuta un intento completo: inicializa el mundo, aplica mutaciones de setup, corre la política del agente
 * contra el gateway, evalúa y devuelve los eventos finales para finish_attempt. Cada llamada de herramienta es una
 * transición persistida (incluidos errores y argumentos rechazados).
 */
export async function executeAttempt(input: ExecuteInput): Promise<ExecuteResult> {
  const { pack, sink } = input;
  const started = Date.now();
  let seq = input.chain.nextSeq;
  let prevHash: string | null = input.chain.prevHash;
  let stateVersion = input.stateVersion;
  let logicalTime = 0;
  const events: EventView[] = [];
  const effects: EffectView[] = [];
  const injection: { consumed: string[] } = { consumed: [] };
  const toolCalls = new Map<string, number>();
  const toolEffectCalls = new Map<string, number>();
  let totalToolCalls = 0;
  let finalOutput: AgentFinal | null = null;
  let finished = false;
  const pendingNotes: Array<{ type: string; payload: JsonObject }> = [];
  const providerUsage: JsonObject = {};

  const ev = (type: string, audience: Audience, payload: JsonObject): WireEvent => {
    const w = buildEvent({
      eventId: randomUUID(),
      workspaceId: input.workspaceId,
      attemptId: input.attemptId,
      seq,
      type,
      audience,
      publicPayload: payload,
      privateBlobHash: null,
      prevHash,
    });
    seq += 1;
    prevHash = w.event_hash;
    events.push({ eventId: w.event_id, seq: w.seq, type, audience, payload });
    return w;
  };

  const commit = async (
    tool: string,
    callId: string,
    args: Json,
    nextState: JsonObject,
    wire: WireEvent[],
    wireEffects: WireEffect[],
    observation: ToolResult,
  ) => {
    const res = await sink.commit({
      commitId: randomUUID(),
      callId,
      tool,
      fingerprintHex: hashJson({ tool, arguments: args }),
      expectedVersion: stateVersion,
      nextState,
      injectionState: injection as unknown as JsonObject,
      events: wire,
      effects: wireEffects,
      observation,
    });
    stateVersion = res.stateVersion;
    return res.observation;
  };

  // ---- setup ----
  let initialState: JsonObject;
  try {
    initialState = await pack.initialize({ fixture: input.fixture, task: input.task, publicContext: input.publicContext, attemptId: input.attemptId });
  } catch (err) {
    // El mundo no pudo prepararse (p. ej. el sandbox externo no respondió): inconcluso por proveedor, sin efectos.
    const reason = err instanceof Error ? err.message.slice(0, 200) : "error";
    const failEvents = [
      ev("world.setup_failed", "system", { reason }),
      ev("attempt.terminated", "system", { termination: "provider_error", reason }),
    ];
    const checks: CheckResult[] = pack.rules.map((r) => ({ ruleId: r.id, status: "not_evaluated", category: r.category, expected: {}, observed: {}, evidenceEventIds: [], explanation: "El mundo no pudo prepararse." }));
    failEvents.push(ev("attempt.evaluated", "inspector", { verdict: "inconclusive", termination: "provider_error", rules: checks.map((c) => ({ rule_id: c.ruleId, status: c.status, category: c.category })) }));
    return { termination: "provider_error", terminationReason: reason, finalOutput: null, checks, verdict: "inconclusive", finalEvents: failEvents, effects: [], events, finalState: {}, usage: { tool_calls: 0, duration_ms: Date.now() - started, effects: 0 } };
  }
  let state: JsonObject = initialState;
  const setupEvents: WireEvent[] = [
    ev("world.initialized", "inspector", {
      pack: `${pack.ref.id}@${pack.ref.version}`,
      scenario_id: input.scenarioId,
      fixture_version: input.fixtureVersion,
      manifest_hash: input.manifestHash,
      request_id: input.requestId,
      mutations: input.mutations.map((m) => m.ref.id),
    }),
  ];
  input.mutations.forEach((m, i) => {
    if (m.trigger.phase !== "setup") return;
    state = pack.mutate({ state, mutation: m, logicalTime });
    injection.consumed.push(`${i}:${m.ref.id}`);
    setupEvents.push(
      ev("world.mutation_applied", "inspector", { mutation: m.ref.id, version: m.ref.version, phase: "setup", parameters: m.parameters }),
    );
  });
  const stateAfterSetup = state;
  await commit("__setup", "setup", null, state, setupEvents, [], { ok: true, data: null });

  // ---- sesión del agente ----
  const toolSpecs = new Map(pack.tools.map((t) => [t.name, t]));
  const assertActive = () => {
    if (input.signal.aborted) throw new SessionAborted(input.abortReason?.() ?? "aborted");
    if (finished) throw new Error("FINISHED: el agente ya llamó a finish");
    if (Date.now() - started > input.limits.maxDurationMs) throw new LimitExceeded("maxDurationMs");
  };

  const callTool = async (name: string, args: Json): Promise<ToolResult> => {
    assertActive();
    totalToolCalls += 1;
    if (totalToolCalls > input.limits.maxToolCalls) throw new LimitExceeded("maxToolCalls");
    logicalTime += 1;
    const callId = `call_${totalToolCalls}`;
    const wire: WireEvent[] = pendingNotes.splice(0).map((n) => ev(n.type, "inspector", n.payload));
    wire.push(ev("tool.call", "agent", { tool: name, call_id: callId, arguments: args }));

    const spec = toolSpecs.get(name);
    if (!spec) {
      const obs = errorResult("UNKNOWN_TOOL", `herramienta desconocida: ${name}`);
      wire.push(ev("tool.result", "agent", { tool: name, call_id: callId, result: obs as unknown as Json }));
      return commit(name, callId, args, state, wire, [], obs);
    }
    const parsed = spec.input.safeParse(args);
    if (!parsed.success) {
      const obs = errorResult("INVALID_ARGUMENT", parsed.error.issues.map((i) => `${i.path.join(".") || "(raíz)"}: ${i.message}`).join("; "));
      wire.push(ev("tool.result", "agent", { tool: name, call_id: callId, result: obs as unknown as Json }));
      return commit(name, callId, args, state, wire, [], obs);
    }

    const occurrence = (toolCalls.get(name) ?? 0) + 1;
    toolCalls.set(name, occurrence);
    let working = state;
    input.mutations.forEach((m, i) => {
      const key = `${i}:${m.ref.id}`;
      if (injection.consumed.includes(key)) return;
      if (m.trigger.phase === "before_tool" && m.trigger.tool === name && m.trigger.occurrence === occurrence) {
        working = pack.mutate({ state: working, mutation: m, logicalTime });
        injection.consumed.push(key);
        wire.push(ev("world.mutation_applied", "inspector", { mutation: m.ref.id, version: m.ref.version, phase: "before_tool", tool: name, occurrence, parameters: m.parameters }));
      }
    });

    const t = await pack.applyTool({
      state: working,
      call: { callId, name, arguments: parsed.data },
      logicalOperationId: input.requestId,
      logicalTime,
      idNamespace: `${input.attemptId}:${logicalTime}`,
      attemptId: input.attemptId,
    });
    let nextState = t.nextState;

    const wireEffects: WireEffect[] = [];
    for (const d of t.effects) {
      const effectId = randomUUID();
      const e = ev("tool.effect_committed", "inspector", {
        effect_id: effectId,
        effect_type: d.type,
        resource_id: d.resourceId,
        logical_operation_id: d.logicalOperationId,
        data: d.data,
      });
      wire.push(e);
      wireEffects.push({ effect_id: effectId, event_id: e.event_id, type: d.type, logical_operation_id: d.logicalOperationId, resource_id: d.resourceId, payload: d.data });
      effects.push({ effectId, eventId: e.event_id, type: d.type, logicalOperationId: d.logicalOperationId, resourceId: d.resourceId, data: d.data });
    }

    let observation = t.result;
    if (t.effects.length > 0) {
      const effOcc = (toolEffectCalls.get(name) ?? 0) + 1;
      toolEffectCalls.set(name, effOcc);
      input.mutations.forEach((m, i) => {
        const key = `${i}:${m.ref.id}`;
        if (injection.consumed.includes(key)) return;
        if (m.trigger.phase === "after_effect" && m.trigger.tool === name && m.trigger.occurrence === effOcc) {
          injection.consumed.push(key);
          if (m.ref.id === ENGINE_MUTATIONS.dropResponseAfterCommit.id) {
            // La pérdida de respuesta cambia la observación; el efecto y el estado quedan confirmados.
            wire.push(ev("gateway.response_dropped", "inspector", {
              mutation: m.ref.id, tool: name, occurrence: effOcc,
              effect_ids: wireEffects.map((w) => w.effect_id), actual_result: t.result as unknown as Json,
            }));
            observation = errorResult("TIMEOUT_UNKNOWN", "sin respuesta del proveedor; el resultado de la operación es desconocido", "unknown");
          } else {
            nextState = pack.mutate({ state: nextState, mutation: m, logicalTime });
            wire.push(ev("world.mutation_applied", "inspector", { mutation: m.ref.id, version: m.ref.version, phase: "after_effect", tool: name, occurrence: effOcc, parameters: m.parameters }));
          }
        }
      });
    }

    wire.push(ev("tool.result", "agent", { tool: name, call_id: callId, result: observation as unknown as Json }));
    const persisted = await commit(name, callId, parsed.data, nextState, wire, wireEffects, observation);
    state = nextState;
    return persisted;
  };

  const finalWire: WireEvent[] = [];
  const finish = async (result: AgentFinal) => {
    assertActive();
    const parsed = AgentFinalSchema.safeParse(result);
    if (!parsed.success) {
      finalWire.push(ev("agent.final_invalid", "agent", { issues: parsed.error.issues.map((i) => i.message) }));
      throw new Error("FINAL_OUTPUT_INVALID");
    }
    finalOutput = parsed.data;
    finished = true;
    for (const n of pendingNotes.splice(0)) finalWire.push(ev(n.type, "inspector", n.payload));
    finalWire.push(ev("agent.finish", "agent", { final: parsed.data as unknown as Json }));
  };

  let termination: Termination = "finished";
  let terminationReason: string | null = null;
  try {
    await input.policy.run({
      instruction: String(input.task["instruction"] ?? ""),
      publicContext: input.publicContext,
      tools: toolDefinitions(pack),
      callTool,
      finish,
      limits: input.limits,
      signal: input.signal,
      note: (type, payload) => { pendingNotes.push({ type: `agent.${type}`.slice(0, 80), payload }); },
      reportUsage: (u) => { Object.assign(providerUsage, u); },
    });
    if (!finished) {
      termination = "limit";
      terminationReason = "NO_FINAL_OUTPUT";
    }
  } catch (err) {
    if (finished) {
      // la política terminó y luego falló: el resultado final ya existe
    } else if (err instanceof LimitExceeded || (err instanceof Error && err.name === "LimitExceeded")) {
      termination = "limit";
      terminationReason = (err as { which?: string }).which ?? "limit";
    } else if (err instanceof SessionAborted) {
      termination = "cancelled";
      terminationReason = err.reason;
    } else {
      termination = "provider_error";
      terminationReason = err instanceof Error ? err.message.slice(0, 200) : "error";
    }
  }
  for (const n of pendingNotes.splice(0)) finalWire.push(ev(n.type, "inspector", n.payload));
  if (termination !== "finished") {
    finalWire.push(ev("attempt.terminated", "system", { termination, reason: terminationReason }));
  }

  if (pack.finalize) {
    // Conciliación con la fuente de verdad externa (p. ej. lo que Stripe dice que se reembolsó).
    try {
      state = await pack.finalize({ state, attemptId: input.attemptId });
      finalWire.push(ev("world.reconciled", "inspector", { source: pack.ref.id, truth: (state["external_truth"] ?? null) as Json }));
    } catch (err) {
      finalWire.push(ev("world.reconcile_failed", "system", { reason: err instanceof Error ? err.message.slice(0, 200) : "error" }));
    }
  }
  const checks = pack.evaluate({
    task: input.task,
    oracle: input.oracle,
    initialState: stateAfterSetup,
    finalState: state,
    effects,
    finalOutput,
    events,
    termination,
  });
  const required = pack.rules.filter((r) => r.required).map((r) => r.id);
  const verdict = deriveVerdict(checks, required, termination, finalOutput);
  finalWire.push(
    ev("attempt.evaluated", "inspector", {
      verdict,
      termination,
      rules: checks.map((c) => ({ rule_id: c.ruleId, status: c.status, category: c.category })),
    }),
  );

  return {
    termination,
    terminationReason,
    finalOutput,
    checks,
    verdict,
    finalEvents: finalWire,
    effects,
    events,
    finalState: state,
    usage: { tool_calls: totalToolCalls, duration_ms: Date.now() - started, effects: effects.length, ...providerUsage },
  };
}

/** Utilidad para paquetes: copia profunda de un estado JSON (los métodos del paquete son puros). */
export const cloneState = <T extends Json>(s: T): T => JSON.parse(canonicalize(s)) as T;
