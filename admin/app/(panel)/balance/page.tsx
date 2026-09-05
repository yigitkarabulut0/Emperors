import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { callAdmin } from "@/lib/api";

type Version = {
  id: number; note: string; created_by: string; created_at: string;
  ever_activated: boolean; live: boolean; bytes: number;
};

export default async function BalancePage({
  searchParams,
}: {
  searchParams: Promise<{ err?: string; ok?: string }>;
}) {
  const { err, ok } = await searchParams;
  const [cur, hist] = await Promise.all([
    callAdmin<{ version: number; document: unknown }>("/balance"),
    callAdmin<{ versions: Version[] }>("/balance/versions"),
  ]);
  if (!cur.ok) return <p className="err">{cur.message}</p>;

  async function publish(formData: FormData) {
    "use server";
    let document: unknown;
    try {
      document = JSON.parse(String(formData.get("document") ?? ""));
    } catch (e) {
      redirect(`/balance?err=${encodeURIComponent("That is not valid JSON: " + (e as Error).message)}`);
    }
    const r = await callAdmin<{ id: number }>("/balance/publish", {
      method: "POST",
      body: { document, note: String(formData.get("note") || "") },
    });
    if (!r.ok) {
      // The server validates before storing, so a rejected document never
      // becomes a version a future rollback could pick by mistake.
      redirect(`/balance?err=${encodeURIComponent(r.message)}`);
    }
    revalidatePath("/balance");
    redirect(`/balance?ok=${encodeURIComponent(`Published version ${r.data.id}. It is live now.`)}`);
  }

  async function rollback(formData: FormData) {
    "use server";
    const r = await callAdmin<{ id: number }>("/balance/rollback", {
      method: "POST",
      body: {
        version_id: Number(formData.get("version_id")),
        reason: String(formData.get("reason") || "rolled back from the panel"),
      },
    });
    if (!r.ok) redirect(`/balance?err=${encodeURIComponent(r.message)}`);
    revalidatePath("/balance");
    redirect(`/balance?ok=${encodeURIComponent(`Version ${r.data.id} is live again.`)}`);
  }

  return (
    <>
      <h1>Balance</h1>
      <p className="muted">
        Editing here changes the running game with no redeploy and no restart.
        The whole configuration publishes as one document, so there is never a
        moment where the job ladder is new and the item table is still old.
      </p>

      {err ? <div className="card err" style={{ marginTop: 12 }}>{err}</div> : null}
      {ok ? <div className="card ok" style={{ marginTop: 12 }}>{ok}</div> : null}

      <form action={publish} className="card" style={{ marginTop: 16 }}>
        <div className="row" style={{ justifyContent: "space-between" }}>
          <h2 style={{ margin: 0 }}>Live document</h2>
          <span className="pill live">version {cur.data.version}</span>
        </div>
        <p className="muted" style={{ fontSize: 12 }}>
          The server validates before storing anything. A document that would break
          the economy — a job with no energy cost, a ladder where unlocking the next
          job is a downgrade, a missing regen cap — is refused and never becomes a
          version.
        </p>
        <textarea
          name="document"
          rows={22}
          defaultValue={JSON.stringify(cur.data.document, null, 2)}
          spellCheck={false}
        />
        <div className="row" style={{ marginTop: 10 }}>
          <input name="note" placeholder="What changed, and why" style={{ flex: 1 }} />
          <button type="submit">Publish</button>
        </div>
      </form>

      <div className="card" style={{ marginTop: 12 }}>
        <h2>History</h2>
        <p className="muted" style={{ fontSize: 12 }}>
          Activation is append-only. A rollback is another activation, never an edit,
          so what was live when stays knowable — the only way to explain an old
          battle or an old item roll after a rebalance.
        </p>
        <table>
          <thead>
            <tr>
              <th className="num">Version</th><th>Note</th><th>By</th>
              <th>Created</th><th className="num">Size</th><th></th>
            </tr>
          </thead>
          <tbody>
            {hist.ok
              ? hist.data.versions.map((v) => (
                  <tr key={v.id}>
                    <td className="num">
                      {v.id} {v.live ? <span className="pill live">live</span> : null}
                    </td>
                    <td>{v.note || <span className="muted">—</span>}</td>
                    <td className="muted">{v.created_by}</td>
                    <td className="muted">{v.created_at.replace("T", " ").replace("Z", "")}</td>
                    <td className="num muted">{(v.bytes / 1024).toFixed(1)} KB</td>
                    <td>
                      {v.live ? null : (
                        <form action={rollback}>
                          <input type="hidden" name="version_id" value={v.id} />
                          <button className="ghost" type="submit">Make live</button>
                        </form>
                      )}
                    </td>
                  </tr>
                ))
              : null}
          </tbody>
        </table>
      </div>
    </>
  );
}
