-- SPOTOUT — Sicherheit aufraeumen (Supabase-Linter)
--
-- 1. Feste search_path fuer Funktionen, die keinen hatten (Lint 0011).
-- 2. aktive_nutzer: nur noch fuer den Betreiber im SQL-Editor, nicht fuer
--    Besucher der App (vorher konnte jeder die Nutzerzahlen lesen).
-- 3. Alte, leere Ablagen party-photos und chat-images nicht mehr oeffentlich.
--    Party-Fotos liegen seit dem 15. September privat in party-fotos.

alter function public.is_group_member(uuid,uuid) set search_path = public, extensions;
alter function public.event_ende(date,time without time zone,time without time zone) set search_path = public, extensions;
alter function public.ist_freimail(text) set search_path = public, extensions;
alter function public.domain_passt(text,text) set search_path = public, extensions;
alter function public.zahlarten_aufraeumen() set search_path = public, extensions;
alter function public.cleanup_old_search_history() set search_path = public, extensions;
alter function public.adresse_schluessel(text) set search_path = public, extensions;
alter function public.enthaelt_sexuelles(text) set search_path = public, extensions;
alter function public.blocke_sexuelle_inhalte() set search_path = public, extensions;
alter function public.blocke_sexuelle_profile() set search_path = public, extensions;
alter function public.domain_aus_url(text) set search_path = public, extensions;
alter function public.guard_name_nur_mit_pro() set search_path = public, extensions;
alter function public.guard_username_wechsel() set search_path = public, extensions;
alter function public.reports_grund_fuellen() set search_path = public, extensions;
alter function public.guard_nachricht_unveraendert() set search_path = public, extensions;

alter view public.aktive_nutzer set (security_invoker = true);
revoke all on public.aktive_nutzer from anon, authenticated;

update storage.buckets set public = false where id in ('party-photos','chat-images');
drop policy if exists "party-photos: jeder darf lesen" on storage.objects;
drop policy if exists "chat-images: jeder darf lesen" on storage.objects;
