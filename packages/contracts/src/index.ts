// PREMORTEM · contratos compartidos (spec v2 §6). Tipos + validación runtime con Zod.
import { z } from "zod";

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------
export type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
export type JsonObject = { [k: string]: Json };
export type JsonSchema = { [k: string]: Json };

export const JsonValue: z.ZodType<Json> = z.lazy(() =>
  z.union([
    z.null(),
    z.boolean(),
    z.number().refine(Number.isFinite, "número no finito"),
    z.string(),
    z.array(JsonValue),
    z.record(z.string(), JsonValue),
  ]),
);

export type VersionRef = { id: string; version: string; contentHash?: string };

// ---------------------------------------------------------------------------
// Herramientas y agente
// ---------------------------------------------------------------------------
export type ToolKind = "read" | "write";

export type ToolDefinition = {
  name: string;
  description: string;
  inputSchema: JsonSchema;
  outputSchema: JsonSchema;
  kind: ToolKind;
};

export type ToolCall = { callId: string; name: string; arguments: Json };

export type ToolError = { code: string; message: string; effectStatus: "none" | "unknown" };
export type ToolResult = { ok: true; data: Json } | { ok: false; error: ToolError };

export const AgentFinalSchema = z.object({
  outcome: z.enum(["completed", "blocked", "needs_clarification"]),
  reasonCode: z.string().max(80).nullable(),
  evidenceIds: z.array(z.string().max(200)).max(50),
  data: JsonValue,
});
export type AgentFinal = z.infer<typeof AgentFinalSchema>;

export type Limits = {
  maxToolCalls: number;
  maxDurationMs: number;
  maxTokens: number;
  maxModelResponses: number;
};

/** Entrada que recibe una política o adaptador de agente. No contiene oráculo, mutaciones ni estado. */
export type AgentSession = {
  instruction: string;
  publicContext: Json;
  tools: readonly ToolDefinition[];
  callTool: (name: string, args: Json) => Promise<ToolResult>;
  finish: (result: AgentFinal) => Promise<void>;
  limits: Limits;
  signal: AbortSignal;
  /** Metadatos observables del adaptador (sin texto libre): modelo, tokens, stop_reason. Se anexan a la traza. */
  note?: (type: string, payload: JsonObject) => void;
  /** Uso acumulado del proveedor (tokens, respuestas). */
  reportUsage?: (usage: JsonObject) => void;
};

export type ReferencePolicy = {
  id: string;
  label: string;
  description: string;
  run: (session: AgentSession) => Promise<void>;
};

// ---------------------------------------------------------------------------
// Dominio
// ---------------------------------------------------------------------------
export type EffectDraft = {
  type: string;
  logicalOperationId: string;
  resourceId: string;
  data: JsonObject;
};

export type Transition = {
  nextState: JsonObject;
  effects: EffectDraft[];
  result: ToolResult;
};

export type MutationTrigger =
  | { phase: "setup" }
  | { phase: "before_tool" | "after_effect"; tool: string; occurrence: number };

export type MutationSpec = {
  ref: { id: string; version: string };
  parameters: JsonObject;
  trigger: MutationTrigger;
};

export type RuleCategory = "safety" | "completion" | "honesty";
export type CheckStatus = "pass" | "violation" | "not_applicable" | "not_evaluated";

export type CheckResult = {
  ruleId: string;
  status: CheckStatus;
  category: RuleCategory;
  expected: Json;
  observed: Json;
  evidenceEventIds: string[];
  explanation: string;
};

export type RuleDefinition = { id: string; label: string; category: RuleCategory; required: boolean };

export type Termination = "finished" | "limit" | "provider_error" | "cancelled";

/** Evento tal como lo ve un evaluador (sin hashes). */
export type EventView = {
  eventId: string;
  seq: number;
  type: string;
  audience: "agent" | "inspector" | "system";
  payload: JsonObject;
};

/** Efecto confirmado tal como lo ve un evaluador. */
export type EffectView = {
  effectId: string;
  eventId: string;
  type: string;
  logicalOperationId: string;
  resourceId: string;
  data: JsonObject;
};

export type ToolSpec = {
  name: string;
  description: string;
  kind: ToolKind;
  input: z.ZodType<Json>;
};

export type ScenarioDefinition = { id: string; label: string; description: string; mutations: MutationSpec[] };

export type DemoCase = {
  label: string;
  fixtureVersion: string;
  task: JsonObject;            // { instruction, ...parámetros visibles }
  publicContext: JsonObject;   // contexto verificable consultable por el agente
  fixture: JsonObject;
  oracle: JsonObject;
};

/**
 * Paquete de dominio. Métodos puros: sin DB, red, reloj, filesystem ni secretos.
 * IDs y aleatoriedad se derivan de idNamespace / logicalTime que entrega el motor.
 */
export interface DomainPack {
  ref: { id: string; version: string };
  label: string;
  description: string;
  tools: readonly ToolSpec[];
  rules: readonly RuleDefinition[];
  scenarios: readonly ScenarioDefinition[];
  /** Mutaciones que el paquete acepta (incluidas las del motor, como engine.drop_response_after_commit). */
  supportedMutations: readonly { id: string; version: string }[];
  referencePolicies: Readonly<Record<string, ReferencePolicy>>;
  demoCases: readonly DemoCase[];

  /**
   * simulated (por defecto): métodos puros, sin red ni secretos.
   * external_sandbox: las herramientas actúan sobre un sandbox externo real (por ejemplo Stripe en modo prueba);
   * pueden ser asíncronas y el resultado no es determinista. Nunca producción.
   */
  environment?: "simulated" | "external_sandbox";
  /** Variables de entorno del servidor sin las cuales el paquete no puede ejecutarse (la API rechaza el run antes de reservar). */
  requiresEnv?: readonly string[];

  initialize(input: { fixture: JsonObject; task: JsonObject; publicContext: JsonObject; attemptId?: string }): JsonObject | Promise<JsonObject>;
  applyTool(input: {
    state: JsonObject;
    call: ToolCall;
    logicalOperationId: string;
    logicalTime: number;
    idNamespace: string;
    attemptId?: string;
  }): Transition | Promise<Transition>;
  /** Solo external_sandbox: concilia el estado final con la fuente de verdad externa antes de evaluar. */
  finalize?(input: { state: JsonObject; attemptId: string }): Promise<JsonObject>;
  mutate(input: { state: JsonObject; mutation: MutationSpec; logicalTime: number }): JsonObject;
  evaluate(input: {
    task: JsonObject;
    oracle: JsonObject;
    initialState: JsonObject;
    finalState: JsonObject;
    effects: readonly EffectView[];
    finalOutput: AgentFinal | null;
    events: readonly EventView[];
    termination: Termination;
  }): CheckResult[];
}

/** Mutaciones que implementa el propio motor, válidas en cualquier paquete que las declare. */
export const ENGINE_MUTATIONS = {
  dropResponseAfterCommit: { id: "engine.drop_response_after_commit", version: "1" },
} as const;

export type Verdict = "passed" | "safe_stop" | "failed" | "inconclusive";

// ---------------------------------------------------------------------------
// API HTTP (spec v2 §17)
// ---------------------------------------------------------------------------
export const LimitsInput = z
  .object({
    maxToolCalls: z.number().int().positive().optional(),
    maxDurationMs: z.number().int().positive().optional(),
    maxTokens: z.number().int().positive().optional(),
    maxModelResponses: z.number().int().positive().optional(),
  })
  .strict();

export const QuoteRunBody = z
  .object({
    projectId: z.string().uuid().optional(),
    caseVersionId: z.string().uuid(),
    agentVersionId: z.string().uuid(),
    scenarioIds: z.array(z.string().min(1).max(80)).min(1).max(32),
    repetitions: z.number().int().min(1).max(3).default(1),
    limits: LimitsInput.default({}),
  })
  .strict();

export const CreateRunBody = QuoteRunBody.extend({
  seed: z.number().int().min(0).max(2_147_483_647).default(1),
}).strict();

export const CreateAgentVersionBody = z.discriminatedUnion("driver", [
  z.object({
    label: z.string().min(1).max(120),
    driver: z.literal("reference"),
    policyId: z.string().min(1).max(80),
    config: z.record(z.string(), JsonValue).default({}),
  }).strict(),
  z.object({
    label: z.string().min(1).max(120),
    driver: z.literal("anthropic"),
    systemPrompt: z.string().min(1).max(20_000),
    model: z.string().min(1).max(100).optional(),
    parentAgentVersionId: z.string().uuid().optional(),
    config: z.record(z.string(), JsonValue).default({}),
  }).strict(),
]);

export type ApiError = { error: { code: string; message: string; detail?: string } };
