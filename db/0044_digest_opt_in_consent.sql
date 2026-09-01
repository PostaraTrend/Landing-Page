-- Role Scout migration 0044 v1.1: digest email defaults to opt in for NEW accounts
-- Why: profiles.digest_opt_in has defaulted to true since 0036, so a new seeker
-- would receive the daily digest without ever asking for it. This flips the
-- default to false for accounts created from now on; the seeker turns the
-- existing Preferences toggle on to receive it. EXISTING rows are left exactly
-- as they are (founder ruling Aug 27: current seekers keep receiving it, and
-- the email itself gains a line telling them how to turn it off). The digest
-- lane already reads this column and needs no change for this migration.
-- Run once in the Supabase SQL editor. Safe to run twice.
-- File as db/0044_digest_opt_in_consent.sql.

alter table public.profiles
  alter column digest_opt_in set default false;

comment on column public.profiles.digest_opt_in is
  'Daily match digest consent. New accounts default to false and opt in via the Preferences toggle; accounts existing before migration 0044 kept their prior value. Read by the Role Scout Match Digest lane.';

-- Report card (expected: false, and existing_on unchanged from before the run)
select
  (select column_default from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles' and column_name = 'digest_opt_in') as new_default,
  (select count(*) from public.profiles where digest_opt_in) as existing_on;
