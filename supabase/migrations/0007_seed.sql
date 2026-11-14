-- بيانات أولية قابلة للتعديل من داخل التطبيق: الدول والمباني/الأدوار حسب المواصفات. لا غرف ولا سعات (تُدخل من الكروكي).
insert into public.countries (name, dial_code) values ('ماليزيا', '+60'), ('إندونيسيا', '+62'), ('الهند', '+91'), ('الكويت', '+965'), ('المملكة العربية السعودية', '+966')
on conflict (name) do nothing;

do $$
declare spec jsonb := '[["الدار",["الدور الثالث","الروف"]],["دار الضيافة",["الدور الأول","الدور الثاني","الدور الثالث"]],["الاستراحة الخضراء",["الدور الأول","الدور الثاني","الدور الثالث"]],["البرج",["الدور الثاني","الدور الثالث"]],["الفرن",["الدور الأول","الدور الثاني"]]]';
  b jsonb; bid int; i int := 0; f text; j int;
begin
  if exists (select 1 from public.buildings) then return; end if;
  for b in select * from jsonb_array_elements(spec) loop
    insert into public.buildings (name, sort) values (b ->> 0, i) returning id into bid; i := i + 1; j := 0;
    for f in select jsonb_array_elements_text(b -> 1) loop insert into public.floors (building_id, name, sort) values (bid, f, j); j := j + 1; end loop;
  end loop;
end $$;
