"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import s from "./login.module.css";

export function LoginForm({ next }: { next: string }) {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [busy, start] = useTransition();

  async function submit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    const form = new FormData(e.currentTarget);
    const res = await fetch("/api/session", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        username: String(form.get("username") ?? ""),
        password: String(form.get("password") ?? ""),
      }),
    });
    const out = await res.json();
    if (!out.ok) {
      // The field values are deliberately left in place: retyping a username
      // because the password was wrong is a small, avoidable insult.
      setError(out.message ?? "could not sign in");
      return;
    }
    start(() => {
      router.replace(next);
      router.refresh();
    });
  }

  return (
    <form className={s.form} onSubmit={submit}>
      <input name="username" placeholder="username" autoComplete="username" autoFocus required />
      <input name="password" type="password" placeholder="password" autoComplete="current-password" required />
      <div className={s.err}>{error}</div>
      <button type="submit" disabled={busy}>
        {busy ? "signing in…" : "Sign in"}
      </button>
    </form>
  );
}
