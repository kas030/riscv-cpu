#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(process.argv[2] ?? "site/public/generated/cpu-visualizer");
const index = JSON.parse(await readFile(resolve(root, "traces/index.json"), "utf8"));
const errors = [];
const requireCoverage = (condition, message) => { if (!condition) errors.push(message); };
const opcode = (hex) => Number.parseInt(hex, 16) & 0x7f;
const fields = (hex) => {
  const word = Number.parseInt(hex, 16) >>> 0;
  const opcode = word & 0x7f;
  const rd = (word >>> 7) & 31;
  return {
    opcode, rd, rs1: (word >>> 15) & 31, rs2: (word >>> 20) & 31,
    writes: [0x03, 0x13, 0x17, 0x33, 0x37, 0x67, 0x6f, 0x73].includes(opcode) && rd !== 0,
    reads1: [0x03, 0x13, 0x23, 0x33, 0x63, 0x67, 0x73].includes(opcode),
    reads2: [0x23, 0x33, 0x63].includes(opcode),
  };
};
const isAlu = (value) => [0x13, 0x17, 0x33, 0x37].includes(value.opcode);
const branchOutcomes = new Map(["beq", "bne", "blt", "bge", "bltu", "bgeu"].map((name) => [name, new Set()]));
const loadLanes = new Map(["lb", "lh", "lw", "lbu", "lhu"].map((name) => [name, new Set()]));
const storeLanes = new Map(["sb", "sh", "sw"].map((name) => [name, new Set()]));
const mnemonics = new Set();
const forwardingSelects = new Set();
const flushedMnemonics = new Set();
const mResults = new Map();
const busyRuns = [];
let conditionalCorrect = false;
let directionError = false;
let targetRedirect = false;
let l0HitDependent = false;
let l0Fill = false;
let l0Invalidate = false;
let loadUseEx = false;
let loadUseMem = false;
let lane1Memory = false;
let independentDualAlu = false;
let adjacentRawSingleIssue = false;
let adjacentWaw = false;
let dualLoadConsumers = false;
let simultaneousDualForward = false;

for (const scenario of index.scenarios) {
  const instructions = new Map(scenario.instructions.map((instruction) => [instruction.instructionId, instruction]));
  const retired = scenario.instructions.filter((instruction) => instruction.retireCycle);
  retired.forEach((instruction) => mnemonics.add(instruction.disassembly.split(" ")[0]));
  for (let offset = 1; offset < scenario.instructions.length; offset += 1) {
    const older = scenario.instructions[offset - 1];
    const younger = scenario.instructions[offset];
    const producer = fields(older.instruction);
    const consumer = fields(younger.instruction);
    const raw = producer.writes && ((consumer.reads1 && producer.rd === consumer.rs1) || (consumer.reads2 && producer.rd === consumer.rs2));
    adjacentRawSingleIssue ||= raw && younger.issueCycle > older.issueCycle;
    adjacentWaw ||= producer.writes && consumer.writes && producer.rd === consumer.rd && younger.issueCycle > older.issueCycle;
  }
  let state = {};
  let busyTag = -1;
  let busyLength = 0;
  const finishBusy = () => {
    if (busyLength) busyRuns.push({ mnemonic: instructions.get(busyTag)?.disassembly.split(" ")[0], length: busyLength });
    busyTag = -1;
    busyLength = 0;
  };
  for (const chunk of scenario.chunks) {
    const payload = JSON.parse(await readFile(resolve(root, "traces", scenario.id, chunk.file), "utf8"));
    for (const frame of payload.frames) {
      Object.assign(state, frame.changed);
      for (const id of ["ForwardA", "ForwardB", "ForwardA_S1", "ForwardB_S1"]) forwardingSelects.add(Number.parseInt(state[id], 2));
      loadUseEx ||= state.LoadUseEX === "1";
      loadUseMem ||= state.LoadUseMEM === "1";
      l0Fill ||= frame.events.some((event) => event.type === "l0-miss");
      l0Invalidate ||= frame.events.some((event) => event.type === "l0-invalidate");
      lane1Memory ||= state.MEM_use_s1_bus === "1" && state.MEM_S1_valid === "1" && (state.MEM_S1_MemRead === "1" || state.MEM_S1_MemWrite === "1");

      const exTags = frame.stages.EX ?? [];
      const ex0 = exTags[0] && instructions.get(exTags[0].instructionId);
      if (ex0 && opcode(ex0.instruction) === 0x63) {
        const name = ex0.disassembly.split(" ")[0];
        branchOutcomes.get(name)?.add(state.BranchTaken_raw);
        conditionalCorrect ||= state.BranchMispredict_raw === "0";
        directionError ||= state.BranchMispredict_raw === "1" && state.EX_pred_taken !== state.BranchTaken_raw;
      }
      if (ex0 && opcode(ex0.instruction) === 0x03 && state.EX_cache_probe_hit === "1") {
        const rd = fields(ex0.instruction).rd;
        const consumers = (frame.stages.ID ?? []).filter(Boolean).map((tag) => fields(tag.instruction));
        l0HitDependent ||= consumers.some((consumer) => consumer.rs1 === rd || consumer.rs2 === rd) && state.LoadUseEX === "0" && state.LoadUseMEM === "0";
      }
      if (exTags[0] && exTags[1]) {
        const left = fields(exTags[0].instruction);
        const right = fields(exTags[1].instruction);
        independentDualAlu ||= isAlu(left) && isAlu(right) && left.rd !== 0 && right.rd !== 0 && left.rd !== right.rd && right.rs1 !== left.rd && right.rs2 !== left.rd;
        dualLoadConsumers ||= left.opcode === 0x33 && right.opcode === 0x33 && [left.rs1, left.rs2, right.rs1, right.rs2].includes(11) && [left.rs1, left.rs2, right.rs1, right.rs2].includes(12);
        simultaneousDualForward ||= [state.ForwardA, state.ForwardB].some((value) => value !== "000") && [state.ForwardA_S1, state.ForwardB_S1].some((value) => value !== "000");
      }
      const currentBusyTag = exTags[0]?.instructionId ?? -1;
      if (state.EX_any_busy === "1") {
        if (busyLength && currentBusyTag !== busyTag) finishBusy();
        busyTag = currentBusyTag;
        busyLength += 1;
      } else finishBusy();

      for (const [lane, tag] of (frame.stages.MEM1 ?? []).entries()) {
        if (!tag || opcode(tag.instruction) !== 0x03) continue;
        const name = instructions.get(tag.instructionId).disassembly.split(" ")[0];
        const address = state[lane === 0 ? "MEM_perip_addr" : "MEM_S1_perip_addr"];
        loadLanes.get(name)?.add(Number.parseInt(address, 16) & 3);
      }
      for (const event of frame.events) {
        if (event.type === "redirect" && event.reason === "target") targetRedirect = true;
        if (event.type === "flush" && event.instructionId !== undefined) flushedMnemonics.add(instructions.get(event.instructionId)?.disassembly.split(" ")[0]);
        if (event.type === "store" && event.address?.startsWith("801")) {
          const instruction = instructions.get(event.instructionId);
          if (instruction) storeLanes.get(instruction.disassembly.split(" ")[0])?.add(Number.parseInt(event.address, 16) & 3);
        }
        if (event.type === "retire" && event.value) {
          const name = instructions.get(event.instructionId)?.disassembly.split(" ")[0];
          if (["mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"].includes(name)) {
            if (!mResults.has(name)) mResults.set(name, new Set());
            mResults.get(name).add(event.value);
          }
        }
      }
    }
  }
  finishBusy();
}

const scope = JSON.parse(await readFile(new URL("isa_scope.json", import.meta.url), "utf8"));
requireCoverage(scope.instructions.every((instruction) => mnemonics.has(instruction)), "supported instruction matrix has missing mnemonics");
for (const [name, outcomes] of branchOutcomes) requireCoverage(outcomes.has("0") && outcomes.has("1"), `${name} lacks taken/not-taken coverage`);
requireCoverage(loadLanes.get("lb").has(0) && loadLanes.get("lb").has(2), "lb lacks low/high byte lanes");
requireCoverage(loadLanes.get("lbu").has(0) && loadLanes.get("lbu").has(3), "lbu lacks low/high byte lanes");
requireCoverage(loadLanes.get("lh").has(0) && loadLanes.get("lh").has(2), "lh lacks both half-word lanes");
requireCoverage(loadLanes.get("lhu").has(0) && loadLanes.get("lhu").has(2), "lhu lacks both half-word lanes");
requireCoverage(loadLanes.get("lw").has(0), "lw lacks aligned word coverage");
requireCoverage([0, 1, 2, 3].every((lane) => storeLanes.get("sb").has(lane)), "sb lacks one or more byte lanes");
requireCoverage(storeLanes.get("sh").has(0) && storeLanes.get("sh").has(2), "sh lacks both half-word lanes");
requireCoverage(storeLanes.get("sw").has(0), "sw lacks aligned word coverage");
requireCoverage([0, 1, 2, 3, 4, 5, 6].every((select) => forwardingSelects.has(select)), "forwarding select matrix is incomplete");
requireCoverage(conditionalCorrect && directionError && targetRedirect, "prediction correct/direction-error/target-redirect matrix is incomplete");
requireCoverage(l0Fill && l0HitDependent && l0Invalidate && loadUseEx && loadUseMem, "L0 miss/hit/invalidate or load-use matrix is incomplete");
requireCoverage(lane1Memory && independentDualAlu && adjacentRawSingleIssue && adjacentWaw && dualLoadConsumers && simultaneousDualForward, "dual-issue/hazard/shared-bus matrix is incomplete");
requireCoverage(flushedMnemonics.has("sw") && [...flushedMnemonics].some((name) => name?.startsWith("csr")), "wrong-path store/CSR flush coverage is missing");
requireCoverage(busyRuns.some((run) => run.mnemonic === "mul" && run.length === 2), "MUL busy duration is missing");
requireCoverage(["mulh", "mulhsu", "mulhu"].every((name) => busyRuns.some((run) => run.mnemonic === name && run.length === 3)), "high multiply busy duration is missing");
requireCoverage(["div", "divu", "rem", "remu"].every((name) => busyRuns.some((run) => run.mnemonic === name && run.length === 33)), "iterative divide/remainder busy duration is missing");
requireCoverage(mResults.get("div")?.has("ffffffff") && mResults.get("div")?.has("80000000"), "DIV zero/overflow results are missing");
requireCoverage(mResults.get("divu")?.has("ffffffff"), "DIVU zero result is missing");
requireCoverage(mResults.get("rem")?.has("0000007b") && mResults.get("rem")?.has("00000000"), "REM zero/overflow results are missing");
requireCoverage(mResults.get("remu")?.has("0000007b"), "REMU zero result is missing");

if (errors.length) {
  console.error(`CPU visualizer scenario coverage failed (${errors.length}):`);
  errors.forEach((error) => console.error(`- ${error}`));
  process.exit(1);
}
console.log(`CPU visualizer scenario coverage OK: ${scope.instructions.length}/${scope.instructions.length} instructions, branch lanes, hazards, prediction, L0, RV32M and wrong-path effects`);
