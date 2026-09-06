"use client";

/**
 * The pieces that make a write happen without a page reload.
 *
 * These import only ./actions (an encrypted action id after compilation) and
 * plain types. They never import lib/api, which pulls in next/headers and would
 * fail the build inside a client graph -- that is the mechanism keeping the
 * admin token on the server, rather than a rule anyone has to remember.
 */

import { useState, useTransition, type ReactNode } from "react";

export type Result = { ok: boolean; message: string };

/**
 * A form whose submit runs a server action and shows the outcome beside itself.
 *
 * useTransition rather than a plain await: `busy` is true for the whole
 * round trip, so the button can say so and cannot be double-submitted -- which
 * on a currency grant is the difference between +1000 and +2000.
 */
export function ActionForm({
  run, children, submit = "Apply", danger = false, confirm, onDone,
}: {
  run: (fd: FormData) => Promise<Result>;
  children: ReactNode;
  submit?: string;
  danger?: boolean;
  confirm?: string;
  onDone?: (r: Result) => void;
}) {
  const [busy, start] = useTransition();
  const [note, setNote] = useState<Result | null>(null);

  return (
    <form
      className="row wrap"
      style={{ gap: 8 }}
      onSubmit={(e) => {
        e.preventDefault();
        // Native form data, so the markup stays plain inputs with names and
        // there is no controlled-state bookkeeping for a dozen fields.
        const fd = new FormData(e.currentTarget);
        if (confirm && !window.confirm(confirm)) return;
        const form = e.currentTarget;
        start(async () => {
          const r = await run(fd);
          setNote(r);
          onDone?.(r);
          // Only a success clears the inputs. A refusal must leave what was
          // typed exactly where it was, so it can be corrected rather than
          // retyped from memory.
          if (r.ok) form.reset();
        });
      }}
    >
      {children}
      <button type="submit" className={danger ? "danger" : undefined} disabled={busy}>
        {busy ? "Working…" : submit}
      </button>
      {note ? <span className={`note ${note.ok ? "ok" : "err"}`}>{note.message}</span> : null}
    </form>
  );
}

/** A single button that runs an action, for things with nothing to fill in. */
export function ActionButton({
  run, label, danger = false, confirm, onDone,
}: {
  run: () => Promise<Result>;
  label: string;
  danger?: boolean;
  confirm?: string;
  onDone?: (r: Result) => void;
}) {
  const [busy, start] = useTransition();
  const [note, setNote] = useState<Result | null>(null);
  return (
    <span className="row" style={{ gap: 8 }}>
      <button
        className={danger ? "danger" : "ghost"}
        disabled={busy}
        onClick={() => {
          if (confirm && !window.confirm(confirm)) return;
          start(async () => {
            const r = await run();
            setNote(r);
            onDone?.(r);
          });
        }}
      >
        {busy ? "…" : label}
      </button>
      {note ? <span className={`note ${note.ok ? "ok" : "err"}`}>{note.message}</span> : null}
    </span>
  );
}
