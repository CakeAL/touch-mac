#!/bin/bash
# 无需 gradle：直接用 Android SDK 的 aapt2 / d8 / apksigner 手工打包。
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_SDK:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/36.0.0"
PLATFORM_JAR="$SDK/platforms/android-37.0/android.jar"
[ -x "$BT/aapt2" ] || { echo "找不到 aapt2: $BT"; exit 1; }
[ -f "$PLATFORM_JAR" ] || { echo "找不到 android.jar: $PLATFORM_JAR"; exit 1; }

rm -rf build
mkdir -p build/classes build/dex build/res

echo "[1/5] 编译资源"
"$BT/aapt2" compile --dir res -o build/res/resources.zip

echo "[2/5] 链接资源与清单"
"$BT/aapt2" link \
  -o build/app-unsigned.apk \
  -I "$PLATFORM_JAR" \
  --manifest AndroidManifest.xml \
  --auto-add-overlay \
  -R build/res/resources.zip

echo "[3/5] 编译 Java"
find src -name '*.java' > build/sources.txt
javac -source 11 -target 11 -nowarn -encoding UTF-8 \
  -classpath "$PLATFORM_JAR" -d build/classes @build/sources.txt

echo "[4/5] dex"
"$BT/d8" --min-api 21 --lib "$PLATFORM_JAR" --output build/dex $(find build/classes -name '*.class')

echo "[5/5] 打包并签名"
cp build/app-unsigned.apk build/app-aligned.apk
(cd build/dex && zip -q -u ../app-aligned.apk classes.dex)
"$BT/zipalign" -f 4 build/app-aligned.apk build/app-final.apk

KS=debug.keystore
if [ ! -f "$KS" ]; then
  keytool -genkeypair -keystore "$KS" -storepass android -keypass android \
    -alias androiddebugkey -dname "CN=Android Debug,O=Android,C=US" \
    -keyalg RSA -keysize 2048 -validity 10000 >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out build/touchbridge.apk build/app-final.apk

echo "OK -> $(pwd)/build/touchbridge.apk"
