\set ON_ERROR_STOP on
select public.gk_bootstrap_admin('admin', 'Admin12345');
create or replace function pg_temp.as_user(un text) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', (select auth_id::text from public.profiles where username = un), false); end $$;
select pg_temp.as_user('admin');
select public.api('POST','/countries','{}','{"name":"ماليزيا","dial_code":"+60"}') ;
select public.api('POST','/countries','{}','{"name":"الهند","dial_code":"+91"}');
select public.api('POST','/events','{}','{"name":"ملتقى 2026","start_date":"2026-12-20","end_date":"2026-12-30"}');
select public.api('POST','/users','{}','{"name":"مشرف ماليزيا","username":"my1","password":"Passw0rd1","role":"country_supervisor","country_id":1}');
select public.api('POST','/users','{}','{"name":"مشرف الهند","username":"in1","password":"Passw0rd1","role":"country_supervisor","country_id":2}');
select public.api('POST','/buildings','{}','{"name":"الدار"}');
select public.api('POST','/floors','{}','{"name":"الدور الثالث","building_id":1}');
select public.api('POST','/rooms','{}','{"floor_id":1,"number":"301","capacity":2}');
select public.api('POST','/rooms','{}','{"floor_id":1,"number":"302","capacity":3}');
-- مشرف ماليزيا
select pg_temp.as_user('my1');
select public.api('POST','/visitors','{}','{"event_id":1,"full_name":"أحمد عبدالله","country_id":1,"category":"family_head","phone":"+60123456789","arrival_date":"2026-12-21","departure_date":"2026-12-25","members":[{"full_name":"فاطمة أحمد","relation":"زوجة"},{"full_name":"علي أحمد","relation":"ابن"}]}');
select 'dup(expect 409)', public.api('POST','/visitors','{}','{"event_id":1,"full_name":"ahmed x","country_id":1,"category":"individual","phone":"0060 123 456 789"}')->>'_status';
do $$ begin begin perform public.api('POST','/visitors','{}','{"event_id":1,"full_name":"هندي","country_id":2,"category":"individual"}'); raise notice 'FAIL no error'; exception when others then raise notice 'OK blocked: %', sqlerrm; end; end $$;
select pg_temp.as_user('in1');
select 'india sees', jsonb_array_length(public.api('GET','/visitors','{"event_id":"1"}')->'visitors');
select 'hidden dup', public.api('POST','/visitors','{}','{"event_id":1,"full_name":"س","country_id":2,"category":"individual","phone":"0123456789"}')::text;
select pg_temp.as_user('admin');
select 'admin sees', jsonb_array_length(public.api('GET','/visitors','{"event_id":"1"}')->'visitors');
-- تسكين الأسرة (3 أشخاص) في غرفة سعتها 2 → يجب أن يفشل ذرّياً
do $$ declare ids jsonb; begin
  select jsonb_agg((x->>'id')::int) into ids from jsonb_array_elements(public.api('GET','/visitors','{"event_id":"1"}')->'visitors') x;
  begin perform public.api('POST','/bookings/bulk','{}', jsonb_build_object('event_id',1,'room_id',1,'visitor_ids',ids)); raise notice 'FAIL bulk passed'; exception when others then raise notice 'OK bulk blocked: %', sqlerrm; end;
  raise notice 'bookings after failed bulk: %', (select count(*) from public.bookings);
  perform public.api('POST','/bookings/bulk','{}', jsonb_build_object('event_id',1,'room_id',2,'visitor_ids',ids));
  raise notice 'bookings after ok bulk: %', (select count(*) from public.bookings);
  begin perform public.api('PUT','/rooms/2','{}','{"capacity":1}'); raise notice 'FAIL cap reduce'; exception when others then raise notice 'OK cap reduce blocked: %', sqlerrm; end;
end $$;
select 'occupancy', public.api('GET','/occupancy','{"floor_id":"1","date":"2026-12-22"}')->'rooms'->1->>'state';
select 'audit rows', count(*) from public.audit_log;
-- الجداول مغلقة أمام authenticated
set role authenticated;
do $$ begin begin perform count(*) from public.visitors; raise notice 'FAIL direct select'; exception when others then raise notice 'OK direct select denied: %', sqlerrm; end; end $$;
reset role;
-- حساب موقوف
select pg_temp.as_user('admin');
select public.api('PUT','/users/2','{}','{"name":"مشرف ماليزيا","role":"country_supervisor","country_id":1,"status":"suspended"}');
select pg_temp.as_user('my1');
do $$ begin begin perform public.api('GET','/visitors','{"event_id":"1"}'); raise notice 'FAIL suspended'; exception when others then raise notice 'OK suspended: % %', sqlstate, sqlerrm; end; end $$;
