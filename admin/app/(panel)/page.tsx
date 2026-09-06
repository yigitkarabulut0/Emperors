import Link from "next/link";
import { callAdmin } from "@/lib/api";
import { Bars } from "@/app/_ui/Chart";

type Point = { day: string; count: number };
type Brief = { id: string; username: string; name: string; level: number; gold: string; state: string; seen: string };
type Analytics = {
  registrations: Point[]; active: Point[]; level_bands: Point[];
  online: Brief[]; online_window_minutes: number; days: number;
};
type Flow = { reason: string; created: string; destroyed: string; net: string; entries: number };
type Dash = {
  players: number; bots: number; active_1d: number; active_7d: number; new_1d: number;
  gold_held: string; avg_level: number; battles: number; attacker_win_pct: number;
  gold_moved: string; avg_rounds: number; flows: Flow[]; days: number; balance_version: number;
};

const n = (v: string | number) => Number(v).toLocaleString("en-US");

export default async function Overview({
  searchParams,
}: { searchParams: Promise<{ days?: string }> }) {
  const { days = "30" } = await searchParams;
  const [a, d] = await Promise.all([
    callAdmin<Analytics>(`/analytics?days=${encodeURIComponent(days)}&online=15`),
    callAdmin<Dash>(`/dashboard?days=${encodeURIComponent(days)}`),
  ]);
  if (!a.ok) return <><h1>Overview</h1><p className="err">{a.message}</p></>;
  if (!d.ok) return <><h1>Overview</h1><p className="err">{d.message}</p></>;

  const created = d.data.flows.reduce((s, f) => s + Number(f.created), 0);
  const destroyed = d.data.flows.reduce((s, f) => s + Number(f.destroyed), 0);
  const sinkPct = created > 0 ? Math.round((destroyed / created) * 100) : 0;
  const totalReg = a.data.registrations.reduce((s, p) => s + p.count, 0);

  return (
    <>
      <div className="head">
        <h1>Overview</h1>
        <div className="row">
          {["7", "30", "90"].map((v) => (
            <Link key={v} href={`/?days=${v}`}
                  className="pill" style={v === days ? { color: "var(--gold)", borderColor: "var(--gold-deep)" } : undefined}>
              {v}d
            </Link>
          ))}
        </div>
      </div>
      <p className="muted">Balance version {d.data.balance_version} · last {a.data.days} days</p>

      <div className="stats">
        <Stat k="Players" v={n(d.data.players)} s={`${n(d.data.bots)} bots alongside`} />
        <Stat k="New this period" v={n(totalReg)} s={`${n(d.data.new_1d)} today`} />
        <Stat k="Active today" v={n(d.data.active_1d)} s={`${n(d.data.active_7d)} this week`} />
        <Stat k="Online now" v={n(a.data.online.length)} s={`last ${a.data.online_window_minutes} min`} />
        <Stat k="Gold held" v={n(d.data.gold_held)} s="across all players" />
        <Stat k="Average level" v={d.data.avg_level.toFixed(1)} />
      </div>

      <div className="grid grid-2">
        <div className="card">
          <h2>Registrations</h2>
          <Bars points={a.data.registrations} />
        </div>
        <div className="card">
          <h2>Active players</h2>
          <Bars points={a.data.active} colour="var(--info)" />
        </div>
      </div>

      <div className="grid grid-2">
        <div className="card">
          <h2>Levels</h2>
          <Bars points={a.data.level_bands} colour="var(--success)" />
        </div>
        <div className="card">
          <h2>Economy</h2>
          <table>
            <tbody>
              <tr><td className="muted">created</td><td className="num">{n(created)}</td></tr>
              <tr><td className="muted">destroyed</td><td className="num">{n(destroyed)}</td></tr>
              <tr><td className="muted">net</td><td className={`num ${created - destroyed > 0 ? "err" : "ok"}`}>
                {created - destroyed > 0 ? "+" : ""}{n(created - destroyed)}</td></tr>
            </tbody>
          </table>
          <p className="muted" style={{ marginTop: 10 }}>
            Sinks absorb {sinkPct}% of what faucets create. Below 100% the supply grows,
            which is fine early and a problem once the population stops.
          </p>
        </div>
      </div>

      <div className="card">
        <div className="head">
          <h2>Here right now</h2>
          <Link href="/players" className="muted">All players →</Link>
        </div>
        {a.data.online.length ? (
          <table>
            <thead><tr><th>PLAYER</th><th className="num">LEVEL</th><th className="num">GOLD</th><th>STATE</th><th className="num">SEEN</th></tr></thead>
            <tbody>
              {a.data.online.map((p) => (
                <tr key={p.id}>
                  <td><Link href={`/players/${p.id}`}>{p.name}</Link>
                      <div className="faint" style={{ fontSize: 11 }}>{p.username}</div></td>
                  <td className="num">{p.level}</td>
                  <td className="num">{n(p.gold)}</td>
                  <td><span className={p.state === "banned" ? "pill err" : "pill"}>{p.state}</span></td>
                  <td className="num muted">{p.seen}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <p className="empty">Nobody in the last {a.data.online_window_minutes} minutes.</p>}
      </div>

      <div className="card">
        <h2>Where gold comes from and goes</h2>
        <table>
          <thead><tr><th>REASON</th><th className="num">CREATED</th><th className="num">DESTROYED</th><th className="num">NET</th><th className="num">ENTRIES</th></tr></thead>
          <tbody>
            {d.data.flows.map((f) => (
              <tr key={f.reason}>
                <td>{f.reason}</td>
                <td className="num ok">{Number(f.created) ? n(f.created) : "—"}</td>
                <td className="num err">{Number(f.destroyed) ? n(f.destroyed) : "—"}</td>
                <td className="num">{n(f.net)}</td>
                <td className="num faint">{f.entries}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}

function Stat({ k, v, s }: { k: string; v: string; s?: string }) {
  return <div className="stat"><div className="k">{k}</div><div className="v">{v}</div>{s ? <div className="s">{s}</div> : null}</div>;
}
