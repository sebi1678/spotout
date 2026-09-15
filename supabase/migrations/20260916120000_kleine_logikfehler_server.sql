-- SPOTOUT — kleine Logikfehler auf dem Server (angewendet als kleine_logikfehler_server)
-- 1 · Austragen hinterlaesst nichts (Mitbringsel, +1, Beitrittsanfrage, Warteliste)
-- 2 · Blockieren trennt Folgen; profil_ansehen/folgen_anfragen/guard kennen Blockierungen;
--     Gespraeche mit Blockierten sind auf beiden Seiten ausgeblendet
-- 3 · Von privat auf oeffentlich: offene Anfragen werden Follower
-- 4 · Einladungsseite zaehlt Begleitpersonen mit
-- 5 · join_by_invite: nach dem Austragen wird neu beim Host angefragt

create or replace function public.gast_ausgetragen()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if not exists (select 1 from public.events e where e.id = old.event_id) then
    return old;                         -- Party wird gerade geloescht
  end if;
  update public.event_items set claimed_by = null, claimed_at = null
   where event_id = old.event_id and claimed_by = old.user_id;
  delete from public.event_guest_requests where event_id = old.event_id and user_id = old.user_id;
  delete from public.event_beitritt_anfragen where event_id = old.event_id and user_id = old.user_id and status <> 'abgelehnt';
  delete from public.event_waitlist where event_id = old.event_id and user_id = old.user_id;
  return old;
exception when others then
  return old;
end $$;
revoke all on function public.gast_ausgetragen() from public, anon, authenticated;
drop trigger if exists zz_gast_ausgetragen_trg on public.event_attendees;
create trigger zz_gast_ausgetragen_trg after delete on public.event_attendees
  for each row execute function public.gast_ausgetragen();

create or replace function public.block_trennt_folgen()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  delete from public.follows
   where (follower_id = new.blocker_id and following_id = new.blocked_id)
      or (follower_id = new.blocked_id and following_id = new.blocker_id);
  delete from public.follow_anfragen
   where (von = new.blocker_id and an = new.blocked_id)
      or (von = new.blocked_id and an = new.blocker_id);
  return new;
end $$;
revoke all on function public.block_trennt_folgen() from public, anon, authenticated;
drop trigger if exists block_trennt_folgen_trg on public.blocks;
create trigger block_trennt_folgen_trg after insert on public.blocks
  for each row execute function public.block_trennt_folgen();
delete from public.follows f using public.blocks b
 where (f.follower_id = b.blocker_id and f.following_id = b.blocked_id)
    or (f.follower_id = b.blocked_id and f.following_id = b.blocker_id);
delete from public.follow_anfragen a using public.blocks b
 where (a.von = b.blocker_id and a.an = b.blocked_id)
    or (a.von = b.blocked_id and a.an = b.blocker_id);

create or replace function public.guard_privates_folgen()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare
  ziel_privat boolean;
begin
  if auth.uid() is null then
    return new;
  end if;
  if public.blockiert(new.follower_id, new.following_id) then
    raise exception 'SPOTOUT_BLOCKIERT';
  end if;
  if coalesce(current_setting('spotout.zusage', true),'') = 'ja' then
    return new;                        -- kommt aus anfrage_beantworten
  end if;
  select privat into ziel_privat from profiles where id = new.following_id;
  if not coalesce(ziel_privat,false) then
    return new;
  end if;
  raise exception 'SPOTOUT_ANFRAGE_NOETIG';
end;
$function$;

create or replace function public.folgen_anfragen(p_an uuid)
 returns text language plpgsql security definer set search_path to 'public'
as $function$
declare
  ich uuid := auth.uid();
  ziel_privat boolean;
  nm text;
begin
  if ich is null then return 'nicht_angemeldet'; end if;
  if public.ist_gesperrt(ich) then return 'gesperrt'; end if;
  if ich = p_an then return 'nicht_du_selbst'; end if;
  if public.blockiert(ich, p_an) then return 'blockiert'; end if;

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
$function$;

create or replace function public.profil_ansehen(p_id uuid)
 returns table(id uuid, username text, full_name text, avatar_url text, is_pro boolean, day_one boolean, kontoart text, website text, verein_ort text, bio text, instagram_handle text, snapchat_handle text, facebook_handle text, privat boolean, offen boolean, anfrage_laeuft boolean)
 language plpgsql stable security definer set search_path to 'public'
as $function$
declare
  ich uuid := auth.uid();
  p record;
  darf boolean;
begin
  select * into p from profiles pr where pr.id = p_id;
  if p.id is null then return; end if;

  darf := ((not coalesce(p.privat,false))
       or (ich is not null and (ich = p_id or sind_verbunden(ich, p_id))))
     and not (ich is not null and ich <> p_id and public.blockiert(ich, p_id));

  return query select
    p.id, p.username, p.full_name, p.avatar_url, p.is_pro,
    coalesce(p.day_one,false),
    p.kontoart, p.website, p.verein_ort,
    case when darf then p.bio              else null end,
    case when darf then p.instagram_handle else null end,
    case when darf then p.snapchat_handle  else null end,
    case when darf then p.facebook_handle  else null end,
    coalesce(p.privat,false), darf,
    (ich is not null and exists (select 1 from follow_anfragen a
                                 where a.von = ich and a.an = p_id));
end;
$function$;

drop policy if exists "Blockiert: Gespraeche ausblenden" on public.conversations;
create policy "Blockiert: Gespraeche ausblenden" on public.conversations as restrictive for select to anon, authenticated
  using (not public.blockiert(user1_id, user2_id));

create or replace function public.privat_aufgehoben()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if coalesce(old.privat,false) and not coalesce(new.privat,false) then
    perform set_config('spotout.zusage', 'ja', true);
    insert into public.follows(follower_id, following_id)
      select a.von, new.id from public.follow_anfragen a
       where a.an = new.id and not public.blockiert(a.von, new.id)
      on conflict do nothing;
    perform set_config('spotout.zusage', '', true);
    delete from public.follow_anfragen where an = new.id;
  end if;
  return new;
end $$;
revoke all on function public.privat_aufgehoben() from public, anon, authenticated;
drop trigger if exists zz_privat_aufgehoben_trg on public.profiles;
create trigger zz_privat_aufgehoben_trg after update of privat on public.profiles
  for each row execute function public.privat_aufgehoben();

create or replace function public.get_event_by_invite(p_code text)
 returns table(id uuid, name text, type text, category text, ev_date date, ev_time time without time zone, address text, lat double precision, lng double precision, price numeric, drink_price numeric, drink_desc text, capacity integer, description text, emoji text, image_url text, host_name text, created_by uuid, registration_deadline timestamp with time zone, host_username text, host_full_name text, host_avatar text, attending bigint, already_in boolean, link_persoenlich boolean, link_verbraucht boolean, link_fuer text, spotify_url text, beitritt_status text)
 language plpgsql stable security definer set search_path to 'public'
as $function$
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
         (select coalesce(sum(1 + coalesce(a.plus_ones,0)),0)::bigint from event_attendees a where a.event_id = e.id),
         exists (select 1 from event_attendees a where a.event_id = e.id and a.user_id = auth.uid()),
         v_pers, v_used, v_fuer, e.spotify_url,
         (select b.status from event_beitritt_anfragen b where b.event_id = e.id and b.user_id = auth.uid())
    from events e
    left join profiles p on p.id = e.created_by
   where e.id = v_ev;
end;
$function$;
grant execute on function public.get_event_by_invite(text) to anon, authenticated;

create or replace function public.join_by_invite(p_code text)
 returns table(ev_id uuid, ergebnis text)
 language plpgsql security definer set search_path to 'public'
as $function$
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

  if ev.typ = 'private' and ev.host is distinct from auth.uid() then
    if public.blockiert(auth.uid(), ev.host) then
      return query select null::uuid, 'code_ungueltig'::text; return;
    end if;
    select * into anfrage from event_beitritt_anfragen b where b.event_id = ev.id and b.user_id = auth.uid();
    if anfrage.id is not null and anfrage.status = 'abgelehnt' then
      return query select ev.id, 'abgelehnt'::text; return;
    end if;
    if anfrage.id is not null and anfrage.status = 'angenommen' then
      delete from event_beitritt_anfragen where id = anfrage.id;
      anfrage := null;
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
$function$;
grant execute on function public.join_by_invite(text) to authenticated;
