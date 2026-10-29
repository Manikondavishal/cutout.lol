// Verifies Razorpay's signature and credits the tickets. Secret: RAZORPAY_KEY_SECRET
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

async function hmac(secret: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const { order_id, payment_id, signature } = await req.json().catch(() => ({}));
  if (!order_id || !payment_id || !signature) return json({ ok: false }, 400);
  const expected = await hmac(Deno.env.get("RAZORPAY_KEY_SECRET")!, `${order_id}|${payment_id}`);
  if (expected !== signature) return json({ ok: false, error: "bad signature" }, 400);
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data, error } = await admin.rpc("credit_purchase", { p_order: order_id, p_payment: payment_id });
  if (error) return json({ ok: false, error: error.message }, 500);
  return json(data);
});
