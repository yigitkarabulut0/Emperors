import Link from "next/link";
import { callAdmin } from "@/lib/api";
import { PlayerTable, type Row } from "./PlayerTable";

type Browse = { players: Row[]; total: number; offset: number; limit: number };

export default async function PlayersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; sort?: string; state?: string; bots?: string; min_level?: string; offset?: string }>;
}) {
  const sp = await searchParams;
  const q = sp.q ?? "";
  const sort = sp.sort ?? "last_seen";
  const offset = Number(sp.offset ?? 0);
  const limit = 50;

  const params = new URLSearchParams({
    q, sort, state: sp.state ?? "", bots: sp.bots ?? "",
    min_level: sp.min_level ?? "0", limit: String(limit), offset: String(offset),
  });
  const res = await callAdmin<Browse>(`/players/browse?${params}`);

  const link = (patch: Record<string, string>) => {
    const u = new URLSearchParams({ q, sort, ...(sp.state ? { state: sp.state } : {}),
      ...(sp.bots ? { bots: sp.bots } : {}), ...(sp.min_level ? { min_level: sp.min_level } : {}) });
    for (const [k, v] of Object.entries(patch)) v ? u.set(k, v) : u.delete(k);
    return `/players?${u}`;
  };

  return (
    <>
      <h1>Players</h1>
      <p className="muted">
        Grants and bans happen in place — the row updates, the page does not reload.
        Every one is written to the audit trail with its before and after values,
        and a gold grant also writes a ledger row so the economy stays honest.
      </p>

      {/* Filters navigate; only writes stay inline. A filter IS a new question,
          and its answer belongs in the URL so it can be shared and reloaded. */}
      <div className="card card-tight">
        <form className="row wrap" style={{ gap: 8 }} action="/players">
          <input name="q" defaultValue={q} placeholder="username or display name" style={{ flex: 1, minWidth: 220 }} />
          <select name="sort" defaultValue={sort}>
            <option value="last_seen">Last seen</option>
            <option value="created">Newest</option>
            <option value="level">Level</option>
            <option value="gold">Gold</option>
          </select>
          <select name="state" defaultValue={sp.state ?? ""}>
            <option value="">Any state</option>
            <option value="active">Active</option>
            <option value="banned">Banned</option>
          </select>
          <input name="min_level" defaultValue={sp.min_level ?? ""} placeholder="min level" style={{ width: 110 }} />
          <label className="row muted" style={{ gap: 6 }}>
            <input type="checkbox" name="bots" value="1" defaultChecked={sp.bots === "1"} style={{ width: 16 }} />
            bots
          </label>
          <button type="submit">Search</button>
          {q || sp.state || sp.bots || sp.min_level ? <Link href="/players" className="button ghost">Clear</Link> : null}
        </form>
      </div>

      <div className="card">
        {!res.ok ? <p className="err">{res.message}</p> : (
          <>
            <div className="head">
              <h2>{res.data.total.toLocaleString("en-US")} players</h2>
              <span className="muted">
                {offset + 1}–{Math.min(offset + limit, res.data.total)}
              </span>
            </div>
            <PlayerTable rows={res.data.players} />
            <div className="row" style={{ justifyContent: "space-between", marginTop: 14 }}>
              {offset > 0
                ? <Link className="button ghost" href={link({ offset: String(Math.max(0, offset - limit)) })}>← Previous</Link>
                : <span />}
              {offset + limit < res.data.total
                ? <Link className="button ghost" href={link({ offset: String(offset + limit) })}>Next →</Link>
                : <span />}
            </div>
          </>
        )}
      </div>
    </>
  );
}
