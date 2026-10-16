-- =====================================================================
-- v3: two-night event (Fri Oct 30 + Sat Oct 31, 2026), per-night check-in,
-- and automatic data retention per the privacy notice.
-- =====================================================================
alter table public.tabi_rsvps add column if not exists nights date[];  -- null = legacy RSVP, valid any night

create table if not exists public.tabi_checkins (
  rsvp_id       uuid not null references public.tabi_rsvps(id) on delete cascade,
  night         date not null,
  checked_in_at timestamptz not null default now(),
  primary key (rsvp_id, night)
);
alter table public.tabi_checkins enable row level security;
revoke all on public.tabi_checkins from anon, authenticated;

create table if not exists public.tabi_marketing_contacts (
  email        text primary key,
  full_name    text not null,
  opted_in_at  timestamptz not null,
  source_event text not null
);
alter table public.tabi_marketing_contacts enable row level security;
revoke all on public.tabi_marketing_contacts from anon, authenticated;

create or replace function public.tabi_event_nights()
returns date[] language sql immutable as $$ select array['2026-10-30','2026-10-31']::date[] $$;

create or replace function public.tabi_current_night()
returns date language sql stable as $$ select ((now() at time zone 'Asia/Manila') - interval '6 hours')::date $$;

create or replace function public.tabi_sync_checkin_status(p_id uuid)
returns void language sql security definer set search_path = public as $$
  update tabi_rsvps r set
    checked_in_at = (select max(checked_in_at) from tabi_checkins c where c.rsvp_id = r.id),
    status = case when r.status = 'cancelled' then 'cancelled'
                  when exists (select 1 from tabi_checkins c where c.rsvp_id = r.id) then 'checked_in'
                  else 'registered' end,
    updated_at = now()
  where r.id = p_id;
$$;

drop function if exists public.rsvp_register(text,text,text,text,text,text,text,boolean,boolean);
create or replace function public.rsvp_register(
  p_event_slug text, p_full_name text, p_email text,
  p_phone text default null, p_party_size text default null,
  p_source text default null, p_guest_type text default null,
  p_consent boolean default false, p_marketing boolean default false,
  p_nights text[] default null
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
  v_nights date[];
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
  begin
    select array_agg(distinct n order by n) into v_nights
      from unnest(coalesce(p_nights, '{}')::date[]) n where n = any (tabi_event_nights());
  exception when others then v_nights := null; end;
  if v_nights is null or cardinality(v_nights) = 0 then
    raise exception 'Pick the night you''re coming' using errcode = '22023';
  end if;

  select * into v_row from tabi_rsvps where event_slug = p_event_slug and lower(email) = v_mail;

  if found then
    update tabi_rsvps set
      full_name  = v_name,
      phone      = coalesce(nullif(btrim(p_phone), ''), phone),
      party_size = coalesce(nullif(p_party_size, ''), party_size),
      source     = coalesce(source, v_src),
      guest_type = case when guest_type = 'guest' then v_type else guest_type end,
      consent_at = coalesce(consent_at, now()),
      marketing_opt_in = coalesce(p_marketing, false),
      nights     = v_nights,
      email_status = case when email_status = 'skipped' then 'pending' else email_status end,
      updated_at = now()
    where id = v_row.id returning * into v_row;
    return jsonb_build_object('ticket_code', v_row.ticket_code, 'full_name', v_row.full_name,
      'returning', true, 'status', v_row.status, 'guest_type', v_row.guest_type, 'nights', v_row.nights);
  end if;

  insert into tabi_rsvps (event_slug, ticket_code, full_name, email, phone, party_size,
                          source, guest_type, consent_at, marketing_opt_in, nights)
  values (p_event_slug, tabi_new_ticket_code(), v_name, v_mail, nullif(btrim(p_phone), ''),
          nullif(p_party_size, ''), v_src, v_type, now(), coalesce(p_marketing, false), v_nights)
  returning * into v_row;

  return jsonb_build_object('ticket_code', v_row.ticket_code, 'full_name', v_row.full_name,
    'returning', false, 'status', v_row.status, 'guest_type', v_row.guest_type, 'nights', v_row.nights);
end $$;

create or replace function public.admin_check_in(p_passcode text, p_event_slug text, p_ticket_code text)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  v_row tabi_rsvps;
  v_night date := tabi_current_night();
  v_at timestamptz;
begin
  if not tabi_admin_verify(p_passcode) then
    return jsonb_build_object('ok', false, 'error', 'Session expired. Log in again.');
  end if;
  select * into v_row from tabi_rsvps
   where event_slug = p_event_slug and ticket_code = upper(btrim(p_ticket_code)) for update;
  if not found then
    return jsonb_build_object('ok', true, 'result', 'not_found');
  elsif v_row.status = 'cancelled' then
    return jsonb_build_object('ok', true, 'result', 'cancelled', 'rsvp', to_jsonb(v_row));
  end if;
  if not (v_night = any (tabi_event_nights())) then
    return jsonb_build_object('ok', true, 'result', 'test_ok', 'night', v_night, 'rsvp', to_jsonb(v_row));
  end if;
  if v_row.nights is not null and not (v_night = any (v_row.nights)) then
    return jsonb_build_object('ok', true, 'result', 'wrong_night', 'night', v_night, 'rsvp', to_jsonb(v_row));
  end if;
  select checked_in_at into v_at from tabi_checkins where rsvp_id = v_row.id and night = v_night;
  if found then
    return jsonb_build_object('ok', true, 'result', 'already', 'night', v_night,
      'rsvp', to_jsonb(v_row) || jsonb_build_object('checked_in_at', v_at));
  end if;
  insert into tabi_checkins (rsvp_id, night) values (v_row.id, v_night);
  perform tabi_sync_checkin_status(v_row.id);
  select * into v_row from tabi_rsvps where id = v_row.id;
  return jsonb_build_object('ok', true, 'result', 'checked_in', 'night', v_night, 'rsvp', to_jsonb(v_row));
end $$;

create or replace function public.admin_set_status(p_passcode text, p_id uuid, p_status text)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  v_row tabi_rsvps;
  v_night date := tabi_current_night();
begin
  if not tabi_admin_verify(p_passcode) then
    return jsonb_build_object('ok', false, 'error', 'Session expired. Log in again.');
  end if;
  if p_status not in ('registered','checked_in','cancelled') then
    return jsonb_build_object('ok', false, 'error', 'Unknown status.');
  end if;
  select * into v_row from tabi_rsvps where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'Guest not found.'); end if;
  if p_status = 'checked_in' then
    if not (v_night = any (tabi_event_nights())) then
      return jsonb_build_object('ok', false, 'error', 'Check-in only works on event nights (Oct 30 and 31).');
    end if;
    update tabi_rsvps set status = 'registered' where id = p_id and status = 'cancelled';
    insert into tabi_checkins (rsvp_id, night) values (p_id, v_night) on conflict do nothing;
  elsif p_status = 'registered' then
    if v_row.status = 'cancelled' then
      update tabi_rsvps set status = 'registered' where id = p_id;
    else
      delete from tabi_checkins where rsvp_id = p_id and night = coalesce(
        (select night from tabi_checkins where rsvp_id = p_id and night = v_night),
        (select max(night) from tabi_checkins where rsvp_id = p_id));
    end if;
  else
    update tabi_rsvps set status = 'cancelled', updated_at = now() where id = p_id;
  end if;
  perform tabi_sync_checkin_status(p_id);
  select * into v_row from tabi_rsvps where id = p_id;
  return jsonb_build_object('ok', true, 'rsvp', to_jsonb(v_row) ||
    jsonb_build_object('checkins', coalesce((select jsonb_agg(c.night order by c.night) from tabi_checkins c where c.rsvp_id = p_id), '[]'::jsonb)));
end $$;

create or replace function public.admin_list_rsvps(p_passcode text, p_event_slug text)
returns jsonb language plpgsql volatile security definer
set search_path = public, extensions
as $$
begin
  if not tabi_admin_verify(p_passcode) then
    return jsonb_build_object('ok', false, 'error', 'Session expired. Log in again.');
  end if;
  return jsonb_build_object('ok', true, 'tonight', tabi_current_night(), 'event_nights', to_jsonb(tabi_event_nights()),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(r) || jsonb_build_object('checkins',
               coalesce((select jsonb_agg(c.night order by c.night) from tabi_checkins c where c.rsvp_id = r.id), '[]'::jsonb))
             order by r.created_at desc)
        from tabi_rsvps r where r.event_slug = p_event_slug), '[]'::jsonb));
end $$;

create or replace function public.tabi_retention_purge()
returns void language plpgsql security definer set search_path = public as $$
begin
  if now() < timestamptz '2027-01-29 00:00+08' then return; end if;
  insert into tabi_marketing_contacts (email, full_name, opted_in_at, source_event)
    select lower(email), full_name, coalesce(consent_at, created_at), event_slug
      from tabi_rsvps where marketing_opt_in
    on conflict (email) do nothing;
  delete from tabi_rsvps where event_slug = 'tabi-tabi-po-2026';
  delete from tabi_admin_attempts;
  delete from tabi_sponsor_inquiries where created_at < now() - interval '1 year';
end $$;
do $$ begin perform cron.unschedule('tabi-retention'); exception when others then null; end $$;
select cron.schedule('tabi-retention', '0 4 * * *', 'select public.tabi_retention_purge()');

revoke all on function public.tabi_event_nights() from public, anon, authenticated;
revoke all on function public.tabi_current_night() from public, anon, authenticated;
revoke all on function public.tabi_sync_checkin_status(uuid) from public, anon, authenticated;
revoke all on function public.tabi_retention_purge() from public, anon, authenticated;
revoke all on function public.rsvp_register(text,text,text,text,text,text,text,boolean,boolean,text[]) from public;
grant execute on function public.rsvp_register(text,text,text,text,text,text,text,boolean,boolean,text[]) to anon, authenticated;
