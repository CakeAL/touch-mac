#!/usr/bin/env python3
"""单指点击 + 双指捏合的演示脚本，用来验证 touchbridge 是否把触摸送进系统。"""
import socket, struct, sys, time

port = int(sys.argv[1]) if len(sys.argv) > 1 else 5288
sock = socket.create_connection(("127.0.0.1", port), timeout=3)

def rec(t, i, x, y, flags=0x07, pressure=0):
    sock.sendall(struct.pack(">BBHHBB", t, i, int(x * 65535), int(y * 65535), flags, pressure))

# 单指点按（屏幕中央偏左）
rec(1, 1, 0.40, 0.55); time.sleep(0.06)
rec(3, 1, 0.40, 0.55)
time.sleep(0.3)

# 双指捏合（缩小）
rec(1, 2, 0.40, 0.55); rec(1, 3, 0.60, 0.55); time.sleep(0.02)
for k in range(1, 11):
    rec(2, 2, 0.40 + 0.01 * k, 0.55)
    rec(2, 3, 0.60 - 0.01 * k, 0.55)
    time.sleep(0.016)
rec(3, 2, 0.50, 0.55); rec(3, 3, 0.50, 0.55)
print("demo sent")
