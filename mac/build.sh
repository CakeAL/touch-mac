#!/bin/sh
set -e
cd "$(dirname "$0")"
clang -fobjc-arc -O2 \
  -framework AppKit -framework Foundation -framework IOKit -framework CoreGraphics \
  -o touchbridge touchbridge.m
echo "built: mac/touchbridge"
