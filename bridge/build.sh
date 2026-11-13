#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MLCC=/tmp/moonlight-common-c
cc -O2 -std=c11 -Wall -Wextra \
  -I"$MLCC/src" -I"$MLCC/enet/include" \
  "$HERE/client.c" \
  "$MLCC/build/libmoonlight-common-c.a" \
  "$MLCC/build/enet/libenet.a" \
  -L/opt/homebrew/opt/openssl/lib -lcrypto \
  -lpthread -framework CoreFoundation \
  -o "$HERE/client"
echo "built $HERE/client"
