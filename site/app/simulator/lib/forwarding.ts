export const forwardSources: Record<number, { stage: string; lane: number; label: string }> = {
  1: { stage: "WB", lane: 0, label: "WB / 槽 0" },
  2: { stage: "MEM1", lane: 0, label: "MEM1 / 槽 0" },
  3: { stage: "MEM2", lane: 0, label: "MEM2 / 槽 0" },
  4: { stage: "WB", lane: 1, label: "WB / 槽 1" },
  5: { stage: "MEM1", lane: 1, label: "MEM1 / 槽 1" },
  6: { stage: "MEM2", lane: 1, label: "MEM2 / 槽 1" },
};

export function decodeForwardSource(value: string | undefined) {
  return forwardSources[Number.parseInt(value ?? "0", 2)];
}
