# ai-server-setup

ConoHa VPS 上に AI 常駐サーバー（Claude Code / herdr / rclone クラウド同期 / XFCE + xrdp デスクトップ）を 1 コマンドで構築するためのスクリプト集。

## 構成

| ファイル | 実行場所 | 役割 |
|---|---|---|
| `conoha-vps.sh` | 手元のPC | ConoHa VPS 3.0 API でインスタンスの作成 / 一覧 / 削除 |
| `startup-ai-server.sh` | VPS (初回起動時に自動実行) | スタートアップスクリプト版。ユーザー作成から環境構築まで無人で行う |
| `setup-ai-server.sh` | VPS (手動実行) | 構築済みVPSに一般ユーザーとしてログインして手動実行する版 |
| `.env.example` | 手元のPC | ConoHa API 認証情報の雛形。`.env` にコピーして使う（`.env` は git 管理外） |

構築される環境: XFCE + xrdp / Chromium / rclone + systemdタイマーによる双方向同期(bisync) / Claude Code / herdr / スワップ4GB / UFW(SSH・RDPのみ)

## クイックスタート

```bash
# 1. ConoHaコントロールパネル「API」画面で APIユーザーを作成し、.env に値を記入
#    (.env は git 管理外。conoha-vps.sh が自動で読み込む。export で環境変数にしても可)
cp .env.example .env
#    → CONOHA_USER_ID / CONOHA_PASSWORD / CONOHA_TENANT_ID / CONOHA_ROOT_PASS を埋める

# 2. startup-ai-server.sh の冒頭 USERNAME / PASSWORD を書き換える（必須）

# 3. 作成（12GBプラン・Ubuntu 24.04・環境構築まで自動）
./conoha-vps.sh create ./startup-ai-server.sh

# 4. 5〜10分後、表示されたIPへSSHまたはRDP(3389)で接続し、残作業:
#    rclone config          … クラウド認証（対話式）
#    ~/bin/first-sync.sh    … 初回同期＋定期タイマー有効化
#    claude                 … Claude Code ログイン
```

プラン変更は `conoha-vps.sh` 冒頭の `RAM_GB`（4 / 12 など）を編集。

```bash
./conoha-vps.sh list                # 一覧・IP確認
./conoha-vps.sh delete <サーバーID>  # 削除（ブートボリュームごと。課金停止に必須）
```

## 同期の仕組み

- 別PC → OneDrive / Google Drive にファイルを置く
- VPS側で `rclone bisync` が5分間隔で双方向同期（`~/sync/<リモート名>/`）
- `inbox/`（受信用）と `outbox/`（出力用）を分離し、Claude Code には outbox 側だけ書かせる運用を推奨
- 同期ログ: `~/.local/share/rclone-logs/`

## セキュリティ上の注意

- **認証情報をこのリポジトリにコミットしないこと**。API認証は `.env`（git 管理外。雛形は `.env.example`）か環境変数で渡し、パスワード類はプレースホルダのまま管理して実値は投入時に差し替える
- `startup-ai-server.sh` の初期パスワードのまま公開ネットワークに晒さない（RDPは3389が全開放のため、構築後すぐ `passwd` で変更）
- 必要に応じて `ai-server-rdp` セキュリティグループのソースIPを自社IPに絞る

## 動作要件

- 手元PC: bash / curl / jq
- VPS: Ubuntu 24.04（ConoHa VPS 3.0・東京リージョン c3j1）
