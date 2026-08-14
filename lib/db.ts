import { createClient } from "@supabase/supabase-js";

// Service-role Supabase client for the routes that decide access.
//
// The `fetch` override is the whole point of this file. Next.js patches the
// global fetch and caches GET responses in its Data Cache, and supabase-js
// issues its reads through that same global fetch. The result was a route that
// read a STALE profiles row: the database said revoked = true, the direct REST
// query said revoked = true, and /api/update kept reading revoked = false and
// serving builds to a revoked customer. `dynamic = "force-dynamic"` does not
// cover this, because it governs the route's own rendering rather than the
// fetches the route makes.
//
// Access checks must never be served from a cache. Revoking someone is the one
// lever this product is built on, so every read behind it is no-store.
export function adminDb() {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    {
      auth: { persistSession: false },
      global: {
        fetch: (input: RequestInfo | URL, init?: RequestInit) =>
          fetch(input, { ...init, cache: "no-store" }),
      },
    }
  );
}
