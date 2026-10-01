-- Focus the system on design agencies, studios, freelancers and business owners.
-- Safe to re-run. Already applied to the live project.
--
-- Rules:
--   * Seed and manual accounts are always trusted.
--   * Discovered accounts only count (and only get promoted) once Laya has classified them as
--     agency / freelancer / business with relevance >= 0.5 (promotion needs >= 0.6).
--   * Patterns are computed only from posts of trusted accounts.

-- ---------------------------------------------------------------------------
-- Functions that exist in the live project (pause switch + discovery guard)
-- ---------------------------------------------------------------------------
create or replace function public.collection_status()
returns jsonb language sql stable security definer set search_path = public, cron as $$
  select jsonb_build_object(
    'paused', not coalesce(bool_or(active), false),
    'jobs', jsonb_object_agg(jobname, active))
  from cron.job where jobname in ('collect-open-platforms','collect-x-instagram','score-posts','find-patterns');
$$;

create or replace function public.set_collection_paused(p_paused boolean)
returns jsonb language plpgsql security definer set search_path = public, cron as $$
declare j record;
begin
  for j in select jobid from cron.job where jobname in ('collect-open-platforms','collect-x-instagram','score-posts','find-patterns') loop
    perform cron.alter_job(j.jobid, active := not p_paused);
  end loop;
  return public.collection_status();
end $$;

create or replace function private.discovery_allowed(p_platform text, p_handle text)
returns boolean language sql stable set search_path = public as $$
  select coalesce((
    select a.origin in ('seed', 'manual')
        or (a.status = 'watch' and coalesce(a.relevance, 0) >= 0.5)
    from accounts a where a.platform = p_platform and a.handle = p_handle), p_handle is null);
$$;

-- ---------------------------------------------------------------------------
-- 1) Tag posts only for accounts we actually watch (31k+ posts, most from parked candidates)
-- ---------------------------------------------------------------------------
create or replace function public.laya_next_posts(p_token text, p_limit int default 25)
returns table(id text, platform text, handle text, text text)
language plpgsql security definer set search_path = public as $$
begin
  if p_token is distinct from (select value from private.config where key = 'worker_token') then
    raise exception 'invalid worker token';
  end if;
  return query
    select p.id, p.platform, p.handle, left(p.text, 3000)
    from posts p
    join accounts a on a.id = p.account_id and a.status = 'watch'
    left join post_tags t on t.post_id = p.id
    where t.post_id is null and length(coalesce(p.text, '')) >= 15
    order by p.is_winner desc, p.posted_at desc nulls last
    limit least(p_limit, 100);
end $$;

-- ---------------------------------------------------------------------------
-- 2) Classify accounts first: watched accounts, then the most promising candidates
-- ---------------------------------------------------------------------------
create or replace function public.laya_next_accounts(p_token text, p_limit int default 25)
returns table(id bigint, platform text, handle text, profile text)
language plpgsql security definer set search_path = public as $$
begin
  if p_token is distinct from (select value from private.config where key = 'worker_token') then
    raise exception 'invalid worker token';
  end if;
  return query
    select a.id, a.platform, a.handle,
           left(coalesce(a.display_name, '') || E'\n' || coalesce(a.bio, '') || E'\n\nRecent posts:\n' ||
             coalesce((select string_agg(left(p.text, 280), E'\n---\n') from (
               select text from posts where account_id = a.id order by posted_at desc limit 3) p), ''), 2500)
    from accounts a
    where a.status in ('candidate', 'watch') and coalesce(a.relevance_source, '') <> 'laya'
      and (a.bio is not null or a.posts_count > 0)
      and (a.status = 'watch' or coalesce(a.relevance, 0) > 0 or a.posts_count > 0)
    order by (a.status = 'watch') desc, coalesce(a.relevance, 0) desc, a.created_at
    limit least(p_limit, 100);
end $$;

-- Saves Laya's verdict. A discovered account that is not an agency / freelancer / business is parked.
create or replace function public.laya_save_accounts(p_token text, p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if p_token is distinct from (select value from private.config where key = 'worker_token') then
    raise exception 'invalid worker token';
  end if;
  update accounts a set relevance = (r->>'relevance')::real, kind = coalesce(r->>'kind', a.kind), relevance_source = 'laya'
  from jsonb_array_elements(p_rows) r
  where a.id = (r->>'id')::bigint;
  get diagnostics n = row_count;

  update accounts a set status = 'ignored'
  from jsonb_array_elements(p_rows) r
  where a.id = (r->>'id')::bigint and a.origin = 'discovered' and a.status in ('candidate', 'watch')
    and (coalesce((r->>'relevance')::real, 0) < 0.5 or coalesce(r->>'kind', '') not in ('agency', 'freelancer', 'business'));
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- 3) Promote only Laya-verified agencies / freelancers / business owners
-- ---------------------------------------------------------------------------
create or replace function public.promote_candidates()
returns jsonb language plpgsql security definer set search_path = public as $$
declare promoted int; pruned int;
begin
  with pick as (
    select a.id from accounts a
    where a.status = 'candidate' and a.posts_count >= 5
      and a.relevance_source = 'laya' and coalesce(a.relevance, 0) >= 0.6
      and a.kind in ('agency', 'freelancer', 'business')
      and coalesce(a.followers, 0) between 300 and 300000
      and coalesce(a.median_eng, 0) >= 3
    order by a.relevance desc, a.median_eng desc
    limit 40
  )
  update accounts set status = 'watch', next_collect_at = now() where id in (select id from pick);
  get diagnostics promoted = row_count;

  with ranked as (
    select id, row_number() over (partition by platform order by (origin = 'seed') desc,
             coalesce(relevance, 0.3) * ln(2 + coalesce(median_eng, 0)) desc) rn
    from accounts where status = 'watch'
  )
  update accounts set status = 'ignored' where id in (select id from ranked where rn > 150);
  get diagnostics pruned = row_count;
  return jsonb_build_object('promoted', promoted, 'pruned', pruned);
end $$;

-- ---------------------------------------------------------------------------
-- 4) Patterns only from trusted accounts (same columns as before)
-- ---------------------------------------------------------------------------
create or replace view public.post_dims with (security_invoker = true) as
 SELECT p.id,
    p.platform,
    p.posted_at,
    p.outlier,
    p.is_winner,
    p.engagement,
    t.purpose,
    COALESCE(t.hook, p.features ->> 'hook_h') AS hook,
    t.subject,
    p.format,
        CASE
            WHEN COALESCE(t.has_cta,
            CASE
                WHEN (p.features ->> 'cta_h')::boolean THEN 1
                ELSE 0
            END::real) >= 0.5::double precision THEN 'with_cta'
            ELSE 'no_cta'
        END AS cta,
    p.features ->> 'length_bucket' AS length,
    TRIM(BOTH FROM to_char((p.posted_at AT TIME ZONE 'UTC'), 'Day')) AS weekday,
        CASE
            WHEN t.specificity IS NULL THEN NULL
            WHEN t.specificity >= 1.5::double precision THEN 'specific'
            ELSE 'vague'
        END AS specificity,
        CASE
            WHEN t.slop IS NULL THEN NULL
            WHEN t.slop >= 0.6::double precision THEN 'sounds_ai'
            ELSE 'sounds_human'
        END AS voice,
    COALESCE(t.relevant, 1::real) AS relevant
   FROM posts p
     JOIN accounts a ON a.id = p.account_id AND a.status = 'watch'
          AND (a.origin IN ('seed', 'manual')
               OR (a.relevance_source = 'laya' AND a.relevance >= 0.5 AND a.kind IN ('agency', 'freelancer', 'business')))
     LEFT JOIN post_tags t ON t.post_id = p.id
  WHERE p.outlier IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 5) Worker access: the four Laya RPCs only
-- ---------------------------------------------------------------------------
revoke execute on function public.laya_next_posts(text, int) from public;
revoke execute on function public.laya_next_accounts(text, int) from public;
revoke execute on function public.laya_save_accounts(text, jsonb) from public;
revoke execute on function public.promote_candidates() from public, anon, authenticated;
grant execute on function public.laya_next_posts(text, int) to anon, authenticated;
grant execute on function public.laya_next_accounts(text, int) to anon, authenticated;
grant execute on function public.laya_save_accounts(text, jsonb) to anon, authenticated;
revoke execute on function public.collection_status() from public, anon, authenticated;
revoke execute on function public.set_collection_paused(boolean) from public, anon, authenticated;
