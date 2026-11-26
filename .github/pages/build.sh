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

# The top page links to both guides. It takes the guide's <style> block, so it always looks like the guide.
style="$(awk '/^<style>/{on=1} on{print} /<\/style>/{if(on) exit}' docs/agw-advanced-routing-demo-guide.html | sed 's#</style></head>#</style>#')"
[ -n "$style" ] || { echo "no <style> block in the guide" >&2; exit 1; }
{
cat <<'HTML'
<!doctype html>
<html lang="en" dir="ltr">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Application Gateway Advanced Routing demo environment</title>
HTML
printf '%s\n' "$style"
cat <<HTML
<style>
.guides{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px;margin-block:32px}
.guide{display:block;background:var(--card);border:1px solid var(--line-soft);border-radius:16px;padding:18px 22px;color:var(--fg);text-decoration:none}
.guide:hover{border-color:var(--accent)}
.guide .t{display:block;font:400 20px/1.4 var(--serif);color:var(--accent)}
.guide .d{display:block;margin-block-start:6px;font-size:14px;color:var(--muted)}
</style></head>
<body><main>
<header>
<p class="meta"><a href="https://github.com/koudaiii/agw-advanced-routing-demo">GitHub: koudaiii/agw-advanced-routing-demo</a></p>
<p class="eyebrow">Build guide · <span lang="ja">構築ガイド</span></p>
<h1>Application Gateway Advanced Routing demo environment</h1>
<p class="lead">How to demonstrate Azure Application Gateway advanced routing rules (preview) and advanced load balancing (preview) on a real gateway.</p>
<p class="lead" lang="ja">Azure Application Gateway の高度なルーティング ルール (プレビュー) と高度な負荷分散 (プレビュー) を、実機で見せるための構築ガイドです。</p>
</header>
<div class="guides">
<a class="guide" href="agw-advanced-routing-demo-guide.html?lang=en"><span class="t">Build guide (English)</span><span class="d">Architecture, deployment, verification, and the demo steps.</span></a>
<a class="guide" lang="ja" href="agw-advanced-routing-demo-guide_ja.html?lang=ja"><span class="t">構築ガイド (日本語)</span><span class="d">構成、デプロイ、動作確認、デモの進め方。</span></a>
</div>
<p class="note">The simulator is not published on this site, because it can send many requests to any URL. Download <a href="${repo_file}"><code>agw-routing-simulator.html</code></a> from the repository and open it locally.<br><span lang="ja">シミュレーターは任意の URL に多数の要求を送れるため、このサイトでは公開していません。リポジトリから <a href="${repo_file}"><code>agw-routing-simulator.html</code></a> を取得し、手元で開いてください。</span></p>
</main></body></html>
HTML
} > "$out/index.html"

# Fail if the site would publish the simulator or a link outside the site.
if find "$out" -name 'agw-routing-simulator*' | grep -q .; then echo "simulator must not be published" >&2; exit 1; fi
if grep -l 'href="\.\./' "$out"/*.html; then echo "relative link outside the site" >&2; exit 1; fi
ls "$out"
