-- SPOTOUT — 24 Stunden, Besucht-Archiv, Abzeichen
--
-- - Party und Fotos verschwinden 24 Stunden nach Partybeginn.
-- - Wer dabei war (auch der Host), behaelt die Party unter "Besucht".
-- - Abzeichen werden automatisch vergeben (Partymaus, Mitbringer, ...).
-- - Gesperrte Konten folgen niemandem.

-- ══════════ Folgen: nicht mit Sperre ══════════
create or replace function public.folgen_anfragen(p_an uuid)
 returns text language plpgsql security definer set search_path to 'public'
as $$
declare
  ich uuid := auth.uid();
  ziel_privat boolean;
  nm text;
begin
  if ich is null then return 'nicht_angemeldet'; end if;
  if public.ist_gesperrt(ich) then return 'gesperrt'; end if;
  if ich = p_an then return 'nicht_du_selbst'; end if;

  select privat into ziel_privat from profiles where id = p_an;
  if ziel_privat is null then return 'gibt_es_nicht'; end if;

  if exists (select 1 from follows f where f.follower_id = ich and f.following_id = p_an) then
    return 'folgst_schon';
  end if;

  if not ziel_privat then
    insert into follows(follower_id, following_id) values (ich, p_an) on conflict do nothing;
    return 'folgt';
  end if;

  insert into follow_anfragen(von, an) values (ich, p_an) on conflict do nothing;
  select coalesce(nullif(trim(full_name),''), username) into nm from profiles where id = ich;
  insert into notifications(user_id, actor_id, art, titel, text)
  select p_an, ich, 'folge_anfrage', coalesce(nm,'Jemand') || ' möchte dir folgen', 'Tipp an, um zu entscheiden'
   where not exists (select 1 from notifications n
                      where n.user_id = p_an and n.actor_id = ich and n.art = 'folge_anfrage'
                        and n.created_at > now() - interval '7 days');
  return 'angefragt';
end;
$$;
revoke all on function public.folgen_anfragen(uuid) from public, anon;
grant execute on function public.folgen_anfragen(uuid) to authenticated;

-- ══════════ 24 Stunden ══════════
create or replace function public.foto_fenster(p_event uuid)
 returns table(beginn timestamptz, schluss timestamptz, gastgeber uuid)
 language sql stable security definer set search_path to 'public'
as $$
  select ((e.date + coalesce(e.time, time '20:00')) at time zone 'Europe/Zurich'),
         ((e.date + coalesce(e.time, time '20:00')) at time zone 'Europe/Zurich') + interval '24 hours',
         e.created_by
    from public.events e
   where e.id = p_event;
$$;
revoke all on function public.foto_fenster(uuid) from public, anon, authenticated;

update public.party_fotos f
   set loeschen_ab = least(f.loeschen_ab,
         ((e.date + coalesce(e.time, time '20:00')) at time zone 'Europe/Zurich') + interval '24 hours')
  from public.events e
 where e.id = f.event_id;

create or replace function public.delete_old_events()
 returns void language plpgsql security definer set search_path to 'public'
as $$
declare weg int;
begin
  delete from public.events e
   where ((e.date + coalesce(e.time, time '20:00')) at time zone 'Europe/Zurich') + interval '24 hours' < now();
  get diagnostics weg = row_count;
  if weg > 0 then
    raise notice 'delete_old_events: % Partys entfernt', weg;
  end if;
end;
$$;
revoke all on function public.delete_old_events() from public, anon, authenticated;

-- "wurde abgesagt" nur, wenn die Party noch nicht angefangen hat
create or replace function public.notify_event_deleted()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
declare r record;
begin
  if ((old.date + coalesce(old.time, time '20:00')) at time zone 'Europe/Zurich') <= now() then
    return old;
  end if;
  for r in select user_id from public.event_attendees where event_id = old.id loop
    insert into public.notifications(user_id, actor_id, event_id, art, titel, text)
    values (r.user_id, old.created_by, null, 'event_gone',
            old.name || ' wurde abgesagt', 'Der Host hat die Party gelöscht');
  end loop;
  return old;
end $$;
revoke all on function public.notify_event_deleted() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'delete-old-events') then
    perform cron.unschedule('delete-old-events');
  end if;
  perform cron.schedule('delete-old-events', '7 * * * *', 'select public.delete_old_events()');
end $$;

-- ══════════ Besucht-Archiv ══════════
-- Ohne Fremdschluessel auf profiles: sonst koennte eine Kontoloeschung, die
-- ueber die Partys des Hosts kaskadiert, am Archiv scheitern. Aufgeraeumt
-- wird unten per Trigger.
create table if not exists public.besucht_archiv (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null,
  event_id    uuid not null,
  name        text not null,
  category    text,
  emoji       text,
  type        text,
  datum       date,
  zeit        time,
  ort         text,
  image_url   text,
  war_host    boolean not null default false,
  gaeste_zahl int not null default 0,
  created_at  timestamptz not null default now(),
  unique (user_id, event_id)
);
create index if not exists besucht_archiv_user_idx on public.besucht_archiv (user_id, datum desc);
alter table public.besucht_archiv enable row level security;
drop policy if exists "Eigenes Archiv" on public.besucht_archiv;
create policy "Eigenes Archiv" on public.besucht_archiv for select to authenticated using (user_id = auth.uid());

-- ══════════ Abzeichen ══════════
create table if not exists public.abzeichen_stand (
  user_id     uuid primary key,
  besucht     int not null default 0,
  gehostet    int not null default 0,
  superhost   int not null default 0,
  mitgebracht int not null default 0,
  fotos       int not null default 0,
  nachteule   int not null default 0,
  updated_at  timestamptz not null default now()
);
alter table public.abzeichen_stand enable row level security;
drop policy if exists "Eigener Stand" on public.abzeichen_stand;
create policy "Eigener Stand" on public.abzeichen_stand for select to authenticated using (user_id = auth.uid());

create table if not exists public.abzeichen (
  user_id     uuid not null,
  schluessel  text not null,
  erhalten_am timestamptz not null default now(),
  primary key (user_id, schluessel)
);
alter table public.abzeichen enable row level security;
drop policy if exists "Abzeichen sichtbar" on public.abzeichen;
create policy "Abzeichen sichtbar" on public.abzeichen for select to anon, authenticated using (true);

create or replace function public.abzeichen_pruefen(p_user uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $$
declare
  s public.abzeichen_stand;
  v_follower int;
  r record;
begin
  if p_user is null or public.ist_verein(p_user) then return; end if;
  insert into public.abzeichen_stand (user_id) values (p_user) on conflict do nothing;
  select * into s from public.abzeichen_stand where user_id = p_user;
  select count(*) into v_follower from public.follows where following_id = p_user;

  for r in
    select * from (values
      ('neu_dabei',    s.besucht >= 1,     'Erste Party',  'Deine erste Party ist im Profil – willkommen!'),
      ('partymaus',    s.besucht >= 5,     'Partymaus',    '5 Partys besucht'),
      ('partylegende', s.besucht >= 20,    'Partylegende', '20 Partys besucht'),
      ('mitbringer',   s.mitgebracht >= 3, 'Mitbringer',   '3-mal etwas von der Mitbringliste mitgebracht'),
      ('gastgeber',    s.gehostet >= 1,    'Gastgeber',    'Deine erste eigene Party gefeiert'),
      ('superhost',    s.superhost >= 3,   'Superhost',    '3 Partys mit mindestens 10 Gästen'),
      ('fotograf',     s.fotos >= 10,      'Fotograf',     '10 Party-Fotos geteilt'),
      ('nachteule',    s.nachteule >= 3,   'Nachteule',    '3 Partys bis nach 2 Uhr'),
      ('beliebt',      v_follower >= 25,   'Beliebt',      '25 Follower')
    ) as t(k, erreicht, titel, text)
  loop
    if r.erreicht and not exists (select 1 from public.abzeichen where user_id = p_user and schluessel = r.k) then
      insert into public.abzeichen (user_id, schluessel) values (p_user, r.k) on conflict do nothing;
      begin
        perform public.notify(p_user, null, null, 'abzeichen', 'Neues Abzeichen: ' || r.titel, r.text);
      exception when others then null;
      end;
    end if;
  end loop;
end $$;
revoke all on function public.abzeichen_pruefen(uuid) from public, anon, authenticated;

-- Vor dem Loeschen einer gefeierten Party: Archiv und Abzeichen-Stand
create or replace function public.party_archivieren()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
declare
  v_start timestamptz := ((old.date + coalesce(old.time, time '20:00')) at time zone 'Europe/Zurich');
  v_nacht boolean := old.end_time is not null and old.end_time >= time '02:00' and old.end_time <= time '08:00';
  r record;
begin
  if v_start > now() then return old; end if;   -- abgesagt, nicht gefeiert
  for r in
    select a.user_id, (a.user_id = old.created_by) as host
      from public.event_attendees a where a.event_id = old.id
    union
    select old.created_by, true where old.created_by is not null
  loop
    begin
      insert into public.besucht_archiv (user_id, event_id, name, category, emoji, type, datum, zeit, ort,
                                         image_url, war_host, gaeste_zahl)
      values (r.user_id, old.id, old.name, old.category, old.emoji, old.type, old.date, old.time,
              nullif(trim(split_part(coalesce(old.address,''), ',', 1)), ''),
              old.image_url, r.host, coalesce(old.gaeste_zahl, 0))
      on conflict (user_id, event_id) do nothing;

      insert into public.abzeichen_stand (user_id) values (r.user_id) on conflict do nothing;
      update public.abzeichen_stand set
        besucht     = besucht   + case when r.host then 0 else 1 end,
        gehostet    = gehostet  + case when r.host then 1 else 0 end,
        superhost   = superhost + case when r.host and coalesce(old.gaeste_zahl,0) >= 10 then 1 else 0 end,
        nachteule   = nachteule + case when v_nacht then 1 else 0 end,
        mitgebracht = mitgebracht + (select count(*) from public.event_items i
                                      where i.event_id = old.id and i.claimed_by = r.user_id),
        updated_at  = now()
       where user_id = r.user_id;
      perform public.abzeichen_pruefen(r.user_id);
    exception when others then
      null;                                      -- nie das Loeschen verhindern
    end;
  end loop;
  return old;
end $$;
revoke all on function public.party_archivieren() from public, anon, authenticated;
drop trigger if exists party_archivieren_trg on public.events;
create trigger party_archivieren_trg before delete on public.events
  for each row execute function public.party_archivieren();

create or replace function public.abzeichen_foto()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if new.uploader is null then return new; end if;
  begin
    insert into public.abzeichen_stand (user_id) values (new.uploader) on conflict do nothing;
    update public.abzeichen_stand set fotos = fotos + 1, updated_at = now() where user_id = new.uploader;
    perform public.abzeichen_pruefen(new.uploader);
  exception when others then null;
  end;
  return new;
end $$;
revoke all on function public.abzeichen_foto() from public, anon, authenticated;
drop trigger if exists abzeichen_foto_trg on public.party_fotos;
create trigger abzeichen_foto_trg after insert on public.party_fotos
  for each row execute function public.abzeichen_foto();

create or replace function public.abzeichen_follower()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  begin
    perform public.abzeichen_pruefen(new.following_id);
  exception when others then null;
  end;
  return new;
end $$;
revoke all on function public.abzeichen_follower() from public, anon, authenticated;
drop trigger if exists abzeichen_follower_trg on public.follows;
create trigger abzeichen_follower_trg after insert on public.follows
  for each row execute function public.abzeichen_follower();

-- Konto geloescht: Archiv und Abzeichen mit weg (laeuft nach den Kaskaden)
create or replace function public.konto_spuren_aufraeumen()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  delete from public.besucht_archiv  where user_id = old.id;
  delete from public.abzeichen       where user_id = old.id;
  delete from public.abzeichen_stand where user_id = old.id;
  return old;
end $$;
revoke all on function public.konto_spuren_aufraeumen() from public, anon, authenticated;
drop trigger if exists zz_konto_spuren_aufraeumen_trg on public.profiles;
create trigger zz_konto_spuren_aufraeumen_trg after delete on public.profiles
  for each row execute function public.konto_spuren_aufraeumen();

-- Bereits vorhandene Follower-Zahlen einmal pruefen
do $$
declare r record;
begin
  for r in select following_id from public.follows group by following_id having count(*) >= 25 loop
    perform public.abzeichen_pruefen(r.following_id);
  end loop;
end $$;
