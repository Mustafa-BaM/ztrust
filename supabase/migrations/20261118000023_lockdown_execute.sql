-- Z Trust · security fix (P0): function EXECUTE privileges
-- 0006 ran "alter default privileges in schema public revoke execute on functions from public, ...".
-- A schema-level default can only ADD privileges; it never removes the global default (EXECUTE to PUBLIC),
-- so every function created after 0006 was callable by PUBLIC, including the anonymous API key.
-- Most of them check membership and permissions inside, but internal helpers (_doc_no, _list_price,
-- _expected_cash, _payroll_totals, …) did not. This migration:
--   1. keeps every API function the app uses callable by signed-in users (explicit grant),
--   2. removes PUBLIC / anon execute everywhere,
--   3. re-grants anon only the public-page, hub, webhook and API-key entry points,
--   4. makes internal helpers (_name) uncallable from the API,
--   5. fixes the default for future functions at the global level.

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f' and p.prorettype <> 'trigger'::regtype
              and p.proname !~ '^_' and has_function_privilege('authenticated', p.oid, 'EXECUTE') loop
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;

revoke execute on all functions in schema public from public, anon;

-- internal helpers: only other functions (running as owner) call them
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f' and p.proname ~ '^_' loop
    execute format('revoke execute on function %s from authenticated', f.sig);
  end loop;
end $$;
-- used inside security-invoker report views
grant execute on function public._voucher_total(uuid) to authenticated;

-- anonymous entry points (each validates a slug, token, key or link itself)
grant execute on function public.payment_link_info(text) to anon;
grant execute on function public.hub_config(text, text), public.hub_sync(text, jsonb) to anon;
grant execute on function public.ingest_delivery_order(text, jsonb) to anon;
grant execute on function public.api_query(text, text, jsonb) to anon;
grant execute on function public.booking_info(text), public.booking_slots(text, uuid, uuid[], date, uuid), public.book_online(text, jsonb) to anon;
grant execute on function public.menu_info(text, text), public.place_order(text, jsonb), public.order_status(uuid) to anon;
-- row-level-security helpers (return false for anonymous callers)
grant execute on function public.is_member(uuid), public.can_see_branch(uuid, uuid), public.has_perm(uuid, text),
                          public.has_feature(uuid, text), public.module_allowed(text, text) to anon;

-- future functions: no implicit EXECUTE for PUBLIC (global default, which a schema-level default cannot override)
alter default privileges revoke execute on functions from public;
