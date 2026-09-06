import { NextRequest, NextResponse } from "next/server";
import { callAdmin } from "@/lib/server/upstream";
import { clearSession, writeSession } from "@/lib/server/session";

type LoginResult = { token: string; username: string; role: string };

/** Sign in. The token is put in an httpOnly cookie and never returned. */
export async function POST(req: NextRequest) {
  let body: { username?: string; password?: string };
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ ok: false, code: "bad_request", message: "malformed body" }, { status: 400 });
  }

  // token: "-" skips the cookie lookup; /login sits outside requireAdmin so the
  // value is ignored, but sending nothing would have callAdmin read a stale
  // cookie and attach someone else's session to a sign-in attempt.
  const res = await callAdmin<LoginResult>("/login", {
    method: "POST",
    body: { username: body.username ?? "", password: body.password ?? "" },
    token: "-",
  });
  if (!res.ok) return NextResponse.json(res, { status: res.status || 401 });

  await writeSession(res.data.token);
  return NextResponse.json({
    ok: true,
    data: { username: res.data.username, role: res.data.role },
  });
}

/** Who am I, and what may I do. */
export async function GET() {
  const res = await callAdmin<{ username: string; role: string }>("/me");
  return NextResponse.json(res, { status: res.ok ? 200 : res.status || 401 });
}

/** Sign out. Revoke upstream first, then drop the cookie regardless — a dead
 *  API must still be able to sign someone out of this browser. */
export async function DELETE() {
  await callAdmin("/logout", { method: "POST" });
  await clearSession();
  return NextResponse.json({ ok: true, data: null });
}
