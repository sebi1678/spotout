-- SPOTOUT — Party-Fotos
--
-- Abgemacht:
--   - Nur Gäste (und der Gastgeber) laden hoch, höchstens 10 Fotos pro Person,
--     ab Partybeginn.
--   - Nur Gäste sehen die Fotos und können sie herunterladen. Niemand sonst.
--   - 27 Stunden nach Partybeginn ist alles weg, Datei und Eintrag.
--   - "Das bin ich – entfernen" wirkt sofort, der Gastgeber kann löschen,
--     jedes Foto lässt sich melden.
--
-- Der Speicher ist privat. Bilder gibt es nur über kurzlebige, signierte
-- Adressen, und die bekommt nur, wer das Foto sehen darf.
-- Gelöscht wird über die Edge Function fotos-aufraeumen (Supabase erlaubt
-- kein direktes Löschen in storage.objects).

-- ── Speicher ──────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('party-fotos', 'party-fotos', false, 3145728, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ── Tabelle ───────────────────────────────────────────────────────────
create table if not exists public.party_fotos (
  id             uuid primary key default gen_random_uuid(),
  -- set null statt cascade: verschwindet die Party vor dem Aufräumen,
  -- bleibt der Eintrag, bis auch die Datei weg ist.
  event_id       uuid references public.events(id) on delete set null,
  uploader       uuid references public.profiles(id) on delete set null,
  pfad           text not null unique,
  breite         int,
  hoehe          int,
  created_at     timestamptz not null default now(),
  loeschen_ab    timestamptz not null,
  entfernt_am    timestamptz,
  entfernt_von   uuid,
  entfernt_grund text check (entfernt_grund in ('selbst','gastgeber','bin_drauf','betreiber'))
);
create index if not exists party_fotos_event_idx on public.party_fotos (event_id, created_at);
create index if not exists party_fotos_loeschen_idx on public.party_fotos (loeschen_ab);
create index if not exists party_fotos_uploader_idx on public.party_fotos (uploader);

alter table public.party_fotos enable row level security;

-- ── Interne Helfer (nicht von aussen aufrufbar) ───────────────────────
-- Beginn in Schweizer Zeit, Schluss 27 Stunden später.
create or replace function public.foto_fenster(p_event uuid)
 returns table(beginn timestamptz, schluss timestamptz, gastgeber uuid)
 language sql stable security definer set search_path to 'public'
as $$
  select ((e.date + coalesce(e.time, time '20:00')) at time zone 'Europe/Zurich'),
         ((e.date + coalesce(e.time, time '20:00')) at time zone 'Europe/Zurich') + interval '27 hours',
         e.created_by
    from public.events e
   where e.id = p_event;
$$;

create or replace function public.foto_gast_fuer(p_event uuid, p_uid uuid)
 returns boolean
 language sql stable security definer set search_path to 'public'
as $$
  select p_uid is not null and exists (
    select 1 from public.foto_fenster(p_event) f
     where f.gastgeber = p_uid
        or exists (select 1 from public.event_attendees a
                    where a.event_id = p_event and a.user_id = p_uid)
  );
$$;

create or replace function public.foto_offen_fuer(p_event uuid, p_uid uuid)
 returns boolean
 language sql stable security definer set search_path to 'public'
as $$
  select public.foto_gast_fuer(p_event, p_uid)
     and exists (select 1 from public.foto_fenster(p_event) f
                  where now() >= f.beginn and now() < f.schluss);
$$;

create or replace function public.foto_zeigen_fuer(p_foto uuid, p_uid uuid)
 returns boolean
 language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.party_fotos f
     where f.id = p_foto
       and f.entfernt_am is null
       and f.loeschen_ab > now()
       and (
         (public.foto_offen_fuer(f.event_id, p_uid)
            and not public.blockiert(p_uid, f.uploader))
         -- Der Betreiber sieht ein Foto nur, wenn es gemeldet wurde.
         or (exists (select 1 from public.profiles p where p.id = p_uid and p.ist_admin)
             and exists (select 1 from public.reports r
                          where r.target_art = 'photo' and r.target_id = f.id))
       )
  );
$$;

revoke all on function public.foto_fenster(uuid)            from public, anon, authenticated;
revoke all on function public.foto_gast_fuer(uuid, uuid)    from public, anon, authenticated;
revoke all on function public.foto_offen_fuer(uuid, uuid)   from public, anon, authenticated;
revoke all on function public.foto_zeigen_fuer(uuid, uuid)  from public, anon, authenticated;

-- ── Für Regeln und App (immer nur für sich selbst) ────────────────────
create or replace function public.foto_zeigen(p_foto uuid)
 returns boolean
 language sql stable security definer set search_path to 'public'
as $$ select public.foto_zeigen_fuer(p_foto, auth.uid()); $$;

create or replace function public.foto_pfad_zeigen(p_name text)
 returns boolean
 language sql stable security definer set search_path to 'public'
as $$
  select exists (select 1 from public.party_fotos f
                  where f.pfad = p_name and public.foto_zeigen_fuer(f.id, auth.uid()));
$$;

-- Pfad: <event_id>/<user_id>/<zufall>.jpg
create or replace function public.foto_darf_hochladen(p_event text)
 returns boolean
 language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_uid   uuid := auth.uid();
  v_event uuid;
begin
  if v_uid is null or p_event is null
     or p_event !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  v_event := p_event::uuid;
  if not public.foto_offen_fuer(v_event, v_uid) then return false; end if;
  return (select count(*) from public.party_fotos
           where event_id = v_event and uploader = v_uid) < 10
     and (select count(*) from storage.objects o
           where o.bucket_id = 'party-fotos'
             and o.name like p_event || '/' || v_uid::text || '/%') < 12;
end $$;

grant execute on function public.foto_zeigen(uuid)          to authenticated;
grant execute on function public.foto_pfad_zeigen(text)     to authenticated;
grant execute on function public.foto_darf_hochladen(text)  to authenticated;
-- "from public" gehoert dazu: Postgres gibt EXECUTE sonst jedem.
revoke all on function public.foto_zeigen(uuid)         from public, anon;
revoke all on function public.foto_pfad_zeigen(text)    from public, anon;
revoke all on function public.foto_darf_hochladen(text) from public, anon;
grant execute on function public.foto_zeigen(uuid)          to authenticated;
grant execute on function public.foto_pfad_zeigen(text)     to authenticated;
grant execute on function public.foto_darf_hochladen(text)  to authenticated;

-- ── Regeln ────────────────────────────────────────────────────────────
drop policy if exists "Fotos fuer Gaeste" on public.party_fotos;
create policy "Fotos fuer Gaeste" on public.party_fotos
  for select to authenticated using (public.foto_zeigen(id));
-- Schreiben nur über die Funktionen unten.

drop policy if exists "party-fotos: Gaeste laden hoch" on storage.objects;
create policy "party-fotos: Gaeste laden hoch" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'party-fotos'
    and (storage.foldername(name))[2] = auth.uid()::text
    and public.foto_darf_hochladen((storage.foldername(name))[1])
  );

drop policy if exists "party-fotos: Gaeste sehen" on storage.objects;
create policy "party-fotos: Gaeste sehen" on storage.objects
  for select to authenticated
  using (bucket_id = 'party-fotos' and public.foto_pfad_zeigen(name));

-- ── Geheimnis für den Aufruf der Aufräum-Function ─────────────────────
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'fotos_aufraeumen_geheimnis') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'),
      'fotos_aufraeumen_geheimnis', 'Aufruf der Edge Function fotos-aufraeumen');
  end if;
end $$;

create or replace function public.fotos_geheimnis()
 returns text
 language sql stable security definer set search_path to 'public'
as $$
  select decrypted_secret from vault.decrypted_secrets
   where name = 'fotos_aufraeumen_geheimnis' limit 1;
$$;
revoke all on function public.fotos_geheimnis() from public, anon, authenticated;
grant execute on function public.fotos_geheimnis() to service_role;

create or replace function public.fotos_aufraeumen_anstossen()
 returns void
 language plpgsql security definer set search_path to 'public'
as $$
begin
  perform net.http_post(
    url     := 'https://tuxyyrlxjkxabhvremqu.supabase.co/functions/v1/fotos-aufraeumen',
    body    := '{}'::jsonb,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-spotout-geheimnis', public.fotos_geheimnis()),
    timeout_milliseconds := 60000
  );
exception when others then
  -- Aufräumen darf nie eine Aktion in der App scheitern lassen.
  null;
end $$;
revoke all on function public.fotos_aufraeumen_anstossen() from public, anon, authenticated;

-- Dateien ohne Eintrag (Hochladen abgebrochen) – für die Function
create or replace function public.fotos_waisen(p_limit int default 200)
 returns table(name text)
 language sql stable security definer set search_path to 'public'
as $$
  select o.name from storage.objects o
   where o.bucket_id = 'party-fotos'
     and o.created_at < now() - interval '2 hours'
     and not exists (select 1 from public.party_fotos f where f.pfad = o.name)
   limit greatest(1, least(coalesce(p_limit, 200), 1000));
$$;
revoke all on function public.fotos_waisen(int) from public, anon, authenticated;
grant execute on function public.fotos_waisen(int) to service_role;

-- ── Aktionen aus der App ──────────────────────────────────────────────
create or replace function public.foto_status(p_event uuid)
 returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_uid uuid := auth.uid();
  f record;
begin
  if v_uid is null or not public.foto_gast_fuer(p_event, v_uid) then
    return jsonb_build_object('gast', false);
  end if;
  select * into f from public.foto_fenster(p_event);
  return jsonb_build_object(
    'gast', true,
    'gastgeber', f.gastgeber = v_uid,
    'beginn', f.beginn,
    'schluss', f.schluss,
    'jetzt', now(),
    'eigene', (select count(*) from public.party_fotos
                where event_id = p_event and uploader = v_uid),
    'max', 10);
end $$;
revoke all on function public.foto_status(uuid) from public, anon;
grant execute on function public.foto_status(uuid) to authenticated;

create or replace function public.foto_eintragen(p_pfad text, p_breite int default null, p_hoehe int default null)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare
  v_uid    uuid := auth.uid();
  v_teile  text[];
  v_event  uuid;
  v_schluss timestamptz;
  v_id     uuid;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'meldung', 'Bitte melde dich an.');
  end if;
  v_teile := string_to_array(coalesce(p_pfad, ''), '/');
  if coalesce(array_length(v_teile, 1), 0) <> 3
     or v_teile[2] <> v_uid::text
     or v_teile[1] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return jsonb_build_object('ok', false, 'meldung', 'Das Foto konnte nicht gespeichert werden.');
  end if;
  v_event := v_teile[1]::uuid;

  if not exists (select 1 from storage.objects
                  where bucket_id = 'party-fotos' and name = p_pfad and owner = v_uid) then
    return jsonb_build_object('ok', false, 'meldung', 'Das Foto konnte nicht gespeichert werden.');
  end if;
  if not public.foto_offen_fuer(v_event, v_uid) then
    return jsonb_build_object('ok', false,
      'meldung', 'Fotos gehen nur für Gäste, ab Partybeginn und 27 Stunden lang.');
  end if;
  if (select count(*) from public.party_fotos
       where event_id = v_event and uploader = v_uid) >= 10 then
    return jsonb_build_object('ok', false, 'meldung', 'Du hast schon 10 Fotos hochgeladen.');
  end if;

  select schluss into v_schluss from public.foto_fenster(v_event);
  insert into public.party_fotos (event_id, uploader, pfad, breite, hoehe, loeschen_ab)
  values (v_event, v_uid, p_pfad,
          nullif(greatest(coalesce(p_breite, 0), 0), 0),
          nullif(greatest(coalesce(p_hoehe, 0), 0), 0),
          v_schluss)
  on conflict (pfad) do nothing
  returning id into v_id;

  return jsonb_build_object('ok', v_id is not null, 'id', v_id);
end $$;
revoke all on function public.foto_eintragen(text, int, int) from public, anon;
grant execute on function public.foto_eintragen(text, int, int) to authenticated;

-- Wer darf entfernen? Wer es hochgeladen hat, der Gastgeber, der Betreiber –
-- und jeder Gast, der das Foto sieht ("Das bin ich").
create or replace function public.foto_entfernen(p_foto uuid)
 returns jsonb
 language plpgsql security definer set search_path to 'public'
as $$
declare
  v_uid   uuid := auth.uid();
  v_grund text;
  f       record;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'meldung', 'Bitte melde dich an.');
  end if;
  select pf.*, e.created_by as gastgeber
    into f
    from public.party_fotos pf
    left join public.events e on e.id = pf.event_id
   where pf.id = p_foto;
  if not found or f.entfernt_am is not null then
    return jsonb_build_object('ok', true, 'grund', 'schon_weg');
  end if;

  if f.uploader = v_uid then
    v_grund := 'selbst';
  elsif f.gastgeber = v_uid then
    v_grund := 'gastgeber';
  elsif exists (select 1 from public.profiles p where p.id = v_uid and p.ist_admin) then
    v_grund := 'betreiber';
  elsif public.foto_zeigen_fuer(p_foto, v_uid) then
    v_grund := 'bin_drauf';
  else
    return jsonb_build_object('ok', false, 'meldung', 'Das darfst du nicht.');
  end if;

  update public.party_fotos
     set entfernt_am = now(), entfernt_von = v_uid,
         entfernt_grund = v_grund, loeschen_ab = now()
   where id = p_foto;

  -- Wer das Foto gemacht hat, erfährt es – aber nicht, von wem.
  if v_grund in ('bin_drauf','gastgeber','betreiber') and f.uploader is not null then
    begin
      perform public.notify(f.uploader, null, f.event_id, 'foto_entfernt',
        'Ein Foto von dir wurde entfernt',
        case v_grund
          when 'bin_drauf' then 'Jemand darauf wollte nicht in der Galerie sein. Danke fürs Verständnis.'
          else 'Es passte nicht in die Galerie dieser Party.'
        end);
    exception when others then null;
    end;
  end if;

  perform public.fotos_aufraeumen_anstossen();
  return jsonb_build_object('ok', true, 'grund', v_grund);
end $$;
revoke all on function public.foto_entfernen(uuid) from public, anon;
grant execute on function public.foto_entfernen(uuid) to authenticated;

-- ── Konto gelöscht: seine Fotos sofort mit ────────────────────────────
create or replace function public.fotos_bei_kontoloeschung()
 returns trigger
 language plpgsql security definer set search_path to 'public'
as $$
begin
  update public.party_fotos
     set entfernt_am = coalesce(entfernt_am, now()),
         entfernt_grund = coalesce(entfernt_grund, 'selbst'),
         loeschen_ab = now()
   where uploader = old.id;
  if found then perform public.fotos_aufraeumen_anstossen(); end if;
  return old;
end $$;
revoke all on function public.fotos_bei_kontoloeschung() from public, anon, authenticated;

drop trigger if exists fotos_bei_kontoloeschung_trg on public.profiles;
create trigger fotos_bei_kontoloeschung_trg
  before delete on public.profiles
  for each row execute function public.fotos_bei_kontoloeschung();

-- ── Alle 15 Minuten aufräumen ─────────────────────────────────────────
do $$
begin
  if exists (select 1 from cron.job where jobname = 'fotos-aufraeumen') then
    perform cron.unschedule('fotos-aufraeumen');
  end if;
  perform cron.schedule('fotos-aufraeumen', '*/15 * * * *',
    'select public.fotos_aufraeumen_anstossen()');
end $$;
