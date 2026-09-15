-- SPOTOUT — Push-Mitteilungen einzeln abschalten (wie auf TikTok)
-- profiles.push_aus haelt die abgeschalteten Gruppen, 'alle' pausiert alles.
-- Die Meldung bleibt in der Liste im App; nur die Push-Nachricht faellt weg.
-- Konto & Sicherheit (Verwarnung, Sperre, Vereinspruefung) laesst sich nicht abschalten.

alter table public.profiles add column if not exists push_aus text[] not null default '{}';

create or replace function public.push_gruppe(p_art text)
 returns text language sql immutable set search_path to 'public'
as $$
  select case
    when p_art = 'nachricht' then 'nachrichten'
    when p_art in ('folge_anfrage','folge_zusage','neuer_follower') then 'follower'
    when p_art in ('invite','beitritt_ok','beitritt_nein','guest_ok','guest_no') then 'einladungen'
    when p_art in ('guest_request','beitritt_anfrage') then 'gaeste'
    when p_art in ('event_changed','event_gone','foto_entfernt') then 'partys'
    when p_art = 'freund_dabei' then 'freunde'
    when p_art in ('abzeichen','day_one') then 'abzeichen'
    else null
  end
$$;

create or replace function public.sende_push()
 returns trigger language plpgsql security definer set search_path to 'public', 'extensions'
as $function$
declare tok text; aus text[]; gruppe text; offen int;
begin
  select push_token, push_aus into tok, aus from public.profiles where id = new.user_id;
  if tok is null or tok = '' then
    return new;
  end if;

  -- Eingestellt wie auf TikTok: alles pausiert oder diese Gruppe aus.
  -- In der Liste im App bleibt die Meldung trotzdem stehen.
  gruppe := public.push_gruppe(new.art);
  if gruppe is not null and ('alle' = any(coalesce(aus,'{}')) or gruppe = any(coalesce(aus,'{}'))) then
    return new;
  end if;

  select count(*) into offen
    from public.notifications
   where user_id = new.user_id and gelesen = false;

  perform net.http_post(
    url     := 'https://exp.host/--/api/v2/push/send',
    headers := jsonb_build_object('Content-Type','application/json','Accept','application/json'),
    body    := jsonb_build_object(
      'to',       tok,
      'title',    new.titel,
      'body',     coalesce(new.text,''),
      'sound',    'default',
      'badge',    offen,
      'priority', 'high',
      'data',     jsonb_build_object(
                    'event_id',        new.event_id,
                    'conversation_id', new.conversation_id,
                    'art',             new.art)
    )
  );
  return new;
end $function$;
revoke all on function public.sende_push() from public, anon, authenticated;
