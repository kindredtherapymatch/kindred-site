-- ============================================================================
-- 0056 -- "Delete my account" actually deletes the account
--
-- It never did. confirmDeleteAccount() cleared localStorage and signed out;
-- the auth.users row survived with the person's email on it, and they could
-- sign straight back in with the same credentials. Verified by doing exactly
-- that.
--
-- The UI says "Deleting is permanent" and "Everything you've saved will be
-- permanently deleted". That was true of their saved data, which is local --
-- and false about the account, which is the thing the button names. Someone
-- who asks a therapy service to delete them, and whose email stays in the
-- database, is a right-to-erasure problem regardless of the BAA.
--
-- ---------------------------------------------------------------------------
-- WHY A SECURITY DEFINER FUNCTION AND NOT AN API CALL. Deleting an auth user
-- normally needs the service_role key, which can never be in a browser. This
-- runs as the definer instead and takes NO parameters, so it can only ever
-- delete auth.uid() -- the caller, and nobody else. There is no argument to
-- tamper with.
-- ---------------------------------------------------------------------------
--
-- 0036 did this for therapists but stopped at the therapists row, leaving the
-- auth user behind too. Same gap, same fix; that one is left alone here
-- because it also handles Stripe, and touching it is a separate change.
-- ============================================================================

create or replace function delete_my_account()
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  uid   uuid := auth.uid();
  mail  text;
  n     int  := 0;
begin
  if uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  select lower(u.email) into mail from auth.users u where u.id = uid;

  /* Inquiries they sent. Matched on client_id AND on email, because the
     email-only front door (0047) can create an inquiry before the person ever
     has an account -- those rows carry the address but no id.

     Deliberate: this removes the therapist's copy of the message too. An
     inquiry is pre-relationship correspondence, not a clinical record, and the
     button promises "conversations" are gone. That stops being the right call
     the day a real therapeutic relationship exists -- therapists then have
     record-retention obligations that outrank an erasure request. Revisit when
     clientDataPersistence turns on. */
  delete from client_inquiries
   where client_id = uid
      or (mail is not null and lower(email) = mail);

  /* The waitlist, if they are on it. Contact details only, no health data. */
  delete from client_notify
   where mail is not null and lower(email) = mail;

  /* Last, so a failure above leaves them able to sign in and try again rather
     than orphaned: an account they cannot reach but whose data still exists is
     worse than one that did not delete. */
  delete from auth.users where id = uid;
  get diagnostics n = row_count;

  /* Returned so the caller can tell a real deletion from a no-op -- the same
     reason 0036 returns a count. The app must not claim success and sign
     someone out on a lie. */
  return n;
end;
$$;

comment on function delete_my_account() is
  'Client self-deletion: their inquiries, their waitlist row, and their auth user. Takes no arguments so it can only ever delete auth.uid(). Returns 1 on a real deletion, 0 if there was nothing to remove.';

revoke all on function delete_my_account() from anon;
grant execute on function delete_my_account() to authenticated;

-- Proof (run separately, as a signed-in test client):
--   select delete_my_account();     -- 1
--   -- then try to sign in again with the same credentials: it must fail.
