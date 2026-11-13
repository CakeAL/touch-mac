#!/usr/bin/env python3
"""TCP -> FIFO 触控转发。

平板上的 TouchBridge App 通过 `adb reverse tcp:47777 tcp:47777` 连到本机 47777，
按行发送 "d|m|u <id> <x> <y>" 或 "c"；本脚本校验后原样写入 bridge client 的 FIFO。

这样做的好处：平板端不需要任何 USB HID / root 权限，Mac 端也不需要；
真正的原生触控仍由已签名的 Sunshine → libvirtualhid 提供。
"""

from __future__ import annotations

import argparse
import re
import errno
import os
import socket
import sys
import threading
import time

FIFO_WAIT_MSG = "waiting for bridge client on FIFO"
_ACTIVE = 0
DEFAULT_ASPECT = 16.0 / 9.0


def parse_aspect(text: str) -> float:
    """接受 "16:9"、"16x9" 或纯浮点。"""
    text = (text or "").strip()
    if not text:
        return DEFAULT_ASPECT
    try:
        if ":" in text:
            a, b = text.split(":", 1)
            return float(a) / float(b)
        if "x" in text.lower():
            a, b = re.split("[xX]", text, maxsplit=1)
            return float(a) / float(b)
        return float(text)
    except (ValueError, ZeroDivisionError):
        log("bad aspect, falling back to 16:9:", text)
        return DEFAULT_ASPECT


def log(*args):
    print("[touchd]", *args, file=sys.stderr, flush=True)


class FifoSink:
    """以非阻塞方式打开 FIFO 写端；没有读端时自动等待。"""

    def __init__(self, path: str):
        self.path = path
        self.fd = None
        self.lock = threading.Lock()
        self.last_wait = 0.0

    def _ensure(self) -> bool:
        if self.fd is not None:
            return True
        try:
            self.fd = os.open(self.path, os.O_WRONLY | os.O_NONBLOCK)
            log("fifo opened:", self.path)
            return True
        except OSError as exc:
            if exc.errno in (errno.ENXIO, errno.ENOENT):
                now = time.time()
                if now - self.last_wait > 3:
                    self.last_wait = now
                    log(FIFO_WAIT_MSG)
                return False
            raise

    def write(self, line: str) -> None:
        data = (line + "\n").encode("ascii")
        with self.lock:
            if not self._ensure():
                return
            try:
                os.write(self.fd, data)
            except OSError as exc:
                if exc.errno in (errno.EPIPE, errno.EBADF, errno.EAGAIN):
                    try:
                        os.close(self.fd)
                    except OSError:
                        pass
                    self.fd = None
                else:
                    raise


def parse(line: str):
    parts = line.split()
    if not parts:
        return None
    kind = parts[0]
    if kind == "c":
        return ("c", 0, 0.0, 0.0)
    if kind not in ("d", "m", "u") or len(parts) != 4:
        return None
    try:
        ident = int(parts[1])
        x = float(parts[2])
        y = float(parts[3])
    except ValueError:
        return None
    if not (0 <= ident <= 31):
        return None
    x = min(1.0, max(0.0, x))
    y = min(1.0, max(0.0, y))
    return (kind, ident, x, y)


def serve_client(conn: socket.socket, addr, sink: FifoSink, aspect: float) -> None:
    log(f"client connected: {addr[0]}:{addr[1]}")
    global _ACTIVE
    _ACTIVE += 1
    active: set[int] = set()
    try:
        # 握手：告诉平板端 Mac 显示器的宽高比，用于画活动框
        conn.sendall(("#aspect %.6f\n" % aspect).encode("ascii"))
    except OSError:
        pass
    sink.write("c")  # 新连接先清空可能残留的触点
    counts = {"d": 0, "m": 0, "u": 0}
    conn.settimeout(None)
    buf = b""
    try:
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                try:
                    text = raw.decode("ascii").strip()
                except UnicodeDecodeError:
                    continue
                parsed = parse(text)
                if parsed is None:
                    continue
                kind, ident, x, y = parsed
                if kind == "c":
                    active.clear()
                elif kind == "d":
                    active.add(ident)
                elif kind == "u":
                    active.discard(ident)
                if kind in counts:
                    counts[kind] += 1
                sink.write(text)
    except OSError as exc:
        log("connection error:", exc)
    finally:
        for ident in sorted(active):
            sink.write(f"u {ident} 0.5 0.5")
        sink.write("c")
        conn.close()
        log(f"client disconnected: {addr[0]}:{addr[1]} ({len(active)} contacts released, d={counts['d']} m={counts['m']} u={counts['u']})")


def main() -> int:
    ap = argparse.ArgumentParser(description="平板触控 TCP -> FIFO 转发")
    ap.add_argument("--listen", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=47777)
    ap.add_argument("--fifo", default="/tmp/touchpipe")
    ap.add_argument("--aspect", default="16:9",
                    help='Mac 显示器宽高比，如 "16:9"、"16:10"、"1.7778"')
    args = ap.parse_args()

    aspect = parse_aspect(args.aspect)
    sink = FifoSink(args.fifo)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.listen, args.port))
    srv.listen(4)
    log(f"listening on {args.listen}:{args.port} -> {args.fifo} aspect={aspect:.4f}")
    try:
        while True:
            conn, addr = srv.accept()
            threading.Thread(target=serve_client, args=(conn, addr, sink, aspect),
                             daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        srv.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
