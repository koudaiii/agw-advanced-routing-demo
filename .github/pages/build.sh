#!/usr/bin/env bash
# Builds the GitHub Pages site: the two guide pages and an index that opens them.
# The simulator is not published (it can send many requests to any URL), so links to it
# are rewritten to its page in the repository, where readers can download it.
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${1:?usage: build.sh <output dir>}"
repo_file="https://github.com/koudaiii/agw-advanced-routing-demo/blob/main/agw-routing-simulator.html"

rm -rf "$out" && mkdir -p "$out"
for f in agw-advanced-routing-demo-guide.html agw-advanced-routing-demo-guide_ja.html; do
  sed -E "s#\.\./agw-routing-simulator\.html(\?lang=(en|ja))?#${repo_file}#g" "docs/$f" > "$out/$f"
done

# The guide picks English or Japanese from ?lang= or the browser language.
cat > "$out/index.html" <<'HTML'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Application Gateway Advanced Routing demo guide</title>
<meta http-equiv="refresh" content="0; url=agw-advanced-routing-demo-guide.html">
</head><body><p><a href="agw-advanced-routing-demo-guide.html">Build guide (English)</a> · <a href="agw-advanced-routing-demo-guide_ja.html?lang=ja" lang="ja">構築ガイド (日本語)</a></p></body></html>
HTML

# Fail if the site would publish the simulator or a link outside the site.
if find "$out" -name 'agw-routing-simulator*' | grep -q .; then echo "simulator must not be published" >&2; exit 1; fi
if grep -l 'href="\.\./' "$out"/*.html; then echo "relative link outside the site" >&2; exit 1; fi
ls "$out"
