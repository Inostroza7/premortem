import { authed, HttpError, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
/** Compra de unidades con Stripe Checkout (sandbox). Pendiente del hito 5: requiere STRIPE_SECRET_KEY y STRIPE_PRICE_ID_UNITS_20. */
export const POST = authed(async () => {
  throw new HttpError(503, "STRIPE_NOT_CONFIGURED", "La compra de unidades aún no está habilitada en este entorno.");
});
