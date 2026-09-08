#!/usr/bin/env bash
#===============================================================================
# conoha-vps.sh — ConoHa VPS 3.0 API でインスタンスを作成/一覧/削除する
#
# 事前準備 (一度だけ):
#   1) ConoHaコントロールパネル「API」画面で APIユーザー を作成し、
#      ユーザーID・パスワード・テナントIDを控える
#   2) 環境変数を設定 (~/.bashrc 等に):
#        export CONOHA_USER_ID="APIユーザーのID"
#        export CONOHA_PASSWORD="APIユーザーのパスワード"
#        export CONOHA_TENANT_ID="テナントID"
#   3) 依存: curl, jq  (mac: brew install jq / ubuntu: sudo apt install jq)
#
# 使い方:
#   ./conoha-vps.sh create [スタートアップスクリプトのパス]
#       例: ./conoha-vps.sh create ./startup-ai-server.sh
#   ./conoha-vps.sh list              # サーバー一覧 (ID/名前/状態/IP)
#   ./conoha-vps.sh delete <サーバーID>  # サーバーと起動ボリュームを削除
#===============================================================================
set -euo pipefail

#--- .env 読み込み --------------------------------------------------------------
# スクリプトと同じディレクトリの .env があれば読み込む (雛形: .env.example)。
# .env に書いたキーはシェルの環境変数より優先される。
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

#--- 設定 ----------------------------------------------------------------------
NAME_TAG="ai-server"          # コントロールパネルに表示される名前
RAM_GB=12                     # プラン (メモリGB): 4 / 12 など
IMAGE_MATCH="ubuntu-24.04"    # OSイメージ名の部分一致
VOLUME_SIZE=100               # ブートストレージGB (プラン既定値)
ROOT_PASS="${CONOHA_ROOT_PASS:-ChangeMe-Root-123!}"  # rootパスワード(要変更)
RDP_SG_NAME="ai-server-rdp"   # RDP(3389)用セキュリティグループ名(自動作成)
IDENTITY="https://identity.c3j1.conoha.io/v3"        # 東京リージョン(c3j1)
#-------------------------------------------------------------------------------

: "${CONOHA_USER_ID:?環境変数 CONOHA_USER_ID を設定してください}"
: "${CONOHA_PASSWORD:?環境変数 CONOHA_PASSWORD を設定してください}"
: "${CONOHA_TENANT_ID:?環境変数 CONOHA_TENANT_ID を設定してください}"
command -v jq >/dev/null || { echo "jq が必要です"; exit 1; }

log() { echo -e "\033[1;36m==> $*\033[0m" >&2; }

#--- 認証: トークン取得 + エンドポイント発見 ------------------------------------
authenticate() {
  local resp headers
  headers=$(mktemp)
  resp=$(curl -fsS -D "$headers" -X POST "$IDENTITY/auth/tokens" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -d @- <<EOF
{"auth": {"identity": {"methods": ["password"],
  "password": {"user": {"id": "$CONOHA_USER_ID", "password": "$CONOHA_PASSWORD"}}},
  "scope": {"project": {"id": "$CONOHA_TENANT_ID"}}}}
EOF
)
  TOKEN=$(grep -i '^x-subject-token:' "$headers" | tr -d '\r' | awk '{print $2}')
  rm -f "$headers"
  [[ -n "$TOKEN" ]] || { echo "認証に失敗しました"; exit 1; }
  # サービスカタログから各エンドポイントを自動発見
  COMPUTE=$(echo "$resp"  | jq -r '.token.catalog[] | select(.type=="compute")     | .endpoints[0].url')
  VOLUME=$(echo "$resp"   | jq -r '.token.catalog[] | select(.type | test("volume")) | .endpoints[0].url' | head -1)
  IMAGE=$(echo "$resp"    | jq -r '.token.catalog[] | select(.type=="image")       | .endpoints[0].url')
  NETWORK=$(echo "$resp"  | jq -r '.token.catalog[] | select(.type=="network")     | .endpoints[0].url')
}

api() { # api <METHOD> <URL> [JSONボディ]
  if [[ $# -ge 3 ]]; then
    curl -fsS -X "$1" "$2" -H "Accept: application/json" \
      -H "Content-Type: application/json" -H "X-Auth-Token: $TOKEN" -d "$3"
  else
    curl -fsS -X "$1" "$2" -H "Accept: application/json" -H "X-Auth-Token: $TOKEN"
  fi
}

#--- create --------------------------------------------------------------------
cmd_create() {
  local startup="${1:-}"

  log "フレーバー(${RAM_GB}GBプラン)を検索"
  local ram_mb=$((RAM_GB * 1024))
  FLAVOR_ID=$(api GET "$COMPUTE/flavors/detail" \
    | jq -r --argjson ram "$ram_mb" '[.flavors[] | select(.ram==$ram)][0].id')
  [[ "$FLAVOR_ID" != "null" && -n "$FLAVOR_ID" ]] || { echo "${RAM_GB}GBのフレーバーが見つかりません (list系APIで確認を)"; exit 1; }
  echo "  flavor: $FLAVOR_ID" >&2

  log "OSイメージ($IMAGE_MATCH)を検索"
  IMAGE_ID=$(api GET "$IMAGE/v2/images?limit=200" \
    | jq -r --arg m "$IMAGE_MATCH" '[.images[] | select(.name | test($m))][0].id')
  [[ "$IMAGE_ID" != "null" && -n "$IMAGE_ID" ]] || { echo "イメージが見つかりません"; exit 1; }
  echo "  image: $IMAGE_ID" >&2

  log "ブートボリュームタイプを確認"
  VTYPE=$(api GET "$VOLUME/types" | jq -r '[.volume_types[] | select(.name | test("boot"))][0].name')

  log "ブートボリューム(${VOLUME_SIZE}GB)を作成"
  VOL_ID=$(api POST "$VOLUME/volumes" "$(jq -n \
    --arg name "$NAME_TAG-boot" --arg vt "$VTYPE" --arg img "$IMAGE_ID" --argjson size "$VOLUME_SIZE" \
    '{volume: {name: $name, size: $size, volume_type: $vt, imageRef: $img}}')" \
    | jq -r '.volume.id')
  echo "  volume: $VOL_ID" >&2

  log "ボリュームの準備完了を待機"
  for _ in $(seq 1 60); do
    local st
    st=$(api GET "$VOLUME/volumes/$VOL_ID" | jq -r '.volume.status')
    [[ "$st" == "available" ]] && break
    [[ "$st" == "error" ]] && { echo "ボリューム作成エラー"; exit 1; }
    sleep 5
  done

  log "RDP用セキュリティグループを確認/作成 ($RDP_SG_NAME)"
  local sg_id
  sg_id=$(api GET "$NETWORK/v2.0/security-groups" \
    | jq -r --arg n "$RDP_SG_NAME" '[.security_groups[] | select(.name==$n)][0].id')
  if [[ "$sg_id" == "null" || -z "$sg_id" ]]; then
    sg_id=$(api POST "$NETWORK/v2.0/security-groups" \
      "{\"security_group\": {\"name\": \"$RDP_SG_NAME\", \"description\": \"xrdp 3389\"}}" \
      | jq -r '.security_group.id')
    api POST "$NETWORK/v2.0/security-group-rules" "$(jq -n --arg sg "$sg_id" \
      '{security_group_rule: {security_group_id: $sg, direction: "ingress",
        ethertype: "IPv4", protocol: "tcp", port_range_min: 3389, port_range_max: 3389}}')" >/dev/null
  fi

  local body
  body=$(jq -n \
    --arg flavor "$FLAVOR_ID" --arg pass "$ROOT_PASS" --arg vol "$VOL_ID" \
    --arg tag "$NAME_TAG" --arg rdp "$RDP_SG_NAME" \
    '{server: {flavorRef: $flavor, adminPass: $pass,
       block_device_mapping_v2: [{uuid: $vol}],
       metadata: {instance_name_tag: $tag},
       security_groups: [{name: "IPv4v6-SSH"}, {name: $rdp}]}}')

  if [[ -n "$startup" ]]; then
    log "スタートアップスクリプトを添付: $startup"
    local b64
    b64=$(base64 -w0 "$startup" 2>/dev/null || base64 "$startup" | tr -d '\n')
    body=$(echo "$body" | jq --arg ud "$b64" '.server.user_data = $ud')
  fi

  log "サーバーを作成 (${RAM_GB}GB / $NAME_TAG)"
  SERVER_ID=$(api POST "$COMPUTE/servers" "$body" | jq -r '.server.id')
  echo "  server: $SERVER_ID" >&2

  log "起動を待機"
  for _ in $(seq 1 60); do
    local st
    st=$(api GET "$COMPUTE/servers/$SERVER_ID" | jq -r '.server.status')
    [[ "$st" == "ACTIVE" ]] && break
    [[ "$st" == "ERROR" ]] && { echo "サーバー作成エラー"; exit 1; }
    sleep 5
  done

  local ip
  ip=$(api GET "$COMPUTE/servers/$SERVER_ID" \
    | jq -r '[.server.addresses[][] | select(.version==4)][0].addr')
  cat >&2 <<EOF

===============================================================================
 作成完了
   サーバーID : $SERVER_ID
   IPv4       : $ip
   SSH        : ssh root@$ip   (パスワード: ROOT_PASS で設定した値)
 スタートアップスクリプト実行中は5〜10分待ってから接続してください。
 進行確認: ssh root@$ip 'tail -f /var/log/startup-ai-server.log'
===============================================================================
EOF
}

#--- list ----------------------------------------------------------------------
cmd_list() {
  api GET "$COMPUTE/servers/detail" | jq -r '
    ["ID","NAME","STATUS","IPv4"],
    (.servers[] | [.id, (.metadata.instance_name_tag // .name), .status,
      ([.addresses[][]? | select(.version==4).addr][0] // "-")])
    | @tsv' | column -t
}

#--- delete --------------------------------------------------------------------
cmd_delete() {
  local id="${1:?サーバーIDを指定してください}"
  log "アタッチ済みボリュームを確認"
  local vols
  vols=$(api GET "$COMPUTE/servers/$id/os-volume_attachments" \
    | jq -r '.volumeAttachments[].volumeId')
  log "サーバー $id を削除"
  api DELETE "$COMPUTE/servers/$id" || true
  sleep 20
  for v in $vols; do
    log "ボリューム $v を削除"
    api DELETE "$VOLUME/volumes/$v" || echo "  (まだ解放中の場合は後で再実行してください)"
  done
  log "削除完了 (課金停止にはボリューム削除まで必要です)"
}

#--- main ----------------------------------------------------------------------
authenticate
case "${1:-create}" in
  create) cmd_create "${2:-}" ;;
  list)   cmd_list ;;
  delete) cmd_delete "${2:-}" ;;
  *) echo "usage: $0 {create [startup.sh] | list | delete <server-id>}"; exit 1 ;;
esac
