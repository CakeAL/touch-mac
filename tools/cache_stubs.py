#!/usr/bin/env python3
"""Resolve unslid stub addresses in the dyld shared cache to import names.

The arm64e shared cache stores per-image __auth_stubs with size 0; the real
stubs live in a dedicated DYLD_CACHE_MAPPING_TEXT_STUBS subcache (.02 here).
Each stub is: adrp x17, page; add x17, x17, #off; ldr x16, [x17]; braa x16, x17
The [x17] slot holds a chained-fixup shared-cache auth rebase whose low 34 bits
are the runtime offset from the cache base (0x180000000).
"""
import glob
import os
import re
import struct
import sys

BASE_DIR = "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld"
CACHE_BASE = 0x180000000
MAIN = os.path.join(BASE_DIR, "dyld_shared_cache_arm64e")
EXPORTS = "/tmp/cache-exports.txt"


class Reader:
    def __init__(self):
        self.mappings = []  # (addr, size, file_offset, path)
        paths = [MAIN] + sorted(glob.glob(MAIN + ".*"))
        for p in paths:
            try:
                with open(p, "rb") as f:
                    h = f.read(0x300)
            except OSError:
                continue
            if not h.startswith(b"dyld_v1"):
                continue
            moff, mcnt = struct.unpack_from("<II", h, 16)
            for i in range(mcnt):
                off = moff + i * 32
                if off + 32 > len(h):
                    break
                addr, size, foff, _maxp, _initp = struct.unpack_from("<QQQII", h, off)
                self.mappings.append((addr, size, foff, p))
        self.images = self._read_images()

    def _read_images(self):
        with open(MAIN, "rb") as f:
            d = f.read()
        images_offset, images_count = struct.unpack_from("<II", d, 0x1C0)
        out = []
        for i in range(images_count):
            off = images_offset + i * 32
            addr, _mtime, _inode, pathoff, _pad = struct.unpack_from("<QQQII", d, off)
            end = d.find(b"\0", pathoff)
            path = d[pathoff:end].decode(errors="replace")
            out.append((addr, path))
        return out

    def read(self, addr, size):
        for a, s, foff, p in self.mappings:
            if a <= addr and addr + size <= a + s:
                with open(p, "rb") as f:
                    f.seek(foff + (addr - a))
                    return f.read(size)
        raise ValueError(f"unmapped address {addr:#x}")

    def image_for(self, addr):
        for idx, (base, path) in enumerate(self.images):
            if idx + 1 < len(self.images):
                nxt = self.images[idx + 1][0]
            else:
                nxt = base + 0x4000000
            if base <= addr < nxt:
                return base, path
        return None, None


def load_exports(path):
    exports = {}
    cur = None
    with open(path, "r", errors="replace") as f:
        for line in f:
            m = re.match(r"^(/\S+) \[[^\]]+\]:", line)
            if m:
                cur = m.group(1)
                continue
            m = re.match(r"^\s+0x([0-9A-Fa-f]+)\s+(\S+)", line)
            if m and cur:
                exports.setdefault((cur, int(m.group(1), 16)), []).append(m.group(2))
    return exports


def decode_stub(data, stub_addr):
    insn = struct.unpack_from("<I", data, 0)[0]
    if (insn & 0x9F000000) != 0x90000000:  # adrp xN, ...
        raise ValueError(f"not adrp: {insn:#x}")
    immlo = (insn >> 29) & 3
    immhi = (insn >> 5) & 0x7FFFF
    imm = (immhi << 2) | immlo
    if imm & (1 << 20):
        imm -= 1 << 21
    got_page = (stub_addr & ~0xFFF) + (imm << 12)
    insn2 = struct.unpack_from("<I", data, 4)[0]
    if (insn2 & 0xFFC00000) != 0x91000000:  # add x17, x17, #imm
        raise ValueError(f"not add: {insn2:#x}")
    imm12 = (insn2 >> 10) & 0xFFF
    got = got_page + imm12
    return got


def main():
    r = Reader()
    exports = load_exports(EXPORTS)
    addrs = [int(x, 0) for x in sys.argv[1:]]
    if not addrs:
        print("usage: cache_stubs.py 0x188076400 [...]", file=sys.stderr)
        return 1
    for stub in addrs:
        data = r.read(stub, 16)
        got = decode_stub(data, stub)
        val = struct.unpack("<Q", r.read(got, 8))[0]
        if val >> 63:
            runtime_offset = val & ((1 << 34) - 1)
            target = CACHE_BASE + runtime_offset
        else:
            # non-auth rebase (not expected for imports)
            target = CACHE_BASE + (val & ((1 << 34) - 1))
        base, path = r.image_for(target)
        if path is None:
            print(f"{stub:#x} -> got {got:#x} val {val:#x} -> {target:#x} (no image)")
            continue
        off = target - base
        names = exports.get((path, off), ["?"])
        print(f"{stub:#x} -> {', '.join(names)}  [{path}+{off:#x}]")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
