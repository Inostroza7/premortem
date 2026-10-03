import { json, open } from "@/lib/server/api";

export const dynamic = "force-dynamic";
/** Ingesta de eventos Stripe firmada. Pendiente del hito 5. */
export const POST = open(async (req) => json(req, { error: { code: "STRIPE_NOT_CONFIGURED", message: "Webhook no habilitado en este entorno." } }, 503));
