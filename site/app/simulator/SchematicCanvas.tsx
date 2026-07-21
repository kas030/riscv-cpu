"use client";

import { Fragment, useEffect, useMemo } from "react";
import {
  Background,
  BaseEdge,
  Controls,
  Handle,
  MiniMap,
  Position,
  ReactFlow,
  ReactFlowProvider,
  getBezierPath,
  useReactFlow,
  type EdgeProps,
  type NodeProps,
} from "@xyflow/react";
import "@xyflow/react/dist/style.css";
import type { GraphManifest, ModuleManifest } from "./lib/types";

type CpuNodeData = {
  module: ModuleManifest;
  ports: { id: string; name: string; direction: string }[];
  nested: boolean;
  state?: "held" | "bubble" | "flushed";
  active: boolean;
  changed: boolean;
  expanded: boolean;
  childCount: number;
  value?: string;
};

function CpuNode({ data, selected }: NodeProps) {
  const node = data as unknown as CpuNodeData;
  return (
    <div className={`cpu-node ${node.nested ? "nested" : ""} lane-${node.module.lane ?? "shared"} kind-${node.module.kind} state-${node.state ?? "normal"} ${node.active ? "active" : ""} ${node.changed ? "changed" : ""} ${selected ? "selected" : ""}`}>
      {node.ports.map((port, index) => <Fragment key={port.id}>
        <Handle id={`${port.id}:target`} type="target" position={Position.Left} style={{ top: `${((index + 1) / (node.ports.length + 1)) * 100}%` }} aria-label={`${port.name} target port`} />
        <Handle id={`${port.id}:source`} type="source" position={Position.Right} style={{ top: `${((index + 1) / (node.ports.length + 1)) * 100}%` }} aria-label={`${port.name} source port`} />
      </Fragment>)}
      <span className="cpu-node-stage">{node.module.stage} · {node.module.kind}</span>
      <strong>{node.module.label}</strong>
      <code>{node.module.module}</code>
      {node.value && <output>{node.value}</output>}
      {node.childCount > 0 && <small>{node.expanded ? "收起内部" : `${node.childCount} 个内部实例`}</small>}
      <div className="cpu-node-ports" aria-label={`${node.module.label} 功能端口`}>{node.ports.map((port) => <span key={port.id} title={`${port.id} · ${port.direction}`}><i className={`direction-${port.direction}`} />{port.name}</span>)}</div>
    </div>
  );
}

function SignalEdge({ id, sourceX, sourceY, targetX, targetY, sourcePosition, targetPosition, markerEnd, data, selected }: EdgeProps) {
  const [path] = getBezierPath({ sourceX, sourceY, targetX, targetY, sourcePosition, targetPosition });
  const edge = data as { kind?: string; active?: boolean; changed?: boolean; label?: string } | undefined;
  return (
    <g className={`cpu-edge kind-${edge?.kind ?? "data"} ${edge?.active ? "active" : ""} ${edge?.changed ? "changed" : ""} ${selected ? "selected" : ""}`}>
      <BaseEdge id={id} path={path} markerEnd={markerEnd} />
      {edge?.label && <text><textPath href={`#${id}`} startOffset="50%">{edge.label}</textPath></text>}
    </g>
  );
}

const nodeTypes = { cpu: CpuNode };
const edgeTypes = { signal: SignalEdge };

function CanvasInner({ graph, selectedModule, setSelectedModule, selectedEdge, setSelectedEdge, expanded, toggleExpanded, signalValues, changedSignals, activeModules, moduleStates, activeInstructionId }: {
  graph: GraphManifest;
  selectedModule?: string;
  setSelectedModule: (id?: string) => void;
  selectedEdge?: string;
  setSelectedEdge: (id?: string) => void;
  expanded: Set<string>;
  toggleExpanded: (id: string) => void;
  signalValues: Record<string, string>;
  changedSignals: Set<string>;
  activeModules: Set<string>;
  moduleStates: Map<string, "held" | "bubble" | "flushed">;
  activeInstructionId?: number;
}) {
  const flow = useReactFlow();
  const portModules = useMemo(() => new Map(graph.ports.map((port) => [port.id, port.moduleId])), [graph]);
  const moduleMap = useMemo(() => new Map(graph.modules.map((module) => [module.id, module])), [graph]);
  const visible = useMemo(() => graph.modules.filter((module) => {
    if (!module.parent) return true;
    let cursor: ModuleManifest | undefined = module;
    while (cursor?.parent) {
      if (!expanded.has(cursor.parent)) return false;
      cursor = moduleMap.get(cursor.parent);
    }
    return true;
  }), [expanded, graph.modules, moduleMap]);
  const visibleIds = useMemo(() => new Set(visible.map((module) => module.id)), [visible]);
  const nodes = useMemo(() => {
    const visibleDescendantCount = (id: string): number => graph.modules
      .filter((module) => module.parent === id && visibleIds.has(module.id))
      .reduce((count, child) => count + 1 + visibleDescendantCount(child.id), 0);
    const expandedRoots = graph.modules.filter((module) => !module.parent && expanded.has(module.id)).map((module) => ({
      y: graph.layouts.overview[module.id]?.y ?? 0,
      extra: 150 + Math.ceil(visibleDescendantCount(module.id) / 2) * 110,
    }));
    const positionOf = (module: ModuleManifest): { x: number; y: number } => {
      if (!module.parent) {
        const base = graph.layouts.overview[module.id] ?? { x: 0, y: 0 };
        return { ...base, y: base.y + expandedRoots.filter((root) => base.y > root.y).reduce((sum, root) => sum + root.extra, 0) };
      }
      const parent = moduleMap.get(module.parent);
      const offset = graph.layouts.modules[module.id] ?? { x: 20, y: 80 };
      const base = parent ? positionOf(parent) : { x: 0, y: 0 };
      return { x: base.x + offset.x, y: base.y + 150 + offset.y };
    };
    return visible.map((module) => {
      const relatedSignals = graph.signals.filter((signal) => graph.edges.some((edge) => edge.signalIds.includes(signal.id) && [portModules.get(edge.source), portModules.get(edge.target)].includes(module.id)));
      const current = relatedSignals.find((signal) => signalValues[signal.id] !== undefined);
      return {
        id: module.id,
        type: "cpu",
        position: positionOf(module),
        selected: selectedModule === module.id,
        data: {
          module,
          ports: graph.ports.filter((port) => port.moduleId === module.id),
          nested: Boolean(module.parent),
          active: activeModules.has(module.id),
          state: moduleStates.get(module.id),
          changed: relatedSignals.some((signal) => changedSignals.has(signal.id)),
          expanded: expanded.has(module.id),
          childCount: graph.modules.filter((item) => item.parent === module.id).length,
          value: current ? `${current.id}=${signalValues[current.id]}` : undefined,
        },
      };
    });
  }, [activeModules, changedSignals, expanded, graph, moduleMap, moduleStates, portModules, selectedModule, signalValues, visible, visibleIds]);
  const edges = useMemo(() => graph.edges.flatMap((edge) => {
    const source = portModules.get(edge.source);
    const target = portModules.get(edge.target);
    if (!source || !target || !visibleIds.has(source) || !visibleIds.has(target)) return [];
    const changed = edge.signalIds.some((id) => changedSignals.has(id));
    const active = activeInstructionId !== undefined
      ? activeModules.has(source) && activeModules.has(target)
      : edge.signalIds.some((id) => signalValues[id] && !/^0+$/.test(signalValues[id]));
    const labels = edge.signalIds.slice(0, 2).map((id) => {
      const signal = graph.signals.find((item) => item.id === id);
      return signal ? `${id}[${signal.width}]:${signal.format}` : id;
    });
    return [{ id: edge.id, source, target, sourceHandle: `${edge.source}:source`, targetHandle: `${edge.target}:target`, type: "signal", selected: selectedEdge === edge.id, animated: active && activeInstructionId === undefined, data: { kind: edge.kind, active, changed, label: labels.join(" · ") } }];
  }), [activeInstructionId, activeModules, changedSignals, graph.edges, graph.signals, portModules, selectedEdge, signalValues, visibleIds]);

  useEffect(() => {
    if (!selectedModule || !visibleIds.has(selectedModule)) return;
    void flow.fitView({ nodes: [{ id: selectedModule }], duration: 300, maxZoom: 1.4, padding: 1.3 });
  }, [flow, selectedModule, visibleIds]);

  return (
    <ReactFlow
      key={[...expanded].sort().join(":") || "overview"}
      nodes={nodes}
      edges={edges}
      nodeTypes={nodeTypes}
      edgeTypes={edgeTypes}
      minZoom={0.18}
      maxZoom={2.2}
      fitView
      nodesDraggable
      onPaneClick={() => { setSelectedModule(undefined); setSelectedEdge(undefined); }}
      onNodeClick={(_, node) => {
        setSelectedModule(node.id);
        setSelectedEdge(undefined);
        if (graph.modules.some((item) => item.parent === node.id)) toggleExpanded(node.id);
      }}
      onEdgeClick={(_, edge) => { setSelectedEdge(edge.id); setSelectedModule(undefined); }}
      aria-label="CPU 功能模块原理图"
    >
      <Background gap={22} size={1} />
      <Controls showInteractive={false} />
      <MiniMap pannable zoomable nodeColor={(node) => node.id.endsWith("1") ? "#7c3aed" : "#2563eb"} />
    </ReactFlow>
  );
}

export function SchematicCanvas(props: Parameters<typeof CanvasInner>[0]) {
  return <ReactFlowProvider><CanvasInner {...props} /></ReactFlowProvider>;
}
