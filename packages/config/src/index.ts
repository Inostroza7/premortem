// Carga de entorno para procesos Node (worker, scripts). Next.js usa el mismo archivo vía next.config.
// PREMORTEM_ENV=local → .env.localdb (Supabase local) · cualquier otro valor → .env.local (proyecto alojado).
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { config } from "dotenv";

export const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

let loaded = false;
export function loadEnv(): string {
  const target = process.env.PREMORTEM_ENV === "local" ? ".env.localdb" : ".env.local";
  if (!loaded) {
    const file = resolve(repoRoot, target);
    if (existsSync(file)) config({ path: file, override: false, quiet: true });
    loaded = true;
  }
  return target;
}

export function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Falta la variable de entorno ${name}`);
  return v;
}
