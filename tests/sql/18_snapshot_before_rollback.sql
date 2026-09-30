-- 롤백 직전 행 수 기록 (롤백 후 기존 행이 남는지 비교)
insert into test_util.snapshot values ('account_links_before_rollback', (select count(*)::text from personnel_pilot_v1.account_links))
on conflict (key) do update set value = excluded.value;
