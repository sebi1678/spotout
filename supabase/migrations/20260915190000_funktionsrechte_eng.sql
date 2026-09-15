-- SPOTOUT — Funktionsrechte eng (Supabase-Linter 0028/0029)
--
-- 55 SECURITY-DEFINER-Funktionen waren fuer Besucher ohne Konto aufrufbar.
-- Eingeteilt nach: Trigger · interne Helfer · Policy-Helfer · App-Aufrufe.
--
-- Wichtigster Fund: notify() und notify_chat() waren von aussen aufrufbar –
-- jeder haette jedem eine Benachrichtigung samt Push mit eigenem Text
-- schicken koennen.
--
-- Bewusst unveraendert (Besucher ohne Konto brauchen sie):
--   blockiert, ist_eingeladen, ist_host, is_group_member  (stehen in Policies)
--   profil_ansehen, get_event_by_invite, get_follow_stats, freunde_dabei, party_gesehen

-- ── Trigger-Funktionen: werden von der Datenbank ausgeloest ─────────────
revoke all on function public.apply_guest_request() from public, anon, authenticated;
revoke all on function public.gaeste_zahl_pflegen() from public, anon, authenticated;
revoke all on function public.gastgeber_eintragen() from public, anon, authenticated;
revoke all on function public.guard_anfrage_pro() from public, anon, authenticated;
revoke all on function public.guard_blocked_message() from public, anon, authenticated;
revoke all on function public.guard_doppelte_party() from public, anon, authenticated;
revoke all on function public.guard_einladung_privat() from public, anon, authenticated;
revoke all on function public.guard_gastgeber_bleibt() from public, anon, authenticated;
revoke all on function public.guard_gespraech_pro() from public, anon, authenticated;
revoke all on function public.guard_kapazitaet() from public, anon, authenticated;
revoke all on function public.guard_mitbringliste() from public, anon, authenticated;
revoke all on function public.guard_plus_ones() from public, anon, authenticated;
revoke all on function public.guard_privates_folgen() from public, anon, authenticated;
revoke all on function public.guard_verein_anmeldung() from public, anon, authenticated;
revoke all on function public.guard_verein_events() from public, anon, authenticated;
revoke all on function public.guard_verein_gespraech() from public, anon, authenticated;
revoke all on function public.guard_verein_kein_pro() from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.melde_freund_dabei() from public, anon, authenticated;
revoke all on function public.melde_nachricht() from public, anon, authenticated;
revoke all on function public.notify_event_changed() from public, anon, authenticated;
revoke all on function public.notify_event_deleted() from public, anon, authenticated;
revoke all on function public.notify_guest_decision() from public, anon, authenticated;
revoke all on function public.notify_guest_request() from public, anon, authenticated;
revoke all on function public.notify_invite() from public, anon, authenticated;
revoke all on function public.sende_push() from public, anon, authenticated;
revoke all on function public.set_event_fee() from public, anon, authenticated;
revoke all on function public.verein_nach_bestaetigung() from public, anon, authenticated;

-- Alter Day-One-Trigger ist entfernt (20260915170000), die Funktion dazu auch
drop function if exists public.day_one_vergeben();

-- ── Interne Helfer: nur aus der Datenbank heraus ───────────────────────
revoke all on function public.notify(uuid,uuid,uuid,text,text,text) from public, anon, authenticated;
revoke all on function public.notify_chat(uuid,uuid,uuid,text,text) from public, anon, authenticated;
revoke all on function public.delete_old_events() from public, anon, authenticated;
revoke all on function public.gaeste_zahl_neu(uuid) from public, anon, authenticated;
revoke all on function public.neuer_einladungscode(integer) from public, anon, authenticated;

-- ── Pruef-Helfer ohne Policy: nicht fuer Besucher ohne Konto ──────────
revoke all on function public.get_pro_status(uuid) from public, anon;
revoke all on function public.ist_admin() from public, anon;
revoke all on function public.ist_verein(uuid) from public, anon;
revoke all on function public.sind_verbunden(uuid,uuid) from public, anon;
revoke all on function public.verein_darf_posten(uuid) from public, anon;
grant execute on function public.get_pro_status(uuid) to authenticated;
grant execute on function public.ist_admin() to authenticated;
grant execute on function public.ist_verein(uuid) to authenticated;
grant execute on function public.sind_verbunden(uuid,uuid) to authenticated;
grant execute on function public.verein_darf_posten(uuid) to authenticated;

-- ── Aktionen, die ein Konto voraussetzen ──────────────────────────────
revoke all on function public.anfrage_beantworten(uuid,boolean) from public, anon;
revoke all on function public.einladung_erstellen(uuid,text) from public, anon;
revoke all on function public.einladungsart_setzen(uuid,boolean) from public, anon;
revoke all on function public.folgen_anfragen(uuid) from public, anon;
revoke all on function public.offenen_link_erneuern(uuid) from public, anon;
revoke all on function public.join_by_invite(text) from public, anon;
revoke all on function public.ping() from public, anon;
grant execute on function public.anfrage_beantworten(uuid,boolean) to authenticated;
grant execute on function public.einladung_erstellen(uuid,text) to authenticated;
grant execute on function public.einladungsart_setzen(uuid,boolean) to authenticated;
grant execute on function public.folgen_anfragen(uuid) to authenticated;
grant execute on function public.offenen_link_erneuern(uuid) to authenticated;
grant execute on function public.join_by_invite(text) to authenticated;
grant execute on function public.ping() to authenticated;
