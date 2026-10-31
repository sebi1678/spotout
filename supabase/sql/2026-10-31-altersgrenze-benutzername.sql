-- SPOTOUT · 31.10.2026 · im Supabase-Dashboard → SQL Editor einfügen und "Run"
-- Zwei Änderungen. Beide lassen sich rückgängig machen (siehe unten).

begin;

-- 1) Partys ab 18 / 21 sieht jeder, auch Jüngere.
--    Sie tragen überall das Abzeichen 18+ / 21+.
--    ANMELDEN darf sich weiterhin nur, wer alt genug ist:
--    die Regel "Altersgrenze: anmelden" auf event_attendees bleibt.
drop policy if exists "Altersgrenze: Partys sehen" on public.events;

-- 2) Benutzername bei der Registrierung: auch Punkt, Bindestrich und
--    Buchstaben mit Umlaut/Akzent (vorher nur a–z, 0–9, _).
--    Kein Punkt am Anfang/Ende, keine zwei Punkte hintereinander.
create or replace function public.handle_new_user()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_art  text := coalesce(new.raw_user_meta_data->>'kontoart','privat');
  v_web  text := nullif(trim(coalesce(new.raw_user_meta_data->>'website','')),'');
  v_ort  text := nullif(trim(coalesce(new.raw_user_meta_data->>'verein_ort','')),'');
  v_stat text := 'privat';
  v_dom  text;
  v_basis text;
  v_user text;
  v_versuch int := 0;
  v_name text;
  v_geb  date;
  v_sozial boolean := coalesce(new.raw_app_meta_data->>'provider','email') in ('apple','google');
begin
  if exists (select 1 from public.gesperrte_emails g
              where g.hash = md5(lower(coalesce(new.email,''))) and g.bis > now()) then
    raise exception 'SPOTOUT_GESPERRTE_EMAIL';
  end if;
  begin
    v_geb := nullif(new.raw_user_meta_data->>'birthdate','')::date;
  exception when others then v_geb := null;
  end;
  if v_art not in ('privat','verein') or v_sozial then
    v_art := 'privat';
  end if;

  if v_art = 'verein' then
    if v_web is null or v_ort is null then
      v_art := 'privat';
    else
      v_dom := lower(split_part(new.email,'@',2));
      if ist_freimail(v_dom) or not domain_passt(new.email, v_web) then
        v_stat := 'handpruefung';
      else
        v_stat := 'neu';
      end if;
    end if;
  end if;

  -- Kleinbuchstaben, Ziffern, Punkt, Unterstrich, Bindestrich und
  -- Buchstaben mit Umlaut/Akzent; mindestens drei Zeichen.
  v_basis := lower(coalesce(new.raw_user_meta_data->>'username',
                            split_part(coalesce(new.email,''),'@',1)));
  v_basis := regexp_replace(v_basis, '[^a-z0-9._ß-öø-ÿ-]', '', 'g');
  v_basis := regexp_replace(v_basis, '\.{2,}', '.', 'g');
  v_basis := btrim(v_basis, '.');
  if length(v_basis) < 3 then v_basis := 'spotout'; end if;
  v_basis := btrim(left(v_basis, 20), '.');

  v_user := v_basis;
  while exists (select 1 from public.profiles p where p.username = v_user) loop
    v_versuch := v_versuch + 1;
    v_user := left(v_basis, 15) || '_' || lpad(floor(random()*10000)::text, 4, '0');
    if v_versuch > 30 then
      v_user := 'spotout_' || replace(new.id::text, '-', '');
      exit;
    end if;
  end loop;

  -- Apple und Google liefern den Namen unter verschiedenen Schlüsseln.
  v_name := coalesce(new.raw_user_meta_data->>'full_name',
                     new.raw_user_meta_data->>'name',
                     '');

  -- E-Mail: Geburtsdatum Pflicht. Apple/Google: wird in der App nachgetragen.
  if v_art = 'privat' and ((v_geb is null and not v_sozial)
                           or v_geb > (current_date - interval '16 years')::date) then
    raise exception 'SPOTOUT_MINDESTALTER';
  end if;

  insert into public.profiles (id, username, full_name, avatar_url, birthdate,
                               kontoart, website, verein_ort, verein_status)
  values (new.id,
          v_user,
          v_name,
          coalesce(new.raw_user_meta_data->>'avatar_url',
                   new.raw_user_meta_data->>'picture',
                   ''),
          case when v_art = 'privat' then v_geb end,
          v_art,
          case when v_art='verein' then v_web else null end,
          case when v_art='verein' then v_ort else null end,
          case when v_art='verein' then v_stat else 'privat' end);
  return new;
end $function$;

commit;

-- Prüfen (sollte 0 Zeilen liefern):
--   select policyname from pg_policies where policyname = 'Altersgrenze: Partys sehen';
--
-- Rückgängig machen von 1) (18+ wieder vor Jüngeren verstecken):
--   create policy "Altersgrenze: Partys sehen" on public.events as restrictive for select
--     using (mindestalter is null or created_by = (select auth.uid())
--            or public.alter_reicht(mindestalter, (select auth.uid())));
