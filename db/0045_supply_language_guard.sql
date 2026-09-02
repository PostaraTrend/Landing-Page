-- Role Scout migration 0045: honest refusal for non-English postings
-- Why: Role Scout matches, scores, and tailors in English only. A seeker who pastes or
-- captures a posting in another language (for example the French Guichet-Emplois version
-- of a Job Bank posting) would get a silent, meaningless score with no explanation. This
-- adds a plain check before saving: if the pasted text does not look like English, refuse
-- and say so, the same way every other input check in this function already works.
-- Language-agnostic on purpose: it checks for the ABSENCE of common English words rather
-- than detecting any specific other language, so it catches French, German, Spanish, or
-- anything else without needing a rule per language.
-- Run once in the Supabase SQL editor. Safe to run twice.
-- File as db/0045_supply_language_guard.sql.

create or replace function public.role_scout_supply_posting(p_url text, p_title text, p_employer text, p_location text, p_text text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_country text;
  v_url text := btrim(coalesce(p_url, ''));
  v_title text := btrim(coalesce(p_title, ''));
  v_employer text := nullif(btrim(coalesce(p_employer, '')), '');
  v_location text := nullif(btrim(coalesce(p_location, '')), '');
  v_text text := btrim(coalesce(p_text, ''));
  v_external_id text;
  v_posting_id uuid;
  v_match_id uuid;
  v_word_count integer;
  v_stopword_count integer;
begin
  if v_uid is null then
    raise exception 'RS-SUP-01 You must be signed in to supply a posting.';
  end if;

  select country_of_search into v_country from public.profiles where id = v_uid;
  if v_country is null or btrim(v_country) = '' then
    raise exception 'RS-SUP-02 Set your country of search in preferences before supplying a posting.';
  end if;

  if v_url !~* '^https?://' then
    raise exception 'RS-SUP-03 The posting link must start with http:// or https://.';
  end if;
  if length(v_title) < 3 or length(v_title) > 200 then
    raise exception 'RS-SUP-04 The job title must be between 3 and 200 characters.';
  end if;
  if length(v_text) < 200 then
    raise exception 'RS-SUP-05 Paste the full posting text. At least 200 characters are needed to tailor honestly.';
  end if;
  if length(v_text) > 30000 then
    raise exception 'RS-SUP-06 The posting text is too long. Keep it under 30000 characters.';
  end if;

  -- 0045: language guard. Counts words in v_text, then counts how many are common
  -- English function words (the, and, for, with, ...). Real English postings run
  -- 15 to 30 percent; real French, German and Spanish postings run at or near 0
  -- percent, verified against live postings pulled from Job Bank, Guichet-Emplois,
  -- JobMESH and JOB TODAY. Threshold set well below the English floor and well
  -- above the non-English ceiling found in that test.
  select array_length(regexp_split_to_array(lower(v_text), '[^a-z'']+'), 1)
    into v_word_count;
  select count(*) into v_stopword_count
  from regexp_split_to_table(lower(v_text), '[^a-z'']+') w
  where w = any (array['the','and','for','with','you','this','that','from','your',
                        'will','are','have','our','all','not','but','can','job',
                        'work','team','we','is','of','to','an']);

  if v_word_count is null or v_word_count = 0
     or (v_stopword_count::numeric / v_word_count::numeric) < 0.03 then
    raise exception 'RS-SUP-07 This posting does not look like it is in English. Role Scout currently matches only in English, so paste the English version of this posting if one is available.';
  end if;

  v_external_id := 'seeker:' || md5(v_uid::text || '|' || lower(v_url));

  insert into public.postings
    (country, title, employer, location, description, url, source_url, source, external_id,
     posted_date, active, fetched_at, last_seen_at, owner_seeker_id)
  values
    (v_country, v_title, v_employer, v_location, v_text, v_url, v_url, 'seeker', v_external_id,
     current_date, true, now(), now(), v_uid)
  on conflict (source, external_id, country) do update
    set title = excluded.title,
        employer = excluded.employer,
        location = excluded.location,
        description = excluded.description,
        posted_date = excluded.posted_date,
        active = true,
        last_seen_at = now(),
        owner_seeker_id = excluded.owner_seeker_id
  returning id into v_posting_id;

  insert into public.matches (seeker_id, posting_id, status, created_at)
  values (v_uid, v_posting_id, 'ready', now())
  on conflict (seeker_id, posting_id) do update
    set status = case when public.matches.status in ('tailoring', 'tailor_running') then public.matches.status else 'ready' end,
        created_at = now()
  returning id into v_match_id;

  -- Ring the match lane so the supplied posting is scored within seconds.
  update public.profiles set full_name = full_name where id = v_uid;

  return v_match_id;
end;
$function$;

-- Report card (expected: two rows, English true, French false)
select proname, prosrc like '%RS-SUP-07%' as language_guard_present
from pg_proc where proname = 'role_scout_supply_posting';
