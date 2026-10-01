-- Chrome extension sends posts from X, Instagram and Contra (token-checked, same worker token as Laya).
-- Row: {platform, post_id, handle, url, text, posted_at, likes, reposts, replies, views, format, media_count, laya?}
create or replace function public.extension_ingest(p_token text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n_tags int := 0;
begin
  if p_token is distinct from (select value from private.config where key = 'worker_token') then
    raise exception 'invalid worker token';
  end if;
  if jsonb_array_length(coalesce(p_rows, '[]'::jsonb)) > 200 then
    raise exception 'too many rows in one call (max 200)';
  end if;

  create temp table if not exists _ext (platform text, post_id text, handle text, j jsonb) on commit drop;
  truncate _ext;
  insert into _ext
  select coalesce(x->>'platform', 'x'), coalesce(x->>'post_id', x->>'tweet_id'), nullif(x->>'handle', 'unknown'), x
  from jsonb_array_elements(p_rows) x;
  delete from _ext where not coalesce(
    (platform = 'x' and post_id ~ '^\d{5,25}$' and handle ~ '^[A-Za-z0-9_]{1,30}$') or
    (platform = 'instagram' and post_id ~ '^[A-Za-z0-9_-]{5,40}$' and handle ~ '^[A-Za-z0-9_.]{1,30}$') or
    (platform = 'contra' and post_id ~ '^[A-Za-z0-9_-]{4,80}$' and (handle is null or handle ~ '^[A-Za-z0-9_.-]{1,40}$')), false);

  insert into accounts(platform, handle, status, origin, discovered_from)
  select distinct platform, handle, 'candidate', 'discovered', 'extension' from _ext where handle is not null
  on conflict (platform, handle) do nothing;

  perform ingest(jsonb_build_object('posts', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', case platform when 'x' then 'x:' when 'instagram' then 'ig:' else 'contra:' end || post_id,
      'platform', platform, 'handle', handle, 'url', j->>'url',
      'text', left(j->>'text', 4000), 'posted_at', nullif(j->>'posted_at', ''), 'format', j->>'format',
      'media_count', (j->>'media_count')::int,
      'likes', (j->>'likes')::int, 'reposts', (j->>'reposts')::int, 'replies', (j->>'replies')::int,
      'views', (j->>'views')::bigint, 'via', 'extension')), '[]'::jsonb)
    from _ext)));

  insert into post_tags(post_id, relevant, hook, has_cta, specificity, slop, answers, model, tagged_at)
  select case platform when 'x' then 'x:' when 'instagram' then 'ig:' else 'contra:' end || post_id,
         (j#>>'{laya,relevant}')::real, j#>>'{laya,hook}', (j#>>'{laya,has_cta}')::real,
         (j#>>'{laya,specificity}')::real, (j#>>'{laya,slop}')::real, j->'laya', 'laya:extension', now()
  from _ext
  where j ? 'laya' and exists (select 1 from posts p where p.id = case platform when 'x' then 'x:' when 'instagram' then 'ig:' else 'contra:' end || post_id)
  on conflict (post_id) do nothing;
  get diagnostics n_tags = row_count;

  return jsonb_build_object('ok', true, 'rows', (select count(*) from _ext), 'tags', n_tags);
end $$;
revoke execute on function public.extension_ingest(text, jsonb) from public;
grant execute on function public.extension_ingest(text, jsonb) to anon, authenticated;
