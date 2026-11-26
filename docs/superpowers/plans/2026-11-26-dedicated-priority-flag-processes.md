# 優先度ベースと機能フラグの専用プロセス Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** :8090 と :8100 のゲートウェイ プールを、:8080 の流用から専用プロセス (8088 / 8089) に移し、停止の影響と名前の読み替えをなくす。

**Architecture:** 4 つのプロセスを `pools.conf` / `pools-canary.conf` に足し、cloud-init を作り直す。`main.bicep` では `pools` の一覧に VM の欄を足して、プールとバックエンド設定 (`hs-<プール名>`) を一覧から作り、手書きの 4 プールを消す。シミュレーターは読み替えの表を消し、表示と停止手順を新しい構成に合わせる。文書 (日英) を最後にそろえる。

**Tech Stack:** Bicep (`Microsoft.Network/applicationGateways@2026-03-01`)、Node.js (依存なし)、bash、単一 HTML のシミュレーター、`node:test` + headless Chrome (CDP)

**Spec:** `docs/superpowers/specs/2026-11-26-dedicated-priority-flag-processes-design.md`

## Global Constraints

- プロセス: `pool-primary` VM 2 :8088 / `pool-standby` VM 1 :8088 / `pool-flag-on` VM 2 :8089 / `pool-flag-off` VM 1 :8089。遅延 0。
- 色: `pool-primary` #b45309、`pool-standby` #475569、`pool-flag-off` #0369a1、`pool-flag-on` #be185d。
- 変えない: ルール、条件、重み、優先度、`minimumHealthyPercent: 60`、:8080 と :8110〜:8130。
- 新しいバックエンド設定は `cookieBasedAffinity: 'Disabled'`、`requestTimeout: 20`、プローブ `healthz`。
- 停止手順: `systemctl stop agw-pool@pool-primary` / `systemctl start agw-pool@pool-primary` (VM `agwdemo-backend-canary`)。
- 文書は英語版と日本語版の両方を直す。シミュレーターの日本語は `data-ja` と `L("日本語", "English")`。
- シミュレーターは TDD (テストを先に変え、失敗を見てから直す)。全体は `node --test backend/server.test.js tests/simulator.test.mjs`。
- Issue #131、ブランチ `dedicated-priority-flag-processes`、PR は 1 つ。マージはオーナーの指示があったときだけ。コミットの末尾は `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。

## Review Focus

1. 新しいポートのヘルス プローブ: `server.js` はどのポートでも `/healthz` に 200 を返すので、8088 / 8089 でも正常になること (Task 6 の実機確認)。
2. 保存済みのシミュレーター設定: ルールの送り先 `pool-flag-on` / `pool-flag-off` は名前が変わらないので、読み込みで捨てられないこと (Task 3 の既存テストで確認)。
3. 文書の取り残し: :8090 / :8100 の文脈に `pool-canary` / `pool-web` や `agw-pool@pool-canary` が残らないこと (Task 4・5 の grep)。
4. `x-backend-pool` が想定外の名前 (たとえば :8090 で `pool-web`) を返したとき、シミュレーターが読み替えずにそのまま出すこと (Task 3 のテスト)。
5. VM の初期化データの大きさ: customData の上限 64 KB に収まること (Task 1)。

---

### Task 1: プロセスの定義と cloud-init

**Files:**
- Modify: `backend/pools.conf` (VM 1)、`backend/pools-canary.conf` (VM 2)
- Regenerate: `deploy/cloud-init.yaml`、`deploy/cloud-init-canary.yaml`

設定ファイルの変更なのでテストは書かない (コードの変更がない)。

- [ ] **Step 1:** `pools.conf` に 2 行を足す。`pool-standby|8088|Standby (priority 2)|#475569|0` と `pool-flag-off|8089|Feature flag off|#0369a1|0`。
- [ ] **Step 2:** `pools-canary.conf` に 2 行を足す。`pool-primary|8088|Primary (priority 1)|#b45309|0` と `pool-flag-on|8089|Feature flag on|#be185d|0`。
- [ ] **Step 3:** 作り直す。`bash deploy/make-cloud-init.sh && bash deploy/make-cloud-init.sh backend/pools-canary.conf deploy/cloud-init-canary.yaml`
- [ ] **Step 4:** 確かめる。YAML として読めること (`uv run --with pyyaml`)、`/etc/agw-demo/pool-primary.env` などの 4 ファイルと `systemctl enable --now agw-pool@<名前>` があること、base64 の大きさが 64 KB 未満であること。期待: VM 1 は 9 プロセス、VM 2 は 5 プロセス。
- [ ] **Step 5:** コミット。

### Task 2: ゲートウェイ (deploy/main.bicep)

**Files:**
- Modify: `deploy/main.bicep` (`pools` の一覧 84 行付近、`poolAddressPools` 36 行付近、手書きの 4 プール 491〜534 行付近、`priorityMap` と `flagMap` 925〜985 行付近、流用を説明するコメント)

**Interfaces:**
- Produces: バックエンド プール `pool-primary` / `pool-standby` / `pool-flag-on` / `pool-flag-off` (名前は変わらない)、バックエンド設定 `hs-pool-primary` (8088)、`hs-pool-standby` (8088)、`hs-pool-flag-on` (8089)、`hs-pool-flag-off` (8089)。

- [ ] **Step 1:** `pools` の各要素に `vm` (1 か 2) を足し、4 つの要素を加える。`poolAddressPools` の宛先を `p.vm == 2 ? vm2Ip : vm1Ip` にする (`pool-canary` は `vm: 2`)。
- [ ] **Step 2:** 手書きの `pool-primary` / `pool-standby` / `pool-flag-off` / `pool-flag-on` を `backendAddressPools` から消す (一覧から作られるため)。
- [ ] **Step 3:** `priorityMap` (規則 `priority-split` の 2 プールと既定) と `flagMap` (規則 `flag-on` と既定) のバックエンド設定を、`hs-pool-web` から `hs-pool-primary` / `hs-pool-standby` / `hs-pool-flag-on` / `hs-pool-flag-off` に替える。
- [ ] **Step 4:** 確かめる。`az bicep build -f deploy/main.bicep --stdout > /dev/null` がエラーなく終わる (BCP037 の警告は既存のもの)。生成された JSON で、4 プールの宛先 IP とバックエンド設定のポートが Global Constraints どおりであること。`az deployment group validate -g rg-agw-advrouting-demo -f deploy/main.bicep` が成功すること (リソース グループがあるとき。読み取りのみ)。
- [ ] **Step 5:** コミット。

### Task 3: シミュレーター (TDD)

**Files:**
- Modify: `agw-routing-simulator.html` (`POOLS` 292〜293 行、`PRIORITY_NAME_ON_8090` / `FLAG_NAME_ON_8100` / `gatewayPoolName` 495〜502 行とその呼び出し 639・944・945・1400 行、`renderDiagram` の `priorityPools` 723〜724 行とコメント 734 行、停止手順の注記 168〜172 行、表示の `rawPool` 948 行)
- Test: `tests/simulator.test.mjs`

**Interfaces:**
- Consumes: Task 1 のプロセス名 (= `x-backend-pool` の値)。

- [ ] **Step 1: 失敗するテストを書く (3 つ)。**
  - `the diagram shows the dedicated ports 8088 and 8089`: 経路図の文字に `:8088 Priority 1`、`:8088 Priority 2`、`:8089 Feature flag on`、`:8089 Feature flag off` があり、`:8080 Priority` がない (英語)。日本語は `:8088 優先度 1` と `:8089 機能フラグ オン`。
  - `the note on stopping the primary names pool-primary and nothing else fails (en / ja)`: #119 のテスト (`the note on stopping pool-canary says what else fails`) を置き換える。本文に `systemctl stop agw-pool@pool-primary` があり、`agw-pool@pool-canary` と「8080 の約 10%」/ "about 10% of requests on port 8080" がない。
  - `a live response on 8090 shows x-backend-pool as it is`: 127.0.0.1:8090 で代わりのゲートウェイを動かし (CORS は既存の代わりと同じ、`x-backend-pool: pool-web` を返す)、「優先度 (ポート 8090)」を実機モードで 1 件送る。応答の文に `x-backend-pool: pool-web` があり、`pool-standby` への読み替えと "process on the VM" がない。8090 が使用中で listen できないときは、このテストだけ skip する。
- [ ] **Step 2: 失敗を見る。** `node --test --test-name-pattern="dedicated ports|stopping the primary|as it is" tests/simulator.test.mjs`。期待: 3 つとも失敗 (図は `:8080 Priority 1`、注記は `agw-pool@pool-canary`、応答は `pool-standby (process on the VM: pool-web)`)。
- [ ] **Step 3: 直す。**
  - `POOLS` の `pool-flag-off` / `pool-flag-on` の `port` を 8089 に。`priorityPools` の `sub` を `L(":8088 優先度 1", ":8088 Priority 1")` / `L(":8088 優先度 2", ":8088 Priority 2")` に。
  - `PRIORITY_NAME_ON_8090`、`FLAG_NAME_ON_8100`、`gatewayPoolName` を消し、呼び出し元はプロセス名をそのまま使う。`rawPool` と "(process on the VM: …)" の表示も消す。476 行と 859 行のコメントを合わせる。
  - 停止手順の注記: コマンドを `agw-pool@pool-primary` に。本文を「優先度ベースを実機で試す前に、VM 2 の pool-primary (8088 番) を手動で止めてください。止めないと Primary に送られ続け、Standby への切り替えは見えません。止まるのは 8090 の Primary だけで、ほかのポートには影響しません。」/ "Before you test priority-based selection on the real gateway, stop pool-primary (port 8088) on VM 2 by hand. Otherwise every request keeps going to Primary and you cannot see the switch to Standby. Only the 8090 primary stops; other ports are not affected." にする。
- [ ] **Step 4: 通ることを見る。** 3 つのテストと全体 (`node --test backend/server.test.js tests/simulator.test.mjs`) が通る。
- [ ] **Step 5:** コミット。

### Task 4: test.sh とガイド (日英)

**Files:**
- Modify: `deploy/test.sh` (39 行の説明)、`docs/agw-advanced-routing-demo-guide.html`、`docs/agw-advanced-routing-demo-guide_ja.html`
- Regenerate: ガイドの図 1 (スクラッチパッドの `gen-svg.py` に 8088 / 8089 の行を足して英日を生成)

- [ ] **Step 1:** `test.sh` の説明を「flag off is pool-flag-off, flag on is pool-flag-on (dedicated processes on port 8089)」に。
- [ ] **Step 2:** 図 1: VM 1 の枠に `pool-standby :8088`、`pool-flag-off :8089`、VM 2 の枠に `pool-primary :8088`、`pool-flag-on :8089` を足し、`priorityMap` / `flagMap` からの線をそれらに付け替える。凡例の「VM 2 の pool-canary を止めると…」を `pool-primary` に。英日で全ラベルが箱に収まることを headless Chrome で確かめる。
- [ ] **Step 3:** 本文 (英日):
  - §3.3 pools.conf の例とプロセス数 (VM 1: 9、VM 2: 5)。
  - §4.1 リソース表の :8090 / :8100 の行と VM の行。
  - §4.2 優先度: 期待結果を `pool-primary` / `pool-standby` に、停止と復帰のコマンドを `agw-pool@pool-primary` に、#119 の注記を「止まるのは 8090 の Primary だけ」に。機能フラグ: 期待結果を `pool-flag-off` / `pool-flag-on` に (#129 の `NEW` の行も)。
  - §6 #9 と §7: #119 で足した「pool-canary の停止中に…」の行を消し、#9 を新しい停止手順に。
- [ ] **Step 4:** 確かめる。`grep -n -E "agw-pool@pool-canary|process name|プロセス名" docs/*.html` で :8090 / :8100 の文脈に古い記述が残っていないこと。日英の HTML のタグの対応が崩れていないこと。
- [ ] **Step 5:** コミット。

### Task 5: README とワークショップのスキル (日英)

**Files:**
- Modify: `README.md`、`README_ja.md`、`.claude/skills/agw-advanced-routing-workshop/SKILL.md`、`SKILL_ja.md`

- [ ] **Step 1:** ファイル一覧のプロセス数 (VM 1: 9、VM 2: 5) と `pools.conf` / `pools-canary.conf` の説明。
- [ ] **Step 2:** :8090 の節: 停止と復帰を `agw-pool@pool-primary` に、影響の文を「8090 の Primary だけ」に。:8100 の節: VM 2 / VM 1 の 8089 番。
- [ ] **Step 3:** 「`pool-primary`… は既存のプロセスを指す」の段落 (README 140 行付近とスキルの同じ箇所) を、専用プロセスの説明に置き換える。
- [ ] **Step 4:** 確かめる。`git grep -n -E "agw-pool@pool-canary|existing processes|既存のプロセス" -- README* .claude` が何も返さない。
- [ ] **Step 5:** コミットし、push して PR を出す (Closes #131)。

### Task 6: 実機での確認

オーナーの了承を得て、環境を作り直す (`./cleanup.sh` → `./deploy.sh`)。

- [ ] **Step 1:** `FRONTEND=<IP> ./test.sh` で、機能フラグが `pool-flag-off` / `pool-flag-on` を返す。
- [ ] **Step 2:** `FRONTEND=<IP>:8090 ./canary-check.sh /app/home 100` で、100 件すべて `pool-primary`。
- [ ] **Step 3:** `agw-pool@pool-primary` を止めて 2〜3 分後: :8090 は 100 件すべて `pool-standby`。:8080 は `canary-check.sh` で失敗なし (約 90:10)、:8100 の `X-Feature: new` は `pool-flag-on` で 200。
- [ ] **Step 4:** 復帰して、:8090 が `pool-primary` に戻る。結果を PR に書く。
