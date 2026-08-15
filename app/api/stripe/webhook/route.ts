import { NextResponse } from "next/server";
import { adminDb } from "@/lib/db";
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

  let event: { id?: string; type?: string; data?: { object?: Record<string, unknown> } };
  try {
    event = JSON.parse(body);
  } catch {
    return NextResponse.json({ error: "bad_json" }, { status: 400 });
  }
  const obj = event.data?.object ?? {};

  const db = adminDb();

  // Idempotency. Stripe retries on any non-2xx and will happily deliver the
  // same event several times, out of order, for up to three days. Without this,
  // a replayed `invoice.paid` arriving after a cancellation would resurrect a
  // subscription that had already ended.
  //
  // Claiming the id BEFORE doing the work is the whole trick: the primary key
  // makes the insert fail for anyone who is second, so exactly one delivery can
  // proceed. Returning 200 on the duplicate is deliberate, because a non-2xx
  // would make Stripe retry the thing we just told it we already handled.
  const eventId = String(event.id ?? "");
  if (eventId) {
    const { error } = await db
      .from("processed_events")
      .insert({ event_id: eventId, event_type: event.type ?? null });
    if (error) return NextResponse.json({ received: true, duplicate: true });
  }

  const customer = String(obj.customer ?? "");

  // Access follows money, automatically and in both directions:
  //   pay -> pro. payment fails or subscription lapses -> back to trial,
  //   and since the 14 free days are long gone, that means the very next
  //   license check refuses and the engine 402s. A recovered payment brings
  //   them straight back. Brady's rule, verbatim: auto-remove anyone whose
  //   payment does not go through.
  const CUT = new Set(["customer.subscription.deleted", "invoice.payment_failed"]);
  const RESTORE = new Set(["invoice.paid", "invoice.payment_succeeded"]);

  if (event.type === "checkout.session.completed") {
    // client_reference_id carries the Supabase user id (the Payment Link is
    // opened with it prefilled from the dashboard).
    const userId = String(obj.client_reference_id ?? "");
    if (userId) {
      await db
        .from("profiles")
        .update({ plan: "pro", revoked: false, stripe_customer_id: customer || null })
        .eq("id", userId);
    }
  } else if (event.type === "customer.subscription.updated") {
    // Covers the in-between states without waiting for deletion: past_due /
    // unpaid cut immediately, a subscription going active restores.
    const status = String(obj.status ?? "");
    if (customer && ["past_due", "unpaid", "canceled", "incomplete_expired"].includes(status)) {
      await db.from("profiles").update({ plan: "trial" }).eq("stripe_customer_id", customer);
    } else if (customer && status === "active") {
      await db.from("profiles").update({ plan: "pro" }).eq("stripe_customer_id", customer);
    }
  } else if (CUT.has(event.type ?? "") && customer) {
    await db.from("profiles").update({ plan: "trial" }).eq("stripe_customer_id", customer);
  } else if (RESTORE.has(event.type ?? "") && customer) {
    await db.from("profiles").update({ plan: "pro" }).eq("stripe_customer_id", customer);
  }

  return NextResponse.json({ received: true });
}
