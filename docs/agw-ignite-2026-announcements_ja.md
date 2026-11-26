# Microsoft Ignite 2026：Azure Application Gateway の発表まとめ

[English](agw-ignite-2026-announcements.md) | 日本語 ／ [Web 版](https://koudaiii.com/agw-advanced-routing-demo/agw-ignite-2026-announcements_ja.html) ／ 関連：[デモ環境の構築ガイド](https://koudaiii.com/agw-advanced-routing-demo/agw-advanced-routing-demo-guide_ja.html)

2026年11月26日時点 ／ 対象：Azure Updates で製品「Application Gateway」、タグ「Microsoft Ignite」に該当する 2026 年の 5 件（すべて 2026年11月17日公開のパブリック プレビューで、Update Types に Microsoft Ignite と Feature を含む）

## 結論：振り分け・認証・データ保護をゲートウェイが引き受ける 5 機能

Ignite 2026 の Application Gateway の発表は、これまでアプリや周辺インフラで作り込んでいた判断をゲートウェイに寄せるものです。対象は「スケール基盤」「トラフィック制御」「アイデンティティ」「データ保護」の 4 領域で、計 5 件あります。

ただし 5 件すべてパブリック プレビュー（SLA なし、本番利用は非推奨）です。「作成時にしか選べない」「ほかのプレビュー機能と併用できない」といった制約もあるため、制約を押さえたうえで PoC から始めるのが現実的です。

| # | 発表（Azure Update ID） | 領域 | 何が変わるか | 既存 GW への適用 |
|---|---|---|---|---|
| 1 | 次世代エラスティック アーキテクチャ＝Accelerated デプロイ層（580428） | スケール基盤 | プロビジョニング時間を最大 50%、オートスケール時間を最大 70% 短縮 | 不可（新規作成時に選択） |
| 2 | 高度なルーティング ルール（579324） | トラフィック制御 | Header / QueryString / ClientIP / Method / Path の条件で振り分け | 可（Basic ルールを Advanced に更新） |
| 3 | 高度な負荷分散（580423） | トラフィック制御 | プール間は重み・優先度、プール内は重み付き RR・最小接続 | 可 |
| 4 | 集中型ユーザー認証 + JWT 検証（580418） | アイデンティティ | OIDC サインインと JWT 検証を 1 つのポリシーで複数 GW に適用 | 可 |
| 5 | Confidential Compute（579649） | データ保護 | データプレーンを TEE で動かし、復号後のデータも保護 | 不可（新規作成時に有効化） |

## 全体像：5 機能はゲートウェイ内のどこに効くか

#2〜#4 はリクエスト処理の各段に、#1 と #5 はゲートウェイの実行基盤そのものに効きます。

```text
クライアント
  │ HTTPS
  ▼
Application Gateway（Standard_v2 / WAF_v2）
  ├─ ① リスナー ............ Advanced ルールは Basic リスナーのみ（マルチサイト非対応）
  ├─ ② WAF ポリシー ........ ルーティング前に評価（GW / リスナー単位）
  ├─ ③ ルーティング ルール .. 認証ポリシー（OIDC / JWT）をルール単位で関連付け【#4】
  ├─ ④ Advanced routing map  優先度順に条件セット（AND）を評価【#2】
  ├─ ⑤ プール選択 .......... 重み、または 優先度 + 最小正常割合【#3】
  └─ ⑥ サーバー選択 ........ ラウンドロビン / 重み付き RR / 最小接続【#3】
  ▼
バックエンド プール

実行基盤：Accelerated 層【#1】／ Confidential Compute（TEE）【#5】
※ プレビュー期間中、Accelerated 層では #2〜#5 を含むほかのプレビュー機能を併用できない
```

## 1. Accelerated デプロイ層：新規 GW のスケールを速くする

Application Gateway v2 の次世代アーキテクチャが、新しいデプロイ層「Accelerated（プレビュー）」として選べるようになりました。現行のデプロイ層と比べ、プロビジョニング時間を最大 50%、オートスケール時間を最大 70% 短縮します。1 分未満のスケールアウトと、より長い接続ドレインにも対応します。追加料金はなく、課金モデルは現行と同じです。

| デプロイ層 | 位置づけ | 向くケース |
|---|---|---|
| Standard | 現行の GA 基盤。パブリック フロントエンド IP が必須 | 一般的なワークロード、WAF が必要な場合 |
| Network isolated | 登録フラグなしでプライベート専用 GW を作成 | パブリック IP 禁止、送信の強制トンネリング、送信 Deny All |
| Accelerated（プレビュー） | パブリック / プライベートのみ / 併用を登録なしで構成 | 急なトラフィック変動、スケール速度・上限を重視 |

プレビュー中の制約：

- デプロイ層は作成後に変更できない。既存 GW のインプレース移行もない（新規作成して構成を移す）
- WAF 層、FIPS モード、TCP/TLS プロキシ、Private Link は非対応
- 現在プレビュー中のほかの機能（本書の #2〜#5 も該当）は併用できない
- ゲートウェイ サブネットに空き IP を 10 個以上確保する。NSG でクライアントの IP 範囲からリスナー ポートへの受信を許可する
- ゲートウェイ正常性ダッシュボード、証明書メタデータ取得 API、オンデマンドのバックエンド正常性、サブネット共有は利用できない
- 提供は 21 リージョン。日本は西日本のみで、東日本は対象外。ポータルではプレビュー用リンクから作成する

注：Learn の日本語版（2026年11月17日更新）は英語版（11月25日更新）より古く、リージョン一覧や制約の記述が一致しない。英語版を正として確認すること。

## 2. 高度なルーティング ルール：1 ルールで 5 種類の条件を組み合わせる

従来のパスベース中心のルーティングに、HTTP 要求の属性による条件分岐が加わりました。ルールは優先度の小さい順に評価され、最初に一致したルールの宛先（バックエンド プールまたはリダイレクト）へ送られます。どのルールにも一致しなければ既定のプールへ送られます。

```text
Advanced routing map（GW あたり最大 100）
  ├─ Advanced routing rule（マップあたり最大 100）... 優先度の小さい順に評価
  │    ├─ 条件セット ... 条件は最大 5 個。すべて一致で成立（AND）
  │    │    └─ 条件 ... 値は最大 5 個。いずれか一致で成立（OR）。値・正規表現は 128 文字まで
  │    └─ 宛先 ... バックエンド プール + HTTP 設定（+ 書き換えセット）、またはリダイレクト
  └─ 既定の宛先 ... どのルールにも一致しないときのプール + HTTP 設定（+ 書き換えセット）
条件セットは GW あたり最大 10,000
```

| 条件の種類 | 一致方法 | 注意点 |
|---|---|---|
| Header | 完全一致 / 正規表現 | 正規表現は RE2 互換のみ |
| QueryString | 完全一致 / 正規表現 | 空値を指定できるのは QueryString のみ |
| ClientIP | IPv4 / IPv6 | CIDR 表記で指定 |
| Method | 完全一致のみ | 大文字で指定（GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, PATCH） |
| Path | 完全一致 / 正規表現 | URL デコード後に評価（`/foo%2Fbar` は `/foo/bar` として比較） |

条件の例（Learn の記載形式）：

```json
{
  "conditionType": "Header",
  "propertyName": "X-Custom-Header",
  "propertyValueMatcher": { "pattern": "^(customer-[0-9]+|partner-[a-z]+)$" }
}
```

制約・注意：

- Basic リスナーのみ。マルチサイト リスナーと L4（TCP/TLS プロキシ）は非対応
- WAF はルーティング前に評価される。WAF ポリシーは GW / リスナー単位で、ルール単位の関連付けはできない
- 書き換えセットはルーティング決定後、バックエンド送信前に適用される
- ポータルの GW 作成ウィザードでは構成できない。作成後に既存の Basic ルールを Advanced に更新する
- Advanced ルールの優先度は、通常のルーティング ルールの優先度とは別物

情報の食い違い：Learn の概要ページに「パブリック プレビュー中は Header 条件のみ」という一文が残っています。一方、同じページの条件一覧、Azure Update、製品ブログはいずれも 5 種類を明記しています。公開したデモ環境でも Header（正規表現）と Path の AND 条件などで動作を確認できたため、5 種類に対応していると判断しました。利用前にポータル / API で確認することを推奨します。

使いどころ：A/B テスト・カナリア（ヘッダー）、API バージョニング（クエリ / ヘッダー）、マルチテナント（テナント ID ヘッダー）、読み書き分離（Method）、社内・パートナー経路（ClientIP）、モバイル分離（User-Agent）。

## 3. 高度な負荷分散：プール間とプール内の 2 段階で配分を決める

1 つのルールに複数のバックエンド プールを関連付け、まずプールを選び、次にプール内のサーバーを選びます。2 つの選択は独立しており、たとえば「プール間は重み付け、プール内は最小接続」と組み合わせられます。

```text
要求
  ▼
① プール選択（1 ルールまたは既定アクションにつきプール最大 5 個。方式はどちらか一方）
  ├─ 重み付け ... 0〜100 の整数で比率を指定（例：8:2 なら 80% / 20%）
  └─ 優先度 ..... 1〜5。最小正常割合（0〜100%）を満たす最上位のプールへ
  ▼
② サーバー選択（プールごとに設定）
  ├─ ラウンドロビン（既定）
  ├─ 重み付きラウンドロビン ... 0〜100。IP / FQDN で登録したサーバーのみ
  └─ 最小接続 ................. Cookie アフィニティ有効時は適用されない
```

優先度フェイルオーバーの例（最小正常割合 60%、プライマリ 5 台・スタンバイ 4 台）：

| 状況 | プライマリの正常率 | 選ばれるプール |
|---|---|---|
| プライマリが 1 台ダウン | 80%（5 台中 4 台） | プライマリ |
| プライマリが 3 台ダウン | 40%（5 台中 2 台） | スタンバイ（正常な 2 台が残っていても切り替わる） |

どのプールも基準を満たさないときは最上位のプールへ送られます。上位プールが基準に戻ると、新しい要求は即座に戻ります（戻りの遅延は設定できない）。

設計時のハマりどころ：

- 重み付けはプールの正常性を見ない。正常なサーバーがないプールが選ばれると要求は失敗する。プールを外すときは重みを 0 にし、正常性で切り替えたいときは優先度を使う
- Cookie アフィニティ有効時、重み付けではプール用 Cookie で既存セッションが固定される（重みの変更は新規セッションにのみ効く）。優先度ではプール用 Cookie を発行せず、切替時に次の要求から移動する
- スケールアウト直後の新インスタンスはプローブに合格するまで異常扱い。正常率が一時的に下がり、意図しない切替が起こりうる（4 台から 8 台に増やすと一時的に 50%）
- 重み付きラウンドロビンは、NIC 関連付けの VM / VMSS を含むプールでは使えない
- Basic SKU と L4（TCP/TLS プロキシ）は非対応。従来のパスベース ルールは 1 プールのまま。複数プールは Basic / Advanced ルール（と Advanced routing map の既定アクション）で構成する
- 専用バックエンド接続を有効にした HTTP 設定は、複数プールの構成に使えない
- API バージョン 2026-03-01 以降が必要

AI での使い方：PTU（予約容量）のエンドポイントを優先度 1、従量課金のエンドポイントを優先度 2 のプールに置くと、予約側の正常率が基準を下回ったときだけ従量課金側へ流せます。クライアント側の変更は不要です。

## 4. 集中型ユーザー認証 + JWT 検証：認証をアプリからゲートウェイへ移す

認証ポリシーを 1 つ作り、複数の GW のルーティング ルールに関連付けられるようになりました。ブラウザー向けには OIDC によるユーザー サインイン、API 向けには JWT 検証を使います。

| 観点 | ユーザー認証 | JWT 検証 |
|---|---|---|
| 主なクライアント | ブラウザー（対話型ユーザー） | API、サービス間、自動化 |
| 方式 | OIDC 認可コード フロー | Bearer トークンの検証（署名・発行者・対象者・有効期限） |
| IdP へのリダイレクト | あり | なし |
| GW のセッション Cookie | あり（既定名 ApplicationGatewayUserSession、既定 7 日） | なし（毎回トークンを検証） |
| 未認証時の動作 | 認証（推奨）/ 許可 / 拒否（401） | 拒否（401）/ 許可（ID ヘッダーなしで転送） |
| バックエンドへのヘッダー | `x-msft-entra-identity`（`<tid>:<sub>`）、取得できれば ID / アクセス トークン | `x-msft-entra-identity`（`tenantId:oid`） |

前提条件：

- Standard_v2 / WAF_v2。HTTPS リスナーが必須（HTTP リスナーは不可）
- 対象は Basic / Advanced ルール（パス条件付きの Advanced ルールを含む）。従来のパスベース ルールは対象外
- 1 つのルールに関連付けられる認証ポリシーは 1 つ。ポリシーはリージョン リソースで、GW と同じリージョンに作る
- ユーザー認証：IdP は Microsoft Entra ID。クライアント シークレットは Key Vault に置き、各 GW のマネージド ID に読み取り権限を付与する。スコープは最大 10 個（既定は openid, profile, email）
- JWT 検証：GW から Microsoft Entra のメタデータ エンドポイントへ TCP 443 で到達できること

旧 JWT 検証プレビューの扱い：

- 今回の JWT 検証は、既存の JWT 検証プレビューの改訂版。旧プレビューは GA に進まず、廃止予定（正式な廃止通知は別途公開）
- 旧ポリシーは新しい集中型 JWT 検証が GA になるまで動作する。自動移行はない
- 新規構成は集中型ポリシーで行い、旧プレビューの利用者は再構成を計画する

## 5. Confidential Compute：復号後のデータも TEE の中で守る

Application Gateway のデータプレーンをハードウェアの信頼された実行環境（TEE）で動かし、GW が復号して処理している間のデータまで保護します。TLS 終端、WAF、L7 ルーティング、L4 プロキシ、負荷分散、監視はそのまま使えます。

```text
クライアント ──TLS──▶ Application Gateway（Confidential Compute）
                        └─ TEE 内で TLS 終端 → WAF 検査 → ルーティング
                           （メモリをハードウェアで暗号化、ハイパーバイザー・ホストから分離）
                      ──TLS──▶ バックエンド（例：Confidential VM）
```

- Standard_v2 / WAF_v2 のアドオン。GW 作成時にのみ有効化できる（既存 GW には不可）
- ポータルでは作成時にチェック ボックスを選択。API では `"enableConfidentialCompute": true`（API バージョン 2026-05-01 以降）
- 料金は「SKU の固定料金 + 容量ユニット + Confidential Compute アドオンの時間課金」
- 提供は 17 リージョン。日本は東日本のみで、西日本は対象外
- アプリ コードの脆弱性や、侵害されたバックエンドからは守れない

| Key Vault の種類 | 秘密鍵の扱い | 保護の範囲 |
|---|---|---|
| Standard / Premium | GW が PFX を取得し、TEE 内で TLS 処理 | 秘密鍵とアプリ データを TEE で保護 |
| Managed HSM | 秘密鍵は HSM から出ず、暗号処理は HSM が担う | 鍵は HSM、アプリ データは TEE で保護 |

向くケース：金融取引、医療情報、個人データ、知的財産を扱うワークロード。Confidential VM などで構成した機密バックエンドの保護を、アプリ配信層まで広げたい場合。

## 組み合わせの制約：設計前に確認する 4 点

1. 作成時にしか選べない：Accelerated 層と Confidential Compute。既存 GW で使うには新規作成と構成移行が必要
2. Accelerated は単独で試す：プレビュー中は WAF 層も、#2〜#5 を含むほかのプレビュー機能も併用できない
3. パスベース ルールは Advanced ルールへ：複数プールの負荷分散と認証ポリシーは従来のパスベース ルールでは使えない。Path 条件付きの Advanced ルールに置き換えると両方使える
4. 日本リージョンが分かれる：Accelerated は西日本のみ、Confidential Compute は東日本のみ

| 機能 | 既存 GW に追加 | WAF_v2 と併用 | L4（TCP/TLS）プロキシ | 従来のパスベース ルール | 日本リージョン |
|---|---|---|---|---|---|
| #1 Accelerated | × | ×（WAF 層非対応） | × | ―（層の機能） | 西日本のみ |
| #2 高度なルーティング | ○ | ○（WAF は GW / リスナー単位） | × | 置き換え先 | 記載なし |
| #3 高度な負荷分散 | ○ | ○ | × | ×（1 プールのまま） | 記載なし |
| #4 ユーザー認証 / JWT | ○ | ○ | ―（HTTPS リスナーのみ） | × | 記載なし |
| #5 Confidential Compute | × | ○ | ○ | ―（基盤の機能） | 東日本のみ |

## 次の一手：シナリオ別に PoC を始める

| お客様の課題 | 試す機能 | 最初の一歩 |
|---|---|---|
| アクセス急増にスケールが追いつかない | #1 | 西日本で、WAF 不要のワークロードを新規 GW に載せてスケール時間を計測する |
| リリースを段階展開したい、AI の PTU を使い切りたい | #2 + #3 | 既存 GW の検証用 Basic ルールを Advanced に更新し、重み 90:10 と優先度での切替を試す |
| アプリごとの認証実装をやめたい | #4 | ブラウザー アプリはユーザー認証、API は JWT 検証のポリシーを作り、複数 GW に関連付ける |
| 処理中データの保護が要件（金融・医療など） | #5 | 東日本で Confidential Compute 付きの GW を新規作成し、Managed HSM の併用を検討する |
| 旧 JWT 検証プレビューを使っている | #4 | 新しい集中型ポリシーへの再構成を計画し、廃止通知を確認する |

いずれもプレビューのため、本番適用は GA と Learn の更新を確認してから判断してください。

## 参考：同時期の関連アップデート（Ignite タグなし）

- GA：WAF Insights for Azure Application Gateway（579280、2026年11月23日公開）
- パブリック プレビュー：Application Gateway for Containers の Private ingress（576393）、MCP gateway（576388）、JWT validation（576382）
- GA：Keyless TLS on Application Gateway with Azure Key Vault Managed HSM（577130）

## デモ環境での検証：Advanced routing と負荷分散を実機で確認した結果

- 公開先：構築ガイド https://koudaiii.com/agw-advanced-routing-demo/ 、シミュレーターと Bicep 一式 https://github.com/koudaiii/agw-advanced-routing-demo
- 構成：WAF_v2（容量 1）、Basic リスナー 7 つ（:80 / :8080 / :8090 / :8100 / :8110 / :8120 / :8130）、Advanced ルール 4 つと Basic ルール 3 つを Bicep でデプロイ
- Advanced routing の CLI コマンド（`advanced-routing-set` / `advanced-routing-map`）は Azure CLI 2.92.0 以降で使える。デモは Bicep でデプロイし、実機の確認に CLI を使う
- 重み 90:10 のカナリア（100 件で 91 / 9）、ヘッダーによる機能フラグ（`X-Feature: new`）、最小正常割合 60% の優先度フェイルオーバーが動作した。プライマリ停止から切替まで約 2〜3 分
- ヘッダーの値は大文字・小文字を区別した（`X-Feature: NEW` は既定のプールへ）
- サーバー選択：3 秒かかるサーバーを含む 2 台に 100 件（同時 6 件）送ると、Round Robin は約半分が遅いサーバーに届き、Least Connections は 10 件以下だった
- エンコード済みのパス（`/api%2Forders`）はデコード後に Path 条件で評価された
- 正規表現は RE2 互換のみ。先読みや後方参照は使えない

## 情報源

Azure Updates（いずれも 2026年11月17日公開）：

- 580428 Public Preview: Next-generation elastic architecture for Azure Application Gateway v2 — https://azure.microsoft.com/ja-jp/updates?id=580428
- 579324 Public Preview: Azure Application Gateway advanced routing rules — https://azure.microsoft.com/ja-jp/updates?id=579324
- 580423 Public Preview: Advanced load balancing in Azure Application Gateway — https://azure.microsoft.com/ja-jp/updates?id=580423
- 580418 Public Preview: Centralized user authentication + JWT validation for Azure Application Gateway — https://azure.microsoft.com/ja-jp/updates?id=580418
- 579649 Public Preview: Azure Application Gateway confidential compute support — https://azure.microsoft.com/ja-jp/updates?id=579649

Microsoft Learn：

- Application Gateway のデプロイ層（英語版） — https://learn.microsoft.com/en-us/azure/application-gateway/deployment-tier
- 高度なルーティング ルール — https://learn.microsoft.com/ja-jp/azure/application-gateway/advanced-rules
- チュートリアル：Advanced ルールでヘッダーベースのルーティングを構成 — https://learn.microsoft.com/ja-jp/azure/application-gateway/configure-advanced-routing-rule
- 高度な負荷分散 — https://learn.microsoft.com/ja-jp/azure/application-gateway/advanced-load-balancing
- ユーザー認証 — https://learn.microsoft.com/ja-jp/azure/application-gateway/user-authentication
- JWT 検証 — https://learn.microsoft.com/ja-jp/azure/application-gateway/json-web-token-overview
- Confidential Compute の概要 — https://learn.microsoft.com/ja-jp/azure/application-gateway/confidential-compute-overview

製品ブログ：

- Redefining application load balancing in Azure Application Gateway（2026年11月11日） — https://techcommunity.microsoft.com/blog/AzureNetworkingBlog/redefining-application-load-balancing-in-azure-application-gateway/4572687
