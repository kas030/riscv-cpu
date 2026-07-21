import type { TraceFrame, TraceScenario } from "./types";

export function reconstructFrames(frames: TraceFrame[]) {
  const state: Record<string, string> = {};
  const registers: Record<string, string> = {};
  const csrs: Record<string, string> = {};
  const memory: Record<string, string> = {};
  const l0: NonNullable<TraceFrame["l0"]> = {};
  return frames.map((frame, index) => {
    if (index > 0 && frame.cycle !== frames[index - 1].cycle + 1) throw new Error(`trace cycle gap: ${frames[index - 1].cycle} -> ${frame.cycle}`);
    Object.assign(state, frame.changed);
    Object.assign(registers, frame.registers);
    Object.assign(csrs, frame.csrs);
    Object.assign(memory, frame.memory);
    for (const [line, value] of Object.entries(frame.l0 ?? {})) {
      if (value.valid) l0[line] = value;
      else delete l0[line];
    }
    return { ...frame, signals: { ...state }, registers: { ...registers }, csrs: { ...csrs }, memory: { ...memory }, l0: { ...l0 } };
  });
}

export function changedSignals(current: Record<string, string>, previous?: Record<string, string>) {
  if (!previous) return new Set(Object.keys(current));
  return new Set(Object.keys(current).filter((key) => current[key] !== previous[key]));
}

export function instructionStateAt(frame: TraceFrame, instruction: TraceScenario["instructions"][number]) {
  for (const [stage, lanes] of Object.entries(frame.stages)) {
    const tag = lanes.find((item) => item?.instructionId === instruction.instructionId);
    if (tag) return { status: tag.state === "held" ? "held" : "active", stage, lane: tag.lane } as const;
  }
  if (frame.events.some((event) => event.type === "flush" && event.instructionId === instruction.instructionId) || (instruction.flushCycle !== undefined && frame.cycle >= instruction.flushCycle)) return { status: "flushed" } as const;
  if (frame.events.some((event) => event.type === "retire" && event.instructionId === instruction.instructionId) || (instruction.retireCycle !== undefined && frame.cycle >= instruction.retireCycle)) return { status: "retired" } as const;
  if (frame.events.some((event) => event.type === "bubble")) return { status: "bubble" } as const;
  return { status: "pending" } as const;
}
