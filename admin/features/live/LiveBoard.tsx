"use client";

import Link from "next/link";
import { useSlice, useNowTick } from "@/store/react";
import { Panel, Pill, Stat, Stats, EmptyState, Skeleton } from "@/ui/kit";
import { gold, num, duration, ago } from "@/lib/format";
import type { LiveRow } from "@/lib/protocol";
import s from "./live.module.css";

function Row({ r, fresh }: { r: LiveRow; fresh: boolean }) {
  const playing = r.presence === "playing";
  return (
    <Link
      href={`/players/${r.id}`}
      className={`${s.row} ${fresh ? s.rowNew : ""}`}
      style={{ color: playing ? "var(--up)" : "var(--warn)" }}
    >
      <i
        className={`${s.dot} ${playing ? s.dotPlaying : s.dotIdle} ${r.inferred ? s.dotInferred : ""}`}
        title={
          r.inferred
            ? "Inferred from this player's actions — their build predates the heartbeat, so silence does not mean they left"
            : "Confirmed by heartbeat — the app is open"
        }
      />
      <span className={s.name} style={{ color: "var(--text)" }}>
        <span className={s.nameMain}>{r.name || r.username}</span>
        <span className={s.nameSub}>@{r.username}</span>
      </span>
      <span className={s.n} style={{ color: "var(--text-2)" }}>{r.level}</span>
      <span className={s.n} style={{ color: "var(--gold-3)" }} title={r.gold}>{gold(r.gold)}</span>
      <span className={s.n} style={{ color: "var(--text-2)" }}>{r.diamonds}</span>
      <span className={s.n} style={{ color: "var(--text-2)" }} title={`since ${r.since}`}>
        {duration(r.seconds_in)}
      </span>
      <span className={s.n} style={{ color: "var(--text-3)" }}>{ago(r.seconds_ago)}</span>
    </Link>
  );
}

function Header() {
  return (
    <div className={s.head}>
      <span />
      <span>player</span>
      <span className={s.n}>lvl</span>
      <span className={s.n}>gold</span>
      <span className={s.n}>gems</span>
      <span className={s.n}>in for</span>
      <span className={s.n}>last seen</span>
    </div>
  );
}

export function LiveBoard() {
  const board = useSlice("board");
  const conn = useSlice("connection");
  const flash = useSlice("flash");
  const now = useNowTick();

  if (!board) {
    return (
      <div className={s.grid}>
        <Stats>
          {[0, 1, 2, 3].map((i) => (
            <div key={i} style={{ padding: "var(--s5)" }}><Skeleton h={40} /></div>
          ))}
        </Stats>
        <Panel title="Who is in the game"><Skeleton h={160} /></Panel>
      </div>
    );
  }

  const inferred = [...board.playing, ...board.idle].filter((r) => r.inferred).length;
  const isFresh = (id: string) => {
    const f = flash.get("join:" + id);
    return !!f && now - f.at < 10_000;
  };

  return (
    <div className={s.grid}>
      <Stats>
        <Stat
          label="In game now"
          value={num(board.count_playing)}
          sub={board.count_playing === 1 ? "one player" : "acting or heartbeating"}
        />
        <Stat label="Idle" value={num(board.count_idle)} sub="here recently, gone quiet" muted />
        <Stat label="Not in game" value={num(board.offline)} sub="of the registered roster" muted />
        <Stat label="Registered" value={num(board.registered)} sub="accounts, excluding bots" muted />
      </Stats>

      <Panel
        title="Who is in the game"
        flush
        actions={
          <span className="u-row">
            {board.reconciling && (
              <Pill tone="warn" dot>reconciling</Pill>
            )}
            {conn.state === "live" ? (
              <Pill tone="ok" dot>updating live</Pill>
            ) : (
              <Pill tone="warn" dot hollow>not updating</Pill>
            )}
          </span>
        }
      >
        {board.reconciling && (
          <div className={s.notice}>
            The server restarted less than two minutes ago. This board was seeded from when
            players were last seen and is still confirming who is really here.
          </div>
        )}
        {inferred > 0 && (
          <div className={s.notice}>
            {inferred} of these {inferred === 1 ? "player is" : "players are"} shown with a hollow
            dot: their build predates the heartbeat, so presence is inferred from what they do.
            Silence does not mean they left.
          </div>
        )}
        {board.playing.length === 0 ? (
          <EmptyState title="Nobody is in the game right now">
            <span className="u-faint">
              Open the game on your phone and you will appear here within a second.
            </span>
          </EmptyState>
        ) : (
          <>
            <Header />
            <div className={s.rows}>
              {board.playing.map((r) => (
                <Row key={r.id} r={r} fresh={isFresh(r.id)} />
              ))}
            </div>
          </>
        )}
      </Panel>

      {board.idle.length > 0 && (
        <Panel title="Gone quiet" flush actions={<span className={s.count}>{board.idle.length}</span>}>
          <Header />
          <div className={s.rows}>
            {board.idle.map((r) => (
              <Row key={r.id} r={r} fresh={false} />
            ))}
          </div>
        </Panel>
      )}
    </div>
  );
}
