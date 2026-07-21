#!/usr/bin/env node
import { access, cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { computeRtlDigest } from "../../tools/cpu_visualizer/rtl_digest.mjs";
import { computeTraceToolDigest } from "../../tools/cpu_visualizer/trace_tool_digest.mjs";
import { createHash } from "node:crypto";

const siteRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = resolve(siteRoot, "..");
const manifestPath = resolve(repoRoot, "tools/cpu_visualizer/manifest.json");
const outputRoot = resolve(siteRoot, "public/generated/cpu-visualizer");
const validator = spawnSync(process.execPath, [resolve(repoRoot, "tools/cpu_visualizer/validate_manifest.mjs"), manifestPath], { cwd: repoRoot, encoding: "utf8" });
if (validator.status !== 0) {
  process.stderr.write(validator.stderr || validator.stdout);
  process.exit(validator.status ?? 1);
}

const { rtlDigest, files: rtlFiles } = await computeRtlDigest(repoRoot);
const { traceToolDigest } = await computeTraceToolDigest(repoRoot);
const manifestSha256 = createHash("sha256").update(await readFile(manifestPath)).digest("hex");

await mkdir(resolve(outputRoot, "traces"), { recursive: true });
await cp(manifestPath, resolve(outputRoot, "graph.json"));
await writeFile(resolve(outputRoot, "build-info.json"), `${JSON.stringify({
  schemaVersion: 1,
  rtlDigest,
  manifestSha256,
  traceToolDigest,
  files: rtlFiles.map((path) => relative(repoRoot, path).split(sep).join("/")),
}, null, 2)}\n`);

const traceIndexPath = resolve(outputRoot, "traces/index.json");
let traceIndex;
try {
  traceIndex = JSON.parse(await readFile(traceIndexPath, "utf8"));
} catch {
  traceIndex = { schemaVersion: 1, graphSchemaVersion: 1, rtlDigest, scenarios: [] };
  await writeFile(traceIndexPath, `${JSON.stringify(traceIndex, null, 2)}\n`);
}
if (traceIndex.graphSchemaVersion !== 1) throw new Error("trace index 的 graphSchemaVersion 与 manifest 不匹配");
if (traceIndex.rtlDigest !== rtlDigest) throw new Error("trace index 的 RTL 摘要已过期，请重新生成全部 trace");
if (traceIndex.manifestSha256 !== manifestSha256) throw new Error("trace index 的 manifest 摘要已过期，请重新生成全部 trace");
if (traceIndex.traceToolDigest !== traceToolDigest) throw new Error("trace index 的采集/后处理工具摘要已过期，请重新生成全部 trace");
if (!(traceIndex.scenarios?.length > 0)) throw new Error("trace index 没有可发布场景");
const covered = new Set();
for (const scenario of traceIndex.scenarios ?? []) {
  if (scenario.rtlDigest !== rtlDigest) throw new Error(`场景 ${scenario.id} 的 RTL 摘要已过期，请重新生成 trace`);
  if (scenario.manifestSha256 !== manifestSha256) throw new Error(`场景 ${scenario.id} 的 manifest 摘要已过期，请重新生成 trace`);
  if (scenario.traceToolDigest !== traceToolDigest) throw new Error(`场景 ${scenario.id} 的 trace 工具摘要已过期，请重新生成 trace`);
  if (scenario.result !== "PASS") throw new Error(`场景 ${scenario.id} 未明确 PASS`);
  for (const instruction of scenario.instructions ?? []) if (instruction.retireCycle) covered.add(instruction.disassembly.split(" ")[0]);
  await access(resolve(outputRoot, "traces", scenario.metadata));
  for (const chunk of scenario.chunks ?? []) await access(resolve(outputRoot, "traces", scenario.id, chunk.file));
}
const traceValidator = spawnSync(process.execPath, [resolve(repoRoot, "tools/cpu_visualizer/validate_trace_data.mjs"), outputRoot], { cwd: repoRoot, encoding: "utf8" });
if (traceValidator.status !== 0) {
  process.stderr.write(traceValidator.stderr || traceValidator.stdout);
  process.exit(traceValidator.status ?? 1);
}
const scope = JSON.parse(await readFile(resolve(repoRoot, "tools/cpu_visualizer/isa_scope.json"), "utf8"));
const missing = scope.instructions.filter((instruction) => !covered.has(instruction));
if (missing.length) throw new Error(`发布 trace 未覆盖当前支持指令: ${missing.join(", ")}`);
const coverageValidator = spawnSync(process.execPath, [resolve(repoRoot, "tools/cpu_visualizer/verify_scenario_coverage.mjs"), outputRoot], { cwd: repoRoot, encoding: "utf8" });
if (coverageValidator.status !== 0) {
  process.stderr.write(coverageValidator.stderr || coverageValidator.stdout);
  process.exit(coverageValidator.status ?? 1);
}
console.log(`CPU visualizer data synced: rtl sha256 ${rtlDigest.slice(0, 12)}, ${traceIndex.scenarios?.length ?? 0} traces`);
