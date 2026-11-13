#!/bin/bash
# 构建 TouchBridgeViewer.app（SwiftPM release 产物 -> .app bundle -> ad-hoc 签名）
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="TouchBridgeViewer"
APP_DIR="build/${APP_NAME}.app"

# 当前沙箱环境里 SwiftPM 自己的 sandbox 和用户级缓存不可用，改用工程内缓存。
mkdir -p .cache/clang
export CLANG_MODULE_CACHE_PATH="$PWD/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.cache/clang"

swift build -c "${CONFIG}" --disable-sandbox

BIN_PATH="$(swift build -c "${CONFIG}" --disable-sandbox --show-bin-path)/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "error: ${BIN_PATH} 不存在，构建失败" >&2
    exit 1
fi

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

# 本机自用，ad-hoc 签名即可；失败不阻断（比如未装命令行工具权限时）
codesign --force --deep --sign - "${APP_DIR}" >/dev/null 2>&1 || \
    echo "warning: ad-hoc 签名失败，可直接运行 Contents/MacOS/${APP_NAME}" >&2

echo "built: ${APP_DIR}"
echo "run:   open ${APP_DIR}"
