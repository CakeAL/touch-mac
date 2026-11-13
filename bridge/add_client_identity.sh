#!/usr/bin/env bash
# 把本地桥接客户端的自签证书写入 Sunshine 的已配对设备表。
# 不修改 Sunshine 二进制或签名，只改它自己的 state 配置文件。
#
# 用法: ./add_client_identity.sh [--revert]
set -euo pipefail

STATE="$HOME/.config/sunshine/sunshine_state.json"
CERT="$(cd "$(dirname "$0")" && pwd)/certs/client.crt"
NAME="touch-bridge"

if [[ "${1:-}" == "--revert" ]]; then
  python3 - "$STATE" "$NAME" <<'PY'
import json, sys
state_path, name = sys.argv[1], sys.argv[2]
with open(state_path) as f:
    state = json.load(f)
before = len(state["root"]["named_devices"])
state["root"]["named_devices"] = [d for d in state["root"]["named_devices"] if d["name"] != name]
with open(state_path, "w") as f:
    json.dump(state, f, indent=2)
print(f"removed {before - len(state['root']['named_devices'])} device(s) named {name}")
PY
  exit 0
fi

[[ -f "$CERT" ]] || { echo "missing $CERT; run: openssl req -x509 ... first" >&2; exit 1; }
cp "$STATE" "$STATE.bak.$(date +%s)"

python3 - "$STATE" "$CERT" "$NAME" <<'PY'
import json, sys, uuid
state_path, cert_path, name = sys.argv[1], sys.argv[2], sys.argv[3]
with open(state_path) as f:
    state = json.load(f)
with open(cert_path) as f:
    cert = f.read()
devices = state["root"]["named_devices"]
devices = [d for d in devices if d["name"] != name]
devices.append({"name": name, "cert": cert, "uuid": str(uuid.uuid4()).upper(), "enabled": True})
state["root"]["named_devices"] = devices
with open(state_path, "w") as f:
    json.dump(state, f, indent=2)
print("paired devices now:", [(d["name"], d["enabled"]) for d in devices])
PY

echo "state updated; restart Sunshine so its client cert chain is rebuilt."
