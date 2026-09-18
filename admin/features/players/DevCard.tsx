"use client";

import { useEffect, useState } from "react";
import { query, useMutate, useSlice } from "@/store/react";
import { Button, Field, Panel } from "@/ui/kit";
import { atLeast } from "@/lib/ops";

type Dev = { available: boolean; max_hours: number; deeds: string[] };

/**
 * Dev tools on a lord, from a server that is not production: move their clocks
 * as if they had been away, or count deeds as if they had done them. Hidden
 * wherever the server has no tools, which is production.
 */
export function DevCard({ id, onChanged }: { id: string; onChanged: () => void }) {
  const me = useSlice("me");
  const pending = useSlice("pending");
  const mutate = useMutate();
  const [dev, setDev] = useState<Dev | null>(null);
  const [hours, setHours] = useState(8);
  const [deed, setDeed] = useState("");
  const [n, setN] = useState(1);

  useEffect(() => {
    void query<Dev>("dev").then((res) => {
      if (res.ok && res.data.available) {
        setDev(res.data);
        setDeed(res.data.deeds[0] ?? "");
      }
    });
  }, []);

  if (!dev || !me || !atLeast(me.role, "designer")) return null;

  async function warp(h: number) {
    const res = await mutate("devTimeWarp", { player_id: id, hours: h }, { key: "warp", success: `${h} hours passed for this lord` });
    if (res.ok) onChanged();
  }
  async function restartGuide() {
    const res = await mutate("devGuide", { player_id: id }, { key: "guide", success: "the guide starts again at its first step" });
    if (res.ok) onChanged();
  }
  async function count() {
    const res = await mutate("devDeeds", { player_id: id, deed, n }, { key: "deeds", success: `${n} × ${deed} counted` });
    if (res.ok) onChanged();
  }
  const whole = (v: string) => Math.max(1, Math.trunc(Number(v) || 1));

  return (
    <Panel title="Dev tools · this server only">
      <div style={{ display: "grid", gap: "var(--s5)" }}>
        <p className="u-faint" style={{ margin: 0 }}>
          Moves this lord&apos;s clocks, never the server&apos;s: energy and the storehouse fill as if they had been
          away; shields, boosts, offers, letters, cooldowns and revenge windows run out that much sooner; the
          day&apos;s reward, refills, rerolls, the Stipend, Royal Favour&apos;s gift and the day&apos;s deals come round by
          whole days. Production has none of this.
        </p>
        <div style={{ display: "flex", gap: "var(--s4)", alignItems: "flex-end", flexWrap: "wrap" }}>
          <Field label="hours away">
            <input id="dev-hours" type="number" min={1} max={dev.max_hours} value={hours} onChange={(e) => setHours(whole(e.target.value))} />
          </Field>
          <Button variant="primary" busy={pending.has("warp")} onClick={() => void warp(hours)}>Warp</Button>
          {[1, 8, 24].map((h) => (
            <Button key={h} size="sm" variant="quiet" onClick={() => void warp(h)}>+{h}h</Button>
          ))}
        </div>
        <div style={{ display: "flex", gap: "var(--s4)", alignItems: "flex-end", flexWrap: "wrap" }}>
          <Field label="deed">
            <select id="dev-deed" value={deed} onChange={(e) => setDeed(e.target.value)}>
              {dev.deeds.map((k) => <option key={k} value={k}>{k.replace(/_/g, " ")}</option>)}
            </select>
          </Field>
          <Field label="how many">
            <input id="dev-deed-n" type="number" min={1} value={n} onChange={(e) => setN(whole(e.target.value))} />
          </Field>
          <Button variant="ghost" busy={pending.has("deeds")} onClick={() => void count()}>Count them</Button>
        </div>
        <div style={{ display: "flex", gap: "var(--s4)", alignItems: "center", flexWrap: "wrap" }}>
          <Button variant="ghost" busy={pending.has("guide")} onClick={() => void restartGuide()}>Restart the guide</Button>
          <span className="u-faint">puts this lord back at the steward&apos;s first step, as a new lord begins it</span>
        </div>
      </div>
    </Panel>
  );
}
