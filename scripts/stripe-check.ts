// Comprueba la clave de Stripe (solo modo prueba): crea un cobro de 1 USD con tarjeta de prueba, lo reembolsa
// con Idempotency-Key, repite la petición para verificar el replay y muestra los enlaces del dashboard de prueba.
import { randomUUID } from "node:crypto";
import Stripe from "stripe";
import { loadEnv } from "@premortem/config";

loadEnv();
const key = process.env.STRIPE_SECRET_KEY ?? "";
if (!key) { console.log("Falta STRIPE_SECRET_KEY en .env.local (clave de prueba sk_test_…)."); process.exit(1); }
if (!key.startsWith("sk_test_") && !key.startsWith("rk_test_")) { console.log("Rechazada: PREMORTEM solo usa claves de modo prueba (sk_test_ / rk_test_)."); process.exit(1); }
const stripe = new Stripe(key, { maxNetworkRetries: 0 });
try {
  const bal = await stripe.balance.retrieve();
  console.log(`Clave válida · modo prueba (livemode=${bal.livemode}) · saldo disponible ${bal.available.map((b) => `${(b.amount / 100).toFixed(2)} ${b.currency.toUpperCase()}`).join(", ") || "0"}`);
  const pi = await stripe.paymentIntents.create({ amount: 100, currency: "usd", payment_method: "pm_card_bypassPending", confirm: true,
    automatic_payment_methods: { enabled: true, allow_redirects: "never" }, description: "PREMORTEM stripe:check", metadata: { premortem: "check" } });
  console.log(`PaymentIntent ${pi.id} · ${pi.status} · 1.00 USD`);
  const k = `premortem-check-${randomUUID()}`;
  const r1 = await stripe.refunds.create({ payment_intent: pi.id, amount: 100 }, { idempotencyKey: k });
  const r2 = await stripe.refunds.create({ payment_intent: pi.id, amount: 100 }, { idempotencyKey: k });
  const replayed = (r2 as any).lastResponse?.headers?.["idempotent-replayed"];
  console.log(`Refund ${r1.id} · ${r1.status} · misma clave devuelve el mismo refund: ${r1.id === r2.id} (Idempotent-Replayed: ${replayed})`);
  if (process.env.STRIPE_RESTRICTED_KEY) {
    const rk = new Stripe(process.env.STRIPE_RESTRICTED_KEY, { maxNetworkRetries: 0 });
    await rk.refunds.create({ payment_intent: pi.id, amount: 1 }).then(
      () => console.log("Aviso: la clave restringida SÍ puede crear reembolsos; para el mundo de permiso revocado debe no tener Refunds: Write."),
      (e: any) => console.log(`Clave restringida: Stripe responde ${e.type} → el mundo de permiso revocado usará un error real.`));
  }
  console.log(`Dashboard: https://dashboard.stripe.com/test/payments/${pi.id}`);
  console.log("OK · Stripe modo prueba listo para PREMORTEM");
} catch (e: any) {
  console.log(`Error de Stripe: ${e?.type ?? ""} ${String(e?.message ?? e).slice(0, 200)}`);
  process.exit(1);
}
