-- ============================================================================
-- 0054 -- Invitations: a countable, tamper-proof link per therapist
--
-- /invitation already personalises from ?to= and ?note=. That is fine for a
-- link typed by hand, but it cannot be counted (two sends look identical), and
-- the recipient can edit their own name and the note supposedly written about
-- them. So each invitation becomes a row with a short token, and the link is
--     kindredtherapymatch.com/invitation?i=<token>
--
-- ---------------------------------------------------------------------------
-- WHAT THIS TABLE HOLDS, AND WHY IT IS LOCKED HARDER THAN IT LOOKS.
-- Therapists are business contacts, not clients: no PHI, no BAA implications.
-- But "who Kindred is courting, and what was said about them" is commercially
-- sensitive and personally awkward -- a note reading "Sarah says she is
-- unhappy at her group practice" must never be readable by anyone but us, and
-- least of all by another therapist. So the table is closed to everyone except
-- hq_members, and the only public access is one function returning one
-- invitation's greeting, by exact token, and nothing else.
-- ---------------------------------------------------------------------------
-- ============================================================================

create table if not exists invitations (
  token       text primary key,
  name        text,
  note        text,
  created_at  timestamptz not null default now(),
  created_by  uuid references auth.users on delete set null,
  opened_at   timestamptz,              -- first open only; never overwritten
  open_count  int not null default 0,
  accepted_at timestamptz               -- they signed up from this link
);

comment on table invitations is
  'One row per therapist invitation. Closed to everyone but hq_members; the public reaches exactly one row, by exact token, through invitation_greeting(). Business contacts, not clients -- no PHI here, but the notes are commercially sensitive and must stay ours.';

alter table invitations enable row level security;

-- Nobody but HQ. No anon policy at all, so PostgREST refuses the table outright.
drop policy if exists invitations_hq_all on invitations;
create policy invitations_hq_all on invitations
  for all
  using  (exists (select 1 from hq_members m where m.user_id = auth.uid()))
  with check (exists (select 1 from hq_members m where m.user_id = auth.uid()));

-- ---------------------------------------------------------------------------
-- Token alphabet excludes 0/O/1/l/I so a token can be read aloud or retyped
-- from a screenshot without ambiguity. 8 chars of 32 is ~1.1e12 combinations,
-- which is the only thing standing between a stranger and someone else's
-- greeting -- there is deliberately no listing endpoint to enumerate.
-- ---------------------------------------------------------------------------
create or replace function new_invitation_token()
returns text
language plpgsql
as $$
declare
  alphabet constant text := 'abcdefghjkmnpqrstuvwxyz23456789';
  t text;
begin
  loop
    t := '';
    for i in 1..8 loop
      t := t || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from invitations where token = t);
  end loop;
  return t;
end;
$$;

-- ---------------------------------------------------------------------------
-- HQ creates one. Restricted to hq_members: without the guard this would be an
-- open endpoint for writing arbitrary text that then renders on our domain.
-- ---------------------------------------------------------------------------
create or replace function create_invitation(p_name text, p_note text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text;
begin
  if not exists (select 1 from hq_members m where m.user_id = auth.uid()) then
    raise exception 'not permitted' using errcode = '42501';
  end if;
  v_token := new_invitation_token();
  insert into invitations (token, name, note, created_by)
  values (v_token, nullif(btrim(coalesce(p_name, '')), ''),
                   nullif(btrim(coalesce(p_note, '')), ''), auth.uid());
  return v_token;
end;
$$;

-- ---------------------------------------------------------------------------
-- The page reads its own greeting. Returns NAME AND NOTE ONLY -- never the
-- token list, never created_by, never the counts. An unknown token returns no
-- rows rather than an error, so a wrong link degrades to the plain "Hello,"
-- the page shows anyway instead of announcing that it guessed wrong.
-- ---------------------------------------------------------------------------
create or replace function invitation_greeting(p_token text)
returns table (name text, note text)
language sql
security definer
set search_path = public
stable
as $$
  select i.name, i.note from invitations i where i.token = p_token;
$$;

-- ---------------------------------------------------------------------------
-- Record an open. Anyone holding the token can call this, so it is capped:
-- opened_at is written once and never moved, and open_count stops at 50. A
-- counter someone can drive to a million tells you nothing, and an opened_at
-- that keeps advancing loses the only fact worth having -- when it first
-- landed.
-- ---------------------------------------------------------------------------
create or replace function invitation_opened(p_token text)
returns void
language sql
security definer
set search_path = public
as $$
  update invitations
     set opened_at  = coalesce(opened_at, now()),
         open_count = least(open_count + 1, 50)
   where token = p_token;
$$;

-- Marks the invitation that produced a signup. Same reasoning as above: set
-- once, never moved, so "when did they accept" stays answerable.
create or replace function invitation_accepted(p_token text)
returns void
language sql
security definer
set search_path = public
as $$
  update invitations
     set accepted_at = coalesce(accepted_at, now())
   where token = p_token;
$$;

revoke all on function create_invitation(text, text) from anon;
grant execute on function invitation_greeting(text) to anon, authenticated;
grant execute on function invitation_opened(text)   to anon, authenticated;
grant execute on function invitation_accepted(text) to anon, authenticated;
grant execute on function create_invitation(text, text) to authenticated;

-- Proof (run separately):
--   select create_invitation('Test Therapist', 'A note.');        -- a token
--   select * from invitation_greeting('<that token>');            -- name + note
--   select invitation_opened('<that token>');
--   select token, name, opened_at, open_count from invitations;   -- HQ only
--   -- and from the anon key, `invitations` itself must answer 42501.
