#!/usr/bin/env bash
# 建立一次 Sunshine 会话，把平板触摸转发成 VoidLink 原生触控。
#
# 用法: ./session.sh [--appid N] [--no-tablet] [--rotate 0|90|180|270]
#                    [--device /dev/input/event3] [--maxx N] [--maxy N]
#
# Ctrl-C 结束会话（会先发 CANCEL_ALL）。
set -uo pipefail

HOST=127.0.0.1
HERE="$(cd "$(dirname "$0")" && pwd)"
CERT="$HERE/certs/client.crt"
KEY="$HERE/certs/client.key"
CLIENT="$HERE/client"
FIFO=/tmp/touchpipe
PIDFILE=/tmp/touchbridge.pids
ADB="${ADB:-adb}"

APPID=881448767
TABLET=1
ROTATE=0
DEVICE=/dev/input/event3
MAXX=1751
MAXY=2799
while [[ $# -gt 0 ]]; do
  case "$1" in
    --appid) APPID="$2"; shift 2 ;;
    --no-tablet) TABLET=0; shift ;;
    --rotate) ROTATE="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    --maxx) MAXX="$2"; shift 2 ;;
    --maxy) MAXY="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

cleanup() {
  [[ -f "$PIDFILE" ]] && while read -r p; do kill "$p" 2>/dev/null; done < "$PIDFILE"
  rm -f "$FIFO" "$PIDFILE"
  echo "[session] stopped" >&2
}
trap cleanup EXIT INT TERM

curl -sS -k --cert "$CERT" --key "$KEY" "https://$HOST:47984/cancel?uniqueid=0123456789ABCDEF" >/dev/null 2>&1

RIKEY="$(openssl rand -hex 16)"
RIKEYID="$((RANDOM * 32768 + RANDOM))"
Q="uniqueid=0123456789ABCDEF&appid=$APPID&mode=1280x720x60&fps=60&hdrMode=0&rikey=$RIKEY&rikeyid=$RIKEYID&localAudioPlayMode=0&surroundAudioInfo=196610&sops=0"
RESP="$(curl -sS -k --cert "$CERT" --key "$KEY" "https://$HOST:47984/launch?$Q")" || { echo "[session] launch failed" >&2; exit 1; }
URL="$(printf '%s' "$RESP" | sed -n 's:.*<sessionUrl0>\(.*\)</sessionUrl0>.*:\1:p' | head -1)"
CODE="$(printf '%s' "$RESP" | sed -n 's/.*status_code="\([0-9]*\)".*/\1/p' | head -1)"
if [[ -z "$URL" ]]; then
  echo "[session] no sessionUrl (status=$CODE)" >&2
  printf '%s\n' "$RESP" | head -c 400 >&2; echo >&2
  exit 1
fi
echo "[session] status=$CODE url=$URL" >&2

[[ -p "$FIFO" ]] || { rm -f "$FIFO"; mkfifo "$FIFO"; }
: > "$PIDFILE"

# 保持 FIFO 写端打开，避免 client 读到 EOF
sleep 100000 > "$FIFO" &
echo $! >> "$PIDFILE"

"$CLIENT" "$URL" "$RIKEY" "$RIKEYID" --stdin --hold-seconds 1 < "$FIFO" >/tmp/touchbridge-client.log 2>&1 &
echo $! >> "$PIDFILE"

if [[ "$TABLET" == "1" ]]; then
  sleep 1.5   # 等会话建立
  python3 "$HERE/tablet_touch.py" --adb "$ADB" --device "$DEVICE" \
      --maxx "$MAXX" --maxy "$MAXY" --rotate "$ROTATE" --out "$FIFO" >/tmp/touchbridge-tablet.log 2>&1 &
  echo $! >> "$PIDFILE"
fi

echo "[session] running. Ctrl-C to stop." >&2
while true; do
  sleep 1
  if ! kill -0 "$(tail -1 "$PIDFILE")" 2>/dev/null; then :; fi
  if [[ -s /tmp/touchbridge-client.log ]] && grep -q '\[main\] done' /tmp/touchbridge-client.log; then
    echo "[session] client exited" >&2
    break
  fi
done
