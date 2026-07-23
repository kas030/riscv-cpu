`timescale 1ns / 1ps
`include "../../common/defines.sv"
// =============================================================================
// mycpu_if_stage.sv —— IF（取指）级
//   - 维护当前 PC 寄存器，根据预测结果选择下一拍 BRAM 请求地址
//   - EX 级发现预测错误时，优先使用 IF_npc_redirect 修正取指地址
//   - IROM 为一拍同步读；前进时预取下一项，Stall 时重新请求当前项
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
    input  logic [DATAWIDTH - 1:0] BP_update_target,
    input  logic                   BP_update_is_jal,
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
    // 当前指令 PC，以及下一拍同步 IROM 请求地址。
    logic [DATAWIDTH - 1:0] IF_next_pc;
    logic [DATAWIDTH - 1:0] IF_seq_pc;
    (* keep = "true" *) logic [DATAWIDTH - 1:0] IF_pc_plus4;
    (* keep = "true" *) logic [DATAWIDTH - 1:0] IF_pc_plus8;
    (* keep = "true" *) logic [DATAWIDTH - 1:0] IF_next_pc_plus4;
    logic                   IF_dual_candidate;
    logic                   IF_slot_raw_hazard;
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
        .update_en       (BP_update_en   ),
        .update_pc       (BP_update_pc   ),
        .update_target   (BP_update_target),
        .update_is_jal   (BP_update_is_jal),
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
    assign IF_slot_mem_conflict = instr_is_mem(IF_instr) && instr_is_mem(irom_data1);
    assign IF_slot_m_conflict   = instr_is_m_ext(IF_instr) && instr_is_m_ext(irom_data1);
    assign IF_dual_candidate = instr_can_dual(IF_instr) &&
                               instr_can_dual(irom_data1) &&
                               !IF_slot_mem_conflict &&
                               !IF_slot_m_conflict &&
                               !IF_slot_raw_hazard;
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
            // Stall 时 PC/指令保持，重复训练同一项不改变结果。
            // 始终更新 pending 可将 hazard 从这组寄存器 CE 路径移除。
            dual_hint_pending_valid <= 1'b1;
            dual_hint_pending_index <= dual_hint_index;
            dual_hint_pending_tag   <= dual_hint_pc_tag;
            dual_hint_pending_value <= IF_dual_candidate;
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
    // IROM B 口固定请求 A 口地址后的相邻 word。分别在 Stall 选择前完成
    // 两条候选路径的 +4，避免 Stall_Front 穿过 32 位进位链后才到 BRAM 地址口。
    assign IF_next_pc_plus4 = IF_next_pc + 32'd4;

    pc_reg #(DATAWIDTH, RESET_VAL) u_pc (
        .clk    (clk        ),
        .rst    (rst        ),
        .en     (~Stall     ),
        .npc    (IF_next_pc ),
        .pc_out (IF_pc      )
    );

    // 同步 IROM 在上升沿采样地址。流水前进时请求下一项，使沿后的 BRAM
    // 返回值与同时更新的 IF_pc 对齐；停顿时重新请求当前项并保持返回稳定。
    assign irom_addr  = rst ? RESET_VAL :
                        Stall ? IF_pc : IF_next_pc;
    assign irom_addr1 = rst ? (RESET_VAL + 32'd4) :
                        Stall ? IF_pc_plus4 : IF_next_pc_plus4;
    assign IF_instr  = irom_data;
    assign IF_instr1 = irom_data1;
endmodule

module branch_predictor #(
    parameter DATAWIDTH   = 32,
    parameter INDEX_WIDTH = 6
) (
    input  logic                   clk,
    input  logic                   rst,
    input  logic [DATAWIDTH-1:0]   IF_pc,
    input  logic                   update_en,
    input  logic [DATAWIDTH-1:0]   update_pc,
    input  logic [DATAWIDTH-1:0]   update_target,
    input  logic                   update_is_jal,
    input  logic                   update_taken,
    output logic                   IF_pred_taken,
    output logic [DATAWIDTH-1:0]   IF_pred_target
);
    localparam BHT_ENTRIES = (1 << INDEX_WIDTH);

    logic [1:0] bht [0:BHT_ENTRIES-1];
    logic [INDEX_WIDTH-1:0] IF_index;
    logic [INDEX_WIDTH-1:0] update_index;
    logic [5:0] btb_tag [0:BHT_ENTRIES-1];
    logic [DATAWIDTH-1:0] btb_target [0:BHT_ENTRIES-1];
    logic btb_valid [0:BHT_ENTRIES-1];
    logic btb_is_jal [0:BHT_ENTRIES-1];
    logic btb_hit;

    assign IF_index     = IF_pc[INDEX_WIDTH+1:2];
    assign update_index = update_pc[INDEX_WIDTH+1:2];
    assign btb_hit = btb_valid[IF_index] &&
                     (btb_tag[IF_index] == IF_pc[13:8]);
    assign IF_pred_taken = btb_hit &&
                           (btb_is_jal[IF_index] || bht[IF_index][1]);
    assign IF_pred_target = btb_target[IF_index];

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < BHT_ENTRIES; i = i + 1) begin
                bht[i] <= 2'b01;
                btb_valid[i] = 1'b0;
            end
        end else if (update_en) begin
            btb_valid[update_index]  <= 1'b1;
            btb_tag[update_index]    <= update_pc[13:8];
            btb_target[update_index] <= update_target;
            btb_is_jal[update_index] <= update_is_jal;
            if (!update_is_jal) begin
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
    end
endmodule
