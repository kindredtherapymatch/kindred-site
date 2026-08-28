-- ============================================================================
-- 0055 -- Six months from signup, not from go-live
--
-- 0029 started the clock at first go-live so a therapist waiting on a
-- hand-checked licence wouldn't burn part of their free period in a queue they
-- couldn't influence. Fair, and it cost two things that turned out to matter
-- more:
--
--   1. It is unforecastable. Nobody can say when revenue starts, because it
--      depends on when each therapist happens to finish verification. HQ's
--      revenue model has no date to key off.
--   2. It never ends for someone who stalls. free_until stays NULL, and
--      listing_is_entitled() reads NULL as entitled -- so an unverified
--      therapist sits in an unbounded free period indefinitely.
--
-- Signup is knowable, explainable in one sentence, and the same for everyone.
--
-- THE COST, stated plainly: a slow licence check now eats into a therapist's
-- free time. At the promised 5 business days out of ~180 that is roughly 3%,
-- which is acceptable -- but LICENSE_CHECK_SLA in app.js is no longer only a
-- courtesy. Missing it now costs them money.
--
-- "Signup" here is the INSERT into therapists, which happens on their first
-- profile save -- not at account creation. Someone who makes an account and
-- never writes anything has no row and no clock, which is right.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The clock starts on the row.
-- ---------------------------------------------------------------------------
alter table therapists
  alter column free_until set default (now() + interval '6 months');

-- ---------------------------------------------------------------------------
-- 2. Retire the go-live trigger. Leaving it would be harmless but misleading:
--    its guard only fires on NULL, and nothing is NULL any more.
-- ---------------------------------------------------------------------------
drop trigger if exists trg_start_free_period on therapists;
drop function if exists start_free_period();

-- ---------------------------------------------------------------------------
-- 3. Anyone currently sitting on NULL has been waiting under the old rule.
--    Start them now rather than retroactively -- nobody loses free time to the
--    date this shipped. Existing dates are left exactly alone, so Desirae
--    keeps 2027-03-01: never move an existing therapist's free period earlier
--    than what they were already promised.
-- ---------------------------------------------------------------------------
update therapists
   set free_until = now() + interval '6 months'
 where free_until is null;

comment on column therapists.free_until is
  'End of this therapist''s six free months, set on INSERT (their first profile save). Per-row on purpose: extending a founding cohort, or making good on a slow licence check, should be an UPDATE and not a deploy. listing_is_entitled() still reads NULL as entitled, which now only happens if someone clears it deliberately.';

-- Proof (run separately):
--   select tgname from pg_trigger where tgname = 'trg_start_free_period';  -- 0 rows
--   select name, free_until, created_at from therapists order by created_at;
--     -- every row has a date; Desirae still 2027-03-01
--   -- and the default is live:
--   select column_default from information_schema.columns
--    where table_name = 'therapists' and column_name = 'free_until';
