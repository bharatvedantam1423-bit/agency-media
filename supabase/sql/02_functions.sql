-- ============ Heuristic text features (instant, no model) ============
create or replace function public.text_features(t text)
returns jsonb language plpgsql immutable set search_path = public as $$
declare
  body text := coalesce(t, '');
  first_line text := left(trim(split_part(body, E'\n', 1)), 280);
  fl text := lower(first_line);
  lt text := lower(body);
  words int := coalesce(array_length(regexp_split_to_array(nullif(trim(body), ''), '\s+'), 1), 0);
  hook text;
begin
  hook := case
    when fl ~ '^\s*(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\M' or fl ~ '\m\d+\s+(tips|ways|lessons|things|mistakes|steps|rules|reasons|tools|ideas|signs|principles|examples|questions|habits|secrets|truths)\M' then 'number_list'
    when fl ~ '\m(before|after)\M' or lt ~ 'before\s*(/|->|vs\.?|and|&)\s*after' then 'before_after'
    when fl ~ '(\$\s?\d|₹\s?\d|\m\d+(\.\d+)?\s?(k|m|%|x)\M|\m\d+\s(clients|leads|followers|mrr|arr|revenue|sales|signups|users)\M)' then 'result_first'
    when fl ~ '^(how|here''s how|this is how|heres how)\M' then 'how_to'
    when fl ~ '\?\s*$' or fl ~ '^(why|what|who|when|would|should|do|does|is|are|can|have you|ever)\M' then 'question'
    when fl ~ '^(stop|unpopular|hot take|nobody|most (people|designers|agencies|founders|brands)|don''t|dont|never|forget|you don''t need|the truth|hard truth|controversial)' or fl ~ '\m(overrated|myth|wrong|lie|lies|dead)\M' then 'contrarian'
    when fl ~ '^(new|introducing|just (launched|shipped|finished|wrapped|released)|launching|we (just|are)|excited|announcing|meet|say hello)\M' then 'announcement'
    when fl ~ '^(i |i''m |im |i''ve |ive |my |we |our |last (year|month|week)|yesterday|today|in 20\d\d|years ago|when i|a client)' then 'story'
    else 'plain' end;

  return jsonb_build_object(
    'chars', length(body),
    'words', words,
    'lines', coalesce(array_length(string_to_array(body, E'\n'), 1), 0),
    'first_line', first_line,
    'hook_h', hook,
    'has_question', body ~ '\?',
    'has_list', body ~ E'(^|\\n)\\s*(\\d+[.)]|[-•→✓✅▪])\\s',
    'emoji_count', (select count(*) from regexp_matches(body, '[\U0001F300-\U0001FAFF☀-➿]', 'g')),
    'hashtags', (select count(*) from regexp_matches(body, '#\w+', 'g')),
    'mentions', (select count(*) from regexp_matches(body, '@\w+', 'g')),
    'has_link', body ~* 'https?://',
    'cta_h', lt ~ '\m(dm me|dm us|send me a dm|link in bio|book a call|book a|reply with|comment|follow for|follow me|subscribe|hire me|hire us|available for|open for|taking on|slots|waitlist|sign up|grab|download|get in touch|work with me|work with us|let''s talk|inquiries|enquiries)\M',
    'length_bucket', case when words < 20 then 'short' when words < 60 then 'medium' when words < 150 then 'long' else 'very_long' end
  );
end $$;

-- Relevance guess from a bio/name before Laya looks at it
create or replace function public.bio_relevance(b text)
returns real language sql immutable set search_path = public as $$
  select least(1.0, 0.2 * (
    select count(*) from regexp_matches(lower(coalesce(b,'')),
      '\m(design|designer|designs|studio|agency|brand|branding|creative|ux|ui|product design|web design|webdesign|founder|freelance|freelancer|illustrat\w*|motion|typograph\w*|art director|figma|framer|webflow|identity|logo|logos|visual|strategist|consultant|clients)\M', 'g')
  ))::real;
$$;

create or replace function public.engagement_for(p_platform text, p_likes int, p_reposts int, p_replies int, p_views bigint, p_saves int)
returns real language sql immutable set search_path = public as $$
  select (case
    when p_platform = 'youtube' then coalesce(p_views,0) / 20.0 + coalesce(p_likes,0) + 3 * coalesce(p_replies,0)
    when p_platform = 'instagram' then coalesce(p_likes,0) + 3 * coalesce(p_replies,0) + coalesce(p_views,0) / 50.0
    else coalesce(p_likes,0) + 2 * coalesce(p_reposts,0) + 3 * coalesce(p_replies,0) + 2 * coalesce(p_saves,0)
  end)::real;
$$;

-- Terms for hot topics: hashtags + dictionary matches
create or replace function public.extract_terms(p_id text, p_text text)
returns void language plpgsql set search_path = public as $$
begin
  delete from post_terms where post_id = p_id;
  insert into post_terms(post_id, term)
  select distinct p_id, t from (
    select '#' || lower(m[1]) t from regexp_matches(coalesce(p_text,''), '#([A-Za-z][A-Za-z0-9_]{2,40})', 'g') m
    union
    select term from topic_terms where active and coalesce(p_text,'') ~* pattern
  ) s
  on conflict do nothing;
end $$;

-- ============ Ingest (called by the collector with the service key) ============
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
      when v_status = 'candidate' then interval '30 days'           -- probed once; promotion decides
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
  end if;

  for r in select * from jsonb_array_elements(coalesce(p->'posts', '[]'::jsonb)) loop
    insert into posts as po (id, platform, account_id, handle, url, text, posted_at, format, media_count,
                             likes, reposts, replies, views, saves, features, lang, via, raw)
    values (r->>'id', r->>'platform',
            coalesce(v_acc_id, (select id from accounts a where a.platform = r->>'platform' and a.handle = r->>'handle')),
            r->>'handle', r->>'url', r->>'text', (r->>'posted_at')::timestamptz, r->>'format',
            coalesce((r->>'media_count')::int, 0),
            coalesce((r->>'likes')::int, 0), coalesce((r->>'reposts')::int, 0), coalesce((r->>'replies')::int, 0),
            (r->>'views')::bigint, (r->>'saves')::int,
            text_features(r->>'text'), r->>'lang', coalesce(r->>'via','timeline'), r->'raw')
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

  -- Accounts the collector noticed (mentions, suggestions, hashtag authors)
  for r in select * from jsonb_array_elements(coalesce(p->'candidates', '[]'::jsonb)) loop
    insert into accounts(platform, handle, display_name, bio, followers, status, origin, discovered_from, relevance, relevance_source)
    values (r->>'platform', r->>'handle', r->>'display_name', r->>'bio', (r->>'followers')::int,
            'candidate', 'discovered', r->>'discovered_from',
            bio_relevance(coalesce(r->>'display_name','') || ' ' || coalesce(r->>'bio','')), 'heuristic')
    on conflict (platform, handle) do nothing;
    if found then n_cand := n_cand + 1; end if;
  end loop;

  -- keep discovery bounded: candidates with no design signal in bio are parked
  update accounts set status = 'ignored'
  where status = 'candidate' and relevance_source = 'heuristic' and bio is not null and coalesce(relevance, 0) = 0
    and created_at > now() - interval '1 hour';

  return jsonb_build_object('account_id', v_acc_id, 'posts', n_posts, 'candidates', n_cand);
end $$;

-- What the collector should fetch next
create or replace function public.next_jobs(p_accounts int default 10, p_sources int default 2)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'accounts', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'platform', platform, 'handle', handle, 'status', status, 'url', url))
      from (
        select id, platform, handle, status, url from accounts
        where status in ('watch','candidate') and next_collect_at <= now()
          and platform in ('x','instagram','bluesky','mastodon','youtube')
          and (status = 'watch' or coalesce(relevance, 0) >= 0.2)
        order by (status = 'watch') desc, next_collect_at
        limit p_accounts
      ) a), '[]'::jsonb),
    'sources', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'platform', platform, 'kind', kind, 'value', value))
      from (
        select id, platform, kind, value from sources
        where active and next_collect_at <= now()
        order by next_collect_at limit p_sources
      ) s), '[]'::jsonb)
  );
$$;

create or replace function public.mark_source_done(p_id bigint)
returns void language sql security definer set search_path = public as $$
  update sources set last_collected_at = now(), next_collect_at = now() + interval '6 hours' + random() * interval '1 hour' where id = p_id;
$$;

-- ============ Scoring ============
create or replace function public.compute_scores()
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update posts set engagement = engagement_for(platform, likes, reposts, replies, views, saves);

  with m as (
    select account_id,
           percentile_cont(0.5) within group (order by engagement) med,
           count(*) n
    from posts
    where account_id is not null and posted_at > now() - interval '180 days'
    group by account_id
  )
  update accounts a set median_eng = m.med, posts_count = m.n from m where a.id = m.account_id;

  update posts p set
    outlier = case when a.posts_count >= 5 and a.median_eng > 0 then p.engagement / a.median_eng end,
    early_outlier = case when p.posted_at > now() - interval '36 hours' and a.posts_count >= 5 and a.median_eng > 0
                         then p.engagement / a.median_eng end,
    is_winner = (a.posts_count >= 5 and a.median_eng > 0 and p.engagement / a.median_eng >= 2 and p.engagement >= 5)
  from accounts a where p.account_id = a.id;
  get diagnostics n = row_count;
  return jsonb_build_object('scored', n);
end $$;

-- Every post with its effective tags (Laya where present, heuristics otherwise)
create or replace view public.post_dims with (security_invoker = true) as
select p.id, p.platform, p.posted_at, p.outlier, p.is_winner, p.engagement,
  t.purpose,
  coalesce(t.hook, p.features->>'hook_h') as hook,
  t.subject,
  p.format,
  case when coalesce(t.has_cta, case when (p.features->>'cta_h')::boolean then 1 else 0 end) >= 0.5 then 'with_cta' else 'no_cta' end as cta,
  p.features->>'length_bucket' as length,
  trim(to_char(p.posted_at at time zone 'UTC', 'Day')) as weekday,
  case when t.specificity is null then null when t.specificity >= 1.5 then 'specific' else 'vague' end as specificity,
  case when t.slop is null then null when t.slop >= 0.6 then 'sounds_ai' else 'sounds_human' end as voice,
  coalesce(t.relevant, 1) as relevant
from posts p
left join post_tags t on t.post_id = p.id
where p.outlier is not null;

create or replace function public.refresh_patterns()
returns jsonb language plpgsql security definer set search_path = public as $$
declare w int; base real; n int := 0;
begin
  foreach w in array array[30, 90] loop
    select coalesce(avg(case when is_winner then 1.0 else 0 end), 0) into base
    from post_dims where posted_at > now() - make_interval(days => w) and relevant >= 0.4;

    delete from pattern_stats where window_days = w;
    insert into pattern_stats(window_days, dimension, value, posts, winners, win_rate, lift, median_outlier, example_ids)
    select w, d.dim, d.val, count(*), count(*) filter (where pd.is_winner),
           avg(case when pd.is_winner then 1.0 else 0 end),
           case when base > 0 then avg(case when pd.is_winner then 1.0 else 0 end) / base end,
           percentile_cont(0.5) within group (order by pd.outlier),
           (array_agg(pd.id order by pd.outlier desc) filter (where pd.is_winner))[1:3]
    from post_dims pd
    cross join lateral (values
      ('purpose', pd.purpose), ('hook', pd.hook), ('subject', pd.subject), ('format', pd.format),
      ('cta', pd.cta), ('length', pd.length), ('weekday', pd.weekday), ('specificity', pd.specificity),
      ('voice', pd.voice), ('platform', pd.platform)
    ) d(dim, val)
    where d.val is not null and pd.posted_at > now() - make_interval(days => w) and pd.relevant >= 0.4
    group by d.dim, d.val
    having count(*) >= 5;

    delete from combo_stats where window_days = w;
    insert into combo_stats(window_days, dim_a, val_a, dim_b, val_b, posts, winners, win_rate, lift, median_outlier, example_ids)
    select w, a.dim, a.val, b.dim, b.val, count(*), count(*) filter (where pd.is_winner),
           avg(case when pd.is_winner then 1.0 else 0 end),
           case when base > 0 then avg(case when pd.is_winner then 1.0 else 0 end) / base end,
           percentile_cont(0.5) within group (order by pd.outlier),
           (array_agg(pd.id order by pd.outlier desc) filter (where pd.is_winner))[1:3]
    from post_dims pd
    cross join lateral (values ('purpose', pd.purpose), ('hook', pd.hook), ('subject', pd.subject), ('format', pd.format), ('cta', pd.cta)) a(dim, val)
    cross join lateral (values ('purpose', pd.purpose), ('hook', pd.hook), ('subject', pd.subject), ('format', pd.format), ('cta', pd.cta)) b(dim, val)
    where a.dim < b.dim and a.val is not null and b.val is not null
      and pd.posted_at > now() - make_interval(days => w) and pd.relevant >= 0.4
    group by a.dim, a.val, b.dim, b.val
    having count(*) >= 5;
    n := n + 1;
  end loop;
  return jsonb_build_object('windows', n);
end $$;

create or replace function public.refresh_hot_topics()
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from hot_topics;
  insert into hot_topics(term, posts_now, posts_prev, eng_now, eng_prev, growth, score, platforms, example_ids)
  select term, now_n, prev_n, now_e, prev_e,
         (now_n + 1.0) / (prev_n / 3.0 + 1.0) as growth,
         ((now_n + 1.0) / (prev_n / 3.0 + 1.0)) * ln(1 + now_n) * (1 + ln(1 + coalesce(now_e, 0) / greatest(coalesce(prev_e, 0), 1))) as score,
         platforms, examples
  from (
    select pt.term,
      count(*) filter (where p.posted_at > now() - interval '7 days') now_n,
      count(*) filter (where p.posted_at <= now() - interval '7 days' and p.posted_at > now() - interval '28 days') prev_n,
      avg(p.outlier) filter (where p.posted_at > now() - interval '7 days') now_e,
      avg(p.outlier) filter (where p.posted_at <= now() - interval '7 days' and p.posted_at > now() - interval '28 days') prev_e,
      array_agg(distinct p.platform) platforms,
      (array_agg(p.id order by coalesce(p.outlier, 0) desc) filter (where p.posted_at > now() - interval '7 days'))[1:3] examples
    from post_terms pt join posts p on p.id = pt.post_id
    where p.posted_at > now() - interval '28 days'
    group by pt.term
  ) s
  where now_n >= 3;
  get diagnostics n = row_count;

  -- self-improving discovery: rising hashtags become new sources (bounded)
  insert into sources(platform, kind, value, origin)
  select 'mastodon', 'hashtag', substr(term, 2), 'auto'
  from hot_topics
  where term like '#%' and posts_now >= 5 and growth >= 1.5
  order by score desc limit 5
  on conflict do nothing;
  delete from sources where origin = 'auto' and id not in (
    select id from sources where origin = 'auto' order by next_collect_at desc limit 25);

  return jsonb_build_object('topics', n);
end $$;

-- Candidates that look like design agencies / business owners and perform get promoted
create or replace function public.promote_candidates()
returns jsonb language plpgsql security definer set search_path = public as $$
declare promoted int; pruned int;
begin
  with pick as (
    select a.id from accounts a
    where a.status = 'candidate' and a.posts_count >= 5
      and coalesce(a.relevance, 0) >= case when a.relevance_source = 'laya' then 0.55 else 0.4 end
      and coalesce(a.median_eng, 0) >= 3
    order by a.relevance desc, a.median_eng desc
    limit 40
  )
  update accounts set status = 'watch', next_collect_at = now() where id in (select id from pick);
  get diagnostics promoted = row_count;

  -- keep each platform's watchlist to the 150 most useful accounts
  with ranked as (
    select id, row_number() over (partition by platform order by (origin = 'seed') desc,
             coalesce(relevance, 0.3) * ln(2 + coalesce(median_eng, 0)) desc) rn
    from accounts where status = 'watch'
  )
  update accounts set status = 'ignored' where id in (select id from ranked where rn > 150);
  get diagnostics pruned = row_count;
  return jsonb_build_object('promoted', promoted, 'pruned', pruned);
end $$;

-- ============ Laya worker RPCs (token-checked; safe to call with the public key) ============
create or replace function public.laya_next_posts(p_token text, p_limit int default 25)
returns table(id text, platform text, handle text, text text)
language plpgsql security definer set search_path = public as $$
begin
  if p_token is distinct from (select value from private.config where key = 'worker_token') then
    raise exception 'invalid worker token';
  end if;
  return query
    select p.id, p.platform, p.handle, left(p.text, 3000)
    from posts p left join post_tags t on t.post_id = p.id
    where t.post_id is null and length(coalesce(p.text, '')) >= 15
    order by p.is_winner desc, p.posted_at desc nulls last
    limit least(p_limit, 100);
end $$;

create or replace function public.laya_save_tags(p_token text, p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if p_token is distinct from (select value from private.config where key = 'worker_token') then
    raise exception 'invalid worker token';
  end if;
  insert into post_tags(post_id, relevant, purpose, hook, subject, has_cta, specificity, slop, answers, model, tagged_at)
  select r->>'post_id', (r->>'relevant')::real, r->>'purpose', r->>'hook', r->>'subject',
         (r->>'has_cta')::real, (r->>'specificity')::real, (r->>'slop')::real, r->'answers', r->>'model', now()
  from jsonb_array_elements(p_rows) r
  where exists (select 1 from posts p where p.id = r->>'post_id')
  on conflict (post_id) do update set
    relevant = excluded.relevant, purpose = excluded.purpose, hook = excluded.hook, subject = excluded.subject,
    has_cta = excluded.has_cta, specificity = excluded.specificity, slop = excluded.slop,
    answers = excluded.answers, model = excluded.model, tagged_at = now();
  get diagnostics n = row_count;
  return n;
end $$;

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
    order by (a.status = 'candidate') desc, a.created_at
    limit least(p_limit, 100);
end $$;

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
  return n;
end $$;

-- ============ Owner actions (used by the dashboard through the Supabase connector) ============
create or replace function public.add_account(p_platform text, p_handle text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare h text := regexp_replace(trim(p_handle), '^@', '');
begin
  if h !~ '^[A-Za-z0-9_.@-]{2,80}$' then raise exception 'That handle has characters we can''t use'; end if;
  insert into accounts(platform, handle, status, origin, next_collect_at)
  values (p_platform, h, 'watch', 'manual', now())
  on conflict (platform, handle) do update set status = 'watch', fail_count = 0, next_collect_at = now();
  return jsonb_build_object('ok', true, 'platform', p_platform, 'handle', h);
end $$;

create or replace function public.set_account_status(p_id bigint, p_status text)
returns void language sql security definer set search_path = public as $$
  update accounts set status = p_status, next_collect_at = now() where id = p_id and p_status in ('watch','ignored','candidate');
$$;

create or replace function public.add_source(p_platform text, p_value text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := lower(regexp_replace(trim(p_value), '^#', ''));
begin
  if v !~ '^[a-z0-9_]{2,60}$' then raise exception 'Hashtags can only use letters, numbers and _'; end if;
  insert into sources(platform, kind, value, origin) values (p_platform, 'hashtag', v, 'manual')
  on conflict (platform, kind, value) do update set active = true, next_collect_at = now();
  return jsonb_build_object('ok', true, 'value', v);
end $$;

-- Lock down: only the owner (connector) and service role call these; the worker gets its 4 RPCs.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.laya_next_posts(text, int) to anon, authenticated;
grant execute on function public.laya_save_tags(text, jsonb) to anon, authenticated;
grant execute on function public.laya_next_accounts(text, int) to anon, authenticated;
grant execute on function public.laya_save_accounts(text, jsonb) to anon, authenticated;
