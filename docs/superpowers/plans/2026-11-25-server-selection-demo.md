# サーバー選択デモ (Round Robin / Least Connections) 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 8110 / 8120 / 8130 の 3 ポートで、Round Robin の基本の動き、遅いサーバーがあるときの問題、Least Connections による解決を、実機とシミュレーターで確かめられるようにする。

**Architecture:** VM 1 と VM 2 に、8086 (遅い / 速い) と 8087 (速い / 速い) のプロセスを足す。ゲートウェイは Basic のルールで 3 ポートを 3 つのプールに送り、`pool-lc` だけ `serverSelectionAlgorithm: 'LeastConnections'` にする。シミュレーターと CLI は、同時 6 件を保つ送り方で、振り分けと所要時間を出す。

**Tech Stack:** Bicep (Microsoft.Network/applicationGateways@2026-03-01)、Node.js 18+ (依存なし)、bash、単一 HTML のシミュレーター (素の JavaScript)、検証は headless Chrome (CDP) と node:test。

**Spec:** `docs/superpowers/specs/2026-11-25-server-selection-demo-design.md`

## Global Constraints

- 1 Issue 1 ブランチ 1 PR。ブランチは `origin/main` から切る (例外は Task 4 と Task 5)。PR 本文の先頭に `Closes #NN`、末尾に `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。
- PR のマージと Issue のクローズは、ユーザーが指示したときだけ行う。
- 文言を足したり直したりするときは、英語版と日本語版の両方を直す。シミュレーターは `L(ja, en)`、静的 HTML は英語の本文と `data-ja`。
- ポートと名前は設計書のとおり: 8110 `pool-rr` (8087: `pool-rr-a` / `pool-rr-b`)、8120 `pool-rr-slow` と 8130 `pool-lc` (8086: `pool-slow` / `pool-fast`)。VM 1 = 192.168.1.10、VM 2 = 192.168.1.11。
- 遅延は 3000 ms。`/healthz` と OPTIONS の事前確認には遅延をかけない。プローブ (間隔 30 秒、タイムアウト 20 秒) は変えない。
- 送り方は同時 6 件を保つ方式。合格の基準: 100 件、同時 6 件で、8110 は約半分ずつ、8120 は `pool-slow` が 35〜65 件で所要時間が約 25 秒以上、8130 は `pool-slow` が 10 件以下で 8120 より明らかに短い。
- 既存の 4 リスナー (80 / 8080 / 8090 / 8100) の動作を変えない。
- 外部ライブラリを足さない。
- zsh の注意: `sed -i ''` ではなく `sed -i` (GNU sed)。前面での `sleep` は使わず `perl -e 'select(undef,undef,undef,N)'`。

## Review Focus

1. **保存済みの負荷分散の設定に `delay` がない** (以前のバージョンの localStorage)。読み込みでエラーにせず、遅延 0 として扱う。→ Task 4 の Step 1 に確認を入れる。
2. **同時 6 件の送り方でのキャンセル**。送信中に押すとすぐ止まり、送っていない要求は「未送信」、送信中は「中止」になる。今の 10 件まとめての動作と同じ。→ Task 2 の Step 1 に確認を入れる。
3. **応答がない要求 (10 秒のタイムアウト)** が混ざったときの所要時間と平均。タイムアウトした要求は平均に入れず、所要時間には入れる。→ Task 2 の Step 1 に確認を入れる。
4. **`DELAY_MS` が数字でない、または負の値**。0 として扱い、プロセスは起動する。→ Task 1 の Step 1 に確認を入れる。
5. **8120 と 8130 のプリセットを、ゲートウェイ URL が空のまま選ぶ**。予測欄に、サーバー選択のポートであることと、テスト要求で確かめることを表示する。既存の 8080 / 8090 と同じ扱い。→ Task 4 の Step 1 に確認を入れる。

---

### Task 1: バックエンドの遅延と 4 つのプロセス (#81)

**Files:**
- Modify: `backend/server.js` (環境変数の読み込みと、要求の処理)
- Modify: `backend/pools.conf`、`backend/pools-canary.conf` (列を追加、行を追加)
- Modify: `deploy/make-cloud-init.sh` (5 列目を読む)
- Regenerate: `deploy/cloud-init.yaml`、`deploy/cloud-init-canary.yaml`
- Create: `backend/server.test.js`

**Interfaces:**
- Produces: 環境変数 `DELAY_MS` (整数 ms、既定 0)。pools.conf の形式 `name|port|label|color|delay_ms`。プロセス `pool-slow` (VM 1、8086、3000)、`pool-rr-a` (VM 1、8087、0)、`pool-fast` (VM 2、8086、0)、`pool-rr-b` (VM 2、8087、0)。

- [ ] **Step 1: 失敗するテストを書く** (`backend/server.test.js`、`node:test` と `child_process.spawn` で server.js を空いているポートで起動する)

```js
test("DELAY_MS delays normal requests", async () => { /* DELAY_MS=300 → GET / の所要時間 >= 280 ms、x-backend-pool は POOL_NAME */ });
test("healthz is not delayed", async () => { /* DELAY_MS=3000 → GET /healthz が 500 ms 未満で 200 "ok" */ });
test("CORS preflight is not delayed", async () => { /* DELAY_MS=3000 → OPTIONS + access-control-request-method が 500 ms 未満で 204 */ });
test("invalid DELAY_MS is treated as 0", async () => { /* DELAY_MS=abc と DELAY_MS=-5 → 起動し、GET / が 500 ms 未満 */ });
```

- [ ] **Step 2: 失敗を確かめる**

Run: `node --test backend/server.test.js`
Expected: 遅延のテストが FAIL (遅延がないため)。

- [ ] **Step 3: `backend/server.js` に遅延を入れる**

`const DELAY_MS` は `Number.parseInt` の結果が 0 以上の整数のときだけその値、それ以外は 0。OPTIONS の事前確認と `/healthz` の分岐の後で、`setTimeout(..., DELAY_MS)` の中で残りの処理 (JSON か HTML の応答) をする。先頭のコメントの使い方の例に `DELAY_MS` を足す。

- [ ] **Step 4: テストが通ることを確かめる**

Run: `node --test backend/server.test.js`
Expected: 4 件とも PASS。

- [ ] **Step 5: pools.conf と cloud-init の生成を直す**

両方の conf の見出しを `# name|port|label|color|delay_ms` にし、既存の行の末尾に `|0` を足す。`pools.conf` に `pool-slow|8086|Slow server (3 s)|#b91c1c|3000` と `pool-rr-a|8087|Round Robin A|#0e7490|0`、`pools-canary.conf` に `pool-fast|8086|Fast server|#15803d|0` と `pool-rr-b|8087|Round Robin B|#6d28d9|0` を足す。`make-cloud-init.sh` は `read -r name port label color delay` で読み、env ファイルに `DELAY_MS=${delay:-0}` を書く。

- [ ] **Step 6: 生成結果を確かめる**

Run: `bash deploy/make-cloud-init.sh && bash deploy/make-cloud-init.sh backend/pools-canary.conf deploy/cloud-init-canary.yaml && grep -c 'DELAY_MS=' deploy/cloud-init.yaml deploy/cloud-init-canary.yaml && grep -A5 'pool-slow.env' deploy/cloud-init.yaml`
Expected: 件数が 7 と 3、`pool-slow.env` に `PORT=8086` と `DELAY_MS=3000`。`systemctl enable --now agw-pool@pool-slow` などが runcmd にある。

- [ ] **Step 7: コミットと PR**

```bash
git add backend deploy/make-cloud-init.sh deploy/cloud-init.yaml deploy/cloud-init-canary.yaml
git commit -m "feat: add DELAY_MS and the slow/fast and round robin backend processes (#81)"
```
ブランチ `server-selection-backend`、PR `Closes #81`。

---

### Task 2: 同時 6 件の送り方と所要時間 (#83)

**Files:**
- Modify: `agw-routing-simulator.html` (`runTestRequests`、`renderTestRun`、定数)
- Create: `deploy/lb-check.sh` (実行権限つき)
- Test: scratchpad の `sim-test-run.mjs` (headless Chrome)、scratchpad の `slow-local.mjs` (ローカルの代役サーバー)

**Interfaces:**
- Produces: `const TEST_CONCURRENCY = 6;`、`async function runLimited(n, limit, task, isCancelled)` (`task(i)` を同時 `limit` 件まで走らせ、1 件終わるごとに次を始める。`isCancelled()` が真なら新しい要求を始めない)。`run.seq[i].ms` (応答までのミリ秒)、`run.elapsedMs` (全体の所要時間)。CLI: `FRONTEND=<IP>:<port> ./lb-check.sh [URI] [N] [CONCURRENCY]`。

- [ ] **Step 1: 失敗する確認スクリプトを書く**

`slow-local.mjs` は 127.0.0.1:8080 で動き、CORS と `x-backend-pool` を返す。要求ごとに `pool-slow` (3000 ms) と `pool-fast` (0 ms) を交互に名乗る。7 件に 1 件は応答しない。`sim-test-run.mjs` はシミュレーターを ja と en で開き、ゲートウェイ URL を `http://127.0.0.1` にして 30 件送り、次を確かめる。
- 結果に「所要時間」(en: "Total time") が出る。
- 凡例の各行に平均の秒数 (例 `平均 3.0 秒` / `avg 3.0 s`) が出る。
- 同時に走っている要求が 6 件を超えない (代役サーバー側で同時接続数の最大を記録して返す)。
- 6 件目を送った直後にキャンセルすると 300 ms 以内に止まり、送っていない要求は「未送信」、送信中は「中止」になる。
- タイムアウトした要求は平均に入らない。

- [ ] **Step 2: 失敗を確かめる**

Run: `node sim-test-run.mjs`
Expected: 「所要時間」が見つからず FAIL。

- [ ] **Step 3: 実装する**

`runTestRequests` の 10 件まとめての `Promise.all` を `runLimited(n, TEST_CONCURRENCY, ...)` に置き換える。1 件ごとのタイムアウトとキャンセルの扱いは今のまま。`performance.now()` で 1 件ごとの `ms` と全体の `elapsedMs` を記録する。`renderTestRun` では、凡例の各行に平均 (`ms` がある要求だけで計算、秒、小数 1 桁) を足し、凡例の前に `L(\`所要時間: ${s} 秒\`, \`Total time: ${s} s\`)` を出す。テスト要求の説明文 (HTML の `data-ja` と英語) に、同時 6 件で送ることを書く。

- [ ] **Step 4: 確認が通ることを確かめる**

Run: `node sim-test-run.mjs`
Expected: ja と en で全項目 PASS。JavaScript のエラーなし。

- [ ] **Step 5: `deploy/lb-check.sh` を作る**

`canary-check.sh` と同じ書き方にする。`xargs -P "$CONCURRENCY"` で curl を並べ、`-w '%{time_total}'` と `x-backend-pool` を 1 行ずつ記録する。出力はプールごとに `  <pool>  <件数>  (<割合>%)  avg <秒> s`、最後に `total: <秒> s`。既定は `/app/home`、100 件、同時 6 件。

- [ ] **Step 6: CLI を確かめる**

Run: `node slow-local.mjs &` の後、`FRONTEND=127.0.0.1:8080 bash deploy/lb-check.sh / 12 6`
Expected: `pool-slow` と `pool-fast` の行があり、`pool-slow` の avg が約 3.0 s、`total:` 行がある。

- [ ] **Step 7: コミットと PR**

```bash
git add agw-routing-simulator.html deploy/lb-check.sh
git commit -m "feat: send test requests six at a time and show the time taken (#83)"
```
ブランチ `test-requests-concurrency`、PR `Closes #83`。

---

### Task 3: ゲートウェイの 3 ポート (#82)

ブランチ `server-selection-gateway` は `origin/main` から切る。Bicep はバックエンドのコードを読まないので、Task 1 とは独立に作れる。実機での確認だけは両方がそろってから行う (Task 6)。

**Files:**
- Modify: `deploy/main.bicep` (フロントエンド ポート、プローブの後のプール、バックエンド設定、リスナー、要求ルーティング ルール)

**Interfaces:**
- Consumes: Task 1 のプロセスとポート (8086 / 8087)。
- Produces: フロントエンド ポート `port-8110` / `port-8120` / `port-8130`、リスナー `listener-rr` / `listener-rr-slow` / `listener-lc`、ルール `rule-rr` (priority 500) / `rule-rr-slow` (600) / `rule-lc` (700)、プール `pool-rr` (8087 の 2 台) / `pool-rr-slow` (8086 の 2 台) / `pool-lc` (8086 の 2 台、`serverSelectionAlgorithm: 'LeastConnections'`)、バックエンド設定 `hs-8086` / `hs-8087` (Http、アフィニティ無効、`requestTimeout: 20`、プローブ `healthz`)。

- [ ] **Step 1: 失敗する確認を書く** (scratchpad の `bicep-check.py`。`az bicep build --file deploy/main.bicep --stdout` の JSON を読む)

確かめること: 上の名前がすべてある。3 つのルールが `ruleType: 'Basic'` で、対応するプールとバックエンド設定を指す。`pool-lc` だけが `serverSelectionAlgorithm == 'LeastConnections'` を持つ。各プールの `backendAddresses` が 192.168.1.10 と 192.168.1.11 の 2 件。既存のポート、リスナー、ルールの数と名前が変わっていない。

- [ ] **Step 2: 失敗を確かめる**

Run: `az bicep build --file deploy/main.bicep --stdout > main.json && python3 -I bicep-check.py main.json`
Expected: `port-8110` がなく FAIL。

- [ ] **Step 3: `deploy/main.bicep` に追加する**

新しいプロセスは `var pools` に入れない (入れると、プロセスごとのプールと設定が作られ、IP の割り当ても合わない)。プールは `backendAddressPools` の配列に直接書く。各要素にコメントで #82 と役割を書く。`serverSelectionAlgorithm` の行には、BCP037 の警告が出ることと、ポータルでの確認の結果 (設計書の該当節) を指すコメントを付ける。

- [ ] **Step 4: 確認が通ることを確かめる**

Run: Step 2 と同じ。
Expected: PASS。警告は既存の種類 (BCP037 など) と、新しい `serverSelectionAlgorithm` の BCP037 だけ。

- [ ] **Step 5: `deploy/test.sh` に 3 ポートを足す**

`run "Round Robin (:8110)"`、`run "RR slow (:8120)"`、`run "Least conn (:8130)"` を足し、注記に「8120 と 8130 は同時に試さない」「件数と時間は lb-check.sh で見る」を足す。

- [ ] **Step 6: コミットと PR**

```bash
git add deploy/main.bicep deploy/test.sh
git commit -m "feat: add round robin and least connections listeners on 8110/8120/8130 (#82)"
```
PR `Closes #82`。実機での確認は Task 6 で行い、結果を PR にコメントする。

---

### Task 4: シミュレーターの 3 ポート対応 (#84)

ブランチ `simulator-server-selection` は Task 2 のブランチから切る (同じファイルの近い場所を直すため)。Task 2 がマージされたら `origin/main` に付け替える。

**Files:**
- Modify: `agw-routing-simulator.html` (`POOLS`、プリセット、`evaluate` の早期の分岐、`gatewayPoolName` の付近、構成図、予測欄の文言、負荷分散の模擬処理とプリセット、検証)
- Test: scratchpad の `sim-ports.mjs`、scratchpad の `sim-dist.mjs`

**Interfaces:**
- Consumes: Task 2 の `run.seq[i].ms` と凡例 (変えない)。
- Produces: `POOLS` に `pool-rr` (8087)、`pool-rr-slow` (8086)、`pool-lc` (8086) を追加。`const SERVER_SELECT_PORTS = { 8110: { pool: "pool-rr", algo: "rr" }, 8120: { pool: "pool-rr-slow", algo: "rr" }, 8130: { pool: "pool-lc", algo: "lc" } };`。予測の種類 `d.kind === "server"` (`d.port` つき)。`const SERVER_COLOR = { "pool-slow": "#b91c1c", "pool-fast": "#15803d", "pool-rr-a": "#0e7490", "pool-rr-b": "#6d28d9" };` を凡例とセルの色に使う。`sv(name, weight = 1, healthy = true, delay = 0)`、サーバーの項目 `delay` (0〜10000 の整数 ms)。`simulate(d, n)` の戻り値に `elapsedMs` と `srvMs` (サーバーごとの合計 ms) を追加。

- [ ] **Step 1: 失敗する確認スクリプトを書く**

`sim-ports.mjs` (ja と en、ゲートウェイ URL は空): 3 つのプリセット `L("Round Robin (ポート 8110)", "Round Robin (port 8110)")`、`L("Round Robin 遅いサーバーあり (ポート 8120)", "Round Robin with a slow server (port 8120)")`、`L("Least Connections (ポート 8130)", "Least Connections (port 8130)")` がある。それぞれを選ぶと、予測欄にポート番号、アルゴリズム名、「テスト要求で確かめる」旨が出て、JavaScript のエラーがない。構成図にそのポートのステージが出る。

`sim-dist.mjs`: 負荷分散欄のプリセット `L("8120: Round Robin、片方が 3 秒", "8120: Round Robin, one server takes 3 s")` と `L("8130: Least Connections、片方が 3 秒", "8130: Least Connections, one server takes 3 s")` を選び、100 件、同時 6 件で、8120 は `pool-slow` が 35〜65 件、8130 は 10 件以下。8130 の所要時間が 8120 より短い。サーバーごとの遅延の入力欄がある。`delay` のない古い設定を localStorage (`agw-routing-simulator:v1` の `dist`) に入れて開いても、エラーにならず遅延 0 として表示される。

- [ ] **Step 2: 失敗を確かめる**

Run: `node sim-ports.mjs; node sim-dist.mjs`
Expected: プリセットが見つからず FAIL。

- [ ] **Step 3: 3 ポートの実装**

既存の 8090 の扱い (プリセット、`evaluate` の早期の分岐、`tones`、色、構成図のステージ、予測欄の文言) と同じ並びで `SERVER_SELECT_PORTS` を使う。`x-backend-pool` にはプロセス名が出るので、`gatewayPoolName` では名前を置き換えない (サーバーごとの件数をそのまま見せるため)。構成図での配置は作業する人に任せる。

- [ ] **Step 4: 負荷分散の模擬処理を時間で動かす**

`simulate` を、同時 `concurrency` 人の利用者がそれぞれ 1 件ずつ順に送る形に変える。1 件の所要時間は `BASE_MS (20) + server.delay`。いちばん早く終わる利用者から次の要求を出し、そのたびに終わった接続を `st.active` から引く。Least Connections の同点は今と同じ (送った件数が少ない方、次に並び順)。遅延の入力欄と検証、`elapsedMs` と平均の表示を足す。2 つのプリセットを足す (`pool-rr-slow` と `pool-lc`、サーバーは `sv("pool-slow", 1, true, 3000)` と `sv("pool-fast")`)。読み込み時に `delay` がないサーバーは 0 にする。

- [ ] **Step 5: 確認が通ることを確かめる**

Run: `node sim-ports.mjs; node sim-dist.mjs`、それと既存の確認 (scratchpad の `flag_check.mjs`)。
Expected: すべて PASS。既存のプリセットの予測は変わらない。

- [ ] **Step 6: コミットと PR**

```bash
git add agw-routing-simulator.html
git commit -m "feat: simulate and predict the round robin and least connections ports (#84)"
```
PR `Closes #84`。

---

### Task 5: ドキュメント (#85)

ブランチ `docs-server-selection` は Task 3 と Task 4 のブランチを取り込んでから切る。マージの後は `origin/main` に付け替える。

**Files:**
- Modify: `README.md`、`README_ja.md` (リポジトリの中身の表に `deploy/lb-check.sh`、「4 つのリスナー」を 7 つに、サーバー選択の節を新しく)
- Modify: `docs/agw-advanced-routing-demo-guide.html`、`docs/agw-advanced-routing-demo-guide_ja.html` (構成の表と図、確認の手順、test.sh の出力例)
- Modify: `.claude/skills/agw-advanced-routing-workshop/SKILL.md`、`SKILL_ja.md` (デモの節、期待される結果の表、ファイルの一覧)

- [ ] **Step 1: 書く内容**

8110 / 8120 / 8130 の役割と、プール、プロセス、ポートの対応。確認のコマンド `FRONTEND=<IP>:8130 ./lb-check.sh /app/home 100 6`。合格の基準の表。8120 と 8130 を同時に試さないこと。遅延 3 秒がプローブのタイムアウト 20 秒より短いので、遅いサーバーも正常のままであること。Least Connections はアフィニティが有効だと使われないこと。`serverSelectionAlgorithm` は公開仕様にないプレビューの項目で、BCP037 の警告が出ること。

- [ ] **Step 2: 英語版と日本語版の対応を確かめる**

Run: `grep -c '8110\|8120\|8130' README.md README_ja.md docs/*.html .claude/skills/agw-advanced-routing-workshop/SKILL*.md`
Expected: 各組 (英語版と日本語版) で件数がほぼ同じ。HTML のタグの対応が崩れていない (前回と同じ Python の確認)。

- [ ] **Step 3: コミットと PR**

```bash
git add README.md README_ja.md docs .claude/skills/agw-advanced-routing-workshop
git commit -m "docs: describe the round robin and least connections demo in English and Japanese (#85)"
```
PR `Closes #85`。

---

### Task 6: 実機での確認

コードの変更はない。Task 1〜4 のブランチを取り込んだ手元だけのブランチ `verify/server-selection` (push しない) で行う。

- [ ] **Step 1: 検証環境を作り直す**

既存の VM には cloud-init が再実行されないため、作り直す。`deploy/cleanup.sh --yes` はこのツールの権限で拒否されたことがあるので、ユーザーに実行してもらう。削除の完了 (`az group exists` が `false`) の後、`deploy/deploy.sh`。

- [ ] **Step 2: 既存のシナリオが変わっていないことを確かめる**

Run: `FRONTEND=<IP> deploy/test.sh`
Expected: 既存の 11 行は前回と同じ。新しい 3 行は HTTP 200。

- [ ] **Step 3: 合格の基準を CLI で確かめる** (ポートは 1 つずつ)

Run: `for p in 8110 8120 8130; do FRONTEND=<IP>:$p deploy/lb-check.sh /app/home 100 6; done`
Expected: Global Constraints の合格の基準を満たす。

- [ ] **Step 4: シミュレーターでも確かめる**

ゲートウェイ URL に実機の IP を入れ、3 つのプリセットでテスト要求を 100 件ずつ送る。Expected: CLI と同じ傾向。

- [ ] **Step 5: 結果を残す**

#82 の PR に結果の表をコメントする。基準を外れた場合は、設計書の「差が見えたと判断する基準」に実機の結果を書き、ユーザーに見直しを相談する。
