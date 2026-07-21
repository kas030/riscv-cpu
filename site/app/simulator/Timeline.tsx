"use client";

import type { TraceFrame } from "./lib/types";

export function Timeline({ frames, cycleIndex, setCycleIndex }: { frames: (TraceFrame & { signals: Record<string, string> })[]; cycleIndex: number; setCycleIndex: (value: number) => void }) {
  const current = frames[cycleIndex];
  return (
    <section className="timeline-panel" aria-label="逐拍时间轴">
      <div className="timeline-heading"><strong>周期时间轴</strong><span>{current ? `cycle ${current.cycle}` : "尚未加载 trace"}</span></div>
      <div className="timeline-track">
        {frames.map((frame, index) => <button key={frame.cycle} className={index === cycleIndex ? "current" : ""} onClick={() => setCycleIndex(index)} title={`周期 ${frame.cycle}: ${frame.events.map((event) => event.label).join("、") || "无事件"}`}>
          <span>{frame.cycle}</span>
          <i>{frame.events.map((event) => <b className={`event-${event.type}`} key={`${event.type}-${event.label}`} />)}</i>
        </button>)}
      </div>
      <div className="event-legend"><span><i className="event-stall" />stall</span><span><i className="event-bubble" />bubble</span><span><i className="event-flush" />flush</span><span><i className="event-l0-hit" />L0</span><span><i className="event-retire" />retire</span><span><i className="event-store" />side effect</span></div>
    </section>
  );
}
