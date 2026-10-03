import { resolve } from "node:path";
import { config } from "dotenv";
import type { NextConfig } from "next";

// Mismo archivo de entorno que worker y scripts: PREMORTEM_ENV=local → .env.localdb; si no, .env.local de la raíz.
const root = resolve(process.cwd(), "../..");
config({ path: resolve(root, process.env.PREMORTEM_ENV === "local" ? ".env.localdb" : ".env.local"), override: false, quiet: true });
if (process.env.PREMORTEM_ENV === "local") {
  // Credenciales del proveedor de modelos compartidas desde .env.local (solo ANTHROPIC_*).
  const shared = config({ path: resolve(root, ".env.local"), processEnv: {}, quiet: true }).parsed ?? {};
  for (const [k, v] of Object.entries(shared)) if ((k.startsWith("ANTHROPIC_") || k.startsWith("STRIPE_")) && v && !process.env[k]) process.env[k] = v;
}

const nextConfig: NextConfig = {
  transpilePackages: [
    "@premortem/agents", "@premortem/config", "@premortem/contracts", "@premortem/crypto", "@premortem/db", "@premortem/domain-registry",
    "@premortem/engine", "@premortem/evidence", "@premortem/domain-refunds", "@premortem/domain-calendar", "@premortem/domain-refunds-stripe",
  ],
  serverExternalPackages: ["postgres"],
  poweredByHeader: false,
};
export default nextConfig;
