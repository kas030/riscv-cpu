// =============================================================================
// hazard_unit.sv —— 流水线冒险检测
//   集中检测两类冒险并输出停顿/冲刷信号：
//     1) Load-Use 冒险：ID/EX 是 load 且其 rd 与 IF/ID 的 rs1 或 rs2 命中
//        → Stall 冻结 pc_reg 和 IF/ID，并 Flush ID/EX 注入气泡
//     2) Branch Redirect：EX 级发现预测错误或未预测跳转
//        → Flush IF/ID 与 ID/EX，把已经取/译的两条错路径指令换成 NOP
//   设计上不区分 BranchRedirect 是否需要 Stall —— pc_reg 在重定向时由 IF 级
//   IF_npc_redirect 直接重定向，不再需要冻结。
// =============================================================================
module hazard_unit (
    input  logic [4:0] IF_ID_rs1     ,                      // IF/ID 已译出的 rs1 号
    input  logic [4:0] IF_ID_rs2     ,                      // IF/ID 已译出的 rs2 号
    input  logic [4:0] ID_EX_rd      ,                      // ID/EX 已译出的 rd 号
    input  logic       ID_EX_MemRead ,                      // ID/EX 是 load 标志
    input  logic       BranchRedirect,                      // EX 级需要修正取指流
    output logic       Stall         ,                      // 冻结 pc_reg + IF/ID
    output logic       Flush_IF_ID   ,                      // IF/ID 注入 NOP
    output logic       Flush_ID_EX                          // ID/EX 控制信号清零
);
    // load-use 检测：ID/EX 是 load 且 rd 与 IF/ID 任一源寄存器命中
    logic load_use;
    assign load_use     = ID_EX_MemRead && (ID_EX_rd != 5'd0) &&
                          ((ID_EX_rd == IF_ID_rs1) || (ID_EX_rd == IF_ID_rs2));

    // 输出：load-use → Stall + Flush_ID_EX；BranchRedirect → Flush_IF_ID + Flush_ID_EX
    assign Stall        = load_use;
    assign Flush_IF_ID  = BranchRedirect;
    assign Flush_ID_EX  = load_use || BranchRedirect;
endmodule
