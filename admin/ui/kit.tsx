"use client";

import { useSlice, useStore } from "@/store/react";
import s from "./kit.module.css";

/* ----------------------------------------------------------------- button --- */

type ButtonProps = React.ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: "primary" | "ghost" | "quiet" | "danger";
  size?: "sm" | "md";
  busy?: boolean;
};

export function Button({ variant = "ghost", size = "md", busy, className, ...rest }: ButtonProps) {
  const cls = [
    s.button,
    s[variant],
    size === "sm" ? s.small : "",
    busy ? s.busy : "",
    className ?? "",
  ].filter(Boolean).join(" ");
  return <button type="button" {...rest} className={cls} disabled={rest.disabled || busy} />;
}

/* ------------------------------------------------------------------- pill --- */

type Tone = "neutral" | "ok" | "warn" | "bad" | "gold" | "synthetic";

const TONE: Record<Tone, string> = {
  neutral: "", ok: s.pillOk, warn: s.pillWarn, bad: s.pillBad,
  gold: s.pillGold, synthetic: s.pillSynthetic,
};

export function Pill({
  tone = "neutral", dot, hollow, children, title,
}: {
  tone?: Tone;
  /** Show a shape as well as a colour, so state does not depend on hue alone. */
  dot?: boolean;
  hollow?: boolean;
  children: React.ReactNode;
  title?: string;
}) {
  return (
    <span className={`${s.pill} ${TONE[tone]}`} title={title}>
      {dot && <i className={`${s.dot} ${hollow ? s.dotHollow : ""}`} />}
      {children}
    </span>
  );
}

/* ------------------------------------------------------------------ panel --- */

export function Panel({
  title, actions, flush, children,
}: {
  title?: React.ReactNode;
  actions?: React.ReactNode;
  flush?: boolean;
  children: React.ReactNode;
}) {
  return (
    <section className={s.panel}>
      {(title || actions) && (
        <header className={s.panelHead}>
          <h2 className={s.panelTitle}>{title}</h2>
          {actions}
        </header>
      )}
      <div className={flush ? s.panelFlush : s.panelBody}>{children}</div>
    </section>
  );
}

/* ------------------------------------------------------------------- stat --- */

export function Stats({ children }: { children: React.ReactNode }) {
  return <div className={s.stats}>{children}</div>;
}

export function Stat({
  label, value, sub, muted, title,
}: {
  label: string;
  value: React.ReactNode;
  sub?: React.ReactNode;
  muted?: boolean;
  title?: string;
}) {
  return (
    <div className={`${s.stat} ${muted ? s.statMuted : ""}`} title={title}>
      <div className={s.statKey}>{label}</div>
      <div className={s.statValue}>{value}</div>
      {sub != null && <div className={s.statSub}>{sub}</div>}
    </div>
  );
}

/* ------------------------------------------------------------------ field --- */

export function Field({
  label, hint, error, children,
}: {
  label: string;
  hint?: React.ReactNode;
  error?: string | null;
  children: React.ReactNode;
}) {
  return (
    <label className={s.field}>
      <span className={s.label}>{label}</span>
      {children}
      {/* The outcome sits next to the control that produced it. A page-level
          banner makes an operator hunt for what happened to the row they just
          touched. */}
      {error ? <span className={s.error}>{error}</span> : hint ? <span className={s.hint}>{hint}</span> : null}
    </label>
  );
}

/* --------------------------------------------------------------- feedback --- */

export function Skeleton({ w = "100%", h = 14 }: { w?: string | number; h?: number }) {
  return <div className={s.skeleton} style={{ width: w, height: h }} />;
}

export function EmptyState({ title, children }: { title: string; children?: React.ReactNode }) {
  return (
    <div className={s.empty}>
      <div className={s.emptyTitle}>{title}</div>
      {children}
    </div>
  );
}

export function Toasts() {
  const toasts = useSlice("toasts");
  const store = useStore();
  if (toasts.length === 0) return null;
  return (
    <div className={s.toasts} role="status" aria-live="polite">
      {toasts.map((t) => (
        <div key={t.id} className={`${s.toast} ${t.tone === "ok" ? s.toastOk : s.toastErr}`}>
          <div className={s.toastText}>
            <div>{t.text}</div>
            {t.detail && <div className={s.toastDetail}>{t.detail}</div>}
          </div>
          <Button variant="quiet" size="sm" onClick={() => store.dismiss(t.id)} aria-label="Dismiss">
            ✕
          </Button>
        </div>
      ))}
    </div>
  );
}
