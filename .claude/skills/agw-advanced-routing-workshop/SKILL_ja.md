# Application Gateway Advanced Routing ワークショップ

これは `SKILL.md` (英語、スキル本体) の日本語版です。ユーザーが書いた言語で答えてください。

このリポジトリは [Advanced rules (プレビュー)](https://learn.microsoft.com/azure/application-gateway/advanced-rules) と [Advanced load balancing (プレビュー)](https://learn.microsoft.com/azure/application-gateway/advanced-load-balancing) を実機で示すデモです。ワークショップは次の順で進めます。

1. 前提の確認
2. デプロイ (Bicep、約 15〜20 分)
3. 疎通確認 (`test.sh`)
4. ライブデモ (ルール、WAF、リダイレクト)
5. カナリア、優先度ベース、機能フラグ、サーバー選択 (ポート 8080、8090、8100、8110〜8130)
6. 負荷分散シミュレーション (シミュレーターのみ)
7. 片付け

作業ディレクトリは **リポジトリのルート** です。Azure の操作は、実行前に必ずユーザーに確認してください (課金が発生し、数分かかります)。

## 1. 前提の確認

```bash
az account show --query "{sub:name, id:id, user:user.name}" -o table   # 対象のサブスクリプションか
az provider show -n Microsoft.Network --query registrationState -o tsv   # Registered であること
```

- デプロイは、`deploy.sh` から Bicep (`deploy/main.bicep`、ARM API `Microsoft.Network/applicationGateways@2026-03-01`) で行います。Bicep は `az bicep version` で確認します。ARM の検証は 2026-05-01 と 2026-07-01 でも通りますが、高度なルールの新しい機能は見つかりませんでした。
- Advanced routing の CLI コマンド (`az network application-gateway advanced-routing-set` / `advanced-routing-map`、Core、GA) は、Azure CLI 2.92.0 以降で使えます。デプロイしたマップ、ルール、条件セットの確認に使います (ガイドの 5.1)。
- SSH 鍵 (`~/.ssh/id_ed25519.pub`) がなければ、`deploy.sh` が生成します。
- パラメーターは不要です。
- 重み付けと優先度ベースのプール選択は、Advanced load balancing の機能です。高度なルールでは、機能の登録なしで動きます (2026-11-20 に実機で確認)。

## 2. デプロイ

```bash
cd deploy
./deploy.sh
```

成功すると、最後の行に `Done. Frontend: http://<IP>/` が出ます。`deploy.sh` は次のことを行います。

- `make-cloud-init.sh` で 2 つの初期化ファイルを生成します (どちらも `backend/server.js` を埋め込み): `cloud-init.yaml` (バックエンド VM 1) と `cloud-init-canary.yaml` (カナリア VM 2、`backend/pools-canary.conf` から)
- リソース グループ `rg-agw-advrouting-demo` を作ります
- `main.bicep` をデプロイします:
  - VNet (`appgw` 192.168.0.0/24、`backend` 192.168.1.0/24)、バックエンドの NSG、NAT Gateway (StandardV2、backend サブネットに関連付け)
  - バックエンド VM 1 (Ubuntu 24.04、固定 IP 192.168.1.10、Node.js プロセス 7 つ: ポート 8080–8083、8085、8086 (`pool-slow`、3 秒)、8087 (`pool-rr-a`))
  - カナリア VM 2 (固定 IP 192.168.1.11、`pool-canary` をポート 8080、`pool-fast` を 8086、`pool-rr-b` を 8087)
  - WAF ポリシー (Prevention、DRS 2.1、カスタム ルール `BlockDemoIp` と `BlockDemoUA`)
  - Application Gateway (WAF_v2) とリスナー 7 つ。4 つは高度なルールと専用のマップを持ち、3 つ (8110〜8130) はサーバー選択用の Basic のルールです:

| ポート | リスナー | ルール | マップ | 内容 |
|---|---|---|---|---|
| 80 | `listener-http` | `rule1` | `advancedRoutingMap1` | ルール 5 つ (partner 10、tenant 20、api-v2 30、campaign 40、mobile 60)。既定 `pool-web` |
| 8080 | `listener-canary` | `rule-canary` | `canaryMap` | ルール `canary-split` (全パス): `pool-web` 90 / `pool-canary` 10、`WeightedDistribution`。既定 `pool-canary` |
| 8090 | `listener-priority` | `rule-priority` | `priorityMap` | ルール `priority-split` (全パス): `pool-primary` (優先度 1)、次に `pool-standby` (優先度 2)、`PriorityAware`、最小正常割合 60%。既定 `pool-standby` |
| 8100 | `listener-flag` | `rule-flag` | `flagMap` | ルール `flag-on` (`X-Feature: new`) → `pool-flag-on`。既定 `pool-flag-off` |
| 8110 | `listener-rr` | `rule-rr` (Basic) | — | `pool-rr`: `pool-rr-a` / `pool-rr-b` (8087)、Round Robin |
| 8120 | `listener-rr-slow` | `rule-rr-slow` (Basic) | — | `pool-rr-slow`: `pool-slow` (3 秒) / `pool-fast` (8086)、Round Robin |
| 8130 | `listener-lc` | `rule-lc` (Basic) | — | `pool-lc`: 8120 と同じサーバー、`serverSelectionAlgorithm: 'LeastConnections'` |

バックエンドが正常になるまで数分かかることがあります。確認:

```bash
az network application-gateway show-backend-health -g rg-agw-advrouting-demo -n agwdemo-agw -o table
```

## 3. 疎通確認

```bash
cd deploy && FRONTEND=<deploy.sh が表示した IP> ./test.sh
```

**期待結果** (実機で確認済み。送信元 IP には依存しません):

| シナリオ | 期待 | 理由 |
|---|---|---|
| Default | 200 pool-web | 既定プール |
| Tenant | 200 pool-tenant | `X-Tenant-Id: customer-*` と `/app` |
| Partner | 200 pool-partner | `X-Partner-Id` が一致 (GET で送る) |
| API v2 | 200 pool-api-v2 | `X-Api-Version: 2.0` と `/api/orders` |
| Encoded path | 200 pool-api-v2 | `/api%2Forders` はデコードしてから照合 |
| Canary (:8080 90:10) | 200 pool-web または pool-canary | ポート 8080 全体を 90% / 10% で振り分け。1 件ではどちらか一方 |
| Campaign | 302 (`https://www.contoso.com/campaign?campaign=...`) | キャンペーンの条件 (優先度 40) が一致 |
| Feature flag off | 200 pool-web (`pool-flag-off`) | ポート 8100、`X-Feature: new` なし。`flagMap` の既定 |
| Feature flag on | 200 pool-canary (`pool-flag-on`) | ポート 8100 で `X-Feature: new` あり。ルール `flag-on` (優先度 10) |
| Mobile | 200 pool-mobile | iPhone の User-Agent |
| Round Robin (:8110) | 200 pool-rr-a または pool-rr-b | `pool-rr` の速い 2 台 |
| RR slow (:8120) | 200 pool-fast、または 3 秒後に pool-slow | 遅いサーバーと速いサーバーの Round Robin |
| Least conn (:8130) | 200 pool-fast、または 3 秒後に pool-slow | 1 件ではどちらにも届く。件数は `lb-check.sh` で見る |
| WAF block (UA) | 403 | `curl -A agw-block-demo`。ルーティングの前に WAF が遮断 (`BlockDemoUA`) |

`x-backend-pool` には、応答したプロセスの名前が出ます。ゲートウェイのプール `pool-primary` と `pool-flag-on` は VM 2 の `pool-canary` プロセスを、`pool-standby` と `pool-flag-off` は VM 1 の `pool-web` プロセスを指します。

## 4. ライブデモ

ブラウザーで `agw-routing-simulator.html` を開き、ゲートウェイ URL に `http://<FRONTEND>` を入れると、予測と実機の応答が並んで表示されます (`backend/server.js` は CORS 対応済み)。シミュレーターはブラウザーの言語に合わせて日本語か英語で表示し、ヘッダーの言語リンクで切り替えられます。

- 実機モードの予測は、プリセットの IP ではなく、ゲートウェイが見ている送信元 IP (`X-Forwarded-For`) を使います。
- ブラウザーは User-Agent ヘッダーを設定できません。「モバイル」と「WAF ブロック」は `curl -A` で見せます。

おすすめの順序:

1. **既定と一致するルール**: 「テナント」と「API v2」のプリセットを送り、実機の `x-backend-pool` が予測と一致することを見せます。
2. **優先度**: パートナーのルール (10) とテナントのルール (20) の両方に一致する要求を作り、数字の小さいほうが勝つことを見せます。
3. **パスの正規化**: 「エンコード済みパス」で、`/api%2Forders` がデコードされて一致することを見せます。
4. **リダイレクト**: 「キャンペーン」を送り、302 と Location ヘッダーを確認します (クエリ文字列は引き継がれます)。
5. **WAF はルーティングより前**: 次の節を参照。

### WAF ブロック

WAF は、ルーティングより前に要求を遮断します。テンプレートが作る User-Agent のルール `BlockDemoUA` (優先度 12) を使います。どのクライアントからでも再現でき、CLI での変更も要りません。

```bash
curl -i -A "agw-block-demo" http://<FRONTEND>/app/home   # → 403 (ルーティングの前に遮断)
curl -i http://<FRONTEND>/app/home                        # → 200 (比較用)
```

シミュレーターでは「WAF ブロック」プリセットで同じ結果を予測します。送信元 IP で遮断する `BlockDemoIp` (198.51.100.0/24) もテンプレートにありますが、送信元 IP は環境で変わるため、デモでは User-Agent のルールを使います。

## 5. カナリア、優先度ベース、機能フラグ、サーバー選択

### カナリア (ポート 8080)

```bash
cd deploy && FRONTEND=<IP>:8080 ./canary-check.sh /app/home 100   # → pool-web 約 90 件、pool-canary 約 10 件 (実機確認: 91 / 9)
cd deploy && FRONTEND=<IP>      ./canary-check.sh /app/home 100   # → ポート 80: 高度なルール、振り分けなし
```

重みは期待値です。件数が少ないと 90 / 10 からずれます。

```text
 VM1 (192.168.1.10)                      VM2 (192.168.1.11)
 +----------------------------+          +----------------------------+
 | :8080 pool-web (既存)      |          | :8080 pool-canary (新版)   |
 | :8081 pool-partner         |          +----------------------------+
 | :8082 pool-tenant          |
 | :8083 pool-api-v2          |
 | :8085 pool-mobile          |
 +----------------------------+

 8080 番: listener-canary -> rule-canary -> canaryMap -> canary-split
          -> WeightedDistribution (pool-web 90 / pool-canary 10)
```

- `pool-web` は VM 1 の 8080 番で動きます。`pool-canary` は同じポートで別の応答を返すため、**別の IP アドレス** が必要で、VM 2 (192.168.1.11) の 8080 番で動かします。
- 高度なルールでは、プールごとにバックエンド設定を持てます。どちらのプールも `hs-pool-web` (8080 番) を使います。VM 2 を別ポートにできるかは未検証です。

### 優先度ベース (ポート 8090)

`pool-primary` (VM 2、優先度 1) は、最小正常割合 60% を満たす間だけ使われます。満たさなければ `pool-standby` (VM 1、優先度 2) が使われます。各プールは 1 台なので、見せられるのはプール全体の切り替えだけです。

| 状態 | 期待 | 手順 |
|---|---|---|
| 正常 | 100 件すべて `pool-primary` (VM 2、プロセス `pool-canary`) | `FRONTEND=<IP>:8090 ./canary-check.sh /app/home 100` |
| `pool-canary` 停止 | 約 2〜3 分後、100 件すべて `pool-standby` (VM 1、プロセス `pool-web`) | 下のコマンドで停止し、2〜3 分待つ |
| 復旧 | 100 件すべて `pool-primary` に戻る | 下のコマンドで起動し、2〜3 分待つ |

```bash
# 停止 (VM 2 の pool-canary)
az vm run-command invoke -g rg-agw-advrouting-demo -n agwdemo-backend-canary --command-id RunShellScript --scripts "systemctl stop agw-pool@pool-canary"
# 復旧
az vm run-command invoke -g rg-agw-advrouting-demo -n agwdemo-backend-canary --command-id RunShellScript --scripts "systemctl start agw-pool@pool-canary"
```

- VM 2 の `pool-canary` を止めないと、すべての要求が Primary に送られ続け、切り替えは見えません。
- `agw-pool@pool-canary` (VM 2 の 8080 番) は、`pool-primary` (8090)、`pool-canary` (8080、重み 10)、`pool-flag-on` (8100) の唯一のサーバーです。停止中は、ポート 8080 の約 10% と、ポート 8100 の `X-Feature: new` の要求も失敗します。確認が終わったらすぐ復帰してください。重み付けはプールの正常性を見ないため、8080 番で `pool-canary` が選ばれた要求は失敗します。停止中は `test.sh` の 8080 番と 8100 番の結果が失敗し得るため、`test.sh` は復帰後に実行します。`pool-fast` と `pool-rr-b` (8086 / 8087 番) は別のプロセスなので影響しません。
- シミュレーターの「テスト要求」は、入力欄の要求 (メソッド、パス、クエリ、ヘッダー。「要求を送信」と同じ) を件数分送ります。Primary / Standby を数えるには、先に「優先度 (ポート 8090)」のプリセットを選びます。送信中はボタンが「キャンセル」に変わります。結果は「実機の応答」に 50 件ずつ表示します。10 秒以内に応答がない要求は、失敗として数えます。

### 機能フラグ (ポート 8100)

クライアントがヘッダーでフラグをオンにします。ルール `flag-on` (優先度 10) は、ヘッダー `X-Feature: new` の要求を `pool-flag-on` (VM 2 の 8080 番) に送ります。それ以外は、マップの既定 `pool-flag-off` (VM 1 の 8080 番) に送ります。

| 要求 | 期待 |
|---|---|
| `:8100/` (ヘッダーなし) | pool-web (`pool-flag-off`、オフ、既定) |
| `:8100/` + `X-Feature: other` | pool-web (`pool-flag-off`、オフ、既定) |
| `:8100/` + `X-Feature: new` | pool-canary (`pool-flag-on`、オン) |
| `:80/` + `X-Feature: new` | pool-web (ポート 80 には機能フラグのルールがない) |

```bash
curl -s -D - -o /dev/null -H "X-Feature: new" http://<FRONTEND-IP>:8100/ | grep -i x-backend-pool
```

- シミュレーターの「機能フラグ (オフ)」「機能フラグ (オン)」プリセットで、同じ結果を予測します。
- クライアントが選ぶ方式で、ランダムには分けないため、A/B テストではありません。統計的な A/B テスト (ランダムに分け、同じ利用者を同じ側に固定する) は issue #27 で扱います。

### サーバー選択 (ポート 8110 / 8120 / 8130)

1 つのプールの中でゲートウェイがサーバーをどう選ぶか、1 台が詰まったとき (hot spot) に何が起きるかを見せます。各ポートは Basic のルールで、2 台入りのプール 1 つに送ります。`x-backend-pool` には応答したサーバーが出ます。

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

- Least Connections と Round Robin の差は、遅いサーバーに前の要求が残っている間にだけ出ます。`lb-check.sh` とシミュレーターのテスト要求は、同時に 6 件を保って送ります。1 件ずつ送る `canary-check.sh` では差が出ません。
- ポートは 1 つずつ試してください。8120 と 8130 は同じ 2 台を使います。
- 3 秒の遅延はプローブのタイムアウト (20 秒) より短いため、`pool-slow` は正常のままです。応答しなくなったサーバーは、どちらのアルゴリズムでもヘルス プローブで外れます。Least Connections が役に立つのは、プローブには合格するが遅いサーバーがあるときです。
- Cookie によるアフィニティが有効だと、Least Connections は使われません。`hs-8086` と `hs-8087` では無効にしています。
- アルゴリズムは、プールの `serverSelectionAlgorithm: 'LeastConnections'` (`pool-lc`) です。公開 API 仕様にも Bicep の型定義にもないプレビューの項目で、ポータルでプールを変更し、前後のゲートウェイを比べて見つけました。
- 新しいプロセスは、最初の起動時に cloud-init で入ります。この変更より前にデプロイした環境は、`./cleanup.sh` の後に `./deploy.sh` で作り直してください。
- シミュレーターのプリセット: 「Round Robin (ポート 8110)」「Round Robin 遅いサーバーあり (ポート 8120)」「Least Connections (ポート 8130)」。

## 6. 負荷分散シミュレーション (シミュレーター)

```text
                  一致したルール
                        |
                        v
              プール選択アルゴリズム
              |                   |
              v                   v
   重み付け (Weighted)        優先度 (Priority)
   Pool A: 重み 8 (80%)       Priority 1 = プライマリ (条件を満たす間)
   Pool B: 重み 2 (20%)       Priority 2 = スタンバイ (満たさないとき)
   異常でも割合は変わらない    条件を満たすかは
                              最小正常割合で決まる
```

`agw-routing-simulator.html` の「負荷分散: プール選択 → サーバー選択」セクションは **シミュレーションのみ** で、実機は変わりません。実機で 2 台入りのプールがあるのは、ポート 8110〜8130 だけです。

- プリセット: ポート 8080 のカナリア 90:10 (実機と同じ)、重み 8:2、優先度 (5 台中 1 台異常 → プライマリ、5 台中 3 台異常 → スタンバイ)、WRR 6:3:1 (全台正常 / 重み 6 のサーバーが異常)
- 期待値 (ドキュメントと同じ): 90:10 → 90/10、8:2 → 80/20。WRR 6:3:1 は全台正常で 60/30/10、重み 6 が異常で 75/25。最小正常割合 60% の優先度では、5 台中 1 台異常ならプライマリのまま、5 台中 3 台異常ならスタンバイ。

ドキュメントの節: 「Pool selection algorithm」「Server selection algorithm」「How requests are distributed」(advanced-load-balancing)。

## 7. 片付け

```bash
cd deploy && ./cleanup.sh             # リソースを一覧表示し、グループ名の入力を求めてから、リソース グループを削除
cd deploy && ./cleanup.sh --dry-run   # 一覧表示だけ
cd deploy && ./cleanup.sh --yes       # 確認なしで削除 (端末がないときに必要)
```

`cleanup.sh` は `az group delete -n rg-agw-advrouting-demo --yes --no-wait` を実行するため、削除は数分かけてバックグラウンドで終わります (`az group exists -n rg-agw-advrouting-demo` が `false` を返せば完了)。ゲートウェイ (WAF_v2) と VM は稼働時間で課金されます。ワークショップの後は必ず削除してください。

## 既知の問題

- **本文のない POST が 403 になる**: `/api/orders` への本文のない POST は、DRS 2.1 のマネージド ルールに遮断されます。本文 (JSON) 付きの POST、GET、PUT は通ります。テストとシミュレーターは GET で送ります。ルール ID は未特定です。
- **ARM API の事実 (2026-11-20 に確認)**: 高度なルールは、単一プール (`backendAddressPool`) と複数プール (`backendAddressPoolsAndSettings` + `poolSelectionAlgorithm`) のどちらも指定できます。`loadDistributionPolicy` (Basic のルールの項目) だけを指定すると、ARM は `ApplicationGatewayAdvancedRoutingRuleMustReference` で拒否します。公開の REST API 仕様 (2026-03-01、2026-05-01) には複数プールの項目がないため、Bicep は BCP037 の警告を出しますが、デプロイは成功します。
- **ルーティング マップには 1 つ以上のルールが必要**: `advancedRoutingRules` が空だと `ApplicationGatewayAdvancedRoutingMapMustSpecifyAdvancedRoutingRules` で失敗します。そのため、`canaryMap` と `priorityMap` は全パス (`^/`) に一致するルールを使います。
- **`backend/server.js` やプール定義を変えると、VM の初期化データが変わる**: 既存の VM に対して `deploy.sh` が `PropertyChangeNotAllowed` (`osProfile.customData`) で失敗します。VM (またはリソース グループ) を削除してから、もう一度デプロイしてください。
- **ポータルでの変更は再デプロイで消える**: `deploy.sh` はゲートウェイをテンプレートの状態に戻します。

## 説明のポイント (ドキュメントとの対応)

| 話題 | ドキュメント | デモ |
|---|---|---|
| 階層 (ルーティング マップ → ルール → 条件セット → 条件) | advanced-rules: Architecture overview | `main.bicep` の `advancedRoutingMaps` / `advancedRoutingConditionSets` |
| 条件の種類 (Header、QueryString、ClientIP、Method、Path) | advanced-rules: Supported condition types | `test.sh` のシナリオ |
| ルールは優先度順に評価し、最初の一致で決まる | advanced-rules: Request flows | 優先度 10 (パートナー) と 20 (テナント) |
| WAF はルーティングより前 | advanced-rules | 「WAF ブロック」 |
| 正規表現 (RE2) とパスの正規化 | advanced-rules: Path, pattern matching | 「エンコード済みパス」 |
| 重み付け (カナリア 90:10) | advanced-load-balancing: Weighted distribution | ポート 8080、`canaryMap`、`canary-check.sh` |
| 優先度ベースと最小正常割合 | advanced-load-balancing: Priority-based selection | ポート 8090、`priorityMap`、VM 2 の `pool-canary` の停止と起動 |
| ヘッダーによる機能フラグ | advanced-rules: Use cases | ポート 8100、`flagMap` |
| サーバー選択 (RR、WRR、Least Connections) | advanced-load-balancing: Server selection | ポート 8110 / 8120 / 8130 と `lb-check.sh`、シミュレーターの「負荷分散」セクション (8120 / 8130 のプリセット) |

## 設計メモ: 外向き通信 (NAT Gateway)

- バックエンド VM には public IP を付けません。インターネットからの受信は、NSG の既定ルールで拒否します。
- 外向き通信 (apt など) は、backend サブネットに関連付けた NAT Gateway (StandardV2、専用の StandardV2 public IP) を通ります。
- backend サブネットは `defaultOutboundAccess: false` (プライベート サブネット) のため、既定の外向き IP は付きません。

## 関連ファイル

- `deploy/main.bicep`: インフラ全体 (テンプレート)
- `deploy/deploy.sh`: デプロイ
- `deploy/make-cloud-init.sh`、`deploy/cloud-init.yaml`、`deploy/cloud-init-canary.yaml`: VM の初期化 (VM 1 / カナリア VM 2)
- `deploy/test.sh`: シナリオの確認
- `deploy/canary-check.sh`: 指定した URI に 100 回連続で送り、プール別の件数を表示
- `deploy/lb-check.sh`: 件数分を同時 6 件で送り、サーバーごとの件数と平均の時間、全体の所要時間を表示 (8110〜8130 のサーバー選択)
- `deploy/cleanup.sh`: リソース グループを削除 (`--dry-run` は一覧表示だけ、`--yes` は確認を省く)
- `backend/server.js`、`backend/pools.conf`、`backend/pools-canary.conf`: バックエンドとプール定義
- `agw-routing-simulator.html`: 予測と実機の応答の比較、テスト要求、負荷分散シミュレーション (英語 / 日本語)
- `docs/agw-advanced-routing-demo-guide.html` (英語)、`docs/agw-advanced-routing-demo-guide_ja.html` (日本語): 参加者向けガイド
- `README.md` (英語)、`README_ja.md` (日本語)

## 参考文献

このスキルに書いた事実の根拠にした公式ページです。プレビューの動きが変わったように見えるときは、これらを確認してください。

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
