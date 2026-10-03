-- 로그인 번호(휴대폰 번호 뒤 4자리) 일괄 등록 (처음 53명 등)
-- SQL 버전: personnel_auth v0.11 부속 / 작성 2026-10-03
-- 선행: personnel_auth_v11.sql 적용, 명단 동기화(personnel_roster_v10_sync.sql) 완료
-- 실행: 아래 "입력" 자리에 줄을 넣어 Supabase SQL Editor 새 탭에서 단독 실행 → 별도 탭에서 personnel_auth_v11_check.sql
--
-- 지키는 것
--   * 번호는 bcrypt 해시로만 저장된다. 전체 번호·뒤 4자리 평문은 어디에도 저장하지 않는다.
--   * 실제 번호가 들어간 이 파일·SQL은 Git에 올리지 않는다. 실행 후 SQL Editor 탭 내용을 지우고 저장하지 않는다.
--   * 현재 인원(비활성 제외)만. 사람은 (사용자ID + 이름) 또는 이름이 정확히 1명일 때만 찾는다.
--   * 하나라도 맞지 않으면(없는 이름, 같은 이름 여러 명, 번호 형식, 같은 이름·같은 번호) 전체 취소
--   * 이미 등록된 사람은 새 번호로 바뀐다. 이후 개별 변경은 관리자 화면에서 한다.
--
-- 엑셀에서 줄 만들기 (예: 이름 B열, 휴대폰 번호 C열, 2행부터) → 빈 열에 아래 식을 넣고 아래로 채운 뒤 그 열을 복사해 "입력" 자리에 붙여넣기
--   ="('"&B2&"', null, '"&RIGHT(SUBSTITUTE(SUBSTITUTE(C2,"-","")," ",""),4)&"'),"
begin;

create temp table login_input on commit drop as
select * from (values
  -- ▼ 입력: ('이름', '사용자ID' 또는 null, '뒤4자리'),
  -- ▲ 실제 값은 Git에 올리지 않는다
  (null::text, null::text, null::text)
) v(display_name, legacy_user_id, code)
where display_name is not null;

do $import$
declare
  r record;
  v_n int;
  v_person uuid;
  v_errors text[] := '{}';
  v_done int := 0;
begin
  create temp table login_resolved (person_id uuid, display_name text, code text) on commit drop;
  for r in select * from login_input loop
    if r.code is null or r.code !~ '^[0-9]{4}$' then
      v_errors := v_errors || format('번호 형식(숫자 4자리) %s', r.display_name);
      continue;
    end if;
    select count(*), min(id::text)::uuid into v_n, v_person from personnel_pilot_v1.people
    where display_name = r.display_name and employment_status <> 'inactive'
      and (r.legacy_user_id is null or legacy_user_id = r.legacy_user_id);
    if v_n = 0 then
      v_errors := v_errors || format('현재 인원 없음 %s', r.display_name);
    elsif v_n > 1 then
      v_errors := v_errors || format('같은 이름 여러 명 %s (사용자ID를 같이 적기)', r.display_name);
    else
      insert into login_resolved values (v_person, r.display_name, r.code);
    end if;
  end loop;
  for r in select person_id, max(display_name) display_name from login_resolved group by person_id having count(*) > 1 loop
    v_errors := v_errors || format('같은 사람 두 줄 %s', r.display_name);
  end loop;
  for r in select personnel_pilot_v1.name_key(display_name) k, code, min(display_name) display_name from login_resolved
           group by 1, 2 having count(*) > 1 loop
    v_errors := v_errors || format('같은 이름·같은 번호 %s (로그인 때 구분 불가)', r.display_name);
  end loop;
  if cardinality(v_errors) > 0 then
    raise exception 'LOGIN_IMPORT_NOT_READY: %', array_to_string(v_errors, ' / ');
  end if;

  for r in select * from login_resolved loop
    perform personnel_pilot_v1.set_login4(r.person_id, r.code, 'login4_import');
    v_done := v_done + 1;
  end loop;
  raise notice '로그인 번호 등록 %명', v_done;
end $import$;

commit;
