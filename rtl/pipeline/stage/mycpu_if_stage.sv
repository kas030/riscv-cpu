`timescale 1ns / 1ps
`include "../../common/defines.sv"
// =============================================================================
// mycpu_if_stage.sv —— IF（取指）级
//   - 维护 pc_reg 寄存器，根据预测结果选择 pc_reg+4 或预测目标
//   - EX 级发现预测错误时，优先使用 IF_npc_redirect 修正取指地址
//   - 把 pc_reg 输出到 IROM 的地址端口，IROM 同周期返回的 32 位指令直接连给
//     IF_instr，再交给 IF/ID 流水寄存器锁存。
//   - Stall=1 时由 pc_reg 模块的 en 入口冻结 pc_reg，使流水线整体停顿。
// =============================================================================
module mycpu_if_stage #(
    parameter DATAWIDTH = 32                ,
    parameter RESET_VAL = 32'h8000_0000
) (
    input  logic [DATAWIDTH - 1:0] irom_data       ,        // IROM 返回的第一槽指令
    input  logic [DATAWIDTH - 1:0] irom_data1      ,        // IROM 返回的第二槽指令（pc+4）
    input  logic [DATAWIDTH - 1:0] IF_npc_redirect ,        // EX 级算出的跳转目标
    input  logic                   clk             ,
    input  logic                   rst             ,
    input  logic                   Stall           ,        // load-use 等冒险时拉高
    input  logic                   BranchRedirect  ,
    input  logic                   BP_update_en    ,
    input  logic [DATAWIDTH - 1:0] BP_update_pc    ,
    input  logic                   BP_update_taken ,
    output logic [DATAWIDTH - 1:0] irom_addr       ,        // 第一槽取指地址
    output logic [DATAWIDTH - 1:0] irom_addr1      ,        // 第二槽取指地址
    output logic [DATAWIDTH - 1:0] IF_pc           ,        // 当前 pc_reg
    output logic [DATAWIDTH - 1:0] IF_instr        ,        // 当前取到的指令
    output logic [DATAWIDTH - 1:0] IF_instr1       ,        // pc+4 取到的指令
    output logic                   IF_issue_dual   ,
    output logic                   IF_pred_taken   ,
    output logic [DATAWIDTH - 1:0] IF_pred_target
);
    // 取下一条指令地址：纠错重定向优先，其次使用动态分支预测。
    logic [DATAWIDTH - 1:0] IF_next_pc;
    logic [DATAWIDTH - 1:0] IF_seq_pc;
    (* keep = "true" *) logic [DATAWIDTH - 1:0] IF_pc_plus4;
    (* keep = "true" *) logic [DATAWIDTH - 1:0] IF_pc_plus8;
    logic                   IF_dual_candidate;
    logic                   IF_slot_raw_hazard;
    logic                   IF_slot_waw_hazard;
    logic                   IF_slot_mem_conflict;
    logic                   IF_slot_m_conflict;
    localparam DUAL_HINT_INDEX_WIDTH = 8;
    localparam DUAL_HINT_ENTRIES = 1 << DUAL_HINT_INDEX_WIDTH;
    logic [5:0] dual_hint_tag [0:DUAL_HINT_ENTRIES-1];
    logic       dual_hint_valid [0:DUAL_HINT_ENTRIES-1];
    logic       dual_hint_value [0:DUAL_HINT_ENTRIES-1];
    logic [DUAL_HINT_INDEX_WIDTH-1:0] dual_hint_index;
    logic [5:0] dual_hint_pc_tag;
    logic       dual_hint_hit;
    logic       dual_hint_pending_valid;
    logic [DUAL_HINT_INDEX_WIDTH-1:0] dual_hint_pending_index;
    logic [5:0] dual_hint_pending_tag;
    logic       dual_hint_pending_value;

    function automatic logic instr_writes_rd(input logic [DATAWIDTH - 1:0] instr);
        logic [6:0] opcode;
        begin
            opcode = instr[6:0];
            instr_writes_rd = (opcode == `R_TYPE ) ||
                              (opcode == `I_TYPE ) ||
                              (opcode == `IL_TYPE) ||
                              (opcode == `IJ_TYPE) ||
                              (opcode == `J_TYPE ) ||
                              (opcode == `U_TYPE ) ||
                              (opcode == `UA_TYPE) ||
                              ((opcode == `CSR_TYPE) &&
                               ((instr[14:12] == 3'b001) ||
                                (instr[14:12] == 3'b010) ||
                                (instr[14:12] == 3'b011) ||
                                (instr[14:12] == 3'b101) ||
                                (instr[14:12] == 3'b110) ||
                                (instr[14:12] == 3'b111)));
        end
    endfunction

    function automatic logic instr_is_mem(input logic [DATAWIDTH - 1:0] instr);
        instr_is_mem = (instr[6:0] == `IL_TYPE) || (instr[6:0] == `S_TYPE);
    endfunction

    function automatic logic instr_is_m_ext(input logic [DATAWIDTH - 1:0] instr);
        instr_is_m_ext = (instr[6:0] == `R_TYPE) && (instr[31:25] == 7'b0000001);
    endfunction

    function automatic logic instr_can_dual(input logic [DATAWIDTH - 1:0] instr);
        logic [6:0] opcode;
        begin
            opcode = instr[6:0];
            // 只把无控制流/无 CSR 副作用的普通整数、M 扩展和单访存指令放进双发射包。
            instr_can_dual = (opcode == `R_TYPE ) ||
                             (opcode == `I_TYPE ) ||
                             (opcode == `IL_TYPE) ||
                             (opcode == `S_TYPE ) ||
                             (opcode == `U_TYPE ) ||
                             (opcode == `UA_TYPE);
        end
    endfunction

    branch_predictor #(DATAWIDTH) u_branch_predictor (
        .clk             (clk            ),
        .rst             (rst            ),
        .IF_pc           (IF_pc          ),
        .IF_instr        (IF_instr       ),
        .update_en       (BP_update_en   ),
        .update_pc       (BP_update_pc   ),
        .update_taken    (BP_update_taken),
        .IF_pred_taken   (IF_pred_taken  ),
        .IF_pred_target  (IF_pred_target )
    );

    // IF 级处在 PC -> IROM -> issue -> next-PC 关键回路上。这里保守地
    // 同时比较第二槽的 rs1/rs2 字段，避免串接 opcode -> uses_rs 译码。
    // I/U 类指令可能因立即数字段偶合而少发射，但不影响正确性。
    assign IF_slot_raw_hazard = instr_writes_rd(IF_instr) &&
                                (IF_instr[11:7] != 5'd0) &&
                                ((IF_instr[11:7] == irom_data1[19:15]) ||
                                 (IF_instr[11:7] == irom_data1[24:20]));
    assign IF_slot_waw_hazard = instr_writes_rd(IF_instr) &&
                                instr_writes_rd(irom_data1) &&
                                (IF_instr[11:7] != 5'd0) &&
                                (IF_instr[11:7] == irom_data1[11:7]);
    assign IF_slot_mem_conflict = instr_is_mem(IF_instr) && instr_is_mem(irom_data1);
    assign IF_slot_m_conflict   = instr_is_m_ext(IF_instr) && instr_is_m_ext(irom_data1);
    assign IF_dual_candidate = instr_can_dual(IF_instr) &&
                               instr_can_dual(irom_data1) &&
                               !IF_slot_mem_conflict &&
                               !IF_slot_m_conflict &&
                               !IF_slot_raw_hazard &&
                               !IF_slot_waw_hazard;
    // 双发射提示表把第二路IROM和复杂合法性译码移出PC反馈环。
    // IROM只读，tag命中后的历史结果始终有效；冷启动/冲突仅保守单发射。
    assign dual_hint_index  = IF_pc[DUAL_HINT_INDEX_WIDTH+1:2];
    assign dual_hint_pc_tag = IF_pc[13:8];
    assign dual_hint_hit = dual_hint_valid[dual_hint_index] &&
                           (dual_hint_tag[dual_hint_index] == dual_hint_pc_tag);
    assign IF_issue_dual = !IF_pred_taken && dual_hint_hit &&
                           dual_hint_value[dual_hint_index];

    integer hint_i;
    always_ff @(posedge clk) begin
        if (rst) begin
            dual_hint_pending_valid <= 1'b0;
            for (hint_i = 0; hint_i < DUAL_HINT_ENTRIES; hint_i = hint_i + 1) begin
                dual_hint_valid[hint_i] = 1'b0;
            end
        end else begin
            // 训练请求先打一拍，使第二路IROM译码不直接驱动提示RAM写口。
            if (dual_hint_pending_valid) begin
                dual_hint_valid[dual_hint_pending_index] <= 1'b1;
                dual_hint_tag[dual_hint_pending_index]   <= dual_hint_pending_tag;
                dual_hint_value[dual_hint_pending_index] <= dual_hint_pending_value;
            end
            dual_hint_pending_valid <= !Stall;
            if (!Stall) begin
                dual_hint_pending_index <= dual_hint_index;
                dual_hint_pending_tag   <= dual_hint_pc_tag;
                dual_hint_pending_value <= IF_dual_candidate;
            end
        end
    end
    // 并行预计算两个顺序地址，避免 IF_issue_dual 进入 32 位加法器
    // 的进位链。keep 防止综合器重新合并为带可变加数的单个加法器。
    assign IF_pc_plus4 = IF_pc + 32'd4;
    assign IF_pc_plus8 = IF_pc + 32'd8;
    assign IF_seq_pc   = IF_issue_dual ? IF_pc_plus8 : IF_pc_plus4;
    assign IF_next_pc    = BranchRedirect ? IF_npc_redirect :
                           IF_pred_taken  ? IF_pred_target   :
                                            IF_seq_pc;

    // pc_reg 寄存器；Stall=1 时 en=0，pc_reg 保持
    pc_reg #(DATAWIDTH, RESET_VAL) u_pc (
        .clk    (clk        ),
        .rst    (rst        ),
        .en     (~Stall     ),
        .npc    (IF_next_pc ),
        .pc_out (IF_pc      )
    );

    // 把 pc_reg 当作取指地址送给 IROM；IROM 当周期吐出的数据即为指令
    assign irom_addr  = IF_pc;
    assign irom_addr1 = IF_pc + 32'd4;
    assign IF_instr   = irom_data;
    assign IF_instr1  = irom_data1;
endmodule

module branch_predictor #(
    parameter DATAWIDTH   = 32,
    parameter INDEX_WIDTH = 6
) (
    input  logic                   clk,
    input  logic                   rst,
    input  logic [DATAWIDTH-1:0]   IF_pc,
    input  logic [DATAWIDTH-1:0]   IF_instr,
    input  logic                   update_en,
    input  logic [DATAWIDTH-1:0]   update_pc,
    input  logic                   update_taken,
    output logic                   IF_pred_taken,
    output logic [DATAWIDTH-1:0]   IF_pred_target
);
    localparam BHT_ENTRIES = (1 << INDEX_WIDTH);

    logic [1:0] bht [0:BHT_ENTRIES-1];
    logic [INDEX_WIDTH-1:0] IF_index;
    logic [INDEX_WIDTH-1:0] update_index;
    logic [DATAWIDTH-1:0] IF_branch_imm;
    logic [DATAWIDTH-1:0] IF_jal_imm;
    logic [DATAWIDTH-1:0] IF_branch_target;
    logic [DATAWIDTH-1:0] IF_jal_target;
    logic IF_is_branch;
    logic IF_is_jal;
    logic IF_branch_pred_taken;
    logic bht_valid [0:BHT_ENTRIES-1];

    assign IF_index     = IF_pc[INDEX_WIDTH+1:2];
    assign update_index = update_pc[INDEX_WIDTH+1:2];
    assign IF_is_branch = (IF_instr[6:0] == `B_TYPE);
    assign IF_is_jal    = (IF_instr[6:0] == `J_TYPE);

    assign IF_branch_imm = {{(DATAWIDTH-13){IF_instr[31]}},
                            IF_instr[31],
                            IF_instr[7],
                            IF_instr[30:25],
                            IF_instr[11:8],
                            1'b0};

    assign IF_jal_imm = {{(DATAWIDTH-21){IF_instr[31]}},
                         IF_instr[31],
                         IF_instr[19:12],
                         IF_instr[20],
                         IF_instr[30:21],
                         1'b0};

    assign IF_branch_target = IF_pc + IF_branch_imm;
    assign IF_jal_target    = IF_pc + IF_jal_imm;

    // Cold conditional branches use BTFNT. Trained entries use the 2-bit counter.
    assign IF_branch_pred_taken = bht_valid[IF_index] ? bht[IF_index][1] :
                                                        IF_branch_imm[DATAWIDTH-1];
    assign IF_pred_taken  = IF_is_jal || (IF_is_branch && IF_branch_pred_taken);
    assign IF_pred_target = IF_is_jal ? IF_jal_target : IF_branch_target;

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < BHT_ENTRIES; i = i + 1) begin
                bht[i] <= 2'b01;
                bht_valid[i] <= 1'b0;
            end
        end else if (update_en) begin
            bht_valid[update_index] <= 1'b1;
            if (update_taken) begin
                if (bht[update_index] != 2'b11) begin
                    bht[update_index] <= bht[update_index] + 2'b01;
                end
            end else begin
                if (bht[update_index] != 2'b00) begin
                    bht[update_index] <= bht[update_index] - 2'b01;
                end
            end
        end
    end
endmodule
