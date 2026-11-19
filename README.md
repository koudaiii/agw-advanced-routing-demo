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

| フォルダー | 内容 |
|---|---|
| `agw-routing-simulator.html` | 単体で動くシミュレーター。ゲートウェイ URL が空ならオフライン、入れると実機に送って予測と比較 |
| `backend/server.js` | 依存なしの Node.js バックエンド。どのプールが応答したか、受信したヘッダー (App Gateway が付けた X-Forwarded-* などを強調) を HTML / JSON で返します。応答ヘッダー `x-backend-pool` にもプール名が入ります。CORS 対応済み (`ALLOW_ORIGIN`、既定 `*`)。 |
| `backend/pools.conf` | VM1 (バックエンド) のプール名・ポート・表示名・色。5 プール (ポート 8080–8083、8085)。`pool-canary` (8084) の行は、VM1 の cloud-init を変えないために残している未使用の行です |
| `backend/pools-canary.conf` | カナリア VM2 のプール定義 (`pool-canary`、ポート 8080) |
| `deploy/deploy.sh` | リソースグループを作成し、`deploy/main.bicep` をデプロイ。SSH 鍵がなければ生成 |
| `deploy/main.bicep` | VNet、バックエンド VM、WAF ポリシー、App Gateway、6 プール、6 条件セット、Advanced routing map、`rule1` (Advanced) を作成 |
| `deploy/make-cloud-init.sh` / `cloud-init.yaml` | バックエンド VM の初期化データ (`backend/server.js` を埋め込み) |
| `deploy/test.sh` | シミュレーターのシナリオを curl で実機に送り、応答したプールを一覧表示 |

## 手順
```bash
az login
cd deploy
./deploy.sh
FRONTEND=<表示されたフロントエンド IP> ./test.sh
FRONTEND=<表示されたフロントエンド IP>:8080 ./canary-check.sh /app/home 100   # ポート 8080 に 100 回連続で送り、プール別の件数を表示
```
- カナリア展開: ポート 8080 のリスナーで、新バージョン (pool-canary) への振り分けを行います。`WEIGHTED_CANARY=false` (既定) では 8080 番の全件を pool-canary に送ります。`WEIGHTED_CANARY=true` では、ポート 8080 全体を pool-web 90% / pool-canary 10% に重み付けします。URI では絞りません。ポート 80 は高度なルール (A/B やヘッダーの振り分け) のままです。
- なぜカナリア用の VM (VM2) が必要か: 重み付け (`loadDistributionPolicy`) は 1 つの Basic ルールに付き、ルール内の全プールが同じバックエンド HTTP 設定 (同じポート) を使います。ARM の振り分けターゲットにはプールごとのポート指定がありません。pool-web は VM1 の 8080 番で動くため、同じポートで別の応答を返す pool-canary を置くには、別の IP アドレスが必要です。そこで新バージョン (pool-canary) を VM2 (10.20.1.11) の 8080 番で動かします。以前の 8084 番では、ポートが一致せず重み付けの対象にできませんでした。VM1 を作り直さずに済ませるなら、VM1 に 2 つ目の IP を付けて同じ方法で動かす代替案もあります (VM1 の初期化データの変更は既存 VM で拒否されるため、再作成が必要になります)。
- 重み付けは Advanced load balancing の機能です。`WEIGHTED_CANARY=true` にはサブスクリプションで `Microsoft.Network/AllowApplicationGatewayLoadDistributionPolicy` の登録が必要です。
  ```bash
  WEIGHTED_CANARY=true ./deploy.sh    # 重み付け 90:10 に切り替え
  WEIGHTED_CANARY=false ./deploy.sh   # 8080 番の全件を pool-canary に戻す
  ```
- デプロイは Bicep (`main.bicep`、ARM API `Microsoft.Network/applicationGateways@2026-03-01`) で行います。Azure CLI 2.87.0 には advanced-routing 用のコマンド (`az network application-gateway advanced-routing-map` など) がないため、CLI では作成できません。
- 完了まで 15〜20 分程度かかります (Application Gateway の作成と更新に時間がかかるため)。
ブラウザーで `http://<フロントエンド IP>/app/home` を開くと、応答したプールのページが表示されます。ヘッダーを付ける場合は curl か、ブラウザー拡張 (ModHeader など) を使います。

## 補足
- WAF ブロックの実演 (WAF はルーティングより前に評価されます): User-Agent に `agw-block-demo` を含む要求は、どのクライアントからでも 403 になります。ルールはテンプレートの `BlockDemoUA` (優先度 12) として最初から入っています。
  ```bash
  curl -i -A "agw-block-demo" http://<FRONTEND>/app/home   # → 403
  curl -i http://<FRONTEND>/app/home                        # → 200
  ```
  送信元 IP による遮断 (`BlockDemoIp`) も残しています。IP は環境で変わるため、デモでは User-Agent を使います。
- 既知の問題: `/api/orders` への POST が、どのパスでも WAF の 403 になります (GET / PUT は通ります)。Detection モードでは通るため、マネージドルール (DRS 2.1) が原因です。原因のルール ID は未特定です。
- ドキュメントには「パブリック プレビュー中は Header 条件のみサポート」とも書かれています。Path / QueryString / ClientIP / Method の条件作成でエラーになった場合は、該当ルールを Header 条件だけにしてください。
- 後片付け: `az group delete -n rg-agw-advrouting-demo --yes --no-wait`
