// SPOTOUT — Stripe Webhook
//
// WICHTIG: Diese Funktion MUSS mit verify_jwt = false laufen.
// Stripe schickt keinen Supabase-JWT, sondern signiert den Rumpf mit
// STRIPE_WEBHOOK_SECRET. Steht verify_jwt auf true, weist Supabase jede
// Zustellung mit 401 ab, bevor auch nur eine Zeile hier ausgefuehrt wird
// — und Zahlungen laufen ins Leere. (Genau das ist am 17.09.2026 bei
// einem Deploy passiert, der den Schalter still zuruecksetzte.)
// Die Echtheitspruefung passiert weiter unten in verifyStripeSignature().
//
// Einzige Stelle, an der Pro vergeben oder entzogen wird, und die einzige
// Stelle, an der eine bezahlte Party freigeschaltet wird. Der Client kann
// beides nicht selbst (Trigger guard_pro_columns bzw. guard_event_fee_columns).
//
// Erwartete Secrets (Supabase → Edge Function Secrets):
//   STRIPE_SECRET_KEY      sk_live_… oder rk_live_… (Subscriptions lesen,
//                          Checkout Sessions schreiben für die Party-Gebühr)
//   STRIPE_WEBHOOK_SECRET  whsec_…  (aus dem Stripe-Event-Ziel)
// SUPABASE_URL und SUPABASE_SERVICE_ROLE_KEY setzt Supabase automatisch.
//
// GET auf diese URL liefert einen Health-Check: ob die Secrets gesetzt sind.
// Nur ja/nein — keine Länge, kein Format, kein Wert.
//
// ── Was am 16.09.2026 geändert wurde ───────────────────────────────────
// 1. Eine gescheiterte Verarbeitung vermerkt das Ereignis nicht mehr als
//    erledigt. Vorher wurde die Sperre gegen Doppelzustellung VOR der
//    Verarbeitung geschrieben: schlug der Handler danach fehl (500), schickte
//    Stripe erneut — und der zweite Versuch wurde als "schon erledigt"
//    abgewiesen. Eine Zahlung konnte damit still verloren gehen.
// 2. Der Health-Check verrät keine Details über die Secrets mehr.
// 3. Schlägt eine Pro-Änderung in der Datenbank fehl, antwortet die Funktion
//    mit 500 statt mit "received" — dann versucht Stripe es erneut.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const STRIPE_SECRET  = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const SB_URL         = Deno.env.get("SUPABASE_URL") ?? "";
const SB_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const sb = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } });

// ── Signaturprüfung (Web Crypto, ohne externe Abhängigkeit) ──────────────
const enc = new TextEncoder();

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function hmacHex(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(payload));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function verifyStripeSignature(body: string, header: string): Promise<string | null> {
  if (!WEBHOOK_SECRET) return "STRIPE_WEBHOOK_SECRET ist nicht gesetzt";
  if (!header) return "Header stripe-signature fehlt";
  const parts: Record<string, string> = {};
  for (const chunk of header.split(",")) {
    const [k, v] = chunk.trim().split("=");
    if (k && v) parts[k] = v;
  }
  const t = parts["t"];
  const v1 = parts["v1"];
  if (!t || !v1) return "Signatur-Header unvollständig";

  const age = Math.abs(Date.now() / 1000 - Number(t));
  if (!Number.isFinite(age) || age > 300) return `Zeitstempel zu alt (${Math.round(age)}s)`;

  const expected = await hmacHex(WEBHOOK_SECRET, `${t}.${body}`);
  if (!timingSafeEqual(expected, v1)) return "Signatur passt nicht zum Secret";
  return null;
}

// ── Stripe-API ─────────────────────────────────────────────────────
async function stripeGet(path: string): Promise<any | null> {
  if (!STRIPE_SECRET) { console.warn("[stripe] STRIPE_SECRET_KEY fehlt"); return null; }
  const r = await fetch(`https://api.stripe.com/v1/${path}`, {
    headers: { Authorization: `Bearer ${STRIPE_SECRET}` },
  });
  if (!r.ok) { console.error("[stripe]", path, r.status, await r.text()); return null; }
  return await r.json();
}

async function stripePost(path: string, form: Record<string, string>): Promise<any | null> {
  if (!STRIPE_SECRET) { console.warn("[stripe] STRIPE_SECRET_KEY fehlt"); return null; }
  const body = new URLSearchParams(form).toString();
  const r = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${STRIPE_SECRET}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body,
  });
  if (!r.ok) { console.error("[stripe:post]", path, r.status, await r.text()); return null; }
  return await r.json();
}

// Zu welchem Abo gehört diese Rechnung? Bis zur API-Fassung 2025-03-31.basil
// stand die Nummer direkt auf der Rechnung; danach steckt sie eine Ebene
// tiefer. Ohne diesen Griff hielte der Webhook jede Verlängerung für eine
// Einmalzahlung und würde sie stillschweigend übergehen.
function subIdOf(inv: any): string | null {
  const kandidaten = [
    inv?.subscription,
    inv?.parent?.subscription_details?.subscription,
    ...(Array.isArray(inv?.lines?.data)
      ? inv.lines.data.map((l: any) =>
          l?.subscription ?? l?.parent?.subscription_item_details?.subscription)
      : []),
  ];
  for (const k of kandidaten) {
    if (typeof k === "string" && k.startsWith("sub_")) return k;
    if (k && typeof k === "object" && typeof k.id === "string") return k.id;
  }
  return null;
}

// Periodenende: alt auf dem Abo, neu (ab 2025-03-31.basil) auf den Positionen
function periodEndOf(sub: any): string | null {
  if (!sub) return null;
  let end: number | null = typeof sub.current_period_end === "number" ? sub.current_period_end : null;
  const items = sub.items?.data;
  if (Array.isArray(items)) {
    for (const it of items) {
      if (typeof it?.current_period_end === "number") {
        end = end === null ? it.current_period_end : Math.max(end, it.current_period_end);
      }
    }
  }
  return end === null ? null : new Date(end * 1000).toISOString();
}

async function findUserId(opts: {
  clientReferenceId?: string | null;
  customerId?: string | null;
  email?: string | null;
}): Promise<string | null> {
  const { clientReferenceId, customerId, email } = opts;

  if (clientReferenceId && /^[0-9a-f-]{36}$/i.test(clientReferenceId)) {
    const { data } = await sb.from("profiles").select("id").eq("id", clientReferenceId).maybeSingle();
    if (data?.id) return data.id;
  }
  if (customerId) {
    const { data } = await sb.from("profiles").select("id").eq("stripe_customer_id", customerId).maybeSingle();
    if (data?.id) return data.id;
  }
  if (email) {
    const { data } = await sb.auth.admin.listUsers({ page: 1, perPage: 200 });
    const hit = data?.users?.find((u) => (u.email ?? "").toLowerCase() === email.toLowerCase());
    if (hit?.id) return hit.id;
  }
  return null;
}

// Eine Testwoche pro Konto. Wer schon einmal eine hatte und trotzdem
// wieder mit einer Probe hereinkommt, dem wird sie in Stripe sofort
// beendet – dann zahlt er ab der ersten Minute.
async function probeSchonVerbraucht(userId: string): Promise<boolean> {
  const { data } = await sb.from("profiles").select("probe_verbraucht").eq("id", userId).maybeSingle();
  return !!data?.probe_verbraucht;
}

// Wirft, wenn die Datenbank nicht mitmacht. Der Aufrufer fängt das und
// antwortet mit 500 – dann versucht Stripe es erneut, statt dass eine
// bezahlte Mitgliedschaft still verschwindet.
async function setPro(
  userId: string,
  on: boolean,
  extra: Record<string, unknown> = {},
  probe = false,
) {
  if (on && probe && await probeSchonVerbraucht(userId)) {
    const subId = String(extra["stripe_subscription_id"] ?? "");
    if (subId.startsWith("sub_")) {
      const r = await stripePost(`subscriptions/${subId}`, { trial_end: "now" });
      console.log("[probe] zweite Testwoche beendet für", userId, r ? "ok" : "fehlgeschlagen");
      if (r) probe = false;
    } else {
      probe = false;
    }
  }

  const patch: Record<string, unknown> = {
    is_pro: on,
    pro_probe: on && probe,
    subscription_status: on ? (probe ? "trialing" : "active") : "cancelled",
    pro_updated_at: new Date().toISOString(),
  };
  for (const [k, v] of Object.entries(extra)) if (v !== null && v !== undefined) patch[k] = v;

  const { error } = await sb.from("profiles").update(patch).eq("id", userId);
  if (error) {
    console.error("[profiles.update]", error.message);
    throw new Error("profiles.update: " + error.message);
  }

  const { error: e2 } = await sb.from("pro_subscriptions").upsert(
    { user_id: userId, status: on ? (probe ? "trialing" : "active") : "cancelled",
      started_at: new Date().toISOString() },
    { onConflict: "user_id" },
  );
  if (e2) {
    console.error("[pro_subscriptions.upsert]", e2.message);
    throw new Error("pro_subscriptions.upsert: " + e2.message);
  }
}

// ── Veröffentlichungsgebühr einer öffentlichen Party ─────────────────────
// Wirft bei Fehlern, damit Stripe es erneut versucht. Eine bezahlte Party,
// die nicht freigeschaltet wird, ist der teuerste denkbare stille Fehler.
async function releaseEvent(session: any): Promise<void> {
  const eventId = session.metadata?.event_id ?? "";
  if (!/^[0-9a-f-]{36}$/i.test(eventId)) {
    console.error("[fee] event_id fehlt oder ist ungültig", session.id);
    return;                       // ohne gültige Kennung hilft auch ein Neuversuch nicht
  }
  if (session.payment_status && session.payment_status !== "paid") {
    console.warn("[fee] noch nicht bezahlt", session.id, session.payment_status);
    return;
  }
  const { data, error } = await sb.from("events")
    .update({ status: "live", fee_paid_at: new Date().toISOString() })
    .eq("id", eventId)
    .select("id,name")
    .maybeSingle();
  if (error) {
    console.error("[fee] Freischaltung fehlgeschlagen", error.message);
    throw new Error("events.update: " + error.message);
  }
  if (!data) {
    console.error("[fee] Party nicht gefunden", eventId);
    throw new Error("Party nicht gefunden: " + eventId);
  }
  console.log("[fee] Party freigeschaltet:", data.id, data.name);
}

// ── Handler ─────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  // Health-Check: nur ja/nein. Länge und Format eines Secrets sind schon
  // ein Hinweis mehr, als ein Fremder wissen muss.
  if (req.method === "GET") {
    const body = {
      ok: true,
      funktion: "stripe-webhook",
      webhook_secret_gesetzt: WEBHOOK_SECRET.length > 0,
      stripe_key_gesetzt: STRIPE_SECRET.length > 0,
      service_role_gesetzt: SB_SERVICE_KEY.length > 0,
    };
    return new Response(JSON.stringify(body, null, 2), {
      status: 200, headers: { "Content-Type": "application/json" },
    });
  }

  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  const body = await req.text();
  const sig = req.headers.get("stripe-signature") ?? "";

  const sigErr = await verifyStripeSignature(body, sig);
  if (sigErr) {
    console.warn("[webhook] Signatur abgelehnt:", sigErr);
    return new Response(`Invalid signature: ${sigErr}`, { status: 400 });
  }

  let event: any;
  try { event = JSON.parse(body); } catch { return new Response("Bad JSON", { status: 400 }); }

  console.log("[webhook]", event.type, event.id);

  // Die Sperre gegen Doppelzustellung wird hier gesetzt – und weiter unten
  // wieder entfernt, falls die Verarbeitung scheitert. Sonst gilt ein
  // Ereignis als erledigt, das nie verarbeitet wurde.
  const { error: dupErr } = await sb.from("stripe_webhook_events")
    .insert({ stripe_event_id: event.id, event_type: event.type });
  if (dupErr && (dupErr as any).code === "23505") {
    return new Response(JSON.stringify({ received: true, duplicate: true }), { status: 200 });
  }
  if (dupErr) {
    // Konnte die Sperre gar nicht geschrieben werden, lieber neu versuchen
    // lassen, als ohne Schutz gegen Doppelzustellung weiterzumachen.
    console.error("[webhook] Sperre nicht schreibbar", dupErr.message);
    return new Response("Idempotency insert failed", { status: 500 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const s = event.data.object;

        // Party-Gebühr: einmalige Zahlung, hat mit Pro nichts zu tun
        if (s.metadata?.kind === "event_fee") {
          await releaseEvent(s);
          break;
        }

        // Alles Weitere ist das Pro-Abo. Eine Einmalzahlung darf niemals
        // Pro freischalten – deshalb hier die harte Bedingung.
        if (!s.subscription) {
          console.warn("[checkout] Zahlung ohne Abo, kein Pro:", s.id, s.mode);
          break;
        }

        const userId = await findUserId({
          clientReferenceId: s.client_reference_id,
          customerId: s.customer,
          email: s.customer_details?.email ?? s.customer_email,
        });
        if (!userId) {
          console.error("[checkout] kein Nutzer gefunden",
            { session: s.id, ref: s.client_reference_id, customer: s.customer });
          break;
        }
        const sub = await stripeGet(`subscriptions/${s.subscription}`);
        const periodEnd = periodEndOf(sub);
        // In der Testwoche steht das Abo auf "trialing" und es ist noch
        // kein Rappen geflossen. Pro gilt trotzdem – so verspricht es die App.
        const probe = sub?.status === "trialing";
        await setPro(userId, true, {
          stripe_customer_id: s.customer ?? null,
          stripe_subscription_id: s.subscription ?? null,
          subscription_current_period_end: periodEnd,
        }, probe);
        console.log("[checkout] Pro aktiviert für", userId,
          probe ? "(Testwoche)" : "", "bis", periodEnd ?? "unbekannt");
        break;
      }

      case "invoice.paid": {
        const inv = event.data.object;
        // Rechnungen ohne Abo gehören zu Einmalzahlungen (Party-Gebühr)
        const subId = subIdOf(inv);
        if (!subId) { console.log("[invoice.paid] ohne Abo, ignoriert"); break; }
        const userId = await findUserId({ customerId: inv.customer, email: inv.customer_email });
        if (!userId) { console.warn("[invoice.paid] kein Nutzer", inv.customer); break; }
        // Die erste Rechnung der Testwoche lautet auf 0 – die zählt noch
        // als Probe. Erst die erste echte Zahlung macht daraus ein Abo.
        const bezahlt = (inv.amount_paid ?? 0) > 0;
        const end = inv.lines?.data?.[0]?.period?.end;
        await setPro(userId, true, {
          stripe_subscription_id: subId,
          subscription_current_period_end: typeof end === "number"
            ? new Date(end * 1000).toISOString() : null,
        }, !bezahlt);
        console.log("[invoice.paid] verlängert für", userId, bezahlt ? "" : "(noch Testwoche)");
        break;
      }

      case "customer.subscription.updated": {
        const sub = event.data.object;
        const userId = await findUserId({ customerId: sub.customer });
        if (!userId) { console.warn("[sub.updated] kein Nutzer", sub.customer); break; }
        const active = ["active", "trialing"].includes(sub.status);

        // Gekündigt, läuft aber noch bis zum Periodenende: Pro bleibt, und
        // im Profil steht "gekuendigt". So sieht man im Betrieb, dass jemand
        // aussteigt, bevor die Mitgliedschaft tatsächlich endet.
        const gekuendigt = active && sub.cancel_at_period_end === true;

        await setPro(userId, active, {
          stripe_subscription_id: sub.id,
          subscription_current_period_end: periodEndOf(sub),
        }, sub.status === "trialing");

        if (gekuendigt) {
          const { error } = await sb.from("profiles")
            .update({ subscription_status: "gekuendigt" }).eq("id", userId);
          if (error) console.error("[sub.updated] Kündigungsvermerk", error.message);
        }
        console.log("[sub.updated]", userId, sub.status,
          gekuendigt ? "(gekündigt, läuft aus)" : "", "-> Pro", active);
        break;
      }

      case "customer.subscription.deleted":
      case "invoice.payment_failed": {
        const obj = event.data.object;
        if (event.type === "invoice.payment_failed") {
          if (!subIdOf(obj)) { console.log("[payment_failed] Einmalzahlung, kein Pro-Entzug"); break; }
          if (obj.next_payment_attempt) {
            console.log("[payment_failed] weiterer Versuch geplant, Pro bleibt");
            break;
          }
        }
        const userId = await findUserId({ customerId: obj.customer });
        if (!userId) { console.warn("[revoke] kein Nutzer", obj.customer); break; }
        await setPro(userId, false);
        console.log("[webhook] Pro entzogen für", userId, event.type);
        break;
      }

      default:
        console.log("[webhook] Event nicht behandelt:", event.type);
    }
  } catch (err) {
    // Hier lag der Fehler: die Sperre blieb stehen, Stripe schickte erneut,
    // und der zweite Versuch wurde als Doppel abgewiesen. Jetzt wird sie
    // wieder entfernt, damit der Neuversuch wirklich verarbeitet wird.
    console.error("[webhook] Fehler", err);
    const { error: delErr } = await sb.from("stripe_webhook_events")
      .delete().eq("stripe_event_id", event.id);
    if (delErr) {
      console.error("[webhook] ACHTUNG: Sperre konnte nicht entfernt werden",
        event.id, delErr.message);
    }
    return new Response("Handler error", { status: 500 });
  }

  return new Response(JSON.stringify({ received: true }), {
    status: 200, headers: { "Content-Type": "application/json" },
  });
});
