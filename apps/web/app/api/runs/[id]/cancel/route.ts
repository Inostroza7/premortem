import { authed, db, json, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const POST = authed(async (ctx, p) => json(ctx.req, await db().cancelRun(p.id!, ctx.workspaceId, ctx.userId)));
