// SPOTOUT — Party-Fotos aufräumen
//
// Löscht Datei und Eintrag jedes Fotos, dessen Zeit um ist: 27 Stunden nach
// Partybeginn, oder sofort, wenn es entfernt wurde. Dazu Dateien, zu denen es
// nie einen Eintrag gab (abgebrochenes Hochladen).
//
// Aufrufer: nur die Datenbank – pg_cron alle 15 Minuten und foto_entfernen()
// direkt nach dem Entfernen. Erkannt am Geheimnis aus dem Vault.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SB_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const BUCKET = "party-fotos";
const PAKET = 100;

const admin = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } });

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function gleich(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false }, 405);

  const { data: soll, error: gFehler } = await admin.rpc("fotos_geheimnis");
  const ist = req.headers.get("x-spotout-geheimnis") ?? "";
  if (gFehler || typeof soll !== "string" || !soll || !gleich(ist, soll)) {
    return json({ ok: false }, 401);
  }

  let geloescht = 0;
  for (let runde = 0; runde < 20; runde++) {
    const { data: faellig, error } = await admin
      .from("party_fotos")
      .select("id,pfad")
      .lte("loeschen_ab", new Date().toISOString())
      .limit(PAKET);
    if (error) return json({ ok: false, fehler: error.message }, 500);
    if (!faellig || faellig.length === 0) break;

    // Erst die Dateien, dann die Einträge – umgekehrt blieben bei einem
    // Fehler Dateien zurück, von denen niemand mehr weiss.
    const { error: sFehler } = await admin.storage.from(BUCKET).remove(faellig.map((f) => f.pfad));
    if (sFehler) return json({ ok: false, fehler: sFehler.message, geloescht }, 500);

    const { error: dFehler } = await admin.from("party_fotos").delete().in("id", faellig.map((f) => f.id));
    if (dFehler) return json({ ok: false, fehler: dFehler.message, geloescht }, 500);

    geloescht += faellig.length;
    if (faellig.length < PAKET) break;
  }

  let waisen = 0;
  const { data: w } = await admin.rpc("fotos_waisen", { p_limit: 500 });
  if (Array.isArray(w) && w.length) {
    const { error } = await admin.storage.from(BUCKET).remove(w.map((x: { name: string }) => x.name));
    if (!error) waisen = w.length;
  }

  return json({ ok: true, geloescht, waisen });
});
