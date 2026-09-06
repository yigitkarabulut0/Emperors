"use client";

import Link from "next/link";
import { useSelectedLayoutSegment } from "next/navigation";
import { useSlice, useSocket, useNowTick } from "@/store/react";
import { num } from "@/lib/format";
import { Button, Toasts } from "./kit";
import s from "./shell.module.css";

const NAV = [
  { seg: null, href: "/", icon: "◉", label: "Live" },
  { seg: "players", href: "/players", icon: "⚔", label: "Players" },
  { seg: "events", href: "/events", icon: "✦", label: "Events" },
  { seg: "economy", href: "/economy", icon: "⚖", label: "Economy" },
  { seg: "audit", href: "/audit", icon: "⌗", label: "Audit" },
  { seg: "balance", href: "/balance", icon: "⚙", label: "Balance" },
];

function Connection() {
  const c = useSlice("connection");
  const socket = useSocket();
  const now = useNowTick();

  if (c.state === "live") {
    return (
      <span className={`${s.conn} ${s.connLive}`} title={`frame ${c.seq}`}>
        <i className={s.connDot} /> live
      </span>
    );
  }
  if (c.state === "offline") {
    return (
      <span className={`${s.conn} ${s.connDead}`} title={c.error ?? ""}>
        <i className={s.connDot} /> offline
        <Button variant="quiet" size="sm" onClick={() => socket?.reconnect()}>
          reconnect
        </Button>
      </span>
    );
  }
  const inSec = c.nextRetryAt ? Math.max(0, Math.round((c.nextRetryAt - now) / 1000)) : null;
  return (
    <span className={`${s.conn} ${s.connWait}`} title={c.error ?? ""}>
      <i className={s.connDot} />
      {c.state === "connecting" ? "connecting" : inSec !== null ? `reconnecting ${inSec}s` : "reconnecting"}
    </span>
  );
}

function Counters() {
  const board = useSlice("board");
  const c = useSlice("connection");
  // Stale means "shown, but I am not currently being told about changes".
  // Offline means I have no honest value at all, so it shows a dash rather than
  // a number that was true a while ago.
  const stale = c.state !== "live";
  const dead = c.state === "offline";
  const v = (n: number | undefined) => (dead ? "—" : num(n ?? 0));

  return (
    <div className={s.counters} data-stale={stale}>
      <div className={s.counter}>
        <span className={s.counterValue}>{v(board?.count_playing)}</span>
        <span className={s.counterLabel}>in game</span>
      </div>
      <div className={`${s.counter} ${s.counterMuted}`}>
        <span className={s.counterValue}>{v(board?.count_idle)}</span>
        <span className={s.counterLabel}>idle</span>
      </div>
      <div className={`${s.counter} ${s.counterMuted}`}>
        <span className={s.counterValue}>{v(board?.offline)}</span>
        <span className={s.counterLabel}>out</span>
      </div>
      <div className={`${s.counter} ${s.counterMuted}`}>
        <span className={s.counterValue}>{v(board?.registered)}</span>
        <span className={s.counterLabel}>registered</span>
      </div>
    </div>
  );
}

export function AppShell({
  me, env, children,
}: {
  me: { username: string; role: string } | null;
  env: string;
  children: React.ReactNode;
}) {
  const segment = useSelectedLayoutSegment();
  const conn = useSlice("connection");
  const board = useSlice("board");
  const now = useNowTick();

  async function signOut() {
    await fetch("/api/session", { method: "DELETE" });
    location.href = "/login";
  }

  return (
    <div className={s.shell}>
      <header className={s.top}>
        <div className={s.brand}>
          <span className={s.brandMark}>⚜</span> Emperors
        </div>
        <span className={s.env}>{env}</span>
        <Counters />
        <Connection />
        <span className={s.who}>
          <span className={s.whoName}>{me?.username ?? "—"}</span>
          {me?.role ? ` · ${me.role}` : ""}
        </span>
        <Button variant="quiet" size="sm" onClick={signOut}>sign out</Button>
      </header>
      {conn.state === "reconnecting" && <div className={s.strip} />}

      <nav className={s.rail} aria-label="Sections">
        {NAV.map((n) => (
          <Link
            key={n.href}
            href={n.href}
            className={s.railLink}
            data-active={segment === n.seg}
          >
            <span className={s.railIcon} aria-hidden>{n.icon}</span>
            <span className={s.railLabel}>{n.label}</span>
          </Link>
        ))}
        <div className={s.railSpacer} />
      </nav>

      <main className={s.main}>{children}</main>

      <footer className={s.foot}>
        <span className={s.footItem}>frame {conn.seq}</span>
        <span className={s.footItem}>
          {board?.reconciling
            ? "reconciling after a restart"
            : board
              ? `board as of ${new Date(board.at).toISOString().slice(11, 19)}Z`
              : "no board yet"}
        </span>
        <span className={s.footGrow} />
        <span className={s.footItem}>{new Date(now).toISOString().slice(11, 19)} UTC</span>
      </footer>

      <Toasts />
    </div>
  );
}
