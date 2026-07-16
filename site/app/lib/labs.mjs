export const instructionPresets = {
  addi_x5: { label: "addi x5, x1, 1", kind: "alu", writes: 5, reads: [1], canDual: true },
  add_x6_x5: { label: "add x6, x5, x2", kind: "alu", writes: 6, reads: [5, 2], canDual: true },
  xor_x7: { label: "xor x7, x3, x4", kind: "alu", writes: 7, reads: [3, 4], canDual: true },
  lw_x8: { label: "lw x8, 0(x3)", kind: "mem", writes: 8, reads: [3], canDual: true },
  sw_x4: { label: "sw x4, 0(x3)", kind: "mem", writes: 0, reads: [3, 4], canDual: true },
  mul_x9: { label: "mul x9, x3, x4", kind: "m", writes: 9, reads: [3, 4], canDual: true },
  div_x10: { label: "div x10, x6, x7", kind: "m", writes: 10, reads: [6, 7], canDual: true },
  beq: { label: "beq x1, x2, target", kind: "control", writes: 0, reads: [1, 2], canDual: false },
  li_x5: { label: "addi x5, x0, 9", kind: "alu", writes: 5, reads: [0], canDual: true },
};

export function analyzePair(first, second) {
  const reasons = [];
  if (!first.canDual || !second.canDual) reasons.push("控制流或 CSR 指令不进入双发射包");
  if (first.kind === "mem" && second.kind === "mem") reasons.push("共享数据端口禁止双访存");
  if (first.kind === "m" && second.kind === "m") reasons.push("同包最多一条 RV32M");
  if (first.writes !== 0 && second.reads.includes(first.writes)) reasons.push("槽 1 读取槽 0 的 rd，形成包内 RAW");
  const waw = first.writes !== 0 && first.writes === second.writes;
  return {
    allowed: reasons.length === 0,
    reasons,
    waw,
    note: waw
      ? "当前 RTL 未显式拒绝 WAW；同拍写回时槽 1 是较年轻写入，最终值来自槽 1。"
      : "槽 0 较老、槽 1 较年轻；两条指令仍按程序序提交。",
  };
}

const priority = ["MEM1_S1", "MEM1_0", "MEM2_S1", "MEM2_0", "WB_S1", "WB_0"];
export function selectForward(rs, producers) {
  const hit = priority.find((key) => producers[key]?.valid && producers[key].rd === rs);
  return hit ?? "REGFILE";
}

export function selectLoad(word, offset, width, unsigned = false) {
  const value = Number(BigInt.asUintN(32, BigInt(word)));
  const bits = width === "byte" ? 8 : width === "half" ? 16 : 32;
  const shift = width === "word" ? 0 : (offset & (width === "half" ? 2 : 3)) * 8;
  const mask = bits === 32 ? 0xffffffff : (1 << bits) - 1;
  const raw = (value >>> shift) & mask;
  if (unsigned || bits === 32) return raw >>> 0;
  const sign = 2 ** (bits - 1);
  return raw & sign ? (raw - 2 ** bits) >>> 0 : raw >>> 0;
}

export function resolveControl({ redirectPending, exBusy, loadHazard }) {
  const stallFront = Boolean(exBusy || loadHazard);
  return {
    stallFront,
    flushIdEx: redirectPending ? true : Boolean(loadHazard && !exBusy),
    flushIfId: Boolean(redirectPending),
    action: redirectPending
      ? stallFront
        ? "保持已锁存重定向，等待前端可消费"
        : "消费重定向并冲刷错误路径"
      : exBusy
        ? "保持 PC、IF/ID 与 ID/EX，M 单元继续运行"
        : loadHazard
          ? "冻结前端并向 ID/EX 注入 bubble"
          : "流水线正常推进",
  };
}
