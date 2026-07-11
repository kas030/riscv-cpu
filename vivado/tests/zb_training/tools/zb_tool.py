#!/usr/bin/env python3
"""RV32 Zb 训练辅助工具：机器码编码、参考运算和定向自测。"""

from __future__ import annotations

import argparse
import sys
from typing import Callable


MASK32 = 0xFFFF_FFFF


def u32(value: int) -> int:
    return value & MASK32


def s32(value: int) -> int:
    value = u32(value)
    return value if value < 0x8000_0000 else value - 0x1_0000_0000


def parse_int(text: str) -> int:
    """接受十进制以及带 0x/0o/0b 前缀的整数。"""
    return int(text, 0)


def parse_reg(text: str) -> int:
    value = parse_int(text[1:]) if text.lower().startswith("x") else parse_int(text)
    check_unsigned("register", value, 5)
    return value


def check_unsigned(name: str, value: int, bits: int) -> None:
    if not 0 <= value < (1 << bits):
        raise ValueError(f"{name}={value} 超出无符号 {bits} 位范围")


def encode_r(funct7: int, rs2: int, rs1: int, funct3: int, rd: int,
             opcode: int = 0x33) -> int:
    """编码标准 R 型指令；所有字段均严格检查，避免静默截断。"""
    for name, value, bits in (
        ("funct7", funct7, 7), ("rs2", rs2, 5), ("rs1", rs1, 5),
        ("funct3", funct3, 3), ("rd", rd, 5), ("opcode", opcode, 7),
    ):
        check_unsigned(name, value, bits)
    return ((funct7 << 25) | (rs2 << 20) | (rs1 << 15) |
            (funct3 << 12) | (rd << 7) | opcode)


def encode_op_imm(imm12: int, rs1: int, funct3: int, rd: int,
                  opcode: int = 0x13) -> int:
    """编码 OP-IMM；imm12 可为 -2048..4095，正数也可直接给原始位型。"""
    if not -2048 <= imm12 <= 0xFFF:
        raise ValueError(f"imm12={imm12} 超出 -2048..4095 范围")
    for name, value, bits in (
        ("rs1", rs1, 5), ("funct3", funct3, 3), ("rd", rd, 5),
        ("opcode", opcode, 7),
    ):
        check_unsigned(name, value, bits)
    return (((imm12 & 0xFFF) << 20) | (rs1 << 15) |
            (funct3 << 12) | (rd << 7) | opcode)


def rol(a: int, b: int) -> int:
    n = b & 31
    return u32(a) if n == 0 else u32((u32(a) << n) | (u32(a) >> (32 - n)))


def ror(a: int, b: int) -> int:
    n = b & 31
    return u32(a) if n == 0 else u32((u32(a) >> n) | (u32(a) << (32 - n)))


def clz(a: int) -> int:
    return 32 if u32(a) == 0 else 32 - u32(a).bit_length()


def ctz(a: int) -> int:
    value = u32(a)
    return 32 if value == 0 else (value & -value).bit_length() - 1


def sext(value: int, bits: int) -> int:
    value &= (1 << bits) - 1
    sign = 1 << (bits - 1)
    return u32((value ^ sign) - sign)


def bit_index(b: int) -> int:
    return b & 31


def carryless_product(a: int, b: int) -> int:
    product = 0
    a = u32(a)
    b = u32(b)
    for bit in range(32):
        if (b >> bit) & 1:
            product ^= a << bit
    return product & 0xFFFF_FFFF_FFFF_FFFF


def reverse_bits_in_byte(value: int) -> int:
    result = 0
    for bit in range(8):
        result |= ((value >> bit) & 1) << (7 - bit)
    return result


def zip_bits(a: int) -> int:
    """RV32 zip：将低、高手字的位交错放入偶、奇数位。"""
    a = u32(a)
    result = 0
    for bit in range(16):
        result |= ((a >> bit) & 1) << (2 * bit)
        result |= ((a >> (bit + 16)) & 1) << (2 * bit + 1)
    return result


def unzip_bits(a: int) -> int:
    a = u32(a)
    result = 0
    for bit in range(16):
        result |= ((a >> (2 * bit)) & 1) << bit
        result |= ((a >> (2 * bit + 1)) & 1) << (bit + 16)
    return result


def xperm(a: int, b: int, element_bits: int) -> int:
    elements = 32 // element_bits
    element_mask = (1 << element_bits) - 1
    result = 0
    for out_index in range(elements):
        index = (u32(b) >> (out_index * element_bits)) & element_mask
        if index < elements:
            selected = (u32(a) >> (index * element_bits)) & element_mask
            result |= selected << (out_index * element_bits)
    return result


UnaryOp = Callable[[int], int]
BinaryOp = Callable[[int, int], int]

UNARY_OPS: dict[str, UnaryOp] = {
    "clz": clz,
    "ctz": ctz,
    "cpop": lambda a: u32(a).bit_count(),
    "sext.b": lambda a: sext(a, 8),
    "sext.h": lambda a: sext(a, 16),
    "zext.h": lambda a: a & 0xFFFF,
    "orc.b": lambda a: sum((0xFF if ((u32(a) >> (8 * i)) & 0xFF) else 0) << (8 * i)
                             for i in range(4)),
    "rev8": lambda a: int.from_bytes(u32(a).to_bytes(4, "little"), "big"),
    "brev8": lambda a: sum(reverse_bits_in_byte(u32(a) >> (8 * i)) << (8 * i)
                            for i in range(4)),
    "zip": zip_bits,
    "unzip": unzip_bits,
}

BINARY_OPS: dict[str, BinaryOp] = {
    "sh1add": lambda a, b: u32((u32(a) << 1) + u32(b)),
    "sh2add": lambda a, b: u32((u32(a) << 2) + u32(b)),
    "sh3add": lambda a, b: u32((u32(a) << 3) + u32(b)),
    "andn": lambda a, b: u32(a) & u32(~b),
    "orn": lambda a, b: u32(a) | u32(~b),
    "xnor": lambda a, b: u32(~(a ^ b)),
    "min": lambda a, b: u32(a if s32(a) < s32(b) else b),
    "max": lambda a, b: u32(a if s32(a) > s32(b) else b),
    "minu": lambda a, b: min(u32(a), u32(b)),
    "maxu": lambda a, b: max(u32(a), u32(b)),
    "rol": rol,
    "ror": ror,
    "rori": ror,
    "bclr": lambda a, b: u32(a) & u32(~(1 << bit_index(b))),
    "bclri": lambda a, b: u32(a) & u32(~(1 << bit_index(b))),
    "bext": lambda a, b: (u32(a) >> bit_index(b)) & 1,
    "bexti": lambda a, b: (u32(a) >> bit_index(b)) & 1,
    "binv": lambda a, b: u32(a) ^ (1 << bit_index(b)),
    "binvi": lambda a, b: u32(a) ^ (1 << bit_index(b)),
    "bset": lambda a, b: u32(a) | (1 << bit_index(b)),
    "bseti": lambda a, b: u32(a) | (1 << bit_index(b)),
    "clmul": lambda a, b: u32(carryless_product(a, b)),
    "clmulh": lambda a, b: u32(carryless_product(a, b) >> 32),
    "clmulr": lambda a, b: u32(carryless_product(a, b) >> 31),
    "pack": lambda a, b: (u32(a) & 0xFFFF) | ((u32(b) & 0xFFFF) << 16),
    "packh": lambda a, b: (u32(a) & 0xFF) | ((u32(b) & 0xFF) << 8),
    "xperm4": lambda a, b: xperm(a, b, 4),
    "xperm8": lambda a, b: xperm(a, b, 8),
}


def evaluate(name: str, a: int, b: int | None = None) -> int:
    name = name.lower()
    if name in UNARY_OPS:
        if b is not None:
            raise ValueError(f"{name} 是单操作数运算")
        return u32(UNARY_OPS[name](a))
    if name in BINARY_OPS:
        if b is None:
            raise ValueError(f"{name} 需要第二个操作数/立即数")
        return u32(BINARY_OPS[name](a, b))
    raise ValueError(f"未知运算 {name!r}；可用 list 查看支持列表")


def format_word(word: int) -> str:
    return f"0x{u32(word):08X}  .word 0x{u32(word):08X}"


def run_selftest() -> None:
    cases: list[tuple[str, int, int | None, int]] = [
        ("sh1add", 0x40000001, 3, 0x80000005),
        ("ror", 0x80000001, 1, 0xC0000000),
        ("cpop", 0xF0F0000F, None, 12),
        ("clz", 0, None, 32),
        ("ctz", 0x80000000, None, 31),
        ("bset", 0, 31, 0x80000000),
        ("bset", 0, 63, 0x80000000),
        ("clmul", 0xB, 0x6, 0x3A),
        ("pack", 0xAAAABBBB, 0xCCCCDDDD, 0xDDDDBBBB),
        ("brev8", 0x01234567, None, 0x80C4A2E6),
        ("xperm8", 0x44332211, 0x00010203, 0x11223344),
        ("xperm8", 0x44332211, 0x00010403, 0x11220044),
        ("min", 0xFFFFFFFF, 1, 0xFFFFFFFF),
        ("minu", 0xFFFFFFFF, 1, 1),
        ("orc.b", 0x00120080, None, 0x00FF00FF),
        ("rev8", 0x01234567, None, 0x67452301),
    ]
    for name, a, b, expected in cases:
        actual = evaluate(name, a, b)
        if actual != expected:
            raise AssertionError(
                f"{name}(0x{a:08X}{'' if b is None else f', 0x{b:X}'}) "
                f"得到 0x{actual:08X}，期望 0x{expected:08X}"
            )

    # 编码公式和互逆性质用于发现字段位置、zip/unzip 循环方向错误。
    assert encode_r(0, 3, 2, 0, 1) == 0x003100B3
    assert encode_op_imm(-1, 2, 0, 1) == 0xFFF10093
    for value in (0, 1, 0x80000000, 0x01234567, 0xFFFFFFFF):
        assert unzip_bits(zip_bits(value)) == u32(value)
        assert rol(ror(value, 7), 7) == u32(value)
    print(f"自测通过：{len(cases)} 个定向向量、2 个编码向量及互逆性质检查")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    enc_r = sub.add_parser("encode-r", help="编码 R 型指令")
    enc_r.add_argument("--funct7", type=parse_int, required=True)
    enc_r.add_argument("--rs2", type=parse_reg, required=True)
    enc_r.add_argument("--rs1", type=parse_reg, required=True)
    enc_r.add_argument("--funct3", type=parse_int, required=True)
    enc_r.add_argument("--rd", type=parse_reg, required=True)
    enc_r.add_argument("--opcode", type=parse_int, default=0x33)

    enc_i = sub.add_parser("encode-op-imm", help="编码 OP-IMM 指令")
    enc_i.add_argument("--imm12", type=parse_int, required=True,
                       help="-2048..4095；可直接输入完整 12 位编码")
    enc_i.add_argument("--rs1", type=parse_reg, required=True)
    enc_i.add_argument("--funct3", type=parse_int, required=True)
    enc_i.add_argument("--rd", type=parse_reg, required=True)
    enc_i.add_argument("--opcode", type=parse_int, default=0x13)

    calc = sub.add_parser("eval", help="计算 RV32 Zb 参考结果")
    calc.add_argument("operation")
    calc.add_argument("rs1", type=parse_int)
    calc.add_argument("rs2", type=parse_int, nargs="?")

    sub.add_parser("list", help="列出支持的参考运算")
    sub.add_parser("selftest", help="运行内置定向自测")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "encode-r":
            print(format_word(encode_r(args.funct7, args.rs2, args.rs1,
                                       args.funct3, args.rd, args.opcode)))
        elif args.command == "encode-op-imm":
            print(format_word(encode_op_imm(args.imm12, args.rs1, args.funct3,
                                            args.rd, args.opcode)))
        elif args.command == "eval":
            print(f"0x{evaluate(args.operation, args.rs1, args.rs2):08X}")
        elif args.command == "list":
            print("单操作数：" + " ".join(sorted(UNARY_OPS)))
            print("双操作数/立即数：" + " ".join(sorted(BINARY_OPS)))
        else:
            run_selftest()
    except (ValueError, AssertionError) as error:
        print(f"错误：{error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
