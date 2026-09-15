-- SPOTOUT — Folgen wie auf Instagram
--
-- - get_follow_stats liefert zusaetzlich folgt_dir ("Folgt dir" / "Auch folgen")
-- - folge_status(ids): fuer Follower-Listen der Stand zu mir, fuer alle auf einmal
-- - Neuer Follower bekommt eine Benachrichtigung "X folgt dir jetzt"
--   (nicht aus einer angenommenen Anfrage, hoechstens einmal pro Woche pro Person)

drop function if exists public.get_follow_stats(uuid, uuid);
create function public.get_follow_stats(p_user_id uuid, p_viewer_id uuid default null)
 returns table(followers bigint, following bigint, viewer_follows boolean, folgt_dir boolean)
 language plpgsql stable security definer set search_path to 'public'
as $$
declare
  ziel_privat boolean;
  darf boolean;
begin
  select privat into ziel_privat from profiles where id = p_user_id;
  darf := (not coalesce(ziel_privat,false))
       or (p_viewer_id is not null
           and (p_viewer_id = p_user_id or sind_verbunden(p_viewer_id, p_user_id)));

  return query select
    case when darf then (select count(*) from follows f where f.following_id = p_user_id) else 0::bigint end,
    case when darf then (select count(*) from follows f where f.follower_id  = p_user_id) else 0::bigint end,
    (p_viewer_id is not null and exists (select 1 from follows f
       where f.follower_id = p_viewer_id and f.following_id = p_user_id)),
    (p_viewer_id is not null and exists (select 1 from follows f
       where f.follower_id = p_user_id and f.following_id = p_viewer_id));
end;
$$;
revoke all on function public.get_follow_stats(uuid, uuid) from public;
grant execute on function public.get_follow_stats(uuid, uuid) to anon, authenticated;

create or replace function public.folge_status(p_ids uuid[])
 returns table(id uuid, ich_folge boolean, folgt_mir boolean, angefragt boolean, privat boolean)
 language sql stable security definer set search_path to 'public'
as $$
  select p.id,
         exists (select 1 from follows f where f.follower_id = auth.uid() and f.following_id = p.id),
         exists (select 1 from follows f where f.follower_id = p.id and f.following_id = auth.uid()),
         exists (select 1 from follow_anfragen a where a.von = auth.uid() and a.an = p.id),
         coalesce(p.privat, false)
    from profiles p
   where auth.uid() is not null
     and p.id = any(coalesce(p_ids, '{}'))
   limit 500;
$$;
revoke all on function public.folge_status(uuid[]) from public, anon;
grant execute on function public.folge_status(uuid[]) to authenticated;

create or replace function public.melde_neuer_follower()
 returns trigger
 language plpgsql security definer set search_path to 'public'
as $$
declare nm text;
begin
  if coalesce(current_setting('spotout.zusage', true),'') = 'ja' then
    return new;
  end if;
  if exists (select 1 from notifications n
              where n.user_id = new.following_id and n.actor_id = new.follower_id
                and n.art = 'neuer_follower' and n.created_at > now() - interval '7 days') then
    return new;
  end if;
  select coalesce(nullif(trim(full_name),''), username) into nm from profiles where id = new.follower_id;
  begin
    perform public.notify(new.following_id, new.follower_id, null, 'neuer_follower',
      coalesce(nm,'Jemand') || ' folgt dir jetzt', '');
  exception when others then null;
  end;
  return new;
end $$;
revoke all on function public.melde_neuer_follower() from public, anon, authenticated;

drop trigger if exists melde_neuer_follower_trg on public.follows;
create trigger melde_neuer_follower_trg
  after insert on public.follows
  for each row execute function public.melde_neuer_follower();
