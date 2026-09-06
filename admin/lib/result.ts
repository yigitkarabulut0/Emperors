/**
 * Every call in this app returns one of these. Nothing throws.
 *
 * The discriminated union was the one genuinely good idea in the panel this
 * replaced: an operator granting currency should never see a stack trace or a
 * blank page because a fetch rejected. A failure is a value with a status and a
 * sentence, and it renders next to the control that produced it.
 */
export type Result<T> =
  | { ok: true; data: T }
  | { ok: false; status: number; code: string; message: string };

export function fail(status: number, code: string, message: string): Result<never> {
  return { ok: false, status, code, message };
}
