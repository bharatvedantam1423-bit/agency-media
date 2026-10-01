insert into private.config(key, value) values
  ('collect_secret', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (key) do nothing;

create or replace function public.check_collect_secret(p_secret text)
returns boolean language sql stable security definer set search_path = public as $$
  select p_secret is not null and p_secret = (select value from private.config where key = 'collect_secret');
$$;
revoke execute on function public.check_collect_secret(text) from public, anon, authenticated;

-- Ingest v2: candidates are stored before posts (so hashtag posts attach to their author),
-- and a probed candidate with no design signal is parked instead of watched.
create or replace function public.ingest(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  acc jsonb := p->'account';
  v_acc_id bigint;
  v_status text;
  v_platform text := acc->>'platform';
  v_handle text := acc->>'handle';
  r jsonb;
  n_posts int := 0;
  n_cand int := 0;
  v_interval interval;
begin
  for r in select * from jsonb_array_elements(coalesce(p->'candidates', '[]'::jsonb)) loop
    insert into accounts(platform, handle, display_name, bio, followers, status, origin, discovered_from, relevance, relevance_source)
    values (r->>'platform', r->>'handle', r->>'display_name', r->>'bio', (r->>'followers')::int,
            case when r->>'bio' is not null and bio_relevance(coalesce(r->>'display_name','') || ' ' || coalesce(r->>'bio','')) = 0
                 then 'ignored' else 'candidate' end,
            'discovered', r->>'discovered_from',
            bio_relevance(coalesce(r->>'display_name','') || ' ' || coalesce(r->>'bio','')), 'heuristic')
    on conflict (platform, handle) do update set
      display_name = coalesce(accounts.display_name, excluded.display_name),
      bio = coalesce(accounts.bio, excluded.bio),
      followers = coalesce(excluded.followers, accounts.followers);
    n_cand := n_cand + 1;
  end loop;

  if v_handle is not null then
    select id, status into v_acc_id, v_status from accounts where platform = v_platform and handle = v_handle;
    if v_acc_id is null then
      insert into accounts(platform, handle, status, origin)
      values (v_platform, v_handle, coalesce(acc->>'status','candidate'), coalesce(acc->>'origin','discovered'))
      returning id, status into v_acc_id, v_status;
    end if;

    if coalesce((acc->>'ok')::boolean, true) = false then
      update accounts set fail_count = fail_count + 1,
        last_error = left(acc->>'error', 300),
        status = case when fail_count + 1 >= 3 then 'invalid' else status end,
        next_collect_at = now() + make_interval(hours => 6 * (fail_count + 1)),
        last_collected_at = now()
      where id = v_acc_id;
      return jsonb_build_object('account_id', v_acc_id, 'ok', false);
    end if;

    v_interval := case
      when v_status = 'candidate' then interval '30 days'
      when v_platform in ('x','instagram') then interval '20 hours'
      else interval '10 hours' end;

    update accounts set
      display_name = coalesce(acc->>'display_name', display_name),
      bio = coalesce(acc->>'bio', bio),
      url = coalesce(acc->>'url', url),
      followers = coalesce((acc->>'followers')::int, followers),
      relevance = case when relevance_source = 'laya' then relevance
                       else greatest(coalesce(relevance, 0), bio_relevance(coalesce(acc->>'display_name','') || ' ' || coalesce(acc->>'bio',''))) end,
      relevance_source = coalesce(relevance_source, 'heuristic'),
      fail_count = 0, last_error = null,
      last_collected_at = now(),
      next_collect_at = now() + v_interval + (random() * interval '2 hours')
    where id = v_acc_id;

    update accounts set status = 'ignored'
    where id = v_acc_id and status = 'candidate' and coalesce(relevance_source, '') <> 'laya' and coalesce(relevance, 0) < 0.2;
  end if;

  for r in select * from jsonb_array_elements(coalesce(p->'posts', '[]'::jsonb)) loop
    insert into posts as po (id, platform, account_id, handle, url, text, posted_at, format, media_count,
                             likes, reposts, replies, views, saves, features, lang, via)
    values (r->>'id', r->>'platform',
            coalesce(v_acc_id, (select id from accounts a where a.platform = r->>'platform' and a.handle = r->>'handle')),
            r->>'handle', r->>'url', r->>'text', (r->>'posted_at')::timestamptz, r->>'format',
            coalesce((r->>'media_count')::int, 0),
            coalesce((r->>'likes')::int, 0), coalesce((r->>'reposts')::int, 0), coalesce((r->>'replies')::int, 0),
            (r->>'views')::bigint, (r->>'saves')::int,
            text_features(r->>'text'), r->>'lang', coalesce(r->>'via','timeline'))
    on conflict (id) do update set
      likes = excluded.likes, reposts = excluded.reposts, replies = excluded.replies,
      views = coalesce(excluded.views, po.views), saves = coalesce(excluded.saves, po.saves),
      text = coalesce(excluded.text, po.text),
      account_id = coalesce(po.account_id, excluded.account_id),
      last_seen_at = now();

    insert into post_snapshots(post_id, likes, reposts, replies, views)
    values (r->>'id', coalesce((r->>'likes')::int,0), coalesce((r->>'reposts')::int,0), coalesce((r->>'replies')::int,0), (r->>'views')::bigint)
    on conflict do nothing;

    perform extract_terms(r->>'id', r->>'text');
    n_posts := n_posts + 1;
  end loop;

  return jsonb_build_object('account_id', v_acc_id, 'posts', n_posts, 'candidates', n_cand);
end $$;

-- Watched accounts first; at most 3 candidate probes per run so discovery never crowds out the watchlist.
create or replace function public.next_jobs(p_accounts int default 10, p_sources int default 2)
returns jsonb language sql security definer set search_path = public as $$
  with w as (
    select id, platform, handle, status, url, next_collect_at from accounts
    where status = 'watch' and next_collect_at <= now()
      and platform in ('x','instagram','bluesky','mastodon','youtube')
    order by next_collect_at limit p_accounts
  ), c as (
    select id, platform, handle, status, url, next_collect_at from accounts
    where status = 'candidate' and next_collect_at <= now() and last_collected_at is null
      and platform in ('x','instagram','bluesky','mastodon','youtube')
      and (bio is null or coalesce(relevance, 0) >= 0.2)
    order by coalesce(relevance, 0) desc, created_at limit 3
  )
  select jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'platform', platform, 'handle', handle, 'status', status, 'url', url))
                          from (select * from w union all select * from c) a), '[]'::jsonb),
    'sources', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'platform', platform, 'kind', kind, 'value', value))
      from (select id, platform, kind, value from sources where active and next_collect_at <= now()
            order by next_collect_at limit p_sources) s), '[]'::jsonb)
  );
$$;

revoke execute on function public.ingest(jsonb) from public, anon, authenticated;
revoke execute on function public.next_jobs(int, int) from public, anon, authenticated;
