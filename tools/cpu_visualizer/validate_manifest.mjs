#!/usr/bin/env node
import { readFile, access, readdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { validateAgainstSchema } from "./schema_validate.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../..");
const manifestPath = process.argv[2] ? resolve(process.cwd(), process.argv[2]) : resolve(here, "manifest.json");
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const errors = [];
const manifestSchema = JSON.parse(await readFile(resolve(here, "manifest.schema.json"), "utf8"));
errors.push(...validateAgainstSchema(manifest, manifestSchema, { path: "manifest" }));

const requireKeys = (object, keys, at) => {
  for (const key of keys) if (!(key in object)) errors.push(`${at}: 缺少 ${key}`);
};
requireKeys(manifest, ["schemaVersion", "rtlRoot", "modules", "ports", "edges", "signals", "groups", "layouts"], "manifest");
if (manifest.schemaVersion !== 1) errors.push("manifest.schemaVersion: 仅支持版本 1");
if (manifest.rtlRoot !== "mycpu") errors.push("manifest.rtlRoot: 必须是 mycpu");

const arrays = ["modules", "ports", "edges", "signals", "groups"];
for (const key of arrays) if (!Array.isArray(manifest[key])) errors.push(`manifest.${key}: 必须是数组`);

const unique = (items, key, label) => {
  const values = new Set();
  for (const item of items ?? []) {
    if (!item[key]) errors.push(`${label}: 缺少 ${key}`);
    else if (values.has(item[key])) errors.push(`${label}: 重复 ${key} ${item[key]}`);
    else values.add(item[key]);
  }
  return values;
};
const moduleIds = unique(manifest.modules, "id", "modules");
const modulePaths = unique(manifest.modules, "path", "modules");
const portIds = unique(manifest.ports, "id", "ports");
const signalIds = unique(manifest.signals, "id", "signals");
const groupIds = unique(manifest.groups, "id", "groups");
unique(manifest.edges, "id", "edges");

for (const module of manifest.modules ?? []) {
  requireKeys(module, ["id", "path", "module", "label", "stage", "kind", "source"], `module ${module.id}`);
  if (module.parent && !moduleIds.has(module.parent)) errors.push(`module ${module.id}: parent ${module.parent} 不存在`);
  const layout = module.parent ? manifest.layouts?.modules?.[module.id] : manifest.layouts?.overview?.[module.id];
  if (!layout || !Number.isFinite(layout.x) || !Number.isFinite(layout.y)) errors.push(`module ${module.id}: 缺少有效的固定布局坐标`);
  if (module.source) {
    const sourcePath = resolve(repo, module.source.file);
    try {
      await access(sourcePath);
      const lines = (await readFile(sourcePath, "utf8")).split(/\r?\n/);
      if (module.source.line > lines.length) errors.push(`module ${module.id}: source.line 超出文件范围`);
    } catch {
      errors.push(`module ${module.id}: 源文件不存在 ${module.source.file}`);
    }
  }
}
for (const port of manifest.ports ?? []) {
  if (!moduleIds.has(port.moduleId)) errors.push(`port ${port.id}: moduleId ${port.moduleId} 不存在`);
}
for (const signal of manifest.signals ?? []) {
  if (!groupIds.has(signal.group)) errors.push(`signal ${signal.id}: group ${signal.group} 不存在`);
  if (!Number.isInteger(signal.width) || signal.width < 1) errors.push(`signal ${signal.id}: width 非法`);
}
for (const edge of manifest.edges ?? []) {
  if (!portIds.has(edge.source)) errors.push(`edge ${edge.id}: source ${edge.source} 不存在`);
  if (!portIds.has(edge.target)) errors.push(`edge ${edge.id}: target ${edge.target} 不存在`);
  for (const signalId of edge.signalIds ?? []) if (!signalIds.has(signalId)) errors.push(`edge ${edge.id}: signal ${signalId} 不存在`);
  if (edge.kind !== "static" && (edge.signalIds?.length ?? 0) === 0) errors.push(`edge ${edge.id}: 非 static edge 必须绑定 signal`);
}
const referencedSignalIds = new Set((manifest.edges ?? []).flatMap((edge) => edge.signalIds ?? []));
for (const signal of manifest.signals ?? []) if (!referencedSignalIds.has(signal.id)) errors.push(`signal ${signal.id}: 未绑定任何 module/edge`);
const portById = new Map((manifest.ports ?? []).map((port) => [port.id, port]));
const connectedModuleIds = new Set();
for (const edge of manifest.edges ?? []) {
  const sourcePort = portById.get(edge.source);
  const targetPort = portById.get(edge.target);
  if (sourcePort) {
    connectedModuleIds.add(sourcePort.moduleId);
  }
  if (targetPort) {
    connectedModuleIds.add(targetPort.moduleId);
  }
}
for (const module of manifest.modules ?? []) {
  const ports = (manifest.ports ?? []).filter((port) => port.moduleId === module.id);
  if (ports.length === 0) errors.push(`module ${module.id}: 没有可视化功能端口`);
  if (!connectedModuleIds.has(module.id)) errors.push(`module ${module.id}: 没有绑定信号的可视化连线`);
}

const collectRtlFiles = async (directory) => {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) result.push(...await collectRtlFiles(path));
    else if (/\.(?:sv|v)$/.test(entry.name)) result.push(path.slice(repo.length + 1));
  }
  return result;
};
const rtlFiles = await collectRtlFiles(resolve(repo, "rtl"));
const sourceByModule = new Map();
for (const file of rtlFiles) {
  const text = (await readFile(resolve(repo, file), "utf8")).replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/.*$/gm, " ");
  for (const match of text.matchAll(/\bmodule\s+([A-Za-z_][\w$]*)[\s\S]*?\bendmodule\b/g)) sourceByModule.set(match[1], { file, body: match[0] });
}
const knownTypes = [...sourceByModule.keys()].sort((a, b) => b.length - a.length).map((value) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
const children = new Map();
for (const [type, source] of sourceByModule) {
  const found = [];
  const expression = new RegExp(`^\\s*(${knownTypes})\\b(.*)$`);
  for (const line of source.body.split(/\r?\n/)) {
    const match = line.match(expression);
    const names = [...line.matchAll(/([A-Za-z_][\w$]*)\s*\(/g)];
    const name = names.at(-1)?.[1];
    if (match && name) found.push({ type: match[1], name });
  }
  children.set(type, found);
}
const discovered = new Map();
const walk = (type, path, depth = 0) => {
  if (depth > 16) throw new Error(`实例递归过深: ${path}`);
  for (const child of children.get(type) ?? []) {
    const childPath = `${path}.${child.name}`;
    discovered.set(childPath, child.type);
    walk(child.type, childPath, depth + 1);
  }
};
walk("mycpu", "mycpu");
if (process.env.CPU_VIZ_DEBUG === "1") console.error([...discovered.entries()]);
for (const module of manifest.modules ?? []) {
  if (!discovered.has(module.path)) errors.push(`module ${module.id}: RTL 实例路径不存在 ${module.path}`);
  else if (discovered.get(module.path) !== module.module) errors.push(`module ${module.id}: 类型应为 ${discovered.get(module.path)}，实际清单为 ${module.module}`);
}
for (const [path, type] of discovered) if (!modulePaths.has(path)) errors.push(`modules: 漏列 RTL 实例 ${path} (${type})`);

for (const signal of manifest.signals ?? []) {
  const segments = signal.path.split(".");
  let ownerType = "mycpu";
  let localExpression = segments.slice(1).join(".");
  for (let end = segments.length - 1; end > 1; end -= 1) {
    const instancePath = segments.slice(0, end).join(".");
    if (!discovered.has(instancePath)) continue;
    ownerType = discovered.get(instancePath);
    localExpression = segments.slice(end).join(".");
    break;
  }
  const body = sourceByModule.get(ownerType)?.body ?? "";
  if (localExpression.includes(".")) {
    errors.push(`signal ${signal.id}: 无法解析 RTL 层次路径 ${signal.path}`);
    continue;
  }
  const identifiers = [...localExpression.matchAll(/[A-Za-z_][\w$]*/g)].map((match) => match[0]);
  if (!identifiers.length || identifiers.some((identifier) => !new RegExp(`\\b${identifier.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`).test(body))) {
    errors.push(`signal ${signal.id}: RTL 信号路径不存在 ${signal.path}`);
  }
}

if (errors.length) {
  console.error(`CPU visualizer manifest 校验失败（${errors.length} 项）:`);
  for (const error of errors) console.error(`- ${error}`);
  process.exit(1);
}
console.log(`CPU visualizer manifest OK: ${manifest.modules.length} modules, ${manifest.signals.length} signals, ${manifest.edges.length} edges`);
