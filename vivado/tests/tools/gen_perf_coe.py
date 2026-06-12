#!/usr/bin/env python3
"""
gen_perf_coe.py - 自研 RV32I CPU 性能测试 COE 生成器（无需 GCC 工具链）

程序结构（约 ~1100 条指令，~1500 周期，50MHz 下约 30µs）：
  Phase A: 30 次紧密 ADDI 链   → 测 EX→EX 前递
  Phase B: 10 次 8 字 LW+ADD   → 测 load-use stall + MEM→EX 前递
  Phase C: 8 元素冒泡排序       → 混合 LW/SW + 密集分支
  Phase D: 校验 + 写 LED 报告

成功：LED = 0xC0DEC0DE
失败：LED = 0xDEADBEEF
最后死循环 j halt 停机。

内存映射（来自 perip_bridge.sv）：
  PC reset = 0x80000000
  BRAM     = 0x80100000 - 0x8013FFFF
  LED      = 0x80200040
"""

import os
import sys

# -------- RV32I 寄存器 ABI 名 --------
ZERO, RA, SP, GP, TP = 0, 1, 2, 3, 4
T0, T1, T2 = 5, 6, 7
S0, S1 = 8, 9
A0, A1, A2, A3, A4, A5, A6, A7 = 10, 11, 12, 13, 14, 15, 16, 17
S2, S3, S4, S5, S6, S7, S8, S9, S10, S11 = 18, 19, 20, 21, 22, 23, 24, 25, 26, 27
T3, T4, T5, T6 = 28, 29, 30, 31


# ===================== 指令编码 =====================

def ENC_R(rd, rs1, rs2, funct3, funct7, opcode):
    return (((funct7 & 0x7F) << 25) | ((rs2 & 0x1F) << 20) |
            ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) |
            ((rd & 0x1F) << 7) | (opcode & 0x7F))

def ENC_I(rd, rs1, imm, funct3, opcode):
    assert -2048 <= imm <= 2047, f"I-imm out of range: {imm}"
    return (((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) |
            ((funct3 & 0x7) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F))

def ENC_S(rs1, rs2, imm, funct3):
    assert -2048 <= imm <= 2047, f"S-imm out of range: {imm}"
    imm12 = imm & 0xFFF
    return (((imm12 >> 5) << 25) | ((rs2 & 0x1F) << 20) |
            ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) |
            ((imm12 & 0x1F) << 7) | 0x23)

def ENC_B(rs1, rs2, imm, funct3):
    assert -4096 <= imm <= 4094 and (imm & 1) == 0, f"B-imm out of range: {imm}"
    imm13 = imm & 0x1FFF
    b12 = (imm13 >> 12) & 1
    b11 = (imm13 >> 11) & 1
    b10_5 = (imm13 >> 5) & 0x3F
    b4_1 = (imm13 >> 1) & 0xF
    return ((b12 << 31) | (b10_5 << 25) | ((rs2 & 0x1F) << 20) |
            ((rs1 & 0x1F) << 15) | ((funct3 & 0x7) << 12) |
            (b4_1 << 8) | (b11 << 7) | 0x63)

def ENC_U(rd, imm20, opcode):
    return (((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | (opcode & 0x7F))

def ENC_J(rd, imm):
    assert -(1 << 20) <= imm <= (1 << 20) - 2 and (imm & 1) == 0, f"J-imm out of range: {imm}"
    imm21 = imm & 0x1FFFFF
    b20 = (imm21 >> 20) & 1
    b10_1 = (imm21 >> 1) & 0x3FF
    b11 = (imm21 >> 11) & 1
    b19_12 = (imm21 >> 12) & 0xFF
    return ((b20 << 31) | (b10_1 << 21) | (b11 << 20) | (b19_12 << 12) |
            ((rd & 0x1F) << 7) | 0x6F)


# -------- 指令包装 --------

def LUI(rd, i):    return ENC_U(rd, i, 0x37)
def AUIPC(rd, i):  return ENC_U(rd, i, 0x17)

def ADDI(rd, rs1, i): return ENC_I(rd, rs1, i, 0b000, 0x13)
def XORI(rd, rs1, i): return ENC_I(rd, rs1, i, 0b100, 0x13)
def ORI(rd, rs1, i):  return ENC_I(rd, rs1, i, 0b110, 0x13)
def ANDI(rd, rs1, i): return ENC_I(rd, rs1, i, 0b111, 0x13)

def ADD(rd, rs1, rs2): return ENC_R(rd, rs1, rs2, 0b000, 0x00, 0x33)
def SUB(rd, rs1, rs2): return ENC_R(rd, rs1, rs2, 0b000, 0x20, 0x33)
def AND(rd, rs1, rs2): return ENC_R(rd, rs1, rs2, 0b111, 0x00, 0x33)
def OR(rd, rs1, rs2):  return ENC_R(rd, rs1, rs2, 0b110, 0x00, 0x33)
def XOR(rd, rs1, rs2): return ENC_R(rd, rs1, rs2, 0b100, 0x00, 0x33)

def LW(rd, rs1, i):   return ENC_I(rd, rs1, i, 0b010, 0x03)
def SW(rs1, rs2, i):  return ENC_S(rs1, rs2, i, 0b010)


# ===================== 汇编器（双 pass + 标签） =====================

class Asm:
    def __init__(self):
        self.words = []        # int 或 ('defer', fn)
        self.labels = {}

    @property
    def pc(self):
        return len(self.words) * 4

    def lbl(self, name):
        assert name not in self.labels, f"duplicate label {name}"
        self.labels[name] = self.pc

    def emit(self, w):
        self.words.append(w)

    def li(self, rd, imm):
        """Load immediate (32-bit). 单条 ADDI 优先；否则 LUI+ADDI。"""
        imm32 = imm & 0xFFFFFFFF
        signed = imm32 - 0x100000000 if imm32 >= 0x80000000 else imm32
        if -2048 <= signed <= 2047:
            self.emit(ADDI(rd, ZERO, signed))
            return
        if imm32 & 0x800:
            upper = ((imm32 >> 12) + 1) & 0xFFFFF
        else:
            upper = (imm32 >> 12) & 0xFFFFF
        lower = imm32 - ((upper << 12) & 0xFFFFFFFF)
        if lower > 2047:
            lower -= 0x100000000
        assert -2048 <= lower <= 2047, f"LI decompose failed for 0x{imm32:08x}"
        self.emit(LUI(rd, upper))
        self.emit(ADDI(rd, rd, lower))

    def _br(self, rs1, rs2, label, funct3):
        cur = self.pc
        idx = len(self.words)
        self.words.append(None)
        def res(L):
            return ENC_B(rs1, rs2, L[label] - cur, funct3)
        self.words[idx] = ('defer', res)

    def beq(self, rs1, rs2, lb):  self._br(rs1, rs2, lb, 0b000)
    def bne(self, rs1, rs2, lb):  self._br(rs1, rs2, lb, 0b001)
    def blt(self, rs1, rs2, lb):  self._br(rs1, rs2, lb, 0b100)
    def bge(self, rs1, rs2, lb):  self._br(rs1, rs2, lb, 0b101)
    def beqz(self, rs, lb):       self.beq(rs, ZERO, lb)
    def bnez(self, rs, lb):       self.bne(rs, ZERO, lb)
    def blez(self, rs, lb):       self.bge(ZERO, rs, lb)   # 0 >= rs ⇔ rs <= 0

    def jal(self, rd, label):
        cur = self.pc
        idx = len(self.words)
        self.words.append(None)
        def res(L):
            return ENC_J(rd, L[label] - cur)
        self.words[idx] = ('defer', res)

    def j(self, label): self.jal(ZERO, label)

    def assemble(self):
        out = []
        for w in self.words:
            if isinstance(w, tuple) and w[0] == 'defer':
                out.append(w[1](self.labels))
            elif isinstance(w, int):
                out.append(w)
            else:
                raise RuntimeError(f"unresolved word at index {len(out)}")
        return out


# ===================== 性能测试程序 =====================

# 调参：减小这些可使仿真时间显著缩短
N_PHASE_A_ITERS = 30   # 每轮 8 条 ADDI，主测前递
N_PHASE_B_ITERS = 10   # 每轮 8 条 LW+ADD，主测 load-use
SORT_LEN        = 8    # 冒泡排序长度（固定，逻辑里硬编码 8）

def build():
    a = Asm()

    # ---------- 入口 ----------
    a.lbl('_start')
    a.li(GP, 0x80100000)               # 数据基址 (BRAM)
    a.li(S7, 0x80200040)               # LED 寄存器地址

    # ---------- Phase A：紧密 ADDI 链 ----------
    a.li(T0, 0)                        # acc = 0
    a.li(S0, N_PHASE_A_ITERS)          # iter
    a.lbl('phaseA')
    for _ in range(8):
        a.emit(ADDI(T0, T0, 1))        # 8 条紧密依赖（EX→EX 前递热身）
    a.emit(ADDI(S0, S0, -1))
    a.bnez(S0, 'phaseA')
    # Expected: t0 = 30 * 8 = 240

    # ---------- Phase B：8 字数组求和 × N ----------
    # 初始化 arr[i] = i+1（i=0..7）
    for i in range(8):
        a.emit(ADDI(T1, ZERO, i + 1))
        a.emit(SW(GP, T1, i * 4))

    a.li(S1, N_PHASE_B_ITERS)
    a.li(T2, 0)                        # sum = 0
    a.lbl('phaseB')
    for i in range(8):
        a.emit(LW(T3, GP, i * 4))      # load
        a.emit(ADD(T2, T2, T3))        # 立即使用 → 1 拍 stall
    a.emit(ADDI(S1, S1, -1))
    a.bnez(S1, 'phaseB')
    # Expected: t2 = 10 * (1+2+3+4+5+6+7+8) = 360

    # ---------- Phase C：冒泡排序 ----------
    # 写入 [8,7,6,5,4,3,2,1] @ gp+0x40
    rev = [8, 7, 6, 5, 4, 3, 2, 1]
    for i, v in enumerate(rev):
        a.emit(ADDI(T1, ZERO, v))
        a.emit(SW(GP, T1, 0x40 + i * 4))

    a.emit(ADDI(S2, ZERO, SORT_LEN - 1))   # i = n-1 = 7
    a.lbl('bs_outer')
    a.blez(S2, 'bs_done')                  # 当 i <= 0 → 完成
    a.emit(ADDI(S3, ZERO, 0))              # j = 0
    a.emit(ADDI(S4, GP, 0x40))             # ptr = &arr[0]
    a.lbl('bs_inner')
    a.emit(LW(T4, S4, 0))                  # a[j]
    a.emit(LW(T5, S4, 4))                  # a[j+1]
    a.bge(T5, T4, 'bs_skip')               # 若 a[j+1] >= a[j] 不交换
    a.emit(SW(S4, T5, 0))                  # 交换
    a.emit(SW(S4, T4, 4))
    a.lbl('bs_skip')
    a.emit(ADDI(S4, S4, 4))                # ptr++
    a.emit(ADDI(S3, S3, 1))                # j++
    a.blt(S3, S2, 'bs_inner')              # j < i → 继续
    a.emit(ADDI(S2, S2, -1))               # i--
    a.j('bs_outer')
    a.lbl('bs_done')

    a.emit(LW(T4, GP, 0x40))               # a[0] 应 = 1
    a.emit(LW(T5, GP, 0x40 + (SORT_LEN - 1) * 4))   # a[n-1] 应 = 8

    # ---------- Phase D：校验 ----------
    a.emit(ADDI(T6, ZERO, N_PHASE_A_ITERS * 8))
    a.bne(T0, T6, 'fail')
    a.li(T6, N_PHASE_B_ITERS * 36)
    a.bne(T2, T6, 'fail')
    a.emit(ADDI(T6, ZERO, 1))
    a.bne(T4, T6, 'fail')
    a.emit(ADDI(T6, ZERO, SORT_LEN))
    a.bne(T5, T6, 'fail')

    # ---------- PASS ----------
    a.lbl('pass')
    a.li(T0, 0xC0DEC0DE)
    a.emit(SW(S7, T0, 0))                  # LED ← PASS magic
    a.j('halt')

    # ---------- FAIL ----------
    a.lbl('fail')
    a.li(T0, 0xDEADBEEF)
    a.emit(SW(S7, T0, 0))                  # LED ← FAIL magic

    # ---------- HALT ----------
    a.lbl('halt')
    a.j('halt')

    return a


# ===================== 输出文件 =====================

def to_coe(words, depth=4096):
    pad = words + [0] * (depth - len(words))
    body = []
    for i, w in enumerate(pad):
        sep = ";" if i == len(pad) - 1 else ","
        body.append(f"{w & 0xFFFFFFFF:08x}{sep}")
    return ("memory_initialization_radix=16;\n"
            "memory_initialization_vector=\n" + "\n".join(body) + "\n")


def to_mif_bin(words, depth=4096):
    """Vivado IP 内部使用的 32-bit 二进制 .mif 格式（每行一个 32-bit 字）"""
    pad = words + [0] * (depth - len(words))
    return "\n".join(f"{w & 0xFFFFFFFF:032b}" for w in pad) + "\n"


def disasm(words, labels):
    rev = {v: k for k, v in labels.items()}
    out = []
    for i, w in enumerate(words):
        addr = i * 4
        if addr in rev:
            out.append(f"\n{rev[addr]}:")
        out.append(f"  0x{addr:04x}:  0x{w:08x}")
    return "\n".join(out)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.normpath(os.path.join(here, '..', 'build'))
    os.makedirs(out_dir, exist_ok=True)

    a = build()
    words = a.assemble()

    coe_path = os.path.join(out_dir, 'perf_test.coe')
    mif_path = os.path.join(out_dir, 'perf_test.mif')
    asm_path = os.path.join(out_dir, 'perf_test.dump')

    with open(coe_path, 'w') as f:
        f.write(to_coe(words))
    with open(mif_path, 'w') as f:
        f.write(to_mif_bin(words))
    with open(asm_path, 'w') as f:
        f.write(disasm(words, a.labels))

    # 估算周期
    n = len(words)
    est = (N_PHASE_A_ITERS * 10
           + 16
           + N_PHASE_B_ITERS * (16 + 8)        # +8 stall/iter
           + 16
           + 7 * 5 + 28 * 9                    # 排序粗估
           + 25)
    print(f"  Instructions   : {n}")
    print(f"  Est. cycles    : ~{est}  ({est/50:.1f} us @ 50 MHz)")
    print(f"  COE            : {coe_path}")
    print(f"  MIF (binary)   : {mif_path}")
    print(f"  Disasm dump    : {asm_path}")
    print(f"  Labels:")
    for name, addr in sorted(a.labels.items(), key=lambda x: x[1]):
        print(f"    0x{addr:04x}  {name}")


if __name__ == "__main__":
    main()
