// SPOTOUT — RevenueCat Webhook (Apple In-App-Käufe)
//
// Apple verlangt für alles, was in der App Funktionen freischaltet, den Kauf
// über den App Store. Das betrifft zwei Dinge:
//
//   1. Pro          — Abo, monatlich, mit 7 Tagen Probezeit
//   2. Party-Gebühr — Einmalkauf, schaltet eine öffentliche Party frei
//
// RevenueCat nimmt Kauf und Beleg-Prüfung ab und meldet jedes Ereignis hierher.
// Pro landet in denselben Feldern wie beim Stripe-Webhook — wer auf der Website
// abonniert, ist auch in der App Pro.
//
// Secret: REVENUECAT_SECRET (dasselbe wie im RevenueCat-Dashboard)
//
// ── Was am 16.09.2026 geändert wurde ───────────────────────────────────
// 1. CANCELLATION wird jetzt vermerkt: subscription_status = 'gekuendigt'.
//    Pro bleibt bis EXPIRATION bestehen — so verspricht es die App —, aber
//    im Profil steht ab sofort, dass jemand aussteigt. Vorher schrieb dieser
//    Fall gar nichts, im Profil stand weiter "active", und eine Kündigung
//    war im Betrieb nicht zu sehen.
// 2. Scheitert die Verarbeitung, wird die Sperre gegen Doppelzustellung
//    wieder gelöst. Vorher blieb sie stehen: RevenueCat schickte erneut,
//    der zweite Versuch galt als Doppel — und der Kauf war still verloren.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const RC_SECRET      = Deno.env.get("REVENUECAT_SECRET") ?? "";
const SB_URL         = Deno.env.get("SUPABASE_URL") ?? "";
const SB_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const sb = createClient(SB_URL, SB_SERVICE_KEY, { auth: { persistSession: false } });

const GIBT_PRO = new Set([
  "INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION", "PRODUCT_CHANGE", "SUBSCRIPTION_EXTENDED",
]);
const NIMMT_PRO = new Set(["EXPIRATION", "REFUND"]);

// Alles, was mit party_fee beginnt, ist eine Gebühr — kein Abo
const istGebuehr = (produkt: string) => /^party_fee/i.test(produkt ?? "");

// Produktnummer → bezahlter Betrag in Franken. Damit prüft die Datenbank,
// dass niemand das billigste Produkt kauft und die teuerste Party freischaltet.
// Apple bietet in der Schweiz nur ganze Franken an, darum keine Rappenbeträge.
const FEE_BETRAG: Record<string, number> = {
  party_fee_3:   3,
  party_fee_5:   5,
  party_fee_8:   8,
  party_fee_15: 15,
  party_fee_30: 30,
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "GET") {
    return json({
      ok: true,
      funktion: "revenuecat-webhook",
      secret_gesetzt: RC_SECRET.length > 0,
      service_role: SB_SERVICE_KEY.length > 0,
      kennt_gebuehren: Object.keys(FEE_BETRAG),
    });
  }
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  if (!RC_SECRET) {
    console.error("[rc] REVENUECAT_SECRET fehlt");
    return new Response("Not configured", { status: 500 });
  }
  const auth = req.headers.get("Authorization") ?? "";
  if (auth !== RC_SECRET && auth !== `Bearer ${RC_SECRET}`) {
    console.warn("[rc] Authorization passt nicht");
    return new Response("Unauthorized", { status: 401 });
  }

  let nutzlast: any;
  try { nutzlast = await req.json(); } catch { return new Response("Bad JSON", { status: 400 }); }

  const e = nutzlast?.event ?? {};
  const art: string     = e.type ?? "";
  const nutzer: string  = e.app_user_id ?? "";
  const produkt: string = e.product_id ?? "";
  const id: string      = e.id ?? "";
  // TRIAL = die sieben Gratis-Tage, INTRO = ein vergünstigter Einstieg,
  // NORMAL = der bezahlte Regelfall.
  const periode: string = (e.period_type ?? "").toUpperCase();

  console.log("[rc]", art, produkt, periode, nutzer, id);

  if (!/^[0-9a-f-]{36}$/i.test(nutzer)) {
    console.warn("[rc] app_user_id ist keine Nutzer-ID:", nutzer);
    return json({ received: true, ignoriert: "anonyme ID" });
  }

  // ── Doppelte Zustellungen abfangen ───────────────────────────────
  // Die Sperre wird hier gesetzt und bei einem Fehler weiter unten wieder
  // gelöst. Bleibt sie nach einem Fehlschlag stehen, gilt ein Kauf als
  // erledigt, der nie verbucht wurde.
  let sperreGesetzt = false;
  if (id) {
    const { error: dup } = await sb.from("stripe_webhook_events")
      .insert({ stripe_event_id: "rc_" + id, event_type: "revenuecat." + art });
    if (dup && (dup as any).code === "23505") {
      return json({ received: true, duplicate: true });
    }
    if (dup) {
      console.error("[rc] Sperre nicht schreibbar", dup.message);
      return new Response("Idempotency insert failed", { status: 500 });
    }
    sperreGesetzt = true;
  }

  const sperreLoesen = async (grund: string) => {
    if (!sperreGesetzt || !id) return;
    const { error } = await sb.from("stripe_webhook_events")
      .delete().eq("stripe_event_id", "rc_" + id);
    if (error) {
      console.error("[rc] ACHTUNG: Sperre konnte nicht entfernt werden", id, error.message);
    } else {
      console.log("[rc] Sperre wieder gelöst nach Fehler:", grund);
    }
  };

  try {
    // ── 1) Party-Gebühr ──────────────────────────────────────────────
    if (istGebuehr(produkt)) {
      if (art === "REFUND" || art === "CANCELLATION") {
        console.log("[rc] Gebühr erstattet — Party bleibt vorerst live", produkt);
        return json({ received: true });
      }
      if (art !== "NON_RENEWING_PURCHASE" && art !== "INITIAL_PURCHASE") {
        return json({ received: true, ignoriert: art });
      }

      const betrag = FEE_BETRAG[produkt.toLowerCase()];
      if (betrag === undefined) {
        console.error("[rc] unbekanntes Gebührenprodukt", produkt);
        return json({ received: true, fehler: "unbekanntes Produkt" });
      }

      // Welche Party gemeint ist, hat die App vorher am Profil hinterlegt
      const { data: prof } = await sb.from("profiles")
        .select("pending_fee_event_id").eq("id", nutzer).maybeSingle();
      const evId = prof?.pending_fee_event_id;
      if (!evId) {
        // Kein Neuversuch: ohne wartende Party hilft auch ein zweiter
        // Anlauf nicht. Der Kauf ist verbucht, der Fall gehört von Hand
        // angeschaut.
        console.error("[rc] keine wartende Party für", nutzer);
        return json({ received: true, fehler: "keine wartende Party" });
      }

      const { data: ergebnis, error } = await sb
        .rpc("gebuehr_bezahlt", { p_user: nutzer, p_event: evId, p_betrag: betrag });
      if (error) {
        console.error("[rc] Freischaltung fehlgeschlagen", error.message);
        await sperreLoesen("gebuehr_bezahlt: " + error.message);
        return new Response("DB error", { status: 500 });
      }
      console.log("[rc] Gebühr", produkt, betrag, "→", ergebnis, evId);
      return json({ received: true, ergebnis });
    }

    // ── 2) Pro-Abo ───────────────────────────────────────────────────
    let an: boolean | null = null;
    if (GIBT_PRO.has(art)) an = true;
    else if (NIMMT_PRO.has(art)) an = false;
    else if (art === "CANCELLATION") {
      // Gekündigt heisst nicht sofort weg. Wer in der Testwoche kündigt,
      // behält Pro bis zum siebten Tag — so verspricht es die App.
      // Vermerkt wird die Kündigung trotzdem: sonst steht im Profil
      // weiter "active", und im Betrieb sieht niemand, dass jemand geht.
      const bisK = typeof e.expiration_at_ms === "number"
        ? new Date(e.expiration_at_ms).toISOString() : null;
      const patchK: Record<string, unknown> = {
        subscription_status: "gekuendigt",
        pro_updated_at: new Date().toISOString(),
      };
      if (bisK) patchK.subscription_current_period_end = bisK;

      const { error: eK } = await sb.from("profiles").update(patchK).eq("id", nutzer);
      if (eK) {
        console.error("[rc] Kündigungsvermerk fehlgeschlagen", eK.message);
        await sperreLoesen("profiles.update (CANCELLATION): " + eK.message);
        return new Response("DB error", { status: 500 });
      }
      const { error: eK2 } = await sb.from("pro_subscriptions").upsert(
        { user_id: nutzer, status: "gekuendigt", started_at: new Date().toISOString() },
        { onConflict: "user_id" },
      );
      if (eK2) console.error("[rc] pro_subscriptions (CANCELLATION)", eK2.message);

      console.log("[rc] Kündigung vermerkt, Pro bleibt bis", bisK ?? "EXPIRATION");
      return json({ received: true, gekuendigt: true, bis: bisK });
    } else if (art === "BILLING_ISSUE") {
      // Apple versucht es weiter. Erst EXPIRATION nimmt Pro weg.
      console.log("[rc] Zahlungsproblem gemeldet, Pro bleibt bis EXPIRATION");
      return json({ received: true });
    } else {
      console.log("[rc] Ereignis nicht behandelt:", art);
      return json({ received: true });
    }

    const bis = typeof e.expiration_at_ms === "number"
      ? new Date(e.expiration_at_ms).toISOString() : null;

    // Läuft gerade die Probewoche? Nur dann, und nur solange Pro an ist.
    const probe = an && periode === "TRIAL";

    const patch: Record<string, unknown> = {
      is_pro: an,
      pro_probe: probe,
      subscription_status: an ? (probe ? "trialing" : "active") : "cancelled",
      pro_updated_at: new Date().toISOString(),
    };
    // Das Enddatum ist der Wächter gegen "Webhook kam nie an". Wenn Apple
    // keines mitschickt, lieber gar keines schreiben als ein falsches.
    if (bis) patch.subscription_current_period_end = bis;

    const { error } = await sb.from("profiles").update(patch).eq("id", nutzer);
    if (error) {
      console.error("[rc] profiles.update", error.message);
      await sperreLoesen("profiles.update: " + error.message);
      return new Response("DB error", { status: 500 });
    }

    const { error: e2 } = await sb.from("pro_subscriptions").upsert(
      { user_id: nutzer, status: an ? (probe ? "trialing" : "active") : "cancelled",
        started_at: new Date().toISOString() },
      { onConflict: "user_id" },
    );
    if (e2) {
      console.error("[rc] pro_subscriptions.upsert", e2.message);
      await sperreLoesen("pro_subscriptions.upsert: " + e2.message);
      return new Response("DB error", { status: 500 });
    }

    console.log("[rc] Pro", an, probe ? "(Testwoche)" : "", "für", nutzer, "bis", bis ?? "unbekannt");
    return json({ received: true, pro: an, probe });

  } catch (err) {
    console.error("[rc] Unerwarteter Fehler", err);
    await sperreLoesen("Ausnahme");
    return new Response("Handler error", { status: 500 });
  }
});
