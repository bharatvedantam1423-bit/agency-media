-- Contra: Discover pages + designer profiles, parsed from the page's embedded data (likes, views, publish date).

create or replace function public.engagement_for(p_platform text, p_likes int, p_reposts int, p_replies int, p_views bigint, p_saves int)
returns real language sql immutable set search_path = public as $$
  select (case
    when p_platform = 'youtube' then coalesce(p_views,0) / 20.0 + coalesce(p_likes,0) + 3 * coalesce(p_replies,0)
    when p_platform = 'instagram' then coalesce(p_likes,0) + 3 * coalesce(p_replies,0) + coalesce(p_views,0) / 50.0
    when p_platform = 'contra' then 3 * coalesce(p_likes,0) + coalesce(p_views,0) / 10.0 + 3 * coalesce(p_replies,0)
    else coalesce(p_likes,0) + 2 * coalesce(p_reposts,0) + 3 * coalesce(p_replies,0) + 2 * coalesce(p_saves,0)
  end)::real;
$$;

create or replace function private.parse_contra(p_html text, p_from text)
returns jsonb language plpgsql set search_path = public as $$
declare j jsonb; v_posts jsonb; v_cands jsonb;
begin
  begin
    j := substring(p_html from '<script id="vike_pageContext" type="application/json">(.*?)</script>')::jsonb;
  exception when others then return null;
  end;
  if j is null then return null; end if;

  create temp table if not exists _cr (r jsonb) on commit drop;
  truncate _cr;
  insert into _cr select x from jsonb_path_query(j, 'lax $.**') x
  where jsonb_typeof(x) = 'object' and x->>'__typename' in ('PortfolioProject', 'UserProfile');

  select coalesce(jsonb_agg(distinct jsonb_build_object(
      'platform', 'contra', 'handle', u->>'displayUsername',
      'display_name', nullif(trim(concat_ws(' ', u->>'firstName', u->>'lastName')), ''),
      'bio', concat_ws(' — ', u->>'title', 'designer on Contra'),
      'followers', (u->>'followerCount')::int, 'discovered_from', p_from)), '[]'::jsonb)
  into v_cands
  from (select c0.r as u from _cr c0) x
  where u->>'__typename' = 'UserProfile' and u->>'displayUsername' ~ '^[A-Za-z0-9_.-]{1,40}$';

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', 'contra:' || (p->>'slug'), 'platform', 'contra', 'handle', u->>'displayUsername',
      'url', 'https://contra.com/p/' || (p->>'slug'),
      'text', p->>'title', 'posted_at', p->>'publishedAt', 'format', 'image', 'media_count', 1,
      'likes', coalesce((p->>'likeCount')::int, 0), 'reposts', 0, 'replies', 0,
      'views', (p->>'viewCount')::bigint, 'via', 'contra')), '[]'::jsonb)
  into v_posts
  from (select c1.r as p from _cr c1 where c1.r->>'__typename' = 'PortfolioProject' and c1.r->>'slug' is not null) a
  left join lateral (select c2.r as u from _cr c2 where c2.r->>'__id' = a.p#>>'{userProfile,__ref}' limit 1) ux on true;

  return jsonb_build_object('posts', v_posts, 'candidates', v_cands);
end $$;

insert into public.sources(platform, kind, value, origin) values
  ('contra', 'keyword', '/discover', 'seed'), ('contra', 'keyword', '/', 'seed')
on conflict do nothing;

-- Queue: watched X / Instagram / Contra accounts (one a minute) plus due Contra pages.
create or replace function private.queue_db_fetches(p_n int default 1)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare a record; s record; rid bigint; n int := 0;
  ua jsonb := '{"User-Agent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36","Accept-Language":"en-US,en;q=0.9"}'::jsonb;
begin
  for a in
    select * from accounts acc
    where acc.platform in ('x','instagram','contra') and acc.next_collect_at <= now()
      and (acc.status = 'watch' or (acc.status = 'candidate' and acc.last_collected_at is null and (acc.bio is null or coalesce(acc.relevance,0) >= 0.2)))
      and not exists (select 1 from private.fetch_queue q where q.account_id = acc.id)
    order by (acc.status = 'watch') desc, acc.next_collect_at
    limit p_n
  loop
    rid := case a.platform
      when 'x' then net.http_get(url := 'https://syndication.twitter.com/srv/timeline-profile/screen-name/' || a.handle, headers := ua, timeout_milliseconds := 30000)
      when 'instagram' then net.http_get(url := 'https://www.instagram.com/api/v1/users/web_profile_info/?username=' || a.handle,
                                         headers := ua || '{"x-ig-app-id":"936619743392459","Accept":"*/*"}'::jsonb, timeout_milliseconds := 30000)
      else net.http_get(url := 'https://contra.com/' || a.handle, headers := ua, timeout_milliseconds := 30000) end;
    insert into private.fetch_queue(request_id, account_id, platform, handle) values (rid, a.id, a.platform, a.handle);
    update accounts set next_collect_at = now() + interval '45 minutes' where id = a.id;
    n := n + 1;
  end loop;

  for s in select * from sources where platform = 'contra' and active and next_collect_at <= now() order by next_collect_at limit 1 loop
    rid := net.http_get(url := 'https://contra.com' || s.value, headers := ua, timeout_milliseconds := 30000);
    insert into private.fetch_queue(request_id, account_id, platform, handle) values (rid, -s.id, 'contra_page', s.value);
    update sources set last_collected_at = now(), next_collect_at = now() + interval '30 minutes' where id = s.id;
    n := n + 1;
  end loop;
  return n;
end $$;

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
      payload := case q.platform
        when 'x' then private.parse_x(q.handle, q.content)
        when 'instagram' then private.parse_instagram(q.handle, q.content)
        when 'contra' then private.parse_contra(q.content, 'contra:@' || q.handle)
        when 'contra_page' then private.parse_contra(q.content, 'contra:' || q.handle) end;
      if payload is not null and q.platform = 'contra' then
        payload := payload || jsonb_build_object('account', jsonb_build_object('platform', 'contra', 'handle', q.handle, 'ok', true,
                     'url', 'https://contra.com/' || q.handle));
      end if;
    end if;

    if q.platform = 'contra_page' then
      if payload is not null then perform ingest(payload); ok := ok + 1; else failed := failed + 1; end if;
    elsif payload is not null then
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
