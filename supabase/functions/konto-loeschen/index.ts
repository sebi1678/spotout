// SPOTOUT — Konto endgueltig loeschen, ohne dass ein Abo weiterlaeuft
//
// Ein Stripe-Abo (Pro im Browser) wird zuerst gekuendigt, dann loescht die
// Datenbankfunktion konto_endgueltig_loeschen den Zugang samt allem, was
// daran haengt. Klappt die Kuendigung nicht, wird NICHT geloescht – sonst
// wuerde Stripe weiter abbuchen, ohne dass es das Konto noch gibt.
// Apple-Abos lassen sich von hier aus nicht kuendigen; das sagt die App.
//
// Mit Apple angemeldet (21.10.2026): Apple verlangt, dass die Anmeldung beim
// Loeschen auch bei Apple widerrufen wird (Richtlinie 5.1.1(v)). Die App
// schickt dafuer einen frischen Code (apple_code). Hier wird er gegen ein
// Token getauscht und dieses sofort widerrufen. Klappt der Widerruf nicht,
// wird trotzdem geloescht – das Recht auf Loeschung geht vor; der Fehler
// steht im Protokoll.
//
// Secrets (nur im Supabase-Dashboard, nie im Code):
//   APPLE_TEAM_ID      6VMVGUPDY5
//   APPLE_KEY_ID       Schluessel-ID aus developer.apple.com → Keys
//   APPLE_PRIVATE_KEY  Inhalt der .p8-Datei (mit BEGIN/END-Zeilen)

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SB_ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SB_SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const APPLE_TEAM = Deno.env.get("APPLE_TEAM_ID") ?? "";
const APPLE_KEY_ID = Deno.env.get("APPLE_KEY_ID") ?? "";
const APPLE_KEY = Deno.env.get("APPLE_PRIVATE_KEY") ?? "";
const APPLE_CLIENT = "com.spotout.app";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}

function b64url(daten: Uint8Array | string): string {
  const bytes = typeof daten === "string" ? new TextEncoder().encode(daten) : daten;
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/* Client-Secret fuer Apple: ein JWT, signiert mit dem .p8-Schluessel (ES256).
   WebCrypto liefert die Signatur schon im Format, das JWT verlangt (r||s). */
async function appleClientSecret(): Promise<string> {
  const pem = APPLE_KEY.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const schluessel = await crypto.subtle.importKey(
    "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  const jetzt = Math.floor(Date.now() / 1000);
  const kopf = b64url(JSON.stringify({ alg: "ES256", kid: APPLE_KEY_ID }));
  const inhalt = b64url(JSON.stringify({
    iss: APPLE_TEAM, iat: jetzt, exp: jetzt + 300, aud: "https://appleid.apple.com", sub: APPLE_CLIENT,
  }));
  const sig = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, schluessel, new TextEncoder().encode(`${kopf}.${inhalt}`),
  ));
  return `${kopf}.${inhalt}.${b64url(sig)}`;
}

async function appleWiderrufen(code: string): Promise<void> {
  if (!APPLE_TEAM || !APPLE_KEY_ID || !APPLE_KEY) {
    console.warn("[konto-loeschen] Apple-Widerruf: Secrets fehlen");
    return;
  }
  const geheim = await appleClientSecret();
  const tausch = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: APPLE_CLIENT, client_secret: geheim, code, grant_type: "authorization_code" }),
  });
  if (!tausch.ok) {
    console.error("[konto-loeschen] Apple-Tausch fehlgeschlagen", tausch.status, await tausch.text());
    return;
  }
  const t = await tausch.json();
  const token = t.refresh_token || t.access_token;
  const hinweis = t.refresh_token ? "refresh_token" : "access_token";
  if (!token) { console.error("[konto-loeschen] Apple: kein Token erhalten"); return; }
  const weg = await fetch("https://appleid.apple.com/auth/revoke", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: APPLE_CLIENT, client_secret: geheim, token, token_type_hint: hinweis }),
  });
  if (!weg.ok) console.error("[konto-loeschen] Apple-Widerruf fehlgeschlagen", weg.status, await weg.text());
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, fehler: "methode" }, 405);

  const auth = req.headers.get("Authorization") ?? "";
  const alsNutzer = createClient(SB_URL, SB_ANON, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });
  const { data: u } = await alsNutzer.auth.getUser();
  const user = u?.user;
  if (!user) return json({ ok: false, fehler: "nicht_angemeldet" }, 401);

  let koerper: { apple_code?: unknown } = {};
  try { koerper = await req.json(); } catch (_) { /* leerer Koerper ist erlaubt */ }

  const admin = createClient(SB_URL, SB_SERVICE, { auth: { persistSession: false } });
  const { data: p } = await admin.from("profiles")
    .select("stripe_subscription_id,subscription_status").eq("id", user.id).maybeSingle();

  const sub = String(p?.stripe_subscription_id ?? "");
  if (sub.startsWith("sub_") && p?.subscription_status !== "cancelled") {
    if (!STRIPE) return json({ ok: false, fehler: "abo" });
    const r = await fetch(`https://api.stripe.com/v1/subscriptions/${sub}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${STRIPE}` },
    });
    if (!r.ok && r.status !== 404) {
      console.error("[konto-loeschen] Stripe-Kuendigung fehlgeschlagen", r.status, await r.text());
      return json({ ok: false, fehler: "abo" });
    }
  }

  const appleCode = typeof koerper?.apple_code === "string" ? koerper.apple_code : "";
  if (appleCode) {
    try { await appleWiderrufen(appleCode); }
    catch (e) { console.error("[konto-loeschen] Apple-Widerruf", (e as Error)?.message); }
  }

  const { data, error } = await alsNutzer.rpc("konto_endgueltig_loeschen");
  if (error) {
    console.error("[konto-loeschen] Datenbank", error.message);
    return json({ ok: false, fehler: "db" });
  }
  return json({ ok: !!(data as any)?.ok });
});
