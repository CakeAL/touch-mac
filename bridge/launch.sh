#!/usr/bin/env bash
# 发起 /launch 并运行桥接客户端。
#
# 用法: ./launch.sh [--appid N] [--two-finger] [--hold N]
# 依赖: bridge/certs/client.crt|key 已在 Sunshine state 中（见 add_client_identity.sh）
set -euo pipefail

HOST=127.0.0.1
HERE="$(cd "$(dirname "$0")" && pwd)"
CERT="$HERE/certs/client.crt"
KEY="$HERE/certs/client.key"
CLIENT="$HERE/client"

APPID=1
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --appid) APPID="$2"; shift 2 ;;
    --two-finger) EXTRA+=(--two-finger); shift ;;
    --hold) EXTRA+=(--hold-seconds "$2"); shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

RIKEY="$(openssl rand -hex 16)"
RIKEYID="$((RANDOM * 32768 + RANDOM))"

Q="uniqueid=0123456789ABCDEF&appid=$APPID&mode=2560x1440x60&fps=60&hdrMode=0&rikey=$RIKEY&rikeyid=$RIKEYID&localAudioPlayMode=0&surroundAudioInfo=196610&sops=0&corever=1&gcmap=0&clientHdrCapVersion=0"

echo "[launch] POST /launch appid=$APPID rikeyid=$RIKEYID" >&2
RESP="$(curl -sS -k --cert "$CERT" --key "$KEY" "https://$HOST:47984/launch?$Q")" || {
  echo "[launch] curl failed" >&2; exit 1; }

CODE="$(printf '%s' "$RESP" | sed -n 's/.*status_code="\([0-9]*\)".*/\1/p' | head -1)"
URL="$(printf '%s' "$RESP" | sed -n 's:.*<sessionUrl0>\(.*\)</sessionUrl0>.*:\1:p' | head -1)"

echo "[launch] status_code=${CODE:-?}" >&2
echo "[launch] sessionUrl0=${URL:-<none>}" >&2
if [[ -z "$URL" ]]; then
  echo "[launch] full response:" >&2
  printf '%s\n' "$RESP" >&2
  exit 1
fi

# 让会话信息落到文件，方便事后核对
cat > /tmp/bridge-launch.env <<EOF
LAUNCH_RIKEY=$RIKEY
LAUNCH_RIKEYID=$RIKEYID
LAUNCH_URL=$URL
LAUNCH_APPID=$APPID
LAUNCH_RESPONSE_CODE=${CODE:-?}
EOF

exec "$CLIENT" "$URL" "$RIKEY" "$RIKEYID" "${EXTRA[@]}"
