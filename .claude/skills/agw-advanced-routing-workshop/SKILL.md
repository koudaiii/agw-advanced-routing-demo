---
name: agw-advanced-routing-workshop
description: Run the Azure Application Gateway Advanced Routing workshop in this repo end to end — prerequisites, Bicep deploy, scenario verification with test.sh, live demos (header/path/IP/method/query/UA rules, WAF-before-routing, redirect, multi-pool distribution simulation), expected results, known issues, and cleanup. Use when the user asks to run, present, rehearse, or troubleshoot this Application Gateway advanced rules demo or workshop.
---

# Application Gateway Advanced Routing ワークショップ

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

- Azure CLI 2.87.0 には `az network application-gateway advanced-routing-*` が **ありません**。そのためデプロイは CLI ではなく Bicep (`deploy/main.bicep`、ARM API `Microsoft.Network/applicationGateways@2026-03-01`) で行います。`az bicep version` で Bicep が使えることを確認します。
- SSH 鍵 (`~/.ssh/id_ed25519.pub`) がなければ `deploy.sh` が自動生成します。
- 必要なパラメーターはありません。カナリアは送信元 IP や URI ではなく、ポート 8080 全体の重み付け (pool-web 90% / pool-canary 10%) で振り分けます。
- 重み付けは Advanced load balancing の機能です。サブスクリプションで `Microsoft.Network/AllowApplicationGatewayLoadDistributionPolicy` が登録されている必要があります (未登録だと deploy が `SubscriptionNotRegisteredForFeature` で失敗します)。

## 2. デプロイ

```bash
cd deploy
./deploy.sh
```

成功すると最後に `Done. Frontend: http://<IP>/` が出ます。以下は `deploy.sh` が行うことです。

- `make-cloud-init.sh` で 2 つの初期化ファイルを生成 (`backend/server.js` を埋め込み): `cloud-init.yaml` (バックエンド VM 1) と `cloud-init-canary.yaml` (カナリア VM 2、`backend/pools-canary.conf`)
- リソースグループ `rg-agw-advrouting-demo` を作成
- `main.bicep` をデプロイ: VNet (`appgw` 10.20.0.0/24 / `backend` 10.20.1.0/24)、バックエンド NSG、バックエンド VM 1 (Ubuntu 24.04、固定 IP 10.20.1.10、ポート 8080〜8085 の各プロセス)、カナリア VM 2 (固定 IP 10.20.1.11、ポート 8080 の `pool-canary`)、WAF_v2 ポリシー (Prevention、DRS 2.1、カスタムルール `BlockDemoIp` と `BlockDemoUA`)、Application Gateway、Advanced routing map (`advancedRoutingMap1`、条件セット 5 つ、ルール 5 つ)、`rule1` (Advanced、ポート 80)、ポート 8080 のリスナーと Basic ルール `rule-canary` (`loadDistributionPolicy` で pool-web 90 / pool-canary 10)

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
| 通常アクセス | 200 pool-web | 既定プール |
| テナント | 200 pool-tenant | `X-Tenant-Id: customer-*` と `/app` |
| パートナー | 200 pool-partner | `X-Partner-Id` 一致。**現状は POST が 403 になる (既知の問題を参照)** |
| API v2 | 200 pool-api-v2 | `X-Api-Version: 2.0` と `/api/orders` |
| エンコード済みパス | 200 pool-api-v2 | `/api%2Forders` はデコードされて一致 |
| カナリア (:8080 90:10) | 200 pool-web / pool-canary | ポート 8080 全体の重み付け。1 件では片方に決まる |
| キャンペーン | 302 (`https://www.contoso.com/campaign?campaign=...`) | キャンペーン条件 (優先度 40) はカナリア (優先度 50) より先に評価される |
| モバイル | 200 pool-mobile | iPhone UA。カナリアはポート 8080 のみのため影響しない |

**100 回連続の確認** (`deploy/canary-check.sh`、ポート 8080):

```bash
cd deploy && FRONTEND=<IP>:8080 ./canary-check.sh /app/home 100   # → pool-web 約 90 件、pool-canary 約 10 件
cd deploy && FRONTEND=<IP>      ./canary-check.sh /app/home 100   # → ポート 80 は高度なルール (重み付けなし)
```

> 注意: 重み付けは「期待値」で、件数は少しずれます (ドキュメントどおり、件数が少ないと期待値から外れます)。

## 4. ライブデモ

ブラウザーで `agw-routing-simulator.html` を開き、ゲートウェイ URL に `http://<FRONTEND>` を入力すると、予測と実機の応答を並べて比較できます (`backend/server.js` は CORS 対応済み)。

- 実機モードでは、予測の送信元 IP はプリセットの値ではなく、ゲートウェイが見ている実際の IP (`X-Forwarded-For`) を使います。
- カナリア (8080 番ポートの 90:10 重み付け) はシミュレーターの「負荷分散」セクションの「カナリア: ポート 8080 全体 90:10」プリセットで予測します。ポート 80 の高度なルールは送信元 IP に依存しません。

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

`agw-routing-simulator.html` の「負荷分散: プール選択 → サーバー選択」セクションは **シミュレーションのみ** です。実機には反映されません (実機の各プールはサーバー 1 台です)。

- プリセット: ポート 8080 全体のカナリア 90:10 (実機と同じ構成)、重み 8:2、優先度 (5 台中 1 台異常 → プライマリ、5 台中 3 台異常 → スタンバイ)、WRR 6:3:1 (全台正常 / 重み 6 が異常)
- 期待値 (ドキュメントと一致): 90:10 → 90/10、8:2 → 80/20。WRR 6:3:1 全台正常 → 60/30/10、重み 6 が異常 → 75/25。優先度 最小正常割合 60%: 5 台中 1 台異常はプライマリ、5 台中 3 台異常はスタンバイ。

ドキュメント対応: 「Pool selection algorithm」「Server selection algorithm」「How requests are distributed」(advanced-load-balancing)。

## 6. 片付け

```bash
az group delete -n rg-agw-advrouting-demo --yes --no-wait
```

ゲートウェイ (WAF_v2)、バックエンド VM、Log Analytics ワークスペース `agwdemo-law` は課金されます。ワークショップ後は必ず削除してください。

## 既知の問題

- **POST が 403 になる (未解決)**: `/api/orders` への POST は、ボディの有無、Content-Type、ヘッダーに関係なく、どのパスでも WAF が 403 を返します。GET と PUT は通ります。WAF を Detection に切り替えると 200 になるため、原因は DRS 2.1 のマネージドルールです。ルール ID は未特定です (WAF ログが約 1 時間たっても届かなかったため)。
  - 対応候補: ルール ID を特定してから [per-rule exclusion](https://learn.microsoft.com/troubleshoot/azure/application-gateway/troubleshoot-waf-blocking-legitimate-requests-403#resolution-a) を追加する。または、ワークショップではパートナーのシナリオを GET ベースで説明する。
  - 特定の手順: `az monitor diagnostic-settings show` で `ApplicationGatewayFirewallLog` が有効か確認 → POST を再送 → 15〜20 分待ってから `AGWFirewallLogs` を `ruleId_s`、`ruleGroup_s`、`requestUri_s` で検索。
- **README の旧 CLI 手順**: 「rule1 を Advanced に切り替えるコマンド」の記述は古く、現在は Bicep が作成します。
- **高度なルールは 1 プールのみ**: 現在の ARM API では、高度なルールに重み付けを指定できません (`ApplicationGatewayAdvancedRoutingRuleMustReference`)。そのためカナリアの重み付けは、ポート 8080 の Basic ルールで行っています。
- **VM 1 に残る未使用の `pool-canary` (8084)**: VM 1 の customData を変えると既存 VM の更新が拒否されるため、`backend/pools.conf` の 8084 行は残しています。ルーティングには使われません。
- **Log Analytics の列名**: `AGWFirewallLogs` の列は `action_s` ではなく、まずテーブルの実際の列を確認してから使ってください。

## 講義のポイント (ドキュメントとの対応)

| 話題 | ドキュメント | デモ |
|---|---|---|
| 階層 (ルーティングマップ → ルール → 条件セット → 条件) | advanced-rules: Architecture overview | `main.bicep` の `advancedRoutingMaps` / `advancedRoutingConditionSets` |
| 条件種別 (Header, QueryString, ClientIP, Method, Path) | advanced-rules: Supported condition types | test.sh の各シナリオ |
| 評価は優先度順、最初の一致で決定 | advanced-rules: Request flows | 優先度 10 (パートナー) と 20 (テナント) |
| WAF はルーティングより前 | advanced-rules: WAF integration | 「WAF はルーティングより前」の節 |
| 正規表現 (RE2) とパス正規化 | advanced-rules: Path, Pattern matching | 「エンコード済みパス」 |
| 負荷分散 (プール選択 / サーバー選択 / 最小正常割合) | advanced-load-balancing | 「負荷分散」セクション (シミュレーター) |
| 重み付けによるカナリア (ポート全体 90:10) | advanced-load-balancing: Weighted distribution (Basic ルール) | ポート 8080 の `rule-canary` と `canary-check.sh` |

## 設計メモ: なぜカナリア用の VM2 が必要か

- 重み付け (`loadDistributionPolicy`) は 1 つの Basic ルールに付き、ルール内の全プールが **同じバックエンド HTTP 設定 (同じポート)** を使います。ARM の振り分けターゲットには、プールごとのポート指定がありません。
- pool-web は VM1 の 8080 番で動いています。同じポートで別の応答を返す pool-canary を置くには、**別の IP アドレス** が必要です。そのため新バージョン (pool-canary) は VM2 (10.20.1.11) の 8080 番で動かします。
- 以前の構成 (VM1 の 8084 番) では、ポートが一致せず重み付けの対象にできませんでした。
- 代替案: VM1 に 2 つ目の IP を付け、同じ方法で動かせば VM が 1 台減ります。ただし VM1 の初期化データ (customData) の変更は既存 VM で拒否されるため、VM1 の再作成が必要になります。

## 現在の実装状態 (8080 番のカナリア)

- 切り替えは環境変数 `WEIGHTED_CANARY` (既定 `false`) で行います。`deploy.sh` がテンプレートのパラメーター `weightedCanary` に渡します。
- `false` (現在): ポート 8080 の全件を pool-canary (VM2) に送ります。重み付けの機能登録が不要です。
- `true`: ポート 8080 を pool-web 90% / pool-canary 10% に重み付けします。`AllowApplicationGatewayLoadDistributionPolicy` の登録が `Registered` になってから `WEIGHTED_CANARY=true ./deploy.sh` で有効にします。
- 登録が `Pending` のままの間は、`weightedCanary=false` で運用します。

## 関連ファイル

- `deploy/main.bicep`: インフラ全体 (テンプレート)
- `deploy/deploy.sh`: デプロイ手順
- `deploy/make-cloud-init.sh`, `deploy/cloud-init.yaml`, `deploy/cloud-init-canary.yaml`: バックエンド VM の初期化 (VM 1 / カナリア VM 2)
- `deploy/test.sh`: 疎通確認
- `deploy/canary-check.sh`: 指定した URI に 100 回連続で送り、プール別の件数を表示 (カナリアは `FRONTEND=<IP>:8080`)
- `backend/server.js`, `backend/pools.conf`, `backend/pools-canary.conf`: バックエンドとプール定義
- `agw-routing-simulator.html`: 予測と実機の比較、負荷分散シミュレーション
- `docs/agw-advanced-routing-demo-guide.html`: 参加者向けガイド
