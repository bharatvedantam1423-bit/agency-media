-- How the database calls the collector edge function (used by the schedule).
-- Change the URL if you move to another project.
insert into private.config(key, value) values
  ('functions_url', 'https://fkmutmzuwexfyqvanmlg.supabase.co/functions/v1')
on conflict (key) do update set value = excluded.value;

create or replace function private.trigger_collect(p_accounts int default 10, p_sources int default 2)
returns bigint language sql security definer set search_path = public, extensions as $$
  select net.http_post(
    url := (select value from private.config where key = 'functions_url') || '/collect?accounts=' || p_accounts || '&sources=' || p_sources,
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-collect-secret', (select value from private.config where key = 'collect_secret')),
    timeout_milliseconds := 150000
  );
$$;
