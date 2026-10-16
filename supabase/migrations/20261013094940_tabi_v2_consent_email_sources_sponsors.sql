-- =====================================================================
-- TABI TABI PO — v2: consent, source tracking, guest types,
-- confirmation emails, sponsor inquiries
-- =====================================================================
create extension if not exists pg_net;
create extension if not exists pg_cron;

-- ---------- RSVP table additions ----------
alter table public.tabi_rsvps
  add column if not exists source            text check (source is null or char_length(source) <= 60),
  add column if not exists guest_type        text not null default 'guest',
  add column if not exists consent_at        timestamptz,
  add column if not exists marketing_opt_in  boolean not null default false,
  add column if not exists email_status      text not null default 'pending',
  add column if not exists email_sent_at     timestamptz,
  add column if not exists email_error       text;

do $$ begin
  alter table public.tabi_rsvps add constraint tabi_rsvps_guest_type_chk
    check (guest_type in ('guest','sponsor','media','artist','vip'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.tabi_rsvps add constraint tabi_rsvps_email_status_chk
    check (email_status in ('pending','sending','sent','failed','skipped'));
exception when duplicate_object then null; end $$;

-- Existing rows (pre-consent): don't email them retroactively.
update public.tabi_rsvps set email_status = 'skipped' where consent_at is null and email_status = 'pending';

-- ---------- Sponsor inquiries ----------
create table if not exists public.tabi_sponsor_inquiries (
  id            uuid primary key default gen_random_uuid(),
  event_slug    text not null,
  company       text not null check (char_length(company) between 1 and 120),
  contact_name  text not null check (char_length(contact_name) between 1 and 120),
  email         text not null check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and char_length(email) <= 200),
  phone         text check (phone is null or char_length(phone) <= 40),
  interest      text check (interest is null or char_length(interest) <= 80),
  message       text check (message is null or char_length(message) <= 2000),
  consent_at    timestamptz not null,
  status        text not null default 'new' check (status in ('new','contacted','confirmed','declined')),
  created_at    timestamptz not null default now()
);
alter table public.tabi_sponsor_inquiries enable row level security;
revoke all on public.tabi_sponsor_inquiries from anon, authenticated;

-- ---------- Guest RPC: register (replaces rsvp_create) ----------
create or replace function public.rsvp_register(
  p_event_slug text, p_full_name text, p_email text,
  p_phone text default null, p_party_size text default null,
  p_source text default null, p_guest_type text default null,
  p_consent boolean default false, p_marketing boolean default false
)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  v_row  tabi_rsvps;
  v_name text := btrim(p_full_name);
  v_mail text := lower(btrim(p_email));
  v_src  text := nullif(left(lower(regexp_replace(coalesce(p_source,''), '[^a-zA-Z0-9_.-]', '', 'g')), 60), '');
  v_type text := case when p_guest_type in ('sponsor','media','artist','vip') then p_guest_type else 'guest' end;
begin
  if not coalesce(p_consent, false) then
    raise exception 'Please agree to the privacy notice to RSVP' using errcode = '22023';
  end if;
  if v_name is null or v_name = '' then
    raise exception 'Name is required' using errcode = '22023';
  end if;
  if v_mail is null or v_mail !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a valid email address' using errcode = '22023';
  end if;

  select * into v_row from tabi_rsvps where event_slug = p_event_slug and lower(email) = v_mail;

  if found then
    update tabi_rsvps set
      full_name  = v_name,
      phone      = coalesce(nullif(btrim(p_phone), ''), phone),
      party_size = coalesce(nullif(p_party_size, ''), party_size),
      source     = coalesce(source, v_src),                         -- first touch wins
      guest_type = case when guest_type = 'guest' then v_type else guest_type end,
      consent_at = coalesce(consent_at, now()),
      marketing_opt_in = coalesce(p_marketing, false),             -- latest choice wins
      email_status = case when email_status = 'skipped' then 'pending' else email_status end,
      updated_at = now()
    where id = v_row.id returning * into v_row;
    return jsonb_build_object('ticket_code', v_row.ticket_code, 'full_name', v_row.full_name,
      'returning', true, 'status', v_row.status, 'guest_type', v_row.guest_type);
  end if;

  insert into tabi_rsvps (event_slug, ticket_code, full_name, email, phone, party_size,
                          source, guest_type, consent_at, marketing_opt_in)
  values (p_event_slug, tabi_new_ticket_code(), v_name, v_mail, nullif(btrim(p_phone), ''),
          nullif(p_party_size, ''), v_src, v_type, now(), coalesce(p_marketing, false))
  returning * into v_row;

  return jsonb_build_object('ticket_code', v_row.ticket_code, 'full_name', v_row.full_name,
    'returning', false, 'status', v_row.status, 'guest_type', v_row.guest_type);
end $$;

-- ---------- Sponsor inquiry RPC ----------
create or replace function public.sponsor_inquiry_create(
  p_event_slug text, p_company text, p_contact_name text, p_email text,
  p_phone text default null, p_interest text default null, p_message text default null,
  p_consent boolean default false
)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare v_mail text := lower(btrim(p_email)); v_recent int;
begin
  if not coalesce(p_consent, false) then
    raise exception 'Please agree to the privacy notice' using errcode = '22023';
  end if;
  if nullif(btrim(p_company),'') is null or nullif(btrim(p_contact_name),'') is null then
    raise exception 'Company and contact name are required' using errcode = '22023';
  end if;
  if v_mail !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Enter a valid email address' using errcode = '22023';
  end if;
  select count(*) into v_recent from tabi_sponsor_inquiries
   where lower(email) = v_mail and created_at > now() - interval '1 hour';
  if v_recent >= 3 then
    raise exception 'We already have your inquiry. We''ll be in touch soon.' using errcode = '22023';
  end if;
  insert into tabi_sponsor_inquiries (event_slug, company, contact_name, email, phone, interest, message, consent_at)
  values (p_event_slug, btrim(p_company), btrim(p_contact_name), v_mail, nullif(btrim(p_phone),''),
          nullif(p_interest,''), nullif(btrim(p_message),''), now());
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Admin RPCs ----------
create or replace function public.admin_list_sponsor_inquiries(p_passcode text, p_event_slug text)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions
as $$
begin
  if not tabi_admin_verify(p_passcode) then
    return jsonb_build_object('ok', false, 'error', 'Session expired. Log in again.');
  end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(to_jsonb(s) order by s.created_at desc)
      from tabi_sponsor_inquiries s where s.event_slug = p_event_slug), '[]'::jsonb));
end $$;

create or replace function public.admin_set_inquiry_status(p_passcode text, p_id uuid, p_status text)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions
as $$
begin
  if not tabi_admin_verify(p_passcode) then
    return jsonb_build_object('ok', false, 'error', 'Session expired. Log in again.');
  end if;
  if p_status not in ('new','contacted','confirmed','declined') then
    return jsonb_build_object('ok', false, 'error', 'Unknown status.');
  end if;
  update tabi_sponsor_inquiries set status = p_status where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- Re-queue failed emails so the next sweep retries them.
create or replace function public.admin_retry_emails(p_passcode text)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare n int;
begin
  if not tabi_admin_verify(p_passcode) then
    return jsonb_build_object('ok', false, 'error', 'Session expired. Log in again.');
  end if;
  update tabi_rsvps set email_status = 'pending', email_error = null
   where email_status in ('failed','sending') and consent_at is not null;
  get diagnostics n = row_count;
  perform tabi_email_sweep();
  return jsonb_build_object('ok', true, 'requeued', n);
end $$;

-- ---------- Email delivery: trigger + sweep -> Edge Function ----------
create or replace function public.tabi_email_sweep()
returns void language plpgsql security definer
set search_path = public, extensions
as $$
begin
  perform net.http_post(
    url := 'https://bsgyfctspsecimphiljp.supabase.co/functions/v1/tabi-send-ticket',
    body := jsonb_build_object('sweep', true),
    headers := '{"Content-Type":"application/json"}'::jsonb,
    timeout_milliseconds := 10000);
end $$;

create or replace function public.tabi_rsvp_email_trigger()
returns trigger language plpgsql security definer
set search_path = public, extensions
as $$
begin
  if new.email_status = 'pending' and new.consent_at is not null then
    perform net.http_post(
      url := 'https://bsgyfctspsecimphiljp.supabase.co/functions/v1/tabi-send-ticket',
      body := jsonb_build_object('id', new.id),
      headers := '{"Content-Type":"application/json"}'::jsonb,
      timeout_milliseconds := 10000);
  end if;
  return new;
end $$;

drop trigger if exists tabi_rsvp_email on public.tabi_rsvps;
create trigger tabi_rsvp_email after insert or update of email_status on public.tabi_rsvps
  for each row when (new.email_status = 'pending') execute function public.tabi_rsvp_email_trigger();

-- Retry anything still pending every 30 minutes (covers provider outages / daily caps).
do $$ begin
  perform cron.unschedule('tabi-email-sweep');
exception when others then null; end $$;
select cron.schedule('tabi-email-sweep', '*/30 * * * *', 'select public.tabi_email_sweep()');

-- ---------- Permissions ----------
revoke all on function public.tabi_email_sweep() from public, anon, authenticated;
revoke all on function public.tabi_rsvp_email_trigger() from public, anon, authenticated;
revoke all on function public.rsvp_register(text,text,text,text,text,text,text,boolean,boolean) from public;
revoke all on function public.sponsor_inquiry_create(text,text,text,text,text,text,text,boolean) from public;
revoke all on function public.admin_list_sponsor_inquiries(text,text) from public;
revoke all on function public.admin_set_inquiry_status(text,uuid,text) from public;
revoke all on function public.admin_retry_emails(text) from public;
grant execute on function public.rsvp_register(text,text,text,text,text,text,text,boolean,boolean) to anon, authenticated;
grant execute on function public.sponsor_inquiry_create(text,text,text,text,text,text,text,boolean) to anon, authenticated;
grant execute on function public.admin_list_sponsor_inquiries(text,text) to anon, authenticated;
grant execute on function public.admin_set_inquiry_status(text,uuid,text) to anon, authenticated;
grant execute on function public.admin_retry_emails(text) to anon, authenticated;
