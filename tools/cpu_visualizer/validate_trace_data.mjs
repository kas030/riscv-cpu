#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { validateAgainstSchema } from "./schema_validate.mjs";

const root = resolve(process.argv[2] ?? "site/public/generated/cpu-visualizer");
const [schema, graph, index] = await Promise.all([
  readFile(new URL("trace.schema.json", import.meta.url), "utf8").then(JSON.parse),
  readFile(resolve(root, "graph.json"), "utf8").then(JSON.parse),
  readFile(resolve(root, "traces/index.json"), "utf8").then(JSON.parse),
]);
const errors = validateAgainstSchema(index, schema.$defs.index, { root: schema, path: "index" });
const signalIds = new Set(graph.signals.map((signal) => signal.id));
const signalById = new Map(graph.signals.map((signal) => [signal.id, signal]));
const validateSignalValue = (scenarioId, cycle, id, value) => {
  const signal = signalById.get(id);
  if (!signal || typeof value !== "string") return;
  const binaryLength = signal.width;
  const hexLength = Math.ceil(signal.width / 4);
  if (!/^[0-9a-fxz]+$/i.test(value) || (value.length !== binaryLength && value.length !== hexLength)) {
    errors.push(`${scenarioId}: ${id} value ${JSON.stringify(value)} does not encode ${signal.width} bits at cycle ${cycle}`);
  }
};
for (const scenario of index.scenarios ?? []) {
  const metadata = JSON.parse(await readFile(resolve(root, "traces", scenario.metadata), "utf8"));
  errors.push(...validateAgainstSchema(metadata, schema.$defs.metadata, { root: schema, path: `${scenario.id}.metadata` }));
  if (scenario.result !== "PASS" || metadata.result?.status !== "PASS") errors.push(`${scenario.id}: result is not PASS`);
  if (scenario.rtlDigest !== index.rtlDigest || metadata.rtl?.rtlDigest !== index.rtlDigest) errors.push(`${scenario.id}: RTL digest mismatch`);
  if (scenario.manifestSha256 !== index.manifestSha256 || metadata.manifestSha256 !== index.manifestSha256) errors.push(`${scenario.id}: manifest digest mismatch`);
  if (scenario.traceToolDigest !== index.traceToolDigest || metadata.traceTool?.traceToolDigest !== index.traceToolDigest) errors.push(`${scenario.id}: trace tool digest mismatch`);
  if (metadata.reference?.status !== "PASS") errors.push(`${scenario.id}: reference result is not PASS`);
  let expectedCycle = 1;
  let retiredTotal = 0;
  for (const chunk of scenario.chunks ?? []) {
    const payload = JSON.parse(await readFile(resolve(root, "traces", scenario.id, chunk.file), "utf8"));
    errors.push(...validateAgainstSchema(payload, schema.$defs.chunk, { root: schema, path: `${scenario.id}.${chunk.file}` }));
    if (payload.frames?.[0]?.cycle !== chunk.start || payload.frames?.at(-1)?.cycle !== chunk.end) errors.push(`${scenario.id}.${chunk.file}: chunk range mismatch`);
    if (new Set(Object.keys(payload.frames?.[0]?.changed ?? {})).size !== signalIds.size || [...signalIds].some((id) => !(id in payload.frames[0].changed))) errors.push(`${scenario.id}.${chunk.file}: first frame is not a complete state snapshot`);
    for (const frame of payload.frames ?? []) {
      if (frame.cycle !== expectedCycle++) errors.push(`${scenario.id}: cycle gap at ${frame.cycle}`);
      if (frame.retireCount !== frame.events.filter((event) => event.type === "retire").length) errors.push(`${scenario.id}: retireCount mismatch at ${frame.cycle}`);
      retiredTotal += frame.retireCount;
      if (frame.retiredTotal !== retiredTotal) errors.push(`${scenario.id}: retiredTotal mismatch at ${frame.cycle}`);
      for (const [id, value] of Object.entries(frame.changed)) {
        if (!signalIds.has(id)) errors.push(`${scenario.id}: undeclared signal ${id}`);
        else validateSignalValue(scenario.id, frame.cycle, id, value);
      }
    }
  }
  if (expectedCycle - 1 !== scenario.totalCycles || retiredTotal !== scenario.retired || metadata.totals?.retired !== retiredTotal) errors.push(`${scenario.id}: totals mismatch`);
}
if (errors.length) {
  console.error(`CPU visualizer trace schema validation failed (${errors.length}):`);
  errors.slice(0, 100).forEach((error) => console.error(`- ${error}`));
  process.exit(1);
}
console.log(`CPU visualizer trace schema OK: ${index.scenarios.length} PASS scenarios`);
