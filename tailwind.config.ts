import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        ink: "#07070B",
        panel: "#0E0E15",
        edge: "rgba(255,255,255,0.08)",
        mist: "#9B9BAD",
        cream: "#F4F2EC",
        volt: "#7C5CFF",
        voltdim: "#6247D9",
      },
      fontFamily: {
        display: ["var(--font-display)", "Georgia", "serif"],
        body: ["var(--font-body)", "system-ui", "sans-serif"],
      },
      boxShadow: {
        pill: "0 24px 80px -16px rgba(0,0,0,0.8), 0 0 0 1px rgba(255,255,255,0.06)",
        glow: "0 0 120px 20px rgba(124,92,255,0.18)",
      },
    },
  },
  plugins: [],
};
export default config;
