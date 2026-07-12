// =============================================================================
// hazard_unit.sv —— 流水线冒险检测
//   集中检测两类冒险并输出停顿/冲刷信号：
//     1) Load-Use 冒险：ID/EX load 固定停一拍；EX/MEM(MEM1) load 在 L0
//        命中时可由 MEM2 前递，否则再停一拍等待 WB。
//     2) Branch Mispredict：EX 级发现预测错误
//        → Flush IF/ID 与 ID/EX，把已经取/译的两条错路径指令换成 NOP
//   预测正确时不冲刷流水线，pc_reg 已经沿预测路径继续取指。
// =============================================================================
module hazard_unit (
    input  logic [4:0] IF_ID_rs1     ,                      // IF/ID 第一槽 rs1 号
    input  logic [4:0] IF_ID_rs2     ,                      // IF/ID 第一槽 rs2 号
    input  logic       IF_ID_uses_rs1,
    input  logic       IF_ID_uses_rs2,
    input  logic [4:0] IF_ID_rs1_1   ,                      // IF/ID 第二槽 rs1 号
    input  logic [4:0] IF_ID_rs2_1   ,                      // IF/ID 第二槽 rs2 号
    input  logic       IF_ID_uses_rs1_1,
    input  logic       IF_ID_uses_rs2_1,
    input  logic       IF_ID_valid_1 ,
    input  logic [4:0] ID_EX_rd      ,                      // ID/EX 第一槽已译出的 rd 号
    input  logic       ID_EX_MemRead ,                      // ID/EX 第一槽是 load 标志
    input  logic [4:0] ID_EX_rd_1    ,                      // ID/EX 第二槽已译出的 rd 号
    input  logic       ID_EX_MemRead_1,                     // ID/EX 第二槽是 load 标志
    input  logic [4:0] EX_MEM_rd     ,                      // EX/MEM(MEM1) 第一槽写回目标
    input  logic       EX_MEM_MemRead,                      // EX/MEM(MEM1) 第一槽是 load 标志
    input  logic       EX_MEM_LoadReady,
    input  logic [4:0] EX_MEM_rd_1   ,                      // EX/MEM(MEM1) 第二槽写回目标
    input  logic       EX_MEM_MemRead_1,                    // EX/MEM(MEM1) 第二槽是 load 标志
    input  logic       EX_MEM_LoadReady_1,
    input  logic       BranchMispredict,                    // EX 级发现预测错误
    output logic       Stall         ,                      // 冻结 pc_reg + IF/ID
    output logic       Flush_IF_ID   ,                      // IF/ID 注入 NOP
    output logic       Flush_ID_EX                          // ID/EX 控制信号清零
);
    // load-use 检测：EX 级 load 和 MEM1 级 load 都还不能被下一条指令消费。
    logic load_use_ex, load_use_mem;
    logic hit_id_ex_slot0, hit_id_ex_slot1;
    logic hit_ex_mem_slot0, hit_ex_mem_slot1;
    logic hit_id_ex_slot0_1, hit_id_ex_slot1_1;
    logic hit_ex_mem_slot0_1, hit_ex_mem_slot1_1;

    assign hit_id_ex_slot0 = (IF_ID_uses_rs1 && (ID_EX_rd == IF_ID_rs1)) ||
                             (IF_ID_uses_rs2 && (ID_EX_rd == IF_ID_rs2));
    assign hit_id_ex_slot1 = IF_ID_valid_1 &&
                             ((IF_ID_uses_rs1_1 && (ID_EX_rd == IF_ID_rs1_1)) ||
                              (IF_ID_uses_rs2_1 && (ID_EX_rd == IF_ID_rs2_1)));
    assign hit_ex_mem_slot0 = (IF_ID_uses_rs1 && (EX_MEM_rd == IF_ID_rs1)) ||
                              (IF_ID_uses_rs2 && (EX_MEM_rd == IF_ID_rs2));
    assign hit_ex_mem_slot1 = IF_ID_valid_1 &&
                              ((IF_ID_uses_rs1_1 && (EX_MEM_rd == IF_ID_rs1_1)) ||
                               (IF_ID_uses_rs2_1 && (EX_MEM_rd == IF_ID_rs2_1)));
    assign hit_id_ex_slot0_1 = (IF_ID_uses_rs1 && (ID_EX_rd_1 == IF_ID_rs1)) ||
                               (IF_ID_uses_rs2 && (ID_EX_rd_1 == IF_ID_rs2));
    assign hit_id_ex_slot1_1 = IF_ID_valid_1 &&
                               ((IF_ID_uses_rs1_1 && (ID_EX_rd_1 == IF_ID_rs1_1)) ||
                                (IF_ID_uses_rs2_1 && (ID_EX_rd_1 == IF_ID_rs2_1)));
    assign hit_ex_mem_slot0_1 = (IF_ID_uses_rs1 && (EX_MEM_rd_1 == IF_ID_rs1)) ||
                                (IF_ID_uses_rs2 && (EX_MEM_rd_1 == IF_ID_rs2));
    assign hit_ex_mem_slot1_1 = IF_ID_valid_1 &&
                                ((IF_ID_uses_rs1_1 && (EX_MEM_rd_1 == IF_ID_rs1_1)) ||
                                 (IF_ID_uses_rs2_1 && (EX_MEM_rd_1 == IF_ID_rs2_1)));

    assign load_use_ex  = (ID_EX_MemRead && (ID_EX_rd != 5'd0) &&
                           (hit_id_ex_slot0 || hit_id_ex_slot1)) ||
                          (ID_EX_MemRead_1 && (ID_EX_rd_1 != 5'd0) &&
                           (hit_id_ex_slot0_1 || hit_id_ex_slot1_1));
    assign load_use_mem = (EX_MEM_MemRead && !EX_MEM_LoadReady &&
                           (EX_MEM_rd != 5'd0) &&
                           (hit_ex_mem_slot0 || hit_ex_mem_slot1)) ||
                          (EX_MEM_MemRead_1 && !EX_MEM_LoadReady_1 &&
                           (EX_MEM_rd_1 != 5'd0) &&
                           (hit_ex_mem_slot0_1 || hit_ex_mem_slot1_1));

    // 输出：load-use → Stall + Flush_ID_EX；预测错误 → Flush_IF_ID + Flush_ID_EX
    assign Stall        = load_use_ex || load_use_mem;
    assign Flush_IF_ID  = BranchMispredict;
    assign Flush_ID_EX  = load_use_ex || load_use_mem || BranchMispredict;
endmodule
