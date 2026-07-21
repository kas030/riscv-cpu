"use client";

import { instructionStateAt } from "./lib/trace-reducer";
import type { TraceFrame, TraceScenario } from "./lib/types";

export function InstructionList({ scenario, frame, selected, onSelect }: { scenario?: TraceScenario; frame?: TraceFrame; selected?: number; onSelect: (id?: number) => void }) {
  const program = scenario ? [...new Map(scenario.instructions.map((instruction) => {
    const key = `${instruction.pc}:${instruction.instruction}`;
    return [key, {
      pc: instruction.pc,
      instruction: instruction.instruction,
      disassembly: instruction.disassembly,
      executions: scenario.instructions.filter((item) => item.pc === instruction.pc && item.instruction === instruction.instruction).length,
    }];
  })).values()].sort((left, right) => Number.parseInt(left.pc, 16) - Number.parseInt(right.pc, 16)) : [];
  const selectedData = scenario?.instructions.find((instruction) => instruction.instructionId === selected);
  return (
    <section className="instruction-panel">
      <details className="program-list">
        <summary>程序静态指令<span>{program.length}</span></summary>
        <div>
          {program.map((instruction) => <article key={`${instruction.pc}-${instruction.instruction}`}>
            <code>0x{instruction.pc}</code>
            <code>{instruction.instruction}</code>
            <strong>{instruction.disassembly}</strong>
            <small>执行 {instruction.executions} 次</small>
          </article>)}
        </div>
      </details>
      <h2>动态指令</h2>
      {!scenario && <p className="empty-note">选择一个真实 RTL 场景后显示。</p>}
      <div className="instruction-list">
        {scenario?.instructions.map((instruction) => {
          const state = frame ? instructionStateAt(frame, instruction) : { status: "pending" as const };
          const current = state.status === "active" || state.status === "held" ? `${state.status === "held" ? "保持" : "当前"} ${state.stage} · 槽 ${state.lane}` : state.status === "retired" ? "已退休" : state.status === "flushed" ? "已冲刷" : state.status === "bubble" ? "气泡" : "等待发射";
          return <button key={instruction.instructionId} className={selected === instruction.instructionId ? "selected" : ""} onClick={() => onSelect(selected === instruction.instructionId ? undefined : instruction.instructionId)}>
          <span>#{instruction.instructionId} · 槽 {instruction.lane}</span>
          <code>0x{instruction.pc}</code>
          <strong>{instruction.disassembly}</strong>
          <small className="instruction-current">{current}</small>
          <small>{instruction.retireCycle ? `退休 @ ${instruction.retireCycle}` : `未提交 · flush @ ${instruction.flushCycle ?? "?"}`}</small>
        </button>;
        })}
      </div>
      {selectedData && <article className="instruction-detail" aria-label="所选动态指令详情">
        <header><strong>#{selectedData.instructionId} 执行详情</strong><code>{selectedData.instruction}</code></header>
        <p><span>体系结构状态</span><b>{selectedData.retireCycle ? `退休 @ ${selectedData.retireCycle}` : `未提交 · flush @ ${selectedData.flushCycle ?? "?"}`}</b></p>
        {frame && <p><span>当前逐拍状态</span><b>{(() => { const state = instructionStateAt(frame, selectedData); return state.status === "active" || state.status === "held" ? `${state.status} · ${state.stage} / 槽 ${state.lane}` : state.status; })()}</b></p>}
        {selectedData.architecturalWrite && <p><span>体系结构写回</span><code>{selectedData.architecturalWrite.register} = 0x{selectedData.architecturalWrite.value}</code></p>}
        {selectedData.memory && <>
          <p><span>体系结构地址</span><code>0x{selectedData.memory.address}</code></p>
          <p><span>总线原始值</span><code>0x{selectedData.memory.rawValue}{selectedData.memory.mask ? ` · mask ${selectedData.memory.mask}` : ""}</code></p>
          {selectedData.memory.architecturalValue && <p><span>体系结构 load 值</span><code>0x{selectedData.memory.architecturalValue}</code></p>}
        </>}
        {selectedData.csr && <p><span>{selectedData.csr.operation}</span><code>CSR 0x{selectedData.csr.index} = 0x{selectedData.csr.value}</code></p>}
      </article>}
    </section>
  );
}
