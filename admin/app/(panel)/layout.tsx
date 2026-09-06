import { redirect } from "next/navigation";
import { callAdmin } from "@/lib/server/upstream";
import { readSession } from "@/lib/server/session";
import { StoreProvider } from "@/store/react";
import { AppShell } from "@/ui/Shell";
import { Degraded } from "@/features/Degraded";

export const dynamic = "force-dynamic";

export default async function PanelLayout({ children }: { children: React.ReactNode }) {
  // Cheap first: no cookie means no round trip.
  if (!(await readSession())) redirect("/login");

  const me = await callAdmin<{ username: string; role: string }>("/me");
  if (!me.ok && me.status === 401) redirect("/login");

  // The API being down must not produce a blank page. The shell renders, the
  // failure is named, and the retry is one click -- this is the single most
  // common local failure and the old panel handled it worst.
  if (!me.ok) {
    return (
      <StoreProvider>
        <AppShell me={null} env={process.env.EMPERORS_ENV ?? "local"}>
          <Degraded message={me.message} />
        </AppShell>
      </StoreProvider>
    );
  }

  return (
    <StoreProvider initial={{ me: me.data as never }}>
      <AppShell me={me.data} env={process.env.EMPERORS_ENV ?? "local"}>
        {children}
      </AppShell>
    </StoreProvider>
  );
}
