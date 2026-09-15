-- SPOTOUT — Profilbesuche wie auf TikTok (Pro)
-- Pro sieht, wer in den letzten 30 Tagen auf dem Profil war. Wer die Einstellung
-- ausschaltet, wird bei anderen nicht mehr gezaehlt und sieht selbst niemanden mehr.
-- Dazu: Zieht jemand eine Follow-Anfrage zurueck, verschwindet die Meldung beim Gegenueber.

alter table public.profiles add column if not exists besuche_an boolean not null default true;
alter table public.profiles add column if not exists besuche_gesehen_am timestamptz;

create table if not exists public.profil_besuche (
  profil_id   uuid not null references public.profiles(id) on delete cascade,
  besucher_id uuid not null references public.profiles(id) on delete cascade,
  zuletzt     timestamptz not null default now(),
  primary key (profil_id, besucher_id)
);
create index if not exists profil_besuche_profil_idx on public.profil_besuche (profil_id, zuletzt desc);
alter table public.profil_besuche enable row level security;   -- nur ueber die Funktionen

create or replace function public.profil_besucht(p_id uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $$
declare ich uuid := auth.uid();
begin
  if ich is null or p_id is null or ich = p_id then return; end if;
  if not coalesce((select besuche_an from profiles where id = ich), false) then return; end if;
  if not exists (select 1 from profiles where id = p_id) then return; end if;
  if public.blockiert(ich, p_id) then return; end if;
  insert into profil_besuche (profil_id, besucher_id, zuletzt) values (p_id, ich, now())
  on conflict (profil_id, besucher_id) do update set zuletzt = excluded.zuletzt;
  delete from profil_besuche where profil_id = p_id and zuletzt < now() - interval '30 days';
end $$;
revoke all on function public.profil_besucht(uuid) from public, anon;
grant execute on function public.profil_besucht(uuid) to authenticated;

create or replace function public.meine_besucher()
 returns jsonb language plpgsql security definer set search_path to 'public'
as $$
declare
  ich uuid := auth.uid();
  me record;
  liste jsonb;
  neu int;
begin
  if ich is null then return jsonb_build_object('status','nicht_angemeldet'); end if;
  select is_pro, besuche_an, besuche_gesehen_am into me from profiles where id = ich;
  if not coalesce(me.is_pro,false) then return jsonb_build_object('status','kein_pro'); end if;
  if not coalesce(me.besuche_an,false) then return jsonb_build_object('status','aus'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'username', p.username, 'full_name', p.full_name, 'avatar_url', p.avatar_url,
           'is_pro', coalesce(p.is_pro,false), 'zuletzt', b.zuletzt,
           'neu', (me.besuche_gesehen_am is null or b.zuletzt > me.besuche_gesehen_am),
           'ich_folge', exists (select 1 from follows f where f.follower_id = ich and f.following_id = p.id),
           'folgt_mir', exists (select 1 from follows f where f.follower_id = p.id and f.following_id = ich),
           'angefragt', exists (select 1 from follow_anfragen a where a.von = ich and a.an = p.id),
           'privat', coalesce(p.privat,false)
         ) order by b.zuletzt desc), '[]'::jsonb),
         count(*) filter (where me.besuche_gesehen_am is null or b.zuletzt > me.besuche_gesehen_am)
    into liste, neu
    from profil_besuche b
    join profiles p on p.id = b.besucher_id
   where b.profil_id = ich
     and b.zuletzt > now() - interval '30 days'
     and coalesce(p.besuche_an,false)
     and not public.blockiert(ich, p.id);

  return jsonb_build_object('status','ok','besucher',liste,'neu',neu);
end $$;
revoke all on function public.meine_besucher() from public, anon;
grant execute on function public.meine_besucher() to authenticated;

create or replace function public.besucher_gesehen()
 returns void language sql security definer set search_path to 'public'
as $$ update profiles set besuche_gesehen_am = now() where id = auth.uid(); $$;
revoke all on function public.besucher_gesehen() from public, anon;
grant execute on function public.besucher_gesehen() to authenticated;

create or replace function public.besucher_neu()
 returns int language sql stable security definer set search_path to 'public'
as $$
  select case when coalesce(me.is_pro,false) and coalesce(me.besuche_an,false) then
    (select count(*)::int from profil_besuche b join profiles p on p.id = b.besucher_id
      where b.profil_id = me.id and b.zuletzt > now() - interval '30 days'
        and (me.besuche_gesehen_am is null or b.zuletzt > me.besuche_gesehen_am)
        and coalesce(p.besuche_an,false) and not public.blockiert(me.id, p.id))
  else 0 end
  from profiles me where me.id = auth.uid();
$$;
revoke all on function public.besucher_neu() from public, anon;
grant execute on function public.besucher_neu() to authenticated;

create or replace function public.besuche_ausgeschaltet()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if coalesce(old.besuche_an,true) and not coalesce(new.besuche_an,true) then
    delete from profil_besuche where besucher_id = new.id;
  end if;
  return new;
end $$;
revoke all on function public.besuche_ausgeschaltet() from public, anon, authenticated;
drop trigger if exists zz_besuche_ausgeschaltet_trg on public.profiles;
create trigger zz_besuche_ausgeschaltet_trg after update of besuche_an on public.profiles
  for each row execute function public.besuche_ausgeschaltet();

create or replace function public.anfrage_zurueckgezogen()
 returns trigger language plpgsql security definer set search_path to 'public'
as $$
begin
  if auth.uid() is not null and auth.uid() = old.von then
    delete from notifications
     where user_id = old.an and actor_id = old.von and art = 'folge_anfrage';
  end if;
  return old;
end $$;
revoke all on function public.anfrage_zurueckgezogen() from public, anon, authenticated;
drop trigger if exists zz_anfrage_zurueckgezogen_trg on public.follow_anfragen;
create trigger zz_anfrage_zurueckgezogen_trg after delete on public.follow_anfragen
  for each row execute function public.anfrage_zurueckgezogen();

-- Angenommen: aus "möchte dir folgen" wird "folgt dir jetzt" – dieselbe Zeile, keine zweite.
-- Gelöscht: die Anfrage verschwindet auch aus den Benachrichtigungen.
-- (angewendet als anfrage_meldung_umwandeln)
create or replace function public.anfrage_beantworten(p_von uuid, p_ja boolean)
 returns text language plpgsql security definer set search_path to 'public'
as $function$
declare
  ich uuid := auth.uid();
  nm text;
  wer text;
begin
  if ich is null then return 'nicht_angemeldet'; end if;

  if not exists (select 1 from follow_anfragen a where a.von = p_von and a.an = ich) then
    return 'keine_anfrage';
  end if;

  delete from follow_anfragen where von = p_von and an = ich;

  if not p_ja then
    delete from notifications where user_id = ich and actor_id = p_von and art = 'folge_anfrage';
    return 'abgelehnt';
  end if;

  perform set_config('spotout.zusage', 'ja', true);
  insert into follows(follower_id, following_id) values (p_von, ich)
  on conflict do nothing;
  perform set_config('spotout.zusage', '', true);

  select coalesce(nullif(trim(full_name),''), username) into wer from profiles where id = p_von;
  update notifications
     set art = 'neuer_follower', titel = coalesce(wer,'Jemand') || ' folgt dir jetzt', text = '', gelesen = true
   where user_id = ich and actor_id = p_von and art = 'folge_anfrage';

  select coalesce(nullif(trim(full_name),''), username) into nm
  from profiles where id = ich;

  insert into notifications(user_id, actor_id, art, titel, text)
  values (p_von, ich, 'folge_zusage',
          coalesce(nm,'Jemand') || ' hat deine Anfrage angenommen',
          'Ihr seid jetzt verbunden');

  return 'angenommen';
end;
$function$;
