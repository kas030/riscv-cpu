import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const generated = new URL("../public/generated/cpu-visualizer/", import.meta.url);

test("dynamic instruction tags never reappear after retire or flush", async () => {
  const index = JSON.parse(await readFile(new URL("traces/index.json", generated), "utf8"));
  for (const scenario of index.scenarios) {
    const terminal = new Set();
    const instructions = new Map(scenario.instructions.map((instruction) => [instruction.instructionId, instruction]));
    const seen = new Set();
    for (const chunk of scenario.chunks) {
      const payload = JSON.parse(await readFile(new URL(`traces/${scenario.id}/${chunk.file}`, generated), "utf8"));
      for (const frame of payload.frames) {
        for (const lanes of Object.values(frame.stages)) for (const tag of lanes) {
          if (!tag) continue;
          assert.ok(instructions.has(tag.instructionId));
          assert.equal(terminal.has(tag.instructionId), false, `${scenario.id} tag ${tag.instructionId} reappeared`);
          seen.add(tag.instructionId);
        }
        for (const event of frame.events) if ((event.type === "retire" || event.type === "flush") && event.instructionId !== undefined) terminal.add(event.instructionId);
      }
    }
    assert.ok(seen.size > 0);
    const retired = scenario.instructions.filter((instruction) => instruction.retireCycle).map((instruction) => instruction.instructionId);
    assert.deepEqual([...retired].sort((a, b) => a - b), retired);
  }
});

test("representative traces contain real microarchitecture events", async () => {
  const index = JSON.parse(await readFile(new URL("traces/index.json", generated), "utf8"));
  const collectEvents = async (id) => {
    const scenario = index.scenarios.find((item) => item.id === id);
    assert.ok(scenario, `missing ${id}`);
    const events = [];
    for (const chunk of scenario.chunks) events.push(...JSON.parse(await readFile(new URL(`traces/${id}/${chunk.file}`, generated), "utf8")).frames.flatMap((frame) => frame.events));
    return events;
  };
  assert.ok((await collectEvents("t08_load_use")).some((event) => event.type === "stall" && /LoadUse/.test(event.label)));
  assert.ok((await collectEvents("t09_branch_hazard")).some((event) => event.type === "redirect"));
  assert.ok((await collectEvents("t09_branch_hazard")).some((event) => event.type === "flush" && event.instructionId !== undefined && /未提交/.test(event.label)));
  assert.ok((await collectEvents("t19_zicsr_trap")).some((event) => event.type === "csr-write"));
  const coverage = index.scenarios.find((item) => item.id === "visualizer_isa_coverage");
  assert.ok(coverage.instructions.some((instruction) => instruction.lane === 1 && instruction.retireCycle));
  const lane1Memory = index.scenarios.find((item) => item.id === "visualizer_lane1_memory");
  let lane1BusSeen = false;
  const state = {};
  for (const chunk of lane1Memory.chunks) for (const frame of JSON.parse(await readFile(new URL(`traces/${lane1Memory.id}/${chunk.file}`, generated), "utf8")).frames) {
    Object.assign(state, frame.changed);
    lane1BusSeen ||= state.MEM_use_s1_bus === "1" && state.MEM_S1_MemRead === "1";
  }
  assert.equal(lane1BusSeen, true);
});

test("published scenes cover forwarding priority, prediction, L0 and RV32M busy", async () => {
  const index = JSON.parse(await readFile(new URL("traces/index.json", generated), "utf8"));
  const forwardSelects = new Set();
  let l0Hit = false;
  let l0Fill = false;
  let mBusy = false;
  let predictedTakenUpdate = false;
  let predictedNotTakenUpdate = false;
  let rawMispredict = false;
  let adjacentWaw = false;
  const writesRd = (instruction) => {
    const word = Number.parseInt(instruction, 16) >>> 0;
    return [0x03, 0x13, 0x17, 0x33, 0x37, 0x67, 0x6f, 0x73].includes(word & 0x7f) ? (word >>> 7) & 31 : 0;
  };
  for (const scenario of index.scenarios) {
    const state = {};
    for (const chunk of scenario.chunks) for (const frame of JSON.parse(await readFile(new URL(`traces/${scenario.id}/${chunk.file}`, generated), "utf8")).frames) {
      Object.assign(state, frame.changed);
      for (const id of ["ForwardA", "ForwardB", "ForwardA_S1", "ForwardB_S1"]) forwardSelects.add(Number.parseInt(state[id], 2));
      l0Hit ||= state.EX_cache_probe_hit === "1";
      l0Fill ||= state.MEM_cache_fill_en === "1";
      mBusy ||= state.EX_any_busy === "1";
      rawMispredict ||= state.BranchMispredict_raw === "1";
      if (state.BP_update_en === "1") {
        predictedTakenUpdate ||= state.BP_update_taken === "1";
        predictedNotTakenUpdate ||= state.BP_update_taken === "0";
      }
    }
    const retired = scenario.instructions.filter((instruction) => instruction.retireCycle);
    for (let index = 1; index < retired.length; index += 1) {
      const prior = writesRd(retired[index - 1].instruction);
      adjacentWaw ||= prior !== 0 && prior === writesRd(retired[index].instruction);
    }
  }
  assert.deepEqual([...forwardSelects].sort(), [0, 1, 2, 3, 4, 5, 6]);
  assert.equal(l0Hit && l0Fill && mBusy && rawMispredict && predictedTakenUpdate && predictedNotTakenUpdate && adjacentWaw, true);
});
