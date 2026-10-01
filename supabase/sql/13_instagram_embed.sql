-- Instagram's public profile embed (/username/embed/) works for business profiles too.
create or replace function private.parse_instagram_embed(p_handle text, p_html text)
returns jsonb language plpgsql set search_path = public as $$
declare ctx jsonb;
begin
  begin
    ctx := ((regexp_replace(substring(p_html from '"contextJSON":("(?:[^"\\]|\\.)*")'), '\\+u0000', '', 'g')::jsonb) #>> '{}')::jsonb -> 'context';
  exception when others then return null;
  end;
  if ctx is null or jsonb_typeof(ctx->'graphql_media') <> 'array' then return null; end if;
  return private.parse_instagram(p_handle, jsonb_build_object('data', jsonb_build_object('user', jsonb_build_object(
    'full_name', ctx->>'full_name',
    'biography', null,
    'edge_followed_by', jsonb_build_object('count', ctx->'followers_count'),
    'edge_owner_to_timeline_media', jsonb_build_object('edges',
      (select coalesce(jsonb_agg(jsonb_build_object('node', m->'shortcode_media')), '[]'::jsonb)
       from jsonb_array_elements(ctx->'graphql_media') m where m ? 'shortcode_media'))
  )))::text);
end $$;

-- Switch the Instagram fetch URL to the embed page and parse it first.
do $$ declare d text; begin
  select pg_get_functiondef('private.queue_db_fetches(int)'::regprocedure) into d;
  d := replace(d, $x$net.http_get(url := 'https://www.instagram.com/api/v1/users/web_profile_info/?username=' || a.handle,
                                         headers := ua || '{"x-ig-app-id":"936619743392459","Accept":"*/*"}'::jsonb, timeout_milliseconds := 30000)$x$,
                  $x$net.http_get(url := 'https://www.instagram.com/' || a.handle || '/embed/', headers := ua, timeout_milliseconds := 30000)$x$);
  execute d;
  select pg_get_functiondef('private.process_db_fetches()'::regprocedure) into d;
  d := replace(d, $x$when 'instagram' then private.parse_instagram(q.handle, q.content)$x$,
                  $x$when 'instagram' then coalesce(private.parse_instagram_embed(q.handle, q.content), private.parse_instagram(q.handle, q.content))$x$);
  execute d;
end $$;
