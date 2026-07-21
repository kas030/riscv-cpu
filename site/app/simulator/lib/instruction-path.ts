export const stageModules: Record<string, [string[], string[]]> = {
  IF: [["if_stage", "pc", "branch_predictor"], ["if_stage", "pc", "branch_predictor"]],
  ID: [["if_id", "id0", "reg_file", "decoder0", "main_ctrl0", "imm_gen0", "alu_ctrl0", "csr_decode0", "hazard"], ["if_id", "id1", "reg_file", "decoder1", "main_ctrl1", "imm_gen1", "alu_ctrl1", "csr_decode1", "hazard"]],
  EX: [["id_ex0", "ex0", "alu0", "rv32m0", "csr0", "redirect0", "ex_load_mask", "forward0"], ["id_ex1", "ex1", "alu1", "rv32m1", "csr1", "redirect1", "ex_load_mask", "forward1"]],
  MEM1: [["ex_mem0", "mem_stage", "lsu", "l0", "mem_load_mask0"], ["ex_mem1", "mem_stage", "lsu", "l0", "mem_load_mask1"]],
  MEM2: [["mem1_mem2_0"], ["mem1_mem2_1"]],
  WB: [["mem_wb0", "wb0", "wb_load_mask0", "wb_mux0", "wb_mux_internal0", "reg_file"], ["mem_wb1", "wb1", "wb_load_mask1", "wb_mux1", "wb_mux_internal1", "reg_file"]],
};

export const modulesAt = (stage: string, lane?: number) => lane === undefined
  ? [...new Set((stageModules[stage] ?? [[], []]).flat())]
  : (stageModules[stage]?.[lane] ?? []);

export function modulesForInstructionAt(stage: string, lane: number, word: string, writesRegister: boolean) {
  const instruction = Number.parseInt(word, 16) >>> 0;
  const opcode = instruction & 0x7f;
  const isLoad = opcode === 0x03;
  const isStore = opcode === 0x23;
  const isMemory = isLoad || isStore;
  const isControl = opcode === 0x63 || opcode === 0x67 || opcode === 0x6f || opcode === 0x73;
  const isRv32m = opcode === 0x33 && ((instruction >>> 25) & 0x7f) === 0x01;
  if (stage === "EX") return [lane === 0 ? "id_ex0" : "id_ex1", lane === 0 ? "ex0" : "ex1", lane === 0 ? "alu0" : "alu1", lane === 0 ? "forward0" : "forward1", ...(isRv32m ? [lane === 0 ? "rv32m0" : "rv32m1"] : []), ...(opcode === 0x73 ? [lane === 0 ? "csr0" : "csr1"] : []), ...(isControl ? [lane === 0 ? "redirect0" : "redirect1"] : []), ...(isLoad ? ["ex_load_mask"] : [])];
  if (stage === "MEM1") return [lane === 0 ? "ex_mem0" : "ex_mem1", ...(isMemory ? ["mem_stage", "lsu", "l0"] : []), ...(isLoad ? [lane === 0 ? "mem_load_mask0" : "mem_load_mask1"] : [])];
  if (stage === "WB") return [lane === 0 ? "mem_wb0" : "mem_wb1", lane === 0 ? "wb0" : "wb1", lane === 0 ? "wb_mux0" : "wb_mux1", lane === 0 ? "wb_mux_internal0" : "wb_mux_internal1", ...(isLoad ? [lane === 0 ? "wb_load_mask0" : "wb_load_mask1"] : []), ...(writesRegister ? ["reg_file"] : [])];
  return modulesAt(stage, lane);
}
