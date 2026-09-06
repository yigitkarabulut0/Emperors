import { redirect } from "next/navigation";
import { readSession } from "@/lib/server/session";
import { LoginForm } from "./LoginForm";
import s from "./login.module.css";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string }>;
}) {
  if (await readSession()) redirect("/");
  const { next } = await searchParams;
  // Only same-site paths, so a crafted ?next= cannot bounce an operator to
  // somewhere else after they type a password.
  const dest = next && next.startsWith("/") && !next.startsWith("//") ? next : "/";

  return (
    <main className={s.wrap}>
      <div className={s.card}>
        <div className={s.brand}>⚜ Emperors</div>
        <div className={s.sub}>live operations</div>
        <LoginForm next={dest} />
      </div>
    </main>
  );
}
