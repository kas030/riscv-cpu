#!/usr/bin/env node
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { computeRtlDigest } from "./rtl_digest.mjs";
import { disassemble } from "./disassemble.mjs";
import { validateAgainstSchema } from "./schema_validate.mjs";
import { computeTraceToolDigest } from "./trace_tool_digest.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../..");
const args = Object.fromEntries(process.argv.slice(2).map((item) => {
  const index = item.indexOf("=");
  return index < 0 ? [item.replace(/^--/, ""), true] : [item.slice(0, index).replace(/^--/, ""), item.slice(index + 1)];
}));
if (!args.raw || !args.out || !args.image || !args.bram || !args["sim-log"]) {
  console.error("usage: build_trace_index.mjs --raw=file --out=dir --image=file --bram=file --sim-log=file [--id=id --title=title]");
  process.exit(2);
}

const rawPath = resolve(process.cwd(), args.raw);
const outDir = resolve(process.cwd(), args.out);
const imagePath = resolve(process.cwd(), args.image);
const bramPath = resolve(process.cwd(), args.bram);
const simLogPath = resolve(process.cwd(), args["sim-log"]);
const id = String(args.id || basename(outDir));
const title = String(args.title || id);
const category = String(args.category || "directed");
const description = String(args.description || "由当前 RTL 的 CPU-only Verilator 仿真生成。 ");
const chunkSize = Number(args["chunk-size"] || 128);
if (!/^[a-z0-9][a-z0-9_-]*$/.test(id)) throw new Error(`非法场景 id: ${id}`);

const manifestBytes = await readFile(resolve(here, "manifest.json"));
const manifest = JSON.parse(manifestBytes.toString("utf8"));
const manifestSha256 = createHash("sha256").update(manifestBytes).digest("hex");
const traceSchema = JSON.parse(await readFile(resolve(here, "trace.schema.json"), "utf8"));
const signalIds = new Set(manifest.signals.map((signal) => signal.id));
const lines = (await readFile(rawPath, "utf8")).trim().split(/\r?\n/).map((line, index) => {
  try { return JSON.parse(line); } catch (error) { throw new Error(`raw JSONL 第 ${index + 1} 行无法解析: ${error.message}`); }
});
const header = lines.shift();
if (header?.type !== "header" || header.schemaVersion !== 1) throw new Error("raw trace header/schema 无效");
const headerSchemaErrors = validateAgainstSchema(header, traceSchema.$defs.rawHeader, { root: traceSchema, path: "raw.header" });
if (headerSchemaErrors.length) throw new Error(headerSchemaErrors.join("\n"));
const rawFrames = lines.filter((item) => item.type === "frame");
if (!rawFrames.length) throw new Error("raw trace 没有 frame");
for (let index = 0; index < rawFrames.length; index += 1) {
  const schemaErrors = validateAgainstSchema(rawFrames[index], traceSchema.$defs.rawFrame, { root: traceSchema, path: `raw.frame[${index}]` });
  if (schemaErrors.length) throw new Error(schemaErrors.join("\n"));
  if (rawFrames[index].cycle !== index + 1) throw new Error(`周期不连续: 期望 ${index + 1}，实际 ${rawFrames[index].cycle}`);
  for (const signal of Object.keys(rawFrames[index].signals)) if (!signalIds.has(signal)) throw new Error(`raw trace 包含 manifest 未声明信号: ${signal}`);
  for (const signal of signalIds) if (!(signal in rawFrames[index].signals)) throw new Error(`raw trace 缺少 manifest 信号: ${signal}`);
}

const simLog = await readFile(simLogPath, "utf8");
if (!simLog.includes(">>> [PASS]")) throw new Error("仿真未明确 PASS，拒绝发布 trace");
if (/stop_reason\s*:\s*timeout/.test(simLog)) throw new Error("仿真超时，拒绝发布 trace");
const metric = (name) => simLog.match(new RegExp(`${name}\\s*:\\s*([^\\n]+)`))?.[1]?.trim();
const { rtlDigest, files: rtlFiles } = await computeRtlDigest(repo);
const { traceToolDigest, files: traceToolFiles } = await computeTraceToolDigest(repo);
const image = await readFile(imagePath);
const imageHash = createHash("sha256").update(image).digest("hex");
const bramImage = await readFile(bramPath);
const bramHash = createHash("sha256").update(bramImage).digest("hex");
const coeVector = bramImage.toString("utf8").match(/memory_initialization_vector\s*=([\s\S]*?);/i)?.[1];
if (!coeVector) throw new Error(`无法解析 BRAM COE: ${bramPath}`);
const initialBramWords = coeVector.split(/[,\s]+/).filter(Boolean).map((word) => Number.parseInt(word.replace(/_/g, ""), 16) >>> 0);
const hex32 = (value) => (value >>> 0).toString(16).padStart(8, "0");
const decodeUsage = (instructionHex) => {
  const word = Number.parseInt(instructionHex, 16) >>> 0;
  const opcode = word & 0x7f;
  const rd = (word >>> 7) & 31;
  const rs1 = (word >>> 15) & 31;
  const rs2 = (word >>> 20) & 31;
  const writes = [0x03, 0x13, 0x17, 0x33, 0x37, 0x67, 0x6f, 0x73].includes(opcode) && rd !== 0;
  const reads1 = [0x03, 0x13, 0x23, 0x33, 0x63, 0x67, 0x73].includes(opcode);
  const reads2 = [0x23, 0x33, 0x63].includes(opcode);
  return {
    opcode, rd, rs1, rs2, writes, reads1, reads2,
    memory: opcode === 0x03 || opcode === 0x23,
    controlOrCsr: [0x63, 0x67, 0x6f, 0x73].includes(opcode),
    rv32m: opcode === 0x33 && ((word >>> 25) & 0x7f) === 0x01,
  };
};
const bramWordAt = (address) => initialBramWords[((address >>> 0) - 0x80100000) >>> 2] ?? 0;

const instructionMap = new Map();
const dead = new Set();
let previousActive = new Set();
let previousTags = {};
let lastRetired = -1;
let retired = 0;
const registers = Object.fromEntries(Array.from({ length: 32 }, (_, index) => [`x${index}`, "00000000"]));
const l0Lines = {};
const memoryState = {};
const observeMemoryWord = (address) => {
  const aligned = (address >>> 0) & 0xfffffffc;
  const key = hex32(aligned);
  if (!(key in memoryState)) memoryState[key] = hex32(bramWordAt(aligned));
  return key;
};
const applyStoreToMemory = (addressHex, mask, dataHex) => {
  const address = Number.parseInt(addressHex, 16) >>> 0;
  if (address < 0x80100000 || address > 0x8013ffff) return undefined;
  const key = observeMemoryWord(address);
  const prior = Number.parseInt(memoryState[key], 16) >>> 0;
  const data = Number.parseInt(dataHex, 16) >>> 0;
  const offset = address & 3;
  let next;
  if (mask === "10") next = data;
  else if (mask === "01") {
    const shift = (offset & 2) * 8;
    next = ((prior & ~(0xffff << shift)) | ((data & 0xffff) << shift)) >>> 0;
  } else {
    const shift = offset * 8;
    next = ((prior & ~(0xff << shift)) | ((data & 0xff) << shift)) >>> 0;
  }
  memoryState[key] = hex32(next);
  return key;
};
const csrNames = ["csr_mstatus", "csr_mtvec", "csr_mscratch", "csr_mepc", "csr_mcause"];
let priorSignals = {};
const frames = [];
const forwardingSources = {
  1: { data: "WB_wdata", rd: "WB_rd" },
  2: { data: "MEM_forward_data_effective", rd: "MEM_rd" },
  3: { data: "MEM2_forward_data", rd: "MEM2_rd" },
  4: { data: "WB_S1_wdata", rd: "WB_S1_rd" },
  5: { data: "MEM_S1_forward_data_effective", rd: "MEM_S1_rd" },
  6: { data: "MEM2_S1_forward_data", rd: "MEM2_S1_rd" },
};
const mmioNames = new Map([
  ["80200020", "SEG"],
  ["80200040", "LED"],
  ["80200050", "COUNTER"],
]);

for (const raw of rawFrames) {
  const observedMemoryThisFrame = new Set();
  const active = new Set();
  for (const [stage, lanes] of Object.entries(raw.tags)) {
    const expected = { ID: ["ID_valid", "ID_S1_valid"], EX: ["EX_valid", "EX_S1_valid"], MEM1: ["MEM_valid", "MEM_S1_valid"], MEM2: ["MEM2_valid", "MEM2_S1_valid"] }[stage];
    const stagePcSignals = { ID: ["ID_pc", "ID_pc1"], EX: ["EX_pc", "EX_S1_pc"] }[stage];
    lanes.forEach((tag, lane) => {
      if (expected && Boolean(tag) !== (raw.signals[expected[lane]] === "1")) throw new Error(`cycle ${raw.cycle}: ${stage} lane ${lane} tag/valid 不一致`);
      if (!tag) return;
      if (stagePcSignals && tag.pc !== raw.signals[stagePcSignals[lane]]) throw new Error(`cycle ${raw.cycle}: ${stage} lane ${lane} tag PC 与 RTL PC 不一致`);
      if (dead.has(tag.instructionId)) throw new Error(`cycle ${raw.cycle}: 已结束 tag ${tag.instructionId} 再次出现`);
      active.add(tag.instructionId);
      const known = instructionMap.get(tag.instructionId);
      if (known && (known.pc !== tag.pc || known.instruction !== tag.instruction)) throw new Error(`cycle ${raw.cycle}: tag ${tag.instructionId} 的 PC/指令发生变化`);
      if (!known) instructionMap.set(tag.instructionId, { instructionId: tag.instructionId, pc: tag.pc, instruction: tag.instruction, disassembly: disassemble(tag.instruction), issueCycle: raw.cycle, lane: tag.lane, lastSeen: raw.cycle });
      else known.lastSeen = raw.cycle;
    });
  }
  const idPair = raw.tags.ID;
  if (Boolean(idPair[1]) !== (raw.signals.ID_issue_dual === "1")) throw new Error(`cycle ${raw.cycle}: ID 槽 1 tag 与 ID_issue_dual 不一致`);
  if (idPair[0] && idPair[1]) {
    const older = decodeUsage(idPair[0].instruction);
    const younger = decodeUsage(idPair[1].instruction);
    const rawDependency = older.writes && ((younger.reads1 && older.rd === younger.rs1) || (younger.reads2 && older.rd === younger.rs2));
    const wawDependency = older.writes && younger.writes && older.rd === younger.rd;
    if (rawDependency || wawDependency) throw new Error(`cycle ${raw.cycle}: 双发射包内出现 ${rawDependency ? "RAW" : "WAW"} 依赖`);
    if (older.controlOrCsr || younger.controlOrCsr || (older.memory && younger.memory) || (older.rv32m && younger.rv32m)) throw new Error(`cycle ${raw.cycle}: 双发射包违反控制流/CSR/共享资源约束`);
  }
  for (const [lane, tag] of (raw.tags.MEM1 ?? []).entries()) {
    if (!tag || (Number.parseInt(tag.instruction, 16) & 0x7f) !== 0x03) continue;
    const instruction = instructionMap.get(tag.instructionId);
    const suffix = lane === 0 ? "" : "_S1";
    instruction.memory = { kind: "load", address: raw.signals[`MEM${suffix}_perip_addr`], rawValue: "00000000" };
    const address = Number.parseInt(instruction.memory.address, 16) >>> 0;
    if (address >= 0x80100000 && address <= 0x8013ffff) observedMemoryThisFrame.add(observeMemoryWord(address));
  }
  for (const [lane, tag] of (raw.tags.MEM2 ?? []).entries()) {
    if (!tag || (Number.parseInt(tag.instruction, 16) & 0x7f) !== 0x03) continue;
    const instruction = instructionMap.get(tag.instructionId);
    if (instruction.memory) instruction.memory.rawValue = raw.signals[lane === 0 ? "MEM2_mdata" : "MEM2_S1_mdata"];
  }
  if (priorSignals.Stall_Front === "1" && priorSignals.Flush_IF_ID === "0" && previousTags.ID && JSON.stringify(raw.tags.ID) !== JSON.stringify(previousTags.ID)) throw new Error(`cycle ${raw.cycle}: front stall 时 ID tag 未保持`);
  if (priorSignals.EX_any_busy === "1" && previousTags.EX && JSON.stringify(raw.tags.EX) !== JSON.stringify(previousTags.EX)) throw new Error(`cycle ${raw.cycle}: RV32M busy 时 EX tag 未保持`);

  const retireIds = [];
  for (const lane of [0, 1]) {
    if (!raw.edgeEvents[`retire${lane}`]) continue;
    const tag = raw.edgeEvents[`retireTag${lane}`];
    if (tag < 0 || !instructionMap.has(tag)) throw new Error(`cycle ${raw.cycle}: retire lane ${lane} 缺少有效 tag`);
    if (dead.has(tag)) throw new Error(`cycle ${raw.cycle}: 已结束 tag ${tag} 产生 retire 副作用`);
    const suffix = lane === 0 ? "" : "_S1";
    if (priorSignals[`WB${suffix}_wdata`] !== raw.edgeEvents[`retireData${lane}`]) throw new Error(`cycle ${raw.cycle}: 槽 ${lane} 退休值不等于上一 postEdge WB mux 输出`);
    retireIds.push(tag);
    if (tag <= lastRetired) throw new Error(`cycle ${raw.cycle}: 退休顺序非单调 (${lastRetired} -> ${tag})`);
    lastRetired = tag;
    retired += 1;
    instructionMap.get(tag).retireCycle = raw.cycle;
    if (raw.edgeEvents[`retireRegWrite${lane}`]) {
      const rd = raw.edgeEvents[`retireRd${lane}`];
      if (rd === 0) throw new Error(`cycle ${raw.cycle}: x0 出现有效写入`);
      registers[`x${rd}`] = raw.edgeEvents[`retireData${lane}`];
      instructionMap.get(tag).architecturalWrite = { register: `x${rd}`, value: raw.edgeEvents[`retireData${lane}`] };
      if (instructionMap.get(tag).memory?.kind === "load") instructionMap.get(tag).memory.architecturalValue = raw.edgeEvents[`retireData${lane}`];
    }
  }
  if (retireIds.length === 2 && retireIds[0] >= retireIds[1]) throw new Error(`cycle ${raw.cycle}: 双槽退休年龄顺序错误`);
  if (raw.edgeEvents.store && raw.edgeEvents.storeTag < 0) throw new Error(`cycle ${raw.cycle}: store 没有动态指令 tag`);
  if ((raw.edgeEvents.csrWrite || raw.edgeEvents.trapEnter || raw.edgeEvents.trapReturn) && raw.edgeEvents.csrTag < 0) throw new Error(`cycle ${raw.cycle}: CSR/trap 副作用没有 tag`);
  if (raw.edgeEvents.store) {
    if (dead.has(raw.edgeEvents.storeTag)) throw new Error(`cycle ${raw.cycle}: 已结束 tag ${raw.edgeEvents.storeTag} 产生 store 副作用`);
    if (priorSignals.perip_wen !== "1" || priorSignals.perip_addr !== raw.edgeEvents.storeAddr || priorSignals.perip_wdata !== raw.edgeEvents.storeData || priorSignals.perip_mask !== raw.edgeEvents.storeMask) throw new Error(`cycle ${raw.cycle}: store event 不等于上一 postEdge 总线值`);
    const validStore = (priorSignals.MEM_valid === "1" && priorSignals.MEM_MemWrite === "1") || (priorSignals.MEM_S1_valid === "1" && priorSignals.MEM_S1_MemWrite === "1");
    if (!validStore) throw new Error(`cycle ${raw.cycle}: 无有效 MEM1 槽产生 store`);
    instructionMap.get(raw.edgeEvents.storeTag).memory = { kind: "store", address: raw.edgeEvents.storeAddr, rawValue: raw.edgeEvents.storeData, mask: raw.edgeEvents.storeMask };
  }
  const storeAddress = Number.parseInt(raw.edgeEvents.storeAddr ?? "0", 16) >>> 0;
  const storeIsBram = Boolean(raw.edgeEvents.store) && storeAddress >= 0x80100000 && storeAddress <= 0x8013ffff;
  if (storeIsBram !== Boolean(raw.edgeEvents.l0Invalidate)) throw new Error(`cycle ${raw.cycle}: BRAM store 与 L0 invalidate 使能不一致`);
  if (raw.edgeEvents.l0Invalidate && ((Number.parseInt(raw.edgeEvents.l0InvalidateAddr, 16) >>> 2) !== (storeAddress >>> 2))) throw new Error(`cycle ${raw.cycle}: store 与 L0 invalidate 字地址不一致`);
  if (raw.edgeEvents.csrWrite || raw.edgeEvents.trapEnter || raw.edgeEvents.trapReturn) {
    if (dead.has(raw.edgeEvents.csrTag)) throw new Error(`cycle ${raw.cycle}: 已结束 tag ${raw.edgeEvents.csrTag} 产生 CSR/trap 副作用`);
    if (priorSignals.EX_valid !== "1") throw new Error(`cycle ${raw.cycle}: 无有效 EX 槽产生 CSR/trap 副作用`);
    instructionMap.get(raw.edgeEvents.csrTag).csr = {
      index: raw.edgeEvents.csrIndex,
      value: raw.edgeEvents.csrValue,
      operation: raw.edgeEvents.trapEnter ? "ecall trap entry" : raw.edgeEvents.trapReturn ? "mret trap return" : "CSR 写",
    };
  }
  if (raw.edgeEvents.redirect && (raw.edgeEvents.redirectTag < 0 || dead.has(raw.edgeEvents.redirectTag))) throw new Error(`cycle ${raw.cycle}: redirect 缺少有效来源动态指令`);
  const memoryUsers = Number(priorSignals.MEM_valid === "1" && (priorSignals.MEM_MemRead === "1" || priorSignals.MEM_MemWrite === "1")) + Number(priorSignals.MEM_S1_valid === "1" && (priorSignals.MEM_S1_MemRead === "1" || priorSignals.MEM_S1_MemWrite === "1"));
  if (memoryUsers > 1) throw new Error(`cycle ${raw.cycle}: 同拍出现 ${memoryUsers} 条共享数据总线访问`);

  const ended = [...previousActive].filter((tag) => !active.has(tag));
  const flushedIds = [];
  for (const tag of ended) {
    const instruction = instructionMap.get(tag);
    if (retireIds.includes(tag) || instruction?.retireCycle) dead.add(tag);
    else {
      dead.add(tag);
      instruction.flushCycle = raw.cycle;
      flushedIds.push(tag);
    }
  }

  const events = [];
  if (raw.signals.Stall_Front === "1") events.push({ type: "stall", label: raw.signals.LoadUseEX === "1" ? "LoadUseEX" : raw.signals.LoadUseMEM === "1" ? "LoadUseMEM" : "EX busy" });
  const redirectFlush = raw.signals.BranchMispredict === "1" || raw.signals.Flush_IF_ID === "1" || raw.signals.Flush_EX_MEM === "1";
  if (redirectFlush) events.push({ type: "flush", label: "控制流流水线冲刷" });
  else if (raw.signals.Flush_ID_EX_comb === "1") events.push({ type: "bubble", label: "ID/EX 注入气泡" });
  for (const tag of flushedIds) events.push({ type: "flush", label: "动态指令被冲刷，未提交", instructionId: tag });
  if (raw.edgeEvents.redirect) events.push({ type: "redirect", label: raw.edgeEvents.redirectReason === 1 ? "预测方向错误 → PC 重定向" : "预测目标错误/未预测目标 → PC 重定向", instructionId: raw.edgeEvents.redirectTag, address: raw.edgeEvents.redirectTarget, reason: raw.edgeEvents.redirectReason === 1 ? "direction" : "target" });
  if (raw.signals.EX_cache_probe_hit === "1") events.push({ type: "l0-hit", label: "L0 probe hit" });
  if (raw.edgeEvents.l0Fill) events.push({ type: "l0-miss", label: "L0 fill at sampled edge", address: raw.edgeEvents.l0FillAddr });
  if (raw.edgeEvents.l0Invalidate) events.push({ type: "l0-invalidate", label: "BRAM store → L0 invalidate", address: raw.edgeEvents.l0InvalidateAddr });
  if (raw.edgeEvents.store) {
    const peripheral = mmioNames.get(raw.edgeEvents.storeAddr);
    events.push({ type: "store", label: `${peripheral ? `${peripheral} write · ` : ""}store mask=${raw.edgeEvents.storeMask}`, instructionId: raw.edgeEvents.storeTag, address: raw.edgeEvents.storeAddr, value: raw.edgeEvents.storeData, peripheral });
  }
  if (raw.edgeEvents.csrWrite || raw.edgeEvents.trapEnter || raw.edgeEvents.trapReturn) events.push({ type: "csr-write", label: raw.edgeEvents.trapEnter ? "ecall trap entry" : raw.edgeEvents.trapReturn ? "mret" : `CSR 0x${raw.edgeEvents.csrIndex} write`, instructionId: raw.edgeEvents.csrTag, value: raw.edgeEvents.csrValue });
  for (const lane of [0, 1]) if (raw.edgeEvents[`retire${lane}`]) events.push({ type: "retire", label: `槽 ${lane} 退休`, instructionId: raw.edgeEvents[`retireTag${lane}`], lane, register: raw.edgeEvents[`retireRegWrite${lane}`] ? `x${raw.edgeEvents[`retireRd${lane}`]}` : undefined, value: raw.edgeEvents[`retireRegWrite${lane}`] ? raw.edgeEvents[`retireData${lane}`] : undefined });

  for (const lane of [0, 1]) for (const operand of ["A", "B"]) {
    const suffix = lane === 0 ? "" : "_S1";
    const select = Number.parseInt(raw.signals[`Forward${operand}${suffix}`], 2);
    const output = raw.signals[`Forward${operand}Data${suffix}`];
    const original = raw.signals[`EX_${lane === 0 ? "" : "S1_"}rR${operand === "A" ? "1" : "2"}_data`];
    const rs = raw.signals[`EX_${lane === 0 ? "" : "S1_"}rs${operand === "A" ? "1" : "2"}`];
    const source = forwardingSources[select];
    const expected = source ? raw.signals[source.data] : original;
    if (output !== expected) throw new Error(`cycle ${raw.cycle}: Forward${operand}${suffix} 的值 ${output} != 选择源 ${expected}`);
    if (source && Number.parseInt(rs, 16) !== Number.parseInt(raw.signals[source.rd], 16)) throw new Error(`cycle ${raw.cycle}: Forward${operand}${suffix} 的 rd 与消费者 rs 不匹配`);
  }

  const stages = Object.fromEntries(Object.entries(raw.tags).map(([stage, lanes]) => [stage, lanes.map((tag, lane) => tag ? { ...tag, state: previousTags[stage]?.[lane]?.instructionId === tag.instructionId ? "held" : "active" } : null)]));
  const changed = {};
  for (const [signal, value] of Object.entries(raw.signals)) if (priorSignals[signal] !== value || (raw.cycle - 1) % chunkSize === 0) changed[signal] = value;
  const chunkBoundary = (raw.cycle - 1) % chunkSize === 0;
  const registerDiff = chunkBoundary ? { ...registers } : {};
  if (!chunkBoundary) for (const lane of [0, 1]) if (raw.edgeEvents[`retire${lane}`] && raw.edgeEvents[`retireRegWrite${lane}`]) registerDiff[`x${raw.edgeEvents[`retireRd${lane}`]}`] = raw.edgeEvents[`retireData${lane}`];
  const csrDiff = chunkBoundary ? Object.fromEntries(csrNames.map((name) => [name.replace("csr_", ""), raw.signals[name]])) : {};
  if (!chunkBoundary) for (const name of csrNames) if (priorSignals[name] !== raw.signals[name]) csrDiff[name.replace("csr_", "")] = raw.signals[name];
  const storedWord = raw.edgeEvents.store ? applyStoreToMemory(raw.edgeEvents.storeAddr, raw.edgeEvents.storeMask, raw.edgeEvents.storeData) : undefined;
  if (storedWord) observedMemoryThisFrame.add(storedWord);
  const memoryDiff = chunkBoundary ? { ...memoryState } : Object.fromEntries([...observedMemoryThisFrame].map((address) => [address, memoryState[address]]));
  const l0Diff = {};
  if (raw.edgeEvents.l0Fill) {
    const address = Number.parseInt(raw.edgeEvents.l0FillAddr, 16) >>> 0;
    const line = String((address >>> 2) & 0x3f);
    l0Lines[line] = { valid: true, tag: ((address >>> 8) & 0x3ff).toString(16).padStart(3, "0"), data: raw.edgeEvents.l0FillData, address: raw.edgeEvents.l0FillAddr };
    l0Diff[line] = l0Lines[line];
  }
  if (raw.edgeEvents.l0Invalidate) {
    const address = Number.parseInt(raw.edgeEvents.l0InvalidateAddr, 16) >>> 0;
    const line = String((address >>> 2) & 0x3f);
    if ((Number.parseInt(l0Lines[line]?.address ?? "0", 16) >>> 2) === (address >>> 2)) {
      delete l0Lines[line];
      l0Diff[line] = { valid: false };
    }
  }
  if (chunkBoundary) {
    for (const key of Object.keys(l0Diff)) delete l0Diff[key];
    Object.assign(l0Diff, l0Lines);
  }
  frames.push({ cycle: raw.cycle, retireCount: retireIds.length, retiredTotal: retired, changed, stages, events, registers: registerDiff, csrs: csrDiff, memory: memoryDiff, l0: l0Diff });
  priorSignals = raw.signals;
  previousTags = raw.tags;
  previousActive = active;
}

const instructions = [...instructionMap.values()].sort((a, b) => a.instructionId - b.instructionId).map(({ lastSeen, ...instruction }) => instruction);
const chunks = [];
const tempDir = outDir;
await mkdir(tempDir, { recursive: true });
for (let start = 0; start < frames.length; start += chunkSize) {
  const part = frames.slice(start, start + chunkSize);
  const file = `cycles-${String(part[0].cycle).padStart(6, "0")}-${String(part.at(-1).cycle).padStart(6, "0")}.json`;
  await writeFile(resolve(tempDir, file), `${JSON.stringify({ schemaVersion: 1, frames: part })}\n`);
  chunks.push({ start: part[0].cycle, end: part.at(-1).cycle, file });
}
const reconstructedFrames = [];
for (const chunk of chunks) reconstructedFrames.push(...JSON.parse(await readFile(resolve(tempDir, chunk.file), "utf8")).frames);
if (JSON.stringify(reconstructedFrames) !== JSON.stringify(frames)) throw new Error("chunk 重建结果与规范化 frame 不一致");
const reconstructedSignals = {};
for (let index = 0; index < reconstructedFrames.length; index += 1) {
  const frame = reconstructedFrames[index];
  Object.assign(reconstructedSignals, frame.changed);
  if (JSON.stringify(reconstructedSignals) !== JSON.stringify(rawFrames[index].signals)) throw new Error(`chunk delta 重建信号与 raw JSONL 在 cycle ${frame.cycle} 不一致`);
  for (const [stage, lanes] of Object.entries(frame.stages)) {
    const publishedTags = lanes.map((tag) => tag ? { instructionId: tag.instructionId, pc: tag.pc, instruction: tag.instruction, lane: tag.lane } : null);
    if (JSON.stringify(publishedTags) !== JSON.stringify(rawFrames[index].tags[stage])) throw new Error(`chunk stage tag 与 raw JSONL 在 cycle ${frame.cycle} / ${stage} 不一致`);
  }
}

const git = (parameters) => spawnSync("git", parameters, { cwd: repo, encoding: "utf8" }).stdout.trim();
const gitCommit = git(["rev-parse", "HEAD"]) || "unknown";
const dirty = Boolean(git(["status", "--porcelain", "--", "rtl", "sim_cpu_only", "tools/cpu_visualizer"]));
const probeHash = createHash("sha256").update(await readFile(resolve(repo, "sim_cpu_only/visual_trace_probe.sv"))).digest("hex");
const metadata = {
  schemaVersion: 1,
  graphSchemaVersion: manifest.schemaVersion,
  manifestSha256,
  scenario: { id, title, category, description },
  rtl: { gitCommit, dirty, rtlDigest, files: rtlFiles.map((file) => file.slice(repo.length + 1)), probeHash },
  traceTool: { traceToolDigest, files: traceToolFiles },
  simulator: { verilator: spawnSync("verilator", ["--version"], { encoding: "utf8" }).stdout.trim(), sampling: header.sampling, configuration: { expectedLed: metric("expected_led"), passLed: metric("pass_led"), failLed: metric("fail_led") } },
  image: { file: basename(imagePath), sha256: imageHash, entry: "80000000" },
  bram: { file: basename(bramPath), sha256: bramHash, base: "80100000" },
  result: { status: "PASS", reason: metric("stop_reason"), expectedLed: metric("expected_led"), actualLed: metric("virtual_led") },
  totals: { cycles: rawFrames.at(-1).cycle, retired, testbenchRetired: Number.parseInt(metric("retired inst") || "0", 10) },
  functionalSha256: createHash("sha256").update(JSON.stringify(rawFrames)).digest("hex"),
  final: { registers, csrs: Object.fromEntries(csrNames.map((name) => [name.replace("csr_", ""), priorSignals[name]])), memory: memoryState },
};
if (metadata.totals.testbenchRetired !== retired) throw new Error(`退休计数不一致: probe=${retired}, testbench=${metadata.totals.testbenchRetired}`);
await writeFile(resolve(tempDir, "metadata.json"), `${JSON.stringify(metadata, null, 2)}\n`);

await mkdir(outDir, { recursive: true });

const indexPath = resolve(dirname(outDir), "index.json");
let index;
try { index = JSON.parse(await readFile(indexPath, "utf8")); } catch { index = { schemaVersion: 1, graphSchemaVersion: manifest.schemaVersion, rtlDigest, scenarios: [] }; }
index.rtlDigest = rtlDigest;
index.graphSchemaVersion = manifest.schemaVersion;
index.manifestSha256 = manifestSha256;
index.traceToolDigest = traceToolDigest;
const entry = { id, title, category, description, rtlDigest, manifestSha256, traceToolDigest, totalCycles: metadata.totals.cycles, retired, result: "PASS", metadata: `${id}/metadata.json`, chunks, instructions };
index.scenarios = [...(index.scenarios ?? []).filter((item) => item.id !== id), entry].sort((a, b) => a.id.localeCompare(b.id));
await writeFile(indexPath, `${JSON.stringify(index, null, 2)}\n`);
console.log(`trace ${id}: PASS, ${frames.length} cycles, ${retired} retired, ${chunks.length} chunks`);
