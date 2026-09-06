/**
 * Number and time formatting, in one place.
 *
 * Gold arrives as a decimal STRING because it is a Go int64 and can exceed
 * Number.MAX_SAFE_INTEGER. Parsing it to a Number to format it would silently
 * corrupt large balances, so the grouping is done on the string.
 */
export function gold(v: string | number | undefined | null): string {
  if (v === undefined || v === null) return "—";
  const s = typeof v === "number" ? Math.trunc(v).toString() : v;
  const neg = s.startsWith("-");
  const digits = neg ? s.slice(1) : s;
  if (!/^\d+$/.test(digits)) return s;
  // A thin space, not a comma: it groups without adding a character that reads
  // as a decimal point to half the world.
  const grouped = digits.replace(/\B(?=(\d{3})+(?!\d))/g, " ");
  return (neg ? "-" : "") + grouped;
}

/** Short form for tiles, where the exact figure goes in the title attribute. */
export function compact(v: string | number | undefined | null): string {
  if (v === undefined || v === null) return "—";
  const n = typeof v === "number" ? v : Number(v);
  if (!Number.isFinite(n)) return gold(v);
  const abs = Math.abs(n);
  if (abs >= 1e9) return (n / 1e9).toFixed(abs >= 1e10 ? 0 : 1) + "b";
  if (abs >= 1e6) return (n / 1e6).toFixed(abs >= 1e7 ? 0 : 1) + "m";
  if (abs >= 1e4) return (n / 1e3).toFixed(0) + "k";
  return gold(Math.trunc(n));
}

export function num(v: number | undefined | null): string {
  if (v === undefined || v === null) return "—";
  return gold(Math.trunc(v));
}

/** Basis points as the percentage an operator actually thinks in. */
export function bp(v: number): string {
  const pct = v / 100;
  const sign = v > 0 ? "+" : "";
  return `${sign}${Number.isInteger(pct) ? pct : pct.toFixed(2)}%`;
}

/** A duration in seconds, at the resolution a human cares about. */
export function duration(s: number): string {
  if (!Number.isFinite(s) || s < 0) return "—";
  if (s < 60) return `${Math.floor(s)}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${Math.floor(s % 60)}s`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ${m % 60}m`;
  return `${Math.floor(h / 24)}d ${h % 24}h`;
}

/** "just now", "40s ago", "6m ago". */
export function ago(seconds: number): string {
  if (!Number.isFinite(seconds)) return "—";
  if (seconds < 3) return "just now";
  return duration(seconds) + " ago";
}

export function shortDate(iso: string | null | undefined): string {
  if (!iso) return "—";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toISOString().slice(0, 16).replace("T", " ");
}
