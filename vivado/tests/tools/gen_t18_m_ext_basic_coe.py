#!/usr/bin/env python3
"""
Generate a standalone RV32IM COE image for t18_m_ext_basic without relying on
an external RISC-V toolchain.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass


PASS_MAGIC = 0xC0DEC0DE
FAIL_MAGIC = 0xDEADBEEF
LED_ADDR = 0x8020_0040
IROM_DEPTH = 4096


def u32(value: int) -> int:
    return value & 0xFFFF_FFFF


def s32(value: int) -> int:
    value &= 0xFFFF_FFFF
    return value if value < 0x8000_0000 else value - 0x1_0000_0000


def check_range(name: str, value: int, bits: int) -> None:
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    if not (lo <= value <= hi):
        raise ValueError(f"{name}={value} out of signed {bits}-bit range")


def encode_r(funct7: int, rs2: int, rs1: int, funct3: int, rd: int, opcode: int = 0x33) -> int:
    return (
        ((funct7 & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_i(imm: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    check_range("imm", imm, 12)
    return (
        ((imm & 0xFFF) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_s(imm: int, rs2: int, rs1: int, funct3: int, opcode: int = 0x23) -> int:
    check_range("imm", imm, 12)
    imm_u = imm & 0xFFF
    return (
        (((imm_u >> 5) & 0x7F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | ((imm_u & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def encode_b(offset: int, rs2: int, rs1: int, funct3: int, opcode: int = 0x63) -> int:
    if offset % 2 != 0:
        raise ValueError(f"branch offset must be 2-byte aligned, got {offset}")
    check_range("offset", offset, 13)
    imm = offset & 0x1FFF
    return (
        (((imm >> 12) & 0x1) << 31)
        | (((imm >> 5) & 0x3F) << 25)
        | ((rs2 & 0x1F) << 20)
        | ((rs1 & 0x1F) << 15)
        | ((funct3 & 0x7) << 12)
        | (((imm >> 1) & 0xF) << 8)
        | (((imm >> 11) & 0x1) << 7)
        | (opcode & 0x7F)
    )


def encode_u(imm20: int, rd: int, opcode: int) -> int:
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F)


def encode_j(offset: int, rd: int, opcode: int = 0x6F) -> int:
    if offset % 2 != 0:
        raise ValueError(f"jump offset must be 2-byte aligned, got {offset}")
    check_range("offset", offset, 21)
    imm = offset & 0x1F_FFFF
    return (
        (((imm >> 20) & 0x1) << 31)
        | (((imm >> 1) & 0x3FF) << 21)
        | (((imm >> 11) & 0x1) << 20)
        | (((imm >> 12) & 0xFF) << 12)
        | ((rd & 0x1F) << 7)
        | (opcode & 0x7F)
    )


def addi(rd: int, rs1: int, imm: int) -> int:
    return encode_i(imm, rs1, 0b000, rd, 0x13)


def lui(rd: int, imm20: int) -> int:
    return encode_u(imm20, rd, 0x37)


def sw(rs2: int, imm: int, rs1: int) -> int:
    return encode_s(imm, rs2, rs1, 0b010)


def bne(rs1: int, rs2: int, offset: int) -> int:
    return encode_b(offset, rs2, rs1, 0b001)


def jal(rd: int, offset: int) -> int:
    return encode_j(offset, rd)


def m_op(funct3: int, rd: int, rs1: int, rs2: int) -> int:
    return encode_r(0b0000001, rs2, rs1, funct3, rd)


@dataclass
class PatchRef:
    index: int
    kind: str
    rs1: int | None
    rs2: int | None
    rd: int | None
    funct3: int | None
    label: str


class Program:
    def __init__(self) -> None:
        self.words: list[int] = []
        self.labels: dict[str, int] = {}
        self.patches: list[PatchRef] = []

    def pc(self) -> int:
        return len(self.words) * 4

    def label(self, name: str) -> None:
        self.labels[name] = self.pc()

    def emit(self, word: int) -> None:
        self.words.append(u32(word))

    def branch_bne(self, rs1: int, rs2: int, label: str) -> None:
        self.patches.append(PatchRef(len(self.words), "bne", rs1, rs2, None, 0b001, label))
        self.words.append(0)

    def jump(self, label: str) -> None:
        self.patches.append(PatchRef(len(self.words), "jal", None, None, 0, None, label))
        self.words.append(0)

    def resolve(self) -> None:
        for patch in self.patches:
            target = self.labels[patch.label]
            here = patch.index * 4
            offset = target - here
            if patch.kind == "bne":
                self.words[patch.index] = bne(patch.rs1, patch.rs2, offset)
            elif patch.kind == "jal":
                self.words[patch.index] = jal(patch.rd or 0, offset)
            else:
                raise ValueError(f"unknown patch kind: {patch.kind}")


def emit_li(prog: Program, rd: int, value: int) -> None:
    value = s32(value)
    if -2048 <= value <= 2047:
        prog.emit(addi(rd, 0, value))
        return

    upper = (u32(value) + 0x800) >> 12
    lower = s32(u32(value) - ((upper & 0xFFFFF) << 12))
    prog.emit(lui(rd, upper))
    if lower != 0:
        prog.emit(addi(rd, rd, lower))


def build_program() -> list[int]:
    prog = Program()

    emit_li(prog, 5, 7)
    emit_li(prog, 6, -3)
    prog.emit(m_op(0b000, 7, 5, 6))
    emit_li(prog, 28, -21)
    prog.branch_bne(7, 28, "fail")

    emit_li(prog, 5, -1)
    emit_li(prog, 6, 2)
    prog.emit(m_op(0b001, 7, 5, 6))
    emit_li(prog, 28, -1)
    prog.branch_bne(7, 28, "fail")

    prog.emit(m_op(0b010, 7, 5, 6))
    emit_li(prog, 28, -1)
    prog.branch_bne(7, 28, "fail")

    emit_li(prog, 5, -1)
    emit_li(prog, 6, 2)
    prog.emit(m_op(0b011, 7, 5, 6))
    emit_li(prog, 28, 1)
    prog.branch_bne(7, 28, "fail")

    emit_li(prog, 5, -20)
    emit_li(prog, 6, 3)
    prog.emit(m_op(0b100, 7, 5, 6))
    emit_li(prog, 28, -6)
    prog.branch_bne(7, 28, "fail")

    prog.emit(m_op(0b110, 7, 5, 6))
    emit_li(prog, 28, -2)
    prog.branch_bne(7, 28, "fail")

    emit_li(prog, 5, 20)
    emit_li(prog, 6, 3)
    prog.emit(m_op(0b101, 7, 5, 6))
    emit_li(prog, 28, 6)
    prog.branch_bne(7, 28, "fail")

    prog.emit(m_op(0b111, 7, 5, 6))
    emit_li(prog, 28, 2)
    prog.branch_bne(7, 28, "fail")

    emit_li(prog, 5, 123)
    emit_li(prog, 6, 0)
    prog.emit(m_op(0b100, 7, 5, 6))
    emit_li(prog, 28, -1)
    prog.branch_bne(7, 28, "fail")

    prog.emit(m_op(0b101, 7, 5, 6))
    emit_li(prog, 28, -1)
    prog.branch_bne(7, 28, "fail")

    prog.emit(m_op(0b110, 7, 5, 6))
    emit_li(prog, 28, 123)
    prog.branch_bne(7, 28, "fail")

    prog.emit(m_op(0b111, 7, 5, 6))
    emit_li(prog, 28, 123)
    prog.branch_bne(7, 28, "fail")

    prog.emit(lui(5, 0x80000))
    emit_li(prog, 6, -1)
    prog.emit(m_op(0b100, 7, 5, 6))
    prog.emit(lui(28, 0x80000))
    prog.branch_bne(7, 28, "fail")

    prog.emit(m_op(0b110, 7, 5, 6))
    prog.branch_bne(7, 0, "fail")

    prog.label("pass")
    emit_li(prog, 10, PASS_MAGIC)
    prog.jump("done")

    prog.label("fail")
    emit_li(prog, 10, FAIL_MAGIC)

    prog.label("done")
    prog.emit(lui(5, LED_ADDR >> 12))
    prog.emit(sw(10, LED_ADDR & 0xFFF, 5))
    prog.jump("done")

    prog.resolve()
    return prog.words


def write_coe(words: list[int], path: str, depth: int) -> None:
    padded = list(words)
    if len(padded) > depth:
        raise ValueError(f"program has {len(padded)} words, exceeds depth {depth}")
    padded.extend([0] * (depth - len(padded)))
    with open(path, "w", encoding="ascii") as f:
        f.write("memory_initialization_radix=16;\n")
        f.write("memory_initialization_vector=\n")
        for idx, word in enumerate(padded):
            sep = ";" if idx == len(padded) - 1 else ","
            f.write(f"{word:08X}{sep}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate COE for t18_m_ext_basic")
    parser.add_argument("output", help="path to output .coe")
    parser.add_argument("--depth", type=int, default=IROM_DEPTH, help="memory depth in words")
    args = parser.parse_args()

    words = build_program()
    write_coe(words, args.output, args.depth)
    print(f"generated {args.output} ({len(words)} program words, depth={args.depth})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
