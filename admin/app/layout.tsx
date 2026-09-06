import type { Metadata } from "next";
import "./globals/layers.css";
import "./globals/tokens.css";
import "./globals/reset.css";
import "./globals/base.css";
import "./globals/utilities.css";

export const metadata: Metadata = {
  title: "Emperors — live ops",
  description: "Who is in the game, and everything you can do about it.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
