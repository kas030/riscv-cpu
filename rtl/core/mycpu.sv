`timescale 1ns / 1ps
`include "../common/defines.sv"
// =============================================================================
// mycpu.sv —— RV32I/RV32M CPU 顶层
//   将流水线各 stage 模块、流水寄存器、hazard_unit、forwarding_unit、
//   寄存器堆按数据流方向连接起来。MEM 后端拆成 MEM1/MEM2 以流水化 BRAM load。
//   对外暴露的接口仅保留：
//     - cpu_clk / cpu_rst                     时钟与复位
//     - irom_addr*/irom_data*                 双路 IROM 取指接口（同步只读）
//     - perip_addr / perip_wen / perip_mask /
//       perip_wdata / perip_rdata             外设/BRAM 访存接口
//   内部信号按 IF→ID→EX→MEM→WB 五级分组。第一槽沿用 `<stage>_<信号>` 命名，
//   第二槽使用 `_S1` 后缀。当前双发射为顺序提交版本：允许无槽内 RAW 的
//   普通整数/M 扩展/单访存指令同发；同包双访存、同包双 M 和控制流组合
//   自动退化为单发射。
// =============================================================================
module mycpu (
    input  logic         cpu_rst   ,
    input  logic         cpu_clk   ,

    // ---- IROM 取指接口 ----
    output logic [31:0]  irom_addr ,
    output logic [31:0]  irom_addr1,
    input  logic [31:0]  irom_data ,
    input  logic [31:0]  irom_data1,

    // ---- 外设/BRAM 访存接口 ----
    output logic [31:0]  perip_addr  ,
    output logic         perip_wen   ,
    output logic [ 1:0]  perip_mask  ,
    output logic [31:0]  perip_wdata ,
    input  logic [31:0]  perip_rdata
);
    // ---- 通用参数 ----
    parameter DATAWIDTH  = 32;
    parameter RESET_VAL  = 32'h8000_0000;                   // pc_reg 复位入口
    parameter ADDR_WIDTH = 5;                                // 寄存器堆地址宽度

    // 时钟/复位别名（保持与子模块端口命名一致）
    logic clk, rst;
    assign clk = cpu_clk;
    assign rst = cpu_rst;

    // -------------------------------------------------------------------------
    // Hazard / Forwarding 控制信号
    // -------------------------------------------------------------------------
    logic        Stall, Flush_IF_ID, Flush_ID_EX;
    logic        Stall_Hazard, EX_busy, EX_any_busy, Stall_Front, Flush_ID_EX_comb;
    logic        Flush_EX_MEM;
    logic [2:0]  ForwardA, ForwardB, ForwardA_S1, ForwardB_S1;
    logic        BranchTaken, BranchTaken_raw;
`ifndef SYNTHESIS
    logic        BranchTaken_stat_q, BranchTaken_stat_pending_q;
`endif
    logic        BranchMispredict, BranchMispredict_raw;
    logic [31:0] IF_npc_redirect_raw;
    logic        redirect_valid_q, redirect_taken_q, redirect_bp_update_q;
    logic [31:0] redirect_target_q, redirect_bp_pc_q;
    logic        BP_update_en, BP_update_taken;
    logic        MEM_bram_access, MEM_S1_bram_access, MEM_use_s1_bus;
    logic [31:0] MEM_bus_addr, MEM_bus_wdata;
    logic        MEM_bus_wen;
    logic [1:0]  MEM_bus_mask;
    logic        MEM_bram_load;
    logic        EX_cache_probe_hit, EX_cache_ready0, EX_cache_ready1;
    logic [31:0] EX_cache_probe_addr, EX_cache_probe_addr0, EX_cache_probe_addr1;
    logic [31:0] EX_cache_probe_data, EX_cache_probe_raw, EX_cache_probe_load_data;
    logic        MEM_cache_fill_en;
    logic [31:0] MEM_cache_fill_addr;
    logic        LoadUseEX, LoadUseMEM;

    localparam logic [13:0] BRAM_ADDR_TAG = 14'h2004;       // 0x8010_0000..0x8013_FFFF

    function automatic logic is_bram_addr(input logic [31:0] addr);
        is_bram_addr = (addr[31:18] == BRAM_ADDR_TAG);
    endfunction

    function automatic logic [31:0] select_load_raw(
        input logic [31:0] word,
        input logic [2:0]  funct3,
        input logic [1:0]  offset
    );
        begin
            case (funct3[1:0])
                2'b00: begin
                    case (offset)
                        2'b00: select_load_raw = {24'b0, word[7:0]};
                        2'b01: select_load_raw = {24'b0, word[15:8]};
                        2'b10: select_load_raw = {24'b0, word[23:16]};
                        default: select_load_raw = {24'b0, word[31:24]};
                    endcase
                end
                2'b01: select_load_raw = offset[1] ? {16'b0, word[31:16]} :
                                                    {16'b0, word[15:0]};
                default: select_load_raw = word;
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // IF 级信号
    // -------------------------------------------------------------------------
    logic [31:0] IF_pc, IF_pc1, IF_npc_redirect, IF_instr, IF_instr1;
    logic        IF_issue_dual;
    logic        IF_pred_taken;
    logic [31:0] IF_pred_target;

    // -------------------------------------------------------------------------
    // IF/ID 寄存器输出（即 ID 级输入）
    // -------------------------------------------------------------------------
    logic [31:0] ID_pc, ID_instr, ID_pc1, ID_instr1, ID_instr1_effective;
    logic        ID_issue_dual;
    logic        ID_pred_taken;
    logic [31:0] ID_pred_target;

    // -------------------------------------------------------------------------
    // ID 级信号
    // -------------------------------------------------------------------------
    logic [31:0] ID_imm, ID_rR1_data, ID_rR2_data;
    logic        ID_RegWrite, ID_MemWrite, ID_MemRead;
    logic        ID_ALUSrcA, ID_ALUSrcB;
    logic [2:0]  ID_MemToReg;
    logic [1:0]  ID_NpcOp, ID_OffsetOrigin;
    logic [`ALU_OP_WIDTH - 1:0] ID_ALUControl;
    logic [11:0] ID_csr_idx;
    logic [4:0]  ID_csr_zimm;
    logic [5:0]  ID_CSRControll;
    logic [2:0]  ID_funct3;
    logic [4:0]  ID_rs1, ID_rs2, ID_rd;
    logic        ID_uses_rs1, ID_uses_rs2;
    logic [31:0] ID_S1_imm, ID_S1_rR1_data, ID_S1_rR2_data;
    logic        ID_S1_RegWrite, ID_S1_MemWrite, ID_S1_MemRead;
    logic        ID_S1_ALUSrcA, ID_S1_ALUSrcB;
    logic [2:0]  ID_S1_MemToReg;
    logic [1:0]  ID_S1_NpcOp, ID_S1_OffsetOrigin;
    logic [`ALU_OP_WIDTH - 1:0] ID_S1_ALUControl;
    logic [11:0] ID_S1_csr_idx;
    logic [4:0]  ID_S1_csr_zimm;
    logic [5:0]  ID_S1_CSRControll;
    logic [2:0]  ID_S1_funct3;
    logic [4:0]  ID_S1_rs1, ID_S1_rs2, ID_S1_rd;
    logic        ID_S1_uses_rs1, ID_S1_uses_rs2;

    // -------------------------------------------------------------------------
    // ID/EX 寄存器输出（即 EX 级输入）
    // -------------------------------------------------------------------------
    logic [31:0] EX_pc, EX_imm, EX_rR1_data, EX_rR2_data;
    logic [4:0]  EX_rs1, EX_rs2, EX_rd;
    logic        EX_RegWrite, EX_MemWrite, EX_MemRead;
    logic [2:0]  EX_MemToReg, EX_funct3;
    logic        EX_ALUSrcA, EX_ALUSrcB;
    logic [`ALU_OP_WIDTH - 1:0] EX_ALUControl;
    logic [1:0]  EX_NpcOp, EX_OffsetOrigin;
    logic [11:0] EX_csr_idx;
    logic [4:0]  EX_csr_zimm;
    logic [5:0]  EX_CSRControll;
    logic        EX_pred_taken;
    logic [31:0] EX_pred_target;
    logic [31:0] EX_S1_pc, EX_S1_imm, EX_S1_rR1_data, EX_S1_rR2_data;
    logic [4:0]  EX_S1_rs1, EX_S1_rs2, EX_S1_rd;
    logic        EX_S1_RegWrite, EX_S1_MemWrite, EX_S1_MemRead;
    logic [2:0]  EX_S1_MemToReg, EX_S1_funct3;
    logic        EX_S1_ALUSrcA, EX_S1_ALUSrcB;
    logic [`ALU_OP_WIDTH - 1:0] EX_S1_ALUControl;
    logic [1:0]  EX_S1_NpcOp, EX_S1_OffsetOrigin;
    logic [11:0] EX_S1_csr_idx;
    logic [4:0]  EX_S1_csr_zimm;
    logic [5:0]  EX_S1_CSRControll;
    logic        EX_S1_pred_taken;
    logic [31:0] EX_S1_pred_target;

    // -------------------------------------------------------------------------
    // EX 级输出
    // -------------------------------------------------------------------------
    logic [31:0] EX_alu_result, EX_mem_addr, EX_forward_B_out;
    logic [31:0] EX_csr_wb;
    logic [31:0] EX_S1_alu_result, EX_S1_mem_addr, EX_S1_forward_B_out;
    logic [31:0] EX_S1_csr_wb;
    logic [31:0] IF_npc_redirect_raw_S1;
    logic        BranchTaken_raw_S1, BranchMispredict_raw_S1, EX_busy_S1;

    // -------------------------------------------------------------------------
    // EX/MEM 寄存器输出（即 MEM 级输入）
    // -------------------------------------------------------------------------
    logic [31:0] MEM_pcadd4, MEM_alu_result, MEM_perip_addr, MEM_perip_bus_addr, MEM_rR2_data, MEM_imm;
    logic [4:0]  MEM_rd;
    logic [31:0] MEM_rd_oh;
    logic        MEM_RegWrite, MEM_MemWrite, MEM_MemRead;
    logic [2:0]  MEM_MemToReg, MEM_funct3;
    logic [31:0] MEM_csr_wb;
    logic [31:0] MEM_S1_pcadd4, MEM_S1_alu_result, MEM_S1_perip_addr, MEM_S1_perip_bus_addr, MEM_S1_rR2_data, MEM_S1_imm;
    logic [4:0]  MEM_S1_rd;
    logic [31:0] MEM_S1_rd_oh;
    logic        MEM_S1_RegWrite, MEM_S1_MemWrite, MEM_S1_MemRead;
    logic [2:0]  MEM_S1_MemToReg, MEM_S1_funct3;
    logic [31:0] MEM_S1_csr_wb;

    // MEM 级中转给 EX 级前递的候选数据 / 外设原始读数
    logic [31:0] MEM_mdata;
    logic [31:0] MEM_forward_data;
    logic [31:0] MEM_S1_forward_data;
    logic [31:0] MEM_forward_data_effective, MEM_S1_forward_data_effective;
    logic        MEM_early_cache_hit0, MEM_early_cache_hit1;
    logic [31:0] MEM_early_cache_data0, MEM_early_cache_data1;
    logic        MEM_cache_hit, MEM_cache_hit0, MEM_cache_hit1;
    logic [31:0] MEM_cache_data;

    // -------------------------------------------------------------------------
    // MEM1/MEM2 寄存器输出（即 MEM2 级输入）
    // -------------------------------------------------------------------------
    logic [31:0] MEM2_pcadd4, MEM2_alu_result, MEM2_mmio_mdata, MEM2_imm;
    logic [4:0]  MEM2_rd;
    logic [31:0] MEM2_rd_oh;
    logic        MEM2_RegWrite, MEM2_MemRead, MEM2_bram_access;
    logic [2:0]  MEM2_MemToReg, MEM2_funct3;
    logic [31:0] MEM2_csr_wb;
    logic [31:0] MEM2_mdata;
    logic [31:0] MEM2_forward_data;
    logic        MEM2_cache_hit;
    logic [31:0] MEM2_S1_pcadd4, MEM2_S1_alu_result, MEM2_S1_mmio_mdata, MEM2_S1_imm;
    logic [4:0]  MEM2_S1_rd;
    logic [31:0] MEM2_S1_rd_oh;
    logic        MEM2_S1_RegWrite, MEM2_S1_MemRead, MEM2_S1_bram_access;
    logic [2:0]  MEM2_S1_MemToReg, MEM2_S1_funct3;
    logic [31:0] MEM2_S1_csr_wb;
    logic [31:0] MEM2_S1_mdata;
    logic [31:0] MEM2_S1_forward_data;
    logic        MEM2_S1_cache_hit;

    // -------------------------------------------------------------------------
    // MEM/WB 寄存器输出（即 WB 级输入）
    // -------------------------------------------------------------------------
    logic [31:0] WB_pcadd4, WB_alu_result, WB_mdata, WB_imm;
    logic [4:0]  WB_rd;
    logic [31:0] WB_rd_oh;
    logic        WB_RegWrite;
    logic [2:0]  WB_MemToReg, WB_funct3;
    logic [31:0] WB_csr_wb;
    logic [31:0] WB_S1_pcadd4, WB_S1_alu_result, WB_S1_mdata, WB_S1_imm;
    logic [4:0]  WB_S1_rd;
    logic [31:0] WB_S1_rd_oh;
    logic        WB_S1_RegWrite;
    logic [2:0]  WB_S1_MemToReg, WB_S1_funct3;
    logic [31:0] WB_S1_csr_wb;

    // -------------------------------------------------------------------------
    // WB 级输出（同时也是 reg_file 写口数据）
    // -------------------------------------------------------------------------
    logic [31:0] WB_wdata;
    logic [31:0] WB_S1_wdata;

`ifndef SYNTHESIS
    // 仿真性能统计使用的架构有效位。每一级严格复刻对应流水寄存器的
    // flush / stall / enable 语义，不参与综合后的功能数据通路。
    logic ID_valid, ID_S1_valid;
    logic EX_valid, EX_S1_valid;
    logic MEM_valid, MEM_S1_valid;
    logic MEM2_valid, MEM2_S1_valid;
    logic WB_retire_valid0, WB_retire_valid1;
    logic MEM2_store0, MEM2_store1;
    logic WB_retire_store0, WB_retire_store1;
`endif

    localparam logic [31:0] NOP_INSTR = 32'h0000_0013;

    assign ID_instr1_effective = ID_issue_dual ? ID_instr1 : NOP_INSTR;

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst || Flush_IF_ID) begin
            ID_valid    <= 1'b0;
            ID_S1_valid <= 1'b0;
        end else if (!Stall_Front) begin
            ID_valid    <= 1'b1;
            ID_S1_valid <= IF_issue_dual;
        end

        if (rst || Flush_ID_EX_comb) begin
            EX_valid    <= 1'b0;
            EX_S1_valid <= 1'b0;
        end else if (!EX_any_busy) begin
            EX_valid    <= ID_valid;
            EX_S1_valid <= ID_S1_valid;
        end

        if (rst || Flush_EX_MEM) begin
            MEM_valid    <= 1'b0;
            MEM_S1_valid <= 1'b0;
        end else if (EX_any_busy) begin
            // 多周期 M 执行时 EX/MEM 保持旧内容，并未发生新的级间传输。
            // 统计通道必须注入 bubble，避免旧指令被 MEM2/WB 重复退休。
            MEM_valid    <= 1'b0;
            MEM_S1_valid <= 1'b0;
        end else if (!EX_any_busy) begin
            MEM_valid    <= EX_valid;
            MEM_S1_valid <= EX_S1_valid;
        end

        if (rst) begin
            MEM2_valid       <= 1'b0;
            MEM2_S1_valid    <= 1'b0;
            MEM2_store0      <= 1'b0;
            MEM2_store1      <= 1'b0;
            WB_retire_valid0 <= 1'b0;
            WB_retire_valid1 <= 1'b0;
            WB_retire_store0 <= 1'b0;
            WB_retire_store1 <= 1'b0;
        end else begin
            MEM2_valid       <= MEM_valid;
            MEM2_S1_valid    <= MEM_S1_valid;
            MEM2_store0      <= MEM_valid && MEM_MemWrite;
            MEM2_store1      <= MEM_S1_valid && MEM_S1_MemWrite;
            WB_retire_valid0 <= MEM2_valid;
            WB_retire_valid1 <= MEM2_S1_valid;
            WB_retire_store0 <= MEM2_store0;
            WB_retire_store1 <= MEM2_store1;
        end
    end
`endif

    assign ID_uses_rs1 = (ID_instr[6:0] == `R_TYPE  ) ||
                         (ID_instr[6:0] == `I_TYPE  ) ||
                         (ID_instr[6:0] == `IL_TYPE ) ||
                         (ID_instr[6:0] == `IJ_TYPE ) ||
                         (ID_instr[6:0] == `S_TYPE  ) ||
                         (ID_instr[6:0] == `B_TYPE  ) ||
                         ((ID_instr[6:0] == `CSR_TYPE) &&
                          ((ID_instr[14:12] == 3'b001) ||
                           (ID_instr[14:12] == 3'b010) ||
                           (ID_instr[14:12] == 3'b011)));

    assign ID_uses_rs2 = (ID_instr[6:0] == `R_TYPE) ||
                         (ID_instr[6:0] == `S_TYPE) ||
                         (ID_instr[6:0] == `B_TYPE);

    assign ID_S1_uses_rs1 = ID_issue_dual &&
                            ((ID_instr1_effective[6:0] == `R_TYPE  ) ||
                             (ID_instr1_effective[6:0] == `I_TYPE  ) ||
                             (ID_instr1_effective[6:0] == `IL_TYPE ) ||
                             (ID_instr1_effective[6:0] == `IJ_TYPE ) ||
                             (ID_instr1_effective[6:0] == `S_TYPE  ) ||
                             (ID_instr1_effective[6:0] == `B_TYPE  ) ||
                             ((ID_instr1_effective[6:0] == `CSR_TYPE) &&
                              ((ID_instr1_effective[14:12] == 3'b001) ||
                               (ID_instr1_effective[14:12] == 3'b010) ||
                               (ID_instr1_effective[14:12] == 3'b011))));

    assign ID_S1_uses_rs2 = ID_issue_dual &&
                            ((ID_instr1_effective[6:0] == `R_TYPE) ||
                             (ID_instr1_effective[6:0] == `S_TYPE) ||
                             (ID_instr1_effective[6:0] == `B_TYPE));

    // =========================================================================
    // 冒险检测 / 前递选择
    // =========================================================================
    hazard_unit u_hazard_unit (
        .IF_ID_rs1     (ID_instr[19:15]),
        .IF_ID_rs2     (ID_instr[24:20]),
        .IF_ID_uses_rs1(ID_uses_rs1    ),
        .IF_ID_uses_rs2(ID_uses_rs2    ),
        .IF_ID_rs1_1   (ID_instr1_effective[19:15]),
        .IF_ID_rs2_1   (ID_instr1_effective[24:20]),
        .IF_ID_uses_rs1_1(ID_S1_uses_rs1),
        .IF_ID_uses_rs2_1(ID_S1_uses_rs2),
        .IF_ID_valid_1 (ID_issue_dual   ),
        .ID_EX_rd      (EX_rd          ),
        .ID_EX_MemRead (EX_MemRead     ),
        .ID_EX_LoadReady(EX_cache_ready0),
        .ID_EX_rd_1    (EX_S1_rd       ),
        .ID_EX_MemRead_1(EX_S1_MemRead ),
        .ID_EX_LoadReady_1(EX_cache_ready1),
        .EX_MEM_rd     (MEM_rd         ),
        .EX_MEM_MemRead(MEM_MemRead    ),
        .EX_MEM_LoadReady(MEM_cache_hit0),
        .EX_MEM_rd_1   (MEM_S1_rd      ),
        .EX_MEM_MemRead_1(MEM_S1_MemRead),
        .EX_MEM_LoadReady_1(MEM_cache_hit1),
        .BranchMispredict (BranchMispredict),
        .Stall         (Stall_Hazard   ),
        .Flush_IF_ID   (Flush_IF_ID    ),
        .Flush_ID_EX   (Flush_ID_EX    ),
        .LoadUseEX     (LoadUseEX      ),
        .LoadUseMEM    (LoadUseMEM     )
    );

    assign MEM_bram_access    = is_bram_addr(MEM_perip_addr);
    assign MEM_S1_bram_access = is_bram_addr(MEM_S1_perip_addr);
    assign MEM_use_s1_bus     = !(MEM_MemWrite || MEM_MemRead) &&
                                (MEM_S1_MemWrite || MEM_S1_MemRead);
    assign MEM_cache_hit0 = MEM_MemRead && MEM_bram_access && MEM_cache_hit;
    assign MEM_cache_hit1 = MEM_S1_MemRead && MEM_S1_bram_access && MEM_cache_hit;
    assign Flush_EX_MEM       = redirect_valid_q;

    // redirect/flush 打拍提交：
    //   EX 级只组合计算 raw redirect；这里寄存后再驱动 IF 重定向和流水 flush，
    //   切断 ALU/branch compare -> Flush_ID_EX 的运行期长路径。
    //
    // 优先级（从高到低）：
    //   1) redirect_valid_q 有效且前段不暂停 → 消费完毕，清 0
    //   2) BranchMispredict_raw 新来了分支误预测 → 直接设置 valid
    //   3) 分支指令（NpcOp==01）且 EX 不忙 → 记录 bp_update（预测正确也要更新）
    always_ff @(posedge clk) begin
        if (rst) begin
            redirect_valid_q     <= 1'b0;
            redirect_target_q    <= '0;
            redirect_taken_q     <= 1'b0;
            redirect_bp_update_q <= 1'b0;
            redirect_bp_pc_q     <= '0;
        end else begin
            // bp_update 默认清 0（仅当有分支完成时在下方设为 1）
            redirect_bp_update_q <= 1'b0;
            // 记录分支 PC，用于更新预测器历史表
            redirect_bp_pc_q     <= EX_pc;

            // pending 重定向期间始终保持已锁存目标。消费重定向只需清 valid，
            // 无需让 load-use stall 进入 target/taken 寄存器的 CE 路径。
            if (!redirect_valid_q) begin
                redirect_target_q <= IF_npc_redirect_raw;
                redirect_taken_q  <= BranchTaken_raw;
            end

            // [优先级 1] 当前重定向正在被 IF 消费
            if (redirect_valid_q) begin
                if (!Stall_Front) begin           // 前段已处理完，可以清 valid
                    redirect_valid_q <= 1'b0;
                end
            // [优先级 2] EX 刚检测到分支误预测，立即发起重定向
            end else if (BranchMispredict_raw) begin
                redirect_valid_q  <= 1'b1;
                // 只有分支（非 jal/jalr）才需要更新预测器历史
                redirect_bp_update_q <= (EX_NpcOp == 2'b01);
            // [优先级 3] 普通分支（预测正确），只需更新预测器，不需要重定向
            end else if (!EX_any_busy && (EX_NpcOp == 2'b01)) begin
                redirect_bp_update_q <= 1'b1;
            end
        end
    end

    assign IF_npc_redirect = redirect_target_q;

    // 前半段统一停顿条件：
    //   1) 原有 load-use 冒险
    //   2) 任一 EX 槽正在执行多周期 RV32M，前面的指令不能继续往前推，否则会覆盖 EX
    //   BRAM load 通过 MEM1/MEM2 后端流水返回，不再冻结整条前段流水。
    assign EX_any_busy     = EX_busy | EX_busy_S1;
    assign Stall_Front     = Stall_Hazard | EX_any_busy;
    // EX 忙时不能再往 ID/EX 注入 bubble，否则会把正在执行的 M 指令冲掉。
    assign Flush_ID_EX_comb = redirect_valid_q ? 1'b1 :
                               (Flush_ID_EX & ~EX_any_busy);
    assign Stall           = Stall_Front;
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst) begin
            BranchTaken_stat_q         <= 1'b0;
            BranchTaken_stat_pending_q <= 1'b0;
        end else begin
            BranchTaken_stat_q <= 1'b0;
            if (BranchTaken_stat_pending_q && !Stall_Front) begin
                BranchTaken_stat_q         <= 1'b1;
                BranchTaken_stat_pending_q <= 1'b0;
            end else if (BranchTaken_raw) begin
                if (Stall_Front) begin
                    BranchTaken_stat_pending_q <= 1'b1;
                end else begin
                    BranchTaken_stat_q <= 1'b1;
                end
            end
        end
    end

    assign BranchTaken     = BranchTaken_stat_q;
`else
    assign BranchTaken     = BranchTaken_raw;
`endif
    assign BranchMispredict = redirect_valid_q;
    assign BP_update_en    = redirect_bp_update_q;
    assign BP_update_taken = redirect_taken_q;
    forwarding_unit u_forwarding_unit (
        .ID_EX_rs1       (EX_rs1      ),
        .ID_EX_rs2       (EX_rs2      ),
        .EX_MEM_rd0      (MEM_rd      ),
        .EX_MEM_valid0   (MEM_RegWrite && (!MEM_MemRead || MEM_early_cache_hit0) &&
                          (MEM_rd != 5'd0)),
        .EX_MEM_rd1      (MEM_S1_rd   ),
        .EX_MEM_valid1   (MEM_S1_RegWrite && (!MEM_S1_MemRead || MEM_early_cache_hit1) &&
                          (MEM_S1_rd != 5'd0)),
        .MEM2_rd0        (MEM2_rd     ),
        .MEM2_valid0     (MEM2_RegWrite && (!MEM2_MemRead || MEM2_cache_hit) &&
                          (MEM2_rd != 5'd0)),
        .MEM2_rd1        (MEM2_S1_rd  ),
        .MEM2_valid1     (MEM2_S1_RegWrite && (!MEM2_S1_MemRead || MEM2_S1_cache_hit) &&
                          (MEM2_S1_rd != 5'd0)),
        .MEM_WB_rd0      (WB_rd       ),
        .MEM_WB_valid0   (WB_RegWrite && (WB_rd != 5'd0)),
        .MEM_WB_rd1      (WB_S1_rd    ),
        .MEM_WB_valid1   (WB_S1_RegWrite && (WB_S1_rd != 5'd0)),
        .ForwardA        (ForwardA    ),
        .ForwardB        (ForwardB    )
    );

    forwarding_unit u_forwarding_unit_s1 (
        .ID_EX_rs1       (EX_S1_rs1   ),
        .ID_EX_rs2       (EX_S1_rs2   ),
        .EX_MEM_rd0      (MEM_rd      ),
        .EX_MEM_valid0   (MEM_RegWrite && (!MEM_MemRead || MEM_early_cache_hit0) &&
                          (MEM_rd != 5'd0)),
        .EX_MEM_rd1      (MEM_S1_rd   ),
        .EX_MEM_valid1   (MEM_S1_RegWrite && (!MEM_S1_MemRead || MEM_early_cache_hit1) &&
                          (MEM_S1_rd != 5'd0)),
        .MEM2_rd0        (MEM2_rd     ),
        .MEM2_valid0     (MEM2_RegWrite && (!MEM2_MemRead || MEM2_cache_hit) &&
                          (MEM2_rd != 5'd0)),
        .MEM2_rd1        (MEM2_S1_rd  ),
        .MEM2_valid1     (MEM2_S1_RegWrite && (!MEM2_S1_MemRead || MEM2_S1_cache_hit) &&
                          (MEM2_S1_rd != 5'd0)),
        .MEM_WB_rd0      (WB_rd       ),
        .MEM_WB_valid0   (WB_RegWrite && (WB_rd != 5'd0)),
        .MEM_WB_rd1      (WB_S1_rd    ),
        .MEM_WB_valid1   (WB_S1_RegWrite && (WB_S1_rd != 5'd0)),
        .ForwardA        (ForwardA_S1 ),
        .ForwardB        (ForwardB_S1 )
    );

    // =========================================================================
    // STAGE 1：IF（取指）
    // =========================================================================
    mycpu_if_stage #(DATAWIDTH, RESET_VAL) u_if_stage (
        .irom_data       (irom_data      ),
        .irom_data1      (irom_data1     ),
        .IF_npc_redirect (IF_npc_redirect),
        .clk             (clk            ),
        .rst             (rst            ),
        .Stall           (Stall_Front    ),
        .BranchRedirect  (BranchMispredict),
        .BP_update_en    (BP_update_en   ),
        .BP_update_pc    (redirect_bp_pc_q),
        .BP_update_taken (BP_update_taken),
        .irom_addr       (irom_addr      ),
        .irom_addr1      (irom_addr1     ),
        .IF_pc           (IF_pc          ),
        .IF_instr        (IF_instr       ),
        .IF_instr1       (IF_instr1      ),
        .IF_issue_dual   (IF_issue_dual  ),
        .IF_pred_taken   (IF_pred_taken  ),
        .IF_pred_target  (IF_pred_target )
    );

    assign IF_pc1 = IF_pc + 32'd4;

    // ---- IF/ID 流水寄存器 ----
    mycpu_if_id_reg #(DATAWIDTH) u_if_id_reg (
        .clk         (clk        ),
        .rst         (rst        ),
        .Flush_IF_ID (Flush_IF_ID),
        .Stall       (Stall_Front),
        .IF_pc       (IF_pc      ),
        .IF_instr    (IF_instr   ),
        .IF_pc1      (IF_pc1     ),
        .IF_instr1   (IF_instr1  ),
        .IF_issue_dual(IF_issue_dual),
        .IF_pred_taken (IF_pred_taken),
        .IF_pred_target(IF_pred_target),
        .ID_pc       (ID_pc      ),
        .ID_instr    (ID_instr   ),
        .ID_pc1      (ID_pc1     ),
        .ID_instr1   (ID_instr1  ),
        .ID_issue_dual(ID_issue_dual),
        .ID_pred_taken (ID_pred_taken),
        .ID_pred_target(ID_pred_target)
    );

    // =========================================================================
    // STAGE 2：ID（译码）
    //   寄存器堆 reg_file 单独例化在顶层，写口取自 WB 级，读口直接出给 ID 级，
    //   形成 WB-ID 内部前递路径
    // =========================================================================
    mycpu_id_stage #(DATAWIDTH) u_id_stage (
        .ID_instr        (ID_instr       ),
        .ID_imm          (ID_imm         ),
        .ID_RegWrite     (ID_RegWrite    ),
        .ID_MemWrite     (ID_MemWrite    ),
        .ID_MemRead      (ID_MemRead     ),
        .ID_ALUSrcA      (ID_ALUSrcA     ),
        .ID_ALUSrcB      (ID_ALUSrcB     ),
        .ID_MemToReg     (ID_MemToReg    ),
        .ID_NpcOp        (ID_NpcOp       ),
        .ID_OffsetOrigin (ID_OffsetOrigin),
        .ID_ALUControl   (ID_ALUControl  ),
        .ID_csr_idx      (ID_csr_idx     ),
        .ID_csr_zimm     (ID_csr_zimm    ),
        .ID_CSRControll  (ID_CSRControll ),
        .ID_funct3       (ID_funct3      ),
        .ID_rs1          (ID_rs1         ),
        .ID_rs2          (ID_rs2         ),
        .ID_rd           (ID_rd          )
    );

    mycpu_id_stage #(DATAWIDTH) u_id_stage_s1 (
        .ID_instr        (ID_instr1_effective),
        .ID_imm          (ID_S1_imm         ),
        .ID_RegWrite     (ID_S1_RegWrite    ),
        .ID_MemWrite     (ID_S1_MemWrite    ),
        .ID_MemRead      (ID_S1_MemRead     ),
        .ID_ALUSrcA      (ID_S1_ALUSrcA     ),
        .ID_ALUSrcB      (ID_S1_ALUSrcB     ),
        .ID_MemToReg     (ID_S1_MemToReg    ),
        .ID_NpcOp        (ID_S1_NpcOp       ),
        .ID_OffsetOrigin (ID_S1_OffsetOrigin),
        .ID_ALUControl   (ID_S1_ALUControl  ),
        .ID_csr_idx      (ID_S1_csr_idx     ),
        .ID_csr_zimm     (ID_S1_csr_zimm    ),
        .ID_CSRControll  (ID_S1_CSRControll ),
        .ID_funct3       (ID_S1_funct3      ),
        .ID_rs1          (ID_S1_rs1         ),
        .ID_rs2          (ID_S1_rs2         ),
        .ID_rd           (ID_S1_rd          )
    );

    reg_file #(ADDR_WIDTH, DATAWIDTH) rf_inst (                  // 实例名沿用 rf_inst，testbench 层级引用依赖此名
        .clk      (clk        ),
        .rst      (rst        ),
        .wen      (WB_RegWrite),                            // 来自 WB 级
        .waddr    (WB_rd      ),
        .wdata    (WB_wdata   ),
        .wen2     (WB_S1_RegWrite),
        .waddr2   (WB_S1_rd   ),
        .wdata2   (WB_S1_wdata),
        .rR1      (ID_rs1     ),
        .rR2      (ID_rs2     ),
        .rR3      (ID_S1_rs1  ),
        .rR4      (ID_S1_rs2  ),
        .rR1_data (ID_rR1_data),
        .rR2_data (ID_rR2_data),
        .rR3_data (ID_S1_rR1_data),
        .rR4_data (ID_S1_rR2_data)
    );

    // ---- ID/EX 流水寄存器 ----
    mycpu_id_ex_reg #(DATAWIDTH, ADDR_WIDTH) u_id_ex_reg (
        .ID_pc           (ID_pc          ),
        .ID_imm          (ID_imm         ),
        .ID_rR1_data     (ID_rR1_data    ),
        .ID_rR2_data     (ID_rR2_data    ),
        .ID_rs1          (ID_rs1         ),
        .ID_rs2          (ID_rs2         ),
        .ID_rd           (ID_rd          ),
        .ID_RegWrite     (ID_RegWrite    ),
        .ID_MemWrite     (ID_MemWrite    ),
        .ID_MemRead      (ID_MemRead     ),
        .ID_MemToReg     (ID_MemToReg    ),
        .ID_funct3       (ID_funct3      ),
        .ID_ALUSrcA      (ID_ALUSrcA     ),
        .ID_ALUSrcB      (ID_ALUSrcB     ),
        .ID_ALUControl   (ID_ALUControl  ),
        .ID_NpcOp        (ID_NpcOp       ),
        .ID_OffsetOrigin (ID_OffsetOrigin),
        .ID_csr_idx      (ID_csr_idx     ),
        .ID_csr_zimm     (ID_csr_zimm    ),
        .ID_CSRControll  (ID_CSRControll ),
        .ID_pred_taken   (ID_pred_taken  ),
        .ID_pred_target  (ID_pred_target ),
        .clk             (clk            ),
        .rst             (rst            ),
        .Flush_ID_EX     (Flush_ID_EX_comb),
        .Stall_ID_EX     (EX_any_busy),
        .EX_pc           (EX_pc          ),
        .EX_imm          (EX_imm         ),
        .EX_rR1_data     (EX_rR1_data    ),
        .EX_rR2_data     (EX_rR2_data    ),
        .EX_rs1          (EX_rs1         ),
        .EX_rs2          (EX_rs2         ),
        .EX_rd           (EX_rd          ),
        .EX_RegWrite     (EX_RegWrite    ),
        .EX_MemWrite     (EX_MemWrite    ),
        .EX_MemRead      (EX_MemRead     ),
        .EX_MemToReg     (EX_MemToReg    ),
        .EX_funct3       (EX_funct3      ),
        .EX_ALUSrcA      (EX_ALUSrcA     ),
        .EX_ALUSrcB      (EX_ALUSrcB     ),
        .EX_ALUControl   (EX_ALUControl  ),
        .EX_NpcOp        (EX_NpcOp       ),
        .EX_OffsetOrigin (EX_OffsetOrigin),
        .EX_csr_idx      (EX_csr_idx     ),
        .EX_csr_zimm     (EX_csr_zimm    ),
        .EX_CSRControll  (EX_CSRControll ),
        .EX_pred_taken   (EX_pred_taken  ),
        .EX_pred_target  (EX_pred_target )
    );

    mycpu_id_ex_reg #(DATAWIDTH, ADDR_WIDTH) u_id_ex_reg_s1 (
        .ID_pc           (ID_pc1         ),
        .ID_imm          (ID_S1_imm      ),
        .ID_rR1_data     (ID_S1_rR1_data ),
        .ID_rR2_data     (ID_S1_rR2_data ),
        .ID_rs1          (ID_S1_rs1      ),
        .ID_rs2          (ID_S1_rs2      ),
        .ID_rd           (ID_S1_rd       ),
        .ID_RegWrite     (ID_S1_RegWrite ),
        .ID_MemWrite     (ID_S1_MemWrite ),
        .ID_MemRead      (ID_S1_MemRead  ),
        .ID_MemToReg     (ID_S1_MemToReg ),
        .ID_funct3       (ID_S1_funct3   ),
        .ID_ALUSrcA      (ID_S1_ALUSrcA  ),
        .ID_ALUSrcB      (ID_S1_ALUSrcB  ),
        .ID_ALUControl   (ID_S1_ALUControl),
        .ID_NpcOp        (ID_S1_NpcOp    ),
        .ID_OffsetOrigin (ID_S1_OffsetOrigin),
        .ID_csr_idx      (ID_S1_csr_idx  ),
        .ID_csr_zimm     (ID_S1_csr_zimm ),
        .ID_CSRControll  (ID_S1_CSRControll),
        .ID_pred_taken   (1'b0           ),
        .ID_pred_target  ('0             ),
        .clk             (clk            ),
        .rst             (rst            ),
        .Flush_ID_EX     (Flush_ID_EX_comb),
        .Stall_ID_EX     (EX_any_busy),
        .EX_pc           (EX_S1_pc       ),
        .EX_imm          (EX_S1_imm      ),
        .EX_rR1_data     (EX_S1_rR1_data ),
        .EX_rR2_data     (EX_S1_rR2_data ),
        .EX_rs1          (EX_S1_rs1      ),
        .EX_rs2          (EX_S1_rs2      ),
        .EX_rd           (EX_S1_rd       ),
        .EX_RegWrite     (EX_S1_RegWrite ),
        .EX_MemWrite     (EX_S1_MemWrite ),
        .EX_MemRead      (EX_S1_MemRead  ),
        .EX_MemToReg     (EX_S1_MemToReg ),
        .EX_funct3       (EX_S1_funct3   ),
        .EX_ALUSrcA      (EX_S1_ALUSrcA  ),
        .EX_ALUSrcB      (EX_S1_ALUSrcB  ),
        .EX_ALUControl   (EX_S1_ALUControl),
        .EX_NpcOp        (EX_S1_NpcOp    ),
        .EX_OffsetOrigin (EX_S1_OffsetOrigin),
        .EX_csr_idx      (EX_S1_csr_idx  ),
        .EX_csr_zimm     (EX_S1_csr_zimm ),
        .EX_CSRControll  (EX_S1_CSRControll),
        .EX_pred_taken   (EX_S1_pred_taken),
        .EX_pred_target  (EX_S1_pred_target)
    );

    // =========================================================================
    // STAGE 3：EX（执行）
    //   双路前递选择 → RV32I 轻量 alu / RV32M 多周期单元 + csr_file + npc_calc
    //   其中 RV32M 执行期间会拉高 EX_busy/EX_busy_S1，冻结前半段流水并阻止 EX/MEM 更新
    // =========================================================================
    mycpu_ex_stage #(DATAWIDTH) u_ex_stage (
        .MEM_forward_data (MEM_forward_data_effective),
        .MEM_S1_forward_data(MEM_S1_forward_data_effective),
        .MEM2_forward_data(MEM2_forward_data),
        .MEM2_S1_forward_data(MEM2_S1_forward_data),
        .WB_wdata         (WB_wdata        ),
        .WB_S1_wdata      (WB_S1_wdata     ),
        .EX_pc            (EX_pc           ),
        .EX_imm           (EX_imm          ),
        .EX_rR1_data      (EX_rR1_data     ),
        .EX_rR2_data      (EX_rR2_data     ),
        .EX_ALUControl    (EX_ALUControl   ),
        .EX_NpcOp         (EX_NpcOp        ),
        .EX_OffsetOrigin  (EX_OffsetOrigin ),
        .EX_csr_idx       (EX_csr_idx      ),
        .EX_csr_zimm      (EX_csr_zimm     ),
        .EX_CSRControll   (EX_CSRControll  ),
        .ForwardA         (ForwardA        ),
        .ForwardB         (ForwardB        ),
        .EX_ALUSrcA       (EX_ALUSrcA      ),
        .EX_ALUSrcB       (EX_ALUSrcB      ),
        .EX_pred_taken    (EX_pred_taken   ),
        .EX_pred_target   (EX_pred_target  ),
        .EX_stall         (1'b0            ),
        .EX_kill          (redirect_valid_q),
        .clk              (clk             ),
        .rst              (rst             ),
        .IF_npc_redirect_raw(IF_npc_redirect_raw),
        .EX_alu_result    (EX_alu_result   ),
        .EX_mem_addr      (EX_mem_addr     ),
        .EX_forward_B_out (EX_forward_B_out),
        .EX_csr_wb        (EX_csr_wb       ),
        .BranchTaken      (BranchTaken_raw ),
        .BranchMispredict (BranchMispredict_raw),
        .EX_busy          (EX_busy         )
    );

    mycpu_ex_stage #(DATAWIDTH) u_ex_stage_s1 (
        .MEM_forward_data (MEM_forward_data_effective),
        .MEM_S1_forward_data(MEM_S1_forward_data_effective),
        .MEM2_forward_data(MEM2_forward_data),
        .MEM2_S1_forward_data(MEM2_S1_forward_data),
        .WB_wdata         (WB_wdata        ),
        .WB_S1_wdata      (WB_S1_wdata     ),
        .EX_pc            (EX_S1_pc        ),
        .EX_imm           (EX_S1_imm       ),
        .EX_rR1_data      (EX_S1_rR1_data  ),
        .EX_rR2_data      (EX_S1_rR2_data  ),
        .EX_ALUControl    (EX_S1_ALUControl),
        // lane1 只接收 IF 级筛选后的普通整数/M/单访存指令，
        // 静态关闭不可达的控制流与 CSR 通路，便于综合删除冗余状态。
        .EX_NpcOp         (2'b00           ),
        .EX_OffsetOrigin  (2'b00           ),
        .EX_csr_idx       (12'b0           ),
        .EX_csr_zimm      (5'b0            ),
        .EX_CSRControll   (6'b0            ),
        .ForwardA         (ForwardA_S1     ),
        .ForwardB         (ForwardB_S1     ),
        .EX_ALUSrcA       (EX_S1_ALUSrcA   ),
        .EX_ALUSrcB       (EX_S1_ALUSrcB   ),
        .EX_pred_taken    (1'b0            ),
        .EX_pred_target   ('0              ),
        .EX_stall         (1'b0            ),
        .EX_kill          (redirect_valid_q),
        .clk              (clk             ),
        .rst              (rst             ),
        .IF_npc_redirect_raw(IF_npc_redirect_raw_S1),
        .EX_alu_result    (EX_S1_alu_result),
        .EX_mem_addr      (EX_S1_mem_addr  ),
        .EX_forward_B_out (EX_S1_forward_B_out),
        .EX_csr_wb        (EX_S1_csr_wb    ),
        .BranchTaken      (BranchTaken_raw_S1),
        .BranchMispredict (BranchMispredict_raw_S1),
        .EX_busy          (EX_busy_S1      )
    );

    // ---- EX/MEM 流水寄存器 ----
    mycpu_ex_mem_reg #(DATAWIDTH, ADDR_WIDTH) u_ex_mem_reg (
        .EX_pc            (EX_pc           ),
        .EX_alu_result    (EX_alu_result   ),
        .EX_mem_addr      (EX_mem_addr     ),
        .EX_forward_B_out (EX_forward_B_out),
        .EX_imm           (EX_imm          ),
        .EX_csr_wb        (EX_csr_wb       ),
        .EX_rd            (EX_rd           ),
        .EX_RegWrite      (EX_RegWrite     ),
        .EX_MemWrite      (EX_MemWrite     ),
        .EX_MemRead       (EX_MemRead      ),
        .EX_MemToReg      (EX_MemToReg     ),
        .EX_funct3        (EX_funct3       ),
        .EX_cache_hit     (EX_cache_ready0 ),
        .EX_cache_data    (EX_cache_probe_load_data),
        .clk              (clk             ),
        .rst              (rst             ),
        .en               (~EX_any_busy),
        .Flush_EX_MEM     (Flush_EX_MEM    ),
        .MEM_pcadd4       (MEM_pcadd4      ),
        .MEM_alu_result   (MEM_alu_result  ),
        .MEM_perip_addr   (MEM_perip_addr  ),
        .MEM_perip_bus_addr(MEM_perip_bus_addr),
        .MEM_rR2_data     (MEM_rR2_data    ),
        .MEM_imm           (MEM_imm        ),
        .MEM_csr_wb       (MEM_csr_wb      ),
        .MEM_forward_data (MEM_forward_data),
        .MEM_rd           (MEM_rd          ),
        .MEM_rd_oh        (MEM_rd_oh       ),
        .MEM_RegWrite     (MEM_RegWrite    ),
        .MEM_MemWrite     (MEM_MemWrite    ),
        .MEM_MemRead      (MEM_MemRead     ),
        .MEM_MemToReg     (MEM_MemToReg    ),
        .MEM_funct3       (MEM_funct3      ),
        .MEM_cache_hit    (MEM_early_cache_hit0),
        .MEM_cache_data   (MEM_early_cache_data0)
    );

    mycpu_ex_mem_reg #(DATAWIDTH, ADDR_WIDTH) u_ex_mem_reg_s1 (
        .EX_pc            (EX_S1_pc        ),
        .EX_alu_result    (EX_S1_alu_result),
        .EX_mem_addr      (EX_S1_mem_addr  ),
        .EX_forward_B_out (EX_S1_forward_B_out),
        .EX_imm           (EX_S1_imm       ),
        .EX_csr_wb        (EX_S1_csr_wb    ),
        .EX_rd            (EX_S1_rd        ),
        .EX_RegWrite      (EX_S1_RegWrite  ),
        .EX_MemWrite      (EX_S1_MemWrite  ),
        .EX_MemRead       (EX_S1_MemRead   ),
        .EX_MemToReg      (EX_S1_MemToReg  ),
        .EX_funct3        (EX_S1_funct3    ),
        .EX_cache_hit     (EX_cache_ready1 ),
        .EX_cache_data    (EX_cache_probe_load_data),
        .clk              (clk             ),
        .rst              (rst             ),
        .en               (~EX_any_busy    ),
        .Flush_EX_MEM     (Flush_EX_MEM    ),
        .MEM_pcadd4       (MEM_S1_pcadd4   ),
        .MEM_alu_result   (MEM_S1_alu_result),
        .MEM_perip_addr   (MEM_S1_perip_addr),
        .MEM_perip_bus_addr(MEM_S1_perip_bus_addr),
        .MEM_rR2_data     (MEM_S1_rR2_data ),
        .MEM_imm          (MEM_S1_imm      ),
        .MEM_csr_wb       (MEM_S1_csr_wb   ),
        .MEM_forward_data (MEM_S1_forward_data),
        .MEM_rd           (MEM_S1_rd       ),
        .MEM_rd_oh        (MEM_S1_rd_oh    ),
        .MEM_RegWrite     (MEM_S1_RegWrite ),
        .MEM_MemWrite     (MEM_S1_MemWrite ),
        .MEM_MemRead      (MEM_S1_MemRead  ),
        .MEM_MemToReg     (MEM_S1_MemToReg ),
        .MEM_funct3       (MEM_S1_funct3   ),
        .MEM_cache_hit    (MEM_early_cache_hit1),
        .MEM_cache_data   (MEM_early_cache_data1)
    );

    // =========================================================================
    // STAGE 4：MEM1（发起访存）
    //   BRAM load 在 MEM1 发起同步读，MEM2 对齐返回数据和写回元数据。
    //   所有外部访存地址均来自 EX/MEM 锁存后的 MEM_perip_addr，切断 EX 级长路径。
    // =========================================================================
    mycpu_mem_stage #(DATAWIDTH) u_mem_stage (
        .perip_rdata      (perip_rdata     ),
        .MEM_perip_addr   (MEM_use_s1_bus ? MEM_S1_perip_bus_addr : MEM_perip_bus_addr),
        .MEM_rR2_data     (MEM_use_s1_bus ? MEM_S1_rR2_data : MEM_rR2_data),
        .MEM_funct3       (MEM_use_s1_bus ? MEM_S1_funct3 : MEM_funct3),
        .MEM_MemWrite     (MEM_use_s1_bus ? MEM_S1_MemWrite : MEM_MemWrite),
        .perip_addr       (MEM_bus_addr    ),
        .perip_wdata      (MEM_bus_wdata   ),
        .MEM_mdata        (MEM_mdata       ),
        .perip_wen        (MEM_bus_wen     ),
        .perip_mask       (MEM_bus_mask    )
    );

    assign perip_wen   = MEM_bus_wen;
    assign perip_wdata = MEM_bus_wdata;
    assign MEM_bram_load = (MEM_MemRead && MEM_bram_access) ||
                           (MEM_S1_MemRead && MEM_S1_bram_access);
    // BRAM load 始终读取完整字；store 与 MMIO 保持原 mask 语义。
    assign perip_mask  = MEM_bram_load ? 2'b10 : MEM_bus_mask;
    assign perip_addr  = (MEM_MemWrite || MEM_MemRead ||
                          MEM_S1_MemWrite || MEM_S1_MemRead) ? MEM_bus_addr : 32'b0;

    // 64 项 BRAM load 结果缓存。外部访问保持不变；EX 提前探测命中时允许
    // 下一拍从 MEM1 前递，miss 仍沿原 BRAM→WB 路径返回。
    load_l0_cache #(.INDEX_WIDTH(6)) u_load_l0_cache (
        .clk          (clk),
        .rst          (rst),
        .lookup_addr  (MEM_use_s1_bus ? MEM_S1_perip_bus_addr : MEM_perip_bus_addr),
        .lookup_hit   (MEM_cache_hit),
        .lookup_data  (MEM_cache_data),
        .probe_addr   (EX_cache_probe_addr),
        .probe_hit    (EX_cache_probe_hit),
        .probe_data   (EX_cache_probe_data),
        .fill_en      (MEM_cache_fill_en),
        .fill_addr    (MEM_cache_fill_addr),
        .fill_data    (perip_rdata),
        .store_en     (MEM_bus_wen && is_bram_addr(MEM_bus_addr)),
        .store_addr   (MEM_bus_addr)
    );

    assign MEM_cache_fill_en = (MEM2_MemRead && MEM2_bram_access) ||
                               (MEM2_S1_MemRead && MEM2_S1_bram_access);
    assign MEM_cache_fill_addr = MEM2_MemRead ? MEM2_alu_result :
                                                   MEM2_S1_alu_result;

    // EX 提前读取完整缓存字，并随 load 一起打入 EX/MEM。下一拍消费者仅
    // 前递寄存后的数据，避免 MEM 异步 L0 读取直接串入 EX ALU。
    // 提前探测只使用 ID/EX 已寄存的基址。需要任意 EX 前递的 load 不能走
    // 零气泡路径，否则会形成 MEM2/WB -> ALU -> L0 -> hazard 的长组合链。
    assign EX_cache_probe_addr0 = EX_rR1_data + EX_imm;
    assign EX_cache_probe_addr1 = EX_S1_rR1_data + EX_S1_imm;
    assign EX_cache_probe_addr = EX_MemRead ? EX_cache_probe_addr0 :
                                 EX_S1_MemRead ? EX_cache_probe_addr1 : 32'b0;
    assign EX_cache_probe_raw = select_load_raw(
        EX_cache_probe_data,
        EX_MemRead ? EX_funct3 : EX_S1_funct3,
        EX_cache_probe_addr[1:0]
    );
    load_mask #(DATAWIDTH) u_ex_cache_load_mask (
        .mask  (EX_MemRead ? EX_funct3 : EX_S1_funct3),
        .dout  (EX_cache_probe_raw),
        .mdata (EX_cache_probe_load_data)
    );

    // 提前探测 EX load。若同拍有更老的同地址 store，则必须按 miss 处理，
    // 避免消费者前递到 store 之前的旧缓存数据。
    assign EX_cache_ready0 = EX_MemRead && (ForwardA == 3'd0) &&
                             is_bram_addr(EX_cache_probe_addr0) &&
                             EX_cache_probe_hit &&
                             !(MEM_cache_fill_en &&
                               (MEM_cache_fill_addr[7:2] == EX_cache_probe_addr0[7:2]) &&
                               (MEM_cache_fill_addr[17:2] != EX_cache_probe_addr0[17:2])) &&
                             !(MEM_bus_wen && is_bram_addr(MEM_bus_addr) &&
                               (MEM_bus_addr[17:2] == EX_cache_probe_addr0[17:2]));
    assign EX_cache_ready1 = EX_S1_MemRead && (ForwardA_S1 == 3'd0) &&
                             is_bram_addr(EX_cache_probe_addr1) &&
                             EX_cache_probe_hit &&
                             !(MEM_cache_fill_en &&
                               (MEM_cache_fill_addr[7:2] == EX_cache_probe_addr1[7:2]) &&
                               (MEM_cache_fill_addr[17:2] != EX_cache_probe_addr1[17:2])) &&
                             !(MEM_bus_wen && is_bram_addr(MEM_bus_addr) &&
                               (MEM_bus_addr[17:2] == EX_cache_probe_addr1[17:2]));

    // 零气泡 load 的前递值来自 EX/MEM 中的寄存副本。
    assign MEM_forward_data_effective = MEM_early_cache_hit0 ? MEM_early_cache_data0 :
                                                            MEM_forward_data;
    assign MEM_S1_forward_data_effective = MEM_early_cache_hit1 ? MEM_early_cache_data1 :
                                                               MEM_S1_forward_data;

    logic [31:0] MEM_cache_raw0, MEM_cache_raw1;
    logic [31:0] MEM_cache_load_data0, MEM_cache_load_data1;
    assign MEM_cache_raw0 = select_load_raw(MEM_cache_data, MEM_funct3,
                                             MEM_perip_bus_addr[1:0]);
    assign MEM_cache_raw1 = select_load_raw(MEM_cache_data, MEM_S1_funct3,
                                             MEM_S1_perip_bus_addr[1:0]);
    load_mask #(DATAWIDTH) u_mem_cache_load_mask (
        .mask(MEM_funct3), .dout(MEM_cache_raw0), .mdata(MEM_cache_load_data0)
    );
    load_mask #(DATAWIDTH) u_mem_cache_load_mask_s1 (
        .mask(MEM_S1_funct3), .dout(MEM_cache_raw1), .mdata(MEM_cache_load_data1)
    );

    // cache hit 与最终前递值在 MEM1/MEM2 边界锁存，避免下一拍的
    // MemToReg/cache/load-mask 选择继续串入 EX ALU。
    always_ff @(posedge clk) begin
        if (rst) begin
            MEM2_cache_hit       <= 1'b0;
            MEM2_S1_cache_hit    <= 1'b0;
            MEM2_forward_data    <= 32'b0;
            MEM2_S1_forward_data <= 32'b0;
        end else begin
            MEM2_cache_hit       <= MEM_cache_hit0;
            MEM2_S1_cache_hit    <= MEM_cache_hit1;
            MEM2_forward_data    <= MEM_cache_hit0 ? MEM_cache_load_data0 :
                                                        MEM_forward_data;
            MEM2_S1_forward_data <= MEM_cache_hit1 ? MEM_cache_load_data1 :
                                                        MEM_S1_forward_data;
        end
    end

    // ---- MEM1/MEM2 流水寄存器 ----
    mycpu_mem1_mem2_reg #(DATAWIDTH, ADDR_WIDTH) u_mem1_mem2_reg (
        .MEM_pcadd4       (MEM_pcadd4      ),
        .MEM_alu_result   (MEM_alu_result  ),
        .MEM_mdata        (MEM_mdata       ),
        .MEM_imm          (MEM_imm         ),
        .MEM_csr_wb       (MEM_csr_wb      ),
        .MEM_rd           (MEM_rd          ),
        .MEM_rd_oh        (MEM_rd_oh       ),
        .MEM_RegWrite     (MEM_RegWrite    ),
        .MEM_MemRead      (MEM_MemRead     ),
        .MEM_MemToReg     (MEM_MemToReg    ),
        .MEM_funct3       (MEM_funct3      ),
        .MEM_bram_access  (MEM_bram_access ),
        .clk              (clk             ),
        .rst              (rst             ),
        .MEM2_pcadd4      (MEM2_pcadd4     ),
        .MEM2_alu_result  (MEM2_alu_result ),
        .MEM2_mmio_mdata  (MEM2_mmio_mdata ),
        .MEM2_imm         (MEM2_imm        ),
        .MEM2_csr_wb      (MEM2_csr_wb     ),
        .MEM2_rd          (MEM2_rd         ),
        .MEM2_rd_oh       (MEM2_rd_oh      ),
        .MEM2_RegWrite    (MEM2_RegWrite   ),
        .MEM2_MemRead     (MEM2_MemRead    ),
        .MEM2_MemToReg    (MEM2_MemToReg   ),
        .MEM2_funct3      (MEM2_funct3     ),
        .MEM2_bram_access (MEM2_bram_access)
    );

    mycpu_mem1_mem2_reg #(DATAWIDTH, ADDR_WIDTH) u_mem1_mem2_reg_s1 (
        .MEM_pcadd4       (MEM_S1_pcadd4      ),
        .MEM_alu_result   (MEM_S1_alu_result  ),
        .MEM_mdata        (MEM_mdata          ),
        .MEM_imm          (MEM_S1_imm         ),
        .MEM_csr_wb       (MEM_S1_csr_wb      ),
        .MEM_rd           (MEM_S1_rd          ),
        .MEM_rd_oh        (MEM_S1_rd_oh       ),
        .MEM_RegWrite     (MEM_S1_RegWrite    ),
        .MEM_MemRead      (MEM_S1_MemRead     ),
        .MEM_MemToReg     (MEM_S1_MemToReg    ),
        .MEM_funct3       (MEM_S1_funct3      ),
        .MEM_bram_access  (MEM_S1_bram_access ),
        .clk              (clk                ),
        .rst              (rst                ),
        .MEM2_pcadd4      (MEM2_S1_pcadd4     ),
        .MEM2_alu_result  (MEM2_S1_alu_result ),
        .MEM2_mmio_mdata  (MEM2_S1_mmio_mdata ),
        .MEM2_imm         (MEM2_S1_imm        ),
        .MEM2_csr_wb      (MEM2_S1_csr_wb     ),
        .MEM2_rd          (MEM2_S1_rd         ),
        .MEM2_rd_oh       (MEM2_S1_rd_oh      ),
        .MEM2_RegWrite    (MEM2_S1_RegWrite   ),
        .MEM2_MemRead     (MEM2_S1_MemRead    ),
        .MEM2_MemToReg    (MEM2_S1_MemToReg   ),
        .MEM2_funct3      (MEM2_S1_funct3     ),
        .MEM2_bram_access (MEM2_S1_bram_access)
    );

    assign MEM2_mdata = (MEM2_MemRead && MEM2_bram_access) ?
                        select_load_raw(perip_rdata, MEM2_funct3,
                                        MEM2_alu_result[1:0]) : MEM2_mmio_mdata;
    assign MEM2_S1_mdata = (MEM2_S1_MemRead && MEM2_S1_bram_access) ?
                           select_load_raw(perip_rdata, MEM2_S1_funct3,
                                           MEM2_S1_alu_result[1:0]) : MEM2_S1_mmio_mdata;

    // ---- MEM/WB 流水寄存器 ----
    mycpu_mem_wb_reg #(DATAWIDTH, ADDR_WIDTH) u_mem_wb_reg (
        .MEM_pcadd4     (MEM2_pcadd4     ),
        .MEM_alu_result (MEM2_alu_result ),
        .MEM_mdata      (MEM2_mdata      ),
        .MEM_imm        (MEM2_imm        ),
        .MEM_csr_wb     (MEM2_csr_wb     ),
        .MEM_rd         (MEM2_rd         ),
        .MEM_rd_oh      (MEM2_rd_oh      ),
        .MEM_RegWrite   (MEM2_RegWrite   ),
        .MEM_MemToReg   (MEM2_MemToReg   ),
        .MEM_funct3     (MEM2_funct3     ),
        .clk            (clk           ),
        .rst            (rst           ),
        .Flush_MEM_WB   (1'b0          ),
        .WB_pcadd4      (WB_pcadd4     ),
        .WB_alu_result  (WB_alu_result ),
        .WB_mdata       (WB_mdata      ),
        .WB_imm         (WB_imm        ),
        .WB_csr_wb      (WB_csr_wb     ),
        .WB_rd          (WB_rd         ),
        .WB_rd_oh       (WB_rd_oh      ),
        .WB_RegWrite    (WB_RegWrite   ),
        .WB_MemToReg    (WB_MemToReg   ),
        .WB_funct3      (WB_funct3     )
    );

    mycpu_mem_wb_reg #(DATAWIDTH, ADDR_WIDTH) u_mem_wb_reg_s1 (
        .MEM_pcadd4     (MEM2_S1_pcadd4     ),
        .MEM_alu_result (MEM2_S1_alu_result ),
        .MEM_mdata      (MEM2_S1_mdata      ),
        .MEM_imm        (MEM2_S1_imm        ),
        .MEM_csr_wb     (MEM2_S1_csr_wb     ),
        .MEM_rd         (MEM2_S1_rd         ),
        .MEM_rd_oh      (MEM2_S1_rd_oh      ),
        .MEM_RegWrite   (MEM2_S1_RegWrite   ),
        .MEM_MemToReg   (MEM2_S1_MemToReg   ),
        .MEM_funct3     (MEM2_S1_funct3     ),
        .clk            (clk                ),
        .rst            (rst                ),
        .Flush_MEM_WB   (1'b0               ),
        .WB_pcadd4      (WB_S1_pcadd4       ),
        .WB_alu_result  (WB_S1_alu_result   ),
        .WB_mdata       (WB_S1_mdata        ),
        .WB_imm         (WB_S1_imm          ),
        .WB_csr_wb      (WB_S1_csr_wb       ),
        .WB_rd          (WB_S1_rd           ),
        .WB_rd_oh       (WB_S1_rd_oh        ),
        .WB_RegWrite    (WB_S1_RegWrite     ),
        .WB_MemToReg    (WB_S1_MemToReg     ),
        .WB_funct3      (WB_S1_funct3       )
    );

    // =========================================================================
    // STAGE 5：WB（写回）
    //   5 路 MemToReg 选择；输出直接接到 reg_file 写口与 forwarding_unit 的候选源
    // =========================================================================
    mycpu_wb_stage #(DATAWIDTH) u_wb_stage (
        .WB_pcadd4     (WB_pcadd4    ),
        .WB_alu_result (WB_alu_result),
        .WB_mdata      (WB_mdata     ),
        .WB_imm        (WB_imm       ),
        .WB_csr_wb     (WB_csr_wb    ),
        .WB_MemToReg   (WB_MemToReg  ),
        .WB_funct3     (WB_funct3    ),
        .WB_wdata      (WB_wdata     )
    );

    mycpu_wb_stage #(DATAWIDTH) u_wb_stage_s1 (
        .WB_pcadd4     (WB_S1_pcadd4    ),
        .WB_alu_result (WB_S1_alu_result),
        .WB_mdata      (WB_S1_mdata     ),
        .WB_imm        (WB_S1_imm       ),
        .WB_csr_wb     (WB_S1_csr_wb    ),
        .WB_MemToReg   (WB_S1_MemToReg  ),
        .WB_funct3     (WB_S1_funct3    ),
        .WB_wdata      (WB_S1_wdata     )
    );

endmodule
