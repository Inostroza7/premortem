// Prompts confidenciales: cifrado de sobre en el backend antes de tocar la base (spec v2 §13).
import { randomUUID } from "node:crypto";
import { kekFromEnv, newWrappedDek, open, promptHmac, seal, sha256Hex, unwrapDek } from "@premortem/crypto";
import { db, HttpError } from "./api";

const ctx = (workspaceId: string, payloadId: string) => ({ workspaceId, ownerKind: "agent_prompt", column: "prompt", resourceId: payloadId });

function kek() {
  try {
    return kekFromEnv();
  } catch (e) {
    throw new HttpError(503, "CRYPTO_NOT_CONFIGURED", e instanceof Error ? e.message : "Cifrado no configurado");
  }
}

/** Devuelve el spec de payload cifrado para core.create_agent_version y el HMAC del prompt. */
export async function sealPrompt(workspaceId: string, userId: string, prompt: string) {
  const k = kek();
  const proposal = newWrappedDek(k, workspaceId);
  const key = await db().ensureDataKey(workspaceId, userId, k.id, proposal.wrapped);
  const dek = key.created ? proposal.dek : unwrapDek(k, workspaceId, key.kek_id, Buffer.from(key.wrapped_dek, "base64"));
  const payloadId = randomUUID();
  const blob = seal(dek, key.key_id, ctx(workspaceId, payloadId), prompt);
  let hmac: Buffer;
  try {
    hmac = promptHmac(process.env, workspaceId, prompt);
  } catch (e) {
    throw new HttpError(503, "CRYPTO_NOT_CONFIGURED", e instanceof Error ? e.message : "HMAC no configurado");
  }
  return {
    promptHmac: hmac,
    promptPayload: { payload_id: payloadId, encrypted: true, blob_b64: blob.toString("base64"), digest: sha256Hex(blob), key_id: key.key_id, classification: "confidential" },
  };
}

/** Descifra el prompt de una versión de agente del workspace (deja registro en core.access_log). */
export async function readPrompt(workspaceId: string, userId: string, agentVersionId: string, purpose: string): Promise<string | null> {
  const r = await db().readAgentPrompt(agentVersionId, workspaceId, userId, purpose);
  const p = r.prompt;
  if (!p) return null;
  if (p.purged) throw new HttpError(410, "PROMPT_PURGED", "El prompt de esta versión fue purgado por retención");
  if (!p.encrypted) return String(p.content ?? "");
  const k = kek();
  const dek = unwrapDek(k, workspaceId, p.kek_id!, Buffer.from(p.wrapped_dek!, "base64"));
  return open(dek, p.key_id!, ctx(workspaceId, p.payload_id), Buffer.from(p.blob_b64!, "base64"));
}
