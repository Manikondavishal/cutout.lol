// Creates a Razorpay order for a ticket pack. Secrets: RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
const PACKS: Record<string, { price: number; tickets: number }> = {
  p5: { price: 49, tickets: 5 }, p12: { price: 99, tickets: 12 }, p30: { price: 199, tickets: 30 }, p80: { price: 499, tickets: 80 },
};
const DAILY_CAP = 499; // rupees per fan per day
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = Deno.env.get("SUPABASE_URL")!, service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const keyId = Deno.env.get("RAZORPAY_KEY_ID"), keySecret = Deno.env.get("RAZORPAY_KEY_SECRET");
  if (!keyId || !keySecret) return json({ error: "Payments are being switched on" }, 503);
  const admin = createClient(url, service);
  const { data: { user } } = await admin.auth.getUser((req.headers.get("Authorization") || "").replace("Bearer ", ""));
  if (!user || user.is_anonymous) return json({ error: "Sign in with Google to buy tickets" }, 401);
  const { pack } = await req.json().catch(() => ({}));
  const p = PACKS[pack]; if (!p) return json({ error: "Unknown pack" }, 400);
  const since = new Date(Date.now() - 24 * 3600e3).toISOString();
  const { data: today } = await admin.from("purchases").select("amount_paise").eq("user_id", user.id).eq("status", "paid").gte("created_at", since);
  const spent = (today || []).reduce((a, r) => a + r.amount_paise, 0) / 100;
  if (spent + p.price > DAILY_CAP) return json({ error: `Daily limit is ₹${DAILY_CAP}. Back tomorrow.` }, 429);
  const rz = await fetch("https://api.razorpay.com/v1/orders", {
    method: "POST", headers: { "Content-Type": "application/json", Authorization: "Basic " + btoa(`${keyId}:${keySecret}`) },
    body: JSON.stringify({ amount: p.price * 100, currency: "INR", receipt: `${user.id.slice(0, 8)}-${Date.now()}`, notes: { pack, user: user.id } }),
  }).then((r) => r.json());
  if (!rz.id) return json({ error: "Couldn't start payment" }, 502);
  await admin.from("purchases").insert({ user_id: user.id, order_id: rz.id, pack, amount_paise: p.price * 100, tickets: p.tickets });
  return json({ order_id: rz.id, amount: rz.amount, key_id: keyId });
});
