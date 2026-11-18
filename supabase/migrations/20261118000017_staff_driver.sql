-- staff profile: drivers too
create or replace function public.set_staff_profile(p_tenant uuid, p_user uuid, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require(p_tenant, 'staff.manage', null, null);
  update memberships set
    bookable = coalesce((p->>'bookable')::boolean, bookable),
    is_driver = coalesce((p->>'is_driver')::boolean, is_driver),
    commission_pct = case when p ? 'commission_pct' then nullif(p->>'commission_pct','')::numeric else commission_pct end,
    color = case when p ? 'color' then nullif(p->>'color','') else color end
   where tenant_id = p_tenant and user_id = p_user;
  if not found then raise exception 'not found' using errcode = '42501'; end if;
end $$;
grant execute on function public.set_staff_profile(uuid, uuid, jsonb) to authenticated;
