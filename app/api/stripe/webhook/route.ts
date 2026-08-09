import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { createHmac, timingSafeEqual } from "crypto";

// Stripe webhook: this is what makes give/take-away AUTOMATIC with money.
// Payment completes -> the account flips to Pro with no human involved.
// Subscription cancels -> the account drops back to trial, and since the 14
// free days are long gone by then, access ends on the next license check.
//
// Signature is verified manually (HMAC-SHA256 over `${t}.${body}` against
// the v1 value in the Stripe-Signature header) so we do not need the stripe
// SDK as a dependency. Inert (503) until STRIPE_WEBHOOK_SECRET is set:
// Stripe dashboard -> Developers -> Webhooks -> Add endpoint
// https://nesso.tech/api/stripe/webhook with events
// checkout.session.completed + customer.subscription.deleted, then
// `npx vercel env add STRIPE_WEBHOOK_SECRET production` with the whsec_ value.
export const dynamic = "force-dynamic";

function verified(body: string, header: string, secret: string): boolean {
  const parts = new Map(
    header.split(",").map((p) => {
      const [k, ...v] = p.split("=");
      return [k.trim(), v.join("=")] as const;
    })
  );
  const t = parts.get("t") ?? "";
  const v1 = parts.get("v1") ?? "";
  if (!t || !v1) return false;
  if (Math.abs(Date.now() / 1000 - Number(t)) > 300) return false;
  const expect = createHmac("sha256", secret).update(`${t}.${body}`).digest("hex");
  const a = Buffer.from(expect);
  const b = Buffer.from(v1);
  return a.length === b.length && timingSafeEqual(a, b);
}

export async function POST(req: Request) {
  const secret = process.env.STRIPE_WEBHOOK_SECRET;
  if (!secret) return NextResponse.json({ error: "webhook_unconfigured" }, { status: 503 });

  const body = await req.text();
  const sig = req.headers.get("stripe-signature") ?? "";
  if (!verified(body, sig, secret)) {
    return NextResponse.json({ error: "bad_signature" }, { status: 400 });
  }

  let event: { type?: string; data?: { object?: Record<string, unknown> } };
  try {
    event = JSON.parse(body);
  } catch {
    return NextResponse.json({ error: "bad_json" }, { status: 400 });
  }
  const obj = event.data?.object ?? {};

  const db = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false } }
  );

  if (event.type === "checkout.session.completed") {
    // client_reference_id carries the Supabase user id (the Payment Link is
    // opened with it prefilled from the dashboard).
    const userId = String(obj.client_reference_id ?? "");
    const customer = String(obj.customer ?? "");
    if (userId) {
      await db
        .from("profiles")
        .update({ plan: "pro", revoked: false, stripe_customer_id: customer || null })
        .eq("id", userId);
    }
  }

  if (event.type === "customer.subscription.deleted") {
    const customer = String(obj.customer ?? "");
    if (customer) {
      await db.from("profiles").update({ plan: "trial" }).eq("stripe_customer_id", customer);
    }
  }

  // Everything else (payment_failed retries etc.) is acknowledged and left
  // to Stripe's own retry machinery; the deletion event is the final word.
  return NextResponse.json({ received: true });
}
