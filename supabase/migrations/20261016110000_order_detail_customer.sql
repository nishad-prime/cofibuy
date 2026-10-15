-- Customer identity on the order detail: who placed it, since when, and
-- their shop-wide footprint. The staff guard above is what makes reading
-- auth.users acceptable; the panel is the only consumer.

 CREATE OR REPLACE FUNCTION api.admin_order_detail(p_order_id uuid)                 
  RETURNS jsonb                                                                     
  LANGUAGE plpgsql                                                                  
  STABLE SECURITY DEFINER                                                           
  SET search_path TO ''                                                             
 AS $function$                                                                      
 declare                                                                            
   v_order public.orders;                                                           
 begin                                                                              
   if not private.is_staff() then                                                   
     raise exception 'forbidden' using errcode = '42501';                           
   end if;                                                                          
                                                                                    
   select * into v_order from public.orders where id = p_order_id;                  
   if not found then                                                                
     raise exception 'order not found' using errcode = 'P0002';                     
   end if;                                                                          
                                                                                    
   return jsonb_build_object(                                                       
     'id', v_order.id,                                                              
     'status', v_order.status,                                                      
     'reference_code', v_order.reference_code,                                      
     'amount', v_order.amount,                                                      
     -- Staff see the real minimum: it is the staff-only threshold, and the         
     -- hide_min flag governs what customers are told, not what the operator knows. 
     'min_amount', v_order.min_amount_snapshot,                                     
     'min_hidden', v_order.hide_min_snapshot,                                       
     'phone_e164', v_order.phone_e164,                                              
     'phone_raw', v_order.phone_raw,                                                
     'attempt_count', v_order.attempt_count,                                        
     'probe_count', v_order.probe_count,                                            
     'created_at', v_order.created_at,                                              
     'expires_at', v_order.expires_at,                                              
     'submitted_at', v_order.submitted_at,                                          
     'reviewed_at', v_order.reviewed_at,                                            
     'reject_reason_en', v_order.reject_reason_en,                                  
     'reject_reason_bn', v_order.reject_reason_bn,                                  
    'customer', (
      select jsonb_build_object(
        'id', u.id,
        'email', u.email,
        'created_at', u.created_at,
        'orders_total', (select count(*) from public.orders o2 where o2.user_id = v_order.user_id),
        'orders_approved', (
          select count(*) from public.orders o2
          where o2.user_id = v_order.user_id and o2.status = 'approved'
        ),
        'revenue_approved', (
          select coalesce(sum(o2.amount), 0) from public.orders o2
          where o2.user_id = v_order.user_id and o2.status = 'approved'
        )
      )
      from auth.users u
      where u.id = v_order.user_id
    ),
     'link', jsonb_build_object(                                                    
       'id', l.id, 'slug', l.slug, 'title_en', l.title_en, 'title_bn', l.title_bn   
     ),                                                                             
     'gateway', jsonb_build_object(                                                 
       'id', g.id, 'kind', g.kind, 'name_en', g.name_en, 'name_bn', g.name_bn,      
       'account_number', g.account_number, 'account_name', g.account_name,          
       'evidence_fields', g.evidence_fields                                         
     ),                                                                             
     'evidence', coalesce(                                                          
       (                                                                            
         select jsonb_agg(                                                          
           jsonb_build_object(                                                      
             'id', e.id,                                                            
             'field_key', e.field_key,                                              
             'value_text_raw', e.value_text_raw,                                    
             'value_text_norm', e.value_text_norm,                                  
             'file_path', e.file_path,                                              
             'attempt', e.attempt,                                                  
             'created_at', e.created_at                                             
           )                                                                        
           order by e.attempt desc, e.field_key                                     
         )                                                                          
         from public.order_evidence e                                               
         where e.order_id = v_order.id                                              
       ),                                                                           
       '[]'::jsonb                                                                  
     ),                                                                             
     'duplicates', coalesce(                                                        
       (                                                                            
         select jsonb_agg(to_jsonb(d))                                              
         from api.admin_order_duplicate_trxids(v_order.id) d                        
       ),                                                                           
       '[]'::jsonb                                                                  
     )                                                                              
   )                                                                                
   from public.pages l, public.payment_gateways g                                   
   where l.id = v_order.link_id and g.id = v_order.gateway_id;                      
 end                                                                                
 $function$;
revoke all on function api.admin_order_detail(uuid) from public, anon, authenticated;
grant execute on function api.admin_order_detail(uuid) to authenticated;
