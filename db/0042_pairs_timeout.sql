-- Role Scout migration 0042: let the scoring function finish through the API
-- Why: role_scout_pairs_to_score now takes seven to nine seconds against the larger posting
-- pool, and the API allows about eight seconds per call. The webhook triggered scoring runs
-- (attest, active version switch, supplied posting) died at that limit with 57014 while the
-- six hourly sweeps mostly slipped under it. Give the function its own two minute allowance,
-- the same fix applied to the NOC lane functions in 0040. Body and signature unchanged.
-- Run once in the Supabase SQL editor. Safe to run twice. File as db/0042_pairs_timeout.sql.

alter function public.role_scout_pairs_to_score(integer) set statement_timeout = '120s';

-- Report card (expected: true)
select exists (
  select 1 from pg_proc p, unnest(p.proconfig) c
  where p.proname = 'role_scout_pairs_to_score' and c = 'statement_timeout=120s'
) as timeout_set;
