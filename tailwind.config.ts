import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        // Warm Nesso palette, drawn from the app icon (#D0A098 clay rose).
        paper: "#FBF6F3",
        card: "#FFFFFF",
        line: "rgba(58,38,32,0.10)",
        muted: "#8A736C",
        ink: "#2B211D",
        rose: "#D0A098",
        rosedeep: "#B47D72",
      },
      fontFamily: {
        display: ["var(--font-display)", "Georgia", "serif"],
        body: ["var(--font-body)", "system-ui", "sans-serif"],
      },
      boxShadow: {
        pill: "0 24px 60px -20px rgba(80,45,35,0.28), 0 0 0 1px rgba(58,38,32,0.06)",
        glow: "0 20px 60px -18px rgba(180,125,114,0.55)",
      },
    },
  },
  plugins: [],
};
export default config;
