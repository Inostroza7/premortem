import { resolve } from "node:path";
import { config } from "dotenv";
import type { NextConfig } from "next";

// Mismo archivo de entorno que worker y scripts: PREMORTEM_ENV=local → .env.localdb; si no, .env.local de la raíz.
const root = resolve(process.cwd(), "../..");
config({ path: resolve(root, process.env.PREMORTEM_ENV === "local" ? ".env.localdb" : ".env.local"), override: false, quiet: true });

const nextConfig: NextConfig = {
  transpilePackages: [
    "@premortem/config", "@premortem/contracts", "@premortem/db", "@premortem/domain-registry",
    "@premortem/engine", "@premortem/evidence", "@premortem/domain-refunds", "@premortem/domain-calendar",
  ],
  serverExternalPackages: ["postgres"],
  poweredByHeader: false,
};
export default nextConfig;
