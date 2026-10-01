-- One definition of "an account we trust to represent design agencies and business owners",
-- reused by hot topics and the dashboard so every number comes from the same pool.
-- Safe to re-run. Already applied to the live project.

create or replace view public.trusted_accounts with (security_invoker = true) as
  select a.* from accounts a
  where a.status = 'watch'
    and (a.origin in ('seed', 'manual')
         or (a.relevance_source = 'laya' and a.relevance >= 0.5 and a.kind in ('agency', 'freelancer', 'business')));

create or replace view public.trusted_posts with (security_invoker = true) as
  select p.* from posts p join trusted_accounts a on a.id = p.account_id;

revoke all on public.trusted_accounts from public, anon, authenticated;
revoke all on public.trusted_posts from public, anon, authenticated;

-- Hot topics: only posts from trusted accounts
do $$ declare d text; begin
  select pg_get_functiondef('public.refresh_hot_topics()'::regprocedure) into d;
  d := replace(d, 'from post_terms pt join posts p on p.id = pt.post_id', 'from post_terms pt join trusted_posts p on p.id = pt.post_id');
  execute d;
end $$;

-- Dashboard: window numbers, top posts and rising posts from trusted accounts;
-- "waiting for Laya" counts only posts Laya will actually read (watched accounts).
do $$ declare d text; begin
  select pg_get_functiondef('public.dashboard(int)'::regprocedure) into d;
  d := replace(d, 'from posts where ', 'from trusted_posts where ');
  d := replace(d, 'join accounts a on a.id = p.account_id and a.status = ''watch''', 'join trusted_accounts a on a.id = p.account_id');
  d := replace(d, 'from posts p where length(coalesce(p.text, '''')) >= 15 and not exists',
                  'from posts p join accounts wa on wa.id = p.account_id and wa.status = ''watch'' where length(coalesce(p.text, '''')) >= 15 and not exists');
  execute d;
end $$;
