import type { Metadata } from "next";
import { Fraunces, Inter } from "next/font/google";
import "./globals.css";

const display = Fraunces({
  subsets: ["latin"],
  variable: "--font-display",
  weight: ["400", "500", "600"],
});
const body = Inter({ subsets: ["latin"], variable: "--font-body" });

export const metadata: Metadata = {
  title: "NessoTalk: talk instead of type, on your Mac",
  description:
    "NessoTalk turns your voice into clean, polished text in any app on your Mac. It runs on our own speech engine, with five rewrite modes, at a third of the price of the big-name tools. 14 days free, no card.",
  openGraph: {
    title: "NessoTalk",
    description:
      "Voice dictation for Mac on NessoTalk's own speech engine. Speak anywhere, paste clean text in seconds. 14 days free, no card.",
    url: "https://nesso.tech",
    siteName: "NessoTalk",
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${display.variable} ${body.variable}`}>
      <body className="bg-paper text-ink font-body antialiased">{children}</body>
    </html>
  );
}
