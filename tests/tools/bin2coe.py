#!/usr/bin/env python3
"""
bin2coe.py —— 把 RISC-V 工具链产出的 .bin 转成 Vivado .coe / .mif

用法：
    python3 bin2coe.py <input.bin> <output.coe>           # 默认 .coe
    python3 bin2coe.py <input.bin> <output.mif> --mif      # 输出 .mif
    python3 bin2coe.py <input.bin> <out> --depth 4096      # 指定深度，余位补 0

约定：
    - 输入 .bin 视为 RV32 指令流，4 字节一条，小端序
    - 输出 32 位每行
"""
import sys
import os
import argparse


def main() -> int:
    p = argparse.ArgumentParser(description="RISC-V .bin → .coe/.mif converter")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--mif", action="store_true",
                   help="output Quartus-style .mif (default is Xilinx .coe)")
    p.add_argument("--depth", type=int, default=4096,
                   help="memory depth (rows). Excess rows zero-filled. Default: 4096")
    p.add_argument("--width", type=int, default=32, choices=[8, 16, 32],
                   help="data width in bits. Default: 32")
    args = p.parse_args()

    with open(args.input, "rb") as f:
        data = f.read()

    bytes_per_word = args.width // 8
    if len(data) % bytes_per_word != 0:
        # Pad with zeros to nearest word boundary
        data += b"\x00" * (bytes_per_word - (len(data) % bytes_per_word))

    words = []
    for i in range(0, len(data), bytes_per_word):
        chunk = data[i:i + bytes_per_word]
        # little-endian
        w = int.from_bytes(chunk, byteorder="little")
        words.append(w)

    if len(words) > args.depth:
        sys.stderr.write(f"WARN: {args.input} has {len(words)} words, "
                         f"exceeds depth {args.depth}. Truncating.\n")
        words = words[:args.depth]
    while len(words) < args.depth:
        words.append(0)

    fmt = f"0{args.width // 4}X"  # uppercase hex, padded
    with open(args.output, "w") as f:
        if args.mif:
            f.write(f"WIDTH={args.width};\n")
            f.write(f"DEPTH={args.depth};\n")
            f.write("ADDRESS_RADIX=HEX;\n")
            f.write("DATA_RADIX=HEX;\n")
            f.write("CONTENT BEGIN\n")
            for addr, w in enumerate(words):
                f.write(f"    {addr:04X} : {w:{fmt}};\n")
            f.write("END;\n")
        else:
            f.write("memory_initialization_radix=16;\n")
            f.write("memory_initialization_vector=\n")
            for i, w in enumerate(words):
                sep = ";" if i == len(words) - 1 else ","
                f.write(f"{w:{fmt}}{sep}\n")

    print(f"OK: {len(words)} words → {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
