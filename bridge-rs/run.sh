#!/bin/bash
# 启动 Rust 桥（常驻待机：平板 App 一连上就自动唤醒 Sunshine 并开会话）。
#
# 用法：
#   bridge-rs/run.sh          # 前台运行，Ctrl-C 退出
#   bridge-rs/run.sh -d       # 后台运行（日志 /tmp/touchbridge.log）
#   bridge-rs/run.sh setup    # 只做 adb reverse（触控/视频/设置口）
set -e
cd "$(dirname "$0")/.."

if [ "$1" = "setup" ]; then
  adb reverse tcp:47777 tcp:47777
  adb reverse tcp:47779 tcp:47779
  adb reverse tcp:47781 tcp:47781
  echo "adb reverse 已建立：47777 触控 / 47779 视频 / 47781 设置"
  exit 0
fi

if [ ! -x bridge-rs/target/release/touchbridge ]; then
  (cd bridge-rs && cargo build --release)
fi

if [ "$1" = "-d" ]; then
  pkill -f "release/touchbridge" 2>/dev/null || true
  sleep 0.3
  nohup bridge-rs/target/release/touchbridge > /tmp/touchbridge.log 2>&1 &
  echo "touchbridge 已在后台启动，日志 /tmp/touchbridge.log"
  echo "平板连上后会自动唤醒 Sunshine；关闭 App 3 秒后会话自动结束。"
else
  exec bridge-rs/target/release/touchbridge
fi
