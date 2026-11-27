# サーバー名 (srv-*) と x-backend-srv ヘッダー 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** バックエンドの 14 プロセスを `srv-` で始まるサーバー名に変え、応答ヘッダーを `x-backend-srv` の 1 種類にする。シミュレーターは Azure の実際のプール名を補って「プール › サーバー」と表示し、経路図を「ルール → プール → サーバー」の 3 列にする。

**Architecture:** ゲートウェイ (Bicep のリソース) は変えない。バックエンド (`server.js`、`pools*.conf`、cloud-init) がサーバー名だけを名乗る。シミュレーターは「サーバー → プール」の表を 1 か所に持ち、それを表示、一致判定、集計、経路図のすべてで使う。

**Tech Stack:** Node.js 18+ (依存なし)、単一 HTML のシミュレーター、`node:test` + ヘッドレス Chrome (CDP)、Bicep、bash。

**Spec:** `docs/superpowers/specs/2026-11-27-server-name-header-design.md`

## Global Constraints

- プール名は Azure Portal で見える実際のバックエンド プール名を使う。サーバー名はそれとは別に `srv-` で付ける (例: :8080 は `pool-web` / `srv-web`)。
- `x-backend-srv` の値には必ずサーバー名 (`srv-` で始まる名前) を入れる。`x-backend-pool` はどこにも残さない。旧ヘッダーへの後方互換は入れない。
- ゲートウェイの構成 (プール名 13 個、ルール、条件、重み、優先度、最小正常割合、サーバー選択の方式、ポート) は変えない。
- サーバー名の対応 (ポート、ラベル、色、遅延は変えない): `pool-web`→`srv-web`、`pool-partner`→`srv-partner`、`pool-tenant`→`srv-tenant`、`pool-api-v2`→`srv-api-v2`、`pool-mobile`→`srv-mobile`、`pool-slow`→`srv-slow`、`pool-rr-a`→`srv-rr-a`、`pool-standby`→`srv-standby`、`pool-flag-off`→`srv-flag-off` (以上 VM 1)、`pool-canary`→`srv-canary`、`pool-fast`→`srv-fast`、`pool-rr-b`→`srv-rr-b`、`pool-primary`→`srv-primary`、`pool-flag-on`→`srv-flag-on` (以上 VM 2)。
- 環境変数は `SERVER_NAME` / `SERVER_LABEL` / `SERVER_COLOR`、JSON のキーは `server` / `serverLabel`、systemd のユニットは `agw-srv@.service`。
- 停止手順は `systemctl stop agw-srv@srv-primary` / `systemctl start agw-srv@srv-primary`。
- 画面の文言は英日の両方を用意する (`L(ja, en)` と `data-ja`)。
- コードの変更は TDD (テストを先に変えて失敗を見る)。各タスクの最後に `node --test backend/server.test.js tests/simulator.test.mjs` の全体を通す。
- `docs/superpowers/` の過去の設計書と計画は変えない。

## Review Focus

1. **旧環境に向けたとき** (`x-backend-pool` だけを返す): 「x-backend-srv ヘッダーなし」と出て、落ちない。→ Task 3 にテスト。
2. **同じサーバーがポートで別のプールになる** (`srv-slow` が :8120 では `pool-rr-slow`、:8130 では `pool-lc`): 表示も集計も取り違えない。→ Task 3 にテスト。
3. **表にないサーバー名** (デモ以外のバックエンドが `x-backend-srv: foo` を返す): プール名なしで `foo` をそのまま出し、例外を出さない。→ Task 3 にテスト。
4. **既定プールを変えた :80 の予測** (既定を `pool-mobile` にし、実機は `srv-mobile` を返す): 「予測と一致」になる。→ Task 3 にテスト。
5. **リダイレクト** (:80 の `campaign` に一致): 経路図でプールの箱はどれも強調されず、リダイレクトの箱だけが強調される。→ Task 4 にテスト。

---

### Task 1: バックエンドがサーバー名と x-backend-srv を返す

**Files:**
- Modify: `backend/server.js` (1-16 行のコメントと定数、30 行、50-51 行、76-95 行の HTML、114 行、125 行、135 行)
- Test: `backend/server.test.js`

**Interfaces:**
- Produces: プロセスは環境変数 `SERVER_NAME` (既定 `srv-web`)、`SERVER_LABEL`、`SERVER_COLOR`、`PORT`、`DELAY_MS` を読む。応答とプリフライトに `x-backend-srv: <SERVER_NAME>`。`access-control-expose-headers: x-backend-srv`。JSON は `{ server, serverLabel, … }` (他のキーは今のまま)。

- [ ] **Step 1: テストを書き換える。** `start()` の既定の環境変数を `SERVER_NAME: "srv-test"` にする。既存の `x-backend-pool` の検証を `x-backend-srv` = `"srv-test"` に替える。次のテストを足す。

```js
test("normal responses and preflights name the server in x-backend-srv only", async () => {
  const base = await start({});
  const res = await fetch(`${base}/app?format=json`);
  assert.strictEqual(res.headers.get("x-backend-srv"), "srv-test");
  assert.strictEqual(res.headers.get("x-backend-pool"), null);
  assert.strictEqual(res.headers.get("access-control-expose-headers"), "x-backend-srv");
  const body = await res.json();
  assert.strictEqual(body.server, "srv-test");
  assert.strictEqual(body.serverLabel, "srv-test");
  assert.strictEqual(body.pool, undefined);
  const pre = await fetch(`${base}/app`, { method: "OPTIONS", headers: { "access-control-request-method": "GET", origin: "http://example.test" } });
  assert.strictEqual(pre.headers.get("x-backend-srv"), "srv-test");
});
test("the HTML page says which server answered", async () => {
  const base = await start({ SERVER_LABEL: "Slow server (3 s)" });
  const html = await (await fetch(`${base}/`)).text();
  assert.match(html, /Backend server that answered this request/);
  assert.match(html, /<h1>srv-test<\/h1>/);
  assert.doesNotMatch(html, /Backend pool/);
});
```

- [ ] **Step 2: 失敗を見る。** Run: `node --test backend/server.test.js` → Expected: 上の 2 件と、書き換えた既存の検証が FAIL。
- [ ] **Step 3: `server.js` を直す。** 定数を `SERVER_NAME` / `SERVER_LABEL` / `SERVER_COLOR` にし、ヘッダー、expose、JSON のキー、`<title>`、見出しを上の Interfaces どおりにする。CSS 変数 `--pool` は `--srv` にする。先頭コメントの「One process = one backend pool.」を「One process = one backend server.」にし、使用例を `SERVER_NAME=srv-tenant …` にする。
- [ ] **Step 4: 通る。** Run: `node --test backend/server.test.js` → Expected: 全件 PASS。
- [ ] **Step 5: Commit.** `git commit -m "backend: name the server in x-backend-srv (SERVER_NAME)"`

### Task 2: VM のプロセス名、cloud-init、Bicep のコメント、確認用スクリプト

**Files:**
- Modify: `backend/pools.conf`、`backend/pools-canary.conf` (名前の欄だけ)
- Modify: `deploy/make-cloud-init.sh` (36 行のユニット名、51-54 行の変数名、60 行)
- Regenerate: `deploy/cloud-init.yaml`、`deploy/cloud-init-canary.yaml`
- Modify: `deploy/main.bicep` のコメントだけ (62 行、83-84 行、245 行、499-529 行など、プロセス名とプール名が同じと読める箇所)
- Modify: `deploy/test.sh`、`deploy/canary-check.sh`、`deploy/lb-check.sh`、`deploy/deploy.sh` (4 行のコメント)

**Interfaces:**
- Consumes: Task 1 の環境変数名。
- Produces: VM 上のユニット `agw-srv@<サーバー名>`、`/etc/agw-demo/<サーバー名>.env`。スクリプトは `x-backend-srv` を読み、サーバー名で数える。

- [ ] **Step 1: conf を直し、cloud-init を作り直す。** Run: `bash deploy/make-cloud-init.sh && bash deploy/make-cloud-init.sh backend/pools-canary.conf deploy/cloud-init-canary.yaml`
- [ ] **Step 2: 確かめる。** Run: `grep -c "systemctl enable --now agw-srv@srv-" deploy/cloud-init.yaml deploy/cloud-init-canary.yaml` → Expected: `9` と `5`。`grep -c "agw-srv@.service" deploy/cloud-init*.yaml` → 各 1。`grep -E "POOL_|agw-pool@|pool-" deploy/cloud-init*.yaml` → Expected: 出力なし。`wc -c deploy/cloud-init*.yaml` → base64 にしても customData の上限 64 KB に収まる (各 48 KB 未満)。
- [ ] **Step 3: Bicep のコメントを直す。** 「backend/pools.conf と同じ」を「プール名 (Azure の backend pool)。そこに入るサーバーは backend/pools*.conf の `srv-…`」の意味にする。サーバー選択の 3 プールのコメントに `srv-slow` / `srv-fast` / `srv-rr-a` / `srv-rr-b` を書く。リソースは変えない。Run: `az bicep build --file deploy/main.bicep --stdout > /dev/null` → Expected: エラーなし (警告は今と同じ)。
- [ ] **Step 4: スクリプトを直す。** awk の `x-backend-pool` を `x-backend-srv` に、出力の `(no-pool-header)` を `(no-srv-header)` に、使い方と期待値の説明をサーバー名に直す (例: 「about 90 srv-web / 10 srv-canary」「few on srv-slow」)。`test.sh` の注記 (37-41 行) も同じ。プール名は補わない。Run: `bash -n deploy/*.sh` → Expected: 出力なし。
- [ ] **Step 5: Commit.** `git commit -m "deploy: srv-* process names, agw-srv@ units, scripts read x-backend-srv"`

### Task 3: シミュレーターがサーバー名を読み、「プール › サーバー」で表示する

**Files:**
- Modify: `agw-routing-simulator.html` (`SERVER_INFO`、`PRIORITY_COLOR` 周辺 474-496 行、`describe` 498-505 行、送信 625-640 行、`liveSummary` / `verdict` 687-703 行、候補一覧 829-863 行、`backendPage`、`renderSim` 880-900 行、実機の応答 930-945 行、テスト要求 1385-1460 行、負荷分散のプリセット 1095-1110 行、停止手順 168-172 行)
- Test: `tests/simulator.test.mjs` (代役ゲートウェイ 81-91 行、`standIn` 284-296 行、#131 のテスト 252-330 行を書き換え)

**Interfaces:**
- Produces (シミュレーター内のグローバル。Task 4 が使う):
  - `SERVERS`: `{ [serverId]: { label, color, vm: 1|2, port } }` — 14 台。色とラベルは今の `POOLS` / `SERVER_INFO` / `PRIORITY_COLOR` から引き継ぐ。
  - `poolOfServer(serverId: string, port: number) → string|null` — :8110〜:8130 は `SERVER_SELECT_PORTS[port].pool` (サーバーがその `servers` にあるとき)、それ以外は `srv-X` → `pool-X` (`POOLS` にあるとき)、どれでもなければ `null`。
  - `routeName(poolId: string|null, serverId: string) → string` — `"pool-rr-slow › srv-slow"`、`poolId` が `null` なら `serverId` だけ。
  - 実機の応答 `state.live` と `run.seq[i]` は `{ server, pool, … }` を持つ。`server` は `x-backend-srv` の値、`pool` は `poolOfServer(server, port)`。
  - `SERVER_SELECT_PORTS[port].servers` は `["srv-slow", "srv-fast"]` などのサーバー名。

- [ ] **Step 1: テストの代役ゲートウェイを新しいヘッダーにする。** `before` の代役と `standIn()` を `x-backend-srv` (expose も) にし、値を `srv-partner` / `srv-web` にする。#131 の 2 件を次の内容に書き換え、テストを足す。

```js
test("a live response on 8090 shows the pool and the server", …)
  // standIn(8090, "srv-standby") → liveOut に "pool-standby › srv-standby" と "x-backend-srv: srv-standby"
test("live 8100 srv-flag-on matches the prediction, and 8090 test requests count pool-primary › srv-primary", …)
  // badge === "Matches the prediction"; testResult に /pool-primary › srv-primary: 6 \(100%\)/
test("srv-slow is pool-rr-slow on 8120 and pool-lc on 8130", …)
  // standIn(8120,"srv-slow") と standIn(8130,"srv-slow"); 各 preset でテスト要求 3 件
  // 8120 の testResult に /pool-rr-slow › srv-slow: 3/、8130 に /pool-lc › srv-slow: 3/
test("an old gateway that only sends x-backend-pool shows that x-backend-srv is missing", …)
  // 代役が x-backend-pool: pool-web だけを返す → liveOut に /No x-backend-srv header/、pageErrors は空
test("an unknown server name is shown as it is, without a pool", …)
  // standIn(8080, "foo") (ポート使用中なら t.skip) → カナリアのプリセットで送信、liveOut に "foo"、"›" を含まない
test("with the default pool set to pool-mobile, a live srv-mobile matches the prediction", …)
  // saveRules で c.defaultPool = "pool-mobile"、代役は srv-mobile → badge "Matches the prediction"
```

停止手順のテスト (253-262 行) は `agw-srv@srv-primary` を含み、`agw-pool@` を含まないことに替える (英日)。

- [ ] **Step 2: 失敗を見る。** Run: `node --test tests/simulator.test.mjs` → Expected: 上の各件が FAIL (表示がまだ `x-backend-pool`)。
- [ ] **Step 3: 実装する。** 送信 (`processPool` の行) と、テスト要求 (`run.seq[i] = …`) で `x-backend-srv` を読み、`{ server, pool: poolOfServer(server, port) }` を入れる。ヘッダーがないときの文言を「x-backend-srv ヘッダーなし (デモ用バックエンドではないか、旧環境か、CORS の Expose-Headers 未設定)」/ "No x-backend-srv header (not the demo backend, an old deployment, or CORS Expose-Headers is missing)" にする。`verdict` は `l.pool === d.pool` のまま (`l.pool` が変換済みになる)。`describe`、`liveSummary`、候補一覧、`backendPage` の見出し、状態表示、テスト要求の凡例とマスの title を `routeName` にする。マスの本文はサーバー名だけ。予測の代わりのページ (`renderSim`) も、1 対 1 のプールでは `routeName(pool, "srv-" + pool.slice(5))` を見出しにする。停止手順と負荷分散のプリセットのサーバー名を `srv-` にする。
- [ ] **Step 4: 通る。** Run: `node --test backend/server.test.js tests/simulator.test.mjs` → Expected: 全件 PASS。
- [ ] **Step 5: Commit.** `git commit -m "simulator: read x-backend-srv and show pool › server"`

### Task 4: 経路図を「ルール → プール → サーバー」の 3 列にする

**Files:**
- Modify: `agw-routing-simulator.html` (`listenerLabel` 707-711 行、`renderDiagram` 712-830 行、`routeColorOf` 535-540 行)
- Test: `tests/simulator.test.mjs` (`listenerLabel` ヘルパー 344-346 行、243-250 行と 353-363 行のテストを書き換え)

**Interfaces:**
- Consumes: Task 3 の `SERVERS`、`poolOfServer`、`SERVER_SELECT_PORTS`。
- Produces: 経路図の SVG。各箱は `data-box="rule|pool|server|redirect"` と `data-id` (ルール名、プール名、サーバー名) と `data-hit="true|false"` を持つ (テストはこれで調べる)。
  - `PORT_NAMES = { 80: { listener: "listener-http", rule: "rule1", map: "advancedRoutingMap1" }, 8080: { listener: "listener-canary", rule: "rule-canary", map: "canaryMap" }, 8090: { listener: "listener-priority", rule: "rule-priority", map: "priorityMap" }, 8100: { listener: "listener-flag", rule: "rule-flag", map: "flagMap" }, 8110: { listener: "listener-rr", rule: "rule-rr", map: null }, 8120: { listener: "listener-rr-slow", rule: "rule-rr-slow", map: null }, 8130: { listener: "listener-lc", rule: "rule-lc", map: null } }`

- [ ] **Step 1: テストを書く。**

```js
for (const lang of ["en", "ja"]) test(`the diagram has 7 rules, 13 pools, 14 servers in three columns (${lang})`, …)
  // data-box="rule" 7 個、"pool" 13 個、"server" 14 個、"redirect" 1 個。
  // 列の x: すべての rule < すべての pool < すべての server。
  // rule の箱の文字に "rule1" と "advancedRoutingMap1"、"rule-rr-slow" と "Basic"。
test("on 8120 the route lights rule-rr-slow, pool-rr-slow, srv-slow and srv-fast, not pool-lc", …)
  // data-hit="true" の data-id 集合 === {rule-rr-slow, pool-rr-slow, srv-slow, srv-fast}
test("a redirect lights rule1 and the redirect box, and no pool", …)
  // :80 で Query campaign=spring → hit は {rule1, redirect}。pool と server の hit は 0 個。
test("a :80 match on pool-tenant lights pool-tenant and srv-tenant", …)
test("pool-rr-slow and pool-lc both draw lines to srv-slow and srv-fast", …)
  // プール → サーバーの線 (data-from / data-to を持つ path) を数える
```

「listener follows the request's port」のテスト (353-363 行) は、期待値を `listener-flag :8100` / `listener-canary :8080` に替える (英日共通)。243-250 行の「dedicated ports 8088 and 8089」は、サーバーの箱 `srv-primary`、`srv-standby`、`srv-flag-on`、`srv-flag-off` に `:8088` / `:8089` が出ることに替える。

- [ ] **Step 2: 失敗を見る。** Run: `node --test tests/simulator.test.mjs` → Expected: 上の各件が FAIL。
- [ ] **Step 3: 実装する。** リスナーの箱は `${PORT_NAMES[port].listener} :${port}`。④ の箱は 1 行目がルール名、2 行目がマップ名か `Basic`。⑤ に 13 個のプールの箱、⑥ に VM 2 / VM 1 の枠と 14 個のサーバーの箱、VM の枠の下にリダイレクトの箱を置く。線は「ルール → プール」(今の `mapTargets` をプール名で)、「プール → サーバー」(1 対 1 と `SERVER_SELECT_PORTS`)、「rule1 → リダイレクト」(点線、プール列を通らない)。強調は、予測のプール (と `kind` ごとの候補) と、そのサーバー (1 対 1 なら 1 台、サーバー選択なら 2 台)。`viewBox` の幅は 1034 から広げ (目安 1300)、プールの並び順は線の交差が少なくなるよう VM 2 → VM 1 の順に合わせる。既定プールの箱には「(既定)」/「(default)」。
- [ ] **Step 4: 通る。** Run: `node --test backend/server.test.js tests/simulator.test.mjs` → Expected: 全件 PASS。
- [ ] **Step 5: 目で確かめる。** ブラウザーで英日、ライトとダークで開き、:8120、:8090、:80 (tenant とリダイレクト) を送って、文字が箱からはみ出さないこと、強調の線が正しい箱に届くことを見る。
- [ ] **Step 6: Commit.** `git commit -m "simulator: route diagram in three columns (rule → pool → server)"`

### Task 5: ガイド、README、ワークショップのスキル

**Files:**
- Modify: `docs/agw-advanced-routing-demo-guide.html`、`docs/agw-advanced-routing-demo-guide_ja.html` (図 1 の SVG 87-210 行、§3.3、§4.1、§4.2、§6、§7、CORS の表、`server.js` の抜粋 283-301 行)
- Modify: `README.md`、`README_ja.md`、`.agents/skills/agw-advanced-routing-workshop/SKILL.md`、`SKILL_ja.md`
- Create (コミットしない): スクラッチパッドに図 1 の生成スクリプト

**Interfaces:**
- Consumes: Task 1〜4 の名前 (サーバー名、ヘッダー、ユニット名、ルール / リスナー名、3 列の構成)。

- [ ] **Step 1: 図 1 を作り直す。** スクラッチパッドに生成スクリプトを書き、英日の SVG を出す。構成はシミュレーターと同じ 3 列 (ルール → プール → サーバー、VM 2 / VM 1 の枠、rule1 からリダイレクトへの点線)。スクリプトで文字列の幅を見積もり、すべての文字が箱に収まることを確かめてから、HTML の `<svg>` を差し替える。`<desc>` の説明も新しい構成に直す。
- [ ] **Step 2: 本文を直す。** `x-backend-pool` → `x-backend-srv`、応答例のサーバー名、`agw-pool@pool-primary` → `agw-srv@srv-primary`、`server.js` の抜粋、「名前はゲートウェイのプールと同じ」という説明を「プールは Portal の名前、サーバーは `srv-`」に直す。README とスキルも同じ。
- [ ] **Step 3: 取り残しを確かめる。** Run: `git grep -n -E "x-backend-pool|agw-pool@|POOL_NAME|POOL_LABEL|POOL_COLOR|pool-(slow|fast|rr-a|rr-b)\b" -- ':!docs/superpowers'` → Expected: 出力なし。`git grep -n -E "pool-(web|partner|tenant|api-v2|mobile|canary|primary|standby|flag-on|flag-off)\b" -- ':!docs/superpowers'` の各行を目で見て、プール (Portal の名前) を指している箇所だけが残っていること。
- [ ] **Step 4: 通る。** Run: `node --test backend/server.test.js tests/simulator.test.mjs` → Expected: 全件 PASS (ガイドが 320 px に収まるテストを含む)。ブラウザーで英日のガイドを開き、図 1 を目で確かめる。
- [ ] **Step 5: Commit.** `git commit -m "docs: srv-* servers, x-backend-srv, and the three-column figure"`

### Task 6: 環境を作り直し、実機で確かめてから PR を出す

**Files:** なし (実機の操作だけ)。結果は PR の本文に書く。

- [ ] **Step 1: オーナーに一声かける。** `./cleanup.sh` は今の環境 (20.222.123.60) を消す。実行の直前に確認を取る。
- [ ] **Step 2: 作り直す。** Run: `cd deploy && ./cleanup.sh && ./deploy.sh` → Expected: デプロイ成功。新しい公開 IP を控える。
- [ ] **Step 3: 実機で確かめる。**
  - `FRONTEND=<IP> ./test.sh` → 各行に `srv-` で始まるサーバー名が出る。
  - `FRONTEND=<IP>:8130 ./lb-check.sh /app/home 100 6` → `srv-slow` が 10 件以下。続けて `:8120` → `srv-slow` が 35〜65 件で、全体の所要時間が 8130 よりはっきり長い。
  - `az vm run-command invoke -g rg-agw-advrouting-demo -n agwdemo-backend-canary --command-id RunShellScript --scripts "systemctl stop agw-srv@srv-primary"` の 2〜3 分後、`:8090` が `srv-standby` を返す。`systemctl start agw-srv@srv-primary` で戻す。
  - ブラウザーのシミュレーターに新しい IP を入れ、:8120 のテスト要求の結果に `pool-rr-slow › srv-slow` / `pool-rr-slow › srv-fast`、経路図の 3 列の強調が出る。
- [ ] **Step 4: PR を出す。** 本文に、変更の要約、実機の結果 (件数と時間)、新しい公開 IP を書く。実機の確認がすべて済むまでマージしない。
