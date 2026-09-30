-- 시험 도우미 (로컬 시험 DB 전용)
create schema if not exists test_util;
grant usage on schema test_util to anon, authenticated, service_role;
create or replace function test_util.expect(p_label text, p_got text, p_want text) returns text
language plpgsql as $$
begin
  if p_got is distinct from p_want then
    raise exception 'TEST FAILED [%]: got=% want=%', p_label, p_got, p_want;
  end if;
  return 'ok  ' || p_label;
end $$;
-- p_sql을 현재 역할로 실행하고, 오류 메시지에 p_want가 들어 있어야 통과
create or replace function test_util.expect_error(p_label text, p_sql text, p_want text) returns text
language plpgsql as $$
begin
  execute p_sql;
  raise exception 'TEST FAILED [%]: no error (want %)', p_label, p_want;
exception
  when raise_exception or insufficient_privilege or others then
    if sqlerrm like 'TEST FAILED%' then raise; end if;
    if position(p_want in sqlerrm) = 0 then
      raise exception 'TEST FAILED [%]: error=% want=%', p_label, sqlerrm, p_want;
    end if;
    return 'ok  ' || p_label || '  (' || sqlerrm || ')';
end $$;
-- 로그인 흉내: JWT claims 설정 (역할 전환은 스크립트에서 set role로 한다)
create or replace function test_util.claims(p_sub text, p_session text default null) returns text
language sql as $$
  select set_config('request.jwt.claims',
    jsonb_build_object('sub', p_sub, 'role', 'authenticated', 'session_id', p_session)::text, false)
$$;
grant execute on all functions in schema test_util to anon, authenticated, service_role;
