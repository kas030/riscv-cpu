import { reconstructFrames } from "./trace-reducer";
import type { TraceFrame, TraceIndex, TraceScenario } from "./types";

const base = "/generated/cpu-visualizer";
async function json<T>(url: string): Promise<T> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`无法加载 ${url}: HTTP ${response.status}`);
  return response.json() as Promise<T>;
}

export const loadTraceIndex = () => json<TraceIndex>(`${base}/traces/index.json`);
export async function loadScenarioChunk(scenario: TraceScenario, chunkIndex: number) {
  const chunk = scenario.chunks[chunkIndex];
  if (!chunk) throw new Error(`场景 ${scenario.id} 不存在 chunk ${chunkIndex}`);
  const payload = await json<{ frames: TraceFrame[] }>(`${base}/traces/${scenario.id}/${chunk.file}`);
  return reconstructFrames(payload.frames);
}

export async function loadScenarioChunks(scenario: TraceScenario, throughIndex: number) {
  const chunks = [];
  for (let index = 0; index <= throughIndex; index += 1) chunks.push(...await loadScenarioChunk(scenario, index));
  return chunks;
}
