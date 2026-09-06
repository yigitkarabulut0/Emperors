import { callAdmin } from "@/lib/api";
import { EventsClient, type Boost, type Bucket } from "./EventsClient";

export default async function EventsPage() {
  const res = await callAdmin<{ boosts: Boost[]; buckets: Bucket[] }>("/boosts");
  return (
    <>
      <h1>Events</h1>
      <p className="muted">
        Server-wide, time-boxed changes to what everyone earns and rolls.
      </p>
      {!res.ok ? <p className="err">{res.message}</p>
               : <EventsClient boosts={res.data.boosts} buckets={res.data.buckets} />}
    </>
  );
}
