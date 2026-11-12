#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p build
clang -fobjc-arc -O2 -framework AppKit -framework CoreGraphics -framework Foundation \
  -o build/screeninfo screeninfo.m
clang -fobjc-arc -O2 -framework AppKit -framework Foundation -framework IOKit \
  -o build/vnat vnat.m
clang -fobjc-arc -O2 -framework Foundation -framework IOKit -o build/vkeyb vkeyb.m
clang -fobjc-arc -O2 -framework AppKit -framework Foundation -framework IOKit \
  -o build/vtouch vtouch.m
clang -fobjc-arc -O2 -framework Foundation -framework IOKit -o build/vtcreate vtcreate.m
echo "built: probe/build/"
