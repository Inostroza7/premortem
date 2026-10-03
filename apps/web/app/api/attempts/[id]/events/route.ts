import { authed, hexOf, json, preflight } from "@/lib/server/api";

export const dynamic = "force-dynamic";
export const OPTIONS = preflight;
/** Traza paginada. ?after_seq=N&limit=200&audience=agent|inspector|system (opcional). */
export const GET = authed(async (ctx, p) => {
  const u = new URL(ctx.req.url);
  const after = Math.max(Number(u.searchParams.get("after_seq") ?? 0) || 0, 0);
  const limit = Math.min(Math.max(Number(u.searchParams.get("limit") ?? 200) || 200, 1), 500);
  let q = ctx.sb.from("attempt_events").select("event_id, seq, type, audience, public_payload, event_hash, prev_hash, created_at")
    .eq("attempt_id", p.id!).gt("seq", after).order("seq").limit(limit);
  const audience = u.searchParams.get("audience");
  if (audience) q = q.eq("audience", audience);
  const { data, error } = await q;
  if (error) throw error;
  const events = (data ?? []).map((e: any) => ({ ...e, event_hash: hexOf(e.event_hash), prev_hash: hexOf(e.prev_hash) }));
  return json(ctx.req, { events, next_after_seq: events.length ? events[events.length - 1].seq : after, has_more: events.length === limit });
});
