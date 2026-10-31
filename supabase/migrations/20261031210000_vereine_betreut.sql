-- Vereinskonten, die der Betreiber anlegt, bedient und uebergibt.
-- Zugriff nur ueber die Funktion vereine-verwalten: Zeilenregeln sind an,
-- aber es gibt absichtlich keine – niemand liest die Tabelle direkt.

begin;

create table if not exists public.vereine_betreut (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  email         text not null,
  angelegt_von  uuid references auth.users(id) on delete set null,
  angelegt_am   timestamptz not null default now(),
  uebergeben_am timestamptz,
  entfernt_am   timestamptz
);
alter table public.vereine_betreut enable row level security;

-- Beendet alle Sitzungen eines Kontos. Nur fuer den Server.
create or replace function public.verein_sitzungen_beenden(p_user uuid)
returns void
language sql
security definer
set search_path = auth, public
as $$
  delete from auth.sessions where user_id = p_user;
$$;
revoke all on function public.verein_sitzungen_beenden(uuid) from public, anon, authenticated;
grant execute on function public.verein_sitzungen_beenden(uuid) to service_role;

commit;
