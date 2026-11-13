#!/usr/bin/env python3
"""把 Android 触摸屏（adb getevent）转成 bridge/client 的 stdin 触控指令。

用法:
  tablet_touch.py [--device /dev/input/event3] [--maxx 1751] [--maxy 2799]
                  [--rotate 0|90|180|270] [--out FIFO|-] [--rate HZ]

输出协议（每行一条）:
  d <id> <x> <y>   手指按下
  m <id> <x> <y>   移动
  u <id> <x> <y>   抬起
  c                取消全部

坐标 0..1，左上原点（与视频区域一致）。
"""
import argparse, subprocess, sys, time

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--device", default="/dev/input/event3")
    ap.add_argument("--maxx", type=float, default=1751)
    ap.add_argument("--maxy", type=float, default=2799)
    ap.add_argument("--rotate", type=int, default=0, choices=[0, 90, 180, 270])
    ap.add_argument("--out", default="-", help="输出文件（FIFO）或 - 表示 stdout")
    ap.add_argument("--rate", type=float, default=120, help="最大发送频率 Hz")
    ap.add_argument("--adb", default="adb")
    args = ap.parse_args()

    out = sys.stdout if args.out == "-" else open(args.out, "w", buffering=1)
    proc = subprocess.Popen([args.adb, "exec-out", "getevent", "-lt", args.device],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)

    # slot -> dict(id, x, y, active, sent)
    slots = {}
    cur = 0
    last_send = 0.0
    sent_any = False

    def norm(x, y):
        nx, ny = x / args.maxx, y / args.maxy
        if args.rotate == 90:
            nx, ny = ny, 1.0 - nx
        elif args.rotate == 180:
            nx, ny = 1.0 - nx, 1.0 - ny
        elif args.rotate == 270:
            nx, ny = 1.0 - ny, nx
        return min(max(nx, 0.0), 1.0), min(max(ny, 0.0), 1.0)

    def emit(line):
        nonlocal sent_any
        out.write(line + "\n")
        out.flush()
        sent_any = True

    def flush():
        nonlocal last_send, sent_any
        now = time.time()
        if now - last_send < 1.0 / args.rate:
            return
        last_send = now
        for slot, st in slots.items():
            x, y = norm(st["x"], st["y"])
            if st["active"] and not st["sent"]:
                st["sent"] = "d"
                emit(f"d {st['id']} {x:.4f} {y:.4f}")
            elif st["active"] and st["sent"] == "d":
                if abs(st["lx"] - x) > 0.0005 or abs(st["ly"] - y) > 0.0005:
                    st["lx"], st["ly"] = x, y
                    emit(f"m {st['id']} {x:.4f} {y:.4f}")
        for slot, st in list(slots.items()):
            if not st["active"] and st["sent"] in ("d", "m"):
                st["sent"] = "u"
                x, y = norm(st["x"], st["y"])
                emit(f"u {st['id']} {x:.4f} {y:.4f}")

    buf = b""
    while True:
        chunk = proc.stdout.read(4096)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                text = line.decode(errors="replace").strip()
            except Exception:
                continue
            if not text:
                continue
            parts = text.split()
            # 形如: [ 37152.442255] EV_ABS ABS_MT_POSITION_X 00000407
            try:
                idx = parts.index("EV_SYN") if "EV_SYN" in parts else -1
            except ValueError:
                idx = -1
            if idx >= 0 and len(parts) > idx + 1 and parts[idx + 1] == "SYN_REPORT":
                flush()
                continue
            if len(parts) < 4:
                continue
            kind, code, val = parts[-3], parts[-2], parts[-1]
            try:
                v = int(val, 16)
            except ValueError:
                continue
            if kind == "EV_ABS":
                if code == "ABS_MT_SLOT":
                    cur = v
                elif code == "ABS_MT_TRACKING_ID":
                    st = slots.setdefault(cur, {"id": v, "x": 0, "y": 0, "active": False,
                                                "sent": None, "lx": -1, "ly": -1})
                    if v == 0xFFFFFFFF:
                        st["active"] = False
                    else:
                        st["id"] = v
                        st["active"] = True
                elif code == "ABS_MT_POSITION_X":
                    slots.setdefault(cur, {"id": cur, "x": 0, "y": 0, "active": False,
                                           "sent": None, "lx": -1, "ly": -1})["x"] = v
                elif code == "ABS_MT_POSITION_Y":
                    slots.setdefault(cur, {"id": cur, "x": 0, "y": 0, "active": False,
                                           "sent": None, "lx": -1, "ly": -1})["y"] = v
            elif kind == "EV_KEY" and code == "BTN_TOUCH" and v == 0:
                for st in slots.values():
                    st["active"] = False
                flush()

    if sent_any:
        emit("c")

if __name__ == "__main__":
    main()
