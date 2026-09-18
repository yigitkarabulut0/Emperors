import { Suspense } from "react";
import { MailView } from "@/features/mail/MailView";

export default function MailPage() {
  // The composer reads ?player= (the player page's "send a letter"), and
  // useSearchParams needs a Suspense boundary above it.
  return (
    <Suspense fallback={null}>
      <MailView />
    </Suspense>
  );
}
