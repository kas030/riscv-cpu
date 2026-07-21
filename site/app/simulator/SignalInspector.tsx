"use client";

import { useMemo, useState } from "react";
import { formatSignalValue, hasUnknown } from "./lib/format-value";
import { decodeForwardSource } from "./lib/forwarding";
import { connectionsForSignal, signalsForModule, sourceForSignal } from "./lib/graph-model";
import type { GraphManifest, ModuleManifest, StageTag } from "./lib/types";

export function SignalInspector({ graph, values, previous, stages, selectedInstruction, selectedModule, selectedEdge, signalQuery, setSignalQuery }: {
  graph: GraphManifest;
  values: Record<string, string>;
  previous: Record<string, string>;
  stages: Record<string, [StageTag | null, StageTag | null]>;
  selectedInstruction?: number;
  selectedModule?: ModuleManifest;
  selectedEdge?: string;
  signalQuery: string;
  setSignalQuery: (value: string) => void;
}) {
  const [pinned, setPinned] = useState<string[]>([]);
  const [mode, setMode] = useState<"hex" | "unsigned" | "signed">("hex");
  const relatedSignals = useMemo(() => {
    if (!selectedModule) return new Set<string>();
    return signalsForModule(graph, selectedModule.id);
  }, [graph, selectedModule]);
  const selectedEdgeData = graph.edges.find((edge) => edge.id === selectedEdge);
  const sourcePort = graph.ports.find((port) => port.id === selectedEdgeData?.source);
  const targetPort = graph.ports.find((port) => port.id === selectedEdgeData?.target);
  const sourceModule = graph.modules.find((module) => module.id === sourcePort?.moduleId);
  const targetModule = graph.modules.find((module) => module.id === targetPort?.moduleId);
  const filtered = useMemo(() => graph.signals.filter((signal) => {
    const query = signalQuery.trim().toLowerCase();
    const matchesQuery = !query || `${signal.id} ${signal.label} ${signal.path} ${signal.description}`.toLowerCase().includes(query);
    const matchesModule = !selectedModule || relatedSignals.has(signal.id) || signal.path.startsWith(`${selectedModule.path}.`);
    const matchesEdge = !selectedEdgeData || selectedEdgeData.signalIds.includes(signal.id);
    return matchesQuery && matchesModule && matchesEdge;
  }).sort((a, b) => Number(pinned.includes(b.id)) - Number(pinned.includes(a.id))), [graph.signals, pinned, relatedSignals, selectedEdgeData, selectedModule, signalQuery]);
  const forwarding = [0, 1].flatMap((lane) => ["A", "B"].flatMap((operand) => {
    const suffix = lane === 0 ? "" : "_S1";
    const source = decodeForwardSource(values[`Forward${operand}${suffix}`]);
    const consumer = stages.EX?.[lane];
    if (!source || !consumer || (selectedInstruction !== undefined && consumer.instructionId !== selectedInstruction)) return [];
    return [{ lane, operand, source, producer: stages[source.stage]?.[source.lane], consumer, value: values[`Forward${operand}Data${suffix}`] }];
  }));
  return (
    <aside className="signal-inspector">
      <header><div><span>RTL INSPECTOR</span><h2>{selectedModule?.label ?? (selectedEdgeData ? `连线 · ${selectedEdgeData.id}` : "信号检查器")}</h2></div>{selectedModule && <code>{selectedModule.path}</code>}{selectedEdgeData && <code>{selectedEdgeData.kind}</code>}</header>
      {selectedModule && <p className="source-link">{selectedModule.source.file}:{selectedModule.source.line}</p>}
      {selectedEdgeData && <p className="source-link">{sourceModule?.label ?? sourcePort?.moduleId}.{sourcePort?.name ?? selectedEdgeData.source} → {targetModule?.label ?? targetPort?.moduleId}.{targetPort?.name ?? selectedEdgeData.target}</p>}
      {forwarding.length > 0 && <div className="forward-summary"><strong>本拍前递来源</strong>{forwarding.map((item) => <p key={`${item.lane}-${item.operand}`}><code>#{item.producer?.instructionId ?? "?"}</code><span>{item.source.label}</span><b>→</b><code>#{item.consumer.instructionId} rs{item.operand === "A" ? "1" : "2"}</code><output>0x{item.value}</output></p>)}</div>}
      <div className="signal-controls"><input value={signalQuery} onChange={(event) => setSignalQuery(event.target.value)} placeholder="搜索信号名称、路径或说明" aria-label="搜索信号" /><select value={mode} onChange={(event) => setMode(event.target.value as typeof mode)} aria-label="数值格式"><option value="hex">十六进制</option><option value="unsigned">无符号十进制</option><option value="signed">有符号十进制</option></select></div>
      <div className="signal-list">
        {filtered.map((signal) => {
          const value = values[signal.id];
          const changed = value !== previous[signal.id];
          const connections = connectionsForSignal(graph, signal.id);
          const source = sourceForSignal(graph, signal.path);
          return <article key={signal.id} className={`${changed ? "changed" : ""} ${hasUnknown(value ?? "") ? "unknown" : ""} ${value && /^0+$/.test(value) ? "zero" : ""}`}>
            <button className="pin" onClick={() => setPinned((items) => items.includes(signal.id) ? items.filter((id) => id !== signal.id) : items.length < 8 ? [...items, signal.id] : items)} aria-label={`${pinned.includes(signal.id) ? "取消固定" : "固定"} ${signal.id}`}>{pinned.includes(signal.id) ? "◆" : "◇"}</button>
            <div><strong>{signal.id}</strong><small>{signal.description} · {signal.width} bit · {signal.group}</small><small className="signal-path">{signal.path}</small><small className="signal-source">{source.file}{source.line ? `:${source.line}` : ""} · {source.symbol}</small></div>
            <div className="signal-values"><output>{formatSignalValue(value, signal, mode)}</output><small>上一拍 {formatSignalValue(previous[signal.id], signal, mode)}</small></div>
            {connections.length > 0 && <div className="signal-connections">{connections.slice(0, 3).map((connection) => <small key={connection.edge.id}>{connection.sourceModule?.label ?? connection.sourcePort?.moduleId}.{connection.sourcePort?.name ?? connection.edge.source} → {connection.targetModule?.label ?? connection.targetPort?.moduleId}.{connection.targetPort?.name ?? connection.edge.target}</small>)}</div>}
            {signal.enum && pinned.includes(signal.id) && <ul className="mux-options" aria-label={`${signal.id} 可选输入`}>{Object.entries(signal.enum).map(([key, label]) => <li key={key} className={Number.parseInt(value ?? "0", 2) === Number(key) ? "selected" : ""}><code>{key}</code>{label}</li>)}</ul>}
          </article>;
        })}
        {!filtered.length && <p className="empty-note">当前模块或连线没有匹配的已采样信号。</p>}
      </div>
    </aside>
  );
}
