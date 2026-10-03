// Persistencia en memoria para pruebas de conformidad: misma secuencia, CAS y enlace que la base real.
import { randomUUID } from "node:crypto";
import type { AttemptSink, CommitRequest, CommitResponse } from "@premortem/engine";
import { buildEvent, type WireEvent } from "@premortem/evidence";

export class MemorySink implements AttemptSink {
  version = 0;
  events: WireEvent[] = [];
  commits = new Map<string, CommitResponse>();
  constructor(readonly workspaceId: string, readonly attemptId: string) {
    this.events.push(buildEvent({ eventId: randomUUID(), workspaceId, attemptId, seq: 1, type: "attempt.genesis", audience: "system", publicPayload: {}, privateBlobHash: null, prevHash: null }));
  }
  get head() { return this.events[this.events.length - 1]!.event_hash; }
  append(evs: WireEvent[]) {
    for (const e of evs) {
      const last = this.events[this.events.length - 1]!;
      if (e.seq !== last.seq + 1) throw new Error(`EVENT_SEQ_MISMATCH ${e.seq}`);
      if (e.prev_hash !== last.event_hash) throw new Error(`EVENT_CHAIN_BROKEN ${e.seq}`);
      this.events.push(e);
    }
  }
  async commit(req: CommitRequest): Promise<CommitResponse> {
    const prev = this.commits.get(req.commitId);
    if (prev) return { ...prev, replayed: true };
    if (req.expectedVersion !== this.version) throw new Error("STATE_STALE");
    if (req.events.length === 0) throw new Error("EVENTS_REQUIRED");
    const ids = new Set(req.events.map((e) => e.event_id));
    for (const f of req.effects) if (!ids.has(f.event_id)) throw new Error("EFFECT_EVENT_NOT_IN_TRANSITION");
    this.append(req.events);
    this.version += 1;
    const res = { observation: req.observation, stateVersion: this.version, replayed: false };
    this.commits.set(req.commitId, res);
    return res;
  }
}
