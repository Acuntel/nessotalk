import { NextResponse } from "next/server";

// Stripe-ready checkout stub. When STRIPE_SECRET_KEY + price ids land in env,
// swap the 503 for a real Checkout Session create. Until then the dashboard
// shows the founding-price-locked message and the trial keeps running.
export async function POST() {
  if (!process.env.STRIPE_SECRET_KEY) {
    return NextResponse.json({ error: "billing_not_live" }, { status: 503 });
  }
  return NextResponse.json({ error: "billing_not_configured" }, { status: 503 });
}
