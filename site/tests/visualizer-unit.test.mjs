import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import test from "node:test";
import ts from "typescript";

const site = fileURLToPath(new URL("../", import.meta.url));
const sourceRoot = resolve(site, "app/simulator/lib");
const outputRoot = await mkdtemp(join(tmpdir(), "cpu-visualizer-unit-"));
for (const name of ["disassemble", "format-value", "forwarding", "graph-model", "instruction-path", "trace-reducer", "types"]) {
  const source = await readFile(resolve(sourceRoot, `${name}.ts`), "utf8");
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
    .replace(/from "(\.\/[^".]+)"/g, 'from "$1.js"');
  await mkdir(dirname(resolve(outputRoot, `${name}.js`)), { recursive: true });
  await writeFile(resolve(outputRoot, `${name}.js`), output);
}
const load = (name) => import(`${pathToFileURL(resolve(outputRoot, `${name}.js`)).href}?v=${Date.now()}`);

test("delta frames rebuild state and detect changed signals", async () => {
  const { changedSignals, reconstructFrames } = await load("trace-reducer");
  const empty = { stages: {}, events: [], registers: {}, csrs: {}, memory: {}, l0: {}, retireCount: 0, retiredTotal: 0 };
  const frames = reconstructFrames([
    { ...empty, cycle: 1, changed: { pc: "80000000", valid: "0" } },
    { ...empty, cycle: 2, changed: { pc: "80000004" } },
  ]);
  assert.deepEqual(frames[1].signals, { pc: "80000004", valid: "0" });
  assert.deepEqual([...changedSignals(frames[1].signals, frames[0].signals)], ["pc"]);
  assert.throws(() => reconstructFrames([{ ...empty, cycle: 1, changed: {} }, { ...empty, cycle: 3, changed: {} }]), /cycle gap/);
});

test("32-bit values preserve signed, instruction and X/Z representations", async () => {
  const { formatSignalValue, hasUnknown } = await load("format-value");
  const signed = { width: 32, format: "signed" };
  assert.equal(formatSignalValue("ffffffff", signed, "signed"), "-1");
  assert.equal(formatSignalValue("0000002a", { width: 32, format: "hex" }, "unsigned"), "42");
  assert.match(formatSignalValue("00500093", { width: 32, format: "instruction" }), /addi ra,zero,5/);
  assert.equal(formatSignalValue("xxxx0000", { width: 32, format: "hex" }), "XXXX0000");
  assert.equal(hasUnknown("00z0"), true);
});

test("module/edge filtering and forwarding decode use manifest semantics", async () => {
  const { connectionsForSignal, filterGraphBySignalGroup, moduleAncestors, modulesForSearch, signalsForModule, sourceForSignal } = await load("graph-model");
  const { decodeForwardSource } = await load("forwarding");
  const graph = {
    modules: [{ id: "root", label: "EX", module: "stage", path: "mycpu.ex", source: { file: "rtl/ex.sv", line: 1 } }, { id: "alu", parent: "root", label: "ALU", module: "alu", path: "mycpu.ex.alu", source: { file: "rtl/alu.sv", line: 9 } }],
    ports: [{ id: "root.out", moduleId: "root" }, { id: "alu.in", moduleId: "alu" }],
    signals: [{ id: "data", group: "execute" }, { id: "hold", group: "control" }],
    edges: [{ id: "data-edge", source: "root.out", target: "alu.in", kind: "data", signalIds: ["data"] }, { id: "static", source: "root.out", target: "alu.in", kind: "static", signalIds: [] }],
  };
  assert.deepEqual(moduleAncestors(graph.modules[1], graph), ["root"]);
  assert.deepEqual(modulesForSearch(graph, "mycpu.ex.alu").map((item) => item.id), ["alu"]);
  assert.deepEqual([...signalsForModule(graph, "alu")], ["data"]);
  assert.deepEqual(connectionsForSignal(graph, "data").map((connection) => [connection.sourceModule.id, connection.sourcePort.id, connection.targetModule.id, connection.targetPort.id]), [["root", "root.out", "alu", "alu.in"]]);
  assert.deepEqual(sourceForSignal(graph, "mycpu.ex.alu.result"), { file: "rtl/alu.sv", line: 9, symbol: "result" });
  assert.deepEqual(sourceForSignal(graph, "mycpu.top_signal"), { file: "rtl/core/mycpu.sv", symbol: "top_signal" });
  assert.deepEqual(filterGraphBySignalGroup(graph, "control").edges.map((edge) => edge.id), ["static"]);
  assert.equal(decodeForwardSource("101").label, "MEM1 / 槽 1");
  assert.equal(decodeForwardSource("000"), undefined);
});

test("instruction presentation distinguishes hold, bubble, flush and retire", async () => {
  const { instructionStateAt } = await load("trace-reducer");
  const instruction = { instructionId: 7, retireCycle: 9, flushCycle: undefined };
  const frame = (cycle, stages = {}, events = []) => ({ cycle, stages, events });
  assert.deepEqual(instructionStateAt(frame(3, { EX: [{ instructionId: 7, lane: 0, state: "held" }, null] }), instruction), { status: "held", stage: "EX", lane: 0 });
  assert.deepEqual(instructionStateAt(frame(4, {}, [{ type: "bubble" }]), { ...instruction, retireCycle: undefined }), { status: "bubble" });
  assert.deepEqual(instructionStateAt(frame(5, {}, [{ type: "flush", instructionId: 7 }]), { ...instruction, retireCycle: undefined }), { status: "flushed" });
  assert.deepEqual(instructionStateAt(frame(9, {}, [{ type: "retire", instructionId: 7 }]), instruction), { status: "retired" });
});

test("selected instruction path includes only its lane and functional units", async () => {
  const { modulesForInstructionAt } = await load("instruction-path");
  assert.deepEqual(modulesForInstructionAt("EX", 1, "022081b3", true), ["id_ex1", "ex1", "alu1", "forward1", "rv32m1"]);
  assert.deepEqual(modulesForInstructionAt("MEM1", 0, "00012083", true), ["ex_mem0", "mem_stage", "lsu", "l0", "mem_load_mask0"]);
  assert.ok(modulesForInstructionAt("WB", 0, "00012083", true).includes("wb_load_mask0"));
  assert.ok(!modulesForInstructionAt("WB", 1, "00108093", false).includes("reg_file"));
  assert.ok(modulesForInstructionAt("EX", 0, "300110f3", true).includes("csr0"));
  assert.ok(!modulesForInstructionAt("EX", 0, "00108093", true).includes("rv32m0"));
});
