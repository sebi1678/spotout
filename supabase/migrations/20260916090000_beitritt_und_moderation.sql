-- SPOTOUT — Beitritt nur mit Bestaetigung & automatische Moderation
--
-- A · Private Party ueber Einladungslink: der Host bestaetigt jede Person.
-- B · Melden: Verwarnung -> 7 Tage Sperre -> dauerhafte Sperre, automatisch.
--     Zaehlen nur verschiedene Melder mit Konten aelter als 24 h, und nach
--     jeder Stufe braucht es neue Meldungen. Schwere Meldungen blenden den
--     Inhalt sofort aus. Die gemeldete Person sieht Inhalt, Gruende und
--     Datum – nie, wer gemeldet hat. Der Betreiber kann alles aufheben.

-- ══════════ A · Beitritt ══════════
create table if not exists public.event_beitritt_anfragen (
  id             uuid primary key default gen_random_uuid(),
  event_id       uuid not null references public.events(id) on delete cascade,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  link_id        uuid references public.event_invite_links(id) on delete set null,
  status         text not null default 'offen' check (status in ('offen','angenommen','abgelehnt')),
  created_at     timestamptz not null default now(),
  entschieden_am timestamptz,
  unique (event_id, user_id)
);
create index if not exists event_beitritt_anfragen_event_idx on public.event_beitritt_anfragen (event_id, status);
alter table public.event_beitritt_anfragen enable row level security;
drop policy if exists "Beitrittsanfragen sehen" on public.event_beitritt_anfragen;
create policy "Beitrittsanfragen sehen" on public.event_beitritt_anfragen
  for select to authenticated using (user_id = auth.uid() or public.ist_host(event_id, auth.uid()));

-- ══════════ B · Moderation: Spalten ══════════
alter table public.profiles    add column if not exists gesperrt_bis timestamptz;
alter table public.events      add column if not exists ausgeblendet boolean not null default false;
alter table public.party_fotos add column if not exists ausgeblendet boolean not null default false;
alter table public.messages    add column if not exists ausgeblendet boolean not null default false;
alter table public.reports     add column if not exists ziel_user uuid references public.profiles(id) on delete cascade;
create index if not exists reports_ziel_idx on public.reports (ziel_user, status, created_at);

create or replace function public.ist_gesperrt(p_user uuid)
 returns boolean language sql stable security definer set search_path to 'public'
as $$ select coalesce((select gesperrt_bis > now() from public.profiles where id = p_user), false); $$;
revoke all on function public.ist_gesperrt(uuid) from public, anon;
grant execute on function public.ist_gesperrt(uuid) to authenticated;

-- Nutzer duerfen die Sperre nicht selbst aufheben
create or replace function public.guard_pro_columns()
 returns trigger language plpgsql set search_path to 'public'
as $$
begin
  if current_user in ('postgres','supabase_admin','service_role')
     or coalesce(current_setting('request.jwt.claims', true)::json->>'role','') = 'service_role' then
    return new;
  end if;
  new.is_pro                          := old.is_pro;
  new.pro_probe                       := old.pro_probe;
  new.probe_verbraucht                := old.probe_verbraucht;
  new.gebuehrenfrei                   := old.gebuehrenfrei;
  new.subscription_status             := old.subscription_status;
  new.stripe_customer_id              := old.stripe_customer_id;
  new.stripe_subscription_id          := old.stripe_subscription_id;
  new.subscription_current_period_end := old.subscription_current_period_end;
  new.pro_updated_at                  := old.pro_updated_at;
  new.verified                        := old.verified;
  new.day_one                         := old.day_one;
  new.ist_admin                       := old.ist_admin;
  new.verein_status                   := old.verein_status;
  new.website                         := old.website;
  new.gesperrt_bis                    := old.gesperrt_bis;
  return new;
end;
$$;

-- Ausgeblendet setzt nur die Moderation, nie der Besitzer
create or replace function public.guard_moderation_spalten()
 returns trigger language plpgsql set search_path to 'public'
as $$
begin
  if current_user not in ('postgres','supabase_admin','service_role') then
    new.ausgeblendet := old.ausgeblendet;
  end if;
  return new;
end $$;
drop trigger if exists guard_moderation_spalten_trg on public.events;
create trigger guard_moderation_spalten_trg before update on public.events
  for each row execute function public.guard_moderation_spalten();
drop trigger if exists guard_moderation_spalten_trg on public.messages;
create trigger guard_moderation_spalten_trg before update on public.messages
  for each row execute function public.guard_moderation_spalten();
drop trigger if exists guard_moderation_spalten_trg on public.party_fotos;
create trigger guard_moderation_spalten_trg before update on public.party_fotos
  for each row execute function public.guard_moderation_spalten();

-- ── Gesperrte schreiben nichts (zusaetzliche, einschraenkende Regeln) ──
drop policy if exists "Gesperrt: keine Partys" on public.events;
create policy "Gesperrt: keine Partys" on public.events as restrictive for insert to authenticated
  with check (not public.ist_gesperrt(auth.uid()));
drop policy if exists "Gesperrt: Partys nicht aendern" on public.events;
create policy "Gesperrt: Partys nicht aendern" on public.events as restrictive for update to authenticated
  using (not public.ist_gesperrt(auth.uid()));
drop policy if exists "Gesperrt: keine Nachrichten" on public.messages;
create policy "Gesperrt: keine Nachrichten" on public.messages as restrictive for insert to authenticated
  with check (not public.ist_gesperrt(auth.uid()));
drop policy if exists "Gesperrt: keine Anmeldung" on public.event_attendees;
create policy "Gesperrt: keine Anmeldung" on public.event_attendees as restrictive for insert to authenticated
  with check (not public.ist_gesperrt(auth.uid()));
drop policy if exists "Gesperrt: keine Gespraeche" on public.conversations;
create policy "Gesperrt: keine Gespraeche" on public.conversations as restrictive for insert to authenticated
  with check (not public.ist_gesperrt(auth.uid()));
drop policy if exists "Gesperrt: keine Nachrichtenanfragen" on public.message_requests;
create policy "Gesperrt: keine Nachrichtenanfragen" on public.message_requests as restrictive for insert to authenticated
  with check (not public.ist_gesperrt(auth.uid()));
drop policy if exists "Gesperrt: nicht folgen" on public.follows;
create policy "Gesperrt: nicht folgen" on public.follows as restrictive for insert to authenticated
  with check (not public.ist_gesperrt(auth.uid()));
drop policy if exists "Gesperrt: keine Begleitanfragen" on public.event_guest_requests;
create policy "Gesperrt: keine Begleitanfragen" on public.event_guest_requests as restrictive for insert to authenticated
  with check (not public.ist_gesperrt(auth.uid()));
drop policy if exists "Gesperrt: nicht melden" on public.reports;
create policy "Gesperrt: nicht melden" on public.reports as restrictive for insert to authenticated
  with check (not public.ist_gesperrt(auth.uid()));
drop policy if exists "Gesperrt: Mitbringliste" on public.event_items;
create policy "Gesperrt: Mitbringliste" on public.event_items as restrictive for update to authenticated
  using (not public.ist_gesperrt(auth.uid()));

-- ── Ausgeblendetes sieht nur der Besitzer (und der Betreiber) ──
drop policy if exists "Moderation: Partys ausblenden" on public.events;
create policy "Moderation: Partys ausblenden" on public.events as restrictive for select to anon, authenticated
  using (
    created_by = auth.uid()
    or (not ausgeblendet
        and not exists (select 1 from public.profiles h
                         where h.id = events.created_by and h.gesperrt_bis = 'infinity'::timestamptz))
    or exists (select 1 from public.profiles a where a.id = auth.uid() and a.ist_admin)
  );
drop policy if exists "Moderation: Nachrichten ausblenden" on public.messages;
create policy "Moderation: Nachrichten ausblenden" on public.messages as restrictive for select to authenticated
  using (not ausgeblendet or sender_id = auth.uid());

create or replace function public.foto_zeigen_fuer(p_foto uuid, p_uid uuid)
 returns boolean language sql stable security definer set search_path to 'public'
as $$
  select exists (
    select 1 from public.party_fotos f
     where f.id = p_foto
       and f.entfernt_am is null
       and f.loeschen_ab > now()
       and (
         (public.foto_offen_fuer(f.event_id, p_uid)
            and not f.ausgeblendet
            and not public.blockiert(p_uid, f.uploader))
         or (exists (select 1 from public.profiles p where p.id = p_uid and p.ist_admin)
             and exists (select 1 from public.reports r
                          where r.target_art = 'photo' and r.target_id = f.id))
       )
  );
$$;
revoke all on function public.foto_zeigen_fuer(uuid, uuid) from public, anon, authenticated;

create or replace function public.foto_darf_hochladen(p_event text)
 returns boolean language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_uid   uuid := auth.uid();
  v_event uuid;
begin
  if v_uid is null or p_event is null
     or p_event !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  if public.ist_gesperrt(v_uid) then return false; end if;
  v_event := p_event::uuid;
  if not public.foto_offen_fuer(v_event, v_uid) then return false; end if;
  return (select count(*) from public.party_fotos
           where event_id = v_event and uploader = v_uid) < 10
     and (select count(*) from storage.objects o
           where o.bucket_id = 'party-fotos'
             and o.name like p_event || '/' || v_uid::text || '/%') < 12;
end $$;
revoke all on function public.foto_darf_hochladen(text) from public, anon;
grant execute on function public.foto_darf_hochladen(text) to authenticated;

-- ══════════ A · Beitritt: Funktionen ══════════
create or replace function public.join_by_invite(p_code text)
 returns table(ev_id uuid, ergebnis text)
 language plpgsql security definer set search_path to 'public'
as $$
declare
  ev record;
  cnt int;
  link record;
  anfrage record;
  wer text;
  p_norm text := upper(trim(p_code));
begin
  if auth.uid() is null then
    return query select null::uuid, 'nicht_angemeldet'::text; return;
  end if;
  if public.ist_gesperrt(auth.uid()) then
    return query select null::uuid, 'gesperrt'::text; return;
  end if;

  select l.* into link from event_invite_links l where upper(l.code) = p_norm for update;

  if link.id is not null then
    if link.used_by is not null and link.used_by <> auth.uid() then
      return query select link.event_id, 'link_verbraucht'::text; return;
    end if;
    select e.id as id, e.capacity as capacity, e.registration_deadline as dl,
           e.type as typ, e.name as name, e.created_by as host
      into ev from events e where e.id = link.event_id;
  else
    select e.id as id, e.capacity as capacity, e.registration_deadline as dl,
           e.type as typ, e.name as name, e.created_by as host
      into ev
      from events e
     where e.invite_code is not null
       and upper(e.invite_code) = p_norm
       and e.nur_persoenliche_links = false
     limit 1;
  end if;

  if ev.id is null then
    return query select null::uuid, 'code_ungueltig'::text; return;
  end if;

  if exists (select 1 from event_attendees a where a.event_id = ev.id and a.user_id = auth.uid()) then
    if link.id is not null and link.used_by is null then
      update event_invite_links set used_by = auth.uid(), used_at = now() where id = link.id;
    end if;
    return query select ev.id, 'schon_dabei'::text; return;
  end if;

  if ev.dl is not null and now() > ev.dl then
    return query select ev.id, 'frist_abgelaufen'::text; return;
  end if;

  select coalesce(sum(1 + coalesce(a.plus_ones,0)),0) into cnt from event_attendees a where a.event_id = ev.id;
  if ev.capacity is not null and cnt >= ev.capacity then
    return query select ev.id, 'voll'::text; return;
  end if;

  -- Private Party: der Host bestaetigt jede Person, die ueber einen Link kommt
  if ev.typ = 'private' and ev.host is distinct from auth.uid() then
    select * into anfrage from event_beitritt_anfragen b where b.event_id = ev.id and b.user_id = auth.uid();
    if anfrage.id is not null and anfrage.status = 'abgelehnt' then
      return query select ev.id, 'abgelehnt'::text; return;
    end if;
    if anfrage.id is null then
      insert into event_beitritt_anfragen (event_id, user_id, link_id) values (ev.id, auth.uid(), link.id);
      select coalesce(nullif(trim(full_name),''), username, 'Jemand') into wer from profiles where id = auth.uid();
      perform public.notify(ev.host, auth.uid(), ev.id, 'beitritt_anfrage',
        wer || ' möchte zu ' || ev.name, 'Über deinen Einladungslink · bitte kurz bestätigen');
    end if;
    if link.id is not null and link.used_by is null then
      update event_invite_links set used_by = auth.uid(), used_at = now() where id = link.id;
    end if;
    return query select ev.id, 'angefragt'::text; return;
  end if;

  insert into event_attendees(event_id, user_id) values (ev.id, auth.uid()) on conflict do nothing;
  if link.id is not null then
    update event_invite_links set used_by = auth.uid(), used_at = now() where id = link.id;
  end if;
  return query select ev.id, 'beigetreten'::text;
end;
$$;
revoke all on function public.join_by_invite(text) from public, anon;
grant execute on function public.join_by_invite(text) to authenticated;

create or replace function public.beitritt_entscheiden(p_anfrage uuid, p_ja boolean)
 returns text language plpgsql security definer set search_path to 'public'
as $$
declare
  a record;
  ev record;
  host_nm text;
begin
  select * into a from event_beitritt_anfragen where id = p_anfrage for update;
  if a.id is null then return 'gibt_es_nicht'; end if;
  select id, name, created_by into ev from events where id = a.event_id;
  if ev.created_by is distinct from auth.uid() then return 'nur_gastgeber'; end if;
  if a.status <> 'offen' then return 'schon_entschieden'; end if;
  select coalesce(nullif(trim(full_name),''), username, 'Der Host') into host_nm from profiles where id = auth.uid();

  if p_ja then
    begin
      insert into event_attendees(event_id, user_id) values (a.event_id, a.user_id) on conflict do nothing;
    exception when others then
      if sqlerrm like '%SPOTOUT_PARTY_VOLL%' then return 'voll'; end if;
      raise;
    end;
    update event_beitritt_anfragen set status = 'angenommen', entschieden_am = now() where id = a.id;
    perform public.notify(a.user_id, auth.uid(), a.event_id, 'beitritt_ok',
      'Du bist dabei: ' || ev.name, host_nm || ' hat dich bestätigt');
    return 'angenommen';
  end if;

  update event_beitritt_anfragen set status = 'abgelehnt', entschieden_am = now() where id = a.id;
  update event_invite_links set used_by = null, used_at = null where id = a.link_id and used_by = a.user_id;
  perform public.notify(a.user_id, auth.uid(), null, 'beitritt_nein',
    'Diesmal nicht: ' || ev.name, 'Der Host hat deine Anfrage abgelehnt');
  return 'abgelehnt';
end $$;
revoke all on function public.beitritt_entscheiden(uuid, boolean) from public, anon;
grant execute on function public.beitritt_entscheiden(uuid, boolean) to authenticated;

drop function if exists public.get_event_by_invite(text);
create function public.get_event_by_invite(p_code text)
 returns table(id uuid, name text, type text, category text, ev_date date, ev_time time without time zone,
               address text, lat double precision, lng double precision, price numeric, drink_price numeric,
               drink_desc text, capacity integer, description text, emoji text, image_url text, host_name text,
               created_by uuid, registration_deadline timestamptz, host_username text, host_full_name text,
               host_avatar text, attending bigint, already_in boolean, link_persoenlich boolean,
               link_verbraucht boolean, link_fuer text, spotify_url text, beitritt_status text)
 language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_ev uuid;
  v_pers boolean := false;
  v_used boolean := false;
  v_fuer text;
  p_norm text := upper(trim(p_code));
begin
  select l.event_id, (l.used_by is not null and l.used_by is distinct from auth.uid()), l.label
    into v_ev, v_used, v_fuer
    from event_invite_links l where upper(l.code) = p_norm limit 1;

  if v_ev is not null then
    v_pers := true;
  else
    select e.id into v_ev from events e
     where e.invite_code is not null and upper(e.invite_code) = p_norm and e.nur_persoenliche_links = false
     limit 1;
  end if;
  if v_ev is null then return; end if;

  return query
  select e.id, e.name, e.type, e.category, e.date, e."time",
         e.address, e.lat, e.lng, e.price, e.drink_price, e.drink_desc, e.capacity,
         e.description, e.emoji, e.image_url, e.host_name,
         e.created_by, e.registration_deadline,
         p.username, p.full_name, p.avatar_url,
         (select count(*) from event_attendees a where a.event_id = e.id),
         exists (select 1 from event_attendees a where a.event_id = e.id and a.user_id = auth.uid()),
         v_pers, v_used, v_fuer, e.spotify_url,
         (select b.status from event_beitritt_anfragen b where b.event_id = e.id and b.user_id = auth.uid())
    from events e
    left join profiles p on p.id = e.created_by
   where e.id = v_ev;
end;
$$;
revoke all on function public.get_event_by_invite(text) from public;
grant execute on function public.get_event_by_invite(text) to anon, authenticated;

-- ══════════ B · Moderation: Sanktionen ══════════
create table if not exists public.sanktionen (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles(id) on delete cascade,
  stufe           int  not null check (stufe between 1 and 3),
  art             text not null check (art in ('verwarnung','sperre_7_tage','sperre_dauerhaft')),
  gruende         text[] not null default '{}',
  details         jsonb  not null default '[]'::jsonb,
  report_ids      uuid[] not null default '{}',
  gesperrt_bis    timestamptz,
  created_at      timestamptz not null default now(),
  gesehen_am      timestamptz,
  aufgehoben_am   timestamptz,
  aufgehoben_von  uuid
);
create index if not exists sanktionen_user_idx on public.sanktionen (user_id, created_at desc);
alter table public.sanktionen enable row level security;
drop policy if exists "Eigene Sanktionen" on public.sanktionen;
create policy "Eigene Sanktionen" on public.sanktionen for select to authenticated
  using (user_id = auth.uid() or exists (select 1 from public.profiles a where a.id = auth.uid() and a.ist_admin));

create or replace function public.meldegrund_text(p_key text)
 returns text language sql immutable set search_path to 'public'
as $$
  select case p_key
    when 'belaestigung'          then 'Belästigung oder Drohung'
    when 'hass'                  then 'Hass oder Beleidigung'
    when 'sexuell'               then 'Sexuelle Inhalte'
    when 'fake_profil'           then 'Falsches Profil oder fremde Fotos'
    when 'unter16'               then 'Jünger als 16'
    when 'spam'                  then 'Spam, Werbung oder Betrug'
    when 'betrug'                then 'Betrug'
    when 'erfunden'              then 'Party gibt es nicht oder ist Abzocke'
    when 'falsch'                then 'Falsche Angaben'
    when 'falsche_angaben'       then 'Falsche Angaben (Ort, Zeit, Preis)'
    when 'gefaehrlich'           then 'Gefährlich: Gewalt, Waffen, Drogen'
    when 'gewalt'                then 'Gewalt oder Drogen'
    when 'ohne_einverstaendnis'  then 'Zeigt jemanden ohne Einverständnis'
    else 'Verstoss gegen die Community-Regeln'
  end;
$$;

-- Vor dem Speichern: wem gehoert der Inhalt? Keine Selbstmeldung, kein Massenmelden
create or replace function public.melden_vorbereiten()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
declare v_heute int;
begin
  new.ziel_user := case new.target_art
    when 'user'    then new.target_id
    when 'event'   then (select created_by from public.events where id = new.target_id)
    when 'photo'   then (select uploader from public.party_fotos where id = new.target_id)
    when 'message' then (select sender_id from public.messages where id = new.target_id)
  end;
  if new.ziel_user is not null and new.ziel_user = new.reporter_id then
    raise exception 'SPOTOUT_SELBST_MELDEN';
  end if;
  select count(*) into v_heute from public.reports
   where reporter_id = new.reporter_id and created_at > now() - interval '24 hours';
  if v_heute >= 20 then
    raise exception 'SPOTOUT_ZU_VIELE_MELDUNGEN';
  end if;
  return new;
end $$;
revoke all on function public.melden_vorbereiten() from public, anon, authenticated;
drop trigger if exists melden_vorbereiten_trg on public.reports;
create trigger melden_vorbereiten_trg before insert on public.reports
  for each row execute function public.melden_vorbereiten();

create or replace function public.moderation_nach_meldung()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
declare
  v_schwer  boolean;
  v_letzte  timestamptz;
  v_stufe   int;
  v_anzahl  int;
  v_ids     uuid[];
  v_art     text;
  v_bis     timestamptz;
  v_details jsonb;
  v_gruende text[];
  v_admin   record;
begin
  -- 1 · Schwere Meldung: Inhalt sofort ausblenden, Betreiber informieren
  v_schwer := new.grund in ('sexuell','gewalt')
           or coalesce(new.gruende,'{}') && array['unter16','gefaehrlich','ohne_einverstaendnis'];
  if v_schwer then
    if new.target_art = 'event' then
      update public.events set ausgeblendet = true where id = new.target_id;
    elsif new.target_art = 'photo' then
      update public.party_fotos set ausgeblendet = true where id = new.target_id;
    elsif new.target_art = 'message' then
      update public.messages set ausgeblendet = true where id = new.target_id;
    end if;
    for v_admin in select id from public.profiles where ist_admin loop
      begin
        perform public.notify(v_admin.id, null, null, 'meldung_schwer',
          'Schwere Meldung: ' || public.meldegrund_text(coalesce(new.gruende[array_length(new.gruende,1)], new.grund)),
          case when new.target_art = 'user' then 'Ein Konto wurde gemeldet · Tipp an, um zu prüfen'
               else 'Der Inhalt ist ausgeblendet · Tipp an, um zu prüfen' end);
      exception when others then null;
      end;
    end loop;
  end if;

  -- 2 · Stufen: Verwarnung -> 7 Tage -> dauerhaft
  if new.ziel_user is null then return new; end if;
  if exists (select 1 from public.profiles where id = new.ziel_user and ist_admin) then return new; end if;

  select max(created_at), coalesce(max(stufe), 0) into v_letzte, v_stufe
    from public.sanktionen where user_id = new.ziel_user and aufgehoben_am is null;
  if v_stufe >= 3 then return new; end if;

  select array_agg(r.id), count(distinct r.reporter_id)
    into v_ids, v_anzahl
    from public.reports r
    join public.profiles p on p.id = r.reporter_id
   where r.ziel_user = new.ziel_user
     and r.status = 'offen'
     and r.created_at >= coalesce(v_letzte, '-infinity'::timestamptz)
     and r.created_at > now() - interval '30 days'
     and p.created_at < now() - interval '24 hours'
     and not coalesce(p.gesperrt_bis > now(), false);
  if coalesce(v_anzahl, 0) < 2 then return new; end if;

  v_stufe := v_stufe + 1;
  v_art := case v_stufe when 1 then 'verwarnung' when 2 then 'sperre_7_tage' else 'sperre_dauerhaft' end;
  v_bis := case v_stufe when 2 then now() + interval '7 days' when 3 then 'infinity'::timestamptz else null end;

  with rr as (
    select r.target_art, r.target_id, min(r.created_at) as datum,
           array_agg(distinct coalesce(r.gruende[array_length(r.gruende,1)], r.grund)) as keys
      from public.reports r
     where r.id = any(v_ids)
     group by r.target_art, r.target_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'art', rr.target_art,
           'titel', case rr.target_art
              when 'event'   then coalesce((select 'Deine Party „' || e.name || '“' from public.events e where e.id = rr.target_id), 'Eine Party von dir')
              when 'photo'   then 'Ein Party-Foto von dir'
              when 'message' then coalesce((select 'Deine Nachricht: „' || left(m.content, 80) || '“' from public.messages m where m.id = rr.target_id), 'Eine Nachricht von dir')
              else 'Dein Profil'
            end,
           'gruende', (select jsonb_agg(public.meldegrund_text(k)) from unnest(rr.keys) k),
           'datum', to_char(rr.datum at time zone 'Europe/Zurich', 'DD.MM.YYYY')
         ) order by rr.datum), '[]'::jsonb)
    into v_details
    from rr;

  select coalesce(array_agg(distinct x), '{}') into v_gruende
    from public.reports r, unnest(r.gruende) x where r.id = any(v_ids);

  insert into public.sanktionen (user_id, stufe, art, gruende, details, report_ids, gesperrt_bis)
  values (new.ziel_user, v_stufe, v_art, v_gruende, v_details, v_ids, v_bis);

  if v_bis is not null then
    update public.profiles set gesperrt_bis = v_bis where id = new.ziel_user;
  end if;
  update public.reports set status = 'geprueft', bearbeitet_am = now() where id = any(v_ids);

  begin
    perform public.notify(new.ziel_user, null, null, 'sanktion',
      case v_stufe when 1 then 'Verwarnung von SPOTOUT'
                   when 2 then 'Dein Konto ist 7 Tage gesperrt'
                   else 'Dein Konto ist gesperrt' end,
      'Öffne SPOTOUT, um zu sehen, worum es geht.');
  exception when others then null;
  end;
  return new;
end $$;
revoke all on function public.moderation_nach_meldung() from public, anon, authenticated;
drop trigger if exists moderation_nach_meldung_trg on public.reports;
create trigger moderation_nach_meldung_trg after insert on public.reports
  for each row execute function public.moderation_nach_meldung();

-- ── Fuer die App: eigene Verwarnung oder Sperre ──
create or replace function public.meine_sanktion()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare s record;
begin
  if auth.uid() is null then return null; end if;
  select * into s from public.sanktionen
   where user_id = auth.uid() and aufgehoben_am is null
     and ((gesperrt_bis is not null and gesperrt_bis > now()) or gesehen_am is null)
   order by (gesperrt_bis is not null and gesperrt_bis > now()) desc, created_at desc
   limit 1;
  if s.id is null then return null; end if;
  return jsonb_build_object(
    'id', s.id, 'art', s.art, 'stufe', s.stufe,
    'gesperrt', coalesce(s.gesperrt_bis > now(), false),
    'dauerhaft', coalesce(s.gesperrt_bis = 'infinity'::timestamptz, false),
    'gesperrt_bis', case when s.gesperrt_bis = 'infinity'::timestamptz then null else s.gesperrt_bis end,
    'details', s.details, 'erstellt', s.created_at);
end $$;
revoke all on function public.meine_sanktion() from public, anon;
grant execute on function public.meine_sanktion() to authenticated;

create or replace function public.sanktion_gesehen(p_id uuid)
 returns void language sql security definer set search_path to 'public'
as $$ update public.sanktionen set gesehen_am = coalesce(gesehen_am, now()) where id = p_id and user_id = auth.uid(); $$;
revoke all on function public.sanktion_gesehen(uuid) from public, anon;
grant execute on function public.sanktion_gesehen(uuid) to authenticated;

-- ── Fuer den Betreiber ──
create or replace function public.moderation_uebersicht()
 returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and ist_admin) then
    raise exception 'SPOTOUT_NUR_BETREIBER';
  end if;
  return jsonb_build_object(
    'meldungen', coalesce((
      select jsonb_agg(x order by x->>'created_at' desc) from (
        select jsonb_build_object(
          'id', r.id, 'created_at', r.created_at, 'art', r.target_art, 'target_id', r.target_id,
          'status', r.status, 'notiz', r.notiz,
          'gruende', (select jsonb_agg(public.meldegrund_text(k)) from unnest(r.gruende) k),
          'ziel', (select coalesce(nullif(trim(full_name),''), username) from public.profiles where id = r.ziel_user),
          'ziel_user', r.ziel_user,
          'melder', (select username from public.profiles where id = r.reporter_id),
          'titel', case r.target_art
             when 'event'   then (select name from public.events where id = r.target_id)
             when 'message' then (select left(content, 120) from public.messages where id = r.target_id)
             when 'photo'   then 'Party-Foto'
             else 'Profil' end,
          'ausgeblendet', case r.target_art
             when 'event'   then (select ausgeblendet from public.events where id = r.target_id)
             when 'message' then (select ausgeblendet from public.messages where id = r.target_id)
             when 'photo'   then (select ausgeblendet from public.party_fotos where id = r.target_id)
             else false end
        ) as x
        from public.reports r
        where r.created_at > now() - interval '60 days'
        order by r.created_at desc
        limit 100
      ) t), '[]'::jsonb),
    'sanktionen', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id, 'art', s.art, 'stufe', s.stufe, 'created_at', s.created_at,
        'dauerhaft', s.gesperrt_bis = 'infinity'::timestamptz,
        'gesperrt_bis', case when s.gesperrt_bis = 'infinity'::timestamptz then null else s.gesperrt_bis end,
        'aufgehoben', s.aufgehoben_am is not null,
        'wer', (select coalesce(nullif(trim(full_name),''), username) from public.profiles where id = s.user_id),
        'details', s.details) order by s.created_at desc)
        from public.sanktionen s where s.created_at > now() - interval '90 days'), '[]'::jsonb)
  );
end $$;
revoke all on function public.moderation_uebersicht() from public, anon;
grant execute on function public.moderation_uebersicht() to authenticated;

create or replace function public.sanktion_aufheben(p_id uuid)
 returns text language plpgsql security definer set search_path to 'public'
as $$
declare s record;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and ist_admin) then
    return 'nur_betreiber';
  end if;
  select * into s from public.sanktionen where id = p_id for update;
  if s.id is null or s.aufgehoben_am is not null then return 'nichts_zu_tun'; end if;
  update public.sanktionen set aufgehoben_am = now(), aufgehoben_von = auth.uid() where id = p_id;
  -- Die Meldungen dahinter zaehlen nicht mehr
  update public.reports set status = 'abgelehnt', bearbeitet_am = now() where id = any(s.report_ids);
  -- Sperre aufheben, sofern keine andere Sperre aktiv bleibt
  update public.profiles p
     set gesperrt_bis = (select max(x.gesperrt_bis) from public.sanktionen x
                          where x.user_id = s.user_id and x.aufgehoben_am is null and x.gesperrt_bis > now())
   where p.id = s.user_id;
  begin
    perform public.notify(s.user_id, null, null, 'sanktion_aufgehoben',
      case when s.stufe = 1 then 'Verwarnung zurückgenommen' else 'Deine Sperre ist aufgehoben' end,
      'Nach einer Prüfung durch SPOTOUT.');
  exception when others then null;
  end;
  return 'aufgehoben';
end $$;
revoke all on function public.sanktion_aufheben(uuid) from public, anon;
grant execute on function public.sanktion_aufheben(uuid) to authenticated;

create or replace function public.meldung_erledigen(p_report uuid, p_aktion text)
 returns text language plpgsql security definer set search_path to 'public'
as $$
declare r record;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and ist_admin) then
    return 'nur_betreiber';
  end if;
  select * into r from public.reports where id = p_report;
  if r.id is null then return 'gibt_es_nicht'; end if;
  if p_aktion = 'einblenden' then
    if r.target_art = 'event' then update public.events set ausgeblendet = false where id = r.target_id;
    elsif r.target_art = 'photo' then update public.party_fotos set ausgeblendet = false where id = r.target_id;
    elsif r.target_art = 'message' then update public.messages set ausgeblendet = false where id = r.target_id;
    end if;
    update public.reports set status = 'abgelehnt', bearbeitet_am = now()
     where target_art = r.target_art and target_id = r.target_id and status = 'offen';
    return 'eingeblendet';
  elsif p_aktion = 'abweisen' then
    update public.reports set status = 'abgelehnt', bearbeitet_am = now() where id = r.id;
    return 'abgewiesen';
  elsif p_aktion = 'entfernen' then
    if r.target_art = 'event' then delete from public.events where id = r.target_id;
    elsif r.target_art = 'photo' then
      update public.party_fotos set entfernt_am = now(), entfernt_von = auth.uid(),
             entfernt_grund = 'betreiber', loeschen_ab = now() where id = r.target_id;
      perform public.fotos_aufraeumen_anstossen();
    elsif r.target_art = 'message' then update public.messages set ausgeblendet = true where id = r.target_id;
    end if;
    update public.reports set status = 'entfernt', bearbeitet_am = now()
     where target_art = r.target_art and target_id = r.target_id;
    return 'entfernt';
  end if;
  return 'unbekannt';
end $$;
revoke all on function public.meldung_erledigen(uuid, text) from public, anon;
grant execute on function public.meldung_erledigen(uuid, text) to authenticated;
