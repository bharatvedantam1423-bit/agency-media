-- Instagram business-profile 400s are an Instagram-side bug: retry daily, never mark the account invalid.
create or replace function private.process_db_fetches()
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare q record; payload jsonb; ok int := 0; failed int := 0; transient int := 0;
begin
  for q in
    select f.*, r.status_code, r.content, r.timed_out, r.error_msg
    from private.fetch_queue f join net._http_response r on r.id = f.request_id
  loop
    payload := null;
    if q.status_code = 200 then
      payload := case q.platform when 'x' then private.parse_x(q.handle, q.content)
                                 else private.parse_instagram(q.handle, q.content) end;
    end if;

    if payload is not null then
      perform ingest(payload);
      ok := ok + 1;
    elsif q.platform = 'instagram' and q.status_code = 400 and q.content like '%ig_business_category%' then
      update accounts set next_collect_at = now() + interval '24 hours',
        last_error = 'Instagram is blocking public data for business profiles right now; retrying daily'
      where id = q.account_id;
      transient := transient + 1;
    elsif q.timed_out or q.status_code is null or q.status_code = 429 or q.status_code >= 500 then
      update accounts set next_collect_at = now() + interval '3 hours', last_error = 'Rate limited or slow, retrying later'
      where id = q.account_id;
      transient := transient + 1;
    else
      perform ingest(jsonb_build_object('account', jsonb_build_object(
        'platform', q.platform, 'handle', q.handle, 'ok', false,
        'error', case when q.status_code = 200 then 'No recent public posts (inactive, private or wrong handle)'
                      else q.platform || ' answered ' || q.status_code end)));
      failed := failed + 1;
    end if;
    delete from private.fetch_queue where request_id = q.request_id;
  end loop;

  delete from private.fetch_queue where queued_at < now() - interval '2 hours';

  if ok + failed + transient > 0 then
    insert into runs(job, finished_at, ok, stats)
    values ('collect_x_instagram', now(), ok > 0 or failed = 0,
            jsonb_build_object('accounts_ok', ok, 'accounts_failed', failed, 'rate_limited', transient));
  end if;
  return jsonb_build_object('ok', ok, 'failed', failed, 'rate_limited', transient);
end $$;

-- One post, dashboard-ready
create or replace function public.post_card(p_id text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', p.id, 'platform', p.platform, 'handle', p.handle,
    'name', a.display_name, 'url', p.url, 'text', left(p.text, 500),
    'posted_at', p.posted_at, 'format', p.format,
    'likes', p.likes, 'reposts', p.reposts, 'replies', p.replies, 'views', p.views,
    'outlier', round(coalesce(p.outlier, 0)::numeric, 2), 'winner', p.is_winner,
    'hook', coalesce(t.hook, p.features->>'hook_h'), 'purpose', t.purpose, 'subject', t.subject,
    'cta', coalesce(t.has_cta >= 0.5, (p.features->>'cta_h')::boolean),
    'specificity', round(t.specificity::numeric, 2), 'slop', round(t.slop::numeric, 2),
    'first_line', p.features->>'first_line', 'tagged', t.post_id is not null)
  from posts p left join accounts a on a.id = p.account_id left join post_tags t on t.post_id = p.id
  where p.id = p_id;
$$;

-- Everything the dashboard shows, in one call. p_days: 30, 90 or 1095 (all time)
create or replace function public.dashboard(p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare w int := public.dashboard_window(p_days); ids text[]; res jsonb;
begin
  select array_agg(distinct x) into ids from (
    select unnest(example_ids) x from pattern_stats where window_days = w
    union select unnest(example_ids) from combo_stats where window_days = w
    union select unnest(example_ids) from hot_topics
  ) s where x is not null;

  res := jsonb_build_object(
    'generated_at', now(),
    'window_days', w,
    'summary', jsonb_build_object(
      'posts', (select count(*) from posts where posted_at > now() - make_interval(days => w)),
      'posts_scored', (select count(*) from posts where posted_at > now() - make_interval(days => w) and outlier is not null),
      'winners', (select count(*) from posts where posted_at > now() - make_interval(days => w) and is_winner),
      'posts_all', (select count(*) from posts),
      'tagged', (select count(*) from post_tags),
      'untagged', (select count(*) from posts p where length(coalesce(p.text, '')) >= 15 and not exists (select 1 from post_tags t where t.post_id = p.id)),
      'accounts_watch', (select count(*) from accounts where status = 'watch'),
      'accounts_candidate', (select count(*) from accounts where status = 'candidate'),
      'accounts_invalid', (select count(*) from accounts where status = 'invalid'),
      'discovered_watch', (select count(*) from accounts where origin = 'discovered' and status = 'watch'),
      'last_collect', (select max(coalesce(finished_at, started_at)) from runs where job like 'collect%'),
      'last_tag', (select max(tagged_at) from post_tags),
      'base_win_rate', (select avg(case when is_winner then 1.0 else 0 end) from posts where outlier is not null and posted_at > now() - make_interval(days => w))
    ),
    'platforms', coalesce((select jsonb_agg(jsonb_build_object('platform', platform, 'posts', n, 'winners', wn, 'accounts', ac) order by n desc)
      from (select platform, count(*) n, count(*) filter (where is_winner) wn, count(distinct account_id) ac
            from posts where posted_at > now() - make_interval(days => w) group by platform) s), '[]'::jsonb),
    'patterns', coalesce((select jsonb_object_agg(dimension, vals) from (
      select dimension, jsonb_agg(jsonb_build_object('value', value, 'posts', posts, 'winners', winners,
             'win_rate', round(win_rate::numeric, 3), 'lift', round(lift::numeric, 2),
             'median_outlier', round(median_outlier::numeric, 2), 'examples', example_ids) order by lift desc nulls last) vals
      from pattern_stats where window_days = w group by dimension) s), '{}'::jsonb),
    'combos', coalesce((select jsonb_agg(c) from (
      select jsonb_build_object('a', dim_a, 'va', val_a, 'b', dim_b, 'vb', val_b, 'posts', posts, 'winners', winners,
             'lift', round(lift::numeric, 2), 'median_outlier', round(median_outlier::numeric, 2), 'examples', example_ids) c
      from combo_stats where window_days = w and winners >= 2 and lift is not null
      order by lift desc, winners desc limit 14) s), '[]'::jsonb),
    'hot_topics', coalesce((select jsonb_agg(jsonb_build_object('term', term, 'posts_now', posts_now, 'posts_prev', posts_prev,
             'growth', round(growth::numeric, 2), 'score', round(score::numeric, 2), 'platforms', platforms, 'examples', example_ids) order by score desc)
      from (select * from hot_topics order by score desc limit 24) h), '[]'::jsonb),
    'top_posts', coalesce((select jsonb_agg(post_card(id) order by outlier desc) from (
      select id, outlier from posts where is_winner and posted_at > now() - make_interval(days => w)
      order by outlier desc limit 40) s), '[]'::jsonb),
    'rising', coalesce((select jsonb_agg(post_card(id) order by early_outlier desc) from (
      select id, early_outlier from posts where posted_at > now() - interval '36 hours' and early_outlier >= 1.5
      order by early_outlier desc limit 12) s), '[]'::jsonb),
    'examples', coalesce((select jsonb_object_agg(x, post_card(x)) from unnest(ids) x), '{}'::jsonb),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'platform', platform, 'handle', handle,
             'name', display_name, 'status', status, 'origin', origin, 'followers', followers,
             'median', round(coalesce(median_eng, 0)::numeric, 1), 'posts', posts_count, 'relevance', round(coalesce(relevance, 0)::numeric, 2),
             'kind', kind, 'error', last_error, 'from', discovered_from, 'url', url, 'added', created_at)
             order by (status = 'watch') desc, (status = 'candidate') desc, coalesce(median_eng, 0) desc)
      from (select * from accounts where status in ('watch', 'invalid')
            union all (select * from accounts where status = 'candidate' order by coalesce(relevance, 0) desc, created_at desc limit 60)) a), '[]'::jsonb),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('platform', platform, 'value', value, 'origin', origin, 'active', active) order by origin, value)
      from sources), '[]'::jsonb),
    'runs', coalesce((select jsonb_agg(r order by (r->>'started_at') desc) from (
      select jsonb_build_object('job', job, 'started_at', started_at, 'finished_at', finished_at, 'ok', ok, 'stats', stats, 'error', error) r
      from runs order by started_at desc limit 15) s), '[]'::jsonb)
  );
  return res;
end $$;
revoke execute on function public.dashboard(int) from public, anon, authenticated;
revoke execute on function public.post_card(text) from public, anon, authenticated;

create or replace function private.cleanup()
returns void language sql security definer set search_path = public as $$
  delete from post_snapshots where captured_at < now() - interval '45 days';
  delete from runs where started_at < now() - interval '14 days';
  delete from accounts where status = 'ignored' and origin = 'discovered' and created_at < now() - interval '60 days'
    and not exists (select 1 from posts p where p.account_id = accounts.id);
$$;

-- Schedules
select cron.schedule('collect-open-platforms', '*/10 * * * *', $$select private.trigger_collect(10, 2)$$);
select cron.schedule('collect-x-instagram', '* * * * *', $$select private.process_db_fetches(); select private.queue_db_fetches(1)$$);
select cron.schedule('score-posts', '7,37 * * * *', $$select public.compute_scores()$$);
select cron.schedule('find-patterns', '20 * * * *', $$select public.refresh_patterns(); select public.refresh_hot_topics(); select public.promote_candidates()$$);
select cron.schedule('cleanup', '40 3 * * *', $$select private.cleanup()$$);
