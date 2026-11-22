-- Z Trust · the delivery fee line never goes to the kitchen screen
CREATE OR REPLACE FUNCTION public._kitchen_from_sale(p_sale uuid, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s sales%rowtype; k jsonb := p->'kitchen'; r record; v_ticket uuid; v_default uuid; v_first smallint;
begin
  if k is null or jsonb_typeof(k) <> 'object' then return; end if;
  if coalesce((k->>'hub')::boolean, false) then return; end if;
  select * into s from sales where id = p_sale;
  if not has_feature(s.tenant_id, 'kitchen') then return; end if;   -- kitchen switched off: no tickets
  select id into v_default from kitchen_stations where branch_id = s.branch_id and is_active
   order by is_default desc, sort, name limit 1;
  if v_default is null then return; end if;
  -- coursing: later courses wait until fired
  select min(i.course) into v_first from sale_lines l join items i on i.id = l.item_id where l.sale_id = s.id and i.course is not null;
  for r in
    select coalesce(ks.id, v_default) as station_id,
           jsonb_agg(jsonb_build_object('name', l.name, 'name_ar', i.name_ar, 'qty', l.qty, 'note', l.note, 'course', i.course) order by i.course nulls first, l.name) as items
      from sale_lines l
      left join items i on i.id = l.item_id
      left join categories c on c.id = i.category_id
      left join kitchen_stations ks on ks.id = c.station_id and ks.is_active and ks.branch_id = s.branch_id
     where l.sale_id = s.id
       and not (l.item_id is null and l.name like 'Delivery fee%')   -- the delivery fee is not for the kitchen
     group by 1
  loop
    insert into kitchen_tickets(tenant_id, branch_id, station_id, sale_id, sale_client_id, order_ref, order_type, table_no, customer_name, note)
    values (s.tenant_id, s.branch_id, r.station_id, s.id, s.client_id, s.number,
            coalesce(nullif(k->>'order_type',''),'takeaway'), nullif(k->>'table_no',''),
            coalesce(nullif(k->>'customer_name',''), (select name from customers where id = s.customer_id)),
            nullif(k->>'note',''))
    returning id into v_ticket;
    insert into kitchen_ticket_items(tenant_id, ticket_id, name, name_ar, qty, note, course, held)
    select s.tenant_id, v_ticket, x->>'name', x->>'name_ar', (x->>'qty')::numeric, x->>'note', nullif(x->>'course','')::smallint,
           coalesce(nullif(x->>'course','')::smallint > v_first, false)
      from jsonb_array_elements(r.items) x;
  end loop;
end $function$;
