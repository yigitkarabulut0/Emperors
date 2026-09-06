"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { query, useMutate, useSlice } from "@/store/react";
import { Button, EmptyState, Field, Panel, Pill, Skeleton, Stat, Stats } from "@/ui/kit";
import { atLeast } from "@/lib/ops";
import { bp, gold, num, shortDate } from "@/lib/format";
import s from "./detail.module.css";

type TierOdd = { tier: string; name?: string; pct?: number; chance_bp?: number };

type Detail = {
  id: string; username: string; name: string; level: number;
  gold: string; diamonds: number; state: string; is_bot: boolean;
  last_seen: string; created: string;
  xp: number; xp_to_next: number;
  stat_points_unspent: number; stat_energy: number; stat_attack: number; stat_defense: number;
  energy: number; treasury: string; soldier_slots: number; action_seq: number;
  luck_bp: number; luck_expires_at: string | null;
  odds_now: TierOdd[]; odds_at_luck: TierOdd[]; preview_bp: number;
  audit: { admin: string; action: string; note: string; at: string }[];
};

const TIER_COLOUR: Record<string, string> = {
  common: "var(--tier-common)", uncommon: "var(--tier-uncommon)", rare: "var(--tier-rare)",
  epic: "var(--tier-epic)", legendary: "var(--tier-legendary)", mystic: "var(--tier-mystic)",
};

function pct(o: TierOdd): number {
  if (typeof o.pct === "number") return o.pct;
  if (typeof o.chance_bp === "number") return o.chance_bp / 100;
  return 0;
}

export function PlayerView({ id }: { id: string }) {
  const me = useSlice("me");
  const board = useSlice("board");
  const pending = useSlice("pending");
  const mutate = useMutate();

  const [d, setD] = useState<Detail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [preview, setPreview] = useState(0);

  const load = useCallback(async (previewBP = preview) => {
    const res = await query<Detail>("playerDetail", { id, preview: previewBP || undefined });
    if (res.ok) { setD(res.data); setError(null); } else setError(res.message);
  }, [id, preview]);

  useEffect(() => { void load(); }, [load]);

  const canModerate = me ? atLeast(me.role, "moderator") : false;
  const canDesign = me ? atLeast(me.role, "designer") : false;

  if (error) {
    return <EmptyState title="Could not load this player"><span className="u-faint">{error}</span></EmptyState>;
  }
  if (!d) {
    return (
      <div className={s.page}>
        <Skeleton h={44} />
        <Skeleton h={120} />
        <Skeleton h={220} />
      </div>
    );
  }

  const here = board?.playing.find((r) => r.id === id) ?? board?.idle.find((r) => r.id === id);

  /** Every write refetches, because the server is the authority on what a write
   *  actually did — a level change resets XP, a luck change moves the odds. */
  async function run(op: Parameters<typeof mutate>[0], body: Record<string, unknown>, success: string, key: string) {
    const res = await mutate(op, body, { key, success });
    if (res.ok) await load();
  }

  return (
    <div className={s.page}>
      <header className={s.head}>
        <div className={s.title}>
          <div className={s.name}>{d.name || d.username}</div>
          <div className={s.sub}>
            <span>@{d.username}</span>
            <span>joined {shortDate(d.created)}</span>
            <span>last seen {shortDate(d.last_seen)}</span>
            <span>action #{d.action_seq}</span>
          </div>
          <div className={s.id}>{d.id}</div>
        </div>
        <div className={s.spacer} />
        <div className="u-row">
          {here
            ? <Pill tone={here.presence === "playing" ? "ok" : "warn"} dot hollow={here.inferred}>
                {here.presence === "playing" ? "in the game" : "gone quiet"}
              </Pill>
            : <Pill dot hollow>not in the game</Pill>}
          {d.is_bot && <Pill tone="synthetic">bot</Pill>}
          {d.state === "active"
            ? <Pill tone="ok" dot>active</Pill>
            : <Pill tone="bad" dot hollow>{d.state}</Pill>}
          <Link href="/players"><Button size="sm">back to the list</Button></Link>
        </div>
      </header>

      <Stats>
        <Stat label="Level" value={d.level} sub={`${num(d.xp)} / ${num(d.xp_to_next)} xp`} />
        <Stat label="Gold" value={gold(d.gold)} title={d.gold} />
        <Stat label="Treasury" value={gold(d.treasury)} sub="cannot be stolen" muted />
        <Stat label="Diamonds" value={num(d.diamonds)} muted />
        <Stat label="Energy" value={num(d.energy)} muted />
        <Stat label="Unspent points" value={num(d.stat_points_unspent)} sub={`e${d.stat_energy} a${d.stat_attack} d${d.stat_defense}`} muted />
      </Stats>

      <div className={s.two}>
        {canModerate && (
          <Panel title="Grant or take">
            <p className={s.explain}>
              These are <strong>deltas</strong>, not totals. −500 takes five hundred gold away;
              it does not set the balance to −500. XP lands in the current level&rsquo;s bar and
              deliberately never levels anyone up, because crossing a boundary also grants
              points, diamonds and an energy refill — and a silent &ldquo;+500 xp&rdquo; that did
              all that would be a very surprising thing to have clicked.
            </p>
            <form
              className={s.form}
              onSubmit={(e) => {
                e.preventDefault();
                const f = new FormData(e.currentTarget);
                void run("playerAdjust", {
                  player_id: d.id,
                  gold: Number(f.get("gold") || 0),
                  diamonds: Number(f.get("diamonds") || 0),
                  xp: Number(f.get("xp") || 0),
                  stat_points: Number(f.get("stat_points") || 0),
                  note: String(f.get("note") || ""),
                }, "adjusted", "adjust");
              }}
            >
              <div className={s.inline}>
                <Field label="gold"><input name="gold" type="number" defaultValue={0} /></Field>
                <Field label="diamonds"><input name="diamonds" type="number" defaultValue={0} /></Field>
                <Field label="xp"><input name="xp" type="number" defaultValue={0} /></Field>
                <Field label="points"><input name="stat_points" type="number" defaultValue={0} /></Field>
              </div>
              <div className={s.inline}>
                <div className={s.note}>
                  <Field label="why" hint="Goes in the audit trail. Future you will want it.">
                    <input name="note" placeholder="compensation for the outage" style={{ width: "100%" }} />
                  </Field>
                </div>
                <Button type="submit" variant="primary" busy={pending.has("adjust")}>Apply</Button>
              </div>
            </form>
          </Panel>
        )}

        <Panel title="Set outright">
          <p className={s.explain}>
            These are absolutes. Setting a level resets the XP bar to the bottom of that level,
            because an XP figure from a different level means nothing.
          </p>
          <div className={s.form}>
            {canDesign && (
              <form
                className={s.inline}
                onSubmit={(e) => {
                  e.preventDefault();
                  const f = new FormData(e.currentTarget);
                  void run("playerLevel", {
                    player_id: d.id, level: Number(f.get("level")), note: "set from the panel",
                  }, "level set", "level");
                }}
              >
                <Field label="level"><input name="level" type="number" defaultValue={d.level} min={1} /></Field>
                <Button type="submit" busy={pending.has("level")}>Set level</Button>
              </form>
            )}
            {canModerate && (
              <form
                className={s.inline}
                onSubmit={(e) => {
                  e.preventDefault();
                  const f = new FormData(e.currentTarget);
                  void run("playerEnergy", {
                    player_id: d.id, energy: Number(f.get("energy")), note: "set from the panel",
                  }, "energy set", "energy");
                }}
              >
                <Field label="energy"><input name="energy" type="number" defaultValue={d.energy} min={0} /></Field>
                <Button type="submit" busy={pending.has("energy")}>Set energy</Button>
              </form>
            )}
            {canModerate && (
              <div className={s.inline}>
                {d.state === "active" ? (
                  <Button
                    variant="danger"
                    busy={pending.has("state")}
                    onClick={() => {
                      if (confirm(`Ban ${d.username}?`)) {
                        void run("playerState", { player_id: d.id, state: "banned", note: "banned from the panel" }, "banned", "state");
                      }
                    }}
                  >
                    Ban this player
                  </Button>
                ) : (
                  <Button
                    busy={pending.has("state")}
                    onClick={() => run("playerState", { player_id: d.id, state: "active", note: "unbanned from the panel" }, "unbanned", "state")}
                  >
                    Lift the ban
                  </Button>
                )}
              </div>
            )}
          </div>
        </Panel>
      </div>

      <Panel
        title="Fortune"
        actions={
          d.luck_bp
            ? <Pill tone="gold">{bp(d.luck_bp)}{d.luck_expires_at ? ` until ${shortDate(d.luck_expires_at)}` : " · no expiry"}</Pill>
            : <Pill>none</Pill>
        }
      >
        <p className={s.explain}>
          Fortune pulls item quality toward the top of each tier&rsquo;s band. The table below is
          computed by the same function the roller uses, so the panel cannot promise odds the
          game will not deliver.
        </p>
        <div className={s.inline} style={{ marginBottom: "var(--s6)" }}>
          <Field label="preview at" hint="basis points; 10000 doubles the level coefficient">
            <input
              type="number" value={preview} step={500}
              onChange={(e) => setPreview(Number(e.target.value))}
            />
          </Field>
          <Button onClick={() => load(preview)}>Preview</Button>
          {canDesign && (
            <form
              className={s.inline}
              onSubmit={(e) => {
                e.preventDefault();
                const f = new FormData(e.currentTarget);
                void run("playerLuck", {
                  player_id: d.id,
                  luck_bp: Number(f.get("luck_bp")),
                  days: Number(f.get("days") || 0),
                  note: "fortune set from the panel",
                }, "fortune set", "luck");
              }}
            >
              <Field label="set to"><input name="luck_bp" type="number" defaultValue={d.luck_bp} /></Field>
              <Field label="for days" hint="0 means no expiry"><input name="days" type="number" defaultValue={0} min={0} /></Field>
              <Button type="submit" variant="primary" busy={pending.has("luck")}>Apply fortune</Button>
            </form>
          )}
        </div>

        {d.odds_now?.length > 0 && (
          <table className={s.odds}>
            <thead>
              <tr>
                <th>tier</th>
                <th>now</th>
                <th>at {bp(d.preview_bp)}</th>
                <th>change</th>
              </tr>
            </thead>
            <tbody>
              {d.odds_now.map((o, i) => {
                const at = d.odds_at_luck?.[i];
                const a = pct(o);
                const b = at ? pct(at) : a;
                const delta = b - a;
                return (
                  <tr key={o.tier}>
                    <td>
                      <span className={s.tier}>
                        <i className={s.swatch} style={{ background: TIER_COLOUR[o.tier] ?? "var(--text-3)" }} />
                        {o.name ?? o.tier}
                      </span>
                    </td>
                    <td>{a.toFixed(2)}%</td>
                    <td>{b.toFixed(2)}%</td>
                    <td className={delta > 0 ? s.up : delta < 0 ? s.down : ""}>
                      {delta === 0 ? "—" : `${delta > 0 ? "+" : ""}${delta.toFixed(2)}`}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </Panel>

      <Panel title="What has been done to this player" flush>
        {d.audit?.length ? (
          <table className={s.odds}>
            <thead>
              <tr><th>when</th><th>admin</th><th>action</th><th>note</th></tr>
            </thead>
            <tbody>
              {d.audit.map((a, i) => (
                <tr key={i}>
                  <td style={{ textAlign: "left" }}>{shortDate(a.at)}</td>
                  <td style={{ textAlign: "left" }}>{a.admin}</td>
                  <td style={{ textAlign: "left" }}><Pill>{a.action}</Pill></td>
                  <td style={{ textAlign: "left", fontFamily: "var(--f-ui)" }} className="u-faint">{a.note || "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : (
          <EmptyState title="Nothing has been done to this player yet" />
        )}
      </Panel>
    </div>
  );
}
