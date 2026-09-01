-- Role Scout migration 0043: one posting per role in matching
-- Why: the pool holds the same role many times (one row per location or per feed), so a seeker
-- could see nine identical cards and spend nine of ten daily tailorings on one job. Scoring now
-- offers each seeker one posting per title and employer (the freshest), and never re offers a role
-- the seeker already holds under the same title and employer. Supplied postings are always kept.
-- The two minute allowance from 0042 is carried inside this definition. Signature and results
-- shape unchanged.
-- Run once in the Supabase SQL editor. Safe to run twice. File as db/0043_pairs_dedupe.sql.

create or replace function public.role_scout_pairs_to_score(cap integer DEFAULT 30)
 RETURNS TABLE(seeker_id uuid, posting_id uuid, record_id uuid, title text, employer text, location text, description text, posted_date date, target_roles text[], seniority text, location_pref text, salary_floor numeric, resume_lines jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '120s'
AS $function$
  with attested as (
    -- v0041: the record in force for each seeker (chosen active version, else newest attested);
    -- effective_since moves to now when the seeker switches, so a switch re-scores like a fresh attestation.
    select v.seeker_id, v.record_id, v.effective_since as attested_at
    from public.seeker_active_record v
  ),
  candidates as (
    select p.id as seeker_id, po.id as posting_id, a.record_id,
      po.title, po.employer, po.location, po.description, po.posted_date,
      p.target_roles, p.seniority, p.location_pref, p.salary_floor,
      coalesce(po.posted_date, po.discovered_at::date) as recency_date,
      po.owner_seeker_id,
      case
        when p.target_roles is null or cardinality(p.target_roles) = 0 then 0
        else
          -- strong signal: the whole chip phrase appears in the title (three points)
          coalesce((
            select count(*)
            from unnest(p.target_roles) chip
            where length(replace(chip, ' ', '')) >= 4
              and position(lower(chip) in lower(po.title)) > 0
          ), 0) * 3
          +
          -- weak signal: distinct significant chip words present as whole words (one point each)
          coalesce((
            select count(distinct w)
            from unnest(p.target_roles) chip,
                 regexp_split_to_table(lower(chip), '\s+') w
            where length(w) >= 4
              and lower(po.title) ~ ('\y' || regexp_replace(w, '([^a-z0-9])', '\\\1', 'g') || '\y')
          ), 0)
      end as relevance
    from profiles p
    join attested a on a.seeker_id = p.id
    join postings po
      on (po.country = p.country_of_search or po.country = 'Global')
     and po.active = true
     and (po.owner_seeker_id is null or po.owner_seeker_id = p.id)
     and coalesce(po.posted_date, po.discovered_at::date) >= current_date - 21
    where p.attestation_status = 'attested'
      and not exists (
        select 1 from matches m
        where m.seeker_id = p.id and m.posting_id = po.id
          and (m.status = 'dismissed'
               or (m.created_at >= a.attested_at and (po.owner_seeker_id is null or m.score is not null)))
      )
  ),
  eligible as (
    select *
    from candidates
    where target_roles is null
       or cardinality(target_roles) = 0
       or relevance > 0
       or owner_seeker_id is not null
  ),
  -- 0043: the pool holds the same role many times (one row per location or per feed). Offer each
  -- seeker one posting per title and employer, the freshest, and never a role the seeker already
  -- holds under that title and employer. Postings the seeker supplied are always kept.
  deduped as (
    select distinct on (seeker_id, (owner_seeker_id is not null), lower(title), lower(coalesce(employer, '')))
      *
    from eligible e
    where owner_seeker_id is not null
       or not exists (
         select 1
         from matches m2
         join postings p2 on p2.id = m2.posting_id
         where m2.seeker_id = e.seeker_id
           and lower(p2.title) = lower(e.title)
           and lower(coalesce(p2.employer, '')) = lower(coalesce(e.employer, ''))
           and m2.status <> 'dismissed'
           and m2.score is not null
       )
    order by seeker_id, (owner_seeker_id is not null), lower(title), lower(coalesce(employer, '')), recency_date desc, posting_id
  ),
  ranked as (
    select *,
      row_number() over (
        partition by seeker_id
        order by (owner_seeker_id is not null) desc, relevance desc, recency_date desc
      ) as rn
    from deduped
  )
  select seeker_id, posting_id, record_id, title, employer, location,
    description, posted_date, target_roles, seniority, location_pref,
    salary_floor,
    (select jsonb_agg(jsonb_build_object('section', sl.section, 'content', sl.content)
       order by sl.line_number)
     from source_lines sl where sl.record_id = ranked.record_id) as resume_lines
  from ranked
  where rn <= cap
$function$;

-- Report card (expected: true, true)
select
  (select prosrc like '%deduped as (%' from pg_proc where proname = 'role_scout_pairs_to_score') as dedupe_present,
  (select exists (select 1 from pg_proc p, unnest(p.proconfig) c where p.proname = 'role_scout_pairs_to_score' and c = 'statement_timeout=120s')) as timeout_kept;
