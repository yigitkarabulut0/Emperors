import { redirect } from "next/navigation";
import { cookies } from "next/headers";
import { callAdmin, SESSION_COOKIE } from "@/lib/api";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const { error } = await searchParams;

  async function signIn(formData: FormData) {
    "use server";
    const username = String(formData.get("username") ?? "");
    const password = String(formData.get("password") ?? "");

    const res = await callAdmin<{ token: string; role: string }>("/login", {
      method: "POST",
      body: { username, password },
      token: "-", // skip the cookie lookup; there is no session yet
    });
    if (!res.ok) {
      redirect(`/login?error=${encodeURIComponent(res.message)}`);
    }
    // httpOnly, so no script on the page can read a token that grants currency.
    (await cookies()).set(SESSION_COOKIE, res.data.token, {
      httpOnly: true,
      sameSite: "lax",
      path: "/",
      maxAge: 8 * 60 * 60,
    });
    redirect("/");
  }

  return (
    <main style={{ display: "grid", placeItems: "center", minHeight: "100vh" }}>
      <form action={signIn} className="card" style={{ width: 340 }}>
        <h1>EMPERORS</h1>
        <p className="muted" style={{ marginTop: -6 }}>Live operations</p>
        <div className="grid" style={{ marginTop: 18 }}>
          <input name="username" placeholder="Username" autoFocus autoComplete="username" />
          <input name="password" type="password" placeholder="Password" autoComplete="current-password" />
          {error ? <div className="err">{error}</div> : null}
          <button type="submit">Sign in</button>
        </div>
      </form>
    </main>
  );
}
