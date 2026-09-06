import { Suspense } from "react";
import { BrowseTable } from "@/features/players/BrowseTable";

export default function PlayersPage() {
  // useSearchParams needs a Suspense boundary above it, or the whole route opts
  // out of static rendering with a build-time warning.
  return (
    <Suspense fallback={null}>
      <BrowseTable />
    </Suspense>
  );
}
