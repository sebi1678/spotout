-- SPOTOUT — KI-Prüfung für Vereinskonten
--
-- Registriert sich ein Verein, dessen E-Mail nicht zur Website passt, landet er
-- in der Handprüfung. Ab jetzt startet dann automatisch die Edge Function
-- verein-pruefen: Claude recherchiert, ob es den Verein gibt. Das Ergebnis
-- steht in verein_pruefungen (nur für Betreiber lesbar). Bestätigen oder
-- ablehnen kann ein Betreiber über verein_entscheiden().

-- ── Ergebnisse ────────────────────────────────────────────────────────
create table if not exists public.verein_pruefungen (
  id                     uuid primary key default gen_random_uuid(),
  profil_id              uuid not null references public.profiles(id) on delete cascade,
  urteil                 text not null check (urteil in ('echt','unklar','verdaechtig','fehler')),
  sicherheit             int  not null default 0 check (sicherheit between 0 and 100),
  website_gehoert_verein boolean not null default false,
  offizielle_quelle      boolean not null default false,
  quellen                jsonb not null default '[]'::jsonb,
  begruendung            text,
  entscheidung           text not null check (entscheidung in ('bestaetigt','handpruefung')),
  modell                 text,
  suchen                 int not null default 0,
  tokens_in              int not null default 0,
  tokens_out             int not null default 0,
  kosten_usd             numeric(8,4) not null default 0,
  fehler                 text,
  created_at             timestamptz not null default now()
);
create index if not exists verein_pruefungen_profil_idx
  on public.verein_pruefungen (profil_id, created_at desc);

alter table public.verein_pruefungen enable row level security;
drop policy if exists "Betreiber lesen Pruefungen" on public.verein_pruefungen;
create policy "Betreiber lesen Pruefungen" on public.verein_pruefungen
  for select using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.ist_admin));
-- Schreiben nur die Function mit dem Service-Role-Schlüssel.

-- ── Geheimnis, an dem die Function den Aufruf aus der Datenbank erkennt ──
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'verein_pruefung_geheimnis') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'),
      'verein_pruefung_geheimnis', 'Aufruf der Edge Function verein-pruefen');
  end if;
end $$;

create or replace function public.verein_pruefung_geheimnis()
 returns text
 language sql
 stable
 security definer
 set search_path to 'public'
as $$
  select decrypted_secret from vault.decrypted_secrets
   where name = 'verein_pruefung_geheimnis' limit 1;
$$;
revoke all on function public.verein_pruefung_geheimnis() from public, anon, authenticated;
grant execute on function public.verein_pruefung_geheimnis() to service_role;

-- ── Start der Prüfung ─────────────────────────────────────────────────
create or replace function public.verein_pruefung_starten()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $$
begin
  if new.kontoart = 'verein' and new.verein_status = 'handpruefung' then
    perform net.http_post(
      url     := 'https://tuxyyrlxjkxabhvremqu.supabase.co/functions/v1/verein-pruefen',
      body    := jsonb_build_object('profil_id', new.id),
      headers := jsonb_build_object(
                   'Content-Type', 'application/json',
                   'x-spotout-geheimnis', public.verein_pruefung_geheimnis()),
      timeout_milliseconds := 150000
    );
  end if;
  return new;
end $$;
revoke all on function public.verein_pruefung_starten() from public, anon, authenticated;

drop trigger if exists verein_pruefung_starten_trg on public.profiles;
create trigger verein_pruefung_starten_trg
  after insert on public.profiles
  for each row execute function public.verein_pruefung_starten();

-- ── Entscheidung durch einen Betreiber ────────────────────────────────
create or replace function public.verein_entscheiden(p_profil uuid, p_bestaetigen boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $$
declare
  v_treffer int;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and ist_admin) then
    return jsonb_build_object('ok', false, 'meldung', 'Das darf nur der Betreiber.');
  end if;

  update public.profiles
     set verein_status = case when p_bestaetigen then 'bestaetigt' else 'abgelehnt' end
   where id = p_profil and kontoart = 'verein';
  get diagnostics v_treffer = row_count;
  if v_treffer = 0 then
    return jsonb_build_object('ok', false, 'meldung', 'Verein nicht gefunden.');
  end if;

  if p_bestaetigen then
    perform public.notify(p_profil, auth.uid(), null, 'verein_bestaetigt',
      'Dein Verein ist bestätigt',
      'Du kannst jetzt Anlässe veröffentlichen – ein Logo braucht es noch dazu.');
  else
    perform public.notify(p_profil, auth.uid(), null, 'verein_abgelehnt',
      'Dein Verein konnte nicht bestätigt werden',
      'Schreib uns an support@spotoutapp.ch, dann schauen wir es gemeinsam an.');
  end if;

  return jsonb_build_object('ok', true,
    'meldung', case when p_bestaetigen then 'Bestätigt' else 'Abgelehnt' end);
end $$;
revoke all on function public.verein_entscheiden(uuid, boolean) from public, anon;
grant execute on function public.verein_entscheiden(uuid, boolean) to authenticated;
