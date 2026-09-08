#!/usr/bin/env bash
#===============================================================================
# startup-ai-server.sh  (ConoHaスタートアップスクリプト用 / root・無人実行版)
#
# ConoHaのVPS作成画面「スタートアップスクリプト」に貼り付けて使用。
# root権限で初回起動時に自動実行され、以下を構築します:
#   - 作業用一般ユーザー (sudo可 / RDPログイン用)
#   - XFCE + xrdp / Chromium / rclone + bisyncタイマー / Claude Code / herdr
#   - スワップ4GB / UFW (SSH・RDPのみ)
#
# ★実行前に必ず USERNAME / PASSWORD を書き換えること★
#
# 完了後にやること (SSHまたはRDPでログインして):
#   1) rclone config          … クラウド認証 (対話式)
#   2) ~/bin/first-sync.sh    … 初回同期 + 定期タイマー有効化
#   3) claude                 … Claude Codeログイン
# 実行ログ: /var/log/startup-ai-server.log (と /var/log/cloud-init-output.log)
#===============================================================================
set -euo pipefail
exec > >(tee -a /var/log/startup-ai-server.log) 2>&1

#--- 設定 (必ず変更) -----------------------------------------------------------
USERNAME="tomohide"
PASSWORD="ChangeMe-Now-123!"   # RDP/sudo用。構築後すぐ passwd で変更推奨
REMOTES=("gdrive" "onedrive")  # rclone config で作るリモート名。使う分だけ残す
CLOUD_DIR="ClaudeSync"
SYNC_INTERVAL="5min"
SWAP_SIZE="4G"
#-------------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then echo "root専用です (スタートアップスクリプトとして実行)"; exit 1; fi

HOME_DIR="/home/$USERNAME"
SYNC_BASE="$HOME_DIR/sync"

log() { echo -e "\n==> $*"; }
as_user() { sudo -u "$USERNAME" env HOME="$HOME_DIR" bash -c "$1"; }

#--- 1. ユーザー作成 ------------------------------------------------------------
log "ユーザー $USERNAME を作成"
if ! id "$USERNAME" &>/dev/null; then
  useradd -m -s /bin/bash "$USERNAME"
  echo "$USERNAME:$PASSWORD" | chpasswd
  usermod -aG sudo "$USERNAME"
fi

#--- 2. 基本パッケージ ----------------------------------------------------------
log "aptを更新し基本パッケージを導入"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget git unzip ca-certificates gnupg ufw dbus-x11 sudo

#--- 3. スワップ ---------------------------------------------------------------
if ! swapon --show | grep -q '^'; then
  log "スワップ ${SWAP_SIZE} を作成"
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

#--- 4. XFCE + xrdp ------------------------------------------------------------
log "XFCEデスクトップとxrdpを導入"
apt-get install -y xfce4 xfce4-goodies xrdp
echo "xfce4-session" > "$HOME_DIR/.xsession"
chown "$USERNAME:$USERNAME" "$HOME_DIR/.xsession"
adduser xrdp ssl-cert

cat > /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla <<'EOF'
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
systemctl enable --now xrdp

#--- 5. ブラウザ ---------------------------------------------------------------
log "Chromiumを導入"
apt-get install -y chromium-browser || snap install chromium

#--- 6. ファイアウォール --------------------------------------------------------
log "UFWを設定 (SSH/RDPのみ許可)"
ufw allow OpenSSH
ufw allow 3389/tcp comment 'xrdp'
ufw --force enable

#--- 7. rclone -----------------------------------------------------------------
log "rcloneを導入"
command -v rclone >/dev/null || curl -fsSL https://rclone.org/install.sh | bash

as_user "mkdir -p '$SYNC_BASE' '$HOME_DIR/bin' '$HOME_DIR/.config/systemd/user' '$HOME_DIR/.local/share/rclone-logs'"
for r in "${REMOTES[@]}"; do
  as_user "mkdir -p '$SYNC_BASE/$r/inbox' '$SYNC_BASE/$r/outbox'"
done

#--- 8. bisync用 systemdユーザータイマー ----------------------------------------
log "rclone bisyncの定期実行を設定 (${SYNC_INTERVAL}間隔)"
for r in "${REMOTES[@]}"; do
  cat > "$HOME_DIR/.config/systemd/user/rclone-bisync-$r.service" <<EOF
[Unit]
Description=rclone bisync ($r)

[Service]
Type=oneshot
ExecStart=/usr/bin/rclone bisync $r:$CLOUD_DIR $SYNC_BASE/$r \\
  --create-empty-src-dirs --resilient --recover \\
  --conflict-resolve newer \\
  --log-file %h/.local/share/rclone-logs/bisync-$r.log --log-level INFO
EOF
  cat > "$HOME_DIR/.config/systemd/user/rclone-bisync-$r.timer" <<EOF
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

cat > "$HOME_DIR/bin/first-sync.sh" <<EOF
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
chmod +x "$HOME_DIR/bin/first-sync.sh"
chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.config" "$HOME_DIR/bin" "$HOME_DIR/.local" "$SYNC_BASE"

loginctl enable-linger "$USERNAME"

#--- 9. Claude Code / herdr (ユーザー権限で導入) --------------------------------
log "Claude Codeを導入 (ユーザー: $USERNAME)"
as_user "command -v claude >/dev/null || curl -fsSL https://claude.ai/install.sh | bash"

log "herdrを導入 (ユーザー: $USERNAME)"
as_user "command -v herdr >/dev/null || curl -fsSL https://herdr.dev/install.sh | sh"

as_user "grep -q '.local/bin' '$HOME_DIR/.bashrc' || echo 'export PATH=\"\$HOME/.local/bin:\$HOME/bin:\$PATH\"' >> '$HOME_DIR/.bashrc'"

#--- 10. 完了メモをユーザーのホームに残す ---------------------------------------
cat > "$HOME_DIR/README-setup.txt" <<EOF
===============================================================================
 自動セットアップ完了 ($(date))
===============================================================================
 1) RDP接続: <サーバーIP>:3389 / ユーザー: $USERNAME
    ※パスワードを初期値から変更していない場合は今すぐ passwd で変更!
 2) クラウド認証:  rclone config  (リモート名: ${REMOTES[*]})
    ブラウザ認証はRDPデスクトップ内のChromiumで行うのが簡単です
 3) 初回同期:      ~/bin/first-sync.sh  (以後 ${SYNC_INTERVAL} 間隔で自動同期)
    ローカル側: $SYNC_BASE/<リモート名>/ (inbox=受信用 / outbox=出力用)
 4) Claude Code:   cd ~/sync && claude  (初回起動時にログイン)
 5) herdr:         herdr  (Ctrl+b q でデタッチ / herdr で再アタッチ)
 同期ログ: ~/.local/share/rclone-logs/
 構築ログ: /var/log/startup-ai-server.log
===============================================================================
EOF
chown "$USERNAME:$USERNAME" "$HOME_DIR/README-setup.txt"

log "セットアップ完了"
