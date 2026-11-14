-- تسجيل أحداث تتم في المتصفح (تصدير، تقارير، استيراد) في سجل العمليات
create or replace function gk.audit_event(u public.profiles, b jsonb) returns jsonb
language plpgsql security definer set search_path = public, gk, pg_temp as $fn$
declare a text := b ->> 'action'; ent text := coalesce(b ->> 'entity', 'report');
begin
  if a not in ('export', 'report') or ent not in ('visitor', 'report', 'system') then raise exception 'حدث غير مسموح'; end if;
  perform gk.audit(u, a, ent, null, case when jsonb_typeof(b -> 'details') = 'object' then b -> 'details' else '{}'::jsonb end, nullif(gk.int_or(b ->> 'event_id', 0), 0));
  return jsonb_build_object('ok', true);
end $fn$;
