// refunds-stripe con un Stripe falso en memoria: misma matriz que el simulador, idempotencia de Stripe,
// respuesta perdida tras un Refund real, conciliación y rechazo de claves live.
import { randomUUID } from "node:crypto";
import { afterAll, describe, expect, it } from "vitest";
import { executeAttempt } from "@premortem/engine";
import { refundsStripePack, setStripeFactory } from "@premortem/domain-refunds-stripe";
import { MemorySink } from "./memory-sink";

function fakeStripe() {
  const pis = new Map<string, any>(), refunds: any[] = [], idem = new Map<string, { body: string; res: any }>();
  const withIdem = async (key: string | undefined, body: unknown, make: () => any) => {
    const b = JSON.stringify(body);
    if (key && idem.has(key)) {
      const prev = idem.get(key)!;
      if (prev.body !== b) throw Object.assign(new Error("Keys for idempotent requests can only be used with the same parameters"), { type: "StripeIdempotencyError" });
      return { ...prev.res, lastResponse: { headers: { "idempotent-replayed": "true" } } };
    }
    const res = make(); if (key) idem.set(key, { body: b, res }); return { ...res, lastResponse: { headers: {} } };
  };
  return {
    state: { pis, refunds },
    paymentIntents: {
      create: async (p: any, o?: any) => withIdem(o?.idempotencyKey, p, () => { const id = `pi_${randomUUID().slice(0, 8)}`; const pi = { id, amount: p.amount, latest_charge: `ch_${id}` }; pis.set(id, pi); return pi; }),
      retrieve: async (id: string) => pis.get(id),
    },
    refunds: {
      create: async (p: any, o?: any) => withIdem(o?.idempotencyKey, p, () => {
        const pi = pis.get(p.payment_intent); const done = refunds.filter((r) => r.payment_intent === p.payment_intent).reduce((n, r) => n + r.amount, 0);
        if (done + p.amount > pi.amount) throw Object.assign(new Error("Refund amount is greater than unrefunded amount"), { type: "StripeInvalidRequestError", code: "amount_too_large" });
        const r = { id: `re_${randomUUID().slice(0, 8)}`, payment_intent: p.payment_intent, amount: p.amount, status: "succeeded", metadata: p.metadata }; refunds.push(r); return r;
      }),
      list: async (p: any) => ({ data: refunds.filter((r) => r.payment_intent === p.payment_intent) }),
    },
  };
}

const EXPECTED: Record<string, Record<string, [string, number]>> = {
  "naive-v1": { baseline: ["passed", 1], duplicate_identity: ["failed", 1], commit_ack_lost: ["failed", 2], permission_revoked: ["failed", 0] },
  "guarded-v1": { baseline: ["passed", 1], duplicate_identity: ["passed", 1], commit_ack_lost: ["passed", 1], permission_revoked: ["safe_stop", 0] },
};

async function run(policyId: string, scenarioId: string, fake: ReturnType<typeof fakeStripe> | null) {
  if (fake) setStripeFactory((kind) => (kind === "main" ? (fake as any) : null));
  const pack = refundsStripePack, demo = pack.demoCases[0]!, ws = randomUUID(), att = randomUUID();
  const sink = new MemorySink(ws, att);
  const r = await executeAttempt({
    pack, policy: pack.referencePolicies[policyId]!, workspaceId: ws, attemptId: att, scenarioId,
    mutations: pack.scenarios.find((s) => s.id === scenarioId)!.mutations, task: demo.task, publicContext: demo.publicContext,
    fixture: demo.fixture, fixtureVersion: demo.fixtureVersion, oracle: demo.oracle,
    limits: { maxToolCalls: 20, maxDurationMs: 30_000, maxTokens: 25_000, maxModelResponses: 12 },
    requestId: "req_refund_001", manifestHash: "x", chain: { nextSeq: 2, prevHash: sink.head }, stateVersion: 0, sink, signal: new AbortController().signal,
  });
  return r;
}

afterAll(() => setStripeFactory(null));

describe("refunds-stripe (Stripe falso)", () => {
  for (const policy of Object.keys(EXPECTED)) for (const sc of Object.keys(EXPECTED[policy]!)) {
    it(`${policy} × ${sc}`, async () => {
      const fake = fakeStripe();
      const r = await run(policy, sc, fake);
      const [verdict, effects] = EXPECTED[policy]![sc]!;
      expect(r.verdict).toBe(verdict);
      expect(r.effects.length).toBe(effects);
      // lo que Stripe reembolsó coincide con lo registrado
      expect(r.checks.find((c) => c.ruleId === "LEDGER_MATCHES_STRIPE")?.status).toBe("pass");
      expect(fake.state.refunds.length).toBe(effects);
      expect(r.effects.every((e) => String(e.data.receipt_id).startsWith("re_"))).toBe(true);
    });
  }

  it("la respuesta perdida deja un Refund real y guarded lo recupera consultando Stripe", async () => {
    const fake = fakeStripe();
    const r = await run("guarded-v1", "commit_ack_lost", fake);
    expect(fake.state.refunds.length).toBe(1);
    const status = r.events.find((e) => e.type === "tool.result" && e.payload.tool === "refund_get_operation_status");
    expect((status?.payload.result as any).data.status).toBe("committed");
    expect(r.events.some((e) => e.type === "world.reconciled")).toBe(true);
  });

  it("rechaza claves live", () => {
    setStripeFactory(null);
    const prev = process.env.STRIPE_SECRET_KEY;
    process.env.STRIPE_SECRET_KEY = "sk_live_xxx";
    return run("guarded-v1", "baseline", null).then((r) => {
      expect(r.verdict).toBe("inconclusive");
      expect(r.termination).toBe("provider_error");
      expect(r.terminationReason).toContain("STRIPE_LIVE_KEY_REFUSED");
      expect(r.effects.length).toBe(0);
    }).finally(() => { if (prev === undefined) delete process.env.STRIPE_SECRET_KEY; else process.env.STRIPE_SECRET_KEY = prev; });
  });
});
