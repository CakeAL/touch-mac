#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=build/TouchLab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
clang -fobjc-arc -O2 -framework AppKit -framework Foundation \
  -o "$APP/Contents/MacOS/TouchLab" touchlab.m
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: mac/TouchLab/$APP"
