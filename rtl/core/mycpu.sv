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
    logic        Stall_Hazard, Stall_LateSubword, EX_busy, EX_any_busy;
    logic        Stall_Front, Flush_ID_EX_comb;
    logic        Flush_EX_MEM;
    logic [2:0]  ID_ForwardA, ID_ForwardB, ID_ForwardA_S1, ID_ForwardB_S1;
    logic [2:0]  ForwardA, ForwardB, ForwardA_S1, ForwardB_S1;
    logic [31:0] ForwardAData, ForwardBData, ForwardAData_S1, ForwardBData_S1;
    logic        BranchTaken, BranchTaken_raw;
`ifndef SYNTHESIS
    logic        BranchTaken_stat_q, BranchTaken_stat_pending_q;
`endif
    logic        BranchMispredict, BranchMispredict_raw;
    logic [31:0] IF_npc_redirect_raw;
    logic        redirect_valid_q, redirect_taken_q, redirect_bp_update_q;
    logic        redirect_bp_is_jal_q;
    logic [31:0] redirect_target_q, redirect_bp_pc_q, redirect_bp_target_q;
    logic        BP_update_en, BP_update_taken;
    logic        MEM_bram_access, MEM_S1_bram_access, MEM_use_s1_bus;
    logic [31:0] MEM_bus_addr, MEM_bus_wdata;
    logic        MEM_bus_wen;
    logic [1:0]  MEM_bus_mask;
    logic        MEM_store_valid;
    logic [31:0] MEM_store_addr, MEM_store_data;
    logic        MEM_bram_load;
    logic        EX_cache_probe_hit, EX_cache_ready0, EX_cache_ready1;
    logic [31:0] EX_cache_probe_addr, EX_cache_probe_addr0, EX_cache_probe_addr1;
    logic [31:0] EX_cache_probe_data, EX_cache_probe_raw, EX_cache_probe_load_data;
    logic        MEM_cache_fill_en;
    logic [31:0] MEM_cache_fill_addr;
    logic        MEM_cache_fill_q_en;
    logic [31:0] MEM_cache_fill_q_addr, MEM_cache_fill_q_data;
    logic [31:0] MEM_cache_lookup_addr;
    logic        MEM_cache_hit_raw, EX_cache_probe_hit_raw;
    logic [31:0] MEM_cache_data_raw, EX_cache_probe_data_raw;
    logic [3:0]  store_bypass_byte_valid_q [0:7];
    logic [12:0] store_bypass_tag_q [0:7];
    logic [31:0] store_bypass_data_q [0:7];
    logic        EX_store_bypass_hit;
    logic [31:0] MEM_store_bypass_data;
    logic [2:0]  MEM_store_funct3;
    logic [3:0]  MEM_store_byte_mask, MEM_load_byte_mask, EX_load_byte_mask;
    logic [31:0] MEM_store_aligned_data;
    logic        LoadUseEX, LoadUseMEM, LoadUseMEM_base;

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

    function automatic logic [3:0] access_byte_mask(
        input logic [2:0] funct3,
        input logic [1:0] offset
    );
        begin
            case (funct3[1:0])
                2'b00: access_byte_mask = 4'b0001 << offset;
                2'b01: access_byte_mask = offset[1] ? 4'b1100 : 4'b0011;
                default: access_byte_mask = 4'b1111;
            endcase
        end
    endfunction

    function automatic logic [31:0] align_store_data(
        input logic [31:0] data,
        input logic [2:0]  funct3,
        input logic [1:0]  offset
    );
        begin
            case (funct3[1:0])
                2'b00: align_store_data = {24'b0, data[7:0]}
                                                << {offset, 3'b000};
                2'b01: align_store_data = offset[1] ? {data[15:0], 16'b0} :
                                                      {16'b0, data[15:0]};
                default: align_store_data = data;
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
    logic [31:0] ID_imm, ID_rR1_data, ID_rR2_data, ID_mem_addr_early;
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
    logic [31:0] ID_S1_imm, ID_S1_rR1_data, ID_S1_rR2_data, ID_S1_mem_addr_early;
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
    logic [31:0] EX_pc, EX_imm, EX_rR1_data, EX_rR2_data, EX_mem_addr_early;
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
    logic        EX_pipe_valid, EX_S1_pipe_valid;
    logic        EX_RegWrite_eff, EX_MemWrite_eff, EX_MemRead_eff;
    logic        EX_S1_RegWrite_eff, EX_S1_MemWrite_eff, EX_S1_MemRead_eff;
    logic [`ALU_OP_WIDTH - 1:0] EX_ALUControl_eff, EX_S1_ALUControl_eff;
    logic [1:0]  EX_NpcOp_eff;
    logic [5:0]  EX_CSRControll_eff;
    logic [31:0] EX_pred_target;
    logic [31:0] EX_S1_pc, EX_S1_imm, EX_S1_rR1_data, EX_S1_rR2_data;
    logic [31:0] EX_S1_mem_addr_early;
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

    assign EX_RegWrite_eff = EX_pipe_valid && EX_RegWrite;
    assign EX_MemWrite_eff = EX_pipe_valid && EX_MemWrite;
    assign EX_MemRead_eff  = EX_pipe_valid && EX_MemRead;
    assign EX_S1_RegWrite_eff = EX_S1_pipe_valid && EX_S1_RegWrite;
    assign EX_S1_MemWrite_eff = EX_S1_pipe_valid && EX_S1_MemWrite;
    assign EX_S1_MemRead_eff  = EX_S1_pipe_valid && EX_S1_MemRead;
    assign EX_ALUControl_eff = EX_pipe_valid ? EX_ALUControl : '0;
    assign EX_S1_ALUControl_eff = EX_S1_pipe_valid ? EX_S1_ALUControl : '0;
    assign EX_NpcOp_eff = EX_pipe_valid ? EX_NpcOp : 2'b0;
    assign EX_CSRControll_eff = EX_pipe_valid ? EX_CSRControll : 6'b0;

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
    logic        MEM_load_ready0, MEM_load_ready1, MEM_store_bypass_hit;
    logic        MEM_lookup_ready0, MEM_lookup_ready1;
    logic [31:0] MEM_load_ready_word;
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
    logic        WB_bram_access, WB_S1_bram_access;
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

    // 消费者本地 late operand：ID 看到生产者位于 MEM2 时，把对应值和
    // 唯一 load 的原始字随消费者锁存到 ID/EX。下一拍不再跨区域读取 WB。
    logic        MEM2_load_slot1;
    logic        MEM2_late_word0, MEM2_late_word1;
    logic        MEM2_subword_miss0, MEM2_subword_miss1;
    logic        ID_dep_mem2_0, ID_dep_mem2_1;
    logic [31:0] ID_late_load_word;
    logic [31:0] ID_late_data1, ID_late_data2;
    logic [31:0] ID_S1_late_data1, ID_S1_late_data2;

    logic [31:0] EX_late_data1, EX_late_data2, EX_late_load_word;
    logic [31:0] EX_S1_late_data1, EX_S1_late_data2, EX_S1_late_load_word;

    // 当前 ID 消费者进入 EX 时，各生产者也恰好前进一级。前递来源选择在
    // ID 提前完成并随消费者打拍，从 EX 数据路径移除 rd 比较和优先级链。
    function automatic logic [2:0] select_id_forward(input logic [4:0] rs);
        begin
            if (rs == 5'd0) begin
                select_id_forward = 3'd0;
            end else if (EX_S1_RegWrite_eff && (EX_S1_rd == rs)) begin
                select_id_forward = 3'd5;
            end else if (EX_RegWrite_eff && (EX_rd == rs)) begin
                select_id_forward = 3'd2;
            end else if (MEM_S1_RegWrite && (MEM_S1_rd == rs)) begin
                select_id_forward = 3'd6;
            end else if (MEM_RegWrite && (MEM_rd == rs)) begin
                select_id_forward = 3'd3;
            end else if (MEM2_S1_RegWrite && (MEM2_S1_rd == rs)) begin
                select_id_forward = MEM2_late_word1 ? 3'd7 : 3'd4;
            end else if (MEM2_RegWrite && (MEM2_rd == rs)) begin
                select_id_forward = MEM2_late_word0 ? 3'd7 : 3'd1;
            end else begin
                select_id_forward = 3'd0;
            end
        end
    endfunction

    assign MEM2_load_slot1 = MEM2_S1_RegWrite &&
                             (MEM2_S1_MemToReg == 3'b010);
    assign MEM2_late_word0 = MEM2_RegWrite &&
                             (MEM2_MemToReg == 3'b010) && !MEM2_cache_hit &&
                             (MEM2_funct3 == 3'b010);
    assign MEM2_late_word1 = MEM2_S1_RegWrite &&
                             (MEM2_S1_MemToReg == 3'b010) && !MEM2_S1_cache_hit &&
                             (MEM2_S1_funct3 == 3'b010);

    assign ID_late_load_word = MEM2_load_slot1 ? MEM2_S1_mdata : MEM2_mdata;

    // MEM2_forward_data 已包含非 load 写回值和 L0 命中时的已格式化
    // load 值。只有 L0 miss 才需要另外处理同步 BRAM 的晚到返回。
    assign ID_late_data1 = (ID_ForwardA == 3'd4) ? MEM2_S1_forward_data :
                                                   MEM2_forward_data;
    assign ID_late_data2 = (ID_ForwardB == 3'd4) ? MEM2_S1_forward_data :
                                                   MEM2_forward_data;
    assign ID_S1_late_data1 = (ID_ForwardA_S1 == 3'd4) ? MEM2_S1_forward_data :
                                                         MEM2_forward_data;
    assign ID_S1_late_data2 = (ID_ForwardB_S1 == 3'd4) ? MEM2_S1_forward_data :
                                                         MEM2_forward_data;

    // 3'd7 直接表示 miss lw 原始字，将原先独立的 late-load 二选一
    // 合并到通用前递 mux；subword miss 仍由下方的一拍停顿处理。

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

    // L0 miss 的 byte/half load 不走晚到数据快速路径。若当前 ID 包依赖
    // MEM2 中的这类 load，多停一拍等它进入 WB；无依赖和 L0 命中均不停。
    assign MEM2_subword_miss0 = MEM2_RegWrite && MEM2_MemRead &&
                                !MEM2_cache_hit && (MEM2_rd != 5'd0) &&
                                (MEM2_funct3 != 3'b010);
    assign MEM2_subword_miss1 = MEM2_S1_RegWrite && MEM2_S1_MemRead &&
                                !MEM2_S1_cache_hit && (MEM2_S1_rd != 5'd0) &&
                                (MEM2_S1_funct3 != 3'b010);
    assign ID_dep_mem2_0 = (ID_uses_rs1 && (ID_rs1 == MEM2_rd)) ||
                           (ID_uses_rs2 && (ID_rs2 == MEM2_rd)) ||
                           (ID_S1_uses_rs1 && (ID_S1_rs1 == MEM2_rd)) ||
                           (ID_S1_uses_rs2 && (ID_S1_rs2 == MEM2_rd));
    assign ID_dep_mem2_1 = (ID_uses_rs1 && (ID_rs1 == MEM2_S1_rd)) ||
                           (ID_uses_rs2 && (ID_rs2 == MEM2_S1_rd)) ||
                           (ID_S1_uses_rs1 && (ID_S1_rs1 == MEM2_S1_rd)) ||
                           (ID_S1_uses_rs2 && (ID_S1_rs2 == MEM2_S1_rd));
    assign Stall_LateSubword = (MEM2_subword_miss0 && ID_dep_mem2_0) ||
                               (MEM2_subword_miss1 && ID_dep_mem2_1);

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
        .ID_EX_MemRead (EX_MemRead_eff ),
        .ID_EX_LoadReady(EX_cache_ready0),
        .ID_EX_rd_1    (EX_S1_rd       ),
        .ID_EX_MemRead_1(EX_S1_MemRead_eff),
        .ID_EX_LoadReady_1(EX_cache_ready1),
        .EX_MEM_rd     (MEM_rd         ),
        .EX_MEM_MemRead(MEM_MemRead    ),
        .EX_MEM_LoadReady(MEM_load_ready0),
        .EX_MEM_rd_1   (MEM_S1_rd      ),
        .EX_MEM_MemRead_1(MEM_S1_MemRead),
        .EX_MEM_LoadReady_1(MEM_load_ready1),
        .BranchMispredict (BranchMispredict),
        .Stall         (Stall_Hazard   ),
        .Flush_IF_ID   (Flush_IF_ID    ),
        .Flush_ID_EX   (Flush_ID_EX    ),
        .LoadUseEX     (LoadUseEX      ),
        .LoadUseMEM    (LoadUseMEM_base)
    );

    assign LoadUseMEM = LoadUseMEM_base | Stall_LateSubword;

    assign MEM_bram_access    = is_bram_addr(MEM_perip_addr);
    assign MEM_S1_bram_access = is_bram_addr(MEM_S1_perip_addr);
    assign MEM_use_s1_bus     = !(MEM_MemWrite || MEM_MemRead) &&
                                (MEM_S1_MemWrite || MEM_S1_MemRead);
    assign MEM_store_addr     = MEM_MemWrite ? MEM_perip_bus_addr :
                                               MEM_S1_perip_bus_addr;
    assign MEM_store_data     = MEM_MemWrite ? MEM_rR2_data : MEM_S1_rR2_data;
    assign MEM_store_funct3   = MEM_MemWrite ? MEM_funct3 : MEM_S1_funct3;
    assign MEM_store_valid    = ((MEM_MemWrite && MEM_bram_access) ||
                                 (MEM_S1_MemWrite && MEM_S1_bram_access));
    assign MEM_cache_hit0 = MEM_MemRead && MEM_bram_access && MEM_cache_hit;
    assign MEM_cache_hit1 = MEM_S1_MemRead && MEM_S1_bram_access && MEM_cache_hit;
    assign MEM_store_byte_mask = access_byte_mask(MEM_store_funct3,
                                                   MEM_store_addr[1:0]);
    assign MEM_store_aligned_data = align_store_data(MEM_store_data,
                                                      MEM_store_funct3,
                                                      MEM_store_addr[1:0]);
    assign MEM_load_byte_mask = access_byte_mask(
        MEM_S1_MemRead ? MEM_S1_funct3 : MEM_funct3,
        MEM_cache_lookup_addr[1:0]
    );
    assign EX_load_byte_mask = access_byte_mask(
        EX_MemRead_eff ? EX_funct3 : EX_S1_funct3,
        EX_cache_probe_addr[1:0]
    );
    assign MEM_store_bypass_hit =
        (store_bypass_tag_q[MEM_cache_lookup_addr[4:2]] ==
         MEM_cache_lookup_addr[17:5]) &&
        ((store_bypass_byte_valid_q[MEM_cache_lookup_addr[4:2]] &
          MEM_load_byte_mask) == MEM_load_byte_mask);
    assign MEM_store_bypass_data =
        store_bypass_data_q[MEM_cache_lookup_addr[4:2]];
    assign MEM_lookup_ready0 = MEM_MemRead && MEM_bram_access &&
                               (MEM_cache_hit || MEM_store_bypass_hit);
    assign MEM_lookup_ready1 = MEM_S1_MemRead && MEM_S1_bram_access &&
                               (MEM_cache_hit || MEM_store_bypass_hit);
    // hazard 已单独检查 MEM_MemRead；LoadReady 只需保留地址范围和命中，
    // 避免同一 MemRead 控制重复串入 L0 返回路径。
    assign MEM_load_ready0 = MEM_early_cache_hit0 ||
                             (MEM_bram_access &&
                              (MEM_cache_hit || MEM_store_bypass_hit));
    assign MEM_load_ready1 = MEM_early_cache_hit1 ||
                             (MEM_S1_bram_access &&
                              (MEM_cache_hit || MEM_store_bypass_hit));
    assign Flush_EX_MEM       = redirect_valid_q;

    // redirect/flush 打拍提交：
    //   EX 级只组合计算 raw redirect；这里寄存后再驱动 IF 重定向和流水 flush，
    //   切断 ALU/branch compare -> Flush_ID_EX 的运行期长路径。
    //
    // redirect 优先级（从高到低）：
    //   1) redirect_valid_q 有效且前段不暂停 → 消费完毕，清 0
    //   2) BranchMispredict_raw 新来了分支误预测 → 直接设置 valid
    // 预测器更新与误预测结果解耦：branch/jal 在 EX 完成就训练。
    always_ff @(posedge clk) begin
        if (rst) begin
            redirect_valid_q     <= 1'b0;
            redirect_target_q    <= '0;
            redirect_taken_q     <= 1'b0;
            redirect_bp_update_q <= 1'b0;
            redirect_bp_pc_q     <= '0;
            redirect_bp_target_q <= '0;
            redirect_bp_is_jal_q <= 1'b0;
        end else begin
            // 预测器训练不依赖误预测结果。branch/jal 使用固定 PC 相对目标；
            // 普通 jalr 使用本次实际目标，后续目标变化仍由 EX 比较纠正。
            redirect_bp_update_q <= !redirect_valid_q &&
                                    ((EX_NpcOp_eff == 2'b01) ||
                                     (EX_NpcOp_eff == 2'b11) ||
                                     ((EX_NpcOp_eff == 2'b10) &&
                                      (EX_OffsetOrigin == 2'b01)));
            // 记录分支 PC，用于更新预测器历史表
            redirect_bp_pc_q     <= EX_pc;
            // branch/jal 的预测目标始终是 PC+imm；分支本次不跳转时
            // IF_npc_redirect_raw 是 PC+4，不能用来训练后续 taken 目标。
            redirect_bp_target_q <= ((EX_NpcOp_eff == 2'b10) &&
                                     (EX_OffsetOrigin == 2'b01)) ?
                                    IF_npc_redirect_raw : EX_pc + EX_imm;
            redirect_bp_is_jal_q <= (EX_NpcOp_eff == 2'b11) ||
                                    ((EX_NpcOp_eff == 2'b10) &&
                                     (EX_OffsetOrigin == 2'b01));

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
            end
        end
    end

    assign IF_npc_redirect = redirect_target_q;

    // 前半段统一停顿条件：
    //   1) 原有 load-use 冒险
    //   2) 任一 EX 槽正在执行多周期 RV32M，前面的指令不能继续往前推，否则会覆盖 EX
    //   BRAM load 通过 MEM1/MEM2 后端流水返回，不再冻结整条前段流水。
    assign EX_any_busy     = EX_busy | EX_busy_S1;
    assign Stall_Front     = Stall_Hazard | Stall_LateSubword | EX_any_busy;
    // EX 忙时不能再往 ID/EX 注入 bubble，否则会把正在执行的 M 指令冲掉。
    assign Flush_ID_EX_comb = redirect_valid_q ? 1'b1 :
                               ((Flush_ID_EX | Stall_LateSubword) & ~EX_any_busy);
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
        .ID_EX_data1     (EX_rR1_data ),
        .ID_EX_data2     (EX_rR2_data ),
        .EX_MEM_data0    (MEM_forward_data_effective),
        .EX_MEM_data1    (MEM_S1_forward_data_effective),
        .MEM2_data0      (MEM2_forward_data),
        .MEM2_data1      (MEM2_S1_forward_data),
        .LATE_data1      (EX_late_data1),
        .LATE_data2      (EX_late_data2),
        .LATE_load_word  (EX_late_load_word),
        .ForwardA_sel    (ForwardA    ),
        .ForwardB_sel    (ForwardB    ),
        .ForwardAData    (ForwardAData),
        .ForwardBData    (ForwardBData)
    );

    forwarding_unit u_forwarding_unit_s1 (
        .ID_EX_data1     (EX_S1_rR1_data),
        .ID_EX_data2     (EX_S1_rR2_data),
        .EX_MEM_data0    (MEM_forward_data_effective),
        .EX_MEM_data1    (MEM_S1_forward_data_effective),
        .MEM2_data0      (MEM2_forward_data),
        .MEM2_data1      (MEM2_S1_forward_data),
        .LATE_data1      (EX_S1_late_data1),
        .LATE_data2      (EX_S1_late_data2),
        .LATE_load_word  (EX_S1_late_load_word),
        .ForwardA_sel    (ForwardA_S1 ),
        .ForwardB_sel    (ForwardB_S1 ),
        .ForwardAData    (ForwardAData_S1),
        .ForwardBData    (ForwardBData_S1)
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
        .BP_update_target(redirect_bp_target_q),
        .BP_update_is_jal(redirect_bp_is_jal_q),
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

    assign ID_ForwardA    = select_id_forward(ID_rs1);
    assign ID_ForwardB    = select_id_forward(ID_rs2);
    assign ID_ForwardA_S1 = select_id_forward(ID_S1_rs1);
    assign ID_ForwardB_S1 = select_id_forward(ID_S1_rs2);

    // 零气泡 L0 探测只允许未使用 EX 前递的 load。此时 ID 读出的基址就是
    // EX 的实际基址，可把地址加法提前一拍并锁存，缩短 L0 hit 到 hazard 的路径。
    // 真正的访存地址仍由 EX ALU 计算，外部总线语义不变。
    assign ID_mem_addr_early    = ID_rR1_data + ID_imm;
    assign ID_S1_mem_addr_early = ID_S1_rR1_data + ID_S1_imm;

    // ---- ID/EX 流水寄存器 ----
    mycpu_id_ex_reg #(DATAWIDTH, ADDR_WIDTH) u_id_ex_reg (
        .ID_pc           (ID_pc          ),
        .ID_imm          (ID_imm         ),
        .ID_rR1_data     (ID_rR1_data    ),
        .ID_rR2_data     (ID_rR2_data    ),
        .ID_mem_addr_early(ID_mem_addr_early),
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
        .ID_ForwardA     (ID_ForwardA    ),
        .ID_ForwardB     (ID_ForwardB    ),
        .ID_late_data1   (ID_late_data1  ),
        .ID_late_data2   (ID_late_data2  ),
        .ID_late_load_word(ID_late_load_word),
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
        .EX_mem_addr_early(EX_mem_addr_early),
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
        .EX_ForwardA     (ForwardA       ),
        .EX_ForwardB     (ForwardB       ),
        .EX_late_data1   (EX_late_data1  ),
        .EX_late_data2   (EX_late_data2  ),
        .EX_late_load_word(EX_late_load_word),
        .EX_pred_taken   (EX_pred_taken  ),
        .EX_pred_target  (EX_pred_target ),
        .EX_pipe_valid   (EX_pipe_valid  )
    );

    mycpu_id_ex_reg #(DATAWIDTH, ADDR_WIDTH) u_id_ex_reg_s1 (
        .ID_pc           (ID_pc1         ),
        .ID_imm          (ID_S1_imm      ),
        .ID_rR1_data     (ID_S1_rR1_data ),
        .ID_rR2_data     (ID_S1_rR2_data ),
        .ID_mem_addr_early(ID_S1_mem_addr_early),
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
        .ID_ForwardA     (ID_ForwardA_S1 ),
        .ID_ForwardB     (ID_ForwardB_S1 ),
        .ID_late_data1   (ID_S1_late_data1),
        .ID_late_data2   (ID_S1_late_data2),
        .ID_late_load_word(ID_late_load_word),
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
        .EX_mem_addr_early(EX_S1_mem_addr_early),
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
        .EX_ForwardA     (ForwardA_S1    ),
        .EX_ForwardB     (ForwardB_S1    ),
        .EX_late_data1   (EX_S1_late_data1),
        .EX_late_data2   (EX_S1_late_data2),
        .EX_late_load_word(EX_S1_late_load_word),
        .EX_pred_taken   (EX_S1_pred_taken),
        .EX_pred_target  (EX_S1_pred_target),
        .EX_pipe_valid   (EX_S1_pipe_valid)
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
        .EX_ALUControl    (EX_ALUControl_eff),
        .EX_NpcOp         (EX_NpcOp_eff    ),
        .EX_OffsetOrigin  (EX_OffsetOrigin ),
        .EX_csr_idx       (EX_csr_idx      ),
        .EX_csr_zimm      (EX_csr_zimm     ),
        .EX_CSRControll   (EX_CSRControll_eff),
        .ForwardA         (ForwardA        ),
        .ForwardB         (ForwardB        ),
        .ForwardAData     (ForwardAData    ),
        .ForwardBData     (ForwardBData    ),
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
        .EX_ALUControl    (EX_S1_ALUControl_eff),
        // lane1 只接收 IF 级筛选后的普通整数/M/单访存指令，
        // 静态关闭不可达的控制流与 CSR 通路，便于综合删除冗余状态。
        .EX_NpcOp         (2'b00           ),
        .EX_OffsetOrigin  (2'b00           ),
        .EX_csr_idx       (12'b0           ),
        .EX_csr_zimm      (5'b0            ),
        .EX_CSRControll   (6'b0            ),
        .ForwardA         (ForwardA_S1     ),
        .ForwardB         (ForwardB_S1     ),
        .ForwardAData     (ForwardAData_S1 ),
        .ForwardBData     (ForwardBData_S1 ),
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
        .EX_RegWrite      (EX_RegWrite_eff ),
        .EX_MemWrite      (EX_MemWrite_eff ),
        .EX_MemRead       (EX_MemRead_eff  ),
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
        .EX_RegWrite      (EX_S1_RegWrite_eff),
        .EX_MemWrite      (EX_S1_MemWrite_eff),
        .EX_MemRead       (EX_S1_MemRead_eff),
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
    // L0 lookup 只服务 load；无需经过包含 store 的通用总线 lane 选择。
    assign MEM_cache_lookup_addr = MEM_S1_MemRead ? MEM_S1_perip_bus_addr :
                                                    MEM_perip_bus_addr;

    load_l0_cache #(.INDEX_WIDTH(6)) u_load_l0_cache (
        .clk          (clk),
        .rst          (rst),
        .lookup_addr  (MEM_cache_lookup_addr),
        .lookup_hit   (MEM_cache_hit_raw),
        .lookup_data  (MEM_cache_data_raw),
        .probe_addr   (EX_cache_probe_addr),
        .probe_hit    (EX_cache_probe_hit_raw),
        .probe_data   (EX_cache_probe_data_raw),
        .fill_en      (MEM_cache_fill_q_en),
        .fill_addr    (MEM_cache_fill_q_addr),
        .fill_data    (MEM_cache_fill_q_data),
        .store_en     (MEM_bus_wen && is_bram_addr(MEM_bus_addr)),
        .store_addr   (MEM_bus_addr)
    );

    assign MEM_cache_fill_en = (MEM2_MemRead && MEM2_bram_access) ||
                               (MEM2_S1_MemRead && MEM2_S1_bram_access);
    assign MEM_cache_fill_addr = MEM2_MemRead ? MEM2_alu_result :
                                                   MEM2_S1_alu_result;

    // BRAM 返回先进入窄寄存器，再在下一拍写 L0，切断 BRAM 大读 mux 到
    // 64 项分布式 RAM 写口的组合路径。q 项在写入前作为虚拟最新缓存行
    // 参与 lookup/probe，因此命中时序和原实现保持一致。
    always_ff @(posedge clk) begin
        if (rst) begin
            MEM_cache_fill_q_en   <= 1'b0;
            MEM_cache_fill_q_addr <= 32'b0;
            MEM_cache_fill_q_data <= 32'b0;
        end else begin
            MEM_cache_fill_q_en <= MEM_cache_fill_en &&
                                   !(MEM_bus_wen && is_bram_addr(MEM_bus_addr) &&
                                     (MEM_bus_addr[17:2] == MEM_cache_fill_addr[17:2]));
            MEM_cache_fill_q_addr <= MEM_cache_fill_addr;
            MEM_cache_fill_q_data <= perip_rdata;
        end
    end

    // 八项直接映射 store buffer 覆盖 O0 代码常见的相邻栈槽。每项独立
    // 记录四个字节的有效性，使 sb/sh 后的同范围 load 也可直接旁路。
    integer store_bypass_i;
    integer store_byte_i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (store_bypass_i = 0; store_bypass_i < 8;
                 store_bypass_i = store_bypass_i + 1) begin
                store_bypass_byte_valid_q[store_bypass_i] = 4'b0;
                store_bypass_tag_q[store_bypass_i] = '0;
                store_bypass_data_q[store_bypass_i] = '0;
            end
        end else if (MEM_store_valid) begin
            if (store_bypass_tag_q[MEM_store_addr[4:2]] !=
                MEM_store_addr[17:5]) begin
                store_bypass_byte_valid_q[MEM_store_addr[4:2]] <=
                    MEM_store_byte_mask;
                store_bypass_tag_q[MEM_store_addr[4:2]] <= MEM_store_addr[17:5];
                store_bypass_data_q[MEM_store_addr[4:2]] <= MEM_store_aligned_data;
            end else begin
                store_bypass_byte_valid_q[MEM_store_addr[4:2]] <=
                    store_bypass_byte_valid_q[MEM_store_addr[4:2]] |
                    MEM_store_byte_mask;
                for (store_byte_i = 0; store_byte_i < 4;
                     store_byte_i = store_byte_i + 1) begin
                    if (MEM_store_byte_mask[store_byte_i]) begin
                        store_bypass_data_q[MEM_store_addr[4:2]]
                                           [store_byte_i*8 +: 8] <=
                            MEM_store_aligned_data[store_byte_i*8 +: 8];
                    end
                end
            end
        end
    end

    always_comb begin
        EX_store_bypass_hit =
            (store_bypass_tag_q[EX_cache_probe_addr[4:2]] ==
             EX_cache_probe_addr[17:5]) &&
            ((store_bypass_byte_valid_q[EX_cache_probe_addr[4:2]] &
              EX_load_byte_mask) == EX_load_byte_mask);
        // 当前 MEM store 比寄存的上一项更新。完整字可直接旁路；同字的
        // byte/half store 仅在覆盖 load 所需全部字节时直接旁路。
        if (MEM_store_valid &&
            (MEM_store_addr[17:2] == EX_cache_probe_addr[17:2])) begin
            EX_store_bypass_hit =
                ((MEM_store_byte_mask & EX_load_byte_mask) == EX_load_byte_mask);
        end
    end

    always_comb begin
        MEM_cache_hit  = MEM_cache_hit_raw;
        MEM_cache_data = MEM_cache_data_raw;
        if (MEM_cache_fill_q_en &&
            (MEM_cache_fill_q_addr[7:2] == MEM_cache_lookup_addr[7:2])) begin
            MEM_cache_hit  = (MEM_cache_fill_q_addr[17:2] ==
                              MEM_cache_lookup_addr[17:2]);
            MEM_cache_data = MEM_cache_fill_q_data;
        end
        EX_cache_probe_hit  = EX_cache_probe_hit_raw;
        EX_cache_probe_data = EX_cache_probe_data_raw;
        if (MEM_cache_fill_q_en &&
            (MEM_cache_fill_q_addr[7:2] == EX_cache_probe_addr[7:2])) begin
            EX_cache_probe_hit  = (MEM_cache_fill_q_addr[17:2] ==
                                   EX_cache_probe_addr[17:2]);
            EX_cache_probe_data = MEM_cache_fill_q_data;
        end
        if ((store_bypass_tag_q[EX_cache_probe_addr[4:2]] ==
             EX_cache_probe_addr[17:5]) &&
            ((store_bypass_byte_valid_q[EX_cache_probe_addr[4:2]] &
              EX_load_byte_mask) == EX_load_byte_mask)) begin
            EX_cache_probe_hit  = 1'b1;
            EX_cache_probe_data = store_bypass_data_q[EX_cache_probe_addr[4:2]];
        end
        if (MEM_store_valid &&
            (MEM_store_addr[17:2] == EX_cache_probe_addr[17:2])) begin
            EX_cache_probe_hit =
                ((MEM_store_byte_mask & EX_load_byte_mask) == EX_load_byte_mask);
            EX_cache_probe_data = MEM_store_aligned_data;
        end
    end

    // EX 提前读取完整缓存字，并随 load 一起打入 EX/MEM。下一拍消费者仅
    // 前递寄存后的数据，避免 MEM 异步 L0 读取直接串入 EX ALU。
    // 提前探测只使用 ID/EX 已寄存的基址。需要任意 EX 前递的 load 不能走
    // 零气泡路径，否则会形成 MEM2/WB -> ALU -> L0 -> hazard 的长组合链。
    assign EX_cache_probe_addr0 = EX_mem_addr_early;
    assign EX_cache_probe_addr1 = EX_S1_mem_addr_early;
    assign EX_cache_probe_addr = EX_MemRead_eff ? EX_cache_probe_addr0 :
                                 EX_S1_MemRead_eff ? EX_cache_probe_addr1 : 32'b0;
    assign EX_cache_probe_raw = select_load_raw(
        EX_cache_probe_data,
        EX_MemRead_eff ? EX_funct3 : EX_S1_funct3,
        EX_cache_probe_addr[1:0]
    );
    load_mask #(DATAWIDTH) u_ex_cache_load_mask (
        .mask  (EX_MemRead_eff ? EX_funct3 : EX_S1_funct3),
        .dout  (EX_cache_probe_raw),
        .mdata (EX_cache_probe_load_data)
    );

    // 提前探测 EX load。若同拍有更老的同地址 store，则必须按 miss 处理，
    // 避免消费者前递到 store 之前的旧缓存数据。
    assign EX_cache_ready0 = EX_MemRead_eff && (ForwardA == 3'd0) &&
                             is_bram_addr(EX_cache_probe_addr0) &&
                             (EX_store_bypass_hit ||
                              (EX_cache_probe_hit &&
                               !(MEM_cache_fill_en &&
                                 (MEM_cache_fill_addr[7:2] == EX_cache_probe_addr0[7:2]) &&
                                 (MEM_cache_fill_addr[17:2] != EX_cache_probe_addr0[17:2]))));
    assign EX_cache_ready1 = EX_S1_MemRead_eff && (ForwardA_S1 == 3'd0) &&
                             is_bram_addr(EX_cache_probe_addr1) &&
                             (EX_store_bypass_hit ||
                              (EX_cache_probe_hit &&
                               !(MEM_cache_fill_en &&
                                 (MEM_cache_fill_addr[7:2] == EX_cache_probe_addr1[7:2]) &&
                                 (MEM_cache_fill_addr[17:2] != EX_cache_probe_addr1[17:2]))));

    // 零气泡 load 的前递值来自 EX/MEM 中的寄存副本。
    assign MEM_forward_data_effective = MEM_forward_data;
    assign MEM_S1_forward_data_effective = MEM_S1_forward_data;

    logic [31:0] MEM_cache_raw0, MEM_cache_raw1;
    logic [31:0] MEM_cache_load_data0, MEM_cache_load_data1;
    assign MEM_load_ready_word = MEM_store_bypass_hit ? MEM_store_bypass_data :
                                                        MEM_cache_data;
    assign MEM_cache_raw0 = select_load_raw(MEM_load_ready_word, MEM_funct3,
                                             MEM_perip_bus_addr[1:0]);
    assign MEM_cache_raw1 = select_load_raw(MEM_load_ready_word, MEM_S1_funct3,
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
            MEM2_cache_hit       <= MEM_load_ready0;
            MEM2_S1_cache_hit    <= MEM_load_ready1;
            MEM2_forward_data    <= MEM_lookup_ready0 ? MEM_cache_load_data0 :
                                                        MEM_forward_data;
            MEM2_S1_forward_data <= MEM_lookup_ready1 ? MEM_cache_load_data1 :
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
                        perip_rdata : MEM2_mmio_mdata;
    assign MEM2_S1_mdata = (MEM2_S1_MemRead && MEM2_S1_bram_access) ?
                           perip_rdata : MEM2_S1_mmio_mdata;

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
        .MEM_bram_access(MEM2_bram_access),
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
        .WB_funct3      (WB_funct3     ),
        .WB_bram_access (WB_bram_access)
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
        .MEM_bram_access(MEM2_S1_bram_access),
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
        .WB_funct3      (WB_S1_funct3       ),
        .WB_bram_access (WB_S1_bram_access  )
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
        .WB_bram_access(WB_bram_access),
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
        .WB_bram_access(WB_S1_bram_access),
        .WB_wdata      (WB_S1_wdata     )
    );

endmodule
