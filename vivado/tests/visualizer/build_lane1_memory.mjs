#!/usr/bin/env node
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const output = resolve(here, "../build/visualizer_lane1_memory.coe");
const words = [];
const mask = (value, bits) => value & (2 ** bits - 1);
const i = (imm, rs1, funct3, rd, opcode = 0x13) => ((mask(imm, 12) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode) >>> 0;
const u = (imm20, rd) => ((mask(imm20, 20) << 12) | (rd << 7) | 0x37) >>> 0;
const s = (imm, rs2, rs1, funct3) => (((mask(imm, 12) >>> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | ((mask(imm, 12) & 0x1f) << 7) | 0x23) >>> 0;
const b = (offset, rs2, rs1, funct3) => {
  const value = mask(offset, 13);
  return ((((value >>> 12) & 1) << 31) | (((value >>> 5) & 0x3f) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (((value >>> 1) & 0xf) << 8) | (((value >>> 11) & 1) << 7) | 0x63) >>> 0;
};
const j = (offset) => {
  const value = mask(offset, 21);
  return ((((value >>> 20) & 1) << 31) | (((value >>> 1) & 0x3ff) << 21) | (((value >>> 11) & 1) << 20) | (((value >>> 12) & 0xff) << 12) | 0x6f) >>> 0;
};
const emit = (word) => words.push(word >>> 0);

emit(u(0x80100, 5));               // t0 = BRAM base
emit(i(0, 0, 0, 1));              // ra = 0
emit(i(0, 0, 0, 3));              // gp = loop counter
const loop = words.length * 4;
emit(i(1, 1, 0, 1));              // lane 0: independent ALU
emit(i(12, 5, 2, 2, 0x03));       // lane 1 after hint training: lw sp,12(t0)
emit(i(1, 3, 0, 3));
emit(i(4, 3, 2, 4));
emit(b(loop - words.length * 4, 0, 4, 1));
emit(u(0xc0dec, 10)); emit(i(0x0de, 10, 0, 10));
emit(u(0x80200, 5)); emit(i(0x40, 5, 0, 5)); emit(s(0, 10, 5, 2));
emit(j(0));

while (words.length < 4096) words.push(0);
await mkdir(dirname(output), { recursive: true });
const body = words.map((word, index) => `${word.toString(16).padStart(8, "0")}${index === words.length - 1 ? ";" : ","}`).join("\n");
await writeFile(output, `memory_initialization_radix=16;\nmemory_initialization_vector=\n${body}\n`);
console.log(`generated ${output} (${words.length} words)`);
