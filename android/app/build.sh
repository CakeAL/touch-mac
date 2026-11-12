#!/bin/bash
# 不用 Gradle，直接用 build-tools 里的 aapt2/javac/d8/zipalign/apksigner 出 APK。
# 用法：./build.sh   （产物写到 build/TouchPad.apk）
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/36.0.0"
AJAR="$SDK/platforms/android-37.0/android.jar"
KS="$HOME/.android/debug.keystore"
PKG=dev.local.touchpad
OUT=build
APK=$OUT/TouchPad.apk

[ -x "$BT/aapt2" ] || { echo "找不到 aapt2：$BT"; exit 1; }
[ -f "$AJAR" ] || { echo "找不到 android.jar：$AJAR"; exit 1; }
[ -f "$KS" ] || { echo "找不到 debug keystore：$KS"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/classes" "$OUT/dex"

echo "== aapt2 link =="
"$BT/aapt2" link -o "$OUT/base.apk" \
  -I "$AJAR" \
  --manifest AndroidManifest.xml \
  --min-sdk-version 26 \
  --target-sdk-version 36

echo "== javac =="
javac -source 17 -target 17 -encoding UTF-8 \
  -classpath "$AJAR" -d "$OUT/classes" \
  src/${PKG//.//}/MainActivity.java

echo "== d8 =="
"$BT/d8" --lib "$AJAR" --min-api 26 \
  --output "$OUT/dex" "$OUT"/classes/${PKG//.//}/*.class

echo "== package =="
cp "$OUT/base.apk" "$OUT/unsigned.apk"
( cd "$OUT/dex" && zip -q -X "../unsigned.apk" classes.dex )

echo "== zipalign =="
"$BT/zipalign" -f 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "== sign =="
"$BT/apksigner" sign \
  --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --ks-key-alias androiddebugkey \
  --out "$APK" "$OUT/aligned.apk"

"$BT/apksigner" verify --print-certs "$APK" | head -5
ls -lh "$APK"
