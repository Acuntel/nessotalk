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
    "NessoTalk turns your voice into clean, polished text in any Mac app. Transcription runs on your machine, your words stay yours, and it costs a third of the big-name tools. 14 days free.",
  openGraph: {
    title: "NessoTalk",
    description:
      "Local-first voice dictation for Mac. Speak anywhere, paste clean text in seconds. 14 days free, no card.",
    url: "https://nessotalk.vercel.app",
    siteName: "NessoTalk",
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${display.variable} ${body.variable}`}>
      <body className="bg-ink text-cream font-body antialiased">{children}</body>
    </html>
  );
}
