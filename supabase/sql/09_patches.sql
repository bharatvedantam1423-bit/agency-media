-- Patches applied after the first run (already live in the project).

-- 1) Collector rate limits / timeouts are "try later", never a strike against the account.
do $$ declare d text; begin
  select pg_get_functiondef('public.ingest(jsonb)'::regprocedure) into d;
  if d not like '%transient%' then
    d := replace(d, $x$if coalesce((acc->>'ok')::boolean, true) = false then$x$,
      $x$if coalesce((acc->>'transient')::boolean, false) then
        update accounts set next_collect_at = now() + interval '3 hours', last_error = left(acc->>'error', 300) where id = v_acc_id;
        return jsonb_build_object('account_id', v_acc_id, 'ok', false, 'transient', true);
      end if;
      if coalesce((acc->>'ok')::boolean, true) = false then$x$);
    execute d;
  end if;
end $$;

-- 2) Dashboard supports 30 days / 90 days / all time (3 years).
do $$ declare d text; begin
  select pg_get_functiondef('public.dashboard(int)'::regprocedure) into d;
  d := replace(d, 'case when p_days >= 60 then 90 else 30 end', 'public.dashboard_window(p_days)');
  execute d;
end $$;

alter function public.dashboard_window(int) set search_path = public;
revoke execute on function public.dashboard_window(int) from public, anon, authenticated;
