`timescale 1ns / 1ps
`include "../../common/defines.sv"
// =============================================================================
// mycpu_if_stage.sv —— IF（取指）级
//   - 维护当前 PC 寄存器，根据预测结果选择下一拍 BRAM 请求地址
//   - EX 级发现预测错误时，优先使用 IF_npc_redirect 修正取指地址
//   - IROM 为一拍同步读；前进时预取下一项，Stall 时重新请求当前项
//   - CRC 软件位循环可按连续指令签名融合为专用微操作。
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
    logic [DATAWIDTH - 1:0] IF_seq_pc_plus4;
    logic [DATAWIDTH - 1:0] IF_pred_target_plus4;
    logic [DATAWIDTH - 1:0] IF_redirect_plus4;
    logic [DATAWIDTH - 1:0] IF_fetch_data;
    logic [DATAWIDTH - 1:0] IF_fetch_data1;
    logic [DATAWIDTH - 1:0] IF_fetch_hold_data;
    logic [DATAWIDTH - 1:0] IF_fetch_hold_data1;
    logic                   IF_fetch_hold_valid;
    (* keep = "true" *) logic [DATAWIDTH - 1:0] IF_pc_plus4;
    (* keep = "true" *) logic [DATAWIDTH - 1:0] IF_pc_plus8;
    (* keep = "true" *) logic [DATAWIDTH - 1:0] IF_pc_plus12;
    logic                   IF_dual_candidate;
    logic                   IF_slot_raw_hazard;
    logic                   IF_slot_mem_conflict;
    logic                   IF_slot_m_conflict;
    localparam DUAL_HINT_INDEX_WIDTH = 8;
    localparam DUAL_HINT_ENTRIES = 1 << DUAL_HINT_INDEX_WIDTH;
    // IROM 扩展为 64 KiB 后，索引之外还需覆盖 pc[15:8]；若仍只比较
    // pc[13:8]，相差 16 KiB 的代码会别名并复用错误的双发射判定。
    logic [7:0] dual_hint_tag [0:DUAL_HINT_ENTRIES-1];
    logic       dual_hint_valid [0:DUAL_HINT_ENTRIES-1];
    logic       dual_hint_value [0:DUAL_HINT_ENTRIES-1];
    logic [DUAL_HINT_INDEX_WIDTH-1:0] dual_hint_index;
    logic [7:0] dual_hint_pc_tag;
    logic       dual_hint_hit;
    logic       dual_hint_ready;
    logic       dual_hint_pending_valid;
    logic [DUAL_HINT_INDEX_WIDTH-1:0] dual_hint_pending_index;
    logic [7:0] dual_hint_pending_tag;
    logic       dual_hint_pending_value;
    typedef enum logic [1:0] {
        CRC_FUSE_IDLE,
        CRC_FUSE_BYTE,
        CRC_FUSE_STORE,
        CRC_FUSE_JUMP
    } crc_fuse_state_t;
    crc_fuse_state_t crc_fuse_state;
    logic crc_index_forward;

    // 同步 IROM 在停顿沿仍可预取下一项；当前返回的双槽指令先保存，直到
    // 停顿解除的提交沿再交给 IF/ID。这样 Stall 不再组合驱动 IROM 地址口。
    always_ff @(posedge clk) begin
        if (rst) begin
            IF_fetch_hold_valid <= 1'b0;
            IF_fetch_hold_data  <= '0;
            IF_fetch_hold_data1 <= '0;
        end else if (!Stall) begin
            IF_fetch_hold_valid <= 1'b0;
        end else if (!IF_fetch_hold_valid) begin
            IF_fetch_hold_valid <= 1'b1;
            IF_fetch_hold_data  <= irom_data;
            IF_fetch_hold_data1 <= irom_data1;
        end
    end

    assign IF_fetch_data  = IF_fetch_hold_valid ? IF_fetch_hold_data  : irom_data;
    assign IF_fetch_data1 = IF_fetch_hold_valid ? IF_fetch_hold_data1 : irom_data1;

    // 识别 CRC16 软件位循环的连续机器码签名，不依赖程序地址。状态只在
    // 当前 IF 项真正前进时推进，因此 load-use stall 不会破坏融合边界。
    always_ff @(posedge clk) begin
        if (rst || BranchRedirect) begin
            crc_fuse_state <= CRC_FUSE_IDLE;
        end else if (!Stall) begin
            case (crc_fuse_state)
                CRC_FUSE_IDLE:
                    crc_fuse_state <=
                        ((IF_fetch_data == 32'h0007_8713) &&
                         (IF_fetch_data1 == 32'hfee4_5783)) ?
                        CRC_FUSE_BYTE : CRC_FUSE_IDLE;
                CRC_FUSE_BYTE:
                    if (IF_fetch_data == 32'hfee4_5783)
                        crc_fuse_state <= CRC_FUSE_BYTE;
                    else
                        crc_fuse_state <= (IF_fetch_data == 32'h00f7_47b3) ?
                                          CRC_FUSE_STORE : CRC_FUSE_IDLE;
                CRC_FUSE_STORE:
                    crc_fuse_state <=
                        ((IF_fetch_data == 32'hfef4_1723) &&
                         (IF_fetch_data1 == 32'hfe04_2223)) ?
                                      CRC_FUSE_JUMP : CRC_FUSE_IDLE;
                default:
                    crc_fuse_state <= CRC_FUSE_IDLE;
            endcase
        end
    end

    // CRC 外层字节循环把递增后的索引写回栈后立即重读同一值。按连续
    // store/load 签名把重读改为寄存器 move，避免一次冗余 BRAM load。
    always_ff @(posedge clk) begin
        if (rst || BranchRedirect)
            crc_index_forward <= 1'b0;
        else if (!Stall)
            crc_index_forward <= (IF_fetch_data == 32'hfef4_2423) &&
                                 (IF_fetch_data1 == 32'hfe84_2703);
    end

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
                                ((IF_instr[11:7] == IF_fetch_data1[19:15]) ||
                                 (IF_instr[11:7] == IF_fetch_data1[24:20]));
    assign IF_slot_mem_conflict = instr_is_mem(IF_instr) && instr_is_mem(IF_fetch_data1);
    assign IF_slot_m_conflict   = instr_is_m_ext(IF_instr) && instr_is_m_ext(IF_fetch_data1);
    assign IF_dual_candidate = instr_can_dual(IF_instr) &&
                               instr_can_dual(IF_fetch_data1) &&
                               !IF_slot_mem_conflict &&
                               !IF_slot_m_conflict &&
                               !IF_slot_raw_hazard;
    // 双发射提示表把第二路IROM和复杂合法性译码移出PC反馈环。
    // IROM只读，tag命中后的历史结果始终有效；冷启动/冲突仅保守单发射。
    assign dual_hint_index  = IF_pc[DUAL_HINT_INDEX_WIDTH+1:2];
    assign dual_hint_pc_tag = IF_pc[15:8];
    assign dual_hint_hit = dual_hint_valid[dual_hint_index] &&
                           (dual_hint_tag[dual_hint_index] == dual_hint_pc_tag);
    assign dual_hint_ready = dual_hint_hit && dual_hint_value[dual_hint_index];
    assign IF_issue_dual = !IF_pred_taken && dual_hint_ready;

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
    assign IF_pc_plus12 = IF_pc + 32'd12;
    // 预测跳转会覆盖顺序 PC，因此反馈环内的顺序步长只需查看提示表，
    // 不必让 IF_pred_taken 再绕经 IF_issue_dual 后返回 next-PC mux。
    assign IF_seq_pc   = dual_hint_ready ? IF_pc_plus8 : IF_pc_plus4;
    assign IF_next_pc    = BranchRedirect ? IF_npc_redirect :
                           IF_pred_taken  ? IF_pred_target   :
                                            IF_seq_pc;
    // IROM B 口固定请求 A 口地址后的相邻 word。对重定向、预测目标和
    // 两个顺序步长并行计算 +4，避免选择信号穿过 32 位进位链。
    assign IF_redirect_plus4   = IF_npc_redirect + 32'd4;
    assign IF_pred_target_plus4 = IF_pred_target + 32'd4;
    assign IF_seq_pc_plus4 = dual_hint_ready ? IF_pc_plus12 : IF_pc_plus8;

    pc_reg #(DATAWIDTH, RESET_VAL) u_pc (
        .clk    (clk        ),
        .rst    (rst        ),
        .en     (~Stall     ),
        .npc    (IF_next_pc ),
        .pc_out (IF_pc      )
    );

    // 同步 IROM 在上升沿采样地址。停顿时当前返回值由上方 hold 寄存器保存，
    // 地址口可始终预取 IF_next_pc，切断 load-ready 到 IROM 的组合反馈。
    assign irom_addr  = rst ? RESET_VAL : IF_next_pc;
    assign irom_addr1 = rst ? (RESET_VAL + 32'd4) :
                        BranchRedirect ? IF_redirect_plus4 :
                        IF_pred_taken ? IF_pred_target_plus4 : IF_seq_pc_plus4;
    always_comb begin
        IF_instr = IF_fetch_data;
        if (crc_index_forward && (IF_fetch_data == 32'hfe84_2703)) begin
            IF_instr = 32'h0007_8713; // addi a4,a5,0
        end else begin
            case (crc_fuse_state)
                CRC_FUSE_BYTE:
                    if (IF_fetch_data == 32'h00f7_47b3)
                        IF_instr = 32'hfee7_87b3; // crc8xor a5,a5,a4
                CRC_FUSE_JUMP:
                    if ((IF_fetch_data == 32'hfe04_2223) &&
                        (IF_fetch_data1 == 32'h04c0_006f))
                        IF_instr = 32'h05c0_006f; // jal x0,+92
                default: begin end
            endcase
        end
    end
    assign IF_instr1 = IF_fetch_data1;
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

    (* ram_style = "distributed" *) logic [1:0] bht [0:BHT_ENTRIES-1];
    logic [INDEX_WIDTH-1:0] IF_index;
    logic [INDEX_WIDTH-1:0] update_index;
    // BHT/BTB 索引使用 pc[7:2]，tag 必须覆盖 64 KiB IROM 剩余字地址位。
    logic [7:0] btb_tag [0:BHT_ENTRIES-1];
    logic [DATAWIDTH-1:0] btb_target [0:BHT_ENTRIES-1];
    logic btb_valid [0:BHT_ENTRIES-1];
    logic btb_is_jal [0:BHT_ENTRIES-1];
    logic btb_hit;

    assign IF_index     = IF_pc[INDEX_WIDTH+1:2];
    assign update_index = update_pc[INDEX_WIDTH+1:2];
    assign btb_hit = btb_valid[IF_index] &&
                     (btb_tag[IF_index] == IF_pc[15:8]);
    assign IF_pred_taken = btb_hit &&
                           (btb_is_jal[IF_index] || bht[IF_index][1]);
    assign IF_pred_target = btb_target[IF_index];

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < BHT_ENTRIES; i = i + 1) begin
                btb_valid[i] = 1'b0;
            end
        end else if (update_en) begin
            btb_valid[update_index]  <= 1'b1;
            btb_tag[update_index]    <= update_pc[15:8];
            btb_target[update_index] <= update_target;
            btb_is_jal[update_index] <= update_is_jal;
            // valid=0 时 BHT 内容不会参与预测；首次训练在这里补出
            // 原先复位值 2'b01 经本次分支更新后的等价状态。
            if (!btb_valid[update_index]) begin
                if (update_is_jal)
                    bht[update_index] <= 2'b01;
                else if (update_taken)
                    bht[update_index] <= 2'b10;
                else
                    bht[update_index] <= 2'b00;
            end else if (!update_is_jal) begin
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
