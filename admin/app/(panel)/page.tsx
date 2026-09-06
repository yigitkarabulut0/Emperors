import { LiveBoard } from "@/features/live/LiveBoard";

/**
 * The landing page is the live board, not a stats dashboard.
 *
 * It renders entirely from the store, which the websocket fills the moment the
 * socket opens with its hello snapshot — so there is no server fetch here to
 * duplicate and then immediately contradict.
 */
export default function LivePage() {
  return <LiveBoard />;
}
