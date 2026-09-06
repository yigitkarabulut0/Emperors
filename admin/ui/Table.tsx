"use client";

import s from "./table.module.css";

export function TableWrap({ children }: { children: React.ReactNode }) {
  return <div className={s.wrap}>{children}</div>;
}

export function Table({ children }: { children: React.ReactNode }) {
  return <table className={s.table}>{children}</table>;
}

export const num = s.num;
export const changed = s.changed;
export const changedUp = s.changedUp;
export const changedDown = s.changedDown;
