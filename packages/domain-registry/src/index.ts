// Registro de paquetes confiables (spec v2 §5). Único lugar que importa implementaciones concretas;
// runner, cola, billing y API los seleccionan por referencia inmutable "pack_id@version".
import type { DomainPack } from "@premortem/contracts";
import { refundsPack } from "@premortem/domain-refunds";
import { calendarPack } from "@premortem/domain-calendar";

const packs: readonly DomainPack[] = [refundsPack, calendarPack];

export const registry: ReadonlyMap<string, DomainPack> = new Map(packs.map((p) => [`${p.ref.id}@${p.ref.version}`, p]));

export function getPack(packId: string, version: string): DomainPack | undefined {
  return registry.get(`${packId}@${version}`);
}

export const allPacks = packs;
