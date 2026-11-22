-- Z Trust · business dates in local time
-- The database clock is UTC. Journal entries without an explicit date used current_date, so a sale at 01:30 in
-- Kuwait (22:30 UTC) was booked on the previous day, and on the 1st of a month into the previous (possibly closed) period.
-- Business "today" is now the branch's time zone, else the country's, else UTC.

create or replace function public._today(p_tenant uuid, p_branch uuid default null) returns date
language sql stable security definer set search_path = public as $$
  select (now() at time zone coalesce(
            (select nullif(b.timezone, 'UTC') from branches b where b.id = p_branch),
            (select c.timezone from tenants t join countries c on c.code = t.country_code where t.id = p_tenant),
            'UTC'))::date;
$$;
revoke execute on function public._today(uuid, uuid) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public._post_ex(p_tenant uuid, p_branch uuid, p_source text, p_source_id uuid, p_memo text, p_lines jsonb, p_date date DEFAULT NULL::date, p_reference text DEFAULT NULL::text, p_approved_by uuid DEFAULT NULL::uuid, p_reversal_of bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_dr bigint; v_cr bigint; v_prev text; v_no bigint; v_id bigint; l jsonb; v_acct uuid; v_cc uuid; v_branch uuid;
begin
  select coalesce(sum((x->>'debit')::bigint),0), coalesce(sum((x->>'credit')::bigint),0) into v_dr, v_cr
    from jsonb_array_elements(p_lines) x;
  if v_dr <> v_cr then raise exception 'unbalanced journal: debit % credit %', v_dr, v_cr; end if;
  if v_dr = 0 then return null; end if;

  perform pg_advisory_xact_lock(hashtext('je:' || p_tenant::text));
  select hash, entry_no into v_prev, v_no from journal_entries where tenant_id = p_tenant order by entry_no desc limit 1;
  insert into journal_entries(tenant_id, branch_id, entry_no, entry_date, source_type, source_id, memo, reference, approved_by,
                              reversal_of, prev_hash, hash, created_by)
  values (p_tenant, p_branch, coalesce(v_no, 0) + 1, coalesce(p_date, _today(p_tenant, p_branch)), p_source, p_source_id, p_memo, p_reference,
          p_approved_by, p_reversal_of, v_prev, null, auth.uid())
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'debit')::bigint,0) = 0 and coalesce((l->>'credit')::bigint,0) = 0 then continue; end if;
    if (l->>'debit')::bigint < 0 or (l->>'credit')::bigint < 0 then raise exception 'negative journal amount'; end if;
    if l ? 'account_id' then
      select id into v_acct from accounts where id = (l->>'account_id')::uuid and tenant_id = p_tenant;
      if v_acct is null then raise exception 'unknown account'; end if;
    else
      v_acct := _acct(p_tenant, l->>'key');
    end if;
    v_branch := coalesce(nullif(l->>'branch_id','')::uuid, p_branch);
    v_cc := nullif(l->>'cost_center_id','')::uuid;
    if v_cc is not null and not exists (select 1 from cost_centers where id = v_cc and tenant_id = p_tenant) then raise exception 'unknown cost centre'; end if;
    if v_cc is null and v_branch is not null then
      select id into v_cc from cost_centers where tenant_id = p_tenant and branch_id = v_branch and is_active order by code limit 1;
    end if;
    insert into journal_lines(tenant_id, entry_id, account_id, branch_id, debit, credit, customer_id, supplier_id, cost_center_id)
    values (p_tenant, v_id, v_acct, v_branch,
            coalesce((l->>'debit')::bigint,0), coalesce((l->>'credit')::bigint,0),
            nullif(l->>'customer_id','')::uuid, nullif(l->>'supplier_id','')::uuid, v_cc);
  end loop;
  update journal_entries set hash = _entry_digest(v_id) where id = v_id;
  return v_id;
end $function$;
