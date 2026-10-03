import { authed, json, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const GET = authed(async (ctx) => {
  const projectId = new URL(ctx.req.url).searchParams.get("project_id") ?? ctx.projectId;
  const { data, error } = await ctx.sb.from("case_versions")
    .select("id, project_id, label, fixture_version, task, public_context, created_at, domain_pack_version_id, domain_pack_versions(pack_id, version)")
    .eq("workspace_id", ctx.workspaceId).eq("project_id", projectId).order("created_at", { ascending: false });
  if (error) throw error;
  return json(ctx.req, { cases: data });
});
