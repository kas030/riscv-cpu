import type { GraphManifest, ModuleManifest } from "./types";

export function moduleAncestors(module: ModuleManifest, graph: GraphManifest) {
  const result: string[] = [];
  let current = module;
  while (current.parent) {
    result.push(current.parent);
    const next = graph.modules.find((item) => item.id === current.parent);
    if (!next) break;
    current = next;
  }
  return result;
}

export function modulesForSearch(graph: GraphManifest, query: string) {
  const normalized = query.trim().toLowerCase();
  if (!normalized) return graph.modules;
  return graph.modules.filter((item) => `${item.label} ${item.module} ${item.path}`.toLowerCase().includes(normalized));
}

export function signalsForModule(graph: GraphManifest, moduleId: string) {
  const ports = new Set(graph.ports.filter((port) => port.moduleId === moduleId).map((port) => port.id));
  return new Set(graph.edges.filter((edge) => ports.has(edge.source) || ports.has(edge.target)).flatMap((edge) => edge.signalIds));
}

export function connectionsForSignal(graph: GraphManifest, signalId: string) {
  const ports = new Map(graph.ports.map((port) => [port.id, port]));
  const modules = new Map(graph.modules.map((module) => [module.id, module]));
  return graph.edges.filter((edge) => edge.signalIds.includes(signalId)).map((edge) => {
    const sourcePort = ports.get(edge.source);
    const targetPort = ports.get(edge.target);
    return {
      edge,
      sourcePort,
      targetPort,
      sourceModule: sourcePort ? modules.get(sourcePort.moduleId) : undefined,
      targetModule: targetPort ? modules.get(targetPort.moduleId) : undefined,
    };
  });
}

export function sourceForSignal(graph: GraphManifest, signalPath: string) {
  const owner = [...graph.modules]
    .filter((module) => signalPath.startsWith(`${module.path}.`))
    .sort((left, right) => right.path.length - left.path.length)[0];
  const symbol = signalPath.slice((owner?.path ?? "mycpu").length + 1);
  return owner ? { ...owner.source, symbol } : { file: "rtl/core/mycpu.sv", symbol };
}

export function filterGraphBySignalGroup(graph: GraphManifest, group: string) {
  if (group === "all") return graph;
  const signalIds = new Set(graph.signals.filter((signal) => signal.group === group).map((signal) => signal.id));
  return { ...graph, edges: graph.edges.filter((edge) => edge.kind === "static" || edge.signalIds.some((id) => signalIds.has(id))) };
}
