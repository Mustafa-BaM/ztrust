-- Z Trust · "Needs attention" in one call (P0 performance)
-- The dashboard used to download up to 1,000 invoices and several lists to count them in the browser.
-- This returns only the counts (and the unpaid amount), each part gated by the module and the user's permissions.

create or replace function public.dashboard_alerts(p_tenant uuid, p_branch uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_today date; v jsonb := '{}';
begin
  if not can_see_branch(p_tenant, p_branch) then raise exception 'branch not allowed' using errcode = '42501'; end if;
  v_today := _today(p_tenant, p_branch);
  if has_perm(p_tenant, 'inventory.view') or has_perm(p_tenant, 'catalog.manage') or has_perm(p_tenant, 'reports.all') then
    select v || jsonb_build_object(
             'out', count(*) filter (where on_hand <= 0),
             'low', count(*) filter (where on_hand > 0 and reorder_point is not null and on_hand <= reorder_point))
      into v from v_inventory where tenant_id = p_tenant and branch_id = p_branch;
    if has_feature(p_tenant, 'batches') then
      v := v || jsonb_build_object('exp', (select count(*) from v_batches where tenant_id = p_tenant and branch_id = p_branch and on_hand > 0 and days_left <= 7));
    end if;
  end if;
  if has_perm(p_tenant, 'reports.all') or has_perm(p_tenant, 'payments.receive') then
    select v || jsonb_build_object('unpaid', count(*), 'unpaid_amount', coalesce(sum(total - paid_total - refunded_total), 0))
      into v from sales where tenant_id = p_tenant and branch_id = p_branch and doc_type = 'invoice' and status <> 'cancelled' and total - paid_total - refunded_total > 0;
  end if;
  if has_feature(p_tenant, 'qr_ordering') then
    v := v || jsonb_build_object('online', (select count(*) from online_orders where tenant_id = p_tenant and branch_id = p_branch and status = 'pending'));
  end if;
  if has_feature(p_tenant, 'tables') then
    v := v || jsonb_build_object('tables', (select count(*) from open_orders where tenant_id = p_tenant and branch_id = p_branch and status = 'open'));
  end if;
  if has_feature(p_tenant, 'job_cards') or has_feature(p_tenant, 'preorders') then
    select v || jsonb_build_object('ready', count(*) filter (where status = 'ready'),
                                   'late', count(*) filter (where status <> 'ready' and due_at < now()))
      into v from work_orders where tenant_id = p_tenant and branch_id = p_branch and status in ('received','in_progress','ready');
  end if;
  if has_feature(p_tenant, 'appointments') then
    v := v || jsonb_build_object('appts', (select count(*) from appointments a join branches b on b.id = a.branch_id
            where a.tenant_id = p_tenant and a.branch_id = p_branch and (a.starts_at at time zone coalesce(nullif(b.timezone, 'UTC'), 'UTC'))::date = v_today
              and a.status in ('booked','confirmed','arrived')));
  end if;
  if has_feature(p_tenant, 'own_delivery') then
    v := v || jsonb_build_object('deliv', (select count(*) from deliveries where tenant_id = p_tenant and branch_id = p_branch and status in ('pending','assigned','picked_up')));
  end if;
  if has_perm(p_tenant, 'hr.manage') then
    v := v || jsonb_build_object('docs', (select count(*) from employees e where e.tenant_id = p_tenant and e.is_active and
            least(e.civil_id_expiry, e.passport_expiry, e.residency_expiry, e.health_card_expiry, e.license_expiry) <= v_today + 30));
  end if;
  if has_perm(p_tenant, 'payables.pay') or has_perm(p_tenant, 'purchase.create') then
    v := v || jsonb_build_object('requests', (select count(*) from purchase_requests where tenant_id = p_tenant and branch_id = p_branch and status = 'pending'));
  end if;
  return v;
end $$;
revoke execute on function public.dashboard_alerts(uuid, uuid) from public, anon;
grant execute on function public.dashboard_alerts(uuid, uuid) to authenticated;
