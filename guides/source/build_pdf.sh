#!/usr/bin/env bash
# 사용 가이드 PDF 다시 만들기: 이 폴더의 HTML(공개용·비식별화본) → ../*.pdf
#   bash guides/source/build_pdf.sh
# 글꼴(Noto Sans KR)은 Git에 넣지 않는다. 없으면 Google Fonts에서 받아 fonts/에 둔다(.gitignore).
# Chrome/Chromium 경로가 다르면 CHROME=/경로/chrome 으로 지정한다.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/fonts"
for w in 500 700 900; do
  f="$HERE/fonts/NotoSansKR-$w.ttf"
  [ -s "$f" ] && continue
  url=$(curl -fsS -A "Mozilla/4.0" "https://fonts.googleapis.com/css2?family=Noto+Sans+KR:wght@$w" | grep -o 'https://[^)]*' | head -1)
  curl -fsS -o "$f" "$url"
done
CHROME="${CHROME:-$(command -v chromium || command -v chromium-browser || command -v google-chrome || ls /opt/pw-browsers/chromium-*/chrome-linux/chrome 2>/dev/null | head -1)}"
for name in team-leader-tbm-guide site-manager-tbm-guide; do
  "$CHROME" --headless --no-sandbox --disable-gpu --allow-file-access-from-files --no-pdf-header-footer \
    --print-to-pdf="$HERE/../$name.pdf" "file://$HERE/$name.html" 2>/dev/null
  echo "guides/$name.pdf"
done
