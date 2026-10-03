import { ENGINE_VERSION } from "@premortem/engine";
import { db, json, open, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const GET = open(async (req) => {
  let database = "ok";
  try { await db().ping(); } catch { database = "unavailable"; }
  return json(req, { ok: database === "ok", service: "premortem-api", engine_version: ENGINE_VERSION, database, environment: process.env.PREMORTEM_ENV === "local" ? "local" : "hosted" }, database === "ok" ? 200 : 503);
});
