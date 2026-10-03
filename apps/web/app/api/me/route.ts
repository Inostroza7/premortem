import { authed, db, json, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const GET = authed(async (ctx) => {
  const { data: memberships } = await ctx.sb.from("workspace_members").select("role, workspaces(id, name, max_active_jobs, max_jobs_per_run)").eq("user_id", ctx.userId);
  const { data: projects } = await ctx.sb.from("projects").select("id, name, created_at").eq("workspace_id", ctx.workspaceId).order("created_at");
  const wallet = await db().readWallet(ctx.workspaceId, ctx.userId);
  return json(ctx.req, {
    user: { id: ctx.userId, email: ctx.email },
    current: { workspace_id: ctx.workspaceId, project_id: ctx.projectId },
    workspaces: (memberships ?? []).map((m: any) => ({ ...m.workspaces, role: m.role })),
    projects: projects ?? [],
    wallet: { available_units: wallet.available_units, reserved_units: wallet.reserved_units },
  });
});
