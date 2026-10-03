// PREMORTEM · worker. Consume world_jobs de core.job_queue, reclama con lease por job, ejecuta el intento
// con el motor genérico y cierra con veredicto y liquidación. Nunca mantiene locks mientras corre el agente.
import { hostname } from "node:os";
import { randomUUID } from "node:crypto";
import { loadEnv, requireEnv } from "@premortem/config";
import type { Json, JsonObject, Limits, MutationSpec, ReferencePolicy } from "@premortem/contracts";
import { anthropicAgent, anthropicClientFromEnv } from "@premortem/agents";
import { kekFromEnv, open as openBlob, unwrapDek } from "@premortem/crypto";
import { connect, DbError, WorkerDb, type JobContext, type QueueMessage } from "@premortem/db";
import { getPack } from "@premortem/domain-registry";
import { ENGINE_VERSION, executeAttempt, type AttemptSink, type CommitRequest } from "@premortem/engine";
import { buildEvent } from "@premortem/evidence";

const envFile = loadEnv();
const WORKER_ID = process.env.PREMORTEM_WORKER_ID ?? `${hostname()}-${process.pid}`;
const CONCURRENCY = Number(process.env.PREMORTEM_WORKER_CONCURRENCY ?? 4);
const LEASE = Number(process.env.PREMORTEM_LEASE_SECONDS ?? 60);
const HEARTBEAT_MS = Number(process.env.PREMORTEM_HEARTBEAT_SECONDS ?? 15) * 1000;
const POLL_MS = Number(process.env.PREMORTEM_POLL_MS ?? 1000);

const log = (msg: string, extra: Record<string, unknown> = {}) =>
  console.log(JSON.stringify({ t: new Date().toISOString(), worker: WORKER_ID, msg, ...extra }));

const db = new WorkerDb(connect(requireEnv("SUPABASE_DB_URL_WORKER"), { max: CONCURRENCY + 2 }));

class DbSink implements AttemptSink {
  constructor(private readonly ctx: JobContext) {}
  async commit(req: CommitRequest) {
    const r = await db.commit(this.ctx, {
      commitId: req.commitId, callId: req.callId, tool: req.tool, fingerprintHex: req.fingerprintHex,
      expectedVersion: req.expectedVersion, nextState: req.nextState, injectionState: req.injectionState,
      events: req.events, effects: req.effects, observation: req.observation,
    });
    return { observation: r.observation, stateVersion: r.state_version, replayed: r.replayed };
  }
}

function genesis(msg: QueueMessage, attemptId: string) {
  return buildEvent({
    eventId: randomUUID(), workspaceId: msg.workspace_id, attemptId, seq: 1, type: "attempt.genesis", audience: "system",
    publicPayload: { job_id: msg.job_id, run_id: msg.run_id, worker: WORKER_ID, engine_version: ENGINE_VERSION },
    privateBlobHash: null, prevHash: null,
  });
}

/** Selecciona el agente del job. El prompt se descifra solo en memoria y nunca se registra. */
function selectAgent(agent: Record<string, any>, workspaceId: string, policies: Readonly<Record<string, ReferencePolicy>>): ReferencePolicy {
  if (agent.driver === "reference") {
    const p = policies[agent.policy_id];
    if (!p) throw new Error(`POLICY_NOT_IN_PACK:${agent.policy_id}`);
    return p;
  }
  if (agent.driver === "anthropic") {
    const failing = (code: string): ReferencePolicy => ({ id: "unavailable", label: code, description: code, run: async () => { throw new Error(code); } });
    const client = anthropicClientFromEnv();
    if (!client) return failing("PROVIDER_NOT_CONFIGURED");   // termina como provider_error → inconcluso, unidad liberada
    const pr = agent.prompt;
    if (!pr || pr.purged) return failing("PROMPT_UNAVAILABLE");
    let systemPrompt: string;
    if (pr.encrypted) {
      const kek = kekFromEnv();
      const dek = unwrapDek(kek, workspaceId, pr.kek_id, Buffer.from(pr.wrapped_dek, "base64"));
      systemPrompt = openBlob(dek, pr.key_id, { workspaceId, ownerKind: "agent_prompt", column: "prompt", resourceId: pr.payload_id }, Buffer.from(pr.blob_b64, "base64"));
    } else {
      systemPrompt = String(pr.content ?? "");
    }
    const cfg = (agent.config ?? {}) as Record<string, unknown>;
    return anthropicAgent({
      client, model: agent.model_id, systemPrompt,
      ...(typeof cfg.temperature === "number" ? { temperature: cfg.temperature } : {}),
      ...(typeof cfg.max_output_tokens === "number" ? { maxOutputTokens: cfg.max_output_tokens } : {}),
    });
  }
  throw new Error(`DRIVER_NOT_AVAILABLE:${agent.driver}`);
}

async function processMessage(msg: QueueMessage): Promise<void> {
  let attemptId = randomUUID();
  let g = genesis(msg, attemptId);
  let claim = await db.claim(msg.job_id, attemptId, WORKER_ID, LEASE, g);
  if (!claim.claimed) {
    if (claim.reason === "lease_expired") {
      attemptId = randomUUID();
      g = genesis(msg, attemptId);
      claim = await db.recover(msg.job_id, attemptId, WORKER_ID, LEASE, g);
      if (!claim.recovered) {
        log("job no recuperable", { job: msg.job_id, reason: claim.reason });
        if (["recovery_exhausted", "cancelled", "not_running"].includes(claim.reason)) await db.archive(msg.msg_id, WORKER_ID);
        return;
      }
      log("job recuperado", { job: msg.job_id, attempt: claim.attempt_number });
    } else {
      if (claim.reason === "terminal" || claim.reason === "cancelled") await db.archive(msg.msg_id, WORKER_ID);
      // Límite del workspace: reintentar pronto (la base indica retry_after_seconds), no tras el lease completo.
      else if (claim.reason === "workspace_limit") await db.extendVisibility(msg.msg_id, WORKER_ID, Number(claim.retry_after_seconds ?? 5));
      // held: otro worker tiene el lease; el mensaje reaparece cuando vence su visibilidad.
      return;
    }
  }

  const ctx: JobContext = { jobId: msg.job_id, attemptId, worker: WORKER_ID, epoch: Number(claim.lease_epoch) };
  const ac = new AbortController();
  let abortReason: string | undefined;
  const hb = setInterval(async () => {
    try {
      const h = await db.heartbeat(ctx, LEASE, msg.msg_id);
      if (!h.ok) { abortReason = "lease_lost"; ac.abort(); }
      else if (h.cancel_requested) { abortReason = "cancelled"; ac.abort(); }
    } catch (e) {
      log("heartbeat falló", { job: msg.job_id, error: String(e) });
    }
  }, HEARTBEAT_MS);

  try {
    const inputs = await db.readInputs(ctx);
    const manifest = inputs.run.manifest as Record<string, any>;
    const pack = getPack(manifest.pack.pack_id, manifest.pack.version);
    if (!pack) throw new Error(`PACK_NOT_INSTALLED:${manifest.pack.pack_id}@${manifest.pack.version}`);
    const agent = inputs.agent as Record<string, any>;
    const policy = selectAgent(agent, String(inputs.workspace_id), pack.referencePolicies);

    log("ejecutando", { job: msg.job_id, run: msg.run_id, pack: `${pack.ref.id}@${pack.ref.version}`, scenario: inputs.job.scenario_id, policy: policy.id });
    const result = await executeAttempt({
      pack, policy, workspaceId: msg.workspace_id, attemptId, scenarioId: inputs.job.scenario_id,
      mutations: inputs.job.mutations as MutationSpec[], task: inputs.case.task as JsonObject,
      publicContext: inputs.case.public_context as JsonObject, fixture: inputs.case.fixture as JsonObject,
      fixtureVersion: inputs.case.fixture_version, oracle: inputs.case.oracle as JsonObject, limits: inputs.run.limits as Limits,
      requestId: String((inputs.case.task as Record<string, Json>)["request_id"] ?? inputs.job.id),
      manifestHash: String(manifest.case?.content_hash ?? ""), chain: { nextSeq: 2, prevHash: g.event_hash },
      stateVersion: 0, sink: new DbSink(ctx), signal: ac.signal, abortReason: () => abortReason,
    });

    if (abortReason === "lease_lost") {
      log("lease perdido: no se publica veredicto", { job: msg.job_id });
      return;
    }
    const fin = await db.finish(ctx, {
      termination: result.termination,
      verdict: result.verdict,
      finalOutput: result.finalOutput,
      ruleResults: result.checks.map((c) => ({
        rule_id: c.ruleId, status: c.status, category: c.category, expected: c.expected, observed: c.observed,
        evidence_event_ids: c.evidenceEventIds, explanation: c.explanation,
      })),
      usage: result.usage,
      events: result.finalEvents,
    });
    await db.archive(msg.msg_id, WORKER_ID);
    log("job terminado", { job: msg.job_id, verdict: fin.verdict, termination: fin.termination, run_status: fin.run_status });
  } catch (e) {
    const code = e instanceof DbError ? e.sqlstate : "ERR";
    log("job con error", { job: msg.job_id, code, error: e instanceof Error ? e.message : String(e) });
    // Lease/cancelación: el mensaje vuelve por visibilidad y claim/recover deciden. Error de motor: se deja
    // vencer el lease; recover_job reintenta una vez y luego marca error de infraestructura.
  } finally {
    clearInterval(hb);
  }
}

let stopping = false;
const active = new Set<Promise<void>>();

async function loop() {
  log("worker iniciado", { env: envFile, concurrency: CONCURRENCY, lease_seconds: LEASE, engine: ENGINE_VERSION });
  while (!stopping) {
    const free = CONCURRENCY - active.size;
    if (free > 0) {
      try {
        const msgs = await db.dequeue(WORKER_ID, free, LEASE);
        for (const m of msgs) {
          const p = processMessage(m).catch((e) => log("fallo no controlado", { error: String(e) }));
          active.add(p);
          void p.finally(() => active.delete(p));
        }
        if (msgs.length > 0) continue;
      } catch (e) {
        log("dequeue falló", { error: String(e) });
      }
    }
    await new Promise((r) => setTimeout(r, POLL_MS));
  }
  await Promise.allSettled([...active]);
  await db.sql.end({ timeout: 5 });
  log("worker detenido");
}

for (const sig of ["SIGINT", "SIGTERM"] as const) process.on(sig, () => { stopping = true; });
await loop();
