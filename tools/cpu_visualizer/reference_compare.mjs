#!/usr/bin/env node
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const args = Object.fromEntries(process.argv.slice(2).map((item) => {
  const split = item.indexOf("=");
  return [item.slice(2, split), item.slice(split + 1)];
}));
if (!args.image || !args.bram || !args.trace) {
  console.error("usage: reference_compare.mjs --image=file.coe --bram=file.coe --trace=scenario-dir");
  process.exit(2);
}

const wordsFromCoe = async (path) => {
  const text = await readFile(resolve(path), "utf8");
  const vector = text.match(/memory_initialization_vector\s*=([\s\S]*?);/i)?.[1];
  if (!vector) throw new Error(`无法解析 COE: ${path}`);
  return vector.split(/[,\s]+/).filter(Boolean).map((word) => Number.parseInt(word.replace(/_/g, ""), 16) >>> 0);
};
const hex = (value) => (value >>> 0).toString(16).padStart(8, "0");
const u32 = (value) => Number(BigInt.asUintN(32, BigInt(value)));
const s32 = (value) => value >> 0;
const signExtend = (value, bits) => value & 2 ** (bits - 1) ? value - 2 ** bits : value;
const irom = await wordsFromCoe(args.image);
const bramWords = await wordsFromCoe(args.bram);
const memory = new Map();
for (let index = 0; index < bramWords.length; index += 1) for (let lane = 0; lane < 4; lane += 1) memory.set((0x80100000 + index * 4 + lane) >>> 0, (bramWords[index] >>> (lane * 8)) & 0xff);
const readByte = (address) => memory.get(address >>> 0) ?? 0;
const writeByte = (address, value) => memory.set(address >>> 0, value & 0xff);
const registers = Array(32).fill(0);
const csrs = new Map([[0x300, 0x00001800], [0x305, 0], [0x340, 0], [0x341, 0], [0x342, 0]]);
const retired = [];
const stores = [];
let pc = 0x80000000;
let complete = false;

const writeRegister = (index, value, record) => {
  if (index === 0) return;
  registers[index] = u32(value);
  record.register = `x${index}`;
  record.value = hex(registers[index]);
};
const writeCsr = (index, value) => {
  value = u32(value);
  if (index === 0x300) value = (0x1800 | (value & (1 << 3)) | (value & (1 << 7))) >>> 0;
  if (index === 0x341) value &= 0xfffffffc;
  if (csrs.has(index)) csrs.set(index, value);
};

for (let steps = 0; steps < 1_000_000 && !complete; steps += 1) {
  const instruction = irom[(pc >>> 2) & 0xfff] ?? 0;
  const currentPc = pc;
  let nextPc = u32(pc + 4);
  const opcode = instruction & 0x7f;
  const rd = (instruction >>> 7) & 0x1f;
  const funct3 = (instruction >>> 12) & 7;
  const rs1 = (instruction >>> 15) & 0x1f;
  const rs2 = (instruction >>> 20) & 0x1f;
  const funct7 = instruction >>> 25;
  const immediateI = signExtend(instruction >>> 20, 12);
  const immediateS = signExtend(((instruction >>> 25) << 5) | ((instruction >>> 7) & 0x1f), 12);
  const immediateB = signExtend((((instruction >>> 31) & 1) << 12) | (((instruction >>> 7) & 1) << 11) | (((instruction >>> 25) & 0x3f) << 5) | (((instruction >>> 8) & 0xf) << 1), 13);
  const immediateJ = signExtend((((instruction >>> 31) & 1) << 20) | (((instruction >>> 12) & 0xff) << 12) | (((instruction >>> 20) & 1) << 11) | (((instruction >>> 21) & 0x3ff) << 1), 21);
  const record = { pc: hex(currentPc), instruction: hex(instruction) };
  const lhs = registers[rs1];
  const rhs = registers[rs2];

  if (opcode === 0x37) writeRegister(rd, instruction & 0xfffff000, record);
  else if (opcode === 0x17) writeRegister(rd, currentPc + (instruction & 0xfffff000), record);
  else if (opcode === 0x6f) { writeRegister(rd, currentPc + 4, record); nextPc = u32(currentPc + immediateJ); }
  else if (opcode === 0x67 && funct3 === 0) { writeRegister(rd, currentPc + 4, record); nextPc = u32((lhs + immediateI) & 0xfffffffe); }
  else if (opcode === 0x63) {
    const taken = [lhs === rhs, lhs !== rhs, false, false, s32(lhs) < s32(rhs), s32(lhs) >= s32(rhs), lhs < rhs, lhs >= rhs][funct3];
    if (taken) nextPc = u32(currentPc + immediateB);
  } else if (opcode === 0x03) {
    const address = u32(lhs + immediateI);
    const half = readByte(address) | (readByte(address + 1) << 8);
    const word = u32(half | (readByte(address + 2) << 16) | (readByte(address + 3) << 24));
    const loaded = [signExtend(readByte(address), 8), signExtend(half, 16), word, 0, readByte(address), half][funct3] ?? 0;
    writeRegister(rd, loaded, record);
  } else if (opcode === 0x23) {
    const address = u32(lhs + immediateS);
    const mask = funct3 & 3;
    const event = { address: hex(address), mask: mask.toString(2).padStart(2, "0"), value: hex(rhs) };
    stores.push(event);
    if (address >= 0x80100000 && address <= 0x8013ffff) {
      const bytes = mask === 0 ? 1 : mask === 1 ? 2 : 4;
      for (let lane = 0; lane < bytes; lane += 1) writeByte(address + lane, rhs >>> (lane * 8));
    }
    if (address === 0x80200040) complete = true;
  } else if (opcode === 0x13) {
    let result;
    if (funct3 === 0) result = lhs + immediateI;
    else if (funct3 === 1) result = lhs << rs2;
    else if (funct3 === 2) result = Number(s32(lhs) < immediateI);
    else if (funct3 === 3) result = Number(lhs < u32(immediateI));
    else if (funct3 === 4) result = lhs ^ u32(immediateI);
    else if (funct3 === 5) result = funct7 === 0x20 ? s32(lhs) >> rs2 : lhs >>> rs2;
    else if (funct3 === 6) result = lhs | u32(immediateI);
    else if (funct3 === 7) result = lhs & u32(immediateI);
    writeRegister(rd, result, record);
  } else if (opcode === 0x33) {
    let result;
    if (funct7 === 1) {
      const unsignedLeft = BigInt(lhs);
      const unsignedRight = BigInt(rhs);
      const signedLeft = BigInt(s32(lhs));
      const signedRight = BigInt(s32(rhs));
      if (funct3 === 0) result = Number(BigInt.asUintN(32, unsignedLeft * unsignedRight));
      else if (funct3 === 1) result = Number(BigInt.asUintN(32, (signedLeft * signedRight) >> 32n));
      else if (funct3 === 2) result = Number(BigInt.asUintN(32, (signedLeft * unsignedRight) >> 32n));
      else if (funct3 === 3) result = Number(BigInt.asUintN(32, (unsignedLeft * unsignedRight) >> 32n));
      else if (funct3 === 4) result = rhs === 0 ? 0xffffffff : lhs === 0x80000000 && rhs === 0xffffffff ? 0x80000000 : u32(BigInt(s32(lhs)) / BigInt(s32(rhs)));
      else if (funct3 === 5) result = rhs === 0 ? 0xffffffff : Math.floor(lhs / rhs);
      else if (funct3 === 6) result = rhs === 0 ? lhs : lhs === 0x80000000 && rhs === 0xffffffff ? 0 : u32(BigInt(s32(lhs)) % BigInt(s32(rhs)));
      else result = rhs === 0 ? lhs : lhs % rhs;
    } else if (funct3 === 0) result = funct7 === 0x20 ? lhs - rhs : lhs + rhs;
    else if (funct3 === 1) result = lhs << (rhs & 31);
    else if (funct3 === 2) result = Number(s32(lhs) < s32(rhs));
    else if (funct3 === 3) result = Number(lhs < rhs);
    else if (funct3 === 4) result = lhs ^ rhs;
    else if (funct3 === 5) result = funct7 === 0x20 ? s32(lhs) >> (rhs & 31) : lhs >>> (rhs & 31);
    else if (funct3 === 6) result = lhs | rhs;
    else result = lhs & rhs;
    writeRegister(rd, result, record);
  } else if (opcode === 0x73) {
    if (instruction === 0x00000073) {
      let status = csrs.get(0x300);
      status = (status & ~(1 << 7)) | ((status & (1 << 3)) << 4);
      status = (status & ~(1 << 3)) | 0x1800;
      csrs.set(0x300, status >>> 0);
      csrs.set(0x341, currentPc & 0xfffffffc);
      csrs.set(0x342, 11);
      nextPc = csrs.get(0x305) & 0xfffffffc;
    } else if (instruction === 0x30200073) {
      let status = csrs.get(0x300);
      status = (status & ~(1 << 3)) | ((status & (1 << 7)) >>> 4);
      status |= (1 << 7) | 0x1800;
      csrs.set(0x300, status >>> 0);
      nextPc = csrs.get(0x341) & 0xfffffffe;
    } else {
      const index = instruction >>> 20;
      const old = csrs.get(index) ?? 0;
      const source = funct3 >= 5 ? rs1 : lhs;
      writeRegister(rd, old, record);
      if (funct3 === 1 || funct3 === 5) writeCsr(index, source);
      else if ((funct3 === 2 || funct3 === 6) && source !== 0) writeCsr(index, old | source);
      else if ((funct3 === 3 || funct3 === 7) && source !== 0) writeCsr(index, old & ~source);
    }
  } else throw new Error(`reference: unsupported instruction ${hex(instruction)} at ${hex(currentPc)}`);

  registers[0] = 0;
  // CPU-only testbench terminates on the LED bus write while that store is in
  // MEM1, before it reaches the architectural retirement observation point.
  if (!complete) retired.push(record);
  pc = nextPc;
}
if (!complete) throw new Error("reference: program did not write completion LED");

const traceDirectory = resolve(args.trace);
const index = JSON.parse(await readFile(resolve(traceDirectory, "../index.json"), "utf8"));
const scenario = index.scenarios.find((item) => resolve(traceDirectory).endsWith(`/${item.id}`));
if (!scenario) throw new Error(`reference: trace index has no scenario for ${traceDirectory}`);
const retireEvents = new Map();
const traceStores = [];
for (const chunk of scenario.chunks) {
  const payload = JSON.parse(await readFile(resolve(traceDirectory, chunk.file), "utf8"));
  for (const frame of payload.frames) for (const event of frame.events) {
    if (event.type === "retire") retireEvents.set(event.instructionId, event);
    if (event.type === "store") traceStores.push({ address: event.address, mask: event.label.match(/mask=([01]+)/)?.[1], value: event.value });
  }
}
const traceRetired = scenario.instructions.filter((item) => item.retireCycle).map((item) => {
  const event = retireEvents.get(item.instructionId) ?? {};
  return { pc: item.pc, instruction: item.instruction, ...(event.register ? { register: event.register, value: event.value } : {}) };
});
if (traceRetired.length !== retired.length) throw new Error(`reference: retire count RTL=${traceRetired.length}, ref=${retired.length}`);
for (let index = 0; index < retired.length; index += 1) {
  if (JSON.stringify(traceRetired[index]) !== JSON.stringify(retired[index])) throw new Error(`reference: retire ${index} mismatch RTL=${JSON.stringify(traceRetired[index])} ref=${JSON.stringify(retired[index])}`);
}
if (JSON.stringify(traceStores) !== JSON.stringify(stores)) throw new Error(`reference: store sequence mismatch RTL=${JSON.stringify(traceStores)} ref=${JSON.stringify(stores)}`);
const metadataPath = resolve(traceDirectory, "metadata.json");
const metadata = JSON.parse(await readFile(metadataPath, "utf8"));
for (let index = 0; index < 32; index += 1) if (metadata.final.registers[`x${index}`] !== hex(registers[index])) throw new Error(`reference: final x${index} mismatch`);
for (const [addressHex, expected] of Object.entries(metadata.final.memory)) {
  const address = Number.parseInt(addressHex, 16) >>> 0;
  const actual = u32(readByte(address) | (readByte(address + 1) << 8) | (readByte(address + 2) << 16) | (readByte(address + 3) << 24));
  if (expected !== hex(actual)) throw new Error(`reference: final memory 0x${addressHex} mismatch RTL=${expected} ref=${hex(actual)}`);
}
const csrNames = { mstatus: 0x300, mtvec: 0x305, mscratch: 0x340, mepc: 0x341, mcause: 0x342 };
for (const [name, index] of Object.entries(csrNames)) if (metadata.final.csrs[name] !== hex(csrs.get(index))) throw new Error(`reference: final ${name} mismatch RTL=${metadata.final.csrs[name]} ref=${hex(csrs.get(index))}`);
metadata.reference = { model: "independent RV32IM/Zicsr sequential interpreter", status: "PASS", retired: retired.length, stores: stores.length };
await writeFile(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);
console.log(`reference ${scenario.id}: PASS, ${retired.length} retired, ${stores.length} stores`);
