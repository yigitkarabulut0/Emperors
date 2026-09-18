"use client";

import { Fragment, useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { query, useMutate, useSlice } from "@/store/react";
import { Button, EmptyState, Field, Panel, Pill, Skeleton } from "@/ui/kit";
import { Table, TableWrap, num as numCell } from "@/ui/Table";
import { atLeast } from "@/lib/ops";
import { num, shortDate } from "@/lib/format";
import s from "./promo.module.css";

type Reward = {
  diamonds?: number; gold_wages?: number; xp_wages?: number;
  tokens?: Record<string, number>; items?: { tier: string; slot?: string; count: number }[];
};
type Code = {
  code: string; note: string; reward: Reward; max_uses: number; uses: number;
  starts_at: string; expires_at: string | null; state: string; created_by: string; created_at: string;
};
type Redemption = { player_id: string; username: string; redeemed_at: string };
type Tier = { id: string; name: string; rank: number };
type BalanceDoc = {
  rewards?: { promo?: { max_diamonds?: number; expiry_days?: number } };
  tiers?: { tiers?: Tier[] };
};

const STATE_TONE: Record<string, "ok" | "warn" | "bad" | "neutral"> = {
  live: "ok", scheduled: "warn", used_up: "neutral", expired: "neutral", disabled: "bad",
};
const STATE_WORD: Record<string, string> = {
  live: "live", scheduled: "not yet", used_up: "used up", expired: "expired", disabled: "disabled",
};

/** What a code gives, in the words a letter would use. */
function describe(r: Reward, tiers: Tier[]): string {
  const out: string[] = [];
  if (r.diamonds) out.push(`${num(r.diamonds)} diamonds`);
  if (r.gold_wages) out.push(`${num(r.gold_wages)} energy of wages`);
  if (r.xp_wages) out.push(`${num(r.xp_wages)} energy of experience`);
  if (r.tokens?.energy_potion) out.push(`${r.tokens.energy_potion} energy potion${r.tokens.energy_potion === 1 ? "" : "s"}`);
  if (r.tokens?.shield_8h) out.push(`${r.tokens.shield_8h} protection charter${r.tokens.shield_8h === 1 ? "" : "s"}`);
  for (const it of r.items ?? []) {
    const t = tiers.find((x) => x.id === it.tier)?.name ?? it.tier;
    out.push(`${it.count} × ${t} ${it.slot || "gear"}`);
  }
  return out.join(" · ") || "nothing";
}

const whole = (v: string) => Math.max(0, Math.trunc(Number(v) || 0));

function Create({ tiers, maxDiamonds, onMade }: { tiers: Tier[]; maxDiamonds: number; onMade: () => void }) {
  const pending = useSlice("pending");
  const mutate = useMutate();
  const [code, setCode] = useState("");
  const [note, setNote] = useState("");
  const [diamonds, setDiamonds] = useState(0);
  const [goldWages, setGoldWages] = useState(0);
  const [xpWages, setXpWages] = useState(0);
  const [potions, setPotions] = useState(0);
  const [charters, setCharters] = useState(0);
  const [tier, setTier] = useState("");
  const [items, setItems] = useState(0);
  const [maxUses, setMaxUses] = useState(0);
  const [days, setDays] = useState(14);

  const clean = code.toUpperCase().replace(/[^A-Z0-9]/g, "");
  const reward: Reward = {};
  if (diamonds) reward.diamonds = diamonds;
  if (goldWages) reward.gold_wages = goldWages;
  if (xpWages) reward.xp_wages = xpWages;
  if (potions || charters) reward.tokens = { ...(potions ? { energy_potion: potions } : {}), ...(charters ? { shield_8h: charters } : {}) };
  if (tier && items) reward.items = [{ tier, count: items }];
  const empty = Object.keys(reward).length === 0;
  const tooMany = diamonds > maxDiamonds;
  const bad = clean.length < 4 || clean.length > 20;

  async function make() {
    const res = await mutate("promoCreate",
      { code: clean, note, reward, max_uses: maxUses, expires_days: days },
      { key: "promo:create", success: `code ${clean} made` });
    if (res.ok) {
      setCode(""); setNote(""); setDiamonds(0); setGoldWages(0); setXpWages(0);
      setPotions(0); setCharters(0); setItems(0); setTier("");
      onMade();
    }
  }

  return (
    <Panel title="Make a code">
      <p className={s.explain}>
        A code gives only what play gives too — App Review forbids a code that unlocks what is sold —
        so no cosmetics, and at most {num(maxDiamonds)} diamonds. Each lord redeems it once, and each phone
        once; what it gives arrives as a Royal Mail letter.
      </p>
      <form className={s.form} onSubmit={(e) => { e.preventDefault(); void make(); }}>
        <div className={s.inline}>
          <Field label="code" error={code && bad ? "4 to 20 letters and digits" : null} hint={clean ? `redeemed as ${clean}` : "letters and digits"}>
            <input id="promo-code" value={code} onChange={(e) => setCode(e.target.value)} placeholder="SPRING26" style={{ width: 180 }} />
          </Field>
          <Field label="lords" hint="0 is no limit">
            <input id="promo-max" type="number" min={0} value={maxUses} onChange={(e) => setMaxUses(whole(e.target.value))} />
          </Field>
          <Field label="days" hint="0 is never">
            <input id="promo-days" type="number" min={0} max={365} value={days} onChange={(e) => setDays(whole(e.target.value))} />
          </Field>
        </div>
        <div className={s.inline}>
          <Field label="diamonds" error={tooMany ? `at most ${maxDiamonds}` : null}>
            <input id="promo-diamonds" type="number" min={0} value={diamonds} onChange={(e) => setDiamonds(whole(e.target.value))} />
          </Field>
          <Field label="gold wages" hint="energy of their best job">
            <input id="promo-goldwages" type="number" min={0} value={goldWages} onChange={(e) => setGoldWages(whole(e.target.value))} />
          </Field>
          <Field label="xp wages" hint="energy of experience">
            <input id="promo-xpwages" type="number" min={0} value={xpWages} onChange={(e) => setXpWages(whole(e.target.value))} />
          </Field>
          <Field label="potions">
            <input id="promo-potions" type="number" min={0} value={potions} onChange={(e) => setPotions(whole(e.target.value))} />
          </Field>
          <Field label="charters">
            <input id="promo-charters" type="number" min={0} value={charters} onChange={(e) => setCharters(whole(e.target.value))} />
          </Field>
        </div>
        <div className={s.inline}>
          <Field label="gear tier">
            <select id="promo-tier" value={tier} onChange={(e) => setTier(e.target.value)}>
              <option value="">none</option>
              {tiers.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
            </select>
          </Field>
          <Field label="pieces">
            <input id="promo-items" type="number" min={0} value={items} disabled={!tier} onChange={(e) => setItems(whole(e.target.value))} />
          </Field>
          <div className={s.grow}>
            <Field label="why" hint="Kept with the code and in the audit trail.">
              <input id="promo-note" value={note} onChange={(e) => setNote(e.target.value)} placeholder="the spring livestream" style={{ width: "100%" }} />
            </Field>
          </div>
        </div>
        <div className={s.actions}>
          <span className="u-faint">Gives: {describe(reward, tiers)}</span>
          <span className={s.grow} />
          <Button type="submit" variant="primary" disabled={bad || empty || tooMany} busy={pending.has("promo:create")}>
            Make {clean || "the code"}
          </Button>
        </div>
      </form>
    </Panel>
  );
}

function Redeemed({ code }: { code: string }) {
  const [rows, setRows] = useState<Redemption[] | null>(null);
  useEffect(() => {
    void query<{ redemptions: Redemption[] }>("promoRedemptions", { code }).then((res) => {
      if (res.ok) setRows(res.data.redemptions ?? []);
    });
  }, [code]);
  if (!rows) return <Skeleton h={40} />;
  if (rows.length === 0) return <span className="u-faint">Nobody has redeemed it yet.</span>;
  return (
    <span className={s.who}>
      {rows.map((r) => (
        <span key={r.player_id}>
          {r.username ? <Link href={`/players/${r.player_id}`}>{r.username}</Link> : <span className="u-faint">deleted</span>}
          <span className="u-faint"> {shortDate(r.redeemed_at)}</span>
        </span>
      ))}
    </span>
  );
}

export function PromoView() {
  const me = useSlice("me");
  const pending = useSlice("pending");
  const mutate = useMutate();
  const canMake = me ? atLeast(me.role, "designer") : false;
  const [codes, setCodes] = useState<Code[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tiers, setTiers] = useState<Tier[]>([]);
  const [maxDiamonds, setMaxDiamonds] = useState(100);
  const [open, setOpen] = useState<string | null>(null);

  const load = useCallback(async () => {
    const res = await query<{ codes: Code[] }>("promo");
    if (res.ok) { setCodes(res.data.codes ?? []); setError(null); } else setError(res.message);
  }, []);

  useEffect(() => {
    void load();
    void query<{ document: BalanceDoc }>("balance").then((res) => {
      if (!res.ok) return;
      setTiers([...(res.data.document.tiers?.tiers ?? [])].sort((a, b) => a.rank - b.rank));
      setMaxDiamonds(res.data.document.rewards?.promo?.max_diamonds ?? 100);
    });
  }, [load]);

  async function disable(c: Code) {
    const res = await mutate("promoDisable", { code: c.code, note: "" }, { key: `promo:off:${c.code}`, success: `${c.code} disabled` });
    if (res.ok) void load();
  }

  return (
    <div className={s.page}>
      {canMake && <Create tiers={tiers} maxDiamonds={maxDiamonds} onMade={() => void load()} />}
      <Panel title="Codes" flush>
        {error && !codes ? (
          <EmptyState title="Could not load the codes"><span className="u-faint">{error}</span></EmptyState>
        ) : !codes ? (
          <div style={{ padding: "var(--s6)" }}><Skeleton h={120} /></div>
        ) : codes.length === 0 ? (
          <EmptyState title="No code has been made" />
        ) : (
          <TableWrap>
            <Table>
              <thead>
                <tr>
                  <th>code</th><th>state</th><th>gives</th><th className={numCell}>lords</th>
                  <th>ends (utc)</th><th>made by</th><th />
                </tr>
              </thead>
              <tbody>
                {codes.map((c) => (
                  <Fragment key={c.code}>
                    <tr>
                      <td>
                        <div className={s.twoLine}>
                          <span className="u-mono">{c.code}</span>
                          {c.note && <span className="u-faint">{c.note}</span>}
                        </div>
                      </td>
                      <td><Pill tone={STATE_TONE[c.state] ?? "neutral"} dot hollow={c.state !== "live"}>{STATE_WORD[c.state] ?? c.state}</Pill></td>
                      <td className={s.gives} title={describe(c.reward, tiers)}>{describe(c.reward, tiers)}</td>
                      <td className={numCell}>{num(c.uses)}{c.max_uses ? <span className="u-faint"> / {num(c.max_uses)}</span> : ""}</td>
                      <td className="u-mono u-faint">{c.expires_at ? shortDate(c.expires_at) : "never"}</td>
                      <td className="u-faint">{c.created_by} <span className="u-mono">{shortDate(c.created_at).slice(0, 10)}</span></td>
                      <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                        <Button size="sm" variant="quiet" onClick={() => setOpen(open === c.code ? null : c.code)}>
                          {open === c.code ? "hide" : "who"}
                        </Button>
                        {canMake && c.state === "live" && (
                          <Button size="sm" variant="quiet" busy={pending.has(`promo:off:${c.code}`)} onClick={() => void disable(c)}>disable</Button>
                        )}
                      </td>
                    </tr>
                    {open === c.code && (
                      <tr>
                        <td colSpan={7} style={{ whiteSpace: "normal", height: "auto", padding: "var(--s3) var(--s5) var(--s4)" }}>
                          <Redeemed code={c.code} />
                        </td>
                      </tr>
                    )}
                  </Fragment>
                ))}
              </tbody>
            </Table>
          </TableWrap>
        )}
      </Panel>
    </div>
  );
}
