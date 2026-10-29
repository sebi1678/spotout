// SPOTOUT — Eventfrog-Abgleich
//
// Holt Events aus der Schweiz (nächste 60 Tage) von der Eventfrog Public
// API V1 in die Tabelle externe_events. Die Website zeigt sie im Reiter
// „Events“ als Karten mit „Tickets · Eventfrog“ (externeLaden in index.html).
//
// Nach den Vorgaben von Eventfrog (docs.api.eventfrog.net):
// - Erstladung voll, danach nur Änderungen der letzten 3 Tage
//   (modifiedSince mit Überlappung), alle 30 Tage wieder voll.
// - Bilder nie direkt von Eventfrog laden (kein Hotlinking): sie werden
//   hier in den eigenen Speicher kopiert, höchstens BILDER_JE_LAUF pro
//   Aufruf – der Rest folgt beim nächsten Lauf.
// - Orte in Paketen zu 100 IDs holen.
//
// Nur Kategorien, die zu SPOTOUT passen (Party, Club, Festival, Konzert …),
// erkannt am Namen der Eventfrog-Rubrik (PASST).
//
// Aufrufer: nur die Datenbank – pg_cron über eventfrog_sync_anstossen().
// Erkannt am Geheimnis aus dem Vault (eventfrog_geheimnis()).
// API-Schlüssel: Secret EVENTFROG_API_KEY (Supabase → Edge Functions → Secrets).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SB_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const EF_KEY = Deno.env.get("EVENTFROG_API_KEY") ?? "";
const EF = "https://api.eventfrog.net/public/v1";
const BUCKET = "externe-events";
const TAGE_VORAUS = 60;
const BILDER_JE_LAUF = 120;
const BILD_MAX = 3 * 1024 * 1024;

/* Rubriken, die zu Partys und Festen passen. Verglichen wird klein
   geschrieben mit dem deutschen (sonst englischen) Namen der Rubrik. */
const PASST = [
  "party", "club", "disco", "dj", "techno", "house", "electro", "hip hop", "hip-hop",
  "rap", "festival", "openair", "open air", "konzert", "concert", "live", "fest",
  "fasnacht", "ball", "nightlife", "nachtleben", "après", "apres", "rock", "pop",
  "schlager", "latin", "reggae", "metal", "punk",
];

const admin = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } });

type Text = Record<string, string | null> | string | null | undefined;
type Bild = { url?: string | null } | null | undefined;
type EfEvent = {
  id: string; rubricId?: number; title?: Text; url?: string; presaleLink?: string;
  emblemToShow?: Bild; emblemCredits?: string; begin?: string; end?: string; cancelled?: boolean;
  visible?: boolean; published?: boolean; locationIds?: string[]; locationAlias?: Text;
};
type EfOrt = {
  id: string; title?: Text; addressLine?: string; zip?: string; city?: string;
  lat?: number; lng?: number;
};

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

// Mehrsprachige Felder: Deutsch zuerst, dann was es gibt
function text(t: Text): string {
  if (!t) return "";
  if (typeof t === "string") return t.trim();
  return (t.de || t.en || t.fr || t.it || Object.values(t).find(Boolean) || "").trim();
}

/* Eventfrog erlaubt 30 Anfragen pro Minute und 2'000 pro Tag (je Konto).
   Ein Lauf braucht etwa 5–20 Anfragen; mit 2.1 s Abstand bleibt er immer
   unter der Minutengrenze. */
let letzteAnfrage = 0;
async function ef(pfad: string, q: URLSearchParams) {
  const warten = letzteAnfrage + 2100 - Date.now();
  if (warten > 0) await new Promise((ok) => setTimeout(ok, warten));
  letzteAnfrage = Date.now();
  const r = await fetch(`${EF}/${pfad}?${q}`, {
    headers: { Authorization: `Bearer ${EF_KEY}`, Accept: "application/json" },
  });
  if (!r.ok) throw new Error(`Eventfrog ${pfad}: ${r.status} ${(await r.text()).slice(0, 200)}`);
  return await r.json();
}

async function rubrikenLaden(): Promise<Map<number, string>> {
  const d = await ef("rubrics", new URLSearchParams());
  const liste: { id: number; title?: Text }[] = d.rubrics ?? [];
  return new Map(liste.map((r) => [Number(r.id), text(r.title)]));
}

async function eventsLaden(voll: boolean, rubIds: number[]) {
  const heute = new Date();
  const bis = new Date(Date.now() + TAGE_VORAUS * 864e5);
  const alle: EfEvent[] = [];
  for (let seite = 1; seite <= 60; seite++) {
    const q = new URLSearchParams({
      country: "CH",
      from: heute.toISOString().slice(0, 10),
      to: bis.toISOString().slice(0, 10),
      perPage: "1000",
      page: String(seite),
    });
    // Nur passende Rubriken abfragen: statt ~30'000 Events nur ~3'000
    rubIds.forEach((id) => q.append("rubId", String(id)));
    if (!voll) q.set("modifiedSince", new Date(Date.now() - 3 * 864e5).toISOString().slice(0, 10));
    const d = await ef("events", q);
    const teil: EfEvent[] = d.events ?? [];
    alle.push(...teil);
    if (teil.length < 1000) break;
  }
  return alle;
}

async function orteLaden(ids: string[]): Promise<Map<string, EfOrt>> {
  const orte = new Map<string, EfOrt>();
  const eindeutig = [...new Set(ids)];
  for (let i = 0; i < eindeutig.length; i += 100) {
    const q = new URLSearchParams({ perPage: "100" });
    eindeutig.slice(i, i + 100).forEach((id) => q.append("id", id));
    const d = await ef("locations", q);
    for (const o of (d.locations ?? []) as EfOrt[]) orte.set(String(o.id), o);
  }
  return orte;
}

// Ein Bild von Eventfrog holen und in den eigenen Speicher legen
async function bildKopieren(eventfrogId: string, quelle: string): Promise<string | null> {
  try {
    const r = await fetch(quelle);
    if (!r.ok) return null;
    const typ = r.headers.get("content-type") ?? "image/jpeg";
    if (!typ.startsWith("image/")) return null;
    const daten = new Uint8Array(await r.arrayBuffer());
    if (daten.byteLength > BILD_MAX) return null;
    const endung = typ.includes("png") ? "png" : typ.includes("webp") ? "webp" : "jpg";
    const pfad = `${eventfrogId}.${endung}`;
    const { error } = await admin.storage.from(BUCKET).upload(pfad, daten, { contentType: typ, upsert: true });
    if (error) { console.warn("[eventfrog] Bild", eventfrogId, error.message); return null; }
    return admin.storage.from(BUCKET).getPublicUrl(pfad).data.publicUrl;
  } catch (e) {
    console.warn("[eventfrog] Bild", eventfrogId, e);
    return null;
  }
}

// Fehlende Bilder nachholen – die nächsten Events zuerst
async function bilderNachholen() {
  const { data: ohneBild } = await admin.from("externe_events")
    .select("eventfrog_id,bild_quelle")
    .is("bild_url", null).not("bild_quelle", "is", null)
    .order("beginn", { ascending: true }).limit(BILDER_JE_LAUF);
  let bilder = 0;
  for (const x of ohneBild ?? []) {
    const url = await bildKopieren(x.eventfrog_id, x.bild_quelle);
    if (!url) {
      // Nicht ladbar: Quelle vergessen, sonst wird es bei jedem Lauf neu versucht
      await admin.from("externe_events").update({ bild_quelle: null }).eq("eventfrog_id", x.eventfrog_id);
      continue;
    }
    await admin.from("externe_events").update({ bild_url: url }).eq("eventfrog_id", x.eventfrog_id);
    bilder++;
  }
  return bilder;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false }, 405);

  const { data: soll, error: gFehler } = await admin.rpc("eventfrog_geheimnis");
  const ist = req.headers.get("x-spotout-geheimnis") ?? "";
  if (gFehler || typeof soll !== "string" || !soll || !gleich(ist, soll)) {
    return json({ ok: false }, 401);
  }
  /* {"nurBilder":true}: nur Bilder nachholen, keine Anfrage an die
     Eventfrog-API (eigener Auftrag alle 10 Minuten, siehe eventfrog-bilder). */
  const auftrag = await req.json().catch(() => ({}));
  if (auftrag?.nurBilder) {
    try { return json({ ok: true, bilder: await bilderNachholen() }); }
    catch (e) { return json({ ok: false, fehler: String(e instanceof Error ? e.message : e) }, 500); }
  }
  if (!EF_KEY) return json({ ok: false, fehler: "EVENTFROG_API_KEY fehlt" }, 500);

  try {
    // Voll laden, wenn die Tabelle leer ist oder am 1. jedes Monats
    const { count } = await admin.from("externe_events").select("id", { count: "exact", head: true });
    const voll = !count || new Date().getUTCDate() === 1;

    const rubriken = await rubrikenLaden();
    const passt = (id?: number) => {
      const n = (rubriken.get(Number(id)) ?? "").toLowerCase();
      return !!n && PASST.some((w) => n.includes(w));
    };

    /* Dasselbe Event kann auf zwei Seiten der Antwort stehen (die Liste
       verschiebt sich waehrend des Blaetterns). Doppelte liessen das
       Speichern scheitern: "cannot affect row a second time". */
    const rubIds = [...rubriken.keys()].filter((id) => passt(id));
    const events = [...new Map((await eventsLaden(voll, rubIds)).map((e) => [String(e.id), e])).values()];
    const weg: string[] = [];
    const gute: EfEvent[] = [];
    for (const e of events) {
      const sichtbar = e.visible !== false && e.published !== false && !e.cancelled;
      if (sichtbar && e.begin && passt(e.rubricId) && text(e.title)) gute.push(e);
      else weg.push(String(e.id));      // abgesagt, versteckt oder nicht (mehr) passend
    }

    const orte = await orteLaden(gute.flatMap((e) => (e.locationIds ?? []).slice(0, 1)));

    // Was schon da ist: Bild nur neu holen, wenn sich die Quelle geändert hat
    const bisher = new Map<string, { bild_quelle: string | null; bild_url: string | null }>();
    for (let i = 0; i < gute.length; i += 500) {
      const { data } = await admin.from("externe_events")
        .select("eventfrog_id,bild_quelle,bild_url")
        .in("eventfrog_id", gute.slice(i, i + 500).map((e) => String(e.id)));
      for (const x of data ?? []) bisher.set(x.eventfrog_id, x);
    }

    const zeilen = gute.map((e) => {
      const ort = orte.get(String((e.locationIds ?? [])[0] ?? ""));
      const alt = bisher.get(String(e.id));
      const quelle = e.emblemToShow?.url ?? null;
      return {
        eventfrog_id: String(e.id),
        titel: text(e.title).slice(0, 200),
        beginn: e.begin,
        ende: e.end ?? null,
        ort_name: (text(e.locationAlias) || text(ort?.title) || null),
        adresse: [ort?.addressLine, [ort?.zip, ort?.city].filter(Boolean).join(" ")].filter(Boolean).join(", ") || null,
        lat: ort?.lat ?? null,
        lng: ort?.lng ?? null,
        ticket_url: e.presaleLink || e.url || null,
        kategorie: rubriken.get(Number(e.rubricId)) || null,
        bild_quelle: quelle,
        // Eventfrog moechte genannt werden – samt Bildnachweis, falls es einen gibt
        bild_credit: (e.emblemCredits || "").trim().slice(0, 120) || null,
        // Gleiches Bild wie bisher: die eigene Kopie behalten
        bild_url: alt && alt.bild_quelle === quelle ? alt.bild_url : null,
        geaendert_am: new Date().toISOString(),
      };
    });

    for (let i = 0; i < zeilen.length; i += 500) {
      const { error } = await admin.from("externe_events").upsert(zeilen.slice(i, i + 500), { onConflict: "eventfrog_id" });
      if (error) throw new Error("Speichern: " + error.message);
    }
    for (let i = 0; i < weg.length; i += 500) {
      await admin.from("externe_events").delete().in("eventfrog_id", weg.slice(i, i + 500));
    }

    const bilder = await bilderNachholen();

    // Vorbei: einen Tag nach Beginn weg (samt Bild)
    const { data: alt } = await admin.from("externe_events")
      .select("eventfrog_id,bild_url").lt("beginn", new Date(Date.now() - 864e5).toISOString()).limit(1000);
    if (alt?.length) {
      const pfade = alt.filter((x) => x.bild_url).map((x) => String(x.bild_url).split(`/${BUCKET}/`)[1]).filter(Boolean);
      if (pfade.length) await admin.storage.from(BUCKET).remove(pfade);
      await admin.from("externe_events").delete().in("eventfrog_id", alt.map((x) => x.eventfrog_id));
    }

    return json({ ok: true, voll, geholt: events.length, gespeichert: zeilen.length, entfernt: weg.length, bilder, vorbei: alt?.length ?? 0 });
  } catch (e) {
    console.warn("[eventfrog]", e);
    return json({ ok: false, fehler: String(e instanceof Error ? e.message : e) }, 500);
  }
});
