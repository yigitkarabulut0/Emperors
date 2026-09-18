"use client";

import { Panel, Pill, Stat, Stats } from "@/ui/kit";
import { duration, num } from "@/lib/format";

export type Loop = {
  cart_stock: number; cart_cap: number; cart_next_in: number; carts_opened: number;
  calendar_pos: number; calendar_cycles: number; streak: number; last_claim: string;
  road_claimed: number; road_total: number;
  guide_step: string; guide_index: number; guide_steps: number; guide_skipped: boolean;
  golden_today: number; winback_at: string;
};

/**
 * Where a lord stands in the daily loop (retention.json): the questions
 * support is asked -- where is my cart, why did my run break, is the guide
 * stuck -- answered from the lord's own row with the game's arithmetic.
 */
export function DailyLoop({ loop }: { loop: Loop | undefined }) {
  if (!loop) return null;
  const guide = loop.guide_step
    ? <Pill tone="warn" dot>step {loop.guide_index + 1} of {loop.guide_steps} · {loop.guide_step.replace(/_/g, " ")}</Pill>
    : loop.guide_skipped
      ? <Pill dot hollow>guide skipped</Pill>
      : <Pill tone="ok" dot>guide over</Pill>;
  return (
    <Panel title="The daily loop" actions={guide}>
      <Stats>
        <Stat
          label="Tax Cart" value={`${loop.cart_stock} / ${loop.cart_cap}`}
          sub={loop.cart_stock >= loop.cart_cap ? "waiting · the yard is full" : `waiting · next in ${duration(loop.cart_next_in)}`}
        />
        <Stat label="Carts opened" value={num(loop.carts_opened)} muted />
        <Stat
          label="Calendar" value={loop.calendar_pos ? `day ${loop.calendar_pos}` : "—"}
          sub={loop.calendar_pos
            ? `of 28 · ${num(loop.streak)} in a row · ${num(loop.calendar_cycles)} cycles${loop.last_claim ? ` · last ${loop.last_claim}` : ""}`
            : "not begun"}
        />
        <Stat label="Victory Road" value={`${loop.road_claimed} / ${loop.road_total}`} sub="milestones claimed" muted />
        <Stat label="Golden Hours" value={num(loop.golden_today)} sub="lit today" muted />
        <Stat label="Welcome back" value={loop.winback_at ? loop.winback_at.slice(5, 10) : "—"}
          sub={loop.winback_at ? `sent ${loop.winback_at} UTC` : "never sent"} muted />
      </Stats>
    </Panel>
  );
}
