import { NextRequest, NextResponse } from "next/server";
import { callAdmin } from "@/lib/server/upstream";
import { WRITES, atLeast, type WriteOp } from "@/lib/ops";
import { readSession } from "@/lib/server/session";

/**
 * Writes. Every one of them, and nothing else.
 *
 * The role check here is defence in depth and a better error, not the
 * authority: admin.Service checks it again and is the thing that actually
 * decides. Refusing early means an analyst who somehow reaches a designer
 * control gets a sentence instead of a 500 from a database CHECK.
 */
export async function POST(req: NextRequest, ctx: { params: Promise<{ op: string }> }) {
  const { op } = await ctx.params;
  const spec = (WRITES as Record<string, (typeof WRITES)[WriteOp]>)[op];
  if (!spec) {
    return NextResponse.json({ ok: false, code: "unknown_op", message: `no such write: ${op}` }, { status: 404 });
  }
  const token = await readSession();
  if (!token) {
    return NextResponse.json({ ok: false, code: "unauthorized", message: "sign in again" }, { status: 401 });
  }

  const me = await callAdmin<{ username: string; role: string }>("/me");
  if (!me.ok) {
    return NextResponse.json(me, { status: me.status || 401 });
  }
  if (!atLeast(me.data.role, spec.role)) {
    return NextResponse.json(
      { ok: false, code: "forbidden", message: `this needs the ${spec.role} role; you are ${me.data.role}` },
      { status: 403 },
    );
  }

  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    return NextResponse.json({ ok: false, code: "bad_request", message: "malformed body" }, { status: 400 });
  }

  // Copy exactly the declared fields. Anything else the client sent is dropped
  // here rather than being handed to a Go decoder that may or may not reject it.
  const body: Record<string, unknown> = {};
  const src = (raw ?? {}) as Record<string, unknown>;
  for (const f of spec.fields) {
    if (src[f] !== undefined) body[f] = src[f];
  }

  const result = await callAdmin(spec.path, { method: "POST", body });
  return NextResponse.json(result, { status: result.ok ? 200 : result.status || 502 });
}
