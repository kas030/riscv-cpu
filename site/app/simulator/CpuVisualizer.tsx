"use client";

import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { InstructionList } from "./InstructionList";
import { SchematicCanvas } from "./SchematicCanvas";
import { SignalInspector } from "./SignalInspector";
import { StatePanels } from "./StatePanels";
import { Timeline } from "./Timeline";
import { filterGraphBySignalGroup, moduleAncestors, modulesForSearch } from "./lib/graph-model";
import { decodeForwardSource } from "./lib/forwarding";
import { modulesAt, modulesForInstructionAt } from "./lib/instruction-path";
import { loadScenarioChunk, loadScenarioChunks, loadTraceIndex } from "./lib/trace-loader";
import type { GraphManifest, TraceFrame, TraceIndex } from "./lib/types";

type FullFrame = TraceFrame & { signals: Record<string, string> };

export function CpuVisualizer() {
  const [graph, setGraph] = useState<GraphManifest>();
  const [index, setIndex] = useState<TraceIndex>();
  const [scenarioId, setScenarioId] = useState("");
  const [frames, setFrames] = useState<FullFrame[]>([]);
  const [loadedChunks, setLoadedChunks] = useState(0);
  const [cycleIndex, setCycleIndex] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [speed, setSpeed] = useState(1);
  const [selectedModule, setSelectedModule] = useState<string>();
  const [selectedEdge, setSelectedEdge] = useState<string>();
  const [selectedInstruction, setSelectedInstruction] = useState<number>();
  const [followInstruction, setFollowInstruction] = useState(false);
  const [expanded, setExpanded] = useState(new Set<string>());
  const [moduleQuery, setModuleQuery] = useState("");
  const [signalQuery, setSignalQuery] = useState("");
  const [groupFilter, setGroupFilter] = useState("all");
  // Desktop keeps both grid columns visible. On narrow screens the collapsed
  // classes prevent the two fixed drawers from covering the schematic at boot.
  const [leftOpen, setLeftOpen] = useState(false);
  const [rightOpen, setRightOpen] = useState(false);
  const [reducedMotion, setReducedMotion] = useState(() => typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  const [error, setError] = useState("");
  const loadingChunk = useRef(false);

  useEffect(() => {
    Promise.all([
      fetch("/generated/cpu-visualizer/graph.json").then((response) => response.ok ? response.json() as Promise<GraphManifest> : Promise.reject(new Error("graph manifest 加载失败"))),
      loadTraceIndex(),
    ]).then(([loadedGraph, loadedIndex]) => {
      if (loadedGraph.schemaVersion !== loadedIndex.graphSchemaVersion) throw new Error("graph 与 trace schema 版本不一致");
      setGraph(loadedGraph);
      setIndex(loadedIndex);
      if (loadedIndex.scenarios[0]) setScenarioId(loadedIndex.scenarios[0].id);
    }).catch((reason: unknown) => setError(reason instanceof Error ? reason.message : String(reason)));
  }, []);

  const scenario = index?.scenarios.find((item) => item.id === scenarioId);
  useEffect(() => {
    if (!scenario) return;
    let cancelled = false;
    loadScenarioChunk(scenario, 0).then((loaded) => { if (!cancelled) { setFrames(loaded); setLoadedChunks(1); } }).catch((reason: unknown) => { if (!cancelled) setError(reason instanceof Error ? reason.message : String(reason)); });
    return () => { cancelled = true; };
  }, [scenario]);

  const step = useCallback((direction: -1 | 1) => {
    if (direction === 1 && cycleIndex >= frames.length - 1 && scenario && loadedChunks < scenario.chunks.length && !loadingChunk.current) {
      loadingChunk.current = true;
      loadScenarioChunk(scenario, loadedChunks).then((loaded) => {
        setFrames((current) => [...current, ...loaded]);
        setLoadedChunks((current) => current + 1);
        setCycleIndex((current) => current + 1);
      }).catch((reason: unknown) => setError(reason instanceof Error ? reason.message : String(reason))).finally(() => { loadingChunk.current = false; });
      return;
    }
    setCycleIndex((current) => {
      if (!followInstruction || selectedInstruction === undefined) return Math.max(0, Math.min(frames.length - 1, current + direction));
      const currentStage = Object.entries(frames[current]?.stages ?? {}).find(([, lanes]) => lanes.some((tag) => tag?.instructionId === selectedInstruction))?.[0];
      for (let next = current + direction; next >= 0 && next < frames.length; next += direction) {
        const nextStage = Object.entries(frames[next]?.stages ?? {}).find(([, lanes]) => lanes.some((tag) => tag?.instructionId === selectedInstruction))?.[0];
        if (nextStage !== currentStage) return next;
      }
      return current;
    });
  }, [cycleIndex, followInstruction, frames, loadedChunks, scenario, selectedInstruction]);

  useEffect(() => {
    if (!playing || !frames.length) return;
    const timer = window.setInterval(() => setCycleIndex((current) => {
      if (current >= frames.length - 1) {
        if (!scenario || loadedChunks >= scenario.chunks.length) setPlaying(false);
        return current;
      }
      return current + 1;
    }), 700 / speed);
    return () => window.clearInterval(timer);
  }, [frames.length, loadedChunks, playing, scenario, speed]);

  useEffect(() => {
    if (!playing || !scenario || cycleIndex < frames.length - 1 || loadedChunks >= scenario.chunks.length || loadingChunk.current) return;
    loadingChunk.current = true;
    loadScenarioChunk(scenario, loadedChunks).then((loaded) => {
      setFrames((current) => [...current, ...loaded]);
      setLoadedChunks((current) => current + 1);
    }).catch((reason: unknown) => setError(reason instanceof Error ? reason.message : String(reason))).finally(() => { loadingChunk.current = false; });
  }, [cycleIndex, frames.length, loadedChunks, playing, scenario]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.target instanceof HTMLInputElement || event.target instanceof HTMLSelectElement) return;
      if (event.key === "ArrowLeft") { event.preventDefault(); step(-1); }
      if (event.key === "ArrowRight") { event.preventDefault(); step(1); }
      if (event.key === " ") { event.preventDefault(); setPlaying((value) => !value); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [step]);

  const frame = frames[cycleIndex];
  const previous = frames[cycleIndex - 1];
  const changed = useMemo(() => new Set(Object.keys(frame?.signals ?? {}).filter((id) => frame?.signals[id] !== previous?.signals[id])), [frame, previous]);
  const activeModules = useMemo(() => {
    const result = new Set<string>();
    const selected = scenario?.instructions.find((instruction) => instruction.instructionId === selectedInstruction);
    for (const [stage, lanes] of Object.entries(frame?.stages ?? {})) {
      lanes.forEach((tag, lane) => {
        if (tag && (selectedInstruction === undefined || tag.instructionId === selectedInstruction)) {
          const nodes = selected ? modulesForInstructionAt(stage, lane, selected.instruction, Boolean(selected.architecturalWrite)) : modulesAt(stage, lane);
          for (const nodeId of nodes) result.add(nodeId);
        }
      });
    }
    if (selected && frame) {
      for (const [lane, tag] of (frame.stages.EX ?? []).entries()) {
        if (tag?.instructionId !== selected.instructionId) continue;
        for (const operand of ["A", "B"]) {
          const suffix = lane === 0 ? "" : "_S1";
          const source = decodeForwardSource(frame.signals[`Forward${operand}${suffix}`]);
          if (!source) continue;
          const producerModule = source.stage === "MEM1" ? (source.lane === 0 ? "ex_mem0" : "ex_mem1")
            : source.stage === "MEM2" ? (source.lane === 0 ? "mem1_mem2_0" : "mem1_mem2_1")
              : source.lane === 0 ? "wb0" : "wb1";
          result.add(producerModule);
          if (source.stage === "MEM1" && frame.signals.MEM_cache_hit === "1") result.add("l0");
        }
      }
    }
    return result;
  }, [frame, scenario, selectedInstruction]);
  const moduleStates = useMemo(() => {
    const result = new Map<string, "held" | "bubble" | "flushed">();
    for (const [stage, lanes] of Object.entries(frame?.stages ?? {})) {
      lanes.forEach((tag, lane) => {
        if (tag?.state === "held" && (selectedInstruction === undefined || tag.instructionId === selectedInstruction)) for (const moduleId of modulesAt(stage, lane)) result.set(moduleId, "held");
      });
    }
    if (frame?.signals.Flush_ID_EX_comb === "1" && frame.signals.BranchMispredict === "0") for (const moduleId of modulesAt("EX")) result.set(moduleId, "bubble");
    const selectedFlushed = selectedInstruction !== undefined && frame?.events.some((event) => event.type === "flush" && event.instructionId === selectedInstruction);
    if (selectedFlushed) {
      for (const [stage, lanes] of Object.entries(previous?.stages ?? {})) lanes.forEach((tag, lane) => {
        if (tag?.instructionId === selectedInstruction) for (const moduleId of modulesAt(stage, lane)) result.set(moduleId, "flushed");
      });
    } else if (frame?.signals.BranchMispredict === "1") {
      for (const stage of ["ID", "EX", "MEM1"]) for (const moduleId of modulesAt(stage)) result.set(moduleId, "flushed");
    }
    return result;
  }, [frame, previous, selectedInstruction]);
  const searchResults = useMemo(() => graph ? modulesForSearch(graph, moduleQuery).slice(0, 12) : [], [graph, moduleQuery]);
  const selectedModuleData = graph?.modules.find((item) => item.id === selectedModule);
  const visibleGraph = useMemo(() => {
    if (!graph) return graph;
    return filterGraphBySignalGroup(graph, groupFilter);
  }, [graph, groupFilter]);

  const selectModule = (id: string) => {
    if (!graph) return;
    const item = graph.modules.find((module) => module.id === id);
    if (!item) return;
    setSelectedModule(id);
    setSelectedEdge(undefined);
    const hasChildren = graph.modules.some((module) => module.parent === id);
    setExpanded((current) => new Set([...current, ...moduleAncestors(item, graph), ...(hasChildren ? [id] : [])]));
    setModuleQuery("");
  };

  const jumpToCycle = async (cycle: number) => {
    if (!scenario) return;
    const found = frames.findIndex((item) => item.cycle === cycle);
    if (found >= 0) { setCycleIndex(found); return; }
    const targetChunk = scenario.chunks.findIndex((chunk) => cycle >= chunk.start && cycle <= chunk.end);
    if (targetChunk < 0 || loadingChunk.current) return;
    loadingChunk.current = true;
    try {
      const loaded = await loadScenarioChunks(scenario, targetChunk);
      setFrames(loaded);
      setLoadedChunks(targetChunk + 1);
      const target = loaded.findIndex((item) => item.cycle === cycle);
      if (target >= 0) setCycleIndex(target);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      loadingChunk.current = false;
    }
  };

  if (error) return <main className="visualizer-error"><h1>CPU 可视化器无法启动</h1><p>{error}</p><Link href="/">返回课程</Link></main>;
  if (!graph || !index || !visibleGraph) return <main className="visualizer-loading"><span /><p>正在校验并加载 RTL 图清单…</p></main>;

  return (
    <div className={`visualizer-shell ${reducedMotion ? "reduce-motion" : ""} ${leftOpen ? "" : "left-collapsed"} ${rightOpen ? "" : "right-collapsed"}`}>
      <header className="visualizer-toolbar">
        <Link href="/" className="visualizer-brand"><b>RV</b><span>CPU TRACE LAB<small>RTL-grounded playback</small></span></Link>
        <label>场景<select value={scenarioId} onChange={(event) => { setScenarioId(event.target.value); setPlaying(false); setCycleIndex(0); setSelectedInstruction(undefined); setSelectedModule(undefined); setSelectedEdge(undefined); setSignalQuery(""); setFrames([]); setLoadedChunks(0); }}><option value="">选择 trace</option>{index.scenarios.map((item) => <option value={item.id} key={item.id}>{item.title}</option>)}</select></label>
        <div className="play-controls">
          <button onClick={() => { setPlaying(false); setCycleIndex(0); }} title="重置">↺</button>
          <button onClick={() => step(-1)} disabled={!frames.length || cycleIndex === 0} title="上一拍（←）">‹</button>
          <button className="play" onClick={() => setPlaying((value) => !value)} disabled={!frames.length} title="播放/暂停（空格）">{playing ? "暂停" : "播放"}</button>
          <button onClick={() => step(1)} disabled={!frames.length || (cycleIndex >= frames.length - 1 && loadedChunks >= (scenario?.chunks.length ?? 0))} title="下一拍（→）">›</button>
        </div>
        <label>周期<input type="number" min={1} max={scenario?.totalCycles ?? 1} value={frame?.cycle ?? 0} onChange={(event) => void jumpToCycle(Number(event.target.value))} /></label>
        <label>速度<select value={speed} onChange={(event) => setSpeed(Number(event.target.value))}>{[0.25, 0.5, 1, 2, 4].map((value) => <option value={value} key={value}>{value}×</option>)}</select></label>
        <button className="panel-toggle" onClick={() => setLeftOpen((value) => !value)} aria-pressed={leftOpen}>指令</button>
        <button className="panel-toggle" onClick={() => setRightOpen((value) => !value)} aria-pressed={rightOpen}>信号</button>
        <button className="motion-button" onClick={() => setReducedMotion((value) => !value)} aria-pressed={reducedMotion}>{reducedMotion ? "静态" : "动态"}</button>
      </header>

      <aside className="visualizer-left">
        <div className="module-search"><label>定位模块<input value={moduleQuery} onChange={(event) => setModuleQuery(event.target.value)} placeholder="ALU、L0、实例路径…" /></label>{moduleQuery && <div className="module-results">{searchResults.map((module) => <button key={module.id} onClick={() => selectModule(module.id)}><strong>{module.label}</strong><code>{module.path}</code></button>)}</div>}</div>
        <label className="group-filter">连线类别<select value={groupFilter} onChange={(event) => setGroupFilter(event.target.value)}><option value="all">全部关键信号</option>{graph.groups.map((group) => <option value={group.id} key={group.id}>{group.label}</option>)}</select></label>
        <InstructionList scenario={scenario} frame={frame} selected={selectedInstruction} onSelect={(instructionId) => { setSelectedInstruction(instructionId); const instruction = scenario?.instructions.find((item) => item.instructionId === instructionId); if (instruction) void jumpToCycle(instruction.issueCycle); }} />
        <label className="follow"><input type="checkbox" checked={followInstruction} onChange={(event) => setFollowInstruction(event.target.checked)} /> 跟随所选指令的级间迁移</label>
        <StatePanels frame={frame} previous={previous} />
      </aside>

      <main className="visualizer-canvas">
        <div className="trace-provenance"><span className={scenario?.result === "PASS" ? "pass" : "idle"}>{scenario?.result ?? "NO TRACE"}</span><code>RTL {index.rtlDigest.slice(0, 12)}</code><span>{scenario ? `${scenario.retired} retired · ${scenario.totalCycles} cycles` : "等待生成真实 RTL trace"}</span>{frame && <span>本拍退休 {frame.retireCount} · 累计 {frame.retiredTotal}</span>}</div>
        <SchematicCanvas graph={visibleGraph} selectedModule={selectedModule} setSelectedModule={setSelectedModule} selectedEdge={selectedEdge} setSelectedEdge={setSelectedEdge} expanded={expanded} toggleExpanded={(id) => setExpanded((current) => { const next = new Set(current); if (next.has(id)) next.delete(id); else next.add(id); return next; })} signalValues={frame?.signals ?? {}} changedSignals={changed} activeModules={activeModules} moduleStates={moduleStates} activeInstructionId={selectedInstruction} />
      </main>

      <SignalInspector graph={graph} values={frame?.signals ?? {}} previous={previous?.signals ?? {}} stages={frame?.stages ?? {}} selectedInstruction={selectedInstruction} selectedModule={selectedModuleData} selectedEdge={selectedEdge} signalQuery={signalQuery} setSignalQuery={setSignalQuery} />
      <Timeline frames={frames} cycleIndex={cycleIndex} setCycleIndex={setCycleIndex} />
    </div>
  );
}
