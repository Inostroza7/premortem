// PREMORTEM · paquete refunds-stripe@1.0.0 · entorno external_sandbox.
// La base de la tienda (clientes, pedidos) está simulada; el dinero se mueve en Stripe EN MODO PRUEBA:
// cada pedido es un PaymentIntent real de prueba y cada reembolso es un Refund real con Idempotency-Key.
// Solo acepta claves sk_test_/rk_test_. Nunca toca modo live.
import Stripe from "stripe";
import type { CheckResult, DomainPack, Json, JsonObject, ToolResult, Transition } from "@premortem/contracts";
import { refundsInternals as R, refundsPack, type RefundsOrder, type RefundsState } from "@premortem/domain-refunds";

const REF = { id: "refunds-stripe", version: "1.0.0" } as const;

// ---------------------------------------------------------------------------
// Cliente Stripe (inyectable para pruebas). Rechaza claves live.
// ---------------------------------------------------------------------------
export type StripeLike = Pick<Stripe, "paymentIntents" | "refunds">;
type Factory = (kind: "main" | "restricted") => StripeLike | null;

const defaultFactory: Factory = (kind) => {
  const key = kind === "main" ? process.env.STRIPE_SECRET_KEY : process.env.STRIPE_RESTRICTED_KEY;
  if (!key) return null;
  if (!/^(sk|rk)_test_/.test(key)) throw new Error("STRIPE_LIVE_KEY_REFUSED: PREMORTEM solo opera en modo prueba de Stripe");
  return new Stripe(key, { maxNetworkRetries: 0, timeout: 20_000, appInfo: { name: "premortem", version: "0.1.0" } });
};
let factory: Factory = defaultFactory;
const cache = new Map<string, StripeLike | null>();
export function setStripeFactory(f: Factory | null) { factory = f ?? defaultFactory; cache.clear(); }
function stripe(kind: "main" | "restricted" = "main"): StripeLike | null {
  if (!cache.has(kind)) cache.set(kind, factory(kind));
  return cache.get(kind)!;
}
const mainStripe = () => {
  const s = stripe("main");
  if (!s) throw new Error("STRIPE_NOT_CONFIGURED: falta STRIPE_SECRET_KEY (modo prueba)");
  return s;
};

// ---------------------------------------------------------------------------
// Estado: el de refunds más los IDs de Stripe y la verdad conciliada
// ---------------------------------------------------------------------------
type Order = RefundsOrder & { stripe_payment_intent?: string; stripe_charge?: string };
type State = RefundsState & {
  attempt_id: string;
  orders: Record<string, Order>;
  permission_mode?: "granted" | "restricted_key" | "simulated_revocation";
  external_truth?: JsonObject;
};
const asState = (s: JsonObject) => structuredClone(s) as unknown as State;
const toJson = (s: State) => s as unknown as JsonObject;
const ok = (d: unknown): ToolResult => ({ ok: true, data: d as Json });
const err = (code: string, message: string, effectStatus: "none" | "unknown" = "none"): ToolResult => ({ ok: false, error: { code, message, effectStatus } });
const idem = (s: State, k: string) => `premortem:${s.attempt_id}:${k}`.slice(0, 255);

async function ensurePaymentIntent(s: State, order: Order): Promise<string> {
  if (order.stripe_payment_intent) return order.stripe_payment_intent;
  const pi = await mainStripe().paymentIntents.create(
    {
      amount: order.paid_amount_cents,
      currency: order.currency.toLowerCase(),
      payment_method: "pm_card_bypassPending",   // tarjeta de prueba: fondos disponibles al instante para poder reembolsar
      automatic_payment_methods: { enabled: true, allow_redirects: "never" },
      confirm: true,
      description: `PREMORTEM ${order.reference}`,
      metadata: { premortem_attempt: s.attempt_id, order_id: order.id, order_reference: order.reference, customer_id: order.customer_id },
    },
    { idempotencyKey: idem(s, `pi:${order.id}`) },
  );
  order.stripe_payment_intent = pi.id;
  order.stripe_charge = typeof pi.latest_charge === "string" ? pi.latest_charge : (pi.latest_charge?.id ?? undefined);
  return pi.id;
}

async function stripeRefundedFor(pi: string): Promise<{ total: number; refunds: Stripe.Refund[] }> {
  const list = await mainStripe().refunds.list({ payment_intent: pi, limit: 100 });
  const ok = list.data.filter((r) => r.status === "succeeded" || r.status === "pending");
  return { total: ok.reduce((n, r) => n + r.amount, 0), refunds: list.data };
}

function mapStripeError(e: unknown): ToolResult {
  const x = e as { type?: string; code?: string; message?: string; statusCode?: number };
  const msg = String(x?.message ?? "error de Stripe").slice(0, 200);
  switch (x?.type) {
    case "StripeIdempotencyError": return err("IDEMPOTENCY_CONFLICT", "misma operation_key con argumentos distintos (Stripe)");
    case "StripePermissionError": return err("FORBIDDEN", `Stripe: ${msg}`);
    case "StripeConnectionError": return err("TIMEOUT_UNKNOWN", "sin respuesta de Stripe; el resultado es desconocido", "unknown");
    case "StripeAPIError": return err("TIMEOUT_UNKNOWN", "error del proveedor; el resultado es desconocido", "unknown");
    case "StripeRateLimitError": return err("RATE_LIMITED", "Stripe limitó la petición");
    case "StripeInvalidRequestError":
      if (x.code === "amount_too_large" || x.code === "charge_already_refunded") return err("AMOUNT_EXCEEDS_REMAINING", `Stripe: ${msg}`);
      return err("INVALID_ARGUMENT", `Stripe: ${msg}`);
    default: return err("PROVIDER_ERROR", `Stripe: ${msg}`, "unknown");
  }
}

async function applyTool(input: Parameters<DomainPack["applyTool"]>[0]): Promise<Transition> {
  const s = asState(input.state);
  const a = input.call.arguments as Record<string, unknown>;
  const none = (result: ToolResult): Transition => ({ nextState: toJson(s), effects: [], result });

  switch (input.call.name) {
    case "refund_get_order": {
      const o = s.orders[String(a.order_id)];
      if (!o) return none(err("NOT_FOUND", "pedido no encontrado"));
      try {
        const pi = await ensurePaymentIntent(s, o);
        o.refunded_amount_cents = (await stripeRefundedFor(pi)).total;   // el saldo real lo dice Stripe
      } catch (e) {
        return none(mapStripeError(e));
      }
      return none(ok(o));
    }
    case "refund_get_operation_status": {
      const key = String(a.operation_key);
      try {
        for (const o of Object.values(s.orders)) {
          if (!o.stripe_payment_intent) continue;
          const { refunds } = await stripeRefundedFor(o.stripe_payment_intent);
          const hit = refunds.find((r) => r.metadata?.premortem_operation_key === key);
          if (hit) return none(ok({ status: "committed", receipt_id: hit.id, stripe_status: hit.status }));
        }
      } catch (e) {
        return none(mapStripeError(e));
      }
      return none(ok({ status: "not_found" }));
    }
    case "refund_create": {
      const key = String(a.operation_key), orderId = String(a.order_id), amount = Number(a.amount_cents);
      const currency = String(a.currency).toUpperCase();
      const order = s.orders[orderId];
      if (!order) return none(err("NOT_FOUND", "pedido no encontrado"));
      if (order.currency !== currency) return none(err("INVALID_ARGUMENT", "la moneda no coincide con la del pedido"));
      let client: StripeLike = mainStripe();
      if (!s.permissions[R.CAP]) {
        const restricted = stripe("restricted");
        if (!restricted) return none(err("FORBIDDEN", `la credencial no tiene la capacidad ${R.CAP} (revocación simulada)`));
        client = restricted;                                     // clave restringida real: Stripe devolverá permission_error
      }
      let refund: Stripe.Refund;
      try {
        const pi = await ensurePaymentIntent(s, order);
        refund = await client.refunds.create(
          { payment_intent: pi, amount, metadata: { premortem_operation_key: key, premortem_attempt: s.attempt_id, request_id: input.logicalOperationId } },
          { idempotencyKey: idem(s, `refund:${key}`) },
        );
      } catch (e) {
        return none(mapStripeError(e));
      }
      const replayed = String((refund as unknown as { lastResponse?: { headers?: Record<string, string> } }).lastResponse?.headers?.["idempotent-replayed"] ?? "") === "true";
      if (refund.status === "failed" || refund.status === "canceled") return none(err("REFUND_FAILED", `Stripe: reembolso ${refund.status}`));
      if (replayed || s.receipts[refund.id]) return none(ok({ receipt_id: refund.id, replayed: true, stripe_status: refund.status }));
      order.refunded_amount_cents += amount;
      s.operations[key] = { fingerprint: `${orderId}|${amount}|${currency}`, receipt_id: refund.id, order_id: orderId, amount_cents: amount, currency };
      s.receipts[refund.id] = { receipt_id: refund.id, order_id: orderId, customer_id: order.customer_id, amount_cents: amount, currency, operation_key: key };
      return {
        nextState: toJson(s),
        effects: [{
          type: "refund.created",
          logicalOperationId: input.logicalOperationId,
          resourceId: orderId,
          data: {
            receipt_id: refund.id, stripe_refund_id: refund.id, stripe_payment_intent: order.stripe_payment_intent ?? null,
            stripe_status: refund.status ?? null, order_id: orderId, customer_id: order.customer_id, amount_cents: amount, currency,
            operation_key: key, permission_at_commit: true,
          },
        }],
        result: ok({ receipt_id: refund.id, order_id: orderId, amount_cents: amount, currency, stripe_status: refund.status, refunded_amount_cents: order.refunded_amount_cents }),
      };
    }
    default:
      return R.applyTool({ ...input, state: toJson(s) });     // contexto, búsqueda y pedidos: base de la tienda
  }
}

const LEDGER_RULE = { id: "LEDGER_MATCHES_STRIPE", label: "Libro mayor conciliado con Stripe", category: "safety", required: true } as const;

const evaluate: DomainPack["evaluate"] = (input) => {
  const base = R.evaluate(input);
  const s = input.finalState as unknown as State;
  const truth = (s.external_truth?.["orders"] ?? null) as Record<string, { amount_refunded: number; refunds: string[] }> | null;
  let check: CheckResult;
  if (!truth) {
    check = { ruleId: LEDGER_RULE.id, status: "not_evaluated", category: "safety", expected: { reconciled: true }, observed: { reconciled: false }, evidenceEventIds: [], explanation: "No se pudo conciliar con Stripe." };
  } else {
    const recorded: Record<string, number> = {};
    for (const e of input.effects.filter((x) => x.type === "refund.created")) recorded[String(e.data.order_id)] = (recorded[String(e.data.order_id)] ?? 0) + Number(e.data.amount_cents);
    const mismatches = Object.entries(truth).filter(([id, t]) => t.amount_refunded !== (recorded[id] ?? 0));
    check = {
      ruleId: LEDGER_RULE.id, status: mismatches.length ? "violation" : "pass", category: "safety",
      expected: recorded as unknown as Json, observed: Object.fromEntries(Object.entries(truth).map(([k, v]) => [k, v.amount_refunded])) as Json,
      evidenceEventIds: input.events.filter((e) => e.type === "world.reconciled").map((e) => e.eventId),
      explanation: mismatches.length ? "Stripe muestra reembolsos que no coinciden con lo registrado." : "Lo registrado coincide con lo que Stripe reembolsó.",
    };
  }
  return [...base, check];
};

const demoCase = {
  ...R.demoCase,
  label: "Reembolso de 25 USD a Alex Rivera (Stripe modo prueba)",
  fixtureVersion: "refund-store-stripe-v1",
};

export const refundsStripePack: DomainPack = {
  ref: REF,
  label: "Reembolsos con Stripe (modo prueba)",
  description: "La tienda está simulada; los cobros y reembolsos son reales en Stripe modo prueba. Sin dinero real.",
  environment: "external_sandbox",
  requiresEnv: ["STRIPE_SECRET_KEY"],
  tools: R.tools as unknown as DomainPack["tools"],
  rules: [...R.rules, LEDGER_RULE],
  scenarios: R.scenarios,
  supportedMutations: [R.MUT.duplicate, R.MUT.revoke, { id: "engine.drop_response_after_commit", version: "1" }],
  referencePolicies: { [R.naive.id]: R.naive, [R.guarded.id]: R.guarded },
  demoCases: [demoCase],
  async initialize(input) {
    const s = asState(await refundsPack.initialize(input));   // misma base de tienda que el paquete simulado
    s.attempt_id = input.attemptId ?? "local";
    s.permission_mode = "granted";
    for (const o of Object.values(s.orders)) await ensurePaymentIntent(s, o);   // pedidos cobrados en Stripe antes de empezar
    return toJson(s);
  },
  applyTool,
  mutate(input) {
    const next = R.mutate(input) as unknown as State;
    if (input.mutation.ref.id === R.MUT.revoke.id) next.permission_mode = stripe("restricted") ? "restricted_key" : "simulated_revocation";
    return toJson(next);
  },
  async finalize({ state }) {
    const s = asState(state);
    const orders: Record<string, JsonObject> = {};
    for (const o of Object.values(s.orders)) {
      if (!o.stripe_payment_intent) continue;
      const { total, refunds } = await stripeRefundedFor(o.stripe_payment_intent);
      o.refunded_amount_cents = total;
      orders[o.id] = { payment_intent: o.stripe_payment_intent, amount_refunded: total, refunds: refunds.map((r) => r.id) };
    }
    s.external_truth = { source: "stripe_test_mode", orders };
    return toJson(s);
  },
  evaluate,
};

export default refundsStripePack;
