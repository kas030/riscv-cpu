#!/usr/bin/env node
import { readFile } from "node:fs/promises";

if (process.argv.length !== 4) {
  console.error("usage: compare_sim_logs.mjs <trace-on.log> <trace-off.log>");
  process.exit(2);
}
const [on, off] = await Promise.all(process.argv.slice(2).map((path) => readFile(path, "utf8")));
const fields = ["stop_reason", "virtual_led", "cycles", "writeback (reg_file)", "slot1 writeback", "stores", "taken branches", "dual issue packets", "front stall cycles", "load/use EX stalls", "load/use MEM stalls", "ex busy cycles", "L0 load hits", "BRAM loads", "retired inst", "retire digest", "store digest", "register signature", "csr signature", "pc"];
const value = (log, field) => log.match(new RegExp(`^\\s*${field.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*:\\s*(.+)$`, "m"))?.[1]?.trim();
if (!on.includes(">>> [PASS]") || !off.includes(">>> [PASS]")) throw new Error("trace on/off 仿真没有同时明确 PASS");
for (const field of fields) {
  const onValue = value(on, field);
  const offValue = value(off, field);
  if (onValue === undefined || offValue === undefined) throw new Error(`日志缺少比较字段: ${field}`);
  if (onValue !== offValue) throw new Error(`trace 开关改变 ${field}: on=${onValue}, off=${offValue}`);
}
console.log(`trace on/off equivalent: ${fields.length} architectural/performance metrics match`);
