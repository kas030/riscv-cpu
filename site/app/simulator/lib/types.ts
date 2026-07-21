export type ModuleManifest = {
  id: string;
  path: string;
  module: string;
  label: string;
  stage: "IF" | "ID" | "EX" | "MEM1" | "MEM2" | "WB" | "feedback";
  lane?: 0 | 1 | "shared";
  kind: "stage" | "register" | "compute" | "control" | "memory" | "mux";
  parent?: string;
  source: { file: string; line: number };
};

export type SignalManifest = {
  id: string;
  path: string;
  width: number;
  group: string;
  label: string;
  format: "hex" | "binary" | "unsigned" | "signed" | "instruction" | "enum";
  description: string;
  enum?: Record<string, string>;
};

export type GraphManifest = {
  schemaVersion: number;
  description: string;
  modules: ModuleManifest[];
  ports: { id: string; moduleId: string; name: string; direction: string }[];
  edges: { id: string; source: string; target: string; kind: string; signalIds: string[] }[];
  signals: SignalManifest[];
  groups: { id: string; label: string; color: string }[];
  layouts: { overview: Record<string, { x: number; y: number }>; modules: Record<string, { x: number; y: number }> };
};

export type TraceEvent = {
  type: "stall" | "bubble" | "flush" | "redirect" | "l0-hit" | "l0-miss" | "l0-invalidate" | "store" | "csr-write" | "retire";
  label: string;
  instructionId?: number;
  lane?: number;
  address?: string;
  value?: string;
  register?: string;
  reason?: "direction" | "target";
  peripheral?: string;
};

export type StageTag = { instructionId: number; pc: string; instruction: string; lane: number; state?: "active" | "held" | "bubble" | "flushed" };
export type TraceFrame = {
  cycle: number;
  retireCount: number;
  retiredTotal: number;
  changed: Record<string, string>;
  stages: Record<string, [StageTag | null, StageTag | null]>;
  events: TraceEvent[];
  registers?: Record<string, string>;
  csrs?: Record<string, string>;
  memory?: Record<string, string>;
  l0?: Record<string, { valid: boolean; tag?: string; data?: string; address?: string }>;
};

export type TraceScenario = {
  id: string;
  title: string;
  category: string;
  description: string;
  rtlDigest: string;
  manifestSha256: string;
  traceToolDigest: string;
  totalCycles: number;
  retired: number;
  result: "PASS";
  metadata: string;
  chunks: { start: number; end: number; file: string }[];
  instructions: {
    instructionId: number;
    pc: string;
    instruction: string;
    disassembly: string;
    issueCycle: number;
    retireCycle?: number;
    flushCycle?: number;
    lane: number;
    architecturalWrite?: { register: string; value: string };
    memory?: { kind: "load" | "store"; address: string; rawValue: string; architecturalValue?: string; mask?: string };
    csr?: { index: string; value: string; operation: string };
  }[];
};

export type TraceIndex = { schemaVersion: number; graphSchemaVersion: number; rtlDigest: string; manifestSha256: string; traceToolDigest: string; scenarios: TraceScenario[] };
