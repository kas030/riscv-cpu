import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const files = [
  "sim_cpu_only/tb_cpu_only.sv",
  "sim_cpu_only/tb_visual_trace.sv",
  "sim_cpu_only/visual_trace_probe.sv",
  "sim_cpu_only/visual_trace.mk",
  "tools/cpu_visualizer/build_trace_index.mjs",
  "tools/cpu_visualizer/disassemble.mjs",
  "tools/cpu_visualizer/reference_compare.mjs",
  "tools/cpu_visualizer/schema_validate.mjs",
  "tools/cpu_visualizer/trace.schema.json",
  "tools/cpu_visualizer/trace_tool_digest.mjs"
];

export async function computeTraceToolDigest(repoRoot) {
  const hash = createHash("sha256");
  for (const file of files) {
    hash.update(file);
    hash.update("\0");
    hash.update(await readFile(resolve(repoRoot, file)));
    hash.update("\0");
  }
  return { traceToolDigest: hash.digest("hex"), files };
}
