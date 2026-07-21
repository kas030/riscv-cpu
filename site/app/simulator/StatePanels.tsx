"use client";

import { useState } from "react";
import type { TraceEvent, TraceFrame } from "./lib/types";

type FullFrame = TraceFrame & { signals?: Record<string, string> };

function StateGrid({ title, values, previous, written }: { title: string; values?: Record<string, string>; previous?: Record<string, string>; written?: Set<string> }) {
  return <details><summary>{title}<span>{Object.keys(values ?? {}).length}</span></summary><div className="state-grid">{Object.entries(values ?? {}).map(([key, value]) => <div key={key} className={`${previous?.[key] !== undefined && previous[key] !== value ? "changed" : ""} ${written?.has(key) ? "written" : ""}`}><code>{key}</code><strong>0x{value}</strong></div>)}{!Object.keys(values ?? {}).length && <p>本场景未声明观察值</p>}</div></details>;
}

export function StatePanels({ frame, previous }: { frame?: FullFrame; previous?: FullFrame }) {
  const [onlyValidL0, setOnlyValidL0] = useState(true);
  const sideEffects = frame?.events.filter((event: TraceEvent) => ["store", "csr-write", "redirect", "retire"].includes(event.type)) ?? [];
  const written = new Set(sideEffects.flatMap((event) => event.register ? [event.register] : []));
  const hitAddress = frame?.signals?.MEM_cache_hit === "1" ? Number.parseInt(frame.signals.MEM_perip_addr, 16) : -1;
  const hitLine = hitAddress >= 0 ? String((hitAddress >>> 2) & 0x3f) : undefined;
  const l0Rows = onlyValidL0 ? Object.entries(frame?.l0 ?? {}) : Array.from({ length: 64 }, (_, line) => [String(line), frame?.l0?.[String(line)]] as const);
  return <section className="state-panels">
    <StateGrid title="寄存器 x0—x31" values={frame?.registers} previous={previous?.registers} written={written} />
    <StateGrid title="CSR 当前值" values={frame?.csrs} previous={previous?.csrs} />
    <StateGrid title="已观察内存" values={frame?.memory} previous={previous?.memory} />
    <details><summary>L0 cache<span>{Object.keys(frame?.l0 ?? {}).length}/64 valid</span></summary><label className="state-toggle"><input type="checkbox" checked={onlyValidL0} onChange={(event) => setOnlyValidL0(event.target.checked)} /> 仅看有效行</label><div className="effect-list">{l0Rows.map(([line, value]) => <p key={line} className={`${line === hitLine ? "hit" : ""} ${value ? "" : "invalid"}`}><b>line {line}</b>{value ? <><code>tag {value.tag}</code><code>0x{value.data}</code></> : <span>invalid</span>}</p>)}{onlyValidL0 && !l0Rows.length && <p>当前没有有效行</p>}</div></details>
    <details><summary>当前预测表项<span>IF PC</span></summary><div className="effect-list"><p><b>BHT[{Number.parseInt(frame?.signals?.bht_current_index ?? "0", 2)}]</b><code>{frame?.signals?.bht_current_valid === "1" ? frame.signals.bht_current_counter : "cold / BTFNT"}</code></p><p><b>hint[{Number.parseInt(frame?.signals?.hint_current_index ?? "0", 2)}]</b><code>{frame?.signals?.hint_current_valid === "1" ? `${frame.signals.hint_current_tag} → ${frame.signals.hint_current_value}` : "invalid"}</code></p></div></details>
    <details open><summary>本拍副作用<span>{sideEffects.length}</span></summary><div className="effect-list">{sideEffects.map((event, index) => <p key={`${event.type}-${index}`}><b>{event.type}</b>{event.label}{event.register && <code>{event.register}</code>}{event.address && <code>0x{event.address}</code>}{event.value && <code>0x{event.value}</code>}</p>)}{!sideEffects.length && <p>无体系结构副作用</p>}</div></details>
  </section>;
}
