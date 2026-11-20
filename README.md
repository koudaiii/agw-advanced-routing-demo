# Application Gateway Advanced Routing — 実機デモ キット

https://learn.microsoft.com/en-us/azure/application-gateway/advanced-rules

## 概念図

図は Microsoft Learn の [Azure Application Gateway の高度なルーティングルール (プレビュー)](https://learn.microsoft.com/ja-jp/azure/application-gateway/advanced-rules) から引用しています。

**リクエストルーティングルールから、高度なルーティングマップ、ルール、条件セット、ルーティング条件までの階層**

![リクエストルーティングルールから高度なルーティングマップ、ルール、条件セット、ルーティング条件までの階層を示す図](https://learn.microsoft.com/azure/application-gateway/media/advanced-rules/advanced-routing-hierarchy.png)

**基本・パスベース・高度なルーティングルールそれぞれのリクエストフロー**

![基本、パスベース、高度なルーティングルールのためのアプリケーションゲートウェイのリクエストフローの図](https://learn.microsoft.com/azure/application-gateway/media/advanced-rules/rule-flows.png)

### 高度な負荷分散 (プレビュー)

図は Microsoft Learn の [Advanced load balancing on Azure Application Gateway (Preview)](https://learn.microsoft.com/en-us/azure/application-gateway/advanced-load-balancing) から引用しています。

**プール選択: 重み付け配分 (Weighted) と優先度ベース (Priority-based)**

![重み付けプール選択と、プライマリ/スタンバイのプールによる優先度ベース選択を比較する図](https://learn.microsoft.com/azure/application-gateway/media/advanced-load-distribution/pool-selection.png)

**サーバー選択: Round Robin、Weighted Round Robin、Least Connections**

![バックエンドプール内で Round Robin、Weighted Round Robin、Least Connections を比較する図](https://learn.microsoft.com/azure/application-gateway/media/advanced-load-distribution/server-selection.png)

**読み方**: 一致したルールのプールは、次の 2 つの方式のどちらかで選ばれます。
- **重み付け (Weighted)**: 重みの比率で振り分けます (例: 重み 8 と 2 なら 80% / 20%)。プールが異常でも、設定した割合は変わりません。
- **優先度 (Priority)**: 優先度 1 のプールが条件 (最小正常割合) を満たす間は、そこに送ります。満たさなければ、優先度 2 のスタンバイに切り替えます。


| フォルダー | 内容 |
|---|---|
| `agw-routing-simulator.html` | 単体で動くシミュレーター。ゲートウェイ URL が空ならオフライン、入れると実機に送って予測と比較 |
| `backend/server.js` | 依存なしの Node.js バックエンド。どのプールが応答したか、受信したヘッダー (App Gateway が付けた X-Forwarded-* などを強調) を HTML / JSON で返します。応答ヘッダー `x-backend-pool` にもプール名が入ります。CORS 対応済み (`ALLOW_ORIGIN`、既定 `*`)。 |
| `backend/pools.conf` | VM1 (バックエンド) のプール名・ポート・表示名・色。5 プール (ポート 8080–8083、8085) |
| `backend/pools-canary.conf` | カナリア VM2 のプール定義 (`pool-canary`、ポート 8080) |
| `deploy/deploy.sh` | リソースグループを作成し、`deploy/main.bicep` をデプロイ。SSH 鍵がなければ生成 |
| `deploy/main.bicep` | VNet、バックエンド VM 1 (5 プール)、カナリア VM 2 (`pool-canary`、8080)、WAF ポリシー、App Gateway、条件セット 6 つ、Advanced routing map (`advancedRoutingMap1` と `canaryMap`)、ルール `rule1` (ポート 80) と `rule-canary` (ポート 8080、`canaryMap` の 90:10) を作成 |
| `deploy/make-cloud-init.sh` / `cloud-init.yaml` | バックエンド VM 1 の初期化データ (`backend/server.js` を埋め込み) |
| `deploy/cloud-init-canary.yaml` | カナリア VM 2 の初期化データ (`backend/pools-canary.conf` から生成) |
| `deploy/canary-check.sh` | 指定した URI に 100 回連続で送り、x-backend-pool でプール別の件数と割合を表示。カナリアは `FRONTEND=<IP>:8080` |
| `deploy/test.sh` | シミュレーターのシナリオを curl で実機に送り、応答したプールを一覧表示 |

## 手順
```bash
az login
cd deploy
./deploy.sh
FRONTEND=<表示されたフロントエンド IP> ./test.sh
FRONTEND=<表示されたフロントエンド IP>:8080 ./canary-check.sh /app/home 100   # ポート 8080 に 100 回連続で送り、プール別の件数を表示
```
- カナリア展開: ポート 8080 のリスナーで、ルール `canary-split` が全リクエストを pool-web 90% / pool-canary 10% に振り分けます (高度なルールの重み付け)。URI では絞りません。ポート 80 は高度なルール (A/B やヘッダーの振り分け) のままです。
- カナリアの配置: pool-canary は VM2 (192.168.1.11) の 8080 番で動かします。pool-web は VM1 の 8080 番です。同じポートで別の応答を返すため、IP アドレスを分けています。VM2 を別ポートにできるかは未検証です (高度なルールでは、プールごとにバックエンド設定を持てます)。
- 優先度ベースのプール選択 (ポート 8090): ルール `rule-priority` (Advanced、優先度 300) がマップ `priorityMap` を参照します。マップの中では、全パスに一致するルール `priority-split` が、`pool-primary` (Primary、VM 2 の 8080 番、優先度 1) を使い、`pool-primary` の正常なサーバーが最小正常割合 60% に達しない場合は `pool-standby` (Standby、VM 1 の 8080 番、優先度 2) に切り替えます。既定の振り分け先は `pool-standby` です。各プールは 1 台のため、切り替えはプール全体の単位です。
  - 確認: `FRONTEND=<IP>:8090 ./canary-check.sh /app/home 100` で件数を見ます。
  - 停止と復旧 (手動): `az vm run-command invoke -g rg-agw-advrouting-demo -n agwdemo-backend-canary --command-id RunShellScript --scripts "systemctl stop agw-pool@pool-canary"` で VM 2 を止めると、切り替わるまで約 2〜3 分かかります。`systemctl start agw-pool@pool-canary` で戻すと、また `pool-primary` に送られます。
  - シミュレーターの「テスト要求」は、選んでいる要求のポートに件数分送り、どのプールに届いたかを数えます。Primary / Standby の名前で表示します。
- 重み付けは Advanced load balancing の機能です。8080 番のカナリアは、高度なルールで `WeightedDistribution` を使います。
- A/B テスト (ポート 80、#27): `/ab` に `X-Variant: B` を付けた要求は `pool-canary` (変種 B) に送ります。それ以外の `/ab` は既定の `pool-web` (変種 A) です。確認: `curl -H "X-Variant: B" http://<FRONTEND-IP>/ab`。
  ```text
  client --:8080--> listener-canary --> rule-canary (Advanced)
                                              |
                                              v   マップ canaryMap
                                    rule: canary-split  (パス ^/ = 全リクエスト)
                                              |   WeightedDistribution
                                +-------------+-------------+
                                |                           |
                          weight 90                   weight 10
                                |                           |
                                v                           v
                       pool-web (VM1 :8080)        pool-canary (VM2 :8080)
                       既存バージョン                新バージョン
  ```
- デプロイは Bicep (`main.bicep`、ARM API `Microsoft.Network/applicationGateways@2026-03-01`) で行います。Azure CLI 2.87.0 には advanced-routing 用のコマンド (`az network application-gateway advanced-routing-map` など) がないため、CLI では作成できません。
- ARM API の確認 (2026-11-20): 現在の template は 2026-03-01 / 2026-05-01 / 2026-07-01 のすべてで検証に成功します。高度なルールは、単一プール (`backendAddressPool`) と複数プール (`backendAddressPoolsAndSettings` + `poolSelectionAlgorithm`) のどちらも指定できます。`loadDistributionPolicy` だけを指定すると、ARM は `ApplicationGatewayAdvancedRoutingRuleMustReference` で拒否します。Bicep 0.49.2 は `loadDistributionPolicy` を BCP037 で指摘します。
- 完了まで 15〜20 分程度かかります (Application Gateway の作成と更新に時間がかかるため)。
ブラウザーで `http://<フロントエンド IP>/app/home` を開くと、応答したプールのページが表示されます。ヘッダーを付ける場合は curl か、ブラウザー拡張 (ModHeader など) を使います。

## 補足
- WAF ブロックの実演 (WAF はルーティングより前に評価されます): User-Agent に `agw-block-demo` を含む要求は、どのクライアントからでも 403 になります。ルールはテンプレートの `BlockDemoUA` (優先度 12) として最初から入っています。
  ```bash
  curl -i -A "agw-block-demo" http://<FRONTEND>/app/home   # → 403
  curl -i http://<FRONTEND>/app/home                        # → 200
  ```
  送信元 IP による遮断 (`BlockDemoIp`) も残しています。IP は環境で変わるため、デモでは User-Agent を使います。
- 既知の問題: 本文のない POST が、WAF (マネージドルール DRS 2.1) に遮断されて 403 になります。本文 (JSON) を付けた POST や GET / PUT は通ります。テストとシミュレーターのパートナー シナリオは、GET で送るようにしています。原因のルール ID は未特定です。
- ドキュメントには「パブリック プレビュー中は Header 条件のみサポート」とも書かれています。Path / QueryString / ClientIP / Method の条件作成でエラーになった場合は、該当ルールを Header 条件だけにしてください。
- 後片付け: `az group delete -n rg-agw-advrouting-demo --yes --no-wait`
