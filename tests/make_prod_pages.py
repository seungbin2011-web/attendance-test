#!/usr/bin/env python3
# 운영 화면 만들기: 시험 화면(*_test.html)에서 TEST·시험 표시만 바꿔 운영 화면을 만든다.
# 화면 동작(JS 모듈)은 시험 화면과 같다. 모듈은 파일 이름에 _test가 없으면 운영 화면끼리 연결한다(pageUrl).
#   python3 tests/make_prod_pages.py          → 운영 화면 4개를 다시 만든다
#   python3 tests/make_prod_pages.py --check  → 운영 화면이 시험 화면과 맞는지만 확인 (다르면 실패)
# 운영 화면을 직접 고치지 말고, 시험 화면을 고친 뒤 이 스크립트로 다시 만든다.
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
NOTE = '<!-- 운영 화면: tests/make_prod_pages.py가 {src}에서 만든다. 직접 고치지 말 것 -->\n'

PAGES = {
    'index.html': ('personnel_test.html', [
        ('<title>현장 업무 통합 로그인 · 시험</title>', '<title>현장 업무 통합 로그인</title>', 1),
        ('TEST v0.92', 'v1.0', 2),
        ('personnel_test.mjs?v=0.92.1', 'personnel_test.mjs?v=1.0', 1),
    ]),
    'member.html': ('member_test.html', [
        ('<title>팀원 홈 TEST</title>', '<title>팀원 홈</title>', 1),
        ('<span class="ver">TEST v0.10</span>', '<span class="ver">v1.0</span>', 1),
        ('팀원 홈 TEST v0.11', '팀원 홈 v1.0', 1),
        ('tbm_api_test.mjs?v=0.12', 'tbm_api_test.mjs?v=1.0', 2),
    ]),
    'tbm_report.html': ('tbm_report_test.html', [
        ('<title>팀장 TBM 보고 TEST</title>', '<title>팀장 TBM 보고</title>', 1),
        ('v0.62 TEST', 'v1.0', 2),
        (' · 시험 화면</div>', '</div>', 1),
        ('tbm_report_test.mjs?v=0.62.1', 'tbm_report_test.mjs?v=1.0', 1),
    ]),
    'tbm_manager.html': ('tbm_manager_test.html', [
        ('<title>현장 TBM 현황 TEST</title>', '<title>현장 TBM 현황</title>', 1),
        ('v0.41 TEST', 'v1.0', 2),
        (' · 시험 화면</div>', '</div>', 1),
        ('tbm_manager_test.mjs?v=0.41.1', 'tbm_manager_test.mjs?v=1.0', 1),
    ]),
}


def build(target):
    src, rules = PAGES[target]
    text = (ROOT / src).read_text(encoding='utf-8')
    for old, new, count in rules:
        found = text.count(old)
        if found != count:
            raise SystemExit(f'{src}: "{old}" {count}곳이어야 하는데 {found}곳 (시험 화면이 바뀌었으면 이 스크립트도 고칠 것)')
        text = text.replace(old, new)
    # 화면에 보이는 표시만 검사 (스크립트 안의 시험 화면 이동 분기는 그대로 둔다)
    for word in ('TEST', '· 시험', '시험 화면</'):
        if word in text:
            raise SystemExit(f'{target}: 운영 화면에 "{word}"가 남아 있음')
    first, rest = text.split('\n', 1)
    return first + '\n' + NOTE.format(src=src) + rest


def main():
    check = '--check' in sys.argv[1:]
    bad = []
    for target in PAGES:
        text = build(target)
        path = ROOT / target
        if check:
            if not path.exists() or path.read_text(encoding='utf-8') != text:
                bad.append(target)
        else:
            path.write_text(text, encoding='utf-8')
            print(f'{target} ← {PAGES[target][0]}')
    if bad:
        raise SystemExit('운영 화면이 시험 화면과 다름: ' + ', '.join(bad) + ' → python3 tests/make_prod_pages.py 실행')
    if check:
        print('운영 화면 4개가 시험 화면과 일치')


if __name__ == '__main__':
    main()
