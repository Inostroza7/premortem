// Registra (idempotente) los manifiestos de los paquetes instalados en public.domain_pack_versions.
// Uso: pnpm packs:register              → proyecto alojado (.env.local)
//      PREMORTEM_ENV=local pnpm packs:register → Supabase local (.env.localdb)
import { loadEnv, requireEnv } from "@premortem/config";
import { ApiDb, connect } from "@premortem/db";
import { allPacks } from "@premortem/domain-registry";
import { buildManifest, ENGINE_VERSION } from "@premortem/engine";

const envFile = loadEnv();
const url = requireEnv("SUPABASE_DB_URL_API");
const sql = connect(url, { max: 1, transactionPooler: new URL(url).port === "6543" });
const db = new ApiDb(sql);
try {
  for (const pack of allPacks) {
    const { manifest, contentHash } = buildManifest(pack);
    const id = await db.registerDomainPack(pack.ref.id, pack.ref.version, contentHash, manifest, ENGINE_VERSION);
    const retired = await db.retireOtherPackVersions(pack.ref.id, pack.ref.version);
    console.log(`${pack.ref.id}@${pack.ref.version} → ${id} (hash ${contentHash.slice(0, 12)}…)${retired ? ` · retired ${retired} older version(s)` : ""} [${envFile}]`);
  }
} finally {
  await sql.end({ timeout: 5 });
}
