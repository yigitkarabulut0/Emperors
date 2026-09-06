import "server-only";
import { cookies } from "next/headers";

/**
 * The panel's own cookie, on the panel's own origin.
 *
 * Deliberately a different name from the `emperors_admin` cookie the Go server
 * sets. Cookies are port-blind, so a panel on localhost:3000 and the API on
 * localhost:8081 share one jar for the host "localhost"; one name would have
 * them overwrite each other during local development.
 */
export const SESSION_COOKIE = "emperors_admin_session";

/** Eight hours, matching the session the Go server issues. */
export const SESSION_MAX_AGE = 8 * 60 * 60;

export async function readSession(): Promise<string | undefined> {
  return (await cookies()).get(SESSION_COOKIE)?.value;
}

export async function writeSession(token: string): Promise<void> {
  (await cookies()).set(SESSION_COOKIE, token, {
    httpOnly: true,
    sameSite: "lax",
    path: "/",
    maxAge: SESSION_MAX_AGE,
    // Only over TLS in production. Its absence was a real defect in the panel
    // this replaces.
    secure: process.env.NODE_ENV === "production",
  });
}

export async function clearSession(): Promise<void> {
  (await cookies()).delete(SESSION_COOKIE);
}
