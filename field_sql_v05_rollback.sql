-- field v0.5 되돌리기 — 문제가 생겼을 때만, 사용자 확인 후 실행
-- 새 RPC(tbm_carry_cancel)만 없앤다. 데이터는 지우지 않는다.
--   * 이미 취소된 이월(carry_status = 'DROPPED')과 'CARRY_CANCELLED' 이력은 그대로 남는다 (v04 화면에서는 이어받지 않은 이월로 보인다).
-- 되돌린 뒤 field_sql_v05.sql을 다시 실행할 수 있다.
begin;
do $pre$
begin
  if to_regprocedure('public.tbm_carry_cancel(uuid,text,text)') is null then
    raise exception 'PRECHECK: v05가 적용돼 있지 않음';
  end if;
end $pre$;
drop function public.tbm_carry_cancel(uuid, text, text);
notify pgrst, 'reload schema';
commit;
