#!/usr/bin/env node
import ELK from "elkjs/lib/elk.bundled.js";
import { readFile } from "node:fs/promises";

const manifest = JSON.parse(await readFile(new URL("../../tools/cpu_visualizer/manifest.json", import.meta.url), "utf8"));
const roots = manifest.modules.filter((module) => !module.parent);
const portToModule = new Map(manifest.ports.map((port) => [port.id, port.moduleId]));
const rootId = (id) => {
  let currentNode = manifest.modules.find((item) => item.id === id);
  while (currentNode?.parent) currentNode = manifest.modules.find((item) => item.id === currentNode.parent);
  return currentNode?.id;
};
const graph = {
  id: "mycpu",
  layoutOptions: { "elk.algorithm": "layered", "elk.direction": "RIGHT", "elk.spacing.nodeNode": "70", "elk.layered.spacing.nodeNodeBetweenLayers": "120" },
  children: roots.map((module) => ({ id: module.id, width: 210, height: 105 })),
  edges: manifest.edges.flatMap((edge) => {
    const source = rootId(portToModule.get(edge.source));
    const target = rootId(portToModule.get(edge.target));
    return source && target && source !== target ? [{ id: edge.id, sources: [source], targets: [target] }] : [];
  }),
};
const layout = await new ELK().layout(graph);
const suggestion = Object.fromEntries(layout.children.map((node) => [node.id, { x: Math.round(node.x), y: Math.round(node.y) }]));
process.stdout.write(`${JSON.stringify({ note: "辅助坐标；人工确认后再写入 manifest.layouts.overview", overview: suggestion }, null, 2)}\n`);
