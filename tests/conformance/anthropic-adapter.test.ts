// Adaptador Claude con un cliente simulado: protocolo de tool_use / tool_result, finish, límites y metadatos.
import { randomUUID } from "node:crypto";
import { describe, expect, it } from "vitest";
import { anthropicAgent, lineDiff, overfittingWarnings, type MessagesClient } from "@premortem/agents";
import { executeAttempt } from "@premortem/engine";
import { refundsPack } from "@premortem/domain-refunds";
import { MemorySink } from "./memory-sink";

function scripted(steps: Array<(msgs: any[]) => any[]>) {
  const seen: any[] = [];
  const client: MessagesClient = {
    messages: {
      async create(req: any) {
        seen.push(structuredClone(req));
        const step = steps[Math.min(seen.length - 1, steps.length - 1)]!;
        return { model: "claude-test", stop_reason: "tool_use", content: step(req.messages), usage: { input_tokens: 100, output_tokens: 20 } };
      },
    },
  };
  return { client, seen };
}

const run = (client: MessagesClient, limits = {}) => {
  const demo = refundsPack.demoCases[0]!; const ws = randomUUID(), att = randomUUID();
  const sink = new MemorySink(ws, att);
  return executeAttempt({
    pack: refundsPack, policy: anthropicAgent({ client, model: "claude-test", systemPrompt: "Eres un agente de soporte." }),
    workspaceId: ws, attemptId: att, scenarioId: "baseline", mutations: [], task: demo.task, publicContext: demo.publicContext,
    fixture: demo.fixture, fixtureVersion: demo.fixtureVersion, oracle: demo.oracle,
    limits: { maxToolCalls: 20, maxDurationMs: 30_000, maxTokens: 25_000, maxModelResponses: 12, ...limits },
    requestId: "req_refund_001", manifestHash: "x", chain: { nextSeq: 2, prevHash: sink.head }, stateVersion: 0, sink,
    signal: new AbortController().signal,
  });
};

describe("adaptador Claude", () => {
  it("enlaza cada tool_result con su tool_use, registra metadatos y termina con finish", async () => {
    const { client, seen } = scripted([
      () => [{ type: "text", text: "Primero leo el contexto." }, { type: "tool_use", id: "tu_1", name: "refund_get_context", input: {} }],
      () => [{ type: "tool_use", id: "tu_2", name: "finish", input: { outcome: "needs_clarification", reasonCode: "TEST", evidenceIds: [], data: {} } }],
    ]);
    const r = await run(client);
    const second = seen[1];
    const toolResult = second.messages.at(-1).content[0];
    expect(toolResult.type).toBe("tool_result");
    expect(toolResult.tool_use_id).toBe("tu_1");
    expect(second.tools.map((t: any) => t.name)).toContain("finish");
    expect(second.system).toContain("Eres un agente de soporte.");
    expect(r.finalOutput?.outcome).toBe("needs_clarification");
    expect(r.events.filter((e) => e.type === "agent.model_response").length).toBe(2);
    expect(JSON.stringify(r.events)).not.toContain("Primero leo el contexto");   // el texto libre no se guarda
    expect(r.usage.model_responses).toBe(2);
    expect(r.usage.input_tokens).toBe(200);
  });

  it("un error de herramienta llega como is_error", async () => {
    const { client, seen } = scripted([
      () => [{ type: "tool_use", id: "tu_1", name: "refund_get_order", input: { order_id: "no_existe" } }],
      () => [{ type: "tool_use", id: "tu_2", name: "finish", input: { outcome: "blocked", reasonCode: "NOT_FOUND", evidenceIds: [], data: {} } }],
    ]);
    await run(client);
    const tr = seen[1].messages.at(-1).content[0];
    expect(tr.is_error).toBe(true);
    expect(tr.content).toContain("NOT_FOUND");
  });

  it("sin finish tras un recordatorio termina como límite y el veredicto es inconcluso", async () => {
    const { client } = scripted([() => [{ type: "text", text: "Listo." }]]);
    const r = await run(client);
    expect(r.termination).toBe("limit");
    expect(r.verdict).toBe("inconclusive");
  });

  it("respeta el máximo de respuestas del modelo", async () => {
    const { client } = scripted([() => [{ type: "tool_use", id: randomUUID(), name: "refund_get_context", input: {} }]]);
    const r = await run(client, { maxModelResponses: 3 });
    expect(r.termination).toBe("limit");
    expect(r.terminationReason).toBe("maxModelResponses");
  });
});

describe("propuesta de mejora", () => {
  it("diff por líneas y aviso de sobreajuste", () => {
    const d = lineDiff("a\nb\nc", "a\nB\nc\nd");
    expect(d.filter((x) => x.op === "+").map((x) => x.line)).toEqual(["B", "d"]);
    expect(d.filter((x) => x.op === "-").map((x) => x.line)).toEqual(["b"]);
    expect(overfittingWarnings("Nunca reembolses a Alex Chen", ["Alex Chen", "PM-1042"]).length).toBe(1);
  });
});
