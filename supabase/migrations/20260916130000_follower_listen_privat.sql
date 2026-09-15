-- SPOTOUT — Follower-Listen nur, wenn man das Profil sehen darf (wie get_follow_stats)
-- Vorher war die Tabelle follows fuer alle lesbar: private Profile waren nur in der Oberflaeche zu.

create or replace function public.folge_liste(p_user uuid, p_art text)
 returns table(id uuid)
 language plpgsql stable security definer set search_path to 'public'
as $$
declare
  ich uuid := auth.uid();
  ziel_privat boolean;
begin
  select privat into ziel_privat from profiles where profiles.id = p_user;
  if ziel_privat is null then return; end if;
  if coalesce(ziel_privat,false)
     and not (ich is not null and (ich = p_user or sind_verbunden(ich, p_user))) then
    return;
  end if;
  if ich is not null and ich <> p_user and public.blockiert(ich, p_user) then
    return;
  end if;
  if p_art = 'followers' then
    return query select f.follower_id from follows f
      where f.following_id = p_user
        and (ich is null or not public.blockiert(ich, f.follower_id))
      order by f.created_at desc nulls last limit 200;
  else
    return query select f.following_id from follows f
      where f.follower_id = p_user
        and (ich is null or not public.blockiert(ich, f.following_id))
      order by f.created_at desc nulls last limit 200;
  end if;
end $$;
revoke all on function public.folge_liste(uuid, text) from public;
grant execute on function public.folge_liste(uuid, text) to anon, authenticated;

-- Die Tabelle selbst sieht nur, wer beteiligt ist
drop policy if exists "Follows sichtbar" on public.follows;
create policy "Follows sichtbar" on public.follows
  for select to authenticated using (auth.uid() = follower_id or auth.uid() = following_id);
