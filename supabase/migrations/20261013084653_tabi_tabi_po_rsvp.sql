-- =====================================================================
-- TABI TABI PO — RSVP + admin backend
-- Salakot Opening Night · Halloween · Z Hostel
--
-- Security model
--   * The rsvp table has RLS ON and NO policies, and anon/authenticated
--     have no table privileges. The browser can never read or write the
--     table directly.
--   * Guests interact only through two SECURITY DEFINER functions:
--       rsvp_create(...)        -> creates (or re-issues) a ticket
--       rsvp_update_survey(...) -> needs ticket_code + email to edit
--   * The admin dashboard calls admin_* functions that verify a bcrypt-
--     hashed passcode on every call, with per-IP lockout after repeated
--     failures.
--
-- Safe to re-run: every statement is idempotent.
--
-- FIRST LOGIN: the initial passcode below is a placeholder. The admin
-- page forces a change on first login; after that the value in this
-- file no longer works.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table if not exists public.tabi_rsvps (
  id               uuid primary key default gen_random_uuid(),
  event_slug       text not null default 'tabi-tabi-po-2026',
  ticket_code      text not null unique,
  full_name        text not null check (char_length(full_name) between 1 and 120),
  email            text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 200),
  phone            text check (phone is null or char_length(phone) <= 40),
  party_size       text check (party_size is null or party_size in ('solo','1-2','3-5','6+')),
  drink            text check (drink is null or char_length(drink) <= 60),
  staying          text check (staying is null or char_length(staying) <= 60),
  payment          text check (payment is null or char_length(payment) <= 60),
  interests        text[] not null default '{}',
  age_bracket      text check (age_bracket is null or char_length(age_bracket) <= 20),
  costume          text check (costume is null or char_length(costume) <= 80),
  notes            text check (notes is null or char_length(notes) <= 1000),
  answers_count    int  not null default 0,
  survey_completed boolean not null default false,
  status           text not null default 'registered'
                   check (status in ('registered','checked_in','cancelled')),
  checked_in_at    timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create unique index if not exists tabi_rsvps_event_email_uq
  on public.tabi_rsvps (event_slug, lower(email));
create index if not exists tabi_rsvps_event_created_idx
  on public.tabi_rsvps (event_slug, created_at desc);

create table if not exists public.tabi_admin_settings (
  id             int primary key default 1 check (id = 1),
  passcode_hash  text not null,
  must_change    boolean not null default true,
  updated_at     timestamptz not null default now()
);

create table if not exists public.tabi_admin_attempts (
  id         bigint generated always as identity primary key,
  ip         text not null,
  ok         boolean not null,
  created_at timestamptz not null default now()
);
create index if not exists tabi_admin_attempts_ip_idx
  on public.tabi_admin_attempts (ip, created_at desc);

-- Lock everything down: no direct table access from the browser.
alter table public.tabi_rsvps          enable row level security;
alter table public.tabi_admin_settings enable row level security;
alter table public.tabi_admin_attempts enable row level security;
revoke all on public.tabi_rsvps, public.tabi_admin_settings, public.tabi_admin_attempts
  from anon, authenticated;

-- Initial passcode (placeholder — forced change on first admin login)
insert into public.tabi_admin_settings (id, passcode_hash, must_change)
values (1, extensions.crypt('tabi-change-me-on-first-login', extensions.gen_salt('bf', 10)), true)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- Helpers (not callable from the browser)
-- ---------------------------------------------------------------------
create or replace function public.tabi_new_ticket_code()
returns text language plpgsql volatile
set search_path = public, extensions
as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; -- no 0/O/1/I/L
  code text;
  i int;
begin
  loop
    code := 'TTP-';
    for i in 1..6 loop
      code := code || substr(alphabet, 1 + (get_byte(gen_random_bytes(1), 0) % length(alphabet)), 1);
    end loop;
    exit when not exists (select 1 from tabi_rsvps where ticket_code = code);
  end loop;
  return code;
end $$;

create or replace function public.tabi_client_ip()
returns text language sql stable
set search_path = public
as $$
  select coalesce(
    nullif(btrim(split_part(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ',', 1)), ''),
    'unknown');
$$;

-- Returns true when the passcode is valid. Records the attempt.
-- Locks an IP out after 10 failed attempts within 15 minutes.
create or replace function public.tabi_admin_verify(p_passcode text)
returns boolean language plpgsql volatile
security definer
set search_path = public, extensions
as $$
declare
  v_ip    text := tabi_client_ip();
  v_fails int;
  v_ok    boolean;
begin
  select count(*) into v_fails from tabi_admin_attempts
   where ip = v_ip and not ok and created_at > now() - interval '15 minutes';
  if v_fails >= 10 then
    return false;
  end if;

  select passcode_hash = crypt(coalesce(p_passcode, ''), passcode_hash)
    into v_ok from tabi_admin_settings where id = 1;
  v_ok := coalesce(v_ok, false);

  insert into tabi_admin_attempts (ip, ok) values (v_ip, v_ok);
  delete from tabi_admin_attempts where created_at < now() - interval '1 day';
  return v_ok;
end $$;

revoke all on function public.tabi_new_ticket_code()   from public, anon, authenticated;
revoke all on function public.tabi_client_ip()         from public, anon, authenticated;
revoke all on function public.tabi_admin_verify(text)  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Guest-facing RPCs
-- ---------------------------------------------------------------------

-- Step 1: name + email. Re-entering the same email returns the same
-- ticket (so guests can recover a lost QR).
create or replace function public.rsvp_create(
  p_event_slug text,
  p_full_name  text,
  p_email      text,
  p_phone      text default null,
  p_party_size text default null
)
returns jsonb language plpgsql volatile
security definer
set search_path = public, extensions
as $$
declare
  v_row  tabi_rsvps;
  v_name text := btrim(p_full_name);
  v_mail text := lower(btrim(p_email));
begin
  if v_name is null or v_name = '' then
    raise exception 'Name is required' using errcode = '22023';
  end if;
  if v_mail is null or v_mail !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a valid email address' using errcode = '22023';
  end if;

  select * into v_row from tabi_rsvps
   where event_slug = p_event_slug and lower(email) = v_mail;

  if found then
    update tabi_rsvps
       set full_name  = v_name,
           phone      = coalesce(nullif(btrim(p_phone), ''), phone),
           party_size = coalesce(nullif(p_party_size, ''), party_size),
           updated_at = now()
     where id = v_row.id
     returning * into v_row;
    return jsonb_build_object('ticket_code', v_row.ticket_code, 'full_name', v_row.full_name,
                              'returning', true, 'status', v_row.status);
  end if;

  insert into tabi_rsvps (event_slug, ticket_code, full_name, email, phone, party_size)
  values (p_event_slug, tabi_new_ticket_code(), v_name, v_mail,
          nullif(btrim(p_phone), ''), nullif(p_party_size, ''))
  returning * into v_row;

  return jsonb_build_object('ticket_code', v_row.ticket_code, 'full_name', v_row.full_name,
                            'returning', false, 'status', v_row.status);
end $$;

-- Steps 2+: optional survey. Requires ticket_code AND email to match.
create or replace function public.rsvp_update_survey(
  p_ticket_code text,
  p_email       text,
  p_drink       text   default null,
  p_staying     text   default null,
  p_payment     text   default null,
  p_interests   text[] default null,
  p_age_bracket text   default null,
  p_costume     text   default null,
  p_notes       text   default null,
  p_completed   boolean default false
)
returns jsonb language plpgsql volatile
security definer
set search_path = public, extensions
as $$
declare
  v_row tabi_rsvps;
begin
  update tabi_rsvps set
    drink       = coalesce(nullif(p_drink, ''),       drink),
    staying     = coalesce(nullif(p_staying, ''),     staying),
    payment     = coalesce(nullif(p_payment, ''),     payment),
    interests   = case when p_interests is not null and cardinality(p_interests) > 0
                       then p_interests[1:10] else interests end,
    age_bracket = coalesce(nullif(p_age_bracket, ''), age_bracket),
    costume     = coalesce(nullif(btrim(p_costume), ''), costume),
    notes       = coalesce(nullif(btrim(p_notes), ''),   notes),
    survey_completed = survey_completed or coalesce(p_completed, false),
    updated_at  = now()
  where ticket_code = upper(btrim(p_ticket_code))
    and lower(email) = lower(btrim(p_email))
  returning * into v_row;

  if not found then
    raise exception 'Ticket not found' using errcode = 'P0002';
  end if;

  update tabi_rsvps set answers_count =
      (drink is not null)::int + (staying is not null)::int + (payment is not null)::int
    + (cardinality(interests) > 0)::int + (age_bracket is not null)::int
    + (costume is not null)::int
  where id = v_row.id
  returning * into v_row;

  return jsonb_build_object('ok', true, 'answers_count', v_row.answers_count);
end $$;

-- ---------------------------------------------------------------------
-- Admin RPCs (every call re-verifies the passcode)
-- All return jsonb { ok: false, error: '...' } on failure.
-- ---------------------------------------------------------------------
create or replace function public.admin_login(p_passcode text)
returns jsonb language plpgsql volatile
security definer
set search_path = public, extensions
as $$
begin
  if not tabi_admin_verify(p_passcode) then
    return jsonb_build_object('ok', false, 'error', 'Wrong passcode, or too many attempts. Wait 15 minutes and try again.');
  end if;
  return jsonb_build_object('ok', true,
    'must_change', (select must_change from tabi_admin_settings where id = 1));
end $$;

create or replace function public.admin_change_passcode(p_passcode text, p_new_passcode text)
returns jsonb language plpgsql volatile
security definer
set search_path = public, extensions
as $$
begin
  if not tabi_admin_verify(p_passcode) then
    return jsonb_build_object('ok', false, 'error', 'Current passcode is wrong.');
  end if;
  if p_new_passcode is null or char_length(p_new_passcode) < 12 then
    return jsonb_build_object('ok', false, 'error', 'Use at least 12 characters.');
  end if;
  if p_new_passcode = p_passcode then
    return jsonb_build_object('ok', false, 'error', 'Pick a passcode different from the current one.');
  end if;
  update tabi_admin_settings
     set passcode_hash = crypt(p_new_passcode, gen_salt('bf', 10)),
         must_change = false, updated_at = now()
   where id = 1;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_list_rsvps(p_passcode text, p_event_slug text)
returns jsonb language plpgsql volatile
security definer
set search_path = public, extensions
as $$
begin
  if not tabi_admin_verify(p_passcode) then
    return jsonb_build_object('ok', false, 'error', 'Session expired. Log in again.');
  end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(to_jsonb(r) order by r.created_at desc)
      from tabi_rsvps r where r.event_slug = p_event_slug
  ), '[]'::jsonb));
end $$;

-- Door check-in from a scanned QR or typed code.
create or replace function public.admin_check_in(p_passcode text, p_event_slug text, p_ticket_code text)
returns jsonb language plpgsql volatile
security definer
set search_path = public, extensions
as $$
declare
  v_row tabi_rsvps;
begin
  if not tabi_admin_verify(p_passcode) then
    return jsonb_build_object('ok', false, 'error', 'Session expired. Log in again.');
  end if;

  select * into v_row from tabi_rsvps
   where event_slug = p_event_slug and ticket_code = upper(btrim(p_ticket_code))
   for update;

  if not found then
    return jsonb_build_object('ok', true, 'result', 'not_found');
  elsif v_row.status = 'cancelled' then
    return jsonb_build_object('ok', true, 'result', 'cancelled', 'rsvp', to_jsonb(v_row));
  elsif v_row.status = 'checked_in' then
    return jsonb_build_object('ok', true, 'result', 'already', 'rsvp', to_jsonb(v_row));
  end if;

  update tabi_rsvps set status = 'checked_in', checked_in_at = now(), updated_at = now()
   where id = v_row.id returning * into v_row;
  return jsonb_build_object('ok', true, 'result', 'checked_in', 'rsvp', to_jsonb(v_row));
end $$;

create or replace function public.admin_set_status(p_passcode text, p_id uuid, p_status text)
returns jsonb language plpgsql volatile
security definer
set search_path = public, extensions
as $$
declare
  v_row tabi_rsvps;
begin
  if not tabi_admin_verify(p_passcode) then
    return jsonb_build_object('ok', false, 'error', 'Session expired. Log in again.');
  end if;
  if p_status not in ('registered','checked_in','cancelled') then
    return jsonb_build_object('ok', false, 'error', 'Unknown status.');
  end if;
  update tabi_rsvps
     set status = p_status,
         checked_in_at = case when p_status = 'checked_in' then coalesce(checked_in_at, now()) else null end,
         updated_at = now()
   where id = p_id returning * into v_row;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'Guest not found.');
  end if;
  return jsonb_build_object('ok', true, 'rsvp', to_jsonb(v_row));
end $$;

-- Browser-callable functions (revoke the PUBLIC default first, then grant explicitly)
revoke all on function public.rsvp_create(text, text, text, text, text) from public;
revoke all on function public.rsvp_update_survey(text, text, text, text, text, text[], text, text, text, boolean) from public;
revoke all on function public.admin_login(text) from public;
revoke all on function public.admin_change_passcode(text, text) from public;
revoke all on function public.admin_list_rsvps(text, text) from public;
revoke all on function public.admin_check_in(text, text, text) from public;
revoke all on function public.admin_set_status(text, uuid, text) from public;

grant execute on function public.rsvp_create(text, text, text, text, text) to anon, authenticated;
grant execute on function public.rsvp_update_survey(text, text, text, text, text, text[], text, text, text, boolean) to anon, authenticated;
grant execute on function public.admin_login(text) to anon, authenticated;
grant execute on function public.admin_change_passcode(text, text) to anon, authenticated;
grant execute on function public.admin_list_rsvps(text, text) to anon, authenticated;
grant execute on function public.admin_check_in(text, text, text) to anon, authenticated;
grant execute on function public.admin_set_status(text, uuid, text) to anon, authenticated;
