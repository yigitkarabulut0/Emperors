"use client";

import { useState } from "react";
import { Button, Panel } from "@/ui/kit";
import { useRouter } from "next/navigation";

/** Shown when the Go API cannot be reached at all. Names the address and the
 *  command, because "something went wrong" is not a thing anyone can act on. */
export function Degraded({ message }: { message: string }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  return (
    <Panel title="The game server is not answering">
      <p className="u-dim" style={{ marginBottom: "var(--s5)" }}>{message}</p>
      <p className="u-faint" style={{ marginBottom: "var(--s6)" }}>
        Start it with <code>go run ./cmd/api</code> from <code>server/</code>, or open the
        tunnel if the panel should be talking to the deployed box.
      </p>
      <Button
        variant="primary"
        busy={busy}
        onClick={() => { setBusy(true); router.refresh(); setTimeout(() => setBusy(false), 1200); }}
      >
        Try again
      </Button>
    </Panel>
  );
}
