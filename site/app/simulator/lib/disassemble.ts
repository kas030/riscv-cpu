const abi = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"];
const signed = (value: number, bits: number) => value & 2 ** (bits - 1) ? value - 2 ** bits : value;
const reg = (index: number) => abi[index] ?? `x${index}`;

// Display-only decoder. It formats the exact sampled instruction word and is
// never used to derive CPU execution results.
export function disassemble(hex: string) {
  const instruction = Number.parseInt(hex, 16) >>> 0;
  const opcode = instruction & 0x7f;
  const rd = (instruction >>> 7) & 0x1f;
  const funct3 = (instruction >>> 12) & 7;
  const rs1 = (instruction >>> 15) & 0x1f;
  const rs2 = (instruction >>> 20) & 0x1f;
  const funct7 = instruction >>> 25;
  const iImmediate = signed(instruction >>> 20, 12);
  const sImmediate = signed(((instruction >>> 25) << 5) | ((instruction >>> 7) & 0x1f), 12);
  const bImmediate = signed((((instruction >>> 31) & 1) << 12) | (((instruction >>> 7) & 1) << 11) | (((instruction >>> 25) & 0x3f) << 5) | (((instruction >>> 8) & 0xf) << 1), 13);
  const jImmediate = signed((((instruction >>> 31) & 1) << 20) | (((instruction >>> 12) & 0xff) << 12) | (((instruction >>> 20) & 1) << 11) | (((instruction >>> 21) & 0x3ff) << 1), 21);
  const upper = instruction & 0xfffff000;
  if (instruction === 0x00000073) return "ecall";
  if (instruction === 0x30200073) return "mret";
  if (opcode === 0x37) return `lui ${reg(rd)},0x${(upper >>> 12).toString(16)}`;
  if (opcode === 0x17) return `auipc ${reg(rd)},0x${(upper >>> 12).toString(16)}`;
  if (opcode === 0x6f) return `jal ${reg(rd)},${jImmediate}`;
  if (opcode === 0x67 && funct3 === 0) return `jalr ${reg(rd)},${iImmediate}(${reg(rs1)})`;
  if (opcode === 0x63) return `${["beq", "bne", "?", "?", "blt", "bge", "bltu", "bgeu"][funct3]} ${reg(rs1)},${reg(rs2)},${bImmediate}`;
  if (opcode === 0x03) return `${["lb", "lh", "lw", "?", "lbu", "lhu", "?"][funct3]} ${reg(rd)},${iImmediate}(${reg(rs1)})`;
  if (opcode === 0x23) return `${["sb", "sh", "sw"][funct3] ?? "?"} ${reg(rs2)},${sImmediate}(${reg(rs1)})`;
  if (opcode === 0x13) {
    if (funct3 === 1) return `slli ${reg(rd)},${reg(rs1)},${rs2}`;
    if (funct3 === 5) return `${funct7 === 0x20 ? "srai" : "srli"} ${reg(rd)},${reg(rs1)},${rs2}`;
    return `${["addi", "slli", "slti", "sltiu", "xori", "?", "ori", "andi"][funct3]} ${reg(rd)},${reg(rs1)},${iImmediate}`;
  }
  if (opcode === 0x33) {
    if (funct7 === 1) return `${["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"][funct3]} ${reg(rd)},${reg(rs1)},${reg(rs2)}`;
    const names = funct7 === 0x20 ? ["sub", "?", "?", "?", "?", "sra", "?", "?"] : ["add", "sll", "slt", "sltu", "xor", "srl", "or", "and"];
    return `${names[funct3]} ${reg(rd)},${reg(rs1)},${reg(rs2)}`;
  }
  if (opcode === 0x73) {
    const name = ["?", "csrrw", "csrrs", "csrrc", "?", "csrrwi", "csrrsi", "csrrci"][funct3];
    return `${name} ${reg(rd)},0x${(instruction >>> 20).toString(16)},${funct3 >= 5 ? rs1 : reg(rs1)}`;
  }
  return `.word 0x${hex}`;
}
