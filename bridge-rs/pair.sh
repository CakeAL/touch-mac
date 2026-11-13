#!/bin/bash
# 把桥的客户端证书登记到 Sunshine 的已配对设备列表（免 PIN 配对）。
#
# 用法：
#   bridge-rs/pair.sh            # 登记/更新 touchbridge 这一条
#   bridge-rs/pair.sh --revert   # 从列表里删掉这一条
#
# 原理：Sunshine 的 HTTPS 会对每个请求做 verify_client_certificate，
# 要求客户端证书完全等于某条 enabled 的 named_device；官方配对流程需要
# Web UI 上点 PIN（需要 web 密码），而密码在 state 里只有 sha256 哈希，
# 无法反推。直接往 sunshine_state.json 里加一条 cert 是官方等价的做法。
set -e
cd "$(dirname "$0")"

STATE="$HOME/.config/sunshine/sunshine_state.json"
CERT="certs/client.crt"

[ -f "$STATE" ] || { echo "找不到 $STATE —— 先启动一次 Sunshine"; exit 1; }
[ -f "$CERT" ] || { echo "找不到 $CERT"; exit 1; }

NAME=touchbridge

if [ "$1" = "--revert" ]; then
  cp "$STATE" "$STATE.bak.pair"
  python3 - "$STATE" "$NAME" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
d = json.load(open(path))
nd = d.get("root", {}).get("named_devices", [])
d["root"]["named_devices"] = [x for x in nd if x.get("name") != name]
json.dump(d, open(path, "w"), indent=4)
print(f"已移除 {name}，剩余 {len(d['root']['named_devices'])} 个设备")
PY
else
  cp "$STATE" "$STATE.bak.pair"
  python3 - "$STATE" "$CERT" "$NAME" <<'PY'
import json, sys, uuid
path, cert_path, name = sys.argv[1], sys.argv[2], sys.argv[3]
cert = open(cert_path).read()
d = json.load(open(path))
nd = d.setdefault("root", {}).setdefault("named_devices", [])
for x in nd:
    if x.get("name") == name:
        x["cert"] = cert
        x["enabled"] = "true"
        break
else:
    nd.append({"name": name, "cert": cert, "uuid": str(uuid.uuid4()).upper(), "enabled": "true"})
json.dump(d, open(path, "w"), indent=4)
print(f"已登记 {name}（共 {len(nd)} 个设备）")
PY
fi

echo "重启 Sunshine 使其生效："
echo "  osascript -e 'quit app \"Sunshine\"'; sleep 2; open -a /Applications/Sunshine.app"
