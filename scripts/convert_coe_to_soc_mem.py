#!/usr/bin/env python3
"""Convert Vivado COE files to this SoC's $readmemh files."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def read_coe_words(path: Path) -> list[int]:
    text = path.read_text(encoding="utf-8-sig")
    radix_match = re.search(r"memory_initialization_radix\s*=\s*(\d+)\s*;", text, re.I)
    if not radix_match:
        raise ValueError(f"{path}: missing memory_initialization_radix")
    radix = int(radix_match.group(1))
    if radix not in (2, 10, 16):
        raise ValueError(f"{path}: unsupported radix {radix}")

    vector_match = re.search(
        r"memory_initialization_vector\s*=\s*(.*?);",
        text,
        re.I | re.S,
    )
    if not vector_match:
        raise ValueError(f"{path}: missing memory_initialization_vector")

    tokens = re.findall(r"[0-9a-fA-F_xXzZ]+", vector_match.group(1))
    words: list[int] = []
    for token in tokens:
        clean = token.replace("_", "")
        if any(ch in clean.lower() for ch in ("x", "z")):
            raise ValueError(f"{path}: unknown value token {token!r} is not supported")
        value = int(clean, radix)
        if value > 0xFFFF_FFFF:
            raise ValueError(f"{path}: value {token!r} exceeds 32 bits")
        words.append(value)
    return words


def write_irom_mem(words: list[int], path: Path) -> None:
    padded = list(words)
    while len(padded) % 4:
        padded.append(0x0000_0013)

    lines = []
    for idx in range(0, len(padded), 4):
        block = (
            (padded[idx + 3] << 96)
            | (padded[idx + 2] << 64)
            | (padded[idx + 1] << 32)
            | padded[idx + 0]
        )
        lines.append(f"{block:032x}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def write_dram_mem(words: list[int], path: Path) -> None:
    path.write_text("".join(f"{word:08x}\n" for word in words), encoding="ascii")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--irom-coe", type=Path, required=True)
    parser.add_argument("--dram-coe", type=Path, required=True)
    parser.add_argument("--irom-out", type=Path, required=True)
    parser.add_argument("--dram-out", type=Path, required=True)
    args = parser.parse_args()

    irom_words = read_coe_words(args.irom_coe)
    dram_words = read_coe_words(args.dram_coe)
    write_irom_mem(irom_words, args.irom_out)
    write_dram_mem(dram_words, args.dram_out)
    print(f"IROM words={len(irom_words)} blocks={(len(irom_words) + 3) // 4} -> {args.irom_out}")
    print(f"DRAM words={len(dram_words)} -> {args.dram_out}")


if __name__ == "__main__":
    main()
