import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { callAdmin, here } from "@/lib/api";

type Player = {
  id: string; username: string; name: string; level: number;
  gold: string; diamonds: number; state: string; is_bot: boolean; last_seen: string;
};

const n = (v: string | number) => Number(v).toLocaleString("en-US");

export default async function PlayersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; msg?: string; err?: string }>;
}) {
  const { q = "", msg, err } = await searchParams;
  // An empty term matches everyone, and the query is ordered by last_seen_at, so
  // landing on this page with no search shows the 50 most recently active players
  // — which is what a moderator actually wants to see first.
  const res = await callAdmin<{ players: Player[] }>(`/players?q=${encodeURIComponent(q)}`);

  // Server actions, so no admin token ever reaches the browser and every write
  // goes through the Go API that owns the game's invariants.
  //
  // A refused write comes BACK to this page with its reason, rather than being
  // thrown. Throwing produced Next's 500 screen, so a moderator who mistyped a
  // grant got a crash page, lost their search, and never found out that the
  // refusal was "that would leave a negative balance" -- while this page has
  // carried an error slot for exactly that message all along.
  async function adjust(formData: FormData) {
    "use server";
    const back = String(formData.get("q") || "");
    const r = await callAdmin("/players/currency", {
      method: "POST",
      body: {
        player_id: String(formData.get("player_id")),
        gold: Number(formData.get("gold") || 0),
        diamonds: Number(formData.get("diamonds") || 0),
        note: String(formData.get("note") || "via panel"),
      },
    });
    revalidatePath("/players");
    redirect(here(back, r.ok ? { msg: "Granted." } : { err: r.message }));
  }

  async function setState(formData: FormData) {
    "use server";
    const back = String(formData.get("q") || "");
    const state = String(formData.get("state"));
    const r = await callAdmin("/players/state", {
      method: "POST",
      body: {
        player_id: String(formData.get("player_id")),
        state,
        note: String(formData.get("note") || "via panel"),
      },
    });
    revalidatePath("/players");
    redirect(here(back, r.ok ? { msg: state === "banned" ? "Banned." : "Unbanned." } : { err: r.message }));
  }

  return (
    <>
      <h1>Players</h1>
      <p className="muted">
        Every grant and every ban is written to the audit trail with its before and
        after values, and a currency grant also writes a ledger row so the economy
        dashboard stays honest.
      </p>

      <form className="card row" style={{ marginTop: 16 }}>
        <input name="q" defaultValue={q} placeholder="Search by username or display name" style={{ flex: 1 }} />
        <button type="submit">Search</button>
        {q ? <a className="ghost button" href="/players">Clear</a> : null}
      </form>

      {msg ? <p className="ok">{msg}</p> : null}
      {err ? <p className="err">{err}</p> : null}

      {!res.ok ? <p className="err">{res.message}</p> : null}

      {res.ok ? (
        <div className="card" style={{ marginTop: 12 }}>
          <p className="muted" style={{ margin: "0 0 10px" }}>
            {q
              ? `${res.data.players.length} match${res.data.players.length === 1 ? "" : "es"} for “${q}”.`
              : "The 50 most recently active players. Search to narrow."}
          </p>
          <table>
            <thead>
              <tr>
                <th>Player</th><th className="num">Level</th><th className="num">Gold</th>
                <th className="num">Diamonds</th><th>State</th><th>Last seen</th><th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {res.data.players.map((p) => (
                <tr key={p.id}>
                  <td>
                    <div>{p.name}</div>
                    <div className="muted" style={{ fontSize: 11 }}>
                      {p.username}{p.is_bot ? " · bot" : ""}
                    </div>
                  </td>
                  <td className="num">{p.level}</td>
                  <td className="num">{n(p.gold)}</td>
                  <td className="num">{n(p.diamonds)}</td>
                  <td>
                    <span className={p.state === "banned" ? "pill err" : "pill"}>{p.state}</span>
                  </td>
                  <td className="muted">{p.last_seen}</td>
                  <td>
                    <div className="row">
                      <form action={adjust} className="row" style={{ gap: 6 }}>
                        <input type="hidden" name="player_id" value={p.id} />
                        <input type="hidden" name="q" value={q} />
                        <input name="gold" placeholder="gold" style={{ width: 92 }} />
                        <input name="note" placeholder="reason" style={{ width: 120 }} />
                        <button className="ghost" type="submit">Grant</button>
                      </form>
                      <form action={setState}>
                        <input type="hidden" name="player_id" value={p.id} />
                        <input type="hidden" name="q" value={q} />
                        <input type="hidden" name="state" value={p.state === "banned" ? "active" : "banned"} />
                        <button className={p.state === "banned" ? "ghost" : "danger"} type="submit">
                          {p.state === "banned" ? "Unban" : "Ban"}
                        </button>
                      </form>
                    </div>
                  </td>
                </tr>
              ))}
              {res.data.players.length === 0 ? (
                <tr>
                  <td colSpan={7} className="muted">
                    {q ? `Nobody matched “${q}”.` : "No players yet."}
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>
      ) : null}
    </>
  );
}
