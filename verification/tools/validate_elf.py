#!/usr/bin/env python3
import argparse
import re
import subprocess
from pathlib import Path

ALLOWED_OPCODES = {
    "lui", "auipc", "jal", "jalr", "beq", "bne", "blt", "bge", "bltu", "bgeu",
    "lb", "lh", "lw", "lbu", "lhu", "sb", "sh", "sw", "addi", "slti", "sltiu",
    "xori", "ori", "andi", "slli", "srli", "srai", "add", "sub", "sll", "slt",
    "sltu", "xor", "srl", "sra", "or", "and", "mul", "mulh", "mulhsu", "mulhu",
    "div", "divu", "rem", "remu", "csrrw", "csrrs", "csrrc", "csrrwi", "csrrsi",
    "csrrci", "ecall", "mret",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--objdump", default="riscv64-unknown-elf-objdump")
    parser.add_argument("elf", type=Path)
    args = parser.parse_args()

    headers = subprocess.check_output([args.objdump, "-h", str(args.elf)], text=True)
    sections = {}
    for line in headers.splitlines():
        match = re.match(r"\s*\d+\s+(\.\S+)\s+([0-9a-fA-F]+)\s+([0-9a-fA-F]+)", line)
        if match:
            sections[match.group(1)] = (int(match.group(2), 16), int(match.group(3), 16))
    text_size, text_addr = sections.get(".text", (0, 0))
    data_size, data_addr = sections.get(".data", (0, 0))
    if text_addr != 0x80000000 or text_size > 0x4000:
        raise SystemExit(f"invalid IROM layout: addr=0x{text_addr:08x} size=0x{text_size:x}")
    if data_addr != 0x80100000 or data_size > 0x40000:
        raise SystemExit(f"invalid BRAM layout: addr=0x{data_addr:08x} size=0x{data_size:x}")

    disasm = subprocess.check_output([args.objdump, "-d", "-M", "no-aliases", str(args.elf)], text=True)
    seen = set()
    for line in disasm.splitlines():
        match = re.match(r"\s*[0-9a-f]+:\s+[0-9a-f]+\s+([a-z][a-z0-9_.]*)", line)
        if match:
            seen.add(match.group(1))
    unsupported = sorted(seen - ALLOWED_OPCODES)
    if unsupported:
        raise SystemExit(f"unsupported instructions in {args.elf}: {', '.join(unsupported)}")
    print(f"validated {args.elf}: text={text_size} bytes data={data_size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
