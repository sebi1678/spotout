// SPOTOUT — Vereinskonten fuer den Betreiber
//
// Der Betreiber legt ein Konto fuer einen Verein an, postet dessen Anlaesse
// selbst und uebergibt das Konto danach. Alles hier braucht den
// Service-Schluessel und darum einen Server: Konten anlegen, in ein Konto
// wechseln, Passwort setzen. Jede Aktion prueft zuerst ist_admin – die
// Oberflaeche entscheidet nichts.
//
// Passwoerter werden nirgends gespeichert. Das Uebergabe-Passwort entsteht
// bei der Uebergabe, geht einmal an den Betreiber und ist danach weg.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SB_ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SB_SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
}
const fehler = (text: string, status = 400) => json({ fehler: text }, status);

// Ohne 0/O und 1/l/I: das Passwort wird oft abgeschrieben.
function passwortNeu(): string {
  const zeichen = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const zufall = crypto.getRandomValues(new Uint8Array(16));
  const roh = [...zufall].map((b) => zeichen[b % zeichen.length]).join("");
  return `${roh.slice(0, 5)}-${roh.slice(5, 10)}-${roh.slice(10, 15)}`;
}

function websiteSauber(w: string): string {
  const t = w.trim();
  return /^https?:\/\//i.test(t) ? t : `https://${t}`;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return fehler("Nur POST", 405);

  const anmeldung = req.headers.get("Authorization") ?? "";
  const nutzerSb = createClient(SB_URL, SB_ANON, { global: { headers: { Authorization: anmeldung } } });
  const { data: wer, error: werFehler } = await nutzerSb.auth.getUser();
  if (werFehler || !wer?.user) return fehler("Nicht angemeldet", 401);

  const sb = createClient(SB_URL, SB_SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: ich } = await sb.from("profiles").select("ist_admin").eq("id", wer.user.id).maybeSingle();
  if (!ich?.ist_admin) return fehler("Das darf nur der Betreiber.", 403);

  let e: Record<string, unknown>;
  try { e = await req.json(); } catch { return fehler("Ungültige Anfrage"); }
  const aktion = String(e.aktion ?? "");
  const id = String(e.id ?? "");

  async function betreut() {
    const { data } = await sb.from("vereine_betreut").select("*").eq("user_id", id).maybeSingle();
    return data;
  }

  try {
    if (aktion === "liste") {
      const { data: reihen, error } = await sb.from("vereine_betreut")
        .select("*").is("entfernt_am", null).order("angelegt_am", { ascending: false });
      if (error) throw error;
      const ids = (reihen ?? []).map((r) => r.user_id);
      if (!ids.length) return json({ vereine: [] });
      const [{ data: profile }, { data: partys }] = await Promise.all([
        sb.from("profiles").select("id,username,full_name,avatar_url,verein_ort,website,gebuehrenfrei,verein_status").in("id", ids),
        sb.from("events").select("created_by,date").in("created_by", ids),
      ]);
      const heute = new Date().toISOString().slice(0, 10);
      const vereine = (reihen ?? []).map((r) => {
        const p = profile?.find((x) => x.id === r.user_id);
        const eigene = (partys ?? []).filter((x) => x.created_by === r.user_id);
        return {
          id: r.user_id, email: r.email, angelegt_am: r.angelegt_am, uebergeben_am: r.uebergeben_am,
          name: p?.full_name || p?.username || "Verein", username: p?.username ?? "",
          ort: p?.verein_ort ?? "", website: p?.website ?? "", logo: !!p?.avatar_url, avatar: p?.avatar_url ?? "",
          gratis: !!p?.gebuehrenfrei, partys: eigene.length,
          kommend: eigene.filter((x) => x.date >= heute).length,
        };
      });
      return json({ vereine });
    }

    if (aktion === "anlegen") {
      const name = String(e.name ?? "").trim();
      const ort = String(e.ort ?? "").trim();
      const website = String(e.website ?? "").trim();
      const email = String(e.email ?? "").trim().toLowerCase();
      if (name.length < 2) return fehler("Wie heisst der Verein?");
      if (!ort) return fehler("Wo ist der Verein?");
      if (!website) return fehler("Die Website fehlt.");
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return fehler("Diese E-Mail-Adresse sieht nicht richtig aus.");

      // E-Mail gilt als bestaetigt, es geht keine Mail hinaus. Das Passwort
      // ist Zufall und wird nie gezeigt: gezeigt wird erst das der Uebergabe.
      const { data: neu, error } = await sb.auth.admin.createUser({
        email, password: passwortNeu(), email_confirm: true,
        user_metadata: { kontoart: "verein", full_name: name, username: name, website: websiteSauber(website), verein_ort: ort },
      });
      if (error || !neu?.user) {
        const m = String(error?.message ?? "");
        if (/already|exists|registered/i.test(m)) return fehler("Diese E-Mail hat schon ein Konto.");
        throw error ?? new Error("Konto nicht angelegt");
      }
      const uid = neu.user.id;
      try {
        const { error: pf } = await sb.from("profiles")
          .update({ verein_status: "bestaetigt", gebuehrenfrei: true }).eq("id", uid);
        if (pf) throw pf;
        const { error: tf } = await sb.from("vereine_betreut")
          .insert({ user_id: uid, email, angelegt_von: wer.user.id });
        if (tf) throw tf;
        // Der Betreiber hat das Konto selbst angelegt, eine Pruef-Meldung waere Rauschen.
        await sb.from("notifications").delete().eq("actor_id", uid).eq("art", "verein_pruefen");
      } catch (halb) {
        await sb.auth.admin.deleteUser(uid);   // kein halbes Konto liegen lassen
        throw halb;
      }
      return json({ ok: true, id: uid });
    }

    if (!id) return fehler("Welcher Verein?");
    const reihe = await betreut();
    if (!reihe) return fehler("Dieses Konto wird hier nicht verwaltet.", 404);

    if (aktion === "oeffnen") {
      if (reihe.uebergeben_am) return fehler("Dieses Konto ist schon übergeben.", 409);
      const { data: link, error } = await sb.auth.admin.generateLink({ type: "magiclink", email: reihe.email });
      if (error) throw error;
      const anon = createClient(SB_URL, SB_ANON, { auth: { persistSession: false, autoRefreshToken: false } });
      const { data: sitz, error: se } = await anon.auth.verifyOtp({
        type: "magiclink", token_hash: link.properties.hashed_token,
      });
      if (se || !sitz?.session) throw se ?? new Error("Keine Sitzung");
      const { data: p } = await sb.from("profiles").select("username,full_name,avatar_url").eq("id", id).maybeSingle();
      return json({
        ok: true, id, email: reihe.email, zugang: sitz.session.access_token, erneuerung: sitz.session.refresh_token,
        name: p?.full_name || p?.username || "Verein", username: p?.username ?? "", avatar: p?.avatar_url ?? "",
      });
    }

    if (aktion === "uebergeben") {
      const passwort = passwortNeu();
      const { error } = await sb.auth.admin.updateUserById(id, { password: passwort });
      if (error) throw error;
      // Alle offenen Sitzungen weg: ab jetzt gehoert das Konto dem Verein.
      const { error: se } = await sb.rpc("verein_sitzungen_beenden", { p_user: id });
      if (se) throw se;
      const jetzt = reihe.uebergeben_am ?? new Date().toISOString();
      const { error: te } = await sb.from("vereine_betreut").update({ uebergeben_am: jetzt }).eq("user_id", id);
      if (te) throw te;
      return json({ ok: true, passwort, email: reihe.email, uebergeben_am: jetzt });
    }

    if (aktion === "gratis") {
      const an = !!e.an;
      const { error } = await sb.from("profiles").update({ gebuehrenfrei: an }).eq("id", id);
      if (error) throw error;
      return json({ ok: true, gratis: an });
    }

    if (aktion === "entfernen") {
      if (!reihe.uebergeben_am) return fehler("Zuerst übergeben oder löschen.", 409);
      const { error } = await sb.from("vereine_betreut").update({ entfernt_am: new Date().toISOString() }).eq("user_id", id);
      if (error) throw error;
      return json({ ok: true });
    }

    if (aktion === "loeschen") {
      if (reihe.uebergeben_am) return fehler("Ein übergebenes Konto gehört dem Verein.", 409);
      const { error } = await sb.auth.admin.deleteUser(id);
      if (error) throw error;
      await sb.storage.from("avatars").remove([`avatars/${id}.jpg`]);
      return json({ ok: true });
    }

    return fehler("Unbekannte Aktion");
  } catch (err) {
    console.error("[vereine-verwalten]", aktion, err);
    return fehler("Das hat nicht geklappt. Versuch es nochmals.", 500);
  }
});
