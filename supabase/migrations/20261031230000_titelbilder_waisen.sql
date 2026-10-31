-- Titelbilder ohne Party: Beim Loeschen einer Party blieb die Datei liegen.
-- Zwei Tage Frist, weil das Bild vor der Party hochgeladen wird. Bilder, auf
-- die noch das Archiv "Besucht" zeigt, bleiben. Nur fuer den Server.
create or replace function public.titelbilder_waisen(p_limit integer default 200)
returns table(name text)
language sql
stable
security definer
set search_path = storage, public
as $$
  select o.name
    from storage.objects o
   where o.bucket_id = 'event-images'
     and o.created_at < now() - interval '2 days'
     and not exists (select 1 from public.events e where e.image_url like '%/event-images/' || o.name || '%')
     and not exists (select 1 from public.besucht_archiv a where a.image_url like '%/event-images/' || o.name || '%')
   limit p_limit;
$$;
revoke all on function public.titelbilder_waisen(integer) from public, anon, authenticated;
grant execute on function public.titelbilder_waisen(integer) to service_role;
