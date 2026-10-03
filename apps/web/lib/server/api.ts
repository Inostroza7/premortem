// PREMORTEM · utilidades de servidor para las rutas /api. Solo se importan desde route handlers.
import "server-only";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { ZodError } from "zod";
import { ApiDb, connect, DbError } from "@premortem/db";

// ---------------------------------------------------------------------------
// Entorno
// ---------------------------------------------------------------------------
const env = (name: string): string => {
  const v = process.env[name];
  if (!v) throw new HttpError(503, "CONFIG_MISSING", `Falta la variable ${name} en el servidor`);
  return v;
};

let apiDb: ApiDb | null = null;
export function db(): ApiDb {
  if (!apiDb) {
    const url = env("SUPABASE_DB_URL_API");
    apiDb = new ApiDb(connect(url, { max: 5, transactionPooler: new URL(url).port === "6543" }));
  }
  return apiDb;
}

const supabaseUrl = () => env("NEXT_PUBLIC_SUPABASE_URL");
const publishableKey = () => env("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY");

/** Cliente con el token del usuario: todas las lecturas pasan por RLS. */
export function userClient(token: string): SupabaseClient {
  return createClient(supabaseUrl(), publishableKey(), {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// ---------------------------------------------------------------------------
// Errores y respuestas
// ---------------------------------------------------------------------------
export class HttpError extends Error {
  constructor(readonly status: number, readonly code: string, message: string, readonly detail?: string) {
    super(message);
  }
}

const corsOrigins = () => (process.env.CORS_ORIGINS ?? "http://localhost:3000,http://localhost:5173").split(",").map((s) => s.trim());

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin");
  const allowed = origin && (corsOrigins().includes("*") || corsOrigins().includes(origin)) ? origin : null;
  return allowed
    ? {
        "Access-Control-Allow-Origin": allowed,
        "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
        "Access-Control-Allow-Headers": "Authorization,Content-Type,Idempotency-Key,X-Workspace-Id,X-Project-Id",
        "Access-Control-Max-Age": "600",
        Vary: "Origin",
      }
    : {};
}

export function json(req: Request, body: unknown, status = 200, extra: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", ...corsHeaders(req), ...extra },
  });
}

export const preflight = (req: Request) => new Response(null, { status: 204, headers: corsHeaders(req) });

function toErrorResponse(req: Request, e: unknown) {
  if (e instanceof HttpError) return json(req, { error: { code: e.code, message: e.message, detail: e.detail } }, e.status);
  if (e instanceof ZodError) {
    return json(req, { error: { code: "VALIDATION_ERROR", message: "Cuerpo de la petición inválido", detail: e.issues.map((i) => `${i.path.join(".") || "(raíz)"}: ${i.message}`).join("; ") } }, 400);
  }
  if (e instanceof DbError) {
    const status = e.httpStatus;
    if (status === 500) {
      console.error("db_error", e.sqlstate, e.message);
      return json(req, { error: { code: "INTERNAL", message: "Error interno" } }, 500);
    }
    return json(req, { error: { code: e.message, message: e.hint ?? e.message, detail: e.detail } }, status);
  }
  const status = (e as { status?: unknown })?.status;
  if (typeof status === "number" && (e as { constructor?: { name?: string } })?.constructor?.name?.endsWith("Error") && "error" in (e as object)) {
    // Error del proveedor de modelos (Anthropic): se informa sin detalles internos ni credenciales.
    console.error("model_provider_error", status);
    return json(req, { error: { code: "MODEL_PROVIDER_ERROR", message: `El proveedor de modelos respondió ${status}` } }, 502);
  }
  console.error("unhandled", e);
  return json(req, { error: { code: "INTERNAL", message: "Error interno" } }, 500);
}

// ---------------------------------------------------------------------------
// Contexto autenticado: usuario validado por Supabase Auth y workspace por membresía
// ---------------------------------------------------------------------------
export type Ctx = {
  req: Request;
  userId: string;
  email: string | null;
  token: string;
  sb: SupabaseClient;
  workspaceId: string;
  projectId: string;
};

async function resolveContext(req: Request): Promise<Ctx> {
  const auth = req.headers.get("authorization") ?? "";
  const token = auth.toLowerCase().startsWith("bearer ") ? auth.slice(7).trim() : "";
  if (!token) throw new HttpError(401, "UNAUTHENTICATED", "Falta Authorization: Bearer <access_token> de Supabase");
  const sb = userClient(token);
  const { data, error } = await sb.auth.getUser(token);
  if (error || !data.user) throw new HttpError(401, "UNAUTHENTICATED", "Sesión inválida o expirada");

  const { data: memberships, error: mErr } = await sb
    .from("workspace_members")
    .select("workspace_id, role, created_at")
    .eq("user_id", data.user.id)
    .order("created_at", { ascending: true });
  if (mErr) throw new HttpError(500, "INTERNAL", "No se pudo leer la membresía");
  if (!memberships?.length) throw new HttpError(403, "NO_WORKSPACE", "El usuario no pertenece a ningún workspace");
  const wanted = req.headers.get("x-workspace-id");
  const ws = wanted ? memberships.find((m) => m.workspace_id === wanted) : memberships[0];
  if (!ws) throw new HttpError(404, "WORKSPACE_NOT_FOUND", "Workspace no encontrado");

  const { data: projects } = await sb.from("projects").select("id, created_at").eq("workspace_id", ws.workspace_id).order("created_at", { ascending: true });
  const wantedProject = req.headers.get("x-project-id");
  const project = wantedProject ? projects?.find((p) => p.id === wantedProject) : projects?.[0];
  if (!project) throw new HttpError(404, "PROJECT_NOT_FOUND", "Proyecto no encontrado");

  return { req, userId: data.user.id, email: data.user.email ?? null, token, sb, workspaceId: ws.workspace_id, projectId: project.id };
}

type Params = Record<string, string>;
type RouteArgs = { params: Promise<Params> };

/** Envuelve un handler autenticado: CORS, sesión, workspace y mapeo de errores. */
export function authed(handler: (ctx: Ctx, params: Params) => Promise<Response>) {
  return async (req: Request, args?: RouteArgs) => {
    try {
      const params: Params = (args?.params ? await args.params : undefined) ?? {};
      // IDs de ruta mal formados: 404 (no existe), nunca un error interno por el cast a uuid.
      if (params.id !== undefined && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(params.id)) {
        throw new HttpError(404, "NOT_FOUND", "Recurso no encontrado");
      }
      const ctx = await resolveContext(req);
      return await handler(ctx, params);
    } catch (e) {
      return toErrorResponse(req, e);
    }
  };
}

export function open(handler: (req: Request) => Promise<Response>) {
  return async (req: Request) => {
    try {
      return await handler(req);
    } catch (e) {
      return toErrorResponse(req, e);
    }
  };
}

export async function body(req: Request): Promise<unknown> {
  const text = await req.text();
  if (!text) return {};
  if (text.length > 64 * 1024) throw new HttpError(413, "PAYLOAD_TOO_LARGE", "Cuerpo mayor de 64 KiB");
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(400, "INVALID_JSON", "El cuerpo no es JSON válido");
  }
}

/** Lanza 404 si una lectura RLS no devuelve la fila (recurso ausente o ajeno: mismo código). */
export function must<T>(row: T | null | undefined, what: string): T {
  if (!row) throw new HttpError(404, "NOT_FOUND", `${what} no encontrado`);
  return row;
}

/** PostgREST devuelve bytea como "\\x…". */
export const hexOf = (v: unknown): string | null => (typeof v === "string" ? v.replace(/^\\x/, "") : null);
