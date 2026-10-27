#!/usr/bin/env python3
"""Directed RV32IM/address-range regressions using the unmodified course simulator."""
import argparse
import random
import subprocess
from pathlib import Path

MASK = 0xffffffff


def signed(x):
    return x if x < 0x80000000 else x - 0x100000000


def imm(op, rd, rs, value, f3=0):
    return ((value & 4095) << 20) | (rs << 15) | (f3 << 12) | (rd << 7) | op


def store(rs, base, offset=0, size=2):
    return ((offset & 4064) << 20) | (rs << 20) | (base << 15) | (size << 12) | ((offset & 31) << 7) | 0x23


class Program:
    def __init__(self, base=0):
        self.base, self.words, self.checks = base, [], []

    def emit(self, word):
        self.words.append(word & MASK)

    def li(self, rd, value):
        value &= MASK
        self.emit((((value + 0x800) >> 12) << 12) | (rd << 7) | 0x37)
        self.emit(imm(0x13, rd, rd, value))

    def check(self, rs, expected):
        self.li(30, expected)
        self.checks.append((len(self.words), rs))
        self.emit(0)

    def exit(self, value):
        self.li(31, 0x80000000)
        self.li(29, value)
        self.emit(store(29, 31))
        self.emit(0x6f)

    def finish(self):
        self.exit(0)
        fail = len(self.words)
        self.exit(1)
        for index, rs in self.checks:
            offset = (fail - index) * 4
            if offset >= 4096:
                raise ValueError("branch out of range; split the regression")
            self.words[index] = (((offset >> 12) & 1) << 31) | (((offset >> 5) & 63) << 25) | (30 << 20) | (rs << 15) | (1 << 12) | (((offset >> 1) & 15) << 8) | (((offset >> 11) & 1) << 7) | 0x63
        return self.words


def muldiv(f3, a, b):
    sa, sb = signed(a), signed(b)
    if f3 == 0: return a * b & MASK
    if f3 == 1: return (sa * sb >> 32) & MASK
    if f3 == 2: return (sa * b >> 32) & MASK
    if f3 == 3: return (a * b >> 32) & MASK
    if f3 in (4, 6):
        quotient = -1 if b == 0 else (abs(sa) // abs(sb)) * (-1 if (sa < 0) != (sb < 0) else 1)
        return (quotient if f3 == 4 else sa if b == 0 else sa - quotient * sb) & MASK
    return ((MASK if b == 0 else a // b) if f3 == 5 else (a if b == 0 else a % b)) & MASK


def cases():
    rng = random.Random(2026)
    values = [0, 1, MASK, 0x80000000, 0x7fffffff, 2, 0xfffffffe, 0x12345678]
    pairs = [(a, b) for a in values for b in values] + [(rng.getrandbits(32), rng.getrandbits(32)) for _ in range(32)]
    for f3 in range(8):
        # Small independent programs also make a failing M operation easy to locate.
        for batch in range(0, len(pairs), 24):
            p = Program()
            for a, b in pairs[batch:batch+24]:
                p.li(1, a); p.li(2, b)
                p.emit((1 << 25) | (2 << 20) | (1 << 15) | (f3 << 12) | (3 << 7) | 0x33)
                p.check(3, muldiv(f3, a, b))
            yield f"m{f3}-{batch//24}", {0: p.finish()}
    p = Program()
    # Equal low 18 bits expose tag truncation and the old 256 KiB RAM limit.
    for address, value in [(0x40000, 0x89abcdef), (0x140000, 0x12345678), (0xffffffc, 0xfedcba98)]:
        p.li(1, address); p.li(2, value); p.emit(store(2, 1))
    for address, value in [(0x40000, 0x89abcdef), (0x140000, 0x12345678), (0xffffffc, 0xfedcba98)]:
        p.li(1, address)
        p.emit(imm(3, 3, 1, 0, 2)); p.check(3, value)
        p.emit(imm(3, 3, 1, 3, 0)); p.check(3, signed(value) >> 24)
        p.emit(imm(3, 3, 1, 3, 4)); p.check(3, value >> 24)
        p.emit(imm(3, 3, 1, 2, 1)); p.check(3, signed(value) >> 16)
        p.emit(imm(3, 3, 1, 2, 5)); p.check(3, value >> 16)
        p.li(2, 0x55); p.emit(store(2, 1, 1, 0))
        p.li(2, 0x6677); p.emit(store(2, 1, 2, 1))
        p.emit(imm(3, 3, 1, 0, 2)); p.check(3, (value & 255) | 0x66775500)
    yield "full-ram-and-subwords", {0: p.finish()}
    # Repeated indirect calls train both low and high PC BTB entries. AUIPC,
    # return links and taken checks exercise recovery at the high address.
    for high in (0x40000, 0x140000, 0xffff000):
        boot = Program()
        boot.li(1, high)
        for _ in range(12):
            boot.emit(imm(0x67, 5, 1, 0))
        boot.exit(0)
        function = Program(high)
        function.emit((6 << 7) | 0x17)  # auipc x6,0
        function.check(6, high)
        function.emit(imm(0x67, 0, 5, 0))
        yield f"high-pc-{high:08x}", {0: boot.words, high: function.finish()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sim", type=Path, default=Path("build/ooo/sim"))
    parser.add_argument("--latency", type=int, action="append")
    args = parser.parse_args()
    count = 0
    for latency in args.latency or [1, 10, 20]:
        for name, regions in cases():
            image = []
            for address, words in regions.items():
                image.append(f"@{address:x}")
                image.extend(word.to_bytes(4, "little").hex(" ") for word in words)
            data = f"CPU2026-OJ 1\n1000000 {latency}\n" + "\n".join(image) + "\n"
            run = subprocess.run([str(args.sim.resolve())], input=data, capture_output=True, text=True, timeout=60)
            if run.returncode != 0 or run.stdout.strip() != "0":
                raise SystemExit(f"FAIL {name} latency={latency}: {run.stdout} {run.stderr}")
            count += 1
        print(f"PASS directed RV32IM/full-address regressions latency={latency}", flush=True)
    print(f"{count} regressions passed")


if __name__ == "__main__":
    main()
