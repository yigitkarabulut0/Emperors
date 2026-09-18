"use client";

import { useCallback, useEffect, useState } from "react";
import { query, useMutate, useSlice } from "@/store/react";
import { Button, EmptyState, Panel, Pill, Skeleton, Stat, Stats } from "@/ui/kit";
import { atLeast } from "@/lib/ops";
import { ago, gold, num } from "@/lib/format";
import s from "./pvp.module.css";

// Rekabet (service/pvp_desk.go): the Honour Arena's ladder, the Bounty Board's
// escrow and the Throne.
//
// The two numbers to watch are on the board: GOLD HELD is what is escrowed on
// heads right now, and GOLD BURNED is what the crier took out of the economy
// this week. The board is a SINK, and those two say whether it is working.
//
// On the arena, the number to watch is how many of the day's fights were
// against a hired champion: a band that cannot fill itself is a population
// problem, not a balance one.

type ArenaRow = {
  place: number; name: string; level: number; rating: number; peak: number;
  wins: number; losses: number; league: string;
};
type ArenaBand = { id: string; name: string; at_rating: number; lords: number };
type Arena = {
  season: number; ladder: ArenaRow[]; leagues: ArenaBand[]; lords: number;
  fights_today: number; champion_fights_today: number; season_resets_in: number;
};

type BountyRow = {
  id: string; target: string; placer: string; amount: number; remaining: number;
  fee_burned: number; expires_in: number;
};
type BountyPair = { placer: string; claimer: string; claims: number; paid: number };
type Bounties = {
  escrowed: number; burned_this_week: number; open: number; claimed_this_week: number;
  rows: BountyRow[]; pairs: BountyPair[];
};

type Reign = {
  week: number; kingdom_name: string; kingdom_tag: string; emperor_name: string;
  renown: number; members: number; ends_in: number;
};
type Racer = { place: number; kingdom_name: string; kingdom_tag: string; renown: number; members: number };
type Throne = {
  reign: Reign | null; race: Racer[]; past: Reign[];
  measure: string; scope: string; settles_in: number;
};

export function PvPView() {
  const me = useSlice("me");
  const canDesign = me ? atLeast(me.role, "designer") : false;
  return (
    <div className={s.page}>
      <ArenaPanel />
      <BountyPanel canDesign={canDesign} />
      <ThronePanel canDesign={canDesign} />
    </div>
  );
}

/* ----------------------------------------------------------- the arena --- */

function ArenaPanel() {
  const [v, setV] = useState<Arena | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const res = await query<Arena>("pvpArena", { limit: 50 });
    if (res.ok) { setV(res.data); setError(null); } else setError(res.message);
  }, []);
  useEffect(() => { void load(); }, [load]);

  if (error) return <Panel title="The Honour Arena"><EmptyState title={error} /></Panel>;
  if (!v) return <Panel title="The Honour Arena"><Skeleton h={120} /></Panel>;

  const bots = v.fights_today > 0 ? Math.round((v.champion_fights_today * 100) / v.fights_today) : 0;
  return (
    <Panel title={`The Honour Arena · season ${v.season}`} flush>
      <p className={s.lede}>
        The ladder as it stands. A fight here moves a rating and nothing else — no gold, no energy,
        no shield — so what to watch is whether the bands can fill themselves.
      </p>
      <Stats>
        <Stat label="lords ranked" value={num(v.lords)} />
        <Stat label="fights today" value={num(v.fights_today)} />
        <Stat label="against a hired champion" value={`${bots}%`}
          muted={bots < 40}
          title="A band that cannot find a lord offers the champion instead. High here is a population problem, not a balance one." />
        <Stat label="half reset in" value={ago(v.season_resets_in)} />
      </Stats>
      <div className={s.bands}>
        {v.leagues.map((b) => (
          <span key={b.id} className={s.band}>{b.name} <b>{num(b.lords)}</b> · from {num(b.at_rating)}</span>
        ))}
      </div>
      {v.ladder.length === 0 ? (
        <EmptyState title="Nobody has fought this season." />
      ) : (
        <table className="u-table">
          <thead><tr><th>#</th><th>lord</th><th>league</th><th className={s.num}>rating</th>
            <th className={s.num}>peak</th><th className={s.num}>w / l</th></tr></thead>
          <tbody>
            {v.ladder.map((r) => (
              <tr key={r.place}>
                <td className={s.mono}>{r.place}</td>
                <td><b>{r.name}</b> <span className="u-faint">Lv {r.level}</span></td>
                <td><Pill tone="neutral" dot>{r.league}</Pill></td>
                <td className={s.num}>{num(r.rating)}</td>
                <td className={s.num}>{num(r.peak)}</td>
                <td className={s.num}>{r.wins} / {r.losses}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Panel>
  );
}

/* ------------------------------------------------------- the bounty board --- */

function BountyPanel({ canDesign }: { canDesign: boolean }) {
  const pending = useSlice("pending");
  const mutate = useMutate();
  const [v, setV] = useState<Bounties | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const res = await query<Bounties>("pvpBounties", { limit: 50 });
    if (res.ok) { setV(res.data); setError(null); } else setError(res.message);
  }, []);
  useEffect(() => { void load(); }, [load]);

  async function revoke(r: BountyRow) {
    const res = await mutate("bountyRevoke", { id: r.id, note: "" }, {
      key: "bounty:" + r.id,
      success: `withdrawn · ${gold(r.remaining)} back to ${r.placer}`,
    });
    if (res.ok) await load();
  }

  if (error) return <Panel title="The Bounty Board"><EmptyState title={error} /></Panel>;
  if (!v) return <Panel title="The Bounty Board"><Skeleton h={120} /></Panel>;

  return (
    <Panel title="The Bounty Board" flush>
      <p className={s.lede}>
        A price on a head is a gold SINK: the crier&rsquo;s fee is burned and never comes back.
        Gold held is what is escrowed on heads now; gold burned is what left the economy this week.
      </p>
      <Stats>
        <Stat label="gold held on heads" value={gold(v.escrowed)} />
        <Stat label="gold burned this week" value={gold(v.burned_this_week)} />
        <Stat label="prices standing" value={num(v.open)} />
        <Stat label="collected this week" value={num(v.claimed_this_week)} />
      </Stats>
      {v.pairs.length > 0 && (
        <p className={s.warn}>
          Pairs who keep meeting this week:{" "}
          {v.pairs.map((p) => `${p.placer} → ${p.claimer} (${p.claims}, ${gold(p.paid)})`).join(" · ")}
        </p>
      )}
      {v.rows.length === 0 ? (
        <EmptyState title="No price has been set on anybody." />
      ) : (
        <table className="u-table">
          <thead><tr><th>head</th><th>set by</th><th className={s.num}>held</th>
            <th className={s.num}>burned</th><th>stands</th><th /></tr></thead>
          <tbody>
            {v.rows.map((r) => (
              <tr key={r.id}>
                <td><b>{r.target}</b></td>
                <td>{r.placer}</td>
                <td className={s.num}>{gold(r.remaining)} <span className="u-faint">of {gold(r.amount)}</span></td>
                <td className={s.num}>{gold(r.fee_burned)}</td>
                <td>{r.expires_in > 0 ? ago(r.expires_in) : <span className="u-faint">closed</span>}</td>
                <td className={s.actions}>
                  {canDesign && r.expires_in > 0 && (
                    <Button variant="danger" size="sm" busy={pending.has("bounty:" + r.id)}
                      onClick={() => void revoke(r)}>withdraw</Button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Panel>
  );
}

/* ----------------------------------------------------------- the throne --- */

function ThronePanel({ canDesign }: { canDesign: boolean }) {
  const pending = useSlice("pending");
  const mutate = useMutate();
  const [v, setV] = useState<Throne | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const res = await query<Throne>("pvpThrone");
    if (res.ok) { setV(res.data); setError(null); } else setError(res.message);
  }, []);
  useEffect(() => { void load(); }, [load]);

  async function settle() {
    const res = await mutate("throneSettle", { note: "" }, {
      key: "throne", success: "the closed week was settled",
    });
    if (res.ok) await load();
  }

  if (error) return <Panel title="The Throne"><EmptyState title={error} /></Panel>;
  if (!v) return <Panel title="The Throne"><Skeleton h={120} /></Panel>;

  return (
    <Panel
      title="The Throne"
      actions={canDesign && (
        <Button size="sm" busy={pending.has("throne")} onClick={() => void settle()}>
          settle the closed week
        </Button>
      )}
      flush
    >
      <p className={s.lede}>
        Crowned every Monday, on renown <b>{v.measure === "week_gain" ? "gained in the week" : "as it stands"}</b>.
        The emperor&rsquo;s one decree reaches <b>{v.scope === "realm" ? "the whole realm" : v.scope}</b>.
        Settling again crowns nobody twice: the week is claimed in the database.
      </p>
      <Stats>
        <Stat label="reigning" value={v.reign ? v.reign.kingdom_name : <span className="u-faint">nobody</span>}
          sub={v.reign ? `${v.reign.emperor_name} · ${num(v.reign.members)} lords` : undefined} />
        <Stat label="reign ends in" value={v.reign ? ago(v.reign.ends_in) : "—"} />
        <Stat label="next crowning" value={ago(v.settles_in)} />
      </Stats>
      <table className="u-table">
        <thead><tr><th>#</th><th>kingdom</th><th className={s.num}>renown this week</th><th className={s.num}>lords</th></tr></thead>
        <tbody>
          {v.race.length === 0 && <tr><td colSpan={4}><span className="u-faint">No kingdom is in the running.</span></td></tr>}
          {v.race.map((r) => (
            <tr key={r.kingdom_name}>
              <td className={s.mono}>{r.place}</td>
              <td><b>{r.kingdom_name}</b> <span className="u-faint">[{r.kingdom_tag}]</span></td>
              <td className={s.num}>{num(r.renown)}</td>
              <td className={s.num}>{num(r.members)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {v.past.length > 0 && (
        <table className="u-table">
          <thead><tr><th>week</th><th>kingdom</th><th>emperor</th><th className={s.num}>renown</th></tr></thead>
          <tbody>
            {v.past.map((r) => (
              <tr key={r.week}>
                <td className={s.mono}>{new Date(r.week * 86400_000).toISOString().slice(0, 10)}</td>
                <td>{r.kingdom_name}</td>
                <td>{r.emperor_name}</td>
                <td className={s.num}>{num(r.renown)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Panel>
  );
}
