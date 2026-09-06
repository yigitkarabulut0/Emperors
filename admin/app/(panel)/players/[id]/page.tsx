import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import Link from "next/link";
import { callAdmin } from "@/lib/api";

type Odd = { tier: string; bp: number };
type Audit = { id: number; admin: string; action: string; note: string; at: string };

type Detail = {
  id: string; username: string; name: string; level: number;
  gold: string; diamonds: number; state: string; is_bot: boolean; last_seen: string;
  xp: number; xp_to_next: number; stat_points_unspent: number;
  stat_energy: number; stat_attack: number; stat_defense: number;
  energy: number; treasury: string; soldier_slots: number;
  action_seq: number; created: string;
  luck_bp: number; luck_expires_at: string | null;
  odds_now: Odd[]; odds_at_luck: Odd[]; preview_bp: number;
  audit: Audit[] | null;
};

const n = (v: string | number) => Number(v).toLocaleString("en-US");
const pct = (bp: number) => (bp / 100).toFixed(2) + "%";

export default async function PlayerPage({
  params, searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ preview?: string; msg?: string; err?: string }>;
}) {
  const { id } = await params;
  const { preview = "0", msg, err } = await searchParams;

  const res = await callAdmin<Detail>(
    `/players/detail?id=${encodeURIComponent(id)}&preview=${encodeURIComponent(preview)}`,
  );
  if (!res.ok) {
    return (
      <>
        <h1>Player</h1>
        <p className="err">{res.message}</p>
        <p><Link href="/players">Back to the list</Link></p>
      </>
    );
  }
  const p = res.data;

  // One shape for every write: post, revalidate, come back with the outcome.
  // A refusal must land on this page with its reason -- throwing gives Next's
  // 500 screen, which tells an operator nothing and loses what they typed.
  const run = (path: string, build: (f: FormData) => Record<string, unknown>) =>
    async function (formData: FormData) {
      "use server";
      const r = await callAdmin(path, { method: "POST", body: { player_id: id, ...build(formData) } });
      revalidatePath(`/players/${id}`);
      const q = new URLSearchParams();
      if (preview !== "0") q.set("preview", preview);
      q.set(r.ok ? "msg" : "err", r.ok ? "Done." : r.message);
      redirect(`/players/${id}?${q}`);
    };

  const adjust = run("/players/adjust", (f) => ({
    gold: Number(f.get("gold") || 0),
    diamonds: Number(f.get("diamonds") || 0),
    xp: Number(f.get("xp") || 0),
    stat_points: Number(f.get("stat_points") || 0),
    note: String(f.get("note") || "via panel"),
  }));
  const setLevel = run("/players/level", (f) => ({
    level: Number(f.get("level") || 0), note: String(f.get("note") || "via panel"),
  }));
  const setEnergy = run("/players/energy", (f) => ({
    energy: Number(f.get("energy") || 0), note: String(f.get("note") || "via panel"),
  }));
  const setLuck = run("/players/luck", (f) => ({
    luck_bp: Number(f.get("luck_bp") || 0),
    days: Number(f.get("days") || 0),
    note: String(f.get("note") || "via panel"),
  }));
  const setState = run("/players/state", (f) => ({
    state: String(f.get("state")), note: String(f.get("note") || "via panel"),
  }));

  async function previewLuck(formData: FormData) {
    "use server";
    redirect(`/players/${id}?preview=${Number(formData.get("luck_bp") || 0)}`);
  }

  return (
    <>
      <p className="muted"><Link href="/players">← Players</Link></p>
      <h1>{p.name} <span className="muted" style={{ fontSize: 18 }}>@{p.username}</span></h1>
      <p className="muted">
        Joined {p.created} · last seen {p.last_seen} · action_seq {p.action_seq}
        {p.is_bot ? " · bot" : ""} · <span className={p.state === "banned" ? "pill err" : "pill"}>{p.state}</span>
      </p>

      {msg ? <p className="ok">{msg}</p> : null}
      {err ? <p className="err">{err}</p> : null}

      <div className="card">
        <h2>Where they stand</h2>
        <div className="stats">
          <Stat label="Level" value={n(p.level)} sub={`${n(p.xp)} / ${n(p.xp_to_next)} xp`} />
          <Stat label="Gold" value={n(p.gold)} sub={`${n(p.treasury)} banked`} />
          <Stat label="Diamonds" value={n(p.diamonds)} />
          <Stat label="Energy" value={n(p.energy)} />
          <Stat label="Unspent points" value={n(p.stat_points_unspent)}
                sub={`E${p.stat_energy} A${p.stat_attack} D${p.stat_defense}`} />
          <Stat label="Soldier slots" value={n(p.soldier_slots)} />
        </div>
      </div>

      <div className="card">
        <h2>Grant or take</h2>
        <p className="muted">
          Deltas, not totals. Estate income is continuous, so a total typed here
          would be stale by the time it was submitted; <code>+1000</code> is not.
          Gold writes a ledger row so the economy dashboard stays honest.
        </p>
        <form action={adjust} className="row" style={{ flexWrap: "wrap", gap: 8 }}>
          <input name="gold" placeholder="± gold" style={{ width: 110 }} />
          <input name="diamonds" placeholder="± diamonds" style={{ width: 120 }} />
          <input name="xp" placeholder="± xp" style={{ width: 100 }} />
          <input name="stat_points" placeholder="± points" style={{ width: 110 }} />
          <input name="note" placeholder="reason" style={{ minWidth: 200, flex: 1 }} />
          <button type="submit">Apply</button>
        </form>
        <p className="muted" style={{ marginTop: 8 }}>
          Experience lands in the current level&rsquo;s bar and never levels anyone
          up: crossing a boundary grants points, diamonds and a refill, and a
          &ldquo;+500 xp&rdquo; that quietly did all that would be a surprise.
        </p>
      </div>

      <div className="card">
        <h2>Set outright</h2>
        <div className="row" style={{ gap: 24, flexWrap: "wrap", alignItems: "flex-start" }}>
          <form action={setLevel} className="row" style={{ gap: 6 }}>
            <input name="level" placeholder="level" defaultValue={p.level} style={{ width: 90 }} />
            <input name="note" placeholder="reason" style={{ width: 160 }} />
            <button className="ghost" type="submit">Set level</button>
          </form>
          <form action={setEnergy} className="row" style={{ gap: 6 }}>
            <input name="energy" placeholder="energy" defaultValue={p.energy} style={{ width: 90 }} />
            <input name="note" placeholder="reason" style={{ width: 160 }} />
            <button className="ghost" type="submit">Set energy</button>
          </form>
          <form action={setState} className="row" style={{ gap: 6 }}>
            <input type="hidden" name="state" value={p.state === "banned" ? "active" : "banned"} />
            <input name="note" placeholder="reason" style={{ width: 160 }} />
            <button className={p.state === "banned" ? "ghost" : "danger"} type="submit">
              {p.state === "banned" ? "Unban" : "Ban"}
            </button>
          </form>
        </div>
        <p className="muted" style={{ marginTop: 8 }}>
          Setting a level resets the experience bar to the bottom of it — an xp
          figure measured against a different level&rsquo;s requirement means nothing.
          Energy moves its settle anchor with it, or the next read would undo it.
        </p>
      </div>

      <div className="card">
        <h2>Fortune</h2>
        <p className="muted">
          A bonus on the tier ladder, in basis points. 0 is neutral; +10000 doubles
          the level coefficient, which is the ceiling. It shifts what the shop and
          recruiting roll — never who wins a fight.
        </p>

        <p>
          Now: <strong>{p.luck_bp > 0 ? "+" : ""}{n(p.luck_bp)}</strong>
          {p.luck_expires_at ? <span className="muted"> · until {p.luck_expires_at}</span>
                             : p.luck_bp !== 0 ? <span className="err"> · permanent</span> : null}
        </p>

        <form action={previewLuck} className="row" style={{ gap: 6, marginTop: 8 }}>
          <input name="luck_bp" placeholder="preview a value" defaultValue={p.preview_bp || ""} style={{ width: 150 }} />
          <button className="ghost" type="submit">Preview odds</button>
        </form>

        <table style={{ marginTop: 12 }}>
          <thead>
            <tr>
              <th>TIER</th>
              <th style={{ textAlign: "right" }}>NOW</th>
              <th style={{ textAlign: "right" }}>AT {p.preview_bp > 0 ? "+" : ""}{n(p.preview_bp)}</th>
              <th style={{ textAlign: "right" }}>CHANGE</th>
            </tr>
          </thead>
          <tbody>
            {p.odds_now.map((o, i) => {
              const at = p.odds_at_luck[i]?.bp ?? o.bp;
              const d = at - o.bp;
              return (
                <tr key={o.tier}>
                  <td>{o.tier}</td>
                  <td style={{ textAlign: "right" }}>{pct(o.bp)}</td>
                  <td style={{ textAlign: "right" }}>{pct(at)}</td>
                  <td className={d > 0 ? "ok" : d < 0 ? "err" : "muted"} style={{ textAlign: "right" }}>
                    {d === 0 ? "—" : (d > 0 ? "+" : "") + pct(d)}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>

        <form action={setLuck} className="row" style={{ gap: 6, marginTop: 12, flexWrap: "wrap" }}>
          <input name="luck_bp" placeholder="luck (bp)" defaultValue={p.preview_bp || p.luck_bp} style={{ width: 120 }} />
          <input name="days" placeholder="days (0 = forever)" defaultValue={7} style={{ width: 160 }} />
          <input name="note" placeholder="reason" style={{ minWidth: 200, flex: 1 }} />
          <button type="submit">Set fortune</button>
        </form>
        <p className="muted" style={{ marginTop: 8 }}>
          Time-boxed by default. A fortune override moves no counter anyone watches
          and writes no ledger row, so a permanent one compounds quietly for as long
          as nobody looks. An expired one simply stops applying — there is no sweeper
          to forget to run.
        </p>
      </div>

      <div className="card">
        <h2>What has been done to this player</h2>
        {p.audit && p.audit.length ? (
          <table>
            <thead><tr><th>WHEN</th><th>ADMIN</th><th>ACTION</th><th>NOTE</th></tr></thead>
            <tbody>
              {p.audit.map((a) => (
                <tr key={a.id}>
                  <td className="muted">{a.at}</td>
                  <td>{a.admin}</td>
                  <td><span className="pill">{a.action}</span></td>
                  <td>{a.note}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <p className="muted">Nothing yet.</p>}
      </div>
    </>
  );
}

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div className="stat">
      <div className="k">{label}</div>
      <div className="v">{value}</div>
      {sub ? <div className="muted">{sub}</div> : null}
    </div>
  );
}
