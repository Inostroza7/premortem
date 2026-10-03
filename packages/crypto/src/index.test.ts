import { randomUUID, randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { newWrappedDek, open, seal, unwrapDek } from "./index";

const kek = { id: "kek-test", key: randomBytes(32) };
const ws = randomUUID(), keyId = randomUUID();
const ctx = (id: string, w = ws) => ({ workspaceId: w, ownerKind: "agent_prompt", column: "prompt", resourceId: id });

describe("cifrado de sobre", () => {
  it("sella y abre con la DEK envuelta", () => {
    const { wrapped } = newWrappedDek(kek, ws);
    const dek = unwrapDek(kek, ws, kek.id, wrapped);
    const id = randomUUID();
    expect(open(dek, keyId, ctx(id), seal(dek, keyId, ctx(id), "Eres un agente de soporte."))).toBe("Eres un agente de soporte.");
  });
  it("un blob movido a otro recurso o a otro workspace no se abre", () => {
    const { dek } = newWrappedDek(kek, ws);
    const a = randomUUID(), b = randomUUID();
    const blob = seal(dek, keyId, ctx(a), "secreto");
    expect(() => open(dek, keyId, ctx(b), blob)).toThrow();
    expect(() => open(dek, keyId, ctx(a, randomUUID()), blob)).toThrow();
  });
  it("una DEK envuelta para otro workspace no se desenvuelve", () => {
    const { wrapped } = newWrappedDek(kek, ws);
    expect(() => unwrapDek(kek, randomUUID(), kek.id, wrapped)).toThrow();
  });
  it("un blob alterado falla la autenticación", () => {
    const { dek } = newWrappedDek(kek, ws); const id = randomUUID();
    const blob = seal(dek, keyId, ctx(id), "secreto"); blob[blob.length - 20]! ^= 1;
    expect(() => open(dek, keyId, ctx(id), blob)).toThrow();
  });
});
