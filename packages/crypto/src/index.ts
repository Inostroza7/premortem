// PREMORTEM · cifrado de sobre (spec v2 §13). AES-256-GCM de la biblioteca estándar de Node.
// KEK (fuera de la base) → envuelve una DEK por workspace → la DEK cifra cada payload confidencial.
// El AAD liga cada blob a su versión de formato, workspace, tipo, columna y UUID exacto.
import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";

const FORMAT = 1;
const uuidBytes = (u: string) => Buffer.from(u.replace(/-/g, ""), "hex");
const bytesUuid = (b: Buffer) => {
  const h = b.toString("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
};

export type Kek = { id: string; key: Buffer };

export function kekFromEnv(env: NodeJS.ProcessEnv = process.env): Kek {
  const raw = env.PREMORTEM_KEK;
  if (!raw) throw new Error("CRYPTO_NOT_CONFIGURED: falta PREMORTEM_KEK");
  const key = Buffer.from(raw, "base64");
  if (key.length !== 32) throw new Error("CRYPTO_NOT_CONFIGURED: PREMORTEM_KEK debe tener 32 bytes en base64");
  return { id: env.PREMORTEM_KEK_ID ?? "kek-default", key };
}

const dekAad = (workspaceId: string, kekId: string) => Buffer.from(`premortem:dek:v${FORMAT}:${workspaceId}:${kekId}`);

/** Genera una DEK nueva y la devuelve en claro y envuelta (nonce ‖ ct ‖ tag). */
export function newWrappedDek(kek: Kek, workspaceId: string): { dek: Buffer; wrapped: Buffer } {
  const dek = randomBytes(32);
  const nonce = randomBytes(12);
  const c = createCipheriv("aes-256-gcm", kek.key, nonce);
  c.setAAD(dekAad(workspaceId, kek.id));
  const ct = Buffer.concat([c.update(dek), c.final()]);
  return { dek, wrapped: Buffer.concat([nonce, ct, c.getAuthTag()]) };
}

export function unwrapDek(kek: Kek, workspaceId: string, kekId: string, wrapped: Buffer): Buffer {
  if (kekId !== kek.id) throw new Error(`KEK_MISMATCH: la DEK está envuelta con ${kekId}`);
  if (wrapped.length !== 12 + 32 + 16) throw new Error("WRAPPED_DEK_INVALID");
  const d = createDecipheriv("aes-256-gcm", kek.key, wrapped.subarray(0, 12));
  d.setAAD(dekAad(workspaceId, kekId));
  d.setAuthTag(wrapped.subarray(44));
  return Buffer.concat([d.update(wrapped.subarray(12, 44)), d.final()]);
}

export type BlobContext = { workspaceId: string; ownerKind: string; column: string; resourceId: string };
const blobAad = (c: BlobContext) => Buffer.from(`premortem:v${FORMAT}:${c.workspaceId}:${c.ownerKind}:${c.column}:${c.resourceId}`);

/** blob = versión(1) ‖ key_id(16) ‖ nonce(12) ‖ ciphertext ‖ tag(16) */
export function seal(dek: Buffer, keyId: string, ctx: BlobContext, plaintext: string): Buffer {
  const nonce = randomBytes(12);
  const c = createCipheriv("aes-256-gcm", dek, nonce);
  c.setAAD(blobAad(ctx));
  const ct = Buffer.concat([c.update(plaintext, "utf8"), c.final()]);
  return Buffer.concat([Buffer.from([FORMAT]), uuidBytes(keyId), nonce, ct, c.getAuthTag()]);
}

export function open(dek: Buffer, expectedKeyId: string, ctx: BlobContext, blob: Buffer): string {
  if (blob.length < 45 || blob[0] !== FORMAT) throw new Error("BLOB_FORMAT_INVALID");
  const keyId = bytesUuid(blob.subarray(1, 17));
  if (keyId !== expectedKeyId) throw new Error("BLOB_KEY_MISMATCH");
  const d = createDecipheriv("aes-256-gcm", dek, blob.subarray(17, 29));
  d.setAAD(blobAad(ctx));
  d.setAuthTag(blob.subarray(blob.length - 16));
  return Buffer.concat([d.update(blob.subarray(29, blob.length - 16)), d.final()]).toString("utf8");
}

export const sha256Hex = (b: Buffer | string) => createHash("sha256").update(b).digest("hex");

/** HMAC con clave separada y ámbito por tenant: permite comparar prompts sin descifrarlos ni exponer un SHA adivinable. */
export function promptHmac(env: NodeJS.ProcessEnv, workspaceId: string, prompt: string): Buffer {
  const k = env.PREMORTEM_PROMPT_HMAC_KEY;
  if (!k) throw new Error("CRYPTO_NOT_CONFIGURED: falta PREMORTEM_PROMPT_HMAC_KEY");
  return createHmac("sha256", Buffer.from(k, "base64")).update(`premortem:prompt:v${FORMAT}:${workspaceId}:`).update(prompt, "utf8").digest();
}

export const sameHmac = (a: Buffer, b: Buffer) => a.length === b.length && timingSafeEqual(a, b);
