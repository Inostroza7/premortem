// PREMORTEM · persistencia. Contratos RPC sobre las funciones core.* (spec v2 §11). Los roles de conexión
// (premortem_api, premortem_worker) no tienen privilegios de tabla: todo pasa por estas funciones.
import postgres from "postgres";

export type Sql = postgres.Sql;

export function connect(url: string, opts: { max?: number; transactionPooler?: boolean } = {}): Sql {
  const host = new URL(url).hostname;
  const local = host === "127.0.0.1" || host === "localhost";
  return postgres(url, {
    max: opts.max ?? 5,
    prepare: !opts.transactionPooler,      // el pooler en modo transacción no admite prepared statements
    idle_timeout: 20,
    connect_timeout: 10,
    ssl: local ? false : "require",
    onnotice: () => {},
  });
}

// ---------------------------------------------------------------------------
// Errores: SQLSTATE propios PM4xx → HTTP
// ---------------------------------------------------------------------------
export class DbError extends Error {
  constructor(readonly sqlstate: string, message: string, readonly detail?: string, readonly hint?: string) {
    super(message);
  }
  get httpStatus(): number {
    switch (this.sqlstate) {
      case "PM400": return 400;
      case "PM402": return 402;
      case "PM403": return 403;
      case "PM404": return 404;
      case "PM409": return 409;
      case "PM423": return 409;
      default: return 500;
    }
  }
}

export function asDbError(e: unknown): DbError | null {
  if (e && typeof e === "object" && "code" in e && typeof (e as { code: unknown }).code === "string") {
    const pe = e as { code: string; message: string; detail?: string; hint?: string };
    return new DbError(pe.code, pe.message, pe.detail, pe.hint);
  }
  return null;
}

async function one<T>(q: Promise<readonly { r: T }[]>): Promise<T> {
  try {
    const rows = await q;
    return rows[0]!.r;
  } catch (e) {
    throw asDbError(e) ?? e;
  }
}

const hex = (h: string) => Buffer.from(h, "hex");

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------
export type QueueMessage = { msg_id: string; job_id: string; run_id: string; workspace_id: string; read_ct: number };

export type JobContext = { jobId: string; attemptId: string; worker: string; epoch: number };

export class WorkerDb {
  constructor(readonly sql: Sql) {}

  async dequeue(worker: string, max: number, visibilitySeconds: number): Promise<QueueMessage[]> {
    try {
      const rows = await this.sql<QueueMessage[]>`
        select msg_id::text, job_id, run_id, workspace_id, read_ct from core.dequeue_jobs(${worker}, ${max}::int, ${visibilitySeconds}::int)`;
      return [...rows];
    } catch (e) {
      throw asDbError(e) ?? e;
    }
  }

  claim(jobId: string, attemptId: string, worker: string, ttl: number, genesis: object) {
    const s = this.sql;
    return one<Record<string, any>>(s`select core.claim_job(${jobId}::uuid, ${attemptId}::uuid, ${worker}, ${ttl}::int,
      ${s.json({})}::jsonb, ${s.json({})}::jsonb, ${s.json(genesis as never)}::jsonb) as r`);
  }

  recover(jobId: string, attemptId: string, worker: string, ttl: number, genesis: object) {
    const s = this.sql;
    return one<Record<string, any>>(s`select core.recover_job(${jobId}::uuid, ${attemptId}::uuid, ${worker}, ${ttl}::int,
      ${s.json({})}::jsonb, ${s.json({})}::jsonb, ${s.json(genesis as never)}::jsonb) as r`);
  }

  heartbeat(c: JobContext, ttl: number, msgId: string | null) {
    return one<{ ok: boolean; cancel_requested?: boolean; reason?: string }>(
      this.sql`select core.heartbeat_job(${c.jobId}::uuid, ${c.worker}, ${c.epoch}::int, ${ttl}::int, ${msgId}::bigint) as r`,
    );
  }

  readInputs(c: JobContext) {
    return one<Record<string, any>>(this.sql`select core.read_job_inputs(${c.jobId}::uuid, ${c.attemptId}::uuid, ${c.worker}, ${c.epoch}::int) as r`);
  }

  commit(c: JobContext, req: {
    commitId: string; callId: string; tool: string; fingerprintHex: string; expectedVersion: number;
    nextState: object; injectionState: object; events: object[]; effects: object[]; observation: object;
  }) {
    const s = this.sql;
    return one<{ ok: boolean; replayed: boolean; observation: any; state_version: number }>(s`
      select core.commit_transition(${c.jobId}::uuid, ${c.attemptId}::uuid, ${c.worker}, ${c.epoch}::int,
        ${req.commitId}::uuid, ${req.callId}, ${req.tool}, ${hex(req.fingerprintHex)}::bytea, ${req.expectedVersion}::int,
        ${s.json(req.nextState as never)}::jsonb, ${s.json(req.injectionState as never)}::jsonb,
        ${s.json(req.events as never)}::jsonb, ${s.json(req.effects as never)}::jsonb, ${s.json(req.observation as never)}::jsonb) as r`);
  }

  finish(c: JobContext, f: {
    termination: string; verdict: string; finalOutput: object | null; ruleResults: object[]; usage: object; events: object[];
  }) {
    const s = this.sql;
    return one<Record<string, any>>(s`
      select core.finish_attempt(${c.jobId}::uuid, ${c.attemptId}::uuid, ${c.worker}, ${c.epoch}::int,
        ${f.termination}, ${f.verdict}, ${f.finalOutput === null ? null : s.json(f.finalOutput as never)}::jsonb, null::jsonb,
        ${s.json(f.ruleResults as never)}::jsonb, ${s.json(f.usage as never)}::jsonb, ${s.json(f.events as never)}::jsonb) as r`);
  }

  extendVisibility(msgId: string, worker: string, seconds: number): Promise<boolean> {
    return one<boolean>(this.sql`select core.extend_visibility(${msgId}::bigint, ${worker}, ${seconds}::int) as r`);
  }

  async archive(msgId: string, worker: string): Promise<boolean> {
    return one<boolean>(this.sql`select core.archive_message(${msgId}::bigint, ${worker}) as r`);
  }
}

// ---------------------------------------------------------------------------
// API (el user_id llega validado por Supabase Auth; workspace se verifica dentro de cada función)
// ---------------------------------------------------------------------------
export class ApiDb {
  constructor(readonly sql: Sql) {}

  registerDomainPack(packId: string, version: string, contentHashHex: string, manifest: object, engineMinVersion: string) {
    const s = this.sql;
    return one<string>(s`select core.register_domain_pack(${packId}, ${version}, ${hex(contentHashHex)}::bytea,
      ${s.json(manifest as never)}::jsonb, ${engineMinVersion}) as r`);
  }

  createAgentVersion(a: { workspaceId: string; userId: string; label: string; driver: string; driverVersion: string;
    policyId: string | null; modelId: string | null; config: object; contentHashHex: string }) {
    const s = this.sql;
    return one<string>(s`select core.create_agent_version(${a.workspaceId}::uuid, ${a.userId}::uuid, ${a.label}, ${a.driver},
      ${a.driverVersion}, ${a.policyId}, ${a.modelId}, ${s.json(a.config as never)}::jsonb, ${hex(a.contentHashHex)}::bytea) as r`);
  }

  createCaseVersion(c: { workspaceId: string; userId: string; projectId: string; packVersionId: string; label: string;
    fixtureVersion: string; task: object; publicContext: object; fixture: object; oracle: object; contentHashHex: string }) {
    const s = this.sql;
    return one<string>(s`select core.create_case_version(${c.workspaceId}::uuid, ${c.userId}::uuid, ${c.projectId}::uuid,
      ${c.packVersionId}::uuid, ${c.label}, ${c.fixtureVersion}, ${s.json(c.task as never)}::jsonb, ${s.json(c.publicContext as never)}::jsonb,
      ${s.json(c.fixture as never)}::jsonb, ${s.json(c.oracle as never)}::jsonb, ${hex(c.contentHashHex)}::bytea) as r`);
  }

  quoteRun(q: { workspaceId: string; userId: string; projectId: string; caseVersionId: string; agentVersionId: string;
    scenarioIds: string[]; repetitions: number; limits: object }) {
    const s = this.sql;
    return one<Record<string, any>>(s`select core.quote_run(${q.workspaceId}::uuid, ${q.userId}::uuid, ${q.projectId}::uuid,
      ${q.caseVersionId}::uuid, ${q.agentVersionId}::uuid, ${s.array(q.scenarioIds)}::text[], ${q.repetitions}::int,
      ${s.json(q.limits as never)}::jsonb) as r`);
  }

  createRun(q: { workspaceId: string; userId: string; projectId: string; caseVersionId: string; agentVersionId: string;
    scenarioIds: string[]; repetitions: number; seed: number; limits: object; idempotencyKey: string | null; requestBody: object | null;
    engineVersion: string }) {
    const s = this.sql;
    return one<Record<string, any>>(s`select core.create_run(${q.workspaceId}::uuid, ${q.userId}::uuid, ${q.projectId}::uuid,
      ${q.caseVersionId}::uuid, ${q.agentVersionId}::uuid, ${s.array(q.scenarioIds)}::text[], ${q.repetitions}::int, ${q.seed}::int,
      ${s.json(q.limits as never)}::jsonb, 'evaluation', ${q.idempotencyKey},
      ${q.requestBody === null ? null : s.json(q.requestBody as never)}::jsonb, null::uuid, null::jsonb, null::jsonb, ${q.engineVersion}) as r`);
  }

  cancelRun(runId: string, workspaceId: string, userId: string) {
    return one<Record<string, any>>(this.sql`select core.cancel_run(${runId}::uuid, ${workspaceId}::uuid, ${userId}::uuid) as r`);
  }

  readWallet(workspaceId: string, userId: string) {
    return one<Record<string, any>>(this.sql`select core.read_wallet(${workspaceId}::uuid, ${userId}::uuid) as r`);
  }

  async ping(): Promise<boolean> {
    const rows = await this.sql`select 1 as ok`;
    return rows.length === 1;
  }
}
