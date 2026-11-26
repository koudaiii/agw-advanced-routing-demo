# Application Gateway Advanced Routing — 実機デモ キット

[English](README.md) | 日本語

[Azure Application Gateway の高度なルーティング ルール (プレビュー)](https://learn.microsoft.com/ja-jp/azure/application-gateway/advanced-rules) と [高度な負荷分散 (プレビュー)](https://learn.microsoft.com/en-us/azure/application-gateway/advanced-load-balancing) のデモです。Bicep で実際のゲートウェイを作り、ブラウザーで動くシミュレーターで振り分けを予測して、実機の応答と比べます。

## 概念図

図は Microsoft Learn の [Azure Application Gateway の高度なルーティングルール (プレビュー)](https://learn.microsoft.com/ja-jp/azure/application-gateway/advanced-rules) から引用しています。

**階層: リクエスト ルーティング ルール → 高度なルーティング マップ → ルール → 条件セット → ルーティング条件**

![リクエストルーティングルールから高度なルーティングマップ、ルール、条件セット、ルーティング条件までの階層を示す図](https://learn.microsoft.com/azure/application-gateway/media/advanced-rules/advanced-routing-hierarchy.png)

**基本・パスベース・高度なルーティング ルールのリクエストの流れ**

![基本、パスベース、高度なルーティングルールのためのアプリケーションゲートウェイのリクエストフローの図](https://learn.microsoft.com/azure/application-gateway/media/advanced-rules/rule-flows.png)

### 高度な負荷分散 (プレビュー)

図は Microsoft Learn の [Advanced load balancing on Azure Application Gateway (Preview)](https://learn.microsoft.com/en-us/azure/application-gateway/advanced-load-balancing) から引用しています。

**プール選択: 重み付け配分と優先度ベース**

![重み付けプール選択と、プライマリ/スタンバイのプールによる優先度ベース選択を比較する図](https://learn.microsoft.com/azure/application-gateway/media/advanced-load-distribution/pool-selection.png)

**サーバー選択: Round Robin、Weighted Round Robin、Least Connections**

![バックエンドプール内で Round Robin、Weighted Round Robin、Least Connections を比較する図](https://learn.microsoft.com/azure/application-gateway/media/advanced-load-distribution/server-selection.png)

**読み方**: 一致したルールのプールは、次の 2 つの方式のどちらかで選ばれます。
- **重み付け (Weighted)**: 重みの比率で振り分けます (例: 重み 8 と 2 なら 80% / 20%)。プールが異常でも、設定した割合は変わりません。そのため、正常なサーバーがないプールに送られた要求は失敗します。
- **優先度 (Priority)**: 優先度 1 のプールが最小正常割合を満たす間は、そこに送ります。満たさなければ、優先度 2 のスタンバイに切り替えます。

## このリポジトリの内容

| パス | 内容 |
|---|---|
| `agw-routing-simulator.html` | 単体で動くシミュレーター。ゲートウェイ URL が空ならオフラインで動き、URL を入れると実機に要求を送って予測と比べます。ブラウザーの言語に合わせて日本語か英語で表示します |
| `tests/simulator.test.mjs` | シミュレーターのブラウザー テスト (「テスト」を参照) |
| `docs/agw-advanced-routing-demo-guide_ja.html` | 構築ガイド (日本語)。英語は `docs/agw-advanced-routing-demo-guide.html` |
| `backend/server.js` | 依存なしの Node.js バックエンド。どのプールが応答したかと、受信したリクエスト ヘッダー (Application Gateway が付けた `X-Forwarded-*` などを強調) を HTML か JSON で返します。プール名は応答ヘッダー `x-backend-pool` にも入ります。CORS 対応済み (`ALLOW_ORIGIN`、既定は `*`) |
| `backend/pools.conf` | VM 1 のプロセス名・ポート・表示名・色・遅延。9 プロセス (ポート 8080–8083、8085。サーバー選択用に、3 秒遅れる `pool-slow` 8086 と `pool-rr-a` 8087。優先度用の `pool-standby` 8088 と機能フラグ用の `pool-flag-off` 8089) |
| `backend/pools-canary.conf` | VM 2 のプロセス (`pool-canary` 8080。サーバー選択用に `pool-fast` 8086 と `pool-rr-b` 8087。優先度用の `pool-primary` 8088 と機能フラグ用の `pool-flag-on` 8089) |
| `deploy/deploy.sh` | リソース グループを作り、`deploy/main.bicep` をデプロイします。SSH 鍵がなければ生成します |
| `deploy/main.bicep` | VNet、バックエンド VM 1 (9 プロセス: ポート 8080–8083、8085–8089)、VM 2 (5 プロセス: `pool-canary` 8080、`pool-fast` 8086、`pool-rr-b` 8087、`pool-primary` 8088、`pool-flag-on` 8089)、NAT Gateway、WAF ポリシー、Application Gateway、7 つのリスナー。4 つは高度なルールと専用のマップを持ちます: `rule1` / `advancedRoutingMap1` (ポート 80)、`rule-canary` / `canaryMap` (ポート 8080)、`rule-priority` / `priorityMap` (ポート 8090)、`rule-flag` / `flagMap` (ポート 8100)。3 つはサーバー選択用の Basic のルールです: `rule-rr` (ポート 8110)、`rule-rr-slow` (ポート 8120)、`rule-lc` (ポート 8130) |
| `deploy/make-cloud-init.sh` / `cloud-init.yaml` | バックエンド VM 1 の初期化データ (`backend/server.js` を埋め込み)。NodeSource から Node.js 26 (現行の LTS) を入れる |
| `deploy/nodesource-repo.gpg.key` | NodeSource の apt リポジトリの署名鍵。両方の初期化データに埋め込む。指紋 `6F71 F525 2828 41EE DAF8 51B4 2F59 B5F9 9B1B E0B4` |
| `deploy/cloud-init-canary.yaml` | カナリア VM 2 の初期化データ (`backend/pools-canary.conf` から生成) |
| `deploy/canary-check.sh` | 指定した URI に 100 回連続で送り、`x-backend-pool` からプール別の件数と割合を表示します。カナリアは `FRONTEND=<IP>:8080` |
| `deploy/lb-check.sh` | 指定した URI に件数分 (既定は同時 6 件) 送り、サーバーごとの件数、割合、平均の時間と、全体の所要時間を表示します。サーバー選択は `FRONTEND=<IP>:8110`、`:8120`、`:8130` |
| `deploy/test.sh` | シミュレーターのシナリオを curl で実機に送り、応答したプールを一覧表示します |
| `.github/workflows/pages.yml` / `.github/pages/build.sh` | 構築ガイドだけを GitHub Pages で公開します。シミュレーターは任意の URL に多数の要求を送れるため公開せず、シミュレーターへのリンクはこのリポジトリ内のファイルを指します。トップ ページ (`index.html`) は英語ガイドのコピーで、日本語のブラウザーでは日本語ガイドを開きます。Settings → Pages → Source を「GitHub Actions」にする必要があります。「Deploy from a branch」にすると、シミュレーターを含むリポジトリ全体が公開されます |

## 手順

```bash
az login
cd deploy
./deploy.sh
FRONTEND=<deploy.sh が表示したフロントエンド IP> ./test.sh
FRONTEND=<フロントエンド IP>:8080 ./canary-check.sh /app/home 100   # ポート 8080 に 100 回送り、プール別に数える
```

デプロイには 15〜20 分ほどかかります (Application Gateway の作成と更新に時間がかかるため)。ブラウザーで `http://<フロントエンド IP>/app/home` を開くと、応答したプールのページが表示されます。ヘッダーを付ける場合は、curl かブラウザー拡張 (ModHeader など) を使います。

デプロイは Bicep (`main.bicep`、ARM API `Microsoft.Network/applicationGateways@2026-03-01`) で行います。Advanced routing の CLI コマンド (`az network application-gateway advanced-routing-set` / `advanced-routing-map`) は、Azure CLI 2.92.0 以降で使えます。デプロイしたルールの確認に使います (ガイドの 5.1 を参照)。

## リスナー

| ポート | ルール / マップ | 見せること |
|---|---|---|
| 80 | `rule1` / `advancedRoutingMap1` | 条件による振り分け: ヘッダー、パス、クエリ文字列、User-Agent のルール、リダイレクト、既定プール (`pool-web`) |
| 8080 | `rule-canary` / `canaryMap` | カナリア: 重み付け、`pool-web` 90% / `pool-canary` 10% |
| 8090 | `rule-priority` / `priorityMap` | 優先度ベース: まず `pool-primary`、Primary が異常なら `pool-standby` |
| 8100 | `rule-flag` / `flagMap` | 機能フラグ: `X-Feature: new` は `pool-flag-on`、それ以外は `pool-flag-off` |
| 8110 | `rule-rr` / `pool-rr` | サーバー選択: 速い 2 台の Round Robin |
| 8120 | `rule-rr-slow` / `pool-rr-slow` | サーバー選択: 遅いサーバーが 1 台ある Round Robin |
| 8130 | `rule-lc` / `pool-lc` | サーバー選択: 8120 と同じ遅いサーバーと速いサーバーの Least Connections |

### カナリア (ポート 8080)

ルール `canary-split` が、ポート 8080 のすべての要求を `pool-web` 90% / `pool-canary` 10% に振り分けます (高度なルールの重み付け)。URI では絞りません。

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

`pool-canary` は VM 2 (192.168.1.11) の 8080 番、`pool-web` は VM 1 の 8080 番で動きます。同じポートで別の応答を返すため、IP アドレスを分けています。VM 2 を別ポートにできるかは未検証です (高度なルールでは、プールごとにバックエンド設定を持てます)。

### 優先度ベース (ポート 8090)

ルール `rule-priority` (Advanced、優先度 300) がマップ `priorityMap` を使います。マップの中では、全パスに一致するルール `priority-split` が `pool-primary` (VM 2 の 8088 番、優先度 1) に送ります。`pool-primary` の正常なサーバーが最小正常割合 60% を下回ると、`pool-standby` (VM 1 の 8088 番、優先度 2) に切り替えます。既定の振り分け先は `pool-standby` です。各プールは 1 台なので、切り替えはプール全体の単位です。

- 確認: `FRONTEND=<IP>:8090 ./canary-check.sh /app/home 100`
- 停止と復旧 (手動): `az vm run-command invoke -g rg-agw-advrouting-demo -n agwdemo-backend-canary --command-id RunShellScript --scripts "systemctl stop agw-pool@pool-primary"` で VM 2 の `pool-primary` プロセスを止めます。切り替わるまで約 2〜3 分かかります。`systemctl start agw-pool@pool-primary` で戻すと、また `pool-primary` に送られます。このプロセスは 8090 番だけに使われているため、ほかのポートには影響しません。
- シミュレーターの「テスト要求」は、入力欄の要求 (メソッド、パス、クエリ、ヘッダー。「要求を送信」と同じ) を件数分送り、どのプールに届いたかを Primary / Standby の名前で数えます。結果は「実機の応答」に表示します。10 秒以内に応答がない要求は、失敗として数えます。

### 機能フラグ (ポート 8100)

クライアントがヘッダーでフラグをオンにします。`X-Feature: new` を付けた要求は `pool-flag-on` (VM 2 の 8089 番) に、それ以外は既定の `pool-flag-off` (VM 1 の 8089 番) に送ります。確認: `curl -H "X-Feature: new" http://<FRONTEND-IP>:8100/`。ヘッダーの値は大文字と小文字を区別します。`X-Feature: NEW` は `pool-flag-off` に送られます (2026-11-26 に実機で確認)。

クライアントが選ぶ方式で、ランダムには分けないため、A/B テストではありません。統計的な A/B テストは issue #27 で扱います。

### サーバー選択 (ポート 8110 / 8120 / 8130)

この 3 つのポートでは、1 つのプールの中でゲートウェイがサーバーをどう選ぶか、1 台が詰まったとき (hot spot) に何が起きるかを見せます。各ポートは Basic のルールで、2 台入りのプール 1 つに送ります。

| ポート | ルール / プール | サーバー (`x-backend-pool`) | 見せること |
|---|---|---|---|
| 8110 | `rule-rr` / `pool-rr` | `pool-rr-a` (VM 1 の 8087 番)、`pool-rr-b` (VM 2 の 8087 番)。どちらも速い | Round Robin: 交互に届く |
| 8120 | `rule-rr-slow` / `pool-rr-slow` | `pool-slow` (VM 1 の 8086 番、3 秒待つ)、`pool-fast` (VM 2 の 8086 番) | 遅いサーバーがある Round Robin: 約半分の要求が 3 秒待つ |
| 8130 | `rule-lc` / `pool-lc` | 8120 と同じ 2 台 | Least Connections: 新しい要求は遅いサーバーを避ける |

```bash
FRONTEND=<IP>:8110 ./lb-check.sh /app/home 100 6   # 約半分ずつ。所要時間は短い
FRONTEND=<IP>:8120 ./lb-check.sh /app/home 100 6   # pool-slow が約半分。所要時間は約 25 秒以上
FRONTEND=<IP>:8130 ./lb-check.sh /app/home 100 6   # pool-slow は 10 件以下。所要時間は 8120 より明らかに短い
```

- `lb-check.sh` は同時に 6 件を保って送り、サーバーごとの件数、割合、平均の時間と、全体の所要時間を表示します。Least Connections と Round Robin の差は、遅いサーバーに前の要求が残っている間にだけ出るため、要求を重ねて送る必要があります。1 件ずつ送る `canary-check.sh` では差が出ません。
- シミュレーターの「テスト要求」も同じ送り方 (同時 6 件) で、全体の所要時間とサーバーごとの平均を表示します。プリセットは「Round Robin (ポート 8110)」「Round Robin 遅いサーバーあり (ポート 8120)」「Least Connections (ポート 8130)」です。
- ポートは 1 つずつ試してください。8120 と 8130 は同じ 2 台を使うため、一方の要求が、もう一方から見える接続数を変えます。
- `pool-slow` は `/healthz` 以外のすべての要求で 3 秒待ちます。プローブのタイムアウト (20 秒) より短いため、遅いサーバーも正常のままです。応答しなくなったサーバーは、どちらのアルゴリズムでもヘルス プローブで外れます。Least Connections が役に立つのは、プローブには合格するが遅いサーバーがあるときです。
- Cookie によるアフィニティが有効だと、Least Connections は使われません。バックエンド設定 `hs-8086` と `hs-8087` では無効にしています。
- アルゴリズムはプールに設定します: `pool-lc` の `serverSelectionAlgorithm: 'LeastConnections'`。このプレビューの項目は、公開 API 仕様にも Bicep の型定義にもありません。ポータルでプールを変更し、前後のゲートウェイを比べて見つけました (`docs/superpowers/specs/2026-11-25-server-selection-demo-design.md`)。
- プロセスは最初の起動時 (cloud-init) に入ります。この変更より前にデプロイした環境は、`./cleanup.sh` の後に `./deploy.sh` で作り直してください。

`pool-primary` / `pool-standby` (8088 番) と `pool-flag-on` / `pool-flag-off` (8089 番) には、同じ名前の専用プロセスがあります。そのため `x-backend-pool` ヘッダーにはゲートウェイのプール名が出ます。どれかを止めても、ほかのポートには影響しません。

## テスト

```bash
node --test backend/server.test.js tests/simulator.test.mjs
```

- `backend/server.test.js`: バックエンドの遅延、正常性の確認、CORS の事前確認。
- `tests/simulator.test.mjs`: headless Chrome でシミュレーターを動かします。「要求を送信」や「テスト要求を送る」を押したときに、予測が入力欄 (ヘッダー、メソッド、パス、クエリ、クライアント IP) に従うこと、テスト要求が入力欄の要求を送ること (ローカルの代役ゲートウェイで確認)、ポート 8080、8090、8110〜8130 では要求で振り分けないと表示すること、ルールの編集で 100 件の上限をマップごとに数え、`(?i)` などの RE2 のフラグを受け付けること (先読みは受け付けない)、経路図のリスナーが要求のポートに従うこと (WAF に遮断された場合も)、保存した設定がそのまま読み込まれることを確かめます。Chrome が見つからないときはスキップします。場所は `CHROME_PATH` で指定できます。
- GitHub Actions (`.github/workflows/test.yml`) が、pull request ごとと `main` への push ごとに同じコマンドを実行します。

## 補足

- WAF はルーティングより前に評価されます。User-Agent に `agw-block-demo` を含む要求は、どのクライアントからでも 403 になります。ルールはテンプレートの `BlockDemoUA` (優先度 12) です。
  ```bash
  curl -i -A "agw-block-demo" http://<FRONTEND>/app/home   # → 403
  curl -i http://<FRONTEND>/app/home                        # → 200
  ```
  送信元 IP による遮断 (`BlockDemoIp`) もあります。送信元 IP は環境で変わるため、デモでは User-Agent のルールを使います。
- 既知の問題: 本文のない POST は、WAF (マネージド ルール DRS 2.1) に遮断されて 403 になります。本文 (JSON) を付けた POST、GET、PUT は通ります。テストとシミュレーターのパートナーのシナリオは GET で送ります。遮断しているルール ID は未特定です。
- ARM API の確認 (2026-11-20): テンプレートは API バージョン 2026-03-01、2026-05-01、2026-07-01 のどれでも検証に成功します。高度なルールは、単一プール (`backendAddressPool`) と複数プール (`backendAddressPoolsAndSettings` + `poolSelectionAlgorithm`) のどちらも指定できます。`loadDistributionPolicy` だけを指定すると、ARM は `ApplicationGatewayAdvancedRoutingRuleMustReference` で拒否します。Bicep 0.49.2 は `loadDistributionPolicy` を BCP037 で指摘します。
- Microsoft Learn には「パブリック プレビュー中は Header 条件のみサポート」とも書かれています。Path、QueryString、ClientIP、Method の条件の作成に失敗した場合は、そのルールを Header 条件だけにしてください。
- 後片付け: `deploy/cleanup.sh` でリソース グループを削除します (先にグループ名の入力を求めます)。`deploy/cleanup.sh --dry-run` は一覧表示だけ行い、`--yes` は確認を省きます。

## 参考文献

このリポジトリの根拠にした Microsoft Learn の公式ページです。内容が違うときは、ページが正しいものとします (プレビューの機能は変わることがあります)。

- [Azure Application Gateway の高度なルーティング規則 (プレビュー)](https://learn.microsoft.com/azure/application-gateway/advanced-rules): 階層 (マップ、ルール、条件セット、条件)、条件の種類、上限、RE2 の正規表現
- [Azure Application Gateway における高度な負荷分散 (プレビュー)](https://learn.microsoft.com/azure/application-gateway/advanced-load-balancing): 重み付けと優先度ベースのプール選択、Round Robin / Weighted Round Robin / Least Connections、制約 (最大 5 プール、v2 SKU、Basic・Advanced ルールとマップの既定アクション)、重み付けはプールの正常性を見ないこと
- [Azure Application Gateway バックエンド設定の構成](https://learn.microsoft.com/azure/application-gateway/configuration-http-settings): Cookie によるアフィニティ (有効だと Least Connections は使われない) と Dedicated Backend Connection
- [Microsoft.Network/applicationGateways (Bicep / ARM テンプレートのリファレンス)](https://learn.microsoft.com/azure/templates/microsoft.network/applicationgateways): `deploy/main.bicep` で使うプロパティ (`cookieBasedAffinity`、`dedicatedBackendConnection` など)
- [チュートリアル: Azure portal でヘッダーベースのルーティングを構成する](https://learn.microsoft.com/azure/application-gateway/configure-advanced-routing-rule): ポータルで高度なルールを手動で作る手順
- [az network application-gateway advanced-routing-map](https://learn.microsoft.com/cli/azure/network/application-gateway/advanced-routing-map?view=azure-cli-latest): 高度なルーティング マップの一覧と管理
- [az network application-gateway advanced-routing-map rule](https://learn.microsoft.com/cli/azure/network/application-gateway/advanced-routing-map/rule?view=azure-cli-latest): マップのルールの一覧と管理
- [az network application-gateway advanced-routing-set](https://learn.microsoft.com/cli/azure/network/application-gateway/advanced-routing-set?view=azure-cli-latest): 条件セットの表示と管理
- [Azure CLI リリース ノート (2026 年 11 月 3 日、バージョン 2.92.0)](https://learn.microsoft.com/cli/azure/release-notes-azure-cli?view=azure-cli-latest#november-03,-2026): Advanced routing のコマンドが Azure CLI 2.92.0 で追加されたこと
- [Azure Application Gateway のバックエンドの正常性に関する問題のトラブルシューティング](https://learn.microsoft.com/troubleshoot/azure/application-gateway/application-gateway-backend-health-troubleshooting#backend-health-status-unhealthy): 502 の応答と異常なバックエンド
