# Application Gateway Advanced Routing — 実機デモ キット

https://learn.microsoft.com/en-us/azure/application-gateway/advanced-rules

| フォルダー | 内容 |
|---|---|
| `agw-routing-simulator.html` | 単体で動くシミュレーター。ゲートウェイ URL が空ならオフライン、入れると実機に送って予測と比較 |
| `backend/server.js` | 依存なしの Node.js バックエンド。どのプールが応答したか、受信したヘッダー (App Gateway が付けた X-Forwarded-* などを強調) を HTML / JSON で返します。応答ヘッダー `x-backend-pool` にもプール名が入ります。CORS 対応済み (`ALLOW_ORIGIN`、既定 `*`)。 |
| `backend/pools.conf` | プール名・ポート・表示名・色 (6 プール = 1 VM 上の 6 プロセス、ポート 8080–8085) |
| `deploy/deploy.sh` | VNet、バックエンド VM、WAF ポリシー、App Gateway、Advanced routing map / condition set / rule を作成 |
| `deploy/test.sh` | シミュレーターのシナリオを curl で実機に送り、応答したプールを一覧表示 |

## 手順
```bash
az login
cd deploy
DEMO_CLIENT_CIDR="$(curl -s https://api.ipify.org)/32" ./deploy.sh   # 社内 IP (カナリア) ルール用に自分の IP を渡す
FRONTEND=<表示されたフロントエンド IP> ./test.sh
```
ブラウザーで `http://<フロントエンド IP>/app/home` を開くと、応答したプールのページが表示されます。ヘッダーを付ける場合は curl か、ブラウザー拡張 (ModHeader など) を使います。

## 補足
- WAF ブロックの実演: `az network application-gateway waf-policy custom-rule match-condition add ... --values <自分の IP>/32` を追加すると 403 になります (WAF はルーティングより前に評価)。
- ドキュメントには「パブリック プレビュー中は Header 条件のみサポート」とも書かれています。Path / QueryString / ClientIP / Method の条件作成でエラーになった場合は、該当ルールを Header 条件だけにしてください。
- `rule1` を Advanced に切り替えるコマンドが失敗した場合は、ポータルの [ルール] > rule1 > [ルーティング] で種類を Advanced にしてマップを選びます。
- 後片付け: `az group delete -n rg-agw-advrouting-demo`
