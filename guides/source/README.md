# TBM 사용 가이드 (공개용 원본)

운영 화면의 「사용 가이드」 버튼이 여는 PDF와, 그 PDF를 만드는 원본이다.

| 화면 | 버튼 위치 | PDF (주소 고정) |
| --- | --- | --- |
| 팀장 `tbm_report.html` | 홈 상단 「새로고침 / 사용 가이드 / 로그아웃」 | `guides/team-leader-tbm-guide.pdf` |
| 소장 `tbm_manager.html` | 목록 상단 「사용 가이드 / 로그아웃」 | `guides/site-manager-tbm-guide.pdf` |

## 공개용 원칙 (이 저장소와 GitHub Pages는 공개)

- 여기 있는 HTML·이미지·PDF는 **비식별화한 공개용**이다. 캡처 속 이름은 예시 이름(홍길동·김철수·이영희·김민수 등)으로 바꿨고, 현장 사진은 흐리게 처리했다.
- 실명이 보이는 원본 캡처·원본 PDF는 **Git에 넣지 않는다.** 사내 보관본에서만 다룬다.
- 휴대폰 번호 예시는 `010-1234-5678 → 5678`만 쓴다.

## 내용 고치기

1. `team-leader-tbm-guide.html` / `site-manager-tbm-guide.html`의 문구를 고친다. 그림은 `img/`(번호·체크 표시까지 들어간 비식별 캡처).
2. PDF 다시 만들기: `bash guides/source/build_pdf.sh` → `guides/*.pdf`가 같은 이름으로 바뀐다 (주소 그대로).
3. 새 캡처를 쓸 때는 사내 보관본의 스크립트로 비식별화·자르기를 먼저 하고, 결과 이미지만 `img/`에 넣는다.

글꼴(Noto Sans KR)은 `build_pdf.sh`가 받아 `fonts/`에 둔다(Git 제외).

## v1.1 그림 (2026-10, TBM / 출역 관리 개선 v0.1)

- 새 그림(`*_v11.jpg`, `s5_stop_*`, `s8_att_*`, `m7_*`, `m8_*`)은 실제 인원·실제 DB가 아니라 **로컬 흉내 DB**에서 찍었다.
  가짜 시험 인원 이름을 예시 이름(홍길동·김철수·이영희·김민수 등)으로 바꾼 뒤 찍는다.
- 다시 만들기: `cd tests/sessions && node guide_shots_v11.mjs` → `img/`에 저장 → `bash guides/source/build_pdf.sh`
- 추가된 쪽: 팀장 가이드 「⛔ 작업정지」, 「출역 관리 ① 출근 확정 / ② 퇴근 확정」, 작업계획 인원 검색·타 팀원. 소장 가이드 「작업정지 확인」, 「출역 현황」.

## v1.2 그림 (2026-10, TBM v1.1 현장 UX 보정)

- 새 그림 `s2_carry_fold.jpg`(접힌 전일 이월 · 오늘 신규), `s2_carry_cancel.jpg`(이월 취소 사유), `s3_done.jpg`(저장 완료 표시)도 로컬 흉내 DB + 예시 이름으로 찍었다.
- 다시 만들기: `cd tests/sessions && node guide_shots_v12.mjs` → `bash guides/source/build_pdf.sh`
- 팀장 가이드 v1.2(12쪽): 「전일 이월 작업」 쪽 추가, 저장 후 홈 복귀 규칙(표지·각 단계). 소장 가이드 v1.2: PC 화면 안내 한 줄.
