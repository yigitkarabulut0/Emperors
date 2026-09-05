import { callAdmin } from "@/lib/api";

type Flow = { reason: string; created: string; destroyed: string; entries: number; net: string };
type Dashboard = {
  players: number; bots: number; active_1d: number; active_7d: number; new_1d: number;
  gold_held: string; avg_level: number; battles: number; attacker_win_pct: number;
  gold_moved: string; avg_rounds: number; flows: Flow[]; days: number; balance_version: number;
};

const n = (v: string | number) => Number(v).toLocaleString("en-US");

export default async function DashboardPage() {
  const res = await callAdmin<Dashboard>("/dashboard?days=30");
  if (!res.ok) return <p className="err">{res.message}</p>;
  const d = res.data;

  // Faucets vs sinks is the one number that says whether the economy is healthy.
  // Everything else is context for it.
  const created = d.flows.reduce((a, f) => a + Number(f.created), 0);
  const destroyed = d.flows.reduce((a, f) => a + Number(f.destroyed), 0);
  const inflation = created - destroyed;
  const sinkPct = created > 0 ? Math.round((destroyed / created) * 100) : 0;

  return (
    <>
      <h1>Dashboard</h1>
      <p className="muted">Last {d.days} days · balance version {d.balance_version}</p>

      <div className="grid k4" style={{ marginTop: 18 }}>
        {[
          ["Players", n(d.players), `${n(d.bots)} bots alongside`],
          ["Active this week", n(d.active_7d), `${n(d.active_1d)} today`],
          ["New today", n(d.new_1d), `avg level ${d.avg_level.toFixed(1)}`],
          ["Gold held", n(d.gold_held), "across all players"],
        ].map(([l, v, s]) => (
          <div key={l} className="card stat">
            <div className="l">{l}</div>
            <div className="n">{v}</div>
            <div className="muted" style={{ fontSize: 12 }}>{s}</div>
          </div>
        ))}
      </div>

      <div className="grid k2" style={{ marginTop: 12 }}>
        <div className="card">
          <h2>Economy</h2>
          <div className="row" style={{ justifyContent: "space-between" }}>
            <span className="muted">created</span><span className="num">{n(created)}</span>
          </div>
          <div className="row" style={{ justifyContent: "space-between" }}>
            <span className="muted">destroyed</span><span className="num">{n(destroyed)}</span>
          </div>
          <div className="row" style={{ justifyContent: "space-between", marginBottom: 8 }}>
            <span className="muted">net</span>
            <span className={inflation > 0 ? "err" : "ok"}>{inflation > 0 ? "+" : ""}{n(inflation)}</span>
          </div>
          <div className="bar"><i style={{ width: `${Math.min(sinkPct, 100)}%` }} /></div>
          <p className="muted" style={{ fontSize: 12, marginBottom: 0 }}>
            Sinks absorb {sinkPct}% of what faucets create. Below 100% the gold supply
            grows, which is fine early and a problem once the population stops growing.
          </p>
        </div>

        <div className="card">
          <h2>Raids</h2>
          <div className="row" style={{ justifyContent: "space-between" }}>
            <span className="muted">battles</span><span>{n(d.battles)}</span>
          </div>
          <div className="row" style={{ justifyContent: "space-between" }}>
            <span className="muted">attacker wins</span><span>{d.attacker_win_pct.toFixed(0)}%</span>
          </div>
          <div className="row" style={{ justifyContent: "space-between" }}>
            <span className="muted">gold moved</span><span>{n(d.gold_moved)}</span>
          </div>
          <div className="row" style={{ justifyContent: "space-between" }}>
            <span className="muted">average length</span><span>{d.avg_rounds.toFixed(0)} rounds</span>
          </div>
          <p className="muted" style={{ fontSize: 12, marginBottom: 0 }}>
            Combat is calibrated so a +20% Might advantage wins 75% of the time. A
            population-wide attacker win rate far from 50% means matchmaking is
            offering the wrong opponents, not that combat is wrong.
          </p>
        </div>
      </div>

      <div className="card" style={{ marginTop: 12 }}>
        <h2>Where gold comes from and goes</h2>
        <table>
          <thead>
            <tr>
              <th>Reason</th><th className="num">Created</th>
              <th className="num">Destroyed</th><th className="num">Net</th><th className="num">Entries</th>
            </tr>
          </thead>
          <tbody>
            {d.flows.map((f) => (
              <tr key={f.reason}>
                <td>{f.reason}</td>
                <td className="num ok">{Number(f.created) ? n(f.created) : "—"}</td>
                <td className="num err">{Number(f.destroyed) ? n(f.destroyed) : "—"}</td>
                <td className="num">{n(f.net)}</td>
                <td className="num muted">{n(f.entries)}</td>
              </tr>
            ))}
            {d.flows.length === 0 ? (
              <tr><td colSpan={5} className="muted">No gold has moved in this window.</td></tr>
            ) : null}
          </tbody>
        </table>
      </div>
    </>
  );
}
