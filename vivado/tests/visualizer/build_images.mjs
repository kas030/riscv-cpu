#!/usr/bin/env node
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const output = process.argv[2] ? resolve(process.cwd(), process.argv[2]) : resolve(here, "../build/visualizer_isa_coverage.coe");
const words = [];
const labels = new Map();
const fixups = [];
const mask = (value, bits) => value & (2 ** bits - 1);
const r = (funct7, rs2, rs1, funct3, rd, opcode = 0x33) => ((funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode) >>> 0;
const i = (imm, rs1, funct3, rd, opcode = 0x13) => ((mask(imm, 12) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode) >>> 0;
const u = (imm20, rd, opcode = 0x37) => ((mask(imm20, 20) << 12) | (rd << 7) | opcode) >>> 0;
const s = (imm, rs2, rs1, funct3) => (((mask(imm, 12) >>> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | ((mask(imm, 12) & 0x1f) << 7) | 0x23) >>> 0;
const b = (offset, rs2, rs1, funct3) => {
  const value = mask(offset, 13);
  return ((((value >>> 12) & 1) << 31) | (((value >>> 5) & 0x3f) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (((value >>> 1) & 0xf) << 8) | (((value >>> 11) & 1) << 7) | 0x63) >>> 0;
};
const j = (offset, rd = 0) => {
  const value = mask(offset, 21);
  return ((((value >>> 20) & 1) << 31) | (((value >>> 1) & 0x3ff) << 21) | (((value >>> 11) & 1) << 20) | (((value >>> 12) & 0xff) << 12) | (rd << 7) | 0x6f) >>> 0;
};
const emit = (word) => words.push(word >>> 0);
const label = (name) => labels.set(name, words.length * 4);
const branch = (name, rs2, rs1, funct3) => { fixups.push({ index: words.length, name, encode: (offset) => b(offset, rs2, rs1, funct3) }); emit(0); };
const jump = (name, rd = 0) => { fixups.push({ index: words.length, name, encode: (offset) => j(offset, rd) }); emit(0); };

label("start");
emit(i(0, 0, 0, 28));
label("dual_loop");
emit(i(1, 28, 0, 28)); emit(i(7, 0, 0, 29)); emit(i(9, 0, 0, 30)); emit(i(3, 28, 2, 31)); branch("dual_loop", 0, 31, 1);
emit(i(5, 0, 0, 1)); emit(i(2, 0, 0, 2));
emit(r(0x20, 2, 1, 0, 3)); emit(r(0, 2, 1, 1, 4)); emit(r(0, 2, 1, 2, 5)); emit(r(0, 2, 1, 3, 6));
emit(r(0, 2, 1, 4, 7)); emit(r(0, 2, 1, 5, 8)); emit(r(0, 2, 1, 6, 9)); emit(r(0, 2, 1, 7, 10));
emit(i(3, 2, 1, 11)); emit(i(2, 11, 5, 12)); emit(i(-8, 0, 0, 13)); emit(r(0x20, 2, 13, 5, 14)); emit(i((0x20 << 5) | 2, 13, 5, 15));
emit(i(0, 13, 2, 16)); emit(i(1, 13, 3, 17)); emit(i(7, 2, 4, 18)); emit(i(8, 2, 6, 19)); emit(i(1, 18, 7, 20));
emit(u(0x80000, 21));
const targetAddiIndex = words.length; emit(0);
emit(i(0, 21, 0, 22, 0x67));
jump("fail");
label("jalr_target");
emit(i(0x340, 3, 5, 23, 0x73));
label("pass");
emit(u(0xc0dec, 10)); emit(i(0x0de, 10, 0, 10)); jump("done");
label("fail");
emit(u(0xdeadc, 10)); emit(i(-0x111, 10, 0, 10));
label("done");
emit(u(0x80200, 5)); emit(i(0x40, 5, 0, 5)); emit(s(0, 10, 5, 2));
label("hang"); jump("hang");

words[targetAddiIndex] = i(labels.get("jalr_target"), 21, 0, 21);
for (const fixup of fixups) {
  if (!labels.has(fixup.name)) throw new Error(`unknown label ${fixup.name}`);
  words[fixup.index] = fixup.encode(labels.get(fixup.name) - fixup.index * 4);
}
while (words.length < 4096) words.push(0);
await mkdir(dirname(output), { recursive: true });
const body = words.map((word, index) => `${word.toString(16).padStart(8, "0")}${index === words.length - 1 ? ";" : ","}`).join("\n");
await writeFile(output, `memory_initialization_radix=16;\nmemory_initialization_vector=\n${body}\n`);
console.log(`generated ${output} (${words.length} words)`);
