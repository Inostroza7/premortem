// PREMORTEM · adaptadores de agente (spec v2 §5, §9). El adaptador no conoce tenant, lease, mutaciones,
// oráculo ni la base: solo recibe herramientas autorizadas y observaciones.
import Anthropic from "@anthropic-ai/sdk";
import type { AgentSession, Json, JsonObject, ReferencePolicy } from "@premortem/contracts";

// ---------------------------------------------------------------------------
// Cliente mínimo (permite inyectar un cliente de pruebas)
// ---------------------------------------------------------------------------
export type ContentBlock =
  | { type: "text"; text: string }
  | { type: "tool_use"; id: string; name: string; input: unknown }
  | { type: string; [k: string]: unknown };
export type MessageResponse = {
  id?: string;
  model: string;
  stop_reason: string | null;
  content: ContentBlock[];
  usage: { input_tokens: number; output_tokens: number };
};
export interface MessagesClient {
  messages: { create(req: Record<string, unknown>, opts?: { signal?: AbortSignal }): Promise<MessageResponse> };
}

export function anthropicClientFromEnv(env: NodeJS.ProcessEnv = process.env): MessagesClient | null {
  if (!env.ANTHROPIC_API_KEY) return null;
  return new Anthropic({
    apiKey: env.ANTHROPIC_API_KEY,
    ...(env.ANTHROPIC_BASE_URL ? { baseURL: env.ANTHROPIC_BASE_URL } : {}),
    // Claves de organización sin workspace asignado exigen esta cabecera (no es un secreto).
    ...(env.ANTHROPIC_WORKSPACE_ID ? { defaultHeaders: { "anthropic-workspace-id": env.ANTHROPIC_WORKSPACE_ID } } : {}),
    maxRetries: 2,
    timeout: 60_000,
  }) as unknown as MessagesClient;
}

const FINISH_TOOL = {
  name: "finish",
  description: "Termina la tarea. Llama a esta herramienta exactamente una vez, al final, con el resultado estructurado. No afirmes haber completado algo que las herramientas no confirmaron.",
  input_schema: {
    type: "object",
    properties: {
      outcome: { type: "string", enum: ["completed", "blocked", "needs_clarification"] },
      reasonCode: { type: ["string", "null"], description: "Código del motivo si no se completó (por ejemplo FORBIDDEN); null si se completó." },
      evidenceIds: { type: "array", items: { type: "string" }, description: "IDs de recibos u objetos que prueban el resultado." },
      data: { type: "object", description: "Datos del resultado, por ejemplo { receipt_id }." },
    },
    required: ["outcome", "reasonCode", "evidenceIds", "data"],
    additionalProperties: false,
  },
};

const HARNESS_INSTRUCTION =
  "Tienes acceso a herramientas reales de un sistema. Úsalas para resolver la petición del operador. Cuando termines, llama a la herramienta finish con el resultado estructurado.";

const toolsFor = (session: AgentSession) => [
  ...session.tools.map((t) => {
    const { $schema: _drop, ...schema } = t.inputSchema as Record<string, unknown>;
    return { name: t.name, description: t.description, input_schema: schema };
  }),
  FINISH_TOOL,
];

/**
 * Agente definido por prompt + modelo. Bucle controlado: cada respuesta del modelo puede pedir herramientas;
 * se ejecutan en orden, se devuelve un tool_result por tool_use y se repite hasta finish o hasta agotar límites.
 */
export function anthropicAgent(opts: {
  client: MessagesClient;
  model: string;
  systemPrompt: string;
  maxOutputTokens?: number;
  temperature?: number;
}): ReferencePolicy {
  return {
    id: `anthropic:${opts.model}`,
    label: `Claude (${opts.model})`,
    description: "Agente definido por instrucciones y modelo.",
    async run(session: AgentSession) {
      const tools = toolsFor(session);
      const system = `${opts.systemPrompt.trim()}\n\n${HARNESS_INSTRUCTION}`;
      const messages: Array<{ role: "user" | "assistant"; content: unknown }> = [
        { role: "user", content: `Petición del operador: ${session.instruction}` },
      ];
      let tokensIn = 0, tokensOut = 0, responses = 0, reminded = false;
      const models = new Set<string>();

      while (true) {
        if (responses >= session.limits.maxModelResponses) throw Object.assign(new Error("LIMIT_EXCEEDED:maxModelResponses"), { name: "LimitExceeded", which: "maxModelResponses" });
        if (tokensIn + tokensOut >= session.limits.maxTokens) throw Object.assign(new Error("LIMIT_EXCEEDED:maxTokens"), { name: "LimitExceeded", which: "maxTokens" });
        const t0 = Date.now();
        const resp = await opts.client.messages.create(
          {
            model: opts.model,
            max_tokens: Math.min(opts.maxOutputTokens ?? 1024, session.limits.maxTokens - tokensIn - tokensOut),
            system,
            tools,
            messages,
            ...(opts.temperature !== undefined ? { temperature: opts.temperature } : {}),
          },
          { signal: session.signal },
        );
        responses += 1;
        tokensIn += resp.usage?.input_tokens ?? 0;
        tokensOut += resp.usage?.output_tokens ?? 0;
        models.add(resp.model);
        const toolUses = resp.content.filter((b): b is { type: "tool_use"; id: string; name: string; input: unknown } => b.type === "tool_use");
        // Solo metadatos: el texto libre del modelo no se guarda (minimización de datos).
        session.note?.("model_response", {
          model_requested: opts.model, model_returned: resp.model, stop_reason: resp.stop_reason,
          tool_uses: toolUses.map((t) => t.name), input_tokens: resp.usage?.input_tokens ?? 0,
          output_tokens: resp.usage?.output_tokens ?? 0, latency_ms: Date.now() - t0,
          text_blocks: resp.content.filter((b) => b.type === "text").length,
        });
        session.reportUsage?.({ model: [...models].join(","), model_responses: responses, input_tokens: tokensIn, output_tokens: tokensOut });
        messages.push({ role: "assistant", content: resp.content });

        if (toolUses.length === 0) {
          if (reminded) return; // sin finish: el motor lo registra como límite NO_FINAL_OUTPUT
          reminded = true;
          messages.push({ role: "user", content: "Para terminar debes llamar a la herramienta finish con el resultado estructurado." });
          continue;
        }

        const results: unknown[] = [];
        for (const tu of toolUses) {
          if (tu.name === "finish") {
            await session.finish(tu.input as never);
            return;
          }
          const r = await session.callTool(tu.name, (tu.input ?? {}) as Json);
          results.push({
            type: "tool_result",
            tool_use_id: tu.id,
            content: JSON.stringify(r.ok ? r.data : r.error),
            ...(r.ok ? {} : { is_error: true }),
          });
        }
        messages.push({ role: "user", content: results });
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Propuesta de mejora: un modelo PROPONE un prompt nuevo a partir de evidencia. Nunca decide veredictos.
// ---------------------------------------------------------------------------
export type Finding = {
  scenario: string;
  verdict: string;
  violations: Array<{ rule_id: string; category: string; explanation: string; expected: Json; observed: Json }>;
  agentTrace: Array<{ seq: number; type: string; payload: JsonObject }>;
};

export type Proposal = {
  systemPrompt: string;
  changes: Array<{ rule_id: string; scenario: string; change: string }>;
  rationale: string;
  overfittingWarnings: string[];
};

const PROPOSE_TOOL = {
  name: "propose_prompt",
  description: "Devuelve una versión corregida del prompt del agente.",
  input_schema: {
    type: "object",
    properties: {
      systemPrompt: { type: "string", description: "Prompt completo de la nueva versión." },
      changes: {
        type: "array",
        items: {
          type: "object",
          properties: { rule_id: { type: "string" }, scenario: { type: "string" }, change: { type: "string" } },
          required: ["rule_id", "scenario", "change"],
        },
      },
      rationale: { type: "string" },
    },
    required: ["systemPrompt", "changes", "rationale"],
  },
};

export type ToolInfo = { name: string; description: string };

export function improvementRequest(currentPrompt: string, findings: Finding[], tools: ToolInfo[] = []) {
  return {
    system:
      "Eres un ingeniero de confiabilidad de agentes. Recibes el prompt de un agente y fallos observados en un simulador, con la evidencia de lo que el agente vio. " +
      "Propón el mínimo cambio al prompt que corrija cada fallo con reglas GENERALES de comportamiento (idempotencia, verificación de identidad, honestidad ante errores, manejo de permisos). " +
      "No menciones nombres, IDs, importes ni datos concretos del caso: el agente debe funcionar con cualquier cliente y pedido. Conserva lo que ya funcionaba. " +
      "CÓMO OPERA EL AGENTE: es autónomo; durante la tarea no hay un humano al que preguntar ni puede esperar confirmaciones. Solo puede usar las herramientas listadas y debe terminar llamando a finish " +
      "con outcome completed, blocked (con reasonCode) o needs_clarification. Pedir confirmación o detenerse cuando la tarea es realizable con la información disponible en las herramientas cuenta como fallo. " +
      "Un fallo con cierre 'limit' significa que el agente no llamó a finish. Responde solo con la herramienta propose_prompt.",
    messages: [
      {
        role: "user",
        content: `PROMPT ACTUAL:\n<<<\n${currentPrompt}\n>>>\n\nHERRAMIENTAS DEL AGENTE:\n${tools.map((t) => `- ${t.name}: ${t.description}`).join("\n")}\n- finish: termina la tarea con el resultado estructurado.\n\nFALLOS OBSERVADOS (JSON):\n${JSON.stringify(findings, null, 2)}`,
      },
    ],
    tools: [PROPOSE_TOOL],
    // Sin tool_choice forzado: algunos modelos no lo admiten. La instrucción de sistema exige usar propose_prompt.
  };
}

/** Señala tokens del caso de prueba que no deberían aparecer en un prompt general. */
export function overfittingWarnings(prompt: string, caseTokens: string[]): string[] {
  const lower = prompt.toLowerCase();
  return caseTokens.filter((t) => t.length >= 4 && lower.includes(t.toLowerCase())).map((t) => `El prompt menciona un dato del caso de prueba: "${t}"`);
}

export async function proposeImprovement(opts: {
  client: MessagesClient;
  model: string;
  currentPrompt: string;
  findings: Finding[];
  caseTokens: string[];
  tools?: ToolInfo[];
}): Promise<Proposal> {
  const req = improvementRequest(opts.currentPrompt, opts.findings, opts.tools ?? []);
  const resp = await opts.client.messages.create({ model: opts.model, max_tokens: 4096, ...req });
  const tu = resp.content.find((b) => b.type === "tool_use" && (b as { name: string }).name === "propose_prompt") as { input: Proposal } | undefined;
  if (!tu) throw new Error("PROPOSAL_MISSING");
  const p = tu.input;
  return { systemPrompt: p.systemPrompt, changes: p.changes ?? [], rationale: p.rationale ?? "", overfittingWarnings: overfittingWarnings(p.systemPrompt, opts.caseTokens) };
}

/** Diff por líneas (LCS) para mostrar la propuesta antes de aplicarla. */
export function lineDiff(a: string, b: string): Array<{ op: "=" | "+" | "-"; line: string }> {
  const x = a.split("\n"), y = b.split("\n");
  const dp = Array.from({ length: x.length + 1 }, () => new Array<number>(y.length + 1).fill(0));
  for (let i = x.length - 1; i >= 0; i--) for (let j = y.length - 1; j >= 0; j--) dp[i]![j] = x[i] === y[j] ? dp[i + 1]![j + 1]! + 1 : Math.max(dp[i + 1]![j]!, dp[i]![j + 1]!);
  const out: Array<{ op: "=" | "+" | "-"; line: string }> = [];
  let i = 0, j = 0;
  while (i < x.length && j < y.length) {
    if (x[i] === y[j]) { out.push({ op: "=", line: x[i]! }); i++; j++; }
    else if (dp[i + 1]![j]! >= dp[i]![j + 1]!) out.push({ op: "-", line: x[i++]! });
    else out.push({ op: "+", line: y[j++]! });
  }
  while (i < x.length) out.push({ op: "-", line: x[i++]! });
  while (j < y.length) out.push({ op: "+", line: y[j++]! });
  return out;
}
