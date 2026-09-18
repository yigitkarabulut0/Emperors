"use client";

import { useState } from "react";
import { num } from "@/lib/format";
import s from "./columns.module.css";

/** One day of a series. */
export type Point = { day: string; count: number };

/** The top of a count axis: the next 1, 2, 2.5 or 5 times a power of ten. */
export function niceMax(v: number): number {
  if (v <= 1) return 1;
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  for (const m of [1, 2, 2.5, 5, 10]) if (m * p >= v) return m * p;
  return 10 * p;
}

/**
 * One series of daily counts as columns. The hovered or focused column lifts
 * and a tooltip gives its day and value; the same numbers are one click away as
 * a table, so nothing is reachable only by hovering.
 */
export function Columns({ points, unit, format = num }: {
  points: Point[];
  unit: [string, string];
  /** How a value reads on the axis and in the tooltip; counts by default. */
  format?: (n: number) => string;
}) {
  const [hover, setHover] = useState<number | null>(null);
  const top = niceMax(Math.max(0, ...points.map((p) => p.count)));
  const n = points.length;
  const at = hover === null ? null : points[hover];
  const edge = n > 0 && hover !== null ? (hover < n * 0.15 ? s.tipStart : hover > n * 0.85 ? s.tipEnd : "") : "";
  const md = (day: string) => day.slice(5);
  const say = (n: number) => `${format(n)} ${n === 1 ? unit[0] : unit[1]}`;
  // The tooltip stands just above its column, and never above the plot: over
  // the tallest column it sits inside the top of the plot instead.
  const lift = at ? `min(calc(${(at.count / top) * 100}% + 6px), calc(100% - 30px))` : "0";

  return (
    <div className={s.chart}>
      <div className={s.ticks} aria-hidden>
        <span>{format(top)}</span>
        <span>0</span>
      </div>
      <div className={s.plotWrap}>
        <div className={s.plot} onPointerLeave={() => setHover(null)}>
          {points.map((p, i) => (
            <span
              key={p.day}
              className={s.slot}
              data-active={hover === i}
              tabIndex={0}
              aria-label={`${p.day}: ${say(p.count)}`}
              onPointerEnter={() => setHover(i)}
              onFocus={() => setHover(i)}
              onBlur={() => setHover(null)}
            >
              <span className={s.col} style={{ height: `${(p.count / top) * 100}%` }} />
            </span>
          ))}
          {at && hover !== null && (
            <div className={`${s.tip} ${edge}`} style={{ left: `${((hover + 0.5) / n) * 100}%`, bottom: lift }}>
              <span className={s.tipValue}>{format(at.count)}</span>
              <span className={s.tipLabel}>{at.count === 1 ? unit[0] : unit[1]} · {at.day}</span>
            </div>
          )}
        </div>
        <div className={s.axis} aria-hidden>
          <span>{n ? md(points[0].day) : ""}</span>
          <span>{n ? md(points[n - 1].day) : ""}</span>
        </div>
      </div>
    </div>
  );
}
