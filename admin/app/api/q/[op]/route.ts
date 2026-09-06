import { NextRequest, NextResponse } from "next/server";
import { callAdmin } from "@/lib/server/upstream";
import { READS, type ReadOp } from "@/lib/ops";
import { readSession } from "@/lib/server/session";

/** Reads. The op id names the upstream path; the query is allowlisted per op. */
export async function GET(req: NextRequest, ctx: { params: Promise<{ op: string }> }) {
  const { op } = await ctx.params;
  const spec = (READS as Record<string, { path: string; params: readonly string[] }>)[op];
  if (!spec) {
    return NextResponse.json({ ok: false, code: "unknown_op", message: `no such read: ${op}` }, { status: 404 });
  }
  if (!(await readSession())) {
    return NextResponse.json({ ok: false, code: "unauthorized", message: "sign in again" }, { status: 401 });
  }

  const qs = new URLSearchParams();
  for (const key of spec.params) {
    const v = req.nextUrl.searchParams.get(key);
    if (v !== null && v !== "") qs.set(key, v);
  }
  const suffix = qs.toString();
  const result = await callAdmin(spec.path + (suffix ? "?" + suffix : ""));

  // The Result union is passed through verbatim, including failures: the client
  // renders the server's own sentence rather than a paraphrase of it.
  return NextResponse.json(result, { status: result.ok ? 200 : result.status || 502 });
}
