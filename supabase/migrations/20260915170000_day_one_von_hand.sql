-- SPOTOUT — Day One von Hand
--
-- Day One wird nicht mehr automatisch an die ersten 100 vergeben,
-- sondern vom Betreiber von Hand – wie Pro verschenken.
-- Wer das Abzeichen schon hat, behaelt es.

drop trigger if exists trg_day_one on public.profiles;

create or replace function public.day_one_vergeben_von_hand(p_benutzername text)
 returns table(ok boolean, meldung text)
 language plpgsql security definer set search_path to 'public'
as $$
declare ziel public.profiles;
begin
  if not public.ist_admin() then
    return query select false, 'Das darf nur der Betreiber.'::text; return;
  end if;
  select * into ziel from public.profiles
   where lower(username) = lower(btrim(coalesce(p_benutzername,'')));
  if ziel.id is null then
    return query select false, 'Diesen Benutzernamen gibt es nicht.'::text; return;
  end if;
  if coalesce(ziel.kontoart,'privat') = 'verein' then
    return query select false, 'Vereine bekommen kein Day One.'::text; return;
  end if;
  if coalesce(ziel.day_one,false) then
    return query select false, ('@' || ziel.username || ' ist schon Day One.')::text; return;
  end if;
  update public.profiles set day_one = true where id = ziel.id;
  begin
    perform public.notify(ziel.id, auth.uid(), null, 'day_one',
      'Du bist jetzt Day One',
      'Von Anfang an dabei – das Abzeichen steht ab sofort in deinem Profil.');
  exception when others then null;
  end;
  return query select true, ('Day One an @' || ziel.username || ' vergeben')::text;
end $$;
revoke all on function public.day_one_vergeben_von_hand(text) from public, anon;
grant execute on function public.day_one_vergeben_von_hand(text) to authenticated;

create or replace function public.day_one_zurueck(p_benutzername text)
 returns table(ok boolean, meldung text)
 language plpgsql security definer set search_path to 'public'
as $$
declare ziel public.profiles;
begin
  if not public.ist_admin() then
    return query select false, 'Das darf nur der Betreiber.'::text; return;
  end if;
  select * into ziel from public.profiles
   where lower(username) = lower(btrim(coalesce(p_benutzername,'')));
  if ziel.id is null then
    return query select false, 'Diesen Benutzernamen gibt es nicht.'::text; return;
  end if;
  if not coalesce(ziel.day_one,false) then
    return query select false, ('@' || ziel.username || ' hat kein Day One.')::text; return;
  end if;
  update public.profiles set day_one = false where id = ziel.id;
  return query select true, ('Day One bei @' || ziel.username || ' entfernt')::text;
end $$;
revoke all on function public.day_one_zurueck(text) from public, anon;
grant execute on function public.day_one_zurueck(text) to authenticated;
