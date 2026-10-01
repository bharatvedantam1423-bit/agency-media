-- X and Instagram are fetched from the database server (pg_net), one request a minute,
-- because they rate-limit the shared edge-function servers. Everything else stays in the edge function.

create table if not exists private.fetch_queue (
  request_id bigint primary key,
  account_id bigint not null,
  platform text not null,
  handle text not null,
  queued_at timestamptz not null default now()
);

create or replace function private.parse_x(p_handle text, p_html text)
returns jsonb language plpgsql set search_path = public as $$
declare
  j jsonb;
  v_user jsonb;
  v_posts jsonb;
  v_cands jsonb;
begin
  begin
    j := substring(p_html from '<script id="__NEXT_DATA__" type="application/json">(.*?)</script>')::jsonb;
  exception when others then
    return null;
  end;
  if j is null then return null; end if;

  create temp table if not exists _x_t (t jsonb) on commit drop;
  truncate _x_t;
  insert into _x_t
  select e->'content'->'tweet' from jsonb_array_elements(coalesce(j#>'{props,pageProps,timeline,entries}', '[]'::jsonb)) e
  where e->>'type' = 'tweet' and e->'content' ? 'tweet';
  if not exists (select 1 from _x_t) then return null; end if;

  select t->'user' into v_user from _x_t where lower(t#>>'{user,screen_name}') = lower(p_handle) limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', 'x:' || (t->>'id_str'),
      'platform', 'x',
      'handle', p_handle,
      'url', 'https://x.com' || coalesce(t->>'permalink', '/' || p_handle || '/status/' || (t->>'id_str')),
      'text', regexp_replace(coalesce(t->>'full_text', t->>'text', ''), '\s*https://t\.co/\w+\s*$', ''),
      'posted_at', (t->>'created_at')::timestamptz,
      'format', case
          when coalesce(t->>'full_text', t->>'text', '') ~* '(🧵|\mthread\M|^\s*1/|\(1/\d+\))' then 'thread'
          when exists (select 1 from jsonb_array_elements(coalesce(t#>'{extended_entities,media}', t#>'{entities,media}', '[]'::jsonb)) m
                       where m->>'type' in ('video', 'animated_gif')) then 'video'
          when jsonb_array_length(coalesce(t#>'{extended_entities,media}', t#>'{entities,media}', '[]'::jsonb)) > 1 then 'carousel'
          when jsonb_array_length(coalesce(t#>'{extended_entities,media}', t#>'{entities,media}', '[]'::jsonb)) = 1 then 'image'
          when jsonb_array_length(coalesce(t#>'{entities,urls}', '[]'::jsonb)) > 0 then 'link'
          else 'text' end,
      'media_count', jsonb_array_length(coalesce(t#>'{extended_entities,media}', t#>'{entities,media}', '[]'::jsonb)),
      'likes', coalesce((t->>'favorite_count')::int, 0),
      'reposts', coalesce((t->>'retweet_count')::int, 0) + coalesce((t->>'quote_count')::int, 0),
      'replies', coalesce((t->>'reply_count')::int, 0),
      'lang', t->>'lang'
    )), '[]'::jsonb)
  into v_posts
  from _x_t
  where lower(t#>>'{user,screen_name}') = lower(p_handle)
    and not (t ? 'retweeted_status')
    and coalesce(t->>'full_text', t->>'text', '') not like 'RT @%'
    and (t->>'in_reply_to_status_id_str' is null or lower(coalesce(t->>'in_reply_to_screen_name', '')) = lower(p_handle));

  select coalesce(jsonb_agg(c), '[]'::jsonb) into v_cands from (
    select distinct on (lower(h)) jsonb_build_object('platform', 'x', 'handle', h, 'display_name', n, 'bio', b,
                                                     'followers', f, 'discovered_from', 'x:@' || p_handle) c
    from (
      select t#>>'{user,screen_name}' h, t#>>'{user,name}' n, t#>>'{user,description}' b, (t#>>'{user,followers_count}')::int f
      from _x_t where lower(t#>>'{user,screen_name}') <> lower(p_handle)
      union all
      select t#>>'{quoted_status,user,screen_name}', t#>>'{quoted_status,user,name}', t#>>'{quoted_status,user,description}',
             (t#>>'{quoted_status,user,followers_count}')::int
      from _x_t where t ? 'quoted_status'
      union all
      select m->>'screen_name', m->>'name', null, null
      from _x_t, jsonb_array_elements(coalesce(t#>'{entities,user_mentions}', '[]'::jsonb)) m
      where lower(t#>>'{user,screen_name}') = lower(p_handle)
    ) s
    where h is not null and lower(h) <> lower(p_handle)
    order by lower(h), b nulls last
    limit 15
  ) z;

  return jsonb_build_object(
    'account', jsonb_build_object('platform', 'x', 'handle', p_handle, 'ok', true,
                                  'display_name', v_user->>'name', 'bio', v_user->>'description',
                                  'followers', (v_user->>'followers_count')::int, 'url', 'https://x.com/' || p_handle),
    'posts', v_posts,
    'candidates', v_cands);
end $$;

create or replace function private.parse_instagram(p_handle text, p_body text)
returns jsonb language plpgsql set search_path = public as $$
declare
  u jsonb;
  v_posts jsonb;
  v_cands jsonb;
begin
  begin
    u := (p_body::jsonb)#>'{data,user}';
  exception when others then
    return null;
  end;
  if u is null or jsonb_typeof(u) <> 'object' then return null; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', 'ig:' || (n->>'shortcode'),
      'platform', 'instagram',
      'handle', p_handle,
      'url', 'https://www.instagram.com/p/' || (n->>'shortcode') || '/',
      'text', coalesce(n#>>'{edge_media_to_caption,edges,0,node,text}', ''),
      'posted_at', to_timestamp((n->>'taken_at_timestamp')::bigint),
      'format', case n->>'__typename'
                  when 'GraphVideo' then case when n->>'product_type' = 'clips' then 'reel' else 'video' end
                  when 'GraphSidecar' then 'carousel' else 'image' end,
      'media_count', coalesce(jsonb_array_length(n#>'{edge_sidecar_to_children,edges}'), 1),
      'likes', coalesce((n#>>'{edge_liked_by,count}')::int, (n#>>'{edge_media_preview_like,count}')::int, 0),
      'replies', coalesce((n#>>'{edge_media_to_comment,count}')::int, 0),
      'views', (n->>'video_view_count')::bigint
    )), '[]'::jsonb)
  into v_posts
  from jsonb_array_elements(coalesce(u#>'{edge_owner_to_timeline_media,edges}', '[]'::jsonb)) e, lateral (select e->'node' n) x;

  select coalesce(jsonb_agg(c), '[]'::jsonb) into v_cands from (
    select distinct on (lower(h)) jsonb_build_object('platform', 'instagram', 'handle', h, 'display_name', nm,
                                                     'discovered_from', 'instagram:@' || p_handle) c
    from (
      select e#>>'{node,username}' h, e#>>'{node,full_name}' nm
      from jsonb_array_elements(coalesce(u#>'{edge_related_profiles,edges}', '[]'::jsonb)) e
      union all
      select rtrim(m[1], '.'), null
      from jsonb_array_elements(coalesce(u#>'{edge_owner_to_timeline_media,edges}', '[]'::jsonb)) e,
           regexp_matches(coalesce(e#>>'{node,edge_media_to_caption,edges,0,node,text}', ''), '@([A-Za-z0-9_.]{3,30})', 'g') m
    ) s
    where h is not null and lower(h) <> lower(p_handle)
    order by lower(h)
    limit 15
  ) z;

  return jsonb_build_object(
    'account', jsonb_build_object('platform', 'instagram', 'handle', p_handle, 'ok', true,
                                  'display_name', u->>'full_name',
                                  'bio', concat_ws(' — ', u->>'category_name', u->>'biography'),
                                  'followers', (u#>>'{edge_followed_by,count}')::int,
                                  'url', 'https://www.instagram.com/' || p_handle || '/'),
    'posts', v_posts,
    'candidates', v_cands);
end $$;

create or replace function private.queue_db_fetches(p_n int default 1)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare a record; rid bigint; n int := 0;
begin
  for a in
    select * from accounts acc
    where acc.platform in ('x','instagram') and acc.next_collect_at <= now()
      and (acc.status = 'watch' or (acc.status = 'candidate' and acc.last_collected_at is null and (acc.bio is null or coalesce(acc.relevance,0) >= 0.2)))
      and not exists (select 1 from private.fetch_queue q where q.account_id = acc.id)
    order by (acc.status = 'watch') desc, acc.next_collect_at
    limit p_n
  loop
    if a.platform = 'x' then
      rid := net.http_get(
        url := 'https://syndication.twitter.com/srv/timeline-profile/screen-name/' || a.handle,
        headers := '{"User-Agent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36","Accept-Language":"en-US,en;q=0.9"}'::jsonb,
        timeout_milliseconds := 30000);
    else
      rid := net.http_get(
        url := 'https://www.instagram.com/api/v1/users/web_profile_info/?username=' || a.handle,
        headers := '{"User-Agent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36","x-ig-app-id":"936619743392459","Accept":"*/*"}'::jsonb,
        timeout_milliseconds := 30000);
    end if;
    insert into private.fetch_queue(request_id, account_id, platform, handle) values (rid, a.id, a.platform, a.handle);
    update accounts set next_collect_at = now() + interval '45 minutes' where id = a.id;
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
      payload := case q.platform when 'x' then private.parse_x(q.handle, q.content)
                                 else private.parse_instagram(q.handle, q.content) end;
    end if;

    if payload is not null then
      perform ingest(payload);
      ok := ok + 1;
    elsif q.timed_out or q.status_code is null or q.status_code = 429 or q.status_code >= 500 then
      update accounts set next_collect_at = now() + interval '3 hours', last_error = 'Rate limited or slow, retrying later'
      where id = q.account_id;
      transient := transient + 1;
    else
      perform ingest(jsonb_build_object('account', jsonb_build_object(
        'platform', q.platform, 'handle', q.handle, 'ok', false,
        'error', case when q.status_code = 200 then 'No public posts found (wrong handle or private)'
                      else q.platform || ' answered ' || q.status_code end)));
      failed := failed + 1;
    end if;
    delete from private.fetch_queue where request_id = q.request_id;
  end loop;

  -- requests that never came back
  delete from private.fetch_queue where queued_at < now() - interval '2 hours';

  if ok + failed + transient > 0 then
    insert into runs(job, finished_at, ok, stats)
    values ('collect_x_instagram', now(), ok > 0 or failed = 0,
            jsonb_build_object('accounts_ok', ok, 'accounts_failed', failed, 'rate_limited', transient));
  end if;
  return jsonb_build_object('ok', ok, 'failed', failed, 'rate_limited', transient);
end $$;

-- The edge function now handles only Bluesky, Mastodon and YouTube.
create or replace function public.next_jobs(p_accounts int default 10, p_sources int default 2)
returns jsonb language sql security definer set search_path = public as $$
  with w as (
    select id, platform, handle, status, url, next_collect_at from accounts
    where status = 'watch' and next_collect_at <= now()
      and platform in ('bluesky','mastodon','youtube')
    order by next_collect_at limit p_accounts
  ), c as (
    select id, platform, handle, status, url, next_collect_at from accounts
    where status = 'candidate' and next_collect_at <= now() and last_collected_at is null
      and platform in ('bluesky','mastodon','youtube')
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
revoke execute on function public.next_jobs(int, int) from public, anon, authenticated;
