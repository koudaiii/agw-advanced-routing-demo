# Application Gateway Advanced Routing ワークショップ

これは `SKILL.md` (英語、スキル本体) の日本語版です。

このリポジトリは [Advanced rules (プレビュー)](https://learn.microsoft.com/azure/application-gateway/advanced-rules) と [Advanced load balancing (プレビュー)](https://learn.microsoft.com/azure/application-gateway/advanced-load-balancing) を実機で示すデモです。ワークショップは次の順で進めます。

1. 前提確認
2. デプロイ (Bicep, 約 15〜20 分)
3. 疎通確認 (`test.sh`)
4. ライブデモ (ルール、WAF、リダイレクト)
5. 負荷分散シミュレーション (シミュレーターのみ)
6. 片付け

作業ディレクトリは **リポジトリのルート** です。Azure の操作は実行前にユーザーへ確認を取ってください (課金が発生し、数分かかります)。

## 1. 前提確認

```bash
az account show --query "{sub:name, id:id, user:user.name}" -o table   # 対象サブスクリプションか確認
az provider show -n Microsoft.Network --query registrationState -o tsv   # Registered であること
```

- Azure CLI 2.87.0 には `az network application-gateway advanced-routing-*` が **ありません**。そのためデプロイは CLI ではなく Bicep (`deploy/main.bicep`、ARM API `Microsoft.Network/applicationGateways@2026-03-01`) で行います。`az bicep version` で Bicep が使えることを確認します。API バージョンは 2026-03-01 のままです。ARM 検証では 2026-05-01 と 2026-07-01 も成功しましたが、高度なルールの新しい機能は確認できませんでした。
- SSH 鍵 (`~/.ssh/id_ed25519.pub`) がなければ `deploy.sh` が自動生成します。
- 必要なパラメーターはありません。カナリアは送信元 IP や URI では絞らず、ポート 8080 の全リクエストを対象に、pool-web 90% / pool-canary 10% に振り分けます (ルール `canary-split`)。
- 重み付けは Advanced load balancing の機能です。高度なルールで `WeightedDistribution` を指定すれば、実機で振り分けが効きます (2026-11-20 に確認)。

## 2. デプロイ

```bash
cd deploy
./deploy.sh
```

成功すると最後に `Done. Frontend: http://<IP>/` が出ます。以下は `deploy.sh` が行うことです。

- `make-cloud-init.sh` で 2 つの初期化ファイルを生成 (`backend/server.js` を埋め込み): `cloud-init.yaml` (バックエンド VM 1) と `cloud-init-canary.yaml` (カナリア VM 2、`backend/pools-canary.conf`)
- リソースグループ `rg-agw-advrouting-demo` を作成
- `main.bicep` をデプロイ: VNet (`appgw` 192.168.0.0/24 / `backend` 192.168.1.0/24)、バックエンド NSG、バックエンド VM 1 (Ubuntu 24.04、固定 IP 192.168.1.10、Node.js プロセス 5 つ = ポート 8080–8083、8085)、カナリア VM 2 (固定 IP 192.168.1.11、`pool-canary` をポート 8080)、WAF_v2 ポリシー (Prevention、DRS 2.1、カスタムルール `BlockDemoIp` と `BlockDemoUA`)、NAT Gateway (StandardV2、backend サブネットに関連付け)、Application Gateway、Advanced routing map (`advancedRoutingMap1`、ポート 80 の条件セット 5 つとルール 5 つ、既定 pool-web)、マップ `canaryMap` (ポート 8080、既定は pool-canary、ルール `canary-split` で pool-web 90 / pool-canary 10、条件セット `cs-canary-split` は全パス一致)、`rule1` (Advanced、ポート 80)、`rule-canary` (Advanced、ポート 8080、マップ `canaryMap`)。

ゲートウェイのバックエンドが Healthy になるまで数分かかることがあります。確認:

```bash
az network application-gateway show-backend-health -g rg-agw-advrouting-demo -n agwdemo-agw -o table
```

## 3. 疎通確認

```bash
cd deploy && FRONTEND=<表示された IP> ./test.sh
```

**期待結果** (実機で確認済み、送信元 IP に依存しません):

| シナリオ | 期待 | 理由 |
|---|---|---|
| Default (通常アクセス) | 200 pool-web | 既定プール |
| Tenant (テナント) | 200 pool-tenant | `X-Tenant-Id: customer-*` と `/app` |
| Partner (パートナー) | 200 pool-partner | `X-Partner-Id` 一致 (GET で送る) |
| API v2 | 200 pool-api-v2 | `X-Api-Version: 2.0` と `/api/orders` |
| Encoded path (エンコード済みパス) | 200 pool-api-v2 | `/api%2Forders` はデコードされて一致 |
| Canary (:8080 90:10) | 200 pool-web / pool-canary | 8080 番の全体を pool-web 90% / pool-canary 10% で振り分け (1 件では片方に決まる) |
| Campaign (キャンペーン) | 302 (`https://www.contoso.com/campaign?campaign=...`) | 高度なルールのキャンペーン条件 (優先度 40) で一致する |
| Mobile (モバイル) | 200 pool-mobile | iPhone UA。カナリアはポート 8080 のみのため影響しない |
| A/B variant A | 200 pool-web (`pool-A`) | ポート 8100 (変種ヘッダーなし)。マップ `abMap` の既定 |
| A/B variant B | 200 pool-canary (`pool-B`) | ポート 8100 + `X-Variant: B`。ルール `ab-variant-b` (優先度 10) |
| WAF block (UA) | 403 | `curl -A agw-block-demo` の要求。ルーティングの前に WAF が遮断する (`BlockDemoUA`) |

**100 回連続の確認** (`deploy/canary-check.sh`、ポート 8080):

```bash
cd deploy && FRONTEND=<IP>:8080 ./canary-check.sh /app/home 100   # → pool-web 約 90 件、pool-canary 約 10 件 (実機確認: 91 / 9)
cd deploy && FRONTEND=<IP>      ./canary-check.sh /app/home 100   # → ポート 80 は高度なルール (重み付けなし)
```

> 注意: 重み付けは「期待値」で、件数は少しずれます (ドキュメントどおり、件数が少ないと期待値から外れます)。

## 4. ライブデモ

ブラウザーで `agw-routing-simulator.html` を開き、ゲートウェイ URL に `http://<FRONTEND>` を入力すると、予測と実機の応答を並べて比較できます (`backend/server.js` は CORS 対応済み)。

- 実機モードでは、予測の送信元 IP はプリセットの値ではなく、ゲートウェイが見ている実際の IP (`X-Forwarded-For`) を使います。
- カナリア (ポート 8080) はシミュレーターの「負荷分散」セクションの「カナリア: ポート 8080 全体 90:10」プリセットで予測します。実機と同じ 90:10 の構成です。ポート 80 の高度なルールは送信元 IP に依存しません。

推奨の順序:

1. **既定と一致ルール**: 「テナント」「API v2」のプリセットを送信し、実機の `x-backend-pool` と予測が一致することを示す。
2. **優先度**: ルール 1 (パートナー) とルール 2 (テナント) が両方一致しうる要求を作り、優先度の小さい方が勝つことを示す。
3. **Path 条件の正規化**: 「エンコード済みパス」で `/api%2Forders` がデコードされて一致することを示す。
4. **リダイレクト**: 「キャンペーン」を送り、302 と Location (クエリ文字列が引き継がれる) を確認する。優先度 40 の条件なので、プレゼンターの IP からでも出る。
5. **WAF はルーティングより前**: WAF ブロック用の IP を追加して 403 を出す (次の節)。

### WAF ブロックの実演

WAF は、ルーティングより前に要求を遮断します。実演には、テンプレートに入っている User-Agent の WAF ルール `BlockDemoUA` (優先度 12) を使います。どのクライアントからでも再現でき、CLI での作成や削除は不要です。

```bash
curl -i -A "agw-block-demo" http://<FRONTEND>/app/home   # → 403 (ルーティングの前に遮断)
curl -i http://<FRONTEND>/app/home                        # → 200 (比較用)
```

シミュレーターでも、WAF 欄の「ブロックする User-Agent」に `agw-block-demo` を入れた状態で「WAF ブロック (User-Agent)」プリセットを送ると、同じ結果を予測できます。

`BlockDemoIp` (198.51.100.0/24、送信元 IP による遮断) も残しています。送信元 IP は環境で変わるため、デモでは User-Agent を使います。

## 5. 負荷分散シミュレーション (シミュレーター)

```text
                  一致したルール
                        |
                        v
              プール選択アルゴリズム
              |                   |
              v                   v
   重み付け (Weighted)        優先度 (Priority)
   Pool A: 重み 8 (80%)       Priority 1 = 主系 (条件を満たす間)
   Pool B: 重み 2 (20%)       Priority 2 = 待機系 (主系が使えないとき)
   異常でも割合は変わらない    最小正常割合で適格かを判定
```


`agw-routing-simulator.html` の「負荷分散: プール選択 → サーバー選択」セクションは **シミュレーションのみ** です。実機には反映されません (実機の各プールはサーバー 1 台です)。

- プリセット: ポート 8080 全体のカナリア 90:10 (実機と同じ構成)、重み 8:2、優先度 (5 台中 1 台異常 → プライマリ、5 台中 3 台異常 → スタンバイ)、WRR 6:3:1 (全台正常 / 重み 6 が異常)
- 期待値 (ドキュメントと一致): 90:10 → 90/10、8:2 → 80/20。WRR 6:3:1 全台正常 → 60/30/10、重み 6 が異常 → 75/25。優先度 最小正常割合 60%: 5 台中 1 台異常はプライマリ、5 台中 3 台異常はスタンバイ。

ドキュメント対応: 「Pool selection algorithm」「Server selection algorithm」「How requests are distributed」(advanced-load-balancing)。

## 6. 片付け

```bash
az group delete -n rg-agw-advrouting-demo --yes --no-wait
```

ゲートウェイ (WAF_v2) とバックエンド VM は課金されます。ワークショップ後は必ず削除してください。

## 既知の問題

- **本文のない POST が 403 になる**: `/api/orders` への本文のない POST は、DRS 2.1 のマネージドルールに遮断されます。本文 (JSON) 付きの POST や GET / PUT は通ります。ワークショップのテストとシミュレーターは GET で送ります。原因のルール ID は未特定です。
- **ARM API の事実 (2026-11-20 確認)**: 高度なルールは、単一プール (`backendAddressPool`) と複数プール (`backendAddressPoolsAndSettings` + `poolSelectionAlgorithm`) のどちらも指定できます。複数プールの重み付け (`WeightedDistribution`) は、実機に反映されます。高度なルールに `loadDistributionPolicy` (Basic 用の項目) だけを指定すると、ARM は `ApplicationGatewayAdvancedRoutingRuleMustReference` で拒否します。公開の REST API 仕様 (2026-03-01 / 2026-05-01) には複数プールの項目がなく、仕様は不完全です。

## 講義のポイント (ドキュメントとの対応)

| 話題 | ドキュメント | デモ |
|---|---|---|
| 階層 (ルーティングマップ → ルール → 条件セット → 条件) | advanced-rules: Architecture overview | `main.bicep` の `advancedRoutingMaps` / `advancedRoutingConditionSets` |
| 条件種別 (Header, QueryString, ClientIP, Method, Path) | advanced-rules: Supported condition types | test.sh の各シナリオ |
| 評価は優先度順、最初の一致で決定 | advanced-rules: Request flows | 優先度 10 (パートナー) と 20 (テナント) |
| WAF はルーティングより前 | advanced-rules: WAF integration | 「WAF はルーティングより前」の節 |
| 正規表現 (RE2) とパス正規化 | advanced-rules: Path, Pattern matching | 「エンコード済みパス」 |
| 負荷分散 (プール選択 / サーバー選択 / 最小正常割合) | advanced-load-balancing | 「負荷分散」セクション (シミュレーター) |
| 重み付けによるカナリア (ポート全体 90:10) | advanced-load-balancing: Weighted distribution (Advanced ルール) | ポート 8080 の `rule-canary` と マップ `canaryMap`、`canary-check.sh` |

## 設計メモ: なぜカナリア用の VM2 が必要か

```text
 VM1 (192.168.1.10)                      VM2 (192.168.1.11)
 +----------------------------+          +----------------------------+
 | :8080 pool-web (既存)      |          | :8080 pool-canary (新版)   |
 | :8081 pool-partner         |          +----------------------------+
 | :8082 pool-tenant          |
 | :8083 pool-api-v2          |
 | :8085 pool-mobile          |
 +----------------------------+

 8080 番の流れ: listener-canary -> rule-canary -> canaryMap -> canary-split
                 -> WeightedDistribution (pool-web 90 / pool-canary 10)
```


- 高度なルールでは、プールごとにバックエンド設定 (`backendHttpSettings`) を持てます。pool-web と pool-canary は、どちらも `hs-pool-web` (8080 番) を使っています。
- pool-web は VM1 の 8080 番で動いています。同じポートで別の応答を返す pool-canary を置くには、**別の IP アドレス** が必要です。そのため新バージョン (pool-canary) は VM2 (192.168.1.11) の 8080 番で動かします。
- 以前の構成 (VM1 の 8084 番) は、Basic ルールの重み付けに入れられませんでした (同じポートが必要だったため)。VM2 を別ポートにできるかは未検証です。
- 代替案: VM1 に 2 つ目の IP を付け、同じ方法で動かせば VM が 1 台減ります。ただし VM1 の初期化データ (customData) の変更は既存 VM で拒否されるため、VM1 の再作成が必要になります。

## 現在の実装状態 (8080 番のカナリア)

- 8080 番のカナリアは、高度なルール `canary-split` (`WeightedDistribution`、pool-web 90 / pool-canary 10) で動きます。切り替えのスイッチはありません。

## 優先度ベースの確認 (ポート 8090)

構成: リスナー `listener-priority` (8090)、ルール `rule-priority` (Advanced、優先度 300)、マップ `priorityMap`。マップの中で、全パスに一致するルール `priority-split` が、`pool-primary` (VM 2、優先度 1) と `pool-standby` (VM 1、優先度 2) を `PriorityAware`、最小正常割合 60% で振り分けます。既定の振り分け先は `pool-standby` です。

確認は 3 つの状態で行います。

| 状態 | 期待 | 手順 |
|---|---|---|
| 正常 | 100 件すべて `pool-primary` (VM 2) | `FRONTEND=<IP>:8090 ./canary-check.sh /app/home 100` |
| VM 2 停止 | 切り替わるまで約 2〜3 分。その後 100 件すべて `pool-standby` (VM 1) | 下のコマンドで停止し、2〜3 分待つ |
| 復旧 | 100 件すべて `pool-primary` に戻る | 下のコマンドで起動し、2〜3 分待つ |

```bash
# 停止 (VM 2 の pool-canary)
az vm run-command invoke -g rg-agw-advrouting-demo -n agwdemo-backend-canary --command-id RunShellScript --scripts "systemctl stop agw-pool@pool-canary"
# 復旧
az vm run-command invoke -g rg-agw-advrouting-demo -n agwdemo-backend-canary --command-id RunShellScript --scripts "systemctl start agw-pool@pool-canary"
```

- VM 2 の pool-canary を止めないと、Primary に送られ続けるため、Standby への切り替えは見えません。
- シミュレーターの「テスト要求」は、選んでいる要求のポートに件数分送ります。優先度 (8090) のプリセットを選んでから押すと、Primary / Standby の件数を数えられます。押すと「キャンセル」に変わり、送信を止められます。結果は「実機の応答」の欄に、50 件ずつ表示します。


## A/B テスト (ヘッダーで変種を決める)

A/B テストは、専用のリスナー (ポート 8100) と、専用のマップ `abMap` で処理します。ルール `ab-variant-b` (優先度 10) は、ヘッダー `X-Variant` = `B` に一致した要求を `pool-B` (VM 2 の 8080 番) に送ります。一致しない要求は、マップの既定 `pool-A` (VM 1 の 8080 番) に送ります。`rule-ab` (ポート 8100) が `abMap` を参照します。

| 要求 | 期待 |
|---|---|
| `:8100/` (ヘッダーなし) | pool-web (`pool-A`、変種 A、既定) |
| `:8100/` + `X-Variant: A` | pool-web (`pool-A`、変種 A、既定) |
| `:8100/` + `X-Variant: B` | pool-canary (`pool-B`、変種 B) |
| `:80/ab` + `X-Variant: B` | pool-web (ポート 80 には A/B のルールがない) |

```bash
curl -s -D - -o /dev/null -H "X-Variant: B" http://<FRONTEND-IP>:8100/ | grep -i x-backend-pool
```

- シミュレーターの「A/B (変種 A / B)」プリセットで、同じ予測を確認できます。
- 変種の割り振りはクライアントが決めるため、本番の A/B テストではなく、デモ用の仕様です。
- ランダムに 50:50 で割り振る方式 (`/ab` を `WeightedDistribution` で振り分ける) は、このデモでは作っていません。同じ機能で作れますが、同じ利用者が同じ変種に入るとは限りません。

## 設計メモ: 外向き通信 (NAT Gateway)

- バックエンド VM には public IP を付けません。受信は NSG の既定ルール (インターネットからの受信は拒否) で遮断します。
- 外向き通信 (apt など) は NAT Gateway (StandardV2、専用の StandardV2 public IP) を backend サブネットに関連付けて行います。
- backend サブネットは `defaultOutboundAccess: false` (プライベート サブネット) です。既定の外向き IP は付きません。既存の VM では、この変更を反映するには停止と割り当て解除が必要です。

## 関連ファイル

- `deploy/main.bicep`: インフラ全体 (テンプレート)
- `deploy/deploy.sh`: デプロイ手順
- `deploy/make-cloud-init.sh`, `deploy/cloud-init.yaml`, `deploy/cloud-init-canary.yaml`: バックエンド VM の初期化 (VM 1 / カナリア VM 2)
- `deploy/test.sh`: 疎通確認
- `deploy/canary-check.sh`: 指定した URI に 100 回連続で送り、プール別の件数を表示 (カナリアは `FRONTEND=<IP>:8080`)
- `backend/server.js`, `backend/pools.conf`, `backend/pools-canary.conf`: バックエンドとプール定義
- `agw-routing-simulator.html`: 予測と実機の比較、負荷分散シミュレーション
- `docs/agw-advanced-routing-demo-guide_ja.html` (日本語)、`docs/agw-advanced-routing-demo-guide.html` (英語): 参加者向けガイド
