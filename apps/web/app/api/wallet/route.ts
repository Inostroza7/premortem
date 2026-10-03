import { authed, db, json, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const GET = authed(async (ctx) => json(ctx.req, await db().readWallet(ctx.workspaceId, ctx.userId)));
