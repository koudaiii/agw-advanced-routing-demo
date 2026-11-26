#!/usr/bin/env bash
# Builds the GitHub Pages site: the two guide pages, with the English guide also as index.html.
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

# The top page is the English guide itself. Its language script sends Japanese browsers to the Japanese guide.
cp "$out/agw-advanced-routing-demo-guide.html" "$out/index.html"

# Fail if the site would publish the simulator or a link outside the site.
if find "$out" -name 'agw-routing-simulator*' | grep -q .; then echo "simulator must not be published" >&2; exit 1; fi
if grep -l 'href="\.\./' "$out"/*.html; then echo "relative link outside the site" >&2; exit 1; fi
ls "$out"
