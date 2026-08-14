import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { cookies } from "next/headers";

type CookieRow = { name: string; value: string; options: CookieOptions };

export function supabaseServer() {
  const store = cookies();
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      // Same reason as lib/db.ts: Next.js caches GET responses made through the
      // global fetch, and supabase-js reads through it. /api/download decides
      // access from a profiles row read with this client, so a cached row would
      // keep serving builds to someone whose access had already been taken away.
      global: {
        fetch: (input: RequestInfo | URL, init?: RequestInit) =>
          fetch(input, { ...init, cache: "no-store" }),
      },
      cookies: {
        getAll: () => store.getAll(),
        setAll: (all: CookieRow[]) => {
          try {
            all.forEach(({ name, value, options }) => store.set(name, value, options));
          } catch {
            // Server Components cannot set cookies; middleware handles refresh.
          }
        },
      },
    }
  );
}
