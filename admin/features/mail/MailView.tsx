"use client";

import { Fragment, useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { query, useMutate, useNowTick, useSlice, useStore } from "@/store/react";
import { Button, EmptyState, Field, Panel, Pill, Skeleton } from "@/ui/kit";
import { atLeast, type Role } from "@/lib/ops";
import { bp, gold, num, parseUTC, pctOf, shortDate } from "@/lib/format";
import s from "./mail.module.css";

/* ------------------------------------------------------------------ types --- */

type Target = "player" | "segment" | "all";
type Segment = { min_level: number; max_level: number; active_days: number };

/** gameconfig.ItemGrant: no slot rolls one of the three. */
type ItemGrant = { slot?: string; tier: string; count: number };
/** A gear row in the form, where "" is "any slot". */
type ItemRow = { slot: string; tier: string; count: number };
type BoostGrant = { bucket: string; bp: number; hours: number };
/** gameconfig.RewardBundle, as the server reads it: zero fields left out. */
type Bundle = {
  diamonds?: number; gold?: number; xp?: number; gold_wages?: number; xp_wages?: number;
  favour?: number; tokens?: Record<string, number>; items?: ItemGrant[];
  cosmetics?: string[]; boosts?: BoostGrant[];
};

type Token = { id: string; name: string };
type Cosmetic = { id: string; kind: string; name: string; default_owned?: boolean; source_hint?: string };
type Tier = { id: string; name: string; rank: number };
type Limits = {
  max_diamonds: number; max_gold: number; max_xp: number; max_wages_energy: number;
  max_favour: number; max_items: number; max_tokens: number; max_boost_hours: number;
};
/** What the live balance says a letter may carry. */
type Catalog = {
  tokens: Token[]; cosmetics: Cosmetic[]; tiers: Tier[]; limits: Limits;
  defaultExpiry: number; levelCap: number;
};
type BalanceDoc = {
  rewards?: { tokens?: Token[]; limits?: Limits; mail?: { default_expiry_days?: number } };
  cosmetics?: { items?: Cosmetic[] };
  tiers?: { tiers?: Tier[] };
  progression?: { level_cap?: number };
};

type Lord = { id: string; username: string; name: string; level: number };

type Broadcast = {
  id: number; audience: Target; segment: Partial<Segment> | null;
  sender: string; title: string; body: string; attachments: Bundle;
  expires_at: string; created_by: string; created_at: string;
  delivered: number; claimed: number; withdrawn: number; revoked: boolean;
  include_new: boolean; recipient: string; note: string;
};

type Draft = {
  diamonds: number; gold: number; xp: number; gold_wages: number; xp_wages: number; favour: number;
  tokens: Record<string, number>; items: ItemRow[]; cosmetics: string[]; boosts: BoostGrant[];
};

const EMPTY: Draft = {
  diamonds: 0, gold: 0, xp: 0, gold_wages: 0, xp_wages: 0, favour: 0,
  tokens: {}, items: [], cosmetics: [], boosts: [],
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SLOTS: [string, string][] = [["", "any slot"], ["weapon", "weapon"], ["armor", "armour"], ["horse", "horse"]];
/** The buckets a reward may carry a timed bonus in (gameconfig.rewardBoostBuckets). */
const BOOSTS: [string, string][] = [["collect_income_bp", "gold from work"], ["xp_bp", "experience"]];
/** gameconfig.CheckReward's ceiling on a single timed bonus. */
const MAX_BOOST_BP = 20000;

/* --------------------------------------------------------------- the rules --- */

/** The bundle as sent: zero amounts and empty lists left out. */
function bundleOf(d: Draft): Bundle {
  const b: Bundle = {};
  for (const k of ["diamonds", "gold", "xp", "gold_wages", "xp_wages", "favour"] as const) {
    if (d[k] > 0) b[k] = d[k];
  }
  const tokens = Object.fromEntries(Object.entries(d.tokens).filter(([, n]) => n > 0));
  if (Object.keys(tokens).length) b.tokens = tokens;
  if (d.items.length) {
    b.items = d.items.map((i): ItemGrant => (i.slot ? { slot: i.slot, tier: i.tier, count: i.count } : { tier: i.tier, count: i.count }));
  }
  if (d.cosmetics.length) b.cosmetics = d.cosmetics;
  if (d.boosts.length) b.boosts = d.boosts;
  return b;
}

/** gameconfig.RewardBundle.Empty. */
function isEmpty(b: Bundle): boolean {
  return !b.diamonds && !b.gold && !b.xp && !b.gold_wages && !b.xp_wages && !b.favour &&
    !Object.keys(b.tokens ?? {}).length && !(b.items ?? []).length &&
    !(b.cosmetics ?? []).length && !(b.boosts ?? []).length;
}

/**
 * The least role that may send this letter -- admin.mailRole, mirrored so the
 * operator knows BEFORE sending. The server decides; it answers a letter above
 * the sender's role with a bare 403, and this is the sentence that explains it.
 */
function mailRole(target: Target, b: Bundle): { role: Role; why: string } {
  if (target === "all" && !isEmpty(b)) return { role: "owner", why: "it is a gift to every lord" };
  const moves: string[] = [];
  if (b.gold || b.gold_wages) moves.push("gold");
  if (b.xp || b.xp_wages) moves.push("experience");
  if (b.favour) moves.push("favour");
  if ((b.items ?? []).length) moves.push("gear");
  if ((b.boosts ?? []).length) moves.push("a timed bonus");
  if ((b.cosmetics ?? []).length) moves.push("a cosmetic");
  if ((b.diamonds ?? 0) > 100) moves.push("more than 100 diamonds");
  if (moves.length) return { role: "designer", why: `it carries ${moves.join(", ")}` };
  return { role: "moderator", why: isEmpty(b) ? "it carries words only" : "it carries a small gift" };
}

/** A bundle in words, for the confirmation and the history. */
function describe(b: Bundle, cat: Catalog | null): string[] {
  const out: string[] = [];
  if (b.diamonds) out.push(`${num(b.diamonds)} diamonds`);
  if (b.gold) out.push(`${gold(b.gold)} gold`);
  if (b.gold_wages) out.push(`gold for ${num(b.gold_wages)} energy of work`);
  if (b.xp) out.push(`${num(b.xp)} xp`);
  if (b.xp_wages) out.push(`xp for ${num(b.xp_wages)} energy of work`);
  if (b.favour) out.push(`${num(b.favour)} favour`);
  for (const [id, n] of Object.entries(b.tokens ?? {})) {
    out.push(`${n} × ${cat?.tokens.find((t) => t.id === id)?.name ?? id}`);
  }
  for (const i of b.items ?? []) {
    const tier = cat?.tiers.find((t) => t.id === i.tier)?.name ?? i.tier;
    out.push(`${i.count} × ${tier.toLowerCase()} ${i.slot ? (i.slot === "armor" ? "armour" : i.slot) : "gear"}`);
  }
  for (const id of b.cosmetics ?? []) out.push(cat?.cosmetics.find((c) => c.id === id)?.name ?? id);
  for (const g of b.boosts ?? []) {
    out.push(`${bp(g.bp)} ${BOOSTS.find(([k]) => k === g.bucket)?.[1] ?? g.bucket} for ${g.hours}h`);
  }
  return out;
}

function catalogOf(doc: BalanceDoc): Catalog | null {
  const r = doc.rewards;
  if (!r?.limits || !r.tokens) return null;
  return {
    tokens: r.tokens,
    cosmetics: doc.cosmetics?.items ?? [],
    tiers: [...(doc.tiers?.tiers ?? [])].sort((a, b) => a.rank - b.rank),
    limits: r.limits,
    defaultExpiry: r.mail?.default_expiry_days ?? 30,
    levelCap: doc.progression?.level_cap ?? 60,
  };
}

const whole = (v: string) => Math.max(0, Math.trunc(Number(v) || 0));

/* ---------------------------------------------------------------- composer --- */

function Composer({ cat, onSent }: { cat: Catalog; onSent: () => void }) {
  const me = useSlice("me");
  const pending = useSlice("pending");
  const store = useStore();
  const mutate = useMutate();
  const params = useSearchParams();

  const [target, setTarget] = useState<Target>("player");
  const [lord, setLord] = useState<Lord | null>(null);
  const [search, setSearch] = useState("");
  const [matches, setMatches] = useState<Lord[] | null>(null);
  const [finding, setFinding] = useState(false);
  const [findError, setFindError] = useState<string | null>(null);
  const [seg, setSeg] = useState<Segment>({ min_level: 1, max_level: 0, active_days: 0 });
  const [includeNew, setIncludeNew] = useState(false);
  const [audience, setAudience] = useState<number | null>(null);

  const [sender, setSender] = useState("");
  const [title, setTitle] = useState("");
  const [body, setBody] = useState("");
  const [draft, setDraft] = useState<Draft>(EMPTY);
  const [expires, setExpires] = useState(cat.defaultExpiry);
  const [note, setNote] = useState("");
  const [tried, setTried] = useState(false);

  const lookUp = useCallback(async (id: string) => {
    const res = await query<{ id: string; username: string; name: string; level: number }>("playerDetail", { id });
    if (res.ok) {
      setLord({ id: res.data.id, username: res.data.username, name: res.data.name, level: res.data.level });
      setMatches(null);
      setFindError(null);
    } else setFindError(res.status === 404 ? "no lord has that id" : res.message);
  }, []);

  // The player page's "send a letter" arrives with ?player=<id>.
  const preset = params.get("player");
  useEffect(() => {
    if (preset && UUID.test(preset)) {
      setTarget("player");
      void lookUp(preset);
    }
  }, [preset, lookUp]);

  async function find() {
    const q = search.trim();
    if (!q) return;
    setFinding(true);
    if (UUID.test(q)) {
      await lookUp(q);
    } else {
      const res = await query<{ players: { id: string; username: string; name: string; level: number }[] }>(
        "browse", { q, limit: 8, sort: "last_seen" });
      if (res.ok) {
        setMatches(res.data.players.map((p) => ({ id: p.id, username: p.username, name: p.name, level: p.level })));
        setFindError(null);
      } else setFindError(res.message);
    }
    setFinding(false);
  }

  // How many the letter reaches, asked of the server as the choice changes.
  useEffect(() => {
    if (target === "player") { setAudience(lord ? 1 : 0); return; }
    setAudience(null);
    const t = setTimeout(async () => {
      const res = await query<{ audience: number }>("mailPreview", target === "segment"
        ? { target, min_level: seg.min_level, max_level: seg.max_level, active_days: seg.active_days }
        : { target });
      setAudience(res.ok ? res.data.audience : null);
    }, 250);
    return () => clearTimeout(t);
  }, [target, seg, lord]);

  const bundle = bundleOf(draft);
  const need = mailRole(target, bundle);
  const mayAct = me ? atLeast(me.role, need.role) : false;
  const L = cat.limits;
  const carries = describe(bundle, cat);

  /* Everything the server would refuse, said next to the field it is about. */
  const over = (v: number, max: number) => (v > max ? `over the limit of ${num(max)} — the server will refuse it` : null);
  const itemTotal = draft.items.reduce((a, i) => a + i.count, 0);
  const problems: Record<string, string | null> = {
    title: title.trim() === "" ? "a letter needs a title" : [...title.trim()].length > 80 ? "80 characters at most" : null,
    body: [...body].length > 2000 ? "2000 characters at most" : null,
    sender: [...sender].length > 40 ? "40 characters at most" : null,
    expires: expires < 1 || expires > 90 ? "a letter lasts 1 to 90 days" : null,
    lord: target === "player" && !lord ? "choose the lord it goes to" : null,
    segment: target === "segment" && seg.max_level > 0 && seg.min_level > seg.max_level ? "the lowest level is above the highest" : null,
    diamonds: over(draft.diamonds, L.max_diamonds),
    gold: over(draft.gold, L.max_gold),
    xp: over(draft.xp, L.max_xp),
    gold_wages: over(draft.gold_wages, L.max_wages_energy),
    xp_wages: over(draft.xp_wages, L.max_wages_energy),
    favour: over(draft.favour, L.max_favour),
    tokens: Object.values(draft.tokens).some((n) => n > L.max_tokens) ? `${num(L.max_tokens)} of a kind at most` : null,
    items: itemTotal > L.max_items ? `${num(L.max_items)} pieces of gear at most` :
      draft.items.some((i) => i.count < 1) ? "every row needs a count" : null,
    boosts: draft.boosts.some((b) => b.bp < 1 || b.bp > MAX_BOOST_BP) ? `a bonus is +0.01% to ${bp(MAX_BOOST_BP)}` :
      draft.boosts.some((b) => b.hours < 1 || b.hours > L.max_boost_hours) ? `a bonus lasts 1 to ${L.max_boost_hours} hours` : null,
  };
  // Required fields are quiet until the first try; limits speak at once.
  const quietUntilTried = new Set(["title", "lord"]);
  const shown = (k: string) => (quietUntilTried.has(k) && !tried ? null : problems[k]);
  const blocking = Object.values(problems).filter(Boolean);

  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => setDraft((d) => ({ ...d, [k]: v }));

  async function send() {
    setTried(true);
    if (blocking.length || !mayAct) return;
    const who = target === "player"
      ? `${lord!.name || lord!.username} (@${lord!.username})`
      : target === "segment"
        ? `${num(audience ?? 0)} lords of levels ${seg.min_level}–${seg.max_level || cat.levelCap}`
        : `every lord — ${num(audience ?? 0)} now${includeNew ? ", and every lord who joins before it expires" : ""}`;
    const what = carries.length ? `\n\nIt carries ${carries.join(", ")}.` : "\n\nIt carries words only.";
    if (!confirm(`Send “${title.trim()}” to ${who}?${what}\n\nA letter cannot be unsent; it can be revoked, which takes back only the copies nobody has claimed.`)) {
      return;
    }
    const res = await mutate<{ broadcast_id: number; delivered: number; audience: number }>("mailSend", {
      target,
      player_id: target === "player" ? lord!.id : undefined,
      segment: target === "segment" ? seg : undefined,
      sender: sender.trim() || undefined,
      title: title.trim(),
      body,
      attachments: bundle,
      expires_days: expires,
      include_new: target === "all" ? includeNew : undefined,
      note: note.trim() || undefined,
    }, { key: "mail" });
    if (!res.ok) return;
    store.toast("ok", target === "all"
      ? `Sent. Each of ${num(res.data.audience)} lords receives it when they next open the game.`
      : `Delivered to ${num(res.data.delivered)} ${res.data.delivered === 1 ? "lord" : "lords"}.`);
    setTitle(""); setBody(""); setDraft(EMPTY); setNote(""); setTried(false);
    onSent();
  }

  return (
    <Panel title="Write a letter">
      <div className={s.form}>
        <div className={s.two}>
          {/* ---------------------------------------------- who and what it says */}
          <div className={s.col}>
            <div className={s.section}>to</div>
            <div className={s.seg} role="radiogroup" aria-label="who it goes to">
              {([["player", "one lord"], ["segment", "a group"], ["all", "every lord"]] as [Target, string][]).map(([t, label]) => (
                <button key={t} type="button" role="radio" aria-checked={target === t}
                  className={s.segBtn} data-on={target === t} onClick={() => setTarget(t)}>
                  {label}
                </button>
              ))}
            </div>

            {target === "player" && (
              lord ? (
                <div className="u-row">
                  <span className={s.chosen}>
                    <span>{lord.name || lord.username}</span>
                    <span className={s.sub}>@{lord.username} · level {lord.level}</span>
                    <Button size="sm" variant="quiet" aria-label="choose someone else" onClick={() => setLord(null)}>✕</Button>
                  </span>
                  <Link href={`/players/${lord.id}`} className="u-faint" style={{ fontSize: "var(--t-small)" }}>open their page</Link>
                </div>
              ) : (
                <>
                  <Field label="find a lord" error={findError ?? shown("lord")} hint="a name, or the id from their page">
                    <span className={s.search}>
                      <input value={search} onChange={(e) => setSearch(e.target.value)}
                        onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); void find(); } }}
                        placeholder="username or id" />
                      <Button busy={finding} onClick={() => void find()}>Find</Button>
                    </span>
                  </Field>
                  {matches && (matches.length === 0
                    ? <span className="u-faint" style={{ fontSize: "var(--t-small)" }}>Nobody by that name.</span>
                    : (
                      <div className={s.matches}>
                        {matches.map((m) => (
                          <button key={m.id} type="button" className={s.match} onClick={() => { setLord(m); setMatches(null); }}>
                            <span>{m.name || m.username}</span>
                            <span className={s.sub}>@{m.username} · level {m.level}</span>
                          </button>
                        ))}
                      </div>
                    ))}
                </>
              )
            )}

            {target === "segment" && (
              <div className={s.fields}>
                <Field label="from level">
                  <input type="number" min={1} value={seg.min_level}
                    onChange={(e) => setSeg({ ...seg, min_level: Math.max(1, whole(e.target.value)) })} />
                </Field>
                <Field label="to level" hint={seg.max_level === 0 ? `0 is the cap, ${cat.levelCap}` : undefined} error={problems.segment}>
                  <input type="number" min={0} value={seg.max_level}
                    onChange={(e) => setSeg({ ...seg, max_level: whole(e.target.value) })} />
                </Field>
                <Field label="seen within days" hint={seg.active_days === 0 ? "0 is anyone, however long ago" : undefined}>
                  <input type="number" min={0} value={seg.active_days}
                    onChange={(e) => setSeg({ ...seg, active_days: whole(e.target.value) })} />
                </Field>
              </div>
            )}

            {target === "all" && (
              <label className={s.check}>
                <input type="checkbox" checked={includeNew} onChange={(e) => setIncludeNew(e.target.checked)} />
                also every lord who joins before it expires
              </label>
            )}

            <p className={s.help}>
              {target === "player" ? (lord ? "Reaches one lord." : "Reaches one lord, once chosen.")
                : audience === null ? "Counting who it reaches…"
                : target === "all"
                  ? <>Reaches <span className={s.readout}>{num(audience)}</span> lords, each when they next open the game. Banned lords and bots are left out.</>
                  : <>Reaches <span className={s.readout}>{num(audience)}</span> lords now. Banned lords and bots are left out.</>}
            </p>

            <div className={s.section}>the letter</div>
            <Field label="from" hint="Shown as the sender. Empty is “The Crown”." error={problems.sender}>
              <input value={sender} maxLength={60} placeholder="The Crown" onChange={(e) => setSender(e.target.value)} />
            </Field>
            <Field label="title" hint={`${[...title.trim()].length} / 80`} error={shown("title")}>
              <input value={title} maxLength={100} placeholder="For your patience during the outage" onChange={(e) => setTitle(e.target.value)} />
            </Field>
            <div className={s.body}>
              <Field label="body" hint={`${[...body].length} / 2000`} error={problems.body}>
                <textarea value={body} className={s.wide} onChange={(e) => setBody(e.target.value)}
                  placeholder="My lords — the realm was dark for an hour this morning. Accept this with the Crown's thanks." />
              </Field>
            </div>
          </div>

          {/* ------------------------------------------------- what it carries */}
          <div className={s.col}>
            <div className={s.section}>what it carries</div>
            <div className={s.fields}>
              <Field label="diamonds" error={problems.diamonds}>
                <input type="number" min={0} value={draft.diamonds} onChange={(e) => set("diamonds", whole(e.target.value))} />
              </Field>
              <Field label="gold" error={problems.gold}>
                <input type="number" min={0} value={draft.gold} onChange={(e) => set("gold", whole(e.target.value))} />
              </Field>
              <Field label="xp" error={problems.xp}>
                <input type="number" min={0} value={draft.xp} onChange={(e) => set("xp", whole(e.target.value))} />
              </Field>
              <Field label="favour" error={problems.favour}>
                <input type="number" min={0} value={draft.favour} onChange={(e) => set("favour", whole(e.target.value))} />
              </Field>
            </div>
            <div className={s.fields}>
              <Field label="gold wages" hint="in energy" error={problems.gold_wages}>
                <input type="number" min={0} value={draft.gold_wages} onChange={(e) => set("gold_wages", whole(e.target.value))} />
              </Field>
              <Field label="xp wages" hint="in energy" error={problems.xp_wages}>
                <input type="number" min={0} value={draft.xp_wages} onChange={(e) => set("xp_wages", whole(e.target.value))} />
              </Field>
            </div>
            <p className={s.help}>
              Wages are paid in energy: what that much energy earns at the best job the lord can
              do, so the gift is the same share of a day&rsquo;s play at level 5 and at level 55.
              Prefer them to flat gold and xp, which mean a fortune to one lord and nothing to another.
            </p>

            {cat.tokens.length > 0 && (
              <div className={s.fields}>
                {cat.tokens.map((t) => (
                  <Field key={t.id} label={t.name.toLowerCase()} error={(draft.tokens[t.id] ?? 0) > L.max_tokens ? problems.tokens : null}>
                    <input type="number" min={0} value={draft.tokens[t.id] ?? 0}
                      onChange={(e) => set("tokens", { ...draft.tokens, [t.id]: whole(e.target.value) })} />
                  </Field>
                ))}
              </div>
            )}

            <div className={s.rows}>
              <span className="u-micro">gear</span>
              {draft.items.map((it, i) => (
                <div key={i} className={s.rowLine}>
                  <Field label="tier">
                    <select value={it.tier}
                      onChange={(e) => set("items", draft.items.map((x, j) => (j === i ? { ...x, tier: e.target.value } : x)))}>
                      {cat.tiers.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                    </select>
                  </Field>
                  <Field label="slot">
                    <select value={it.slot}
                      onChange={(e) => set("items", draft.items.map((x, j) => (j === i ? { ...x, slot: e.target.value } : x)))}>
                      {SLOTS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                    </select>
                  </Field>
                  <Field label="how many">
                    <input type="number" min={1} value={it.count} style={{ width: 80 }}
                      onChange={(e) => set("items", draft.items.map((x, j) => (j === i ? { ...x, count: whole(e.target.value) } : x)))} />
                  </Field>
                  <Button variant="quiet" aria-label="remove this gear"
                    onClick={() => set("items", draft.items.filter((_, j) => j !== i))}>✕</Button>
                </div>
              ))}
              {problems.items && <span className={s.bad}>{problems.items}</span>}
              <span>
                <Button size="sm" disabled={!cat.tiers.length}
                  onClick={() => set("items", [...draft.items, { tier: cat.tiers[0]?.id ?? "common", slot: "", count: 1 }])}>
                  add gear
                </Button>
              </span>
              {draft.items.length > 0 && (
                <span className={s.sub}>Rolled at the lord&rsquo;s own level when the letter is claimed.</span>
              )}
            </div>

            <div className={s.rows}>
              <span className="u-micro">timed bonus</span>
              {draft.boosts.map((g, i) => (
                <div key={i} className={s.rowLine}>
                  <Field label="bonus to">
                    <select value={g.bucket}
                      onChange={(e) => set("boosts", draft.boosts.map((x, j) => (j === i ? { ...x, bucket: e.target.value } : x)))}>
                      {BOOSTS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
                    </select>
                  </Field>
                  <Field label={`basis points · ${bp(g.bp)}`}>
                    <input type="number" min={1} max={MAX_BOOST_BP} step={500} value={g.bp}
                      onChange={(e) => set("boosts", draft.boosts.map((x, j) => (j === i ? { ...x, bp: whole(e.target.value) } : x)))} />
                  </Field>
                  <Field label="hours">
                    <input type="number" min={1} max={L.max_boost_hours} value={g.hours} style={{ width: 80 }}
                      onChange={(e) => set("boosts", draft.boosts.map((x, j) => (j === i ? { ...x, hours: whole(e.target.value) } : x)))} />
                  </Field>
                  <Button variant="quiet" aria-label="remove this bonus"
                    onClick={() => set("boosts", draft.boosts.filter((_, j) => j !== i))}>✕</Button>
                </div>
              ))}
              {problems.boosts && <span className={s.bad}>{problems.boosts}</span>}
              <span>
                <Button size="sm" onClick={() => set("boosts", [...draft.boosts, { bucket: BOOSTS[0][0], bp: 5000, hours: 24 }])}>
                  add a timed bonus
                </Button>
              </span>
              {draft.boosts.length > 0 && (
                <span className={s.sub}>
                  Starts when the letter is claimed, in the timed lane with every other timed
                  bonus, under one cap.
                </span>
              )}
            </div>

            <div className={s.rows}>
              <span className="u-micro">cosmetics</span>
              {cat.cosmetics.filter((c) => !c.default_owned).length === 0 ? (
                <span className={s.sub}>
                  Every cosmetic in this balance is owned by everyone already, so none can be given.
                </span>
              ) : (
                <div className={s.checks}>
                  {cat.cosmetics.filter((c) => !c.default_owned).map((c) => (
                    <label key={c.id} className={s.check} title={c.source_hint ?? ""}>
                      <input type="checkbox" checked={draft.cosmetics.includes(c.id)}
                        onChange={(e) => set("cosmetics", e.target.checked
                          ? [...draft.cosmetics, c.id]
                          : draft.cosmetics.filter((x) => x !== c.id))} />
                      {c.name} <span className={s.sub}>{c.kind.replace("_", " ")}</span>
                    </label>
                  ))}
                </div>
              )}
            </div>
          </div>
        </div>

        {/* ------------------------------------------------------ send it */}
        <div className={`${s.foot} ${s.top}`}>
          <Field label="lasts days" error={problems.expires}>
            <input type="number" min={1} max={90} value={expires} onChange={(e) => setExpires(whole(e.target.value))} />
          </Field>
          <div className={s.grow}>
            <Field label="why" hint="Goes in the audit trail and the history below, never to the player.">
              <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="compensation for the 14 September outage" className={s.wide} />
            </Field>
          </div>
        </div>
        <div className={s.foot}>
          <div className={s.needs}>
            <span>
              This letter needs the <Pill tone={need.role === "owner" ? "bad" : need.role === "designer" ? "warn" : "neutral"}>{need.role}</Pill> role
              — {need.why}.
            </span>
            {!mayAct && me && (
              <span className={s.bad}>You are {me.role}: the server would refuse it. Ask a{need.role === "owner" ? "n" : ""} {need.role} to send it.</span>
            )}
            {tried && blocking.length > 0 && <span className={s.bad}>{blocking[0]}</span>}
            <span className={s.sub}>{carries.length ? `Carries ${carries.join(" · ")}` : "Carries words only."}</span>
          </div>
          <Button variant="primary" busy={pending.has("mail")} disabled={!mayAct} onClick={() => void send()}>
            Send the letter
          </Button>
        </div>
        <p className={s.help}>
          <strong>Who may send what.</strong> A moderator: words, and up to 100 diamonds or a few
          potions and charters. A designer: anything that moves the economy — gold, wages,
          experience, favour, gear, a timed bonus, a cosmetic, or more than 100 diamonds. The
          owner: any gift to every lord.
        </p>
      </div>
    </Panel>
  );
}

/* ----------------------------------------------------------------- history --- */

function To({ b, cap }: { b: Broadcast; cap: number }) {
  if (b.audience === "player") {
    return b.recipient ? <>{b.recipient}</> : <span className="u-faint" title="The lord has since deleted their account">a departed lord</span>;
  }
  if (b.audience === "all") {
    return <>every lord{b.include_new ? <span className={s.sub}> · and new ones</span> : null}</>;
  }
  const g = b.segment ?? {};
  const lo = g.min_level || 1;
  const hi = g.max_level || cap;
  return (
    <>
      levels {lo}–{hi}
      {g.active_days ? <span className={s.sub}> · seen in {g.active_days}d</span> : null}
    </>
  );
}

function History({ cat, stamp }: { cat: Catalog | null; stamp: number }) {
  const me = useSlice("me");
  const pending = useSlice("pending");
  const store = useStore();
  const mutate = useMutate();
  const now = useNowTick(30_000);
  const [letters, setLetters] = useState<Broadcast[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const res = await query<{ broadcasts: Broadcast[] }>("mailBroadcasts", { limit: 50 });
    if (res.ok) { setLetters(res.data.broadcasts ?? []); setError(null); } else setError(res.message);
  }, []);

  useEffect(() => { void load(); }, [load, stamp]);

  const canRevoke = me ? atLeast(me.role, "designer") : false;

  async function revoke(b: Broadcast) {
    const open = Math.max(0, b.delivered - b.claimed);
    if (!confirm(`Revoke “${b.title}”?\n\nNobody else receives it, and the unclaimed copies (${open} now) are taken back. What was claimed stays claimed.`)) {
      return;
    }
    const res = await mutate<{ unclaimed_pulled: number }>("mailRevoke",
      { broadcast_id: b.id, note: "revoked from the panel" }, { key: "revoke-mail:" + b.id });
    if (res.ok) {
      const n = res.data.unclaimed_pulled;
      store.toast("ok", `Revoked. ${num(n)} unclaimed ${n === 1 ? "copy" : "copies"} taken back.`);
      await load();
    }
  }

  return (
    <Panel title="Letters sent" flush actions={<Button size="sm" variant="quiet" onClick={() => void load()}>refresh</Button>}>
      {error ? (
        <EmptyState title="Could not load the letters"><span className="u-faint">{error}</span></EmptyState>
      ) : !letters ? (
        <div style={{ padding: "var(--s6)" }}><Skeleton h={140} /></div>
      ) : letters.length === 0 ? (
        <EmptyState title="No letter has been sent from the panel" />
      ) : (
        <div style={{ overflow: "auto" }}>
          <table className={s.table}>
            <thead>
              <tr>
                <th>sent</th><th>to</th><th>letter</th><th>carries</th>
                <th className={s.num}>reached</th><th className={s.num}>claimed</th>
                <th>expires</th><th>by</th><th>state</th><th />
              </tr>
            </thead>
            <tbody>
              {letters.map((b) => {
                const exp = parseUTC(b.expires_at);
                const expired = exp ? exp.getTime() < now : false;
                const what = describe(b.attachments ?? {}, cat);
                return (
                  <tr key={b.id}>
                    <td className="u-faint u-mono" style={{ whiteSpace: "nowrap" }}>{shortDate(b.created_at)}</td>
                    <td style={{ whiteSpace: "nowrap" }}><To b={b} cap={cat?.levelCap ?? 60} /></td>
                    <td title={b.body} className={s.letter}>
                      <div className={s.title}>{b.title}</div>
                      <div className={s.sub}>from {b.sender}{b.note ? ` · ${b.note}` : ""}</div>
                    </td>
                    <td className={s.carries}>
                      {what.length
                        ? what.map((w, i) => (
                          <Fragment key={w}>{i > 0 && <span className={s.dot}> · </span>}<span className={s.item}>{w}</span></Fragment>
                        ))
                        : <span className="u-faint">words only</span>}
                    </td>
                    <td className={s.num}>{num(b.delivered)}</td>
                    <td className={s.num}>
                      {num(b.claimed)}
                      {b.delivered > 0 && <span className={s.sub}> {pctOf(b.claimed, b.delivered)}</span>}
                    </td>
                    <td className="u-faint u-mono" style={{ whiteSpace: "nowrap" }}>{shortDate(b.expires_at)}</td>
                    <td className="u-dim">{b.created_by}</td>
                    <td style={{ whiteSpace: "nowrap" }}>
                      {b.revoked ? <Pill tone="bad" dot hollow>revoked</Pill>
                        : expired ? <Pill dot hollow>expired</Pill>
                        : <Pill tone="ok" dot>live</Pill>}
                      {b.revoked && b.withdrawn > 0 && (
                        <span className={s.sub}> {num(b.withdrawn)} taken back</span>
                      )}
                    </td>
                    <td>
                      {canRevoke && !b.revoked && !expired && (
                        <Button size="sm" variant="danger" busy={pending.has("revoke-mail:" + b.id)} onClick={() => void revoke(b)}>
                          revoke
                        </Button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <div style={{ padding: "var(--s5) var(--s6)", borderTop: "1px solid var(--hair)" }} className="u-faint">
        A letter to every lord is written into each inbox the next time that lord opens the game,
        so its reach grows after it is sent. Revoking stops it reaching anyone else and takes back
        the copies nobody has claimed.
      </div>
    </Panel>
  );
}

/* -------------------------------------------------------------------- page --- */

export function MailView() {
  const me = useSlice("me");
  const [cat, setCat] = useState<Catalog | null>(null);
  const [catError, setCatError] = useState<string | null>(null);
  const [stamp, setStamp] = useState(0);

  // What a letter may carry is the live balance's: its tokens, tiers,
  // cosmetics and limits, never a list copied into the panel.
  useEffect(() => {
    void (async () => {
      const res = await query<{ version: number; document: BalanceDoc }>("balance");
      if (!res.ok) { setCatError(res.message); return; }
      const c = catalogOf(res.data.document);
      if (c) setCat(c);
      else setCatError("the live balance has no rewards section, so nothing can be attached");
    })();
  }, []);

  const canSend = me ? atLeast(me.role, "moderator") : false;

  return (
    <div className={s.page}>
      {canSend && (
        catError ? (
          <EmptyState title="Could not open the composer"><span className="u-faint">{catError}</span></EmptyState>
        ) : !cat ? (
          <Panel title="Write a letter"><Skeleton h={320} /></Panel>
        ) : (
          <Composer cat={cat} onSent={() => setStamp((n) => n + 1)} />
        )
      )}
      <History cat={cat} stamp={stamp} />
    </div>
  );
}
