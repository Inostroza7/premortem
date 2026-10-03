// Comprueba un paquete contra el contrato: manifiesto, políticas y la matriz de 4 escenarios en memoria.
// Uso: pnpm domain:check refunds
import { execFileSync } from "node:child_process";
import { allPacks } from "@premortem/domain-registry";
import { buildManifest } from "@premortem/engine";

const id = process.argv[2];
const pack = allPacks.find((p) => p.ref.id === id);
if (!pack) {
  console.error(`Paquete desconocido: ${id}. Disponibles: ${allPacks.map((p) => p.ref.id).join(", ")}`);
  process.exit(1);
}
const { manifest, contentHash } = buildManifest(pack);
console.log(`${pack.ref.id}@${pack.ref.version} · herramientas ${manifest.tools.length} · reglas ${manifest.rules.length} · escenarios ${Object.keys(manifest.scenarios).length} · políticas ${manifest.policies.length} · hash ${contentHash.slice(0, 16)}…`);
execFileSync("pnpm", ["vitest", "run", "tests/conformance", "-t", `${pack.ref.id}@`], { stdio: "inherit" });
