// PREMORTEM · evidencia (spec v2 §14). evidence_format_version = 1.
// Un solo módulo serializa y verifica: JSON canónico (RFC 8785 / JCS) + SHA-256.
import { createHash } from "node:crypto";

export const EVIDENCE_FORMAT_VERSION = 1 as const;

/**
 * JSON canónico según RFC 8785 para los tipos que usa PREMORTEM (null, boolean, número finito, string,
 * array, objeto). Claves ordenadas por unidades UTF-16; números y strings con la serialización de ECMAScript,
 * que es la que exige JCS. Rechaza undefined, NaN, Infinity, funciones y objetos no planos.
 */
export function canonicalize(value: unknown): string {
  if (value === null) return "null";
  switch (typeof value) {
    case "boolean":
      return value ? "true" : "false";
    case "number":
      if (!Number.isFinite(value)) throw new TypeError("JCS: número no finito");
      return JSON.stringify(value);
    case "string":
      return JSON.stringify(value);
    case "object": {
      if (Array.isArray(value)) return "[" + value.map((v) => canonicalize(v)).join(",") + "]";
      const proto = Object.getPrototypeOf(value);
      if (proto !== Object.prototype && proto !== null) throw new TypeError("JCS: objeto no plano");
      const entries = Object.entries(value as Record<string, unknown>);
      for (const [k, v] of entries) if (v === undefined) throw new TypeError(`JCS: valor undefined en "${k}"`);
      entries.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
      return "{" + entries.map(([k, v]) => JSON.stringify(k) + ":" + canonicalize(v)).join(",") + "}";
    }
    default:
      throw new TypeError(`JCS: tipo no admitido ${typeof value}`);
  }
}

export function sha256Hex(input: string | Uint8Array): string {
  return createHash("sha256").update(input).digest("hex");
}

export const hashJson = (value: unknown): string => sha256Hex(canonicalize(value));

export type Audience = "agent" | "inspector" | "system";

export type EnvelopeInput = {
  eventId: string;
  workspaceId: string;
  attemptId: string;
  seq: number;
  type: string;
  audience: Audience;
  publicPayload: Record<string, unknown>;
  privateBlobHash: string | null;
  prevHash: string | null;
};

/** Envelope comprometido por el hash (spec v2 §14). */
export function envelope(e: EnvelopeInput, publicPayloadHash: string) {
  return {
    format: EVIDENCE_FORMAT_VERSION,
    event_id: e.eventId,
    workspace_id: e.workspaceId,
    attempt_id: e.attemptId,
    seq: e.seq,
    type: e.type,
    audience: e.audience,
    public_payload_hash: publicPayloadHash,
    private_blob_hash: e.privateBlobHash,
    prev_hash: e.prevHash,
  };
}

/** Evento listo para core.append_events (claves en snake_case, hashes en hex). */
export type WireEvent = {
  event_id: string;
  seq: number;
  type: string;
  audience: Audience;
  format: 1;
  public_payload: Record<string, unknown>;
  public_payload_hash: string;
  prev_hash: string | null;
  event_hash: string;
  private_payload?: Record<string, unknown>;
  private_blob_hash?: string;
};

export function buildEvent(e: EnvelopeInput): WireEvent {
  if (e.seq === 1 && e.prevHash !== null) throw new Error("el evento génesis no tiene prev_hash");
  if (e.seq > 1 && !e.prevHash) throw new Error("prev_hash requerido para seq > 1");
  const publicPayloadHash = hashJson(e.publicPayload);
  const eventHash = hashJson(envelope(e, publicPayloadHash));
  return {
    event_id: e.eventId,
    seq: e.seq,
    type: e.type,
    audience: e.audience,
    format: 1,
    public_payload: e.publicPayload,
    public_payload_hash: publicPayloadHash,
    prev_hash: e.prevHash,
    event_hash: eventHash,
  };
}

/** Evento tal como se exporta o se lee de public.attempt_events. */
export type StoredEvent = {
  event_id: string;
  workspace_id: string;
  attempt_id: string;
  seq: number;
  type: string;
  audience: Audience;
  public_payload: Record<string, unknown>;
  public_payload_hash: string;
  private_blob_hash: string | null;
  prev_hash: string | null;
  event_hash: string;
};

export type ChainVerification =
  | { ok: true; length: number; head: string | null }
  | { ok: false; length: number; failedAtSeq: number; reason: string };

/**
 * Verifica consistencia interna: secuencia contigua, hash del payload, hash del envelope y enlace.
 * No demuestra autenticidad frente a quien pueda reescribir toda la cadena (spec v2 §14).
 */
export function verifyChain(events: readonly StoredEvent[]): ChainVerification {
  const sorted = [...events].sort((a, b) => a.seq - b.seq);
  let prev: string | null = null;
  for (let i = 0; i < sorted.length; i++) {
    const e = sorted[i]!;
    const fail = (reason: string): ChainVerification => ({ ok: false, length: sorted.length, failedAtSeq: e.seq, reason });
    if (e.seq !== i + 1) return fail("secuencia no contigua");
    if ((e.prev_hash ?? null) !== prev) return fail("prev_hash no enlaza");
    const pph = hashJson(e.public_payload);
    if (pph !== e.public_payload_hash) return fail("public_payload alterado");
    const expected = hashJson(
      envelope(
        {
          eventId: e.event_id,
          workspaceId: e.workspace_id,
          attemptId: e.attempt_id,
          seq: e.seq,
          type: e.type,
          audience: e.audience,
          publicPayload: e.public_payload,
          privateBlobHash: e.private_blob_hash ?? null,
          prevHash: e.prev_hash ?? null,
        },
        pph,
      ),
    );
    if (expected !== e.event_hash) return fail("envelope alterado");
    prev = e.event_hash;
  }
  return { ok: true, length: sorted.length, head: prev };
}
