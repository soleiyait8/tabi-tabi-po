drop trigger if exists tabi_rsvp_email on public.tabi_rsvps;
drop trigger if exists tabi_rsvp_email_ins on public.tabi_rsvps;
drop trigger if exists tabi_rsvp_email_upd on public.tabi_rsvps;
-- New RSVP -> send right away.
create trigger tabi_rsvp_email_ins after insert on public.tabi_rsvps
  for each row when (new.email_status = 'pending') execute function public.tabi_rsvp_email_trigger();
-- Re-queued from skipped/failed (re-RSVP or admin retry) -> send right away.
-- Rate-limited retries (sending -> pending) do NOT fire; the 30-min cron sweep picks them up.
create trigger tabi_rsvp_email_upd after update of email_status on public.tabi_rsvps
  for each row when (old.email_status in ('skipped','failed') and new.email_status = 'pending')
  execute function public.tabi_rsvp_email_trigger();
