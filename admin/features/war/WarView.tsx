"use client";

import { useCallback, useEffect, useState } from "react";
import { query } from "@/store/react";
import { Button, EmptyState, Panel, Skeleton, Stat, Stats } from "@/ui/kit";
import { num } from "@/lib/format";
import s from "./war.module.css";

// Krallik Boss ve Savaslari (Wave 8) at the desk: the beasts standing against
// the realm's kingdoms, and the week's wars.
//
// A READ, and only a read. There is no lever on this page on purpose: a beast's
// health, what a blow costs, what a win is worth and what a week pays are all
// decided in the balance, where Validate holds them and the Balance page
// publishes them.
//
// The figure this page exists for is the KILL RATE. boss.json's
// hp_per_might_bp is calibrated against reference kingdoms so a level-one beast
// falls in 65 to 80 per cent of cycles; this is the same measurement taken in
// the wild. Above the band the beast is a formality, below it the raid is a
// wall, and either way the number to move is in the balance.

type Beast = {
  kingdom_id: string; kingdom_name: string; tag: string; boss_id: string; name: string;
  level: number; hp_max: number; hp_left: number; hp_left_bp: number;
  members: number; fighters: number; kingdom_might: number; ends_in: number; killed: boolean;
};
type War = {
  id: string; a_name: string; b_name: string; a_points: number; b_points: number;
  a_might: number; b_might: number; attacks: number; bye: boolean; settled: boolean;
  winner: string; ends_in: number;
};
type Desk = {
  standing: Beast[]; cycles: number; killed: number; kill_rate_bp: number;
  avg_members: number; damage: number; blows: number; blow_lords: number; chests_paid: number;
  wars: War[]; week: string; next_drawn: string; byes: number;
  attacks: number; attack_wins: number; routs: number; war_lords: number; points: number;
  window_hours: number;
};

const WINDOWS = [24, 72, 168];
/** What the calibration holds the kill rate to, in basis points. */
const BAND = [6500, 8000];

function hours(seconds: number): string {
  if (seconds <= 0) return "over";
  const h = Math.floor(seconds / 3600);
  return h >= 24 ? `${Math.floor(h / 24)}d ${h % 24}h` : `${h}h`;
}

export function WarView() {
  const [v, setV] = useState<Desk | null>(null);
  const [window_, setWindow] = useState(24);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const res = await query<Desk>("kingdomWar", { hours: window_ });
    if (res.ok) { setV(res.data); setError(null); } else setError(res.message);
  }, [window_]);
  useEffect(() => { void load(); }, [load]);

  if (error) return <Panel title="Krallık savaşları"><EmptyState title={error} /></Panel>;
  if (!v) return <Panel title="Krallık savaşları"><Skeleton h={160} /></Panel>;

  const span = v.window_hours === 24 ? "today" : `the last ${v.window_hours} hours`;
  const inBand = v.cycles > 0 && v.kill_rate_bp >= BAND[0] && v.kill_rate_bp <= BAND[1];
  return (
    <div className={s.page}>
      <Panel title="The kingdom's beast" flush>
        <p className={s.lede}>
          One beast per kingdom for forty-eight hours, six blows a member, each costing what a raid
          costs. Its health is the kingdom&apos;s own Might times a calibrated share, so five lords
          and twenty meet the same siege — what changes is how many swords are raised at it.
        </p>
        <div className={s.actions}>
          {WINDOWS.map((h) => (
            <Button key={h} variant={h === window_ ? "primary" : "quiet"} size="sm" onClick={() => setWindow(h)}>
              {h === 24 ? "today" : `${h}h`}
            </Button>
          ))}
        </div>
        <Stats>
          <Stat label="beasts standing" value={num(v.standing.length)} />
          <Stat label={`cycles closed ${span}`} value={num(v.cycles)} />
          <Stat
            label="kill rate"
            value={v.cycles === 0 ? "—" : `${(v.kill_rate_bp / 100).toFixed(0)}%`}
            muted={v.cycles > 0 && !inBand}
            title="boss.json is calibrated so a level-one beast falls in 65–80% of cycles. Outside that band the number to move is hp_per_might_bp, on the Balance page."
          />
          <Stat label={`blows struck ${span}`} value={num(v.blows)} />
          <Stat label="lords who swung" value={num(v.blow_lords)} />
          <Stat label={`chests paid ${span}`} value={num(v.chests_paid)} />
        </Stats>
        {v.standing.length === 0 ? (
          <EmptyState title="No beast stands anywhere.">
            One rises for a kingdom whose window has come round: the boss_cycle job, every ten minutes.
          </EmptyState>
        ) : (
          <table className="u-table">
            <thead><tr><th>kingdom</th><th>beast</th><th className={s.num}>level</th>
              <th>health left</th><th className={s.num}>fighters</th>
              <th className={s.num}>members</th><th className={s.num}>ends in</th></tr></thead>
            <tbody>
              {v.standing.map((b) => (
                <tr key={b.kingdom_id}>
                  <td><b>{b.kingdom_name}</b> <span className="u-faint">[{b.tag}]</span></td>
                  <td>{b.name}</td>
                  <td className={s.num}>{b.level}</td>
                  <td>
                    <span className={s.bar}>
                      <i className={s.barFill} style={{ width: `${Math.max(0, Math.min(100, b.hp_left_bp / 100))}%` }} />
                    </span>{" "}
                    <span className={s.mono}>{num(b.hp_left)} / {num(b.hp_max)}</span>
                  </td>
                  <td className={s.num}>{num(b.fighters)}</td>
                  <td className={s.num}>{num(b.members)}</td>
                  <td className={s.num}>{b.killed ? "down" : hours(b.ends_in)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Panel>

      <Panel title="The kingdom wars" flush>
        <p className={s.lede}>
          Drawn on a Friday evening by the Might of a kingdom&apos;s best fifteen, never against more
          than one and a half times its own, and never the same pair twice running. Nothing of a
          lord&apos;s is at stake in one: no gold is stolen, no energy is spent, and a shield guards
          against raids, not against this.
        </p>
        <Stats>
          <Stat label="week" value={v.week} />
          <Stat label="wars drawn" value={num(v.wars.length - v.byes)} />
          <Stat label="byes" value={num(v.byes)} muted={v.byes > 0}
            title="A kingdom nobody near enough in strength could be found for. Many byes means max_ratio_bp is too tight for the realm's spread." />
          <Stat label={`attacks ${span}`} value={num(v.attacks)} />
          <Stat label="won" value={v.attacks === 0 ? "—" : `${Math.round((v.attack_wins / v.attacks) * 100)}%`} />
          <Stat label="on routed lords" value={num(v.routs)}
            title="Beating a lord who has lost every banner pays a quarter, so a high count is a kingdom farming the one lord who cannot answer." />
          <Stat label="lords who rode out" value={num(v.war_lords)} />
        </Stats>
        {v.wars.length === 0 ? (
          <EmptyState title="No war this week.">
            {`The next pairs are drawn ${new Date(v.next_drawn).toLocaleString()}.`}
          </EmptyState>
        ) : (
          <table className="u-table">
            <thead><tr><th>war</th><th className={s.num}>points</th>
              <th className={s.num}>Might</th><th className={s.num}>attacks</th>
              <th className={s.num}>ends in</th></tr></thead>
            <tbody>
              {v.wars.map((w) => (
                <tr key={w.id}>
                  <td>
                    <b>{w.a_name}</b>{w.bye ? <span className="u-faint"> · a bye</span> : <> v <b>{w.b_name}</b></>}
                    {w.settled ? <span className="u-faint"> · settled</span> : null}
                  </td>
                  <td className={s.num}>{w.bye ? "—" : `${num(w.a_points)} – ${num(w.b_points)}`}</td>
                  <td className={s.num}>{w.bye ? num(w.a_might) : `${num(w.a_might)} / ${num(w.b_might)}`}</td>
                  <td className={s.num}>{num(w.attacks)}</td>
                  <td className={s.num}>{hours(w.ends_in)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Panel>
    </div>
  );
}
