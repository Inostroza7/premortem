import { authed, json, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
export const GET = authed(async (ctx) => {
  const { data, error } = await ctx.sb.from("domain_pack_versions").select("id, pack_id, version, status, manifest, created_at").eq("status", "active").order("pack_id");
  if (error) throw error;
  return json(ctx.req, { domain_packs: data });
});
