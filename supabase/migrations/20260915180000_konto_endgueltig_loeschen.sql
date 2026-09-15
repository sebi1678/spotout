-- SPOTOUT — Konto wirklich loeschen
--
-- Vorher loeschte die App Profil und Daten Schritt fuer Schritt, der Zugang
-- (auth.users) blieb aber bestehen. Wer sich danach nochmals anmeldete,
-- landete in einem Konto ohne Profil.
--
-- Jetzt loescht diese Funktion den Zugang selbst. Alles andere haengt per
-- Fremdschluessel daran (profiles -> Partys, Nachrichten, Follows,
-- Meldungen, Fotos …) und geht in einem Zug mit. Party-Fotos werden ueber
-- den Trigger fotos_bei_kontoloeschung auch im Speicher entfernt.
-- Jeder kann nur das eigene Konto loeschen (auth.uid()).

create or replace function public.konto_endgueltig_loeschen()
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare
  v_uid uuid := auth.uid();
  v_treffer int;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'meldung', 'Nicht angemeldet.');
  end if;
  delete from auth.users where id = v_uid;
  get diagnostics v_treffer = row_count;
  return jsonb_build_object('ok', v_treffer = 1);
end $$;
revoke all on function public.konto_endgueltig_loeschen() from public, anon;
grant execute on function public.konto_endgueltig_loeschen() to authenticated;
