#!/usr/bin/env bash
#===============================================================================
# setup-ai-server.sh
# Ubuntu 22.04/24.04 VPS を AI常駐サーバー化する一括セットアップスクリプト
#
# 導入されるもの:
#   - XFCEデスクトップ + xrdp (リモートデスクトップ接続)
#   - Chromium ブラウザ
#   - rclone (OneDrive / Google Drive 同期) + systemdタイマーによる定期bisync
#   - Claude Code (ネイティブインストーラー / Node.js不要)
#   - herdr (エージェント用ターミナルマルチプレクサ)
#   - スワップ4GB (未設定の場合のみ)
#   - UFW (SSH/RDPのみ許可)
#
# 使い方:
#   1) 一般ユーザー(sudo可)でログインして実行:  bash setup-ai-server.sh
#   2) 完了後、画面の指示に従って rclone config でクラウド認証 (対話式)
#   3) 初回のみ: ~/bin/first-sync.sh を実行 (bisyncの --resync 初期化)
#===============================================================================
set -euo pipefail

#--- 設定 (必要に応じて書き換え) ------------------------------------------------
REMOTES=("gdrive" "onedrive")   # rclone config で作るリモート名。使う分だけ残す
CLOUD_DIR="ClaudeSync"          # クラウド側の同期対象フォルダ名
SYNC_BASE="$HOME/sync"          # ローカル側の同期ベース (例: ~/sync/gdrive)
SYNC_INTERVAL="5min"            # bisync の実行間隔
SWAP_SIZE="4G"
#-------------------------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
  echo "rootではなく一般ユーザー(sudo可)で実行してください"; exit 1
fi

log() { echo -e "\n\033[1;36m==> $*\033[0m"; }

#--- 1. 基本パッケージ ----------------------------------------------------------
log "aptを更新し基本パッケージを導入"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl wget git unzip ca-certificates gnupg ufw dbus-x11

#--- 2. スワップ (OOM対策) ------------------------------------------------------
if ! swapon --show | grep -q '^'; then
  log "スワップ ${SWAP_SIZE} を作成"
  sudo fallocate -l "$SWAP_SIZE" /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
else
  log "スワップは設定済み — スキップ"
fi

#--- 3. XFCEデスクトップ + xrdp -------------------------------------------------
log "XFCEデスクトップとxrdpを導入 (数分かかります)"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  xfce4 xfce4-goodies xrdp

# xrdpセッションでXFCEを起動させる
echo "xfce4-session" > "$HOME/.xsession"
sudo adduser xrdp ssl-cert

# RDP接続時のpolkit認証ダイアログ (colordなど) を抑止
sudo tee /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla >/dev/null <<'EOF'
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF

sudo systemctl enable --now xrdp

#--- 4. ブラウザ ---------------------------------------------------------------
log "Chromiumを導入"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y chromium-browser \
  || sudo snap install chromium

#--- 5. ファイアウォール --------------------------------------------------------
log "UFWを設定 (SSH/RDPのみ許可)"
sudo ufw allow OpenSSH
sudo ufw allow 3389/tcp comment 'xrdp'
sudo ufw --force enable

#--- 6. rclone -----------------------------------------------------------------
log "rcloneを導入"
if ! command -v rclone >/dev/null; then
  curl -fsSL https://rclone.org/install.sh | sudo bash
else
  echo "rcloneは導入済み — スキップ"
fi

# 同期フォルダ構造 (受信用/出力用を分離)
for r in "${REMOTES[@]}"; do
  mkdir -p "$SYNC_BASE/$r/inbox" "$SYNC_BASE/$r/outbox"
done

#--- 7. bisync用 systemdユーザータイマー ----------------------------------------
log "rclone bisyncの定期実行を設定 (${SYNC_INTERVAL}間隔)"
mkdir -p "$HOME/.config/systemd/user" "$HOME/bin" "$HOME/.local/share/rclone-logs"

for r in "${REMOTES[@]}"; do
  cat > "$HOME/.config/systemd/user/rclone-bisync-$r.service" <<EOF
[Unit]
Description=rclone bisync ($r)

[Service]
Type=oneshot
ExecStart=/usr/bin/rclone bisync $r:$CLOUD_DIR $SYNC_BASE/$r \\
  --create-empty-src-dirs --resilient --recover \\
  --conflict-resolve newer \\
  --log-file %h/.local/share/rclone-logs/bisync-$r.log --log-level INFO
EOF
  cat > "$HOME/.config/systemd/user/rclone-bisync-$r.timer" <<EOF
[Unit]
Description=rclone bisync timer ($r)

[Timer]
OnBootSec=2min
OnUnitActiveSec=$SYNC_INTERVAL
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF
done

# 初回同期用ヘルパー (bisyncは初回に --resync が必須)
cat > "$HOME/bin/first-sync.sh" <<EOF
#!/usr/bin/env bash
# rclone config 完了後に一度だけ実行してください
set -e
for r in ${REMOTES[@]}; do
  if rclone listremotes | grep -q "^\$r:"; then
    echo "== \$r: 初回resyncを実行 =="
    rclone mkdir "\$r:$CLOUD_DIR" || true
    rclone bisync "\$r:$CLOUD_DIR" "$SYNC_BASE/\$r" --resync --create-empty-src-dirs -v
    systemctl --user enable --now "rclone-bisync-\$r.timer"
    echo "== \$r: 定期同期タイマーを有効化しました =="
  else
    echo "!! リモート '\$r' が未設定です。先に rclone config を実行してください"
  fi
done
EOF
chmod +x "$HOME/bin/first-sync.sh"

# ログアウト中もユーザーのsystemdタイマーを動かす
sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload

#--- 8. Claude Code (ネイティブインストーラー) ----------------------------------
log "Claude Codeを導入"
if ! command -v claude >/dev/null; then
  curl -fsSL https://claude.ai/install.sh | bash
else
  echo "Claude Codeは導入済み — スキップ"
fi

#--- 9. herdr ------------------------------------------------------------------
log "herdrを導入"
if ! command -v herdr >/dev/null; then
  curl -fsSL https://herdr.dev/install.sh | sh
else
  echo "herdrは導入済み — スキップ"
fi

# PATH (~/.local/bin) の確認
if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
  echo 'export PATH="$HOME/.local/bin:$HOME/bin:$PATH"' >> "$HOME/.bashrc"
fi

#--- 完了 -----------------------------------------------------------------------
cat <<EOF

===============================================================================
 セットアップ完了。残りの手動ステップ:
===============================================================================
 1) RDP接続の確認:
      Windowsの「リモートデスクトップ接続」等で <サーバーIP>:3389 に接続
      (ユーザー: $USER / このLinuxユーザーのパスワード)

 2) クラウドストレージの認証 (対話式):
      rclone config
      → リモート名は ${REMOTES[*]} で作成 (Google Drive / OneDrive を選択)
      → ブラウザ認証はRDPデスクトップ内のChromiumで行うのが簡単です

 3) 初回同期の実行 (認証後に一度だけ):
      ~/bin/first-sync.sh
      → 以後は ${SYNC_INTERVAL} 間隔で自動双方向同期されます
      → ローカル側: $SYNC_BASE/<リモート名>/  (inbox=受信用 / outbox=出力用)

 4) Claude Codeの認証:
      cd ~/sync && claude   (初回起動時にログイン)

 5) herdrの起動:
      herdr   (Ctrl+b q でデタッチ、再接続時は herdr で再アタッチ)

 同期ログ: ~/.local/share/rclone-logs/
 タイマー確認: systemctl --user list-timers
===============================================================================
EOF
