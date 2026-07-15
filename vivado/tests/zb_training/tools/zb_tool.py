#!/usr/bin/env python3
"""RV32 Zb 训练辅助工具：机器码编码、参考运算和定向自测。"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Callable


MASK32 = 0xFFFF_FFFF
R_MASK = 0xFE00_707F
FIXED_I_MASK = 0xFFF0_707F


@dataclass(frozen=True)
class InstructionSpec:
    """生成单条 Zb 指令测试所需的最小 ISA 描述。"""

    name: str
    extension: str
    form: str
    match: int
    mask: int
    vectors: tuple[tuple[int, int | None], ...]
    aliases: tuple[str, ...] = ()


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


def r_match(funct7: int, funct3: int) -> int:
    return (funct7 << 25) | (funct3 << 12) | 0x33


def i_match(imm12: int, funct3: int) -> int:
    return (imm12 << 20) | (funct3 << 12) | 0x13


def i_shamt_match(funct7: int, funct3: int) -> int:
    return (funct7 << 25) | (funct3 << 12) | 0x13


LOGIC_VECTORS = (
    (0x0000_0000, 0x0000_0000),
    (0xFFFF_FFFF, 0x0000_0000),
    (0xAA55_AA55, 0x0F0F_F0F0),
    (0x8000_0001, 0xFFFF_FFFF),
)
MINMAX_VECTORS = (
    (0xFFFF_FFFF, 1),
    (0x8000_0000, 0x7FFF_FFFF),
    (7, 7),
    (0, 0xFFFF_FFFF),
)
ROTATE_VECTORS = (
    (0x8000_0001, 0),
    (0x8000_0001, 1),
    (0x8000_0001, 31),
    (0x0123_4567, 32),
)
ROTATE_IMM_VECTORS = (
    (0x8000_0001, 0),
    (0x8000_0001, 1),
    (0x0123_4567, 15),
    (0x8000_0001, 31),
)
CLMUL_VECTORS = (
    (0, 0xFFFF_FFFF),
    (0xB, 0x6),
    (0x8000_0000, 2),
    (0xFFFF_FFFF, 0xFFFF_FFFF),
)
BIT_REG_VECTORS = (
    (0x8000_0001, 0),
    (0x8000_0001, 31),
    (0x0123_4567, 32),
    (0x89AB_CDEF, 63),
)
BIT_IMM_VECTORS = (
    (0x8000_0001, 0),
    (0x8000_0001, 1),
    (0x0123_4567, 15),
    (0x89AB_CDEF, 31),
)


SPECS = (
    # Zba
    InstructionSpec("sh1add", "Zba", "r", r_match(0x10, 2), R_MASK,
                    ((0, 0), (3, 100), (0x4000_0001, 3), (0xFFFF_FFFF, 1))),
    InstructionSpec("sh2add", "Zba", "r", r_match(0x10, 4), R_MASK,
                    ((0, 0), (3, 100), (0x2000_0001, 3), (0xFFFF_FFFF, 1))),
    InstructionSpec("sh3add", "Zba", "r", r_match(0x10, 6), R_MASK,
                    ((0, 0), (3, 100), (0x1000_0001, 3), (0xFFFF_FFFF, 1))),

    # Zbb
    InstructionSpec("andn", "Zbb", "r", r_match(0x20, 7), R_MASK, LOGIC_VECTORS),
    InstructionSpec("orn", "Zbb", "r", r_match(0x20, 6), R_MASK, LOGIC_VECTORS),
    InstructionSpec("xnor", "Zbb", "r", r_match(0x20, 4), R_MASK, LOGIC_VECTORS),
    InstructionSpec("clz", "Zbb", "i_fixed", i_match(0x600, 1), FIXED_I_MASK,
                    ((0, None), (1, None), (0x8000_0000, None), (0x00F0_0000, None))),
    InstructionSpec("ctz", "Zbb", "i_fixed", i_match(0x601, 1), FIXED_I_MASK,
                    ((0, None), (1, None), (0x8000_0000, None), (0x0010_0000, None))),
    InstructionSpec("cpop", "Zbb", "i_fixed", i_match(0x602, 1), FIXED_I_MASK,
                    ((0, None), (0xFFFF_FFFF, None), (0xAAAA_AAAA, None),
                     (0xF0F0_000F, None))),
    InstructionSpec("min", "Zbb", "r", r_match(0x05, 4), R_MASK, MINMAX_VECTORS),
    InstructionSpec("max", "Zbb", "r", r_match(0x05, 6), R_MASK, MINMAX_VECTORS),
    InstructionSpec("minu", "Zbb", "r", r_match(0x05, 5), R_MASK, MINMAX_VECTORS),
    InstructionSpec("maxu", "Zbb", "r", r_match(0x05, 7), R_MASK, MINMAX_VECTORS),
    InstructionSpec("sext.b", "Zbb", "i_fixed", i_match(0x604, 1), FIXED_I_MASK,
                    ((0, None), (0x7F, None), (0x80, None), (0x0000_8080, None))),
    InstructionSpec("sext.h", "Zbb", "i_fixed", i_match(0x605, 1), FIXED_I_MASK,
                    ((0, None), (0x7FFF, None), (0x8000, None), (0x1234_8080, None))),
    InstructionSpec("zext.h", "Zbb", "r_fixed", r_match(0x04, 4), FIXED_I_MASK,
                    ((0, None), (0xFFFF_FFFF, None), (0x8000, None),
                     (0x1234_8080, None))),
    InstructionSpec("rol", "Zbb", "r", r_match(0x30, 1), R_MASK, ROTATE_VECTORS),
    InstructionSpec("ror", "Zbb", "r", r_match(0x30, 5), R_MASK, ROTATE_VECTORS),
    InstructionSpec("rori", "Zbb", "i_shamt", i_shamt_match(0x30, 5),
                    R_MASK, ROTATE_IMM_VECTORS),
    InstructionSpec("orc.b", "Zbb", "i_fixed", i_match(0x287, 5), FIXED_I_MASK,
                    ((0, None), (0xFFFF_FFFF, None), (0x0012_0080, None),
                     (0x0100_FF00, None))),
    InstructionSpec("rev8", "Zbb", "i_fixed", i_match(0x698, 5), FIXED_I_MASK,
                    ((0, None), (0xFFFF_FFFF, None), (0x0123_4567, None),
                     (0x8000_0001, None))),

    # Zbc
    InstructionSpec("clmul", "Zbc", "r", r_match(0x05, 1), R_MASK, CLMUL_VECTORS),
    InstructionSpec("clmulh", "Zbc", "r", r_match(0x05, 3), R_MASK, CLMUL_VECTORS),
    InstructionSpec("clmulr", "Zbc", "r", r_match(0x05, 2), R_MASK, CLMUL_VECTORS),

    # Zbs
    InstructionSpec("bclr", "Zbs", "r", r_match(0x24, 1), R_MASK, BIT_REG_VECTORS),
    InstructionSpec("bclri", "Zbs", "i_shamt", i_shamt_match(0x24, 1),
                    R_MASK, BIT_IMM_VECTORS),
    InstructionSpec("bext", "Zbs", "r", r_match(0x24, 5), R_MASK, BIT_REG_VECTORS),
    InstructionSpec("bexti", "Zbs", "i_shamt", i_shamt_match(0x24, 5),
                    R_MASK, BIT_IMM_VECTORS),
    InstructionSpec("binv", "Zbs", "r", r_match(0x34, 1), R_MASK, BIT_REG_VECTORS),
    InstructionSpec("binvi", "Zbs", "i_shamt", i_shamt_match(0x34, 1),
                    R_MASK, BIT_IMM_VECTORS),
    InstructionSpec("bset", "Zbs", "r", r_match(0x14, 1), R_MASK, BIT_REG_VECTORS),
    InstructionSpec("bseti", "Zbs", "i_shamt", i_shamt_match(0x14, 1),
                    R_MASK, BIT_IMM_VECTORS),

    # Zbkb 中不与 Zbb 重复的 RV32 指令
    InstructionSpec("pack", "Zbkb", "r", r_match(0x04, 4), R_MASK,
                    ((0, 0), (0xAAAA_BBBB, 0xCCCC_DDDD),
                     (0xFFFF_0000, 0x0000_FFFF), (0x1234_5678, 0x9ABC_DEF0))),
    InstructionSpec("packh", "Zbkb", "r", r_match(0x04, 7), R_MASK,
                    ((0, 0), (0xAAAA_BBCC, 0xDDDD_EEFF),
                     (0xFFFF_0000, 0x0000_FFFF), (0x1234_5678, 0x9ABC_DEF0))),
    InstructionSpec("brev8", "Zbkb", "i_fixed", i_match(0x687, 5), FIXED_I_MASK,
                    ((0, None), (0xFFFF_FFFF, None), (0x0123_4567, None),
                     (0x8000_0001, None)), aliases=("rev.b",)),
    InstructionSpec("zip", "Zbkb", "i_fixed", i_match(0x08F, 1), FIXED_I_MASK,
                    ((0, None), (0xFFFF_FFFF, None), (0x0000_FFFF, None),
                     (0x0123_4567, None))),
    InstructionSpec("unzip", "Zbkb", "i_fixed", i_match(0x08F, 5), FIXED_I_MASK,
                    ((0, None), (0xFFFF_FFFF, None), (0x5555_5555, None),
                     (0x0123_4567, None))),

    # Zbkx
    InstructionSpec("xperm4", "Zbkx", "r", r_match(0x14, 2), R_MASK,
                    ((0x7654_3210, 0x0123_4567), (0x7654_3210, 0x7654_3210),
                     (0x7654_3210, 0xFFFF_FFFF), (0x7654_3210, 0xF120_4567)),
                    aliases=("xperm.n",)),
    InstructionSpec("xperm8", "Zbkx", "r", r_match(0x14, 4), R_MASK,
                    ((0x4433_2211, 0x0001_0203), (0x4433_2211, 0x0302_0100),
                     (0x4433_2211, 0xFFFF_FFFF), (0x4433_2211, 0x0401_0203)),
                    aliases=("xperm.b",)),
)

SPEC_BY_NAME: dict[str, InstructionSpec] = {}
for _spec in SPECS:
    SPEC_BY_NAME[_spec.name] = _spec
    for _alias in _spec.aliases:
        SPEC_BY_NAME[_alias] = _spec


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


def resolve_spec(name: str) -> InstructionSpec:
    try:
        return SPEC_BY_NAME[name.lower()]
    except KeyError as error:
        choices = " ".join(spec.name for spec in SPECS)
        raise ValueError(f"未知指令 {name!r}；可用指令：{choices}") from error


def override_encoding(spec: InstructionSpec, sample_word: int) -> InstructionSpec:
    """从题面样例机器码提取该指令形式中的固定编码位。"""
    if not 0 <= sample_word <= MASK32:
        raise ValueError("--encoding 必须是 0..0xFFFFFFFF 的 32 位机器码")
    if (sample_word & 0b11) != 0b11:
        raise ValueError("--encoding 不是标准 32 位指令（最低两位必须为 11）")
    return replace(spec, match=sample_word & spec.mask)


def encode_instruction(spec: InstructionSpec, rd: int, rs1: int,
                       operand: int | None = None) -> int:
    """按描述编码一条目标指令；operand 是 rs2 或 5 位立即数。"""
    check_unsigned("rd", rd, 5)
    check_unsigned("rs1", rs1, 5)
    word = spec.match & spec.mask
    word |= rd << 7
    word |= rs1 << 15
    if spec.form == "r":
        if operand is None:
            raise ValueError(f"{spec.name} 需要 rs2")
        check_unsigned("rs2", operand, 5)
        word |= operand << 20
    elif spec.form == "i_shamt":
        if operand is None:
            raise ValueError(f"{spec.name} 需要 5 位立即数")
        check_unsigned("shamt/index", operand, 5)
        word |= operand << 20
    elif spec.form not in ("i_fixed", "r_fixed"):
        raise ValueError(f"{spec.name} 使用未知指令形式 {spec.form!r}")
    elif operand is not None:
        raise ValueError(f"{spec.name} 是单源固定编码指令，不接受第二操作数")
    return u32(word)


def target_word(spec: InstructionSpec, rd: int, rs1: int,
                operand_value: int | None) -> int:
    if spec.form == "r":
        # 测试程序固定以 x6 承载第二源，值由 operand_value 初始化。
        return encode_instruction(spec, rd, rs1, 6)
    if spec.form == "i_shamt":
        if operand_value is None:
            raise ValueError(f"{spec.name} 缺少立即数测试值")
        return encode_instruction(spec, rd, rs1, operand_value)
    return encode_instruction(spec, rd, rs1)


def emit_target(spec: InstructionSpec, rd: int, rs1: int,
                operand_value: int | None, indent: str = "    ") -> str:
    word = target_word(spec, rd, rs1, operand_value)
    return f"{indent}.word 0x{word:08X}    /* {spec.name} */"


def emit_inputs(spec: InstructionSpec, a: int, b: int | None,
                lines: list[str]) -> None:
    lines.append(f"    li      x5, 0x{u32(a):08X}")
    if spec.form == "r":
        if b is None:
            raise ValueError(f"{spec.name} 的 R 型向量缺少第二操作数")
        lines.append(f"    li      x6, 0x{u32(b):08X}")


def emit_compare(register: int, expected: int, lines: list[str]) -> None:
    lines.append(f"    li      x28, 0x{u32(expected):08X}")
    lines.append(f"    bne     x{register}, x28, fail")


def collision_test_lines(spec: InstructionSpec) -> list[str]:
    """生成与目标 funct3 接近的 RV32I 运算及一条 RV32M 基线。"""
    funct3 = (spec.match >> 12) & 0x7
    lines = [
        "", "    /* ---------- 邻近译码与 RV32M 基线 ---------- */",
        "    li      x5, 0x80000001",
    ]
    if spec.form in ("r", "r_fixed"):
        r_ops = {
            0: ("add", 0x8000_0002),
            1: ("sll", 0x0000_0002),
            2: ("slt", 0x0000_0001),
            3: ("sltu", 0x0000_0000),
            4: ("xor", 0x8000_0000),
            5: ("srl", 0x4000_0000),
            6: ("or", 0x8000_0001),
            7: ("and", 0x0000_0001),
        }
        mnemonic, expected = r_ops[funct3]
        lines.extend((
            "    li      x6, 1",
            f"    {mnemonic:<7} x7, x5, x6",
        ))
    else:
        i_ops = {
            0: ("addi", 0x8000_0002),
            1: ("slli", 0x0000_0002),
            2: ("slti", 0x0000_0001),
            3: ("sltiu", 0x0000_0000),
            4: ("xori", 0x8000_0000),
            5: ("srli", 0x4000_0000),
            6: ("ori", 0x8000_0001),
            7: ("andi", 0x0000_0001),
        }
        mnemonic, expected = i_ops[funct3]
        lines.append(f"    {mnemonic:<7} x7, x5, 1")
    emit_compare(7, expected, lines)
    lines.extend((
        "    li      x5, 7",
        "    li      x6, 9",
        "    mul     x7, x5, x6",
    ))
    emit_compare(7, 63, lines)
    return lines


def render_test_program(spec: InstructionSpec) -> str:
    """生成只依赖 RV32IM 汇编器的完整自检程序。"""
    lines = [
        "/* =============================================================",
        f" * 自动生成：{spec.extension} {spec.name} 单指令 CPU 测试",
        f" * 固定编码：match=0x{spec.match:08X}, mask=0x{spec.mask:08X}",
        " * 目标指令均使用 .word，汇编器无需支持 Zb 助记符。",
        " * ============================================================= */",
        "    .option norvc",
        "    .section .text.init",
        "    .globl _start",
        "_start:",
        "    /* ---------- 定向功能向量 ---------- */",
    ]

    for index, (a, b) in enumerate(spec.vectors, start=1):
        expected = evaluate(spec.name, a, b)
        lines.append(f"    /* vector {index}: A=0x{u32(a):08X}" +
                     (" */" if b is None else f", B=0x{u32(b):08X} */"))
        emit_inputs(spec, a, b, lines)
        lines.append(emit_target(spec, 7, 5, b))
        emit_compare(7, expected, lines)

    a, b = spec.vectors[-1]
    expected = evaluate(spec.name, a, b)

    lines.extend(("", "    /* ---------- rd 与源寄存器重叠 ---------- */"))
    emit_inputs(spec, a, b, lines)
    lines.append(emit_target(spec, 5, 5, b))
    emit_compare(5, expected, lines)
    if spec.form == "r":
        emit_inputs(spec, a, b, lines)
        lines.append(emit_target(spec, 6, 5, b))
        emit_compare(6, expected, lines)

    lines.extend(("", "    /* ---------- 写 x0 必须无副作用 ---------- */"))
    emit_inputs(spec, a, b, lines)
    lines.append(emit_target(spec, 0, 5, b))
    lines.append("    li      x28, 0")
    lines.append("    bne     x0, x28, fail")

    lines.extend(("", "    /* ---------- 生产者前递与结果立即消费 ---------- */"))
    if spec.form == "r":
        if b is None:
            raise ValueError(f"{spec.name} 的 R 型向量缺少第二操作数")
        lines.append(f"    li      x6, 0x{u32(b):08X}")
    lines.append(f"    li      x5, 0x{u32(a - 1):08X}")
    lines.append("    addi    x5, x5, 1")
    lines.append(emit_target(spec, 7, 5, b))
    lines.append("    addi    x8, x7, 0")
    emit_compare(8, expected, lines)

    lines.extend(("", "    /* ---------- BRAM load-use ---------- */",
                  "    lui     x29, 0x80100",
                  "    addi    x29, x29, 0x200",
                  f"    li      x5, 0x{u32(a):08X}",
                  "    sw      x5, 0(x29)"))
    if spec.form == "r":
        lines.append(f"    li      x6, 0x{u32(b if b is not None else 0):08X}")
    lines.append("    lw      x5, 0(x29)")
    lines.append(emit_target(spec, 7, 5, b))
    emit_compare(7, expected, lines)

    lines.extend(("", "    /* ---------- 双发射：目标位于槽 0 ---------- */"))
    emit_inputs(spec, a, b, lines)
    lines.extend((
        "    li      x29, 3",
        "    li      x30, 0",
        "    .balign 8",
        "dual_slot0_loop:",
        emit_target(spec, 7, 5, b),
        "    addi    x30, x30, 1",
        "    addi    x29, x29, -1",
        "    bne     x29, x0, dual_slot0_loop",
    ))
    emit_compare(7, expected, lines)
    emit_compare(30, 3, lines)

    lines.extend(("", "    /* ---------- 双发射：目标位于槽 1 ---------- */"))
    emit_inputs(spec, a, b, lines)
    lines.extend((
        "    li      x29, 3",
        "    li      x30, 0",
        "    .balign 8",
        "dual_slot1_loop:",
        "    addi    x30, x30, 1",
        emit_target(spec, 7, 5, b),
        "    addi    x29, x29, -1",
        "    bne     x29, x0, dual_slot1_loop",
    ))
    emit_compare(7, expected, lines)
    emit_compare(30, 3, lines)

    lines.extend(collision_test_lines(spec))
    lines.extend((
        "", "pass:",
        "    li      a0, 0xC0DEC0DE",
        "    j       report",
        "fail:",
        "    li      a0, 0xDEADBEEF",
        "report:",
        "    lui     t0, 0x80200",
        "    addi    t0, t0, 0x40",
        "    sw      a0, 0(t0)",
        "1:  j       1b",
        "",
    ))
    return "\n".join(lines)


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

    assert len(SPECS) == 39
    assert len({spec.name for spec in SPECS}) == 39
    vector_count = 0
    for spec in SPECS:
        assert (spec.match & ~spec.mask) == 0
        assert (spec.match & 0b11) == 0b11
        for a, b in spec.vectors:
            evaluate(spec.name, a, b)
            vector_count += 1
            operand = 6 if spec.form == "r" else b
            word = encode_instruction(spec, 7, 5, operand)
            assert (word & spec.mask) == spec.match
            assert ((word >> 7) & 0x1F) == 7
            assert ((word >> 15) & 0x1F) == 5
        generated = render_test_program(spec)
        assert f"自动生成：{spec.extension} {spec.name}" in generated
        assert "0xC0DEC0DE" in generated
        assert "0xDEADBEEF" in generated
        assert "dual_slot0_loop" in generated
        assert "dual_slot1_loop" in generated
        assert "lw      x5, 0(x29)" in generated

    # 与仓库现有 8 个训练样例交叉核对标准机器码。
    known_words = {
        "sh1add": 0x2062_A3B3,
        "ror": 0x6062_D3B3,
        "cpop": 0x6022_9393,
        "bset": 0x2862_93B3,
        "clmulh": 0x0A62_B3B3,
        "pack": 0x0862_C3B3,
        "brev8": 0x6872_D393,
        "xperm8": 0x2862_C3B3,
    }
    for name, expected_word in known_words.items():
        spec = resolve_spec(name)
        operand = 6 if spec.form == "r" else None
        assert encode_instruction(spec, 7, 5, operand) == expected_word

    assert resolve_spec("rev.b").name == "brev8"
    assert resolve_spec("xperm.n").name == "xperm4"
    assert resolve_spec("xperm.b").name == "xperm8"

    base = resolve_spec("sh1add")
    sample = encode_instruction(base, 7, 5, 6) ^ (1 << 25)
    overridden = override_encoding(base, sample)
    rebuilt = encode_instruction(overridden, 1, 2, 3)
    assert (rebuilt & overridden.mask) == (sample & overridden.mask)
    assert ((rebuilt >> 7) & 0x1F) == 1
    assert ((rebuilt >> 15) & 0x1F) == 2
    assert ((rebuilt >> 20) & 0x1F) == 3

    print(
        f"自测通过：39 条候选、{vector_count} 个生成向量、"
        f"{len(cases)} 个参考向量、8 个样例机器码及编码覆盖检查"
    )


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

    generate = sub.add_parser("generate", help="生成指定 Zb 指令的完整 CPU 测试")
    generate.add_argument("instruction", help="候选指令名或支持的别名")
    generate.add_argument("--output", type=Path, required=True,
                          help="输出 .S 文件路径")
    generate.add_argument(
        "--encoding", type=parse_int,
        help="题面给出的任意寄存器实例机器码；仅提取该形式的固定编码位",
    )

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
        elif args.command == "generate":
            spec = resolve_spec(args.instruction)
            if args.encoding is not None:
                spec = override_encoding(spec, args.encoding)
            program = render_test_program(spec)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with args.output.open("w", encoding="utf-8", newline="\n") as output:
                output.write(program)
            print(
                f"已生成 {spec.extension} {spec.name}: {args.output} "
                f"(match=0x{spec.match:08X}, mask=0x{spec.mask:08X})"
            )
        elif args.command == "list":
            for extension in ("Zba", "Zbb", "Zbc", "Zbs", "Zbkb", "Zbkx"):
                names = []
                for spec in SPECS:
                    if spec.extension == extension:
                        alias_text = ("/" + "/".join(spec.aliases)) if spec.aliases else ""
                        names.append(spec.name + alias_text)
                print(f"{extension}: " + " ".join(names))
        else:
            run_selftest()
    except (ValueError, AssertionError) as error:
        print(f"错误：{error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
