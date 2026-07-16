import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const siteRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.resolve(siteRoot, "..");

const manifest = [
  { id: "if-dual", file: "rtl/pipeline/stage/mycpu_if_stage.sv", start: "localparam DUAL_HINT_INDEX_WIDTH = 8;", end: "!IF_slot_raw_hazard;" },
  { id: "predictor", file: "rtl/pipeline/stage/mycpu_if_stage.sv", start: "module branch_predictor #(", end: "endmodule" },
  { id: "decoder", file: "rtl/control/mycpu_decoder.sv", start: "module mycpu_decoder #(", end: "endmodule" },
  { id: "redirect", file: "rtl/control/mycpu_redirect_ctrl.sv", start: "module mycpu_redirect_ctrl #(", end: "endmodule" },
  { id: "m-unit", file: "rtl/datapath/rv32m_unit.sv", start: "module rv32m_unit #(", end: "endmodule" },
  { id: "l0", file: "rtl/memory/load_l0_cache.sv", start: "module load_l0_cache #(", end: "endmodule" },
  { id: "writeback", file: "rtl/pipeline/stage/mycpu_wb_stage.sv", start: "module mycpu_wb_stage #(", end: "endmodule" },
  { id: "hazard", file: "rtl/hazard/hazard_unit.sv", start: "module hazard_unit (", end: "endmodule" },
  { id: "forward", file: "rtl/hazard/forwarding_unit.sv", start: "module forwarding_unit (", end: "endmodule" },
  { id: "pipeline-control", file: "rtl/core/mycpu.sv", start: "// 前半段统一停顿条件：", end: "assign Stall           = Stall_Front;" },
];

function uniqueIndex(text, marker, file) {
  const first = text.indexOf(marker);
  const second = first < 0 ? -1 : text.indexOf(marker, first + marker.length);
  if (first < 0) throw new Error(`${file}: marker not found: ${marker}`);
  if (second >= 0) throw new Error(`${file}: marker is not unique: ${marker}`);
  return first;
}

const snippets = {};
for (const item of manifest) {
  const absolute = path.join(repoRoot, item.file);
  const source = await readFile(absolute, "utf8");
  const start = uniqueIndex(source, item.start, item.file);
  const endFromStart = source.indexOf(item.end, start + item.start.length);
  if (endFromStart < 0) throw new Error(`${item.file}: end marker not found after start: ${item.end}`);
  const end = endFromStart + item.end.length;
  const before = source.slice(0, start);
  snippets[item.id] = {
    path: item.file,
    line: before.split(/\r?\n/).length,
    code: source.slice(start, end).trim(),
  };
}

const outputDir = path.join(siteRoot, "app", "generated");
await mkdir(outputDir, { recursive: true });
await writeFile(path.join(outputDir, "rtl-snippets.json"), `${JSON.stringify(snippets, null, 2)}\n`, "utf8");
console.log(`Synced ${Object.keys(snippets).length} RTL excerpts.`);
