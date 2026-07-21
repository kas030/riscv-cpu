import assert from "node:assert/strict";
import { readFile, stat } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";

const site = new URL("../", import.meta.url);
const repo = new URL("../../", import.meta.url);
const generated = new URL("public/generated/cpu-visualizer/", site);

test("graph manifest covers the complete current RTL instance tree", async () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL("tools/cpu_visualizer/validate_manifest.mjs", repo))], { cwd: fileURLToPath(repo), encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const graph = JSON.parse(await readFile(new URL("graph.json", generated), "utf8"));
  assert.equal(graph.modules.length, 52);
  assert.equal(graph.signals.length, 202);
  assert.ok(graph.modules.some((item) => item.path === "mycpu.u_ex_stage.u_rv32m_unit"));
  assert.ok(graph.modules.some((item) => item.path.endsWith("u_wb_mux.u_mux_key_internal")));
  const moduleIds = new Set(graph.modules.map((item) => item.id));
  const portIds = new Set(graph.ports.map((item) => item.id));
  const signalIds = new Set(graph.signals.map((item) => item.id));
  for (const port of graph.ports) assert.ok(moduleIds.has(port.moduleId));
  const observableModules = new Set();
  for (const edge of graph.edges) {
    assert.ok(portIds.has(edge.source));
    assert.ok(portIds.has(edge.target));
    observableModules.add(graph.ports.find((port) => port.id === edge.source).moduleId);
    observableModules.add(graph.ports.find((port) => port.id === edge.target).moduleId);
    for (const signal of edge.signalIds) assert.ok(signalIds.has(signal));
  }
  assert.deepEqual(graph.modules.filter((module) => !observableModules.has(module.id)), []);
});

test("published payloads stay within the static playback loading budget", async () => {
  const index = JSON.parse(await readFile(new URL("traces/index.json", generated), "utf8"));
  const graphBytes = (await stat(new URL("graph.json", generated))).size;
  const indexBytes = (await stat(new URL("traces/index.json", generated))).size;
  const first = index.scenarios[0];
  const firstChunkBytes = (await stat(new URL(`traces/${first.id}/${first.chunks[0].file}`, generated))).size;
  assert.ok(graphBytes + indexBytes + firstChunkBytes < 1_000_000, "initial graph/index/chunk payload exceeds 1 MB");
  for (const scenario of index.scenarios) for (const chunk of scenario.chunks) {
    assert.ok((await stat(new URL(`traces/${scenario.id}/${chunk.file}`, generated))).size < 512_000, `${scenario.id}/${chunk.file} exceeds 512 KB`);
    assert.ok(chunk.end - chunk.start + 1 <= 128);
  }
});

test("published traces are PASS, digest-matched, contiguous and delta-reconstructable", async () => {
  const [graph, buildInfo, index] = await Promise.all([
    readFile(new URL("graph.json", generated), "utf8").then(JSON.parse),
    readFile(new URL("build-info.json", generated), "utf8").then(JSON.parse),
    readFile(new URL("traces/index.json", generated), "utf8").then(JSON.parse),
  ]);
  assert.equal(index.rtlDigest, buildInfo.rtlDigest);
  assert.equal(index.manifestSha256, buildInfo.manifestSha256);
  assert.equal(index.traceToolDigest, buildInfo.traceToolDigest);
  assert.ok(index.scenarios.length >= 8);
  for (const scenario of index.scenarios) {
    assert.equal(scenario.result, "PASS");
    assert.equal(scenario.rtlDigest, buildInfo.rtlDigest);
    assert.equal(scenario.manifestSha256, buildInfo.manifestSha256);
    assert.equal(scenario.traceToolDigest, buildInfo.traceToolDigest);
    const metadata = JSON.parse(await readFile(new URL(`traces/${scenario.metadata}`, generated), "utf8"));
    assert.equal(metadata.result.status, "PASS");
    assert.equal(metadata.rtl.rtlDigest, buildInfo.rtlDigest);
    assert.equal(metadata.manifestSha256, buildInfo.manifestSha256);
    assert.equal(metadata.traceTool.traceToolDigest, buildInfo.traceToolDigest);
    assert.equal(metadata.totals.retired, scenario.retired);
    assert.match(metadata.functionalSha256, /^[0-9a-f]{64}$/);
    assert.equal(metadata.reference.status, "PASS");
    assert.equal(metadata.reference.retired, scenario.retired);
    const state = {};
    let previousCycle = 0;
    let count = 0;
    for (const chunk of scenario.chunks) {
      const payload = JSON.parse(await readFile(new URL(`traces/${scenario.id}/${chunk.file}`, generated), "utf8"));
      assert.equal(payload.frames[0].cycle, chunk.start);
      assert.equal(payload.frames.at(-1).cycle, chunk.end);
      assert.equal(Object.keys(payload.frames[0].changed).length, graph.signals.length, `${scenario.id}/${chunk.file} 缺少独立 chunk 快照`);
      for (const frame of payload.frames) {
        assert.equal(frame.cycle, previousCycle + 1);
        Object.assign(state, frame.changed);
        previousCycle = frame.cycle;
        count += 1;
      }
    }
    assert.equal(count, scenario.totalCycles);
    assert.equal(Object.keys(state).length, graph.signals.length);
  }
});

test("retired dynamic instructions cover the declared RV32I/RV32M/Zicsr scope", async () => {
  const [scope, index] = await Promise.all([
    readFile(new URL("tools/cpu_visualizer/isa_scope.json", repo), "utf8").then(JSON.parse),
    readFile(new URL("traces/index.json", generated), "utf8").then(JSON.parse),
  ]);
  const covered = new Set(index.scenarios.flatMap((scenario) => scenario.instructions.filter((instruction) => instruction.retireCycle).map((instruction) => instruction.disassembly.split(" ")[0])));
  assert.deepEqual(scope.instructions.filter((instruction) => !covered.has(instruction)), []);
});

test("course content no longer embeds handwritten cycle results", async () => {
  const [content, shell] = await Promise.all([
    readFile(new URL("app/content.ts", site), "utf8"),
    readFile(new URL("app/CourseShell.tsx", site), "utf8"),
  ]);
  assert.doesNotMatch(content, /PipelineScenario|export const scenarios|LoadUseEX.*stages/);
  assert.match(shell, /href="\/simulator"/);
});
