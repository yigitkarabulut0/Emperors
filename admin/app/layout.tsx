import "./globals.css";
import type { ReactNode } from "react";

export const metadata = {
  title: "Emperors — Live Ops",
  description: "Moderation and balance for Emperors",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
