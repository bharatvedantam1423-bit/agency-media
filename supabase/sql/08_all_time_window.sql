-- X's public timeline returns each account's ~100 top posts (often older), so patterns
-- also get an "all time" (3-year) window, and account medians use 3 years of posts.
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
    where account_id is not null and posted_at > now() - interval '3 years'
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

create or replace function public.refresh_patterns()
returns jsonb language plpgsql security definer set search_path = public as $$
declare w int; base real; n int := 0;
begin
  foreach w in array array[30, 90, 1095] loop
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
    cross join lateral (values ('purpose', pd.purpose), ('hook', pd.hook), ('subject', pd.subject), ('format', pd.format), ('cta', pd.cta), ('length', pd.length)) a(dim, val)
    cross join lateral (values ('purpose', pd.purpose), ('hook', pd.hook), ('subject', pd.subject), ('format', pd.format), ('cta', pd.cta), ('length', pd.length)) b(dim, val)
    where a.dim < b.dim and a.val is not null and b.val is not null
      and pd.posted_at > now() - make_interval(days => w) and pd.relevant >= 0.4
    group by a.dim, a.val, b.dim, b.val
    having count(*) >= 5;
    n := n + 1;
  end loop;
  return jsonb_build_object('windows', n);
end $$;

create or replace function public.dashboard_window(p_days int)
returns int language sql immutable as $$
  select case when p_days < 60 then 30 when p_days < 365 then 90 else 1095 end;
$$;
