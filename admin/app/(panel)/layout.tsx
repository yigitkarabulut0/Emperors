import { redirect } from "next/navigation";
import { cookies } from "next/headers";
import type { ReactNode } from "react";
import { callAdmin, isSignedIn, SESSION_COOKIE } from "@/lib/api";

export default async function PanelLayout({ children }: { children: ReactNode }) {
  if (!(await isSignedIn())) redirect("/login");

  const me = await callAdmin<{ username: string; role: string }>("/me");
  if (!me.ok && me.status === 401) redirect("/login");

  async function signOut() {
    "use server";
    await callAdmin("/logout", { method: "POST" });
    (await cookies()).delete(SESSION_COOKIE);
    redirect("/login");
  }

  return (
    <div className="shell">
      <nav className="rail">
        <div className="brand">EMPERORS</div>
        <a href="/">Overview</a>
        <a href="/players">Players</a>
        <a href="/events">Events</a>
        <a href="/balance">Balance</a>
        <a href="/audit">Audit</a>
        <form action={signOut}>
          <div className="muted" style={{ fontSize: 12, marginBottom: 8 }}>
            {me.ok ? `${me.data.username} · ${me.data.role}` : "signed in"}
          </div>
          <button className="ghost" type="submit" style={{ width: "100%" }}>Sign out</button>
        </form>
      </nav>
      <main className="main">{children}</main>
    </div>
  );
}
