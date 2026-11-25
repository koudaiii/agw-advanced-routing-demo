# Application Gateway Advanced Routing ワークショップ

これは `SKILL.md` (英語、スキル本体) の日本語版です。

このリポジトリは [Advanced rules (プレビュー)](https://learn.microsoft.com/azure/application-gateway/advanced-rules) と [Advanced load balancing (プレビュー)](https://learn.microsoft.com/azure/application-gateway/advanced-load-balancing) を実機で示すデモです。ワークショップは次の順で進めます。

1. 前提確認
2. デプロイ (Bicep, 約 15〜20 分)
3. 疎通確認 (`test.sh`)
4. ライブデモ (ルール、WAF、リダイレクト)
5. 負荷分散シミュレーション (シミュレーターのみ)
6. 片付け

カナリア (8080)、優先度 (8090)、機能フラグ (8100)、サーバー選択 (8110〜8130) の節は、片付けの節の後にあります。

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
| Feature flag off | 200 pool-web (`pool-flag-off`) | ポート 8100 (`X-Feature: new` なし)。マップ `flagMap` の既定 |
| Feature flag on | 200 pool-canary (`pool-flag-on`) | ポート 8100 + `X-Feature: new`。ルール `flag-on` (優先度 10) |
| Round Robin (:8110) | 200 pool-rr-a または pool-rr-b | `pool-rr` の速い 2 台 |
| RR slow (:8120) | 200 pool-fast、または 3 秒後に pool-slow | 遅いサーバーと速いサーバーの Round Robin |
| Least conn (:8130) | 200 pool-fast、または 3 秒後に pool-slow | 1 件ではどちらにも届く。件数は `lb-check.sh` で見る |
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


`agw-routing-simulator.html` の「負荷分散: プール選択 → サーバー選択」セクションは **シミュレーションのみ** です。実機には反映されません。実機で 2 台入りのプールがあるのは、ポート 8110〜8130 だけです。

- プリセット: ポート 8080 全体のカナリア 90:10 (実機と同じ構成)、重み 8:2、優先度 (5 台中 1 台異常 → プライマリ、5 台中 3 台異常 → スタンバイ)、WRR 6:3:1 (全台正常 / 重み 6 が異常)
- 期待値 (ドキュメントと一致): 90:10 → 90/10、8:2 → 80/20。WRR 6:3:1 全台正常 → 60/30/10、重み 6 が異常 → 75/25。優先度 最小正常割合 60%: 5 台中 1 台異常はプライマリ、5 台中 3 台異常はスタンバイ。

ドキュメント対応: 「Pool selection algorithm」「Server selection algorithm」「How requests are distributed」(advanced-load-balancing)。

## 6. 片付け

```bash
cd deploy && ./cleanup.sh             # リソースの一覧を表示し、グループ名の入力を求めてからリソースグループを削除
cd deploy && ./cleanup.sh --dry-run   # 一覧表示だけ (削除なし)
cd deploy && ./cleanup.sh --yes       # 確認なしで削除 (端末がないときはこれが必要)
```

`cleanup.sh` は `az group delete -n rg-agw-advrouting-demo --yes --no-wait` を実行します。削除はバックグラウンドで数分かかります (`az group exists -n rg-agw-advrouting-demo` が `false` になれば完了)。ゲートウェイ (WAF_v2) とバックエンド VM は課金されます。ワークショップ後は必ず削除してください。

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
| サーバー選択 (Round Robin / Least Connections) | advanced-load-balancing: Server selection algorithm | ポート 8110 / 8120 / 8130 と `lb-check.sh`、シミュレーターの 8120 / 8130 プリセット |

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
- シミュレーターの「テスト要求」は、選んでいる要求のポートに件数分送ります。優先度 (8090) のプリセットを選んでから押すと、Primary / Standby の件数を数えられます。押すと「キャンセル」に変わり、送信を止められます。結果は「実機の応答」の欄に、50 件ずつ表示します。10 秒以内に応答がない要求は、失敗として数えます。


## 機能フラグ (ヘッダーでオン・オフを決める)

機能フラグ (Feature flag) は、専用のリスナー (ポート 8100) と、専用のマップ `flagMap` で処理します。クライアントがヘッダーでフラグをオンにします。ルール `flag-on` (優先度 10) は、ヘッダー `X-Feature` = `new` に一致した要求を `pool-flag-on` (VM 2 の 8080 番) に送ります。一致しない要求は、マップの既定 `pool-flag-off` (VM 1 の 8080 番) に送ります。`rule-flag` (ポート 8100) が `flagMap` を参照します。

| 要求 | 期待 |
|---|---|
| `:8100/` (ヘッダーなし) | pool-web (`pool-flag-off`、オフ、既定) |
| `:8100/` + `X-Feature: other` | pool-web (`pool-flag-off`、オフ、既定) |
| `:8100/` + `X-Feature: new` | pool-canary (`pool-flag-on`、オン) |
| `:80/` + `X-Feature: new` | pool-web (ポート 80 には機能フラグのルールがない) |

```bash
curl -s -D - -o /dev/null -H "X-Feature: new" http://<FRONTEND-IP>:8100/ | grep -i x-backend-pool
```

- シミュレーターの「機能フラグ (オフ / オン)」プリセットで、同じ予測を確認できます。
- クライアントが選ぶ方式で、ランダムには分けないため、A/B テストではありません。統計的な A/B テスト (ランダムに分け、同じ利用者を同じ側に固定する) は #27 で扱います。

## サーバー選択 (ポート 8110 / 8120 / 8130)

1 つのプールの中でゲートウェイがサーバーをどう選ぶか、1 台が詰まったとき (hot spot) に何が起きるかを見せます。各ポートは Basic のルールで、2 台入りのプールに送ります。`x-backend-pool` には応答したサーバーが出ます。

| ポート | ルール / プール | サーバー | 期待 (100 件、同時 6 件) |
|---|---|---|---|
| 8110 | `rule-rr` / `pool-rr` (Round Robin) | `pool-rr-a` (VM 1 の 8087 番)、`pool-rr-b` (VM 2 の 8087 番) | 約半分ずつ。所要時間は短い |
| 8120 | `rule-rr-slow` / `pool-rr-slow` (Round Robin) | `pool-slow` (VM 1 の 8086 番、3 秒待つ)、`pool-fast` (VM 2 の 8086 番) | `pool-slow` が 35〜65 件。所要時間は約 25 秒以上 |
| 8130 | `rule-lc` / `pool-lc` (Least Connections) | 8120 と同じ 2 台 | `pool-slow` が 10 件以下。所要時間は 8120 より明らかに短い |

```bash
cd deploy && FRONTEND=<IP>:8110 ./lb-check.sh /app/home 100 6
cd deploy && FRONTEND=<IP>:8120 ./lb-check.sh /app/home 100 6
cd deploy && FRONTEND=<IP>:8130 ./lb-check.sh /app/home 100 6
```

- Least Connections と Round Robin の差は、遅いサーバーに前の要求が残っている間にだけ出ます。`lb-check.sh` とシミュレーターのテスト要求は同時に 6 件を保って送ります。1 件ずつ送る `canary-check.sh` では差が出ません。
- ポートは 1 つずつ試してください。8120 と 8130 は同じ 2 台を使います。
- 3 秒の遅延はプローブのタイムアウト (20 秒) より短いため、`pool-slow` は正常のままです。応答しなくなったサーバーは、どちらのアルゴリズムでもヘルスプローブで外れます。Least Connections が役に立つのは、プローブには合格するが遅い、というときです。
- Cookie によるアフィニティが有効だと Least Connections は使われません。`hs-8086` と `hs-8087` では無効にしています。
- アルゴリズムはプールの `serverSelectionAlgorithm: 'LeastConnections'` (`pool-lc`) です。公開 API 仕様にも Bicep の型定義にもないプレビューの項目で、ポータルでプールを変更し、前後のゲートウェイを比べて見つけました。
- 新しいプロセスは最初の起動時に cloud-init で入ります。この変更より前にデプロイした環境は、`./cleanup.sh` の後に `./deploy.sh` で作り直してください。
- シミュレーターのプリセット: 「Round Robin (ポート 8110)」「Round Robin 遅いサーバーあり (ポート 8120)」「Least Connections (ポート 8130)」。

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
- `deploy/lb-check.sh`: 件数分を同時 6 件で送り、サーバーごとの件数と平均の時間、全体の所要時間を表示 (8110〜8130 のサーバー選択)
- `deploy/cleanup.sh`: リソースグループを削除 (`--dry-run` は一覧表示だけ、`--yes` は確認を省く)
- `backend/server.js`, `backend/pools.conf`, `backend/pools-canary.conf`: バックエンドとプール定義
- `agw-routing-simulator.html`: 予測と実機の比較、負荷分散シミュレーション
- `docs/agw-advanced-routing-demo-guide_ja.html` (日本語)、`docs/agw-advanced-routing-demo-guide.html` (英語): 参加者向けガイド
