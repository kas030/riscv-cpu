`timescale 1ns / 1ps

// 仿真专用旁路探针。所有采样发生在 posedge 后 #1，frame 中 signals/stages
// 表示 postEdge 稳定状态；events 表示刚发生在该时钟沿的体系结构副作用。
module visual_trace_probe (
    input logic clk, rst,
    input logic [31:0] IF_pc, IF_pc1, IF_instr, IF_instr1,
    input logic IF_issue_dual, IF_pred_taken,
    input logic IF_slot_raw_hazard_i, IF_slot_waw_hazard_i,
    input logic IF_slot_mem_conflict_i, IF_slot_m_conflict_i, IF_dual_candidate_i,
    input logic [31:0] IF_pred_target,
    input logic [31:0] ID_pc, ID_pc1, ID_instr, ID_instr1,
    input logic ID_issue_dual, ID_valid, ID_S1_valid,
    input logic [31:0] ID_imm, ID_S1_imm,
    input logic [4:0] ID_rs1, ID_rs2, ID_rd, ID_S1_rs1, ID_S1_rs2, ID_S1_rd,
    input logic [21:0] ID_ALUControl, ID_S1_ALUControl,
    input logic [2:0] ID_MemToReg, ID_S1_MemToReg,
    input logic ID_RegWrite, ID_MemRead, ID_MemWrite,
    input logic ID_S1_RegWrite, ID_S1_MemRead, ID_S1_MemWrite,
    input logic [31:0] EX_pc, EX_S1_pc, EX_rR1_data, EX_rR2_data,
    input logic [31:0] EX_S1_rR1_data, EX_S1_rR2_data,
    input logic EX_pred_taken,
    input logic [31:0] EX_pred_target,
    input logic [1:0] EX_NpcOp,
    input logic EX_valid, EX_S1_valid,
    input logic [31:0] EX_alu_result, EX_S1_alu_result, EX_mem_addr, EX_S1_mem_addr,
    input logic [31:0] EX_imm, EX_S1_imm, alu_in_a_i, alu_in_b_i, alu_in_a_s1_i, alu_in_b_s1_i,
    input logic [31:0] EX_csr_wb,
    input logic [4:0] EX_rd, EX_S1_rd,
    input logic [21:0] EX_ALUControl, EX_S1_ALUControl,
    input logic [2:0] EX_MemToReg, EX_S1_MemToReg, EX_funct3, EX_S1_funct3,
    input logic EX_RegWrite, EX_MemRead, EX_MemWrite,
    input logic EX_S1_RegWrite, EX_S1_MemRead, EX_S1_MemWrite,
    input logic EX_busy, EX_busy_S1, EX_any_busy,
    input logic [2:0] ForwardA, ForwardB, ForwardA_S1, ForwardB_S1,
    input logic [31:0] ForwardAData, ForwardBData, ForwardAData_S1, ForwardBData_S1,
    input logic [4:0] EX_rs1, EX_rs2, EX_S1_rs1, EX_S1_rs2,
    input logic MEM_valid, MEM_S1_valid,
    input logic [31:0] MEM_perip_addr, MEM_S1_perip_addr,
    input logic MEM_MemRead, MEM_MemWrite, MEM_S1_MemRead, MEM_S1_MemWrite,
    input logic MEM_use_s1_bus,
    input logic [31:0] MEM_mdata,
    input logic [4:0] MEM_rd, MEM_S1_rd,
    input logic MEM_RegWrite, MEM_S1_RegWrite,
    input logic [31:0] MEM_forward_data_effective, MEM_S1_forward_data_effective,
    input logic MEM_cache_hit,
    input logic [31:0] MEM_cache_data, EX_cache_probe_addr,
    input logic [31:0] EX_cache_probe_data, EX_cache_probe_raw, EX_cache_probe_load_data,
    input logic EX_cache_probe_hit, EX_cache_ready0, EX_cache_ready1,
    input logic [2:0] MEM_funct3, MEM_S1_funct3,
    input logic MEM2_valid, MEM2_S1_valid,
    input logic [31:0] MEM2_mdata, MEM2_S1_mdata,
    input logic [31:0] MEM2_alu_result, MEM2_S1_alu_result,
    input logic [2:0] MEM2_funct3, MEM2_S1_funct3,
    input logic MEM2_MemRead, MEM2_S1_MemRead, MEM2_bram_access, MEM2_S1_bram_access,
    input logic [4:0] MEM2_rd, MEM2_S1_rd,
    input logic MEM2_RegWrite, MEM2_S1_RegWrite,
    input logic [31:0] MEM2_forward_data, MEM2_S1_forward_data,
    input logic WB_retire_valid0, WB_retire_valid1,
    input logic WB_RegWrite, WB_S1_RegWrite,
    input logic [4:0] WB_rd, WB_S1_rd,
    input logic [31:0] WB_wdata, WB_S1_wdata,
    input logic [31:0] WB_mdata, WB_S1_mdata,
    input logic [31:0] WB_pcadd4, WB_S1_pcadd4,
    input logic [31:0] WB_alu_result, WB_S1_alu_result,
    input logic [31:0] WB_imm, WB_S1_imm,
    input logic [31:0] WB_csr_wb, WB_S1_csr_wb,
    input logic [2:0] WB_MemToReg, WB_S1_MemToReg,
    input logic [2:0] WB_funct3, WB_S1_funct3,
    input logic Stall_Front, Stall_Hazard, LoadUseEX, LoadUseMEM,
    input logic Flush_IF_ID, Flush_ID_EX_comb, Flush_EX_MEM,
    input logic BranchMispredict, BranchMispredict_raw, BranchTaken, BranchTaken_raw,
    input logic [31:0] IF_npc_redirect, IF_npc_redirect_raw,
    input logic [31:0] perip_addr, perip_wdata, perip_rdata,
    input logic perip_wen,
    input logic [1:0] perip_mask,
    input logic BP_update_en, BP_update_taken,
    input logic [31:0] redirect_bp_pc_q,
    input logic MEM_cache_fill_en, MEM_bram_access, MEM_S1_bram_access, MEM_bram_load,
    input logic [31:0] MEM_cache_fill_addr,
    input logic csr_write_en_i, csr_trap_enter_i, csr_trap_return_i,
    input logic [31:0] csr_next_i, csr_mstatus_i, csr_mtvec_i,
    input logic [31:0] csr_mscratch_i, csr_mepc_i, csr_mcause_i,
    input logic hint_hit_i, hint_train_i,
    input logic [7:0] hint_current_index_i,
    input logic [5:0] hint_current_tag_i,
    input logic hint_current_valid_i, hint_current_value_i,
    input logic [5:0] bht_current_index_i,
    input logic [1:0] bht_current_counter_i,
    input logic bht_current_valid_i,
    input logic [11:0] EX_csr_idx,
    input logic l0_store_en_i,
    input logic [31:0] l0_store_addr_i
);
    integer trace_fd;
    string trace_path;
    longint unsigned cycle_q;
    longint signed next_id_q;
    longint signed id_tag0, id_tag1, ex_tag0, ex_tag1, mem_tag0, mem_tag1;
    longint signed mem2_tag0, mem2_tag1, wb_tag0, wb_tag1;
    logic [31:0] id_instr_tag0, id_instr_tag1, ex_instr_tag0, ex_instr_tag1;
    logic [31:0] mem_instr_tag0, mem_instr_tag1, mem2_instr_tag0, mem2_instr_tag1;
    logic [31:0] wb_instr_tag0, wb_instr_tag1;
    logic [31:0] id_pc_tag0, id_pc_tag1, ex_pc_tag0, ex_pc_tag1;
    logic [31:0] mem_pc_tag0, mem_pc_tag1, mem2_pc_tag0, mem2_pc_tag1;
    logic [31:0] wb_pc_tag0, wb_pc_tag1;

    logic retire0_q, retire1_q, store_q, csr_write_q, trap_enter_q, trap_return_q, redirect_q;
    logic l0_fill_q, l0_invalidate_q;
    longint signed retire_tag0_q, retire_tag1_q, store_tag_q, csr_tag_q, redirect_tag_q;
    longint signed redirect_origin_tag_q;
    logic [1:0] redirect_reason_q;
    logic [4:0] retire_rd0_q, retire_rd1_q;
    logic [31:0] retire_data0_q, retire_data1_q;
    logic retire_regwrite0_q, retire_regwrite1_q;
    logic [31:0] store_addr_q, store_data_q, redirect_target_event_q, csr_value_q;
    logic [31:0] l0_fill_addr_q, l0_fill_data_q, l0_invalidate_addr_q;
    logic [1:0] store_mask_q;
    logic [11:0] csr_index_q;

    initial begin
        trace_fd = 0;
        if (!$test$plusargs("visual_trace_disable")) begin
            if (!$value$plusargs("visual_trace=%s", trace_path)) trace_path = "build/visual-trace.raw.jsonl";
            trace_fd = $fopen(trace_path, "w");
            if (trace_fd == 0) $fatal(1, "cannot open visual trace: %s", trace_path);
            $fwrite(trace_fd, "{\"type\":\"header\",\"schemaVersion\":1,\"sampling\":\"postEdge signals after #1; events are effects at the sampled edge\"}\n");
        end
    end

    final begin
        if (trace_fd != 0) $fclose(trace_fd);
    end

    task automatic clear_tags;
        begin
            id_tag0 = -1; id_tag1 = -1; ex_tag0 = -1; ex_tag1 = -1;
            mem_tag0 = -1; mem_tag1 = -1; mem2_tag0 = -1; mem2_tag1 = -1;
            wb_tag0 = -1; wb_tag1 = -1;
        end
    endtask

    task automatic write_tag(input longint signed tag, input logic [31:0] pc, input logic [31:0] instruction, input integer lane);
        begin
            if (tag < 0) $fwrite(trace_fd, "null");
            else $fwrite(trace_fd, "{\"instructionId\":%0d,\"pc\":\"%08h\",\"instruction\":\"%08h\",\"lane\":%0d}", tag, pc, instruction, lane);
        end
    endtask

    initial begin
        cycle_q = 0;
        next_id_q = 0;
        clear_tags();
        redirect_origin_tag_q = -1;
        redirect_reason_q = 0;
    end

    always @(posedge clk) begin
        // 捕获该沿真正发生的副作用；这些输入在 NBA 前属于上一 postEdge frame。
        retire0_q <= WB_retire_valid0;
        retire1_q <= WB_retire_valid1;
        retire_tag0_q <= wb_tag0;
        retire_tag1_q <= wb_tag1;
        retire_rd0_q <= WB_rd;
        retire_rd1_q <= WB_S1_rd;
        retire_data0_q <= WB_wdata;
        retire_data1_q <= WB_S1_wdata;
        retire_regwrite0_q <= WB_RegWrite && (WB_rd != 0);
        retire_regwrite1_q <= WB_S1_RegWrite && (WB_S1_rd != 0);
        store_q <= perip_wen;
        store_tag_q <= MEM_use_s1_bus ? mem_tag1 : mem_tag0;
        store_addr_q <= perip_addr;
        store_data_q <= perip_wdata;
        store_mask_q <= perip_mask;
        l0_fill_q <= MEM_cache_fill_en;
        l0_fill_addr_q <= MEM_cache_fill_addr;
        l0_fill_data_q <= perip_rdata;
        l0_invalidate_q <= l0_store_en_i;
        l0_invalidate_addr_q <= l0_store_addr_i;
        csr_write_q <= csr_write_en_i;
        trap_enter_q <= csr_trap_enter_i;
        trap_return_q <= csr_trap_return_i;
        csr_tag_q <= ex_tag0;
        csr_index_q <= EX_csr_idx;
        csr_value_q <= csr_next_i;
        redirect_q <= BranchMispredict && !Stall_Front;
        redirect_tag_q <= redirect_origin_tag_q;
        redirect_target_event_q <= IF_npc_redirect;
        if (BranchMispredict_raw) begin
            redirect_origin_tag_q <= ex_tag0;
            if ((EX_NpcOp == 2'b01) && (EX_pred_taken != BranchTaken_raw)) redirect_reason_q <= 2'd1;
            else redirect_reason_q <= 2'd2;
        end

        if (rst) begin
            cycle_q <= 0;
            next_id_q <= 0;
            id_tag0 <= -1; id_tag1 <= -1; ex_tag0 <= -1; ex_tag1 <= -1;
            mem_tag0 <= -1; mem_tag1 <= -1; mem2_tag0 <= -1; mem2_tag1 <= -1;
            wb_tag0 <= -1; wb_tag1 <= -1;
            redirect_origin_tag_q <= -1;
            redirect_reason_q <= 0;
        end else begin
            cycle_q <= cycle_q + 1;

            if (Flush_IF_ID) begin
                id_tag0 <= -1; id_tag1 <= -1;
            end else if (!Stall_Front) begin
                id_tag0 <= next_id_q;
                id_pc_tag0 <= IF_pc;
                id_instr_tag0 <= IF_instr;
                if (IF_issue_dual) begin
                    id_tag1 <= next_id_q + 1;
                    id_pc_tag1 <= IF_pc1;
                    id_instr_tag1 <= IF_instr1;
                    next_id_q <= next_id_q + 2;
                end else begin
                    id_tag1 <= -1;
                    next_id_q <= next_id_q + 1;
                end
            end

            if (Flush_ID_EX_comb) begin
                ex_tag0 <= -1; ex_tag1 <= -1;
            end else if (!EX_any_busy) begin
                ex_tag0 <= id_tag0; ex_tag1 <= id_tag1;
                ex_pc_tag0 <= id_pc_tag0; ex_pc_tag1 <= id_pc_tag1;
                ex_instr_tag0 <= id_instr_tag0; ex_instr_tag1 <= id_instr_tag1;
            end

            if (Flush_EX_MEM || EX_any_busy) begin
                mem_tag0 <= -1; mem_tag1 <= -1;
            end else begin
                mem_tag0 <= ex_tag0; mem_tag1 <= ex_tag1;
                mem_pc_tag0 <= ex_pc_tag0; mem_pc_tag1 <= ex_pc_tag1;
                mem_instr_tag0 <= ex_instr_tag0; mem_instr_tag1 <= ex_instr_tag1;
            end
            mem2_tag0 <= mem_tag0; mem2_tag1 <= mem_tag1;
            mem2_pc_tag0 <= mem_pc_tag0; mem2_pc_tag1 <= mem_pc_tag1;
            mem2_instr_tag0 <= mem_instr_tag0; mem2_instr_tag1 <= mem_instr_tag1;
            wb_tag0 <= mem2_tag0; wb_tag1 <= mem2_tag1;
            wb_pc_tag0 <= mem2_pc_tag0; wb_pc_tag1 <= mem2_pc_tag1;
            wb_instr_tag0 <= mem2_instr_tag0; wb_instr_tag1 <= mem2_instr_tag1;
        end

        #1;
        if (!rst && trace_fd != 0) begin
            if ((id_tag0 >= 0) != ID_valid || (id_tag1 >= 0) != ID_S1_valid ||
                (ex_tag0 >= 0) != EX_valid || (ex_tag1 >= 0) != EX_S1_valid ||
                (mem_tag0 >= 0) != MEM_valid || (mem_tag1 >= 0) != MEM_S1_valid ||
                (mem2_tag0 >= 0) != MEM2_valid || (mem2_tag1 >= 0) != MEM2_S1_valid)
                $fatal(1, "visual trace tag/valid mismatch at cycle %0d", cycle_q);

            $fwrite(trace_fd, "{\"type\":\"frame\",\"cycle\":%0d,\"signals\":{", cycle_q);
            $fwrite(trace_fd, "\"IF_pc\":\"%08h\",\"IF_pc1\":\"%08h\",\"IF_instr\":\"%08h\",\"IF_instr1\":\"%08h\",", IF_pc, IF_pc1, IF_instr, IF_instr1);
            $fwrite(trace_fd, "\"IF_issue_dual\":\"%01b\",\"IF_pred_taken\":\"%01b\",\"IF_pred_target\":\"%08h\",", IF_issue_dual, IF_pred_taken, IF_pred_target);
            $fwrite(trace_fd, "\"IF_slot_raw_hazard\":\"%01b\",\"IF_slot_waw_hazard\":\"%01b\",\"IF_slot_mem_conflict\":\"%01b\",\"IF_slot_m_conflict\":\"%01b\",\"IF_dual_candidate\":\"%01b\",", IF_slot_raw_hazard_i, IF_slot_waw_hazard_i, IF_slot_mem_conflict_i, IF_slot_m_conflict_i, IF_dual_candidate_i);
            $fwrite(trace_fd, "\"ID_pc\":\"%08h\",\"ID_pc1\":\"%08h\",\"ID_instr\":\"%08h\",\"ID_instr1\":\"%08h\",\"ID_issue_dual\":\"%01b\",", ID_pc, ID_pc1, ID_instr, ID_instr1, ID_issue_dual);
            $fwrite(trace_fd, "\"ID_imm\":\"%08h\",\"ID_S1_imm\":\"%08h\",\"ID_rs1\":\"%02h\",\"ID_rs2\":\"%02h\",\"ID_rd\":\"%02h\",\"ID_S1_rs1\":\"%02h\",\"ID_S1_rs2\":\"%02h\",\"ID_S1_rd\":\"%02h\",", ID_imm, ID_S1_imm, ID_rs1, ID_rs2, ID_rd, ID_S1_rs1, ID_S1_rs2, ID_S1_rd);
            $fwrite(trace_fd, "\"ID_ALUControl\":\"%06h\",\"ID_S1_ALUControl\":\"%06h\",\"ID_MemToReg\":\"%03b\",\"ID_S1_MemToReg\":\"%03b\",", ID_ALUControl, ID_S1_ALUControl, ID_MemToReg, ID_S1_MemToReg);
            $fwrite(trace_fd, "\"ID_valid\":\"%01b\",\"ID_S1_valid\":\"%01b\",\"ID_RegWrite\":\"%01b\",\"ID_MemRead\":\"%01b\",\"ID_MemWrite\":\"%01b\",", ID_valid, ID_S1_valid, ID_RegWrite, ID_MemRead, ID_MemWrite);
            $fwrite(trace_fd, "\"ID_S1_RegWrite\":\"%01b\",\"ID_S1_MemRead\":\"%01b\",\"ID_S1_MemWrite\":\"%01b\",", ID_S1_RegWrite, ID_S1_MemRead, ID_S1_MemWrite);
            $fwrite(trace_fd, "\"EX_pc\":\"%08h\",\"EX_S1_pc\":\"%08h\",\"EX_rR1_data\":\"%08h\",\"EX_rR2_data\":\"%08h\",", EX_pc, EX_S1_pc, EX_rR1_data, EX_rR2_data);
            $fwrite(trace_fd, "\"EX_S1_rR1_data\":\"%08h\",\"EX_S1_rR2_data\":\"%08h\",\"EX_valid\":\"%01b\",\"EX_S1_valid\":\"%01b\",", EX_S1_rR1_data, EX_S1_rR2_data, EX_valid, EX_S1_valid);
            $fwrite(trace_fd, "\"EX_pred_taken\":\"%01b\",\"EX_pred_target\":\"%08h\",\"EX_NpcOp\":\"%02b\",", EX_pred_taken, EX_pred_target, EX_NpcOp);
            $fwrite(trace_fd, "\"EX_alu_result\":\"%08h\",\"EX_S1_alu_result\":\"%08h\",\"EX_mem_addr\":\"%08h\",\"EX_S1_mem_addr\":\"%08h\",", EX_alu_result, EX_S1_alu_result, EX_mem_addr, EX_S1_mem_addr);
            $fwrite(trace_fd, "\"EX_imm\":\"%08h\",\"EX_S1_imm\":\"%08h\",\"EX_rd\":\"%02h\",\"EX_S1_rd\":\"%02h\",\"EX_ALUControl\":\"%06h\",\"EX_S1_ALUControl\":\"%06h\",", EX_imm, EX_S1_imm, EX_rd, EX_S1_rd, EX_ALUControl, EX_S1_ALUControl);
            $fwrite(trace_fd, "\"EX_csr_wb\":\"%08h\",", EX_csr_wb);
            $fwrite(trace_fd, "\"EX_MemToReg\":\"%03b\",\"EX_S1_MemToReg\":\"%03b\",\"EX_funct3\":\"%03b\",\"EX_S1_funct3\":\"%03b\",", EX_MemToReg, EX_S1_MemToReg, EX_funct3, EX_S1_funct3);
            $fwrite(trace_fd, "\"EX_RegWrite\":\"%01b\",\"EX_MemRead\":\"%01b\",\"EX_MemWrite\":\"%01b\",\"EX_S1_RegWrite\":\"%01b\",\"EX_S1_MemRead\":\"%01b\",\"EX_S1_MemWrite\":\"%01b\",", EX_RegWrite, EX_MemRead, EX_MemWrite, EX_S1_RegWrite, EX_S1_MemRead, EX_S1_MemWrite);
            $fwrite(trace_fd, "\"alu_in_a\":\"%08h\",\"alu_in_b\":\"%08h\",\"alu_in_a_s1\":\"%08h\",\"alu_in_b_s1\":\"%08h\",", alu_in_a_i, alu_in_b_i, alu_in_a_s1_i, alu_in_b_s1_i);
            $fwrite(trace_fd, "\"EX_busy\":\"%01b\",\"EX_busy_S1\":\"%01b\",\"EX_any_busy\":\"%01b\",", EX_busy, EX_busy_S1, EX_any_busy);
            $fwrite(trace_fd, "\"ForwardA\":\"%03b\",\"ForwardB\":\"%03b\",\"ForwardA_S1\":\"%03b\",\"ForwardB_S1\":\"%03b\",", ForwardA, ForwardB, ForwardA_S1, ForwardB_S1);
            $fwrite(trace_fd, "\"ForwardAData\":\"%08h\",\"ForwardBData\":\"%08h\",\"ForwardAData_S1\":\"%08h\",\"ForwardBData_S1\":\"%08h\",", ForwardAData, ForwardBData, ForwardAData_S1, ForwardBData_S1);
            $fwrite(trace_fd, "\"EX_rs1\":\"%02h\",\"EX_rs2\":\"%02h\",\"EX_S1_rs1\":\"%02h\",\"EX_S1_rs2\":\"%02h\",", EX_rs1, EX_rs2, EX_S1_rs1, EX_S1_rs2);
            $fwrite(trace_fd, "\"MEM_valid\":\"%01b\",\"MEM_S1_valid\":\"%01b\",\"MEM_perip_addr\":\"%08h\",\"MEM_S1_perip_addr\":\"%08h\",", MEM_valid, MEM_S1_valid, MEM_perip_addr, MEM_S1_perip_addr);
            $fwrite(trace_fd, "\"MEM_MemRead\":\"%01b\",\"MEM_MemWrite\":\"%01b\",\"MEM_S1_MemRead\":\"%01b\",\"MEM_S1_MemWrite\":\"%01b\",\"MEM_use_s1_bus\":\"%01b\",", MEM_MemRead, MEM_MemWrite, MEM_S1_MemRead, MEM_S1_MemWrite, MEM_use_s1_bus);
            $fwrite(trace_fd, "\"MEM_mdata\":\"%08h\",\"MEM_cache_hit\":\"%01b\",\"MEM_cache_data\":\"%08h\",\"EX_cache_probe_addr\":\"%08h\",\"EX_cache_probe_hit\":\"%01b\",", MEM_mdata, MEM_cache_hit, MEM_cache_data, EX_cache_probe_addr, EX_cache_probe_hit);
            $fwrite(trace_fd, "\"EX_cache_probe_data\":\"%08h\",\"EX_cache_probe_raw\":\"%08h\",\"EX_cache_probe_load_data\":\"%08h\",\"EX_cache_ready0\":\"%01b\",\"EX_cache_ready1\":\"%01b\",", EX_cache_probe_data, EX_cache_probe_raw, EX_cache_probe_load_data, EX_cache_ready0, EX_cache_ready1);
            $fwrite(trace_fd, "\"MEM_funct3\":\"%03b\",\"MEM_S1_funct3\":\"%03b\",", MEM_funct3, MEM_S1_funct3);
            $fwrite(trace_fd, "\"MEM_rd\":\"%02h\",\"MEM_S1_rd\":\"%02h\",\"MEM_RegWrite\":\"%01b\",\"MEM_S1_RegWrite\":\"%01b\",\"MEM_forward_data_effective\":\"%08h\",\"MEM_S1_forward_data_effective\":\"%08h\",", MEM_rd, MEM_S1_rd, MEM_RegWrite, MEM_S1_RegWrite, MEM_forward_data_effective, MEM_S1_forward_data_effective);
            $fwrite(trace_fd, "\"MEM2_valid\":\"%01b\",\"MEM2_S1_valid\":\"%01b\",\"MEM2_mdata\":\"%08h\",\"MEM2_S1_mdata\":\"%08h\",", MEM2_valid, MEM2_S1_valid, MEM2_mdata, MEM2_S1_mdata);
            $fwrite(trace_fd, "\"MEM2_alu_result\":\"%08h\",\"MEM2_S1_alu_result\":\"%08h\",\"MEM2_funct3\":\"%03b\",\"MEM2_S1_funct3\":\"%03b\",", MEM2_alu_result, MEM2_S1_alu_result, MEM2_funct3, MEM2_S1_funct3);
            $fwrite(trace_fd, "\"MEM2_MemRead\":\"%01b\",\"MEM2_S1_MemRead\":\"%01b\",\"MEM2_bram_access\":\"%01b\",\"MEM2_S1_bram_access\":\"%01b\",", MEM2_MemRead, MEM2_S1_MemRead, MEM2_bram_access, MEM2_S1_bram_access);
            $fwrite(trace_fd, "\"MEM2_rd\":\"%02h\",\"MEM2_S1_rd\":\"%02h\",\"MEM2_RegWrite\":\"%01b\",\"MEM2_S1_RegWrite\":\"%01b\",\"MEM2_forward_data\":\"%08h\",\"MEM2_S1_forward_data\":\"%08h\",", MEM2_rd, MEM2_S1_rd, MEM2_RegWrite, MEM2_S1_RegWrite, MEM2_forward_data, MEM2_S1_forward_data);
            $fwrite(trace_fd, "\"WB_retire_valid0\":\"%01b\",\"WB_retire_valid1\":\"%01b\",\"WB_RegWrite\":\"%01b\",\"WB_S1_RegWrite\":\"%01b\",", WB_retire_valid0, WB_retire_valid1, WB_RegWrite, WB_S1_RegWrite);
            $fwrite(trace_fd, "\"WB_rd\":\"%02h\",\"WB_S1_rd\":\"%02h\",\"WB_wdata\":\"%08h\",\"WB_S1_wdata\":\"%08h\",\"WB_MemToReg\":\"%03b\",\"WB_S1_MemToReg\":\"%03b\",", WB_rd, WB_S1_rd, WB_wdata, WB_S1_wdata, WB_MemToReg, WB_S1_MemToReg);
            $fwrite(trace_fd, "\"WB_mdata\":\"%08h\",\"WB_S1_mdata\":\"%08h\",\"WB_pcadd4\":\"%08h\",\"WB_S1_pcadd4\":\"%08h\",", WB_mdata, WB_S1_mdata, WB_pcadd4, WB_S1_pcadd4);
            $fwrite(trace_fd, "\"WB_alu_result\":\"%08h\",\"WB_S1_alu_result\":\"%08h\",\"WB_imm\":\"%08h\",\"WB_S1_imm\":\"%08h\",", WB_alu_result, WB_S1_alu_result, WB_imm, WB_S1_imm);
            $fwrite(trace_fd, "\"WB_csr_wb\":\"%08h\",\"WB_S1_csr_wb\":\"%08h\",\"WB_funct3\":\"%03b\",\"WB_S1_funct3\":\"%03b\",", WB_csr_wb, WB_S1_csr_wb, WB_funct3, WB_S1_funct3);
            $fwrite(trace_fd, "\"Stall_Front\":\"%01b\",\"Stall_Hazard\":\"%01b\",\"LoadUseEX\":\"%01b\",\"LoadUseMEM\":\"%01b\",", Stall_Front, Stall_Hazard, LoadUseEX, LoadUseMEM);
            $fwrite(trace_fd, "\"Flush_IF_ID\":\"%01b\",\"Flush_ID_EX_comb\":\"%01b\",\"Flush_EX_MEM\":\"%01b\",\"BranchMispredict\":\"%01b\",\"BranchMispredict_raw\":\"%01b\",\"BranchTaken\":\"%01b\",\"BranchTaken_raw\":\"%01b\",\"IF_npc_redirect\":\"%08h\",\"IF_npc_redirect_raw\":\"%08h\",", Flush_IF_ID, Flush_ID_EX_comb, Flush_EX_MEM, BranchMispredict, BranchMispredict_raw, BranchTaken, BranchTaken_raw, IF_npc_redirect, IF_npc_redirect_raw);
            $fwrite(trace_fd, "\"perip_addr\":\"%08h\",\"perip_wen\":\"%01b\",\"perip_mask\":\"%02b\",\"perip_wdata\":\"%08h\",\"perip_rdata\":\"%08h\",", perip_addr, perip_wen, perip_mask, perip_wdata, perip_rdata);
            $fwrite(trace_fd, "\"BP_update_en\":\"%01b\",\"BP_update_taken\":\"%01b\",\"redirect_bp_pc_q\":\"%08h\",", BP_update_en, BP_update_taken, redirect_bp_pc_q);
            $fwrite(trace_fd, "\"MEM_cache_fill_en\":\"%01b\",\"MEM_cache_fill_addr\":\"%08h\",\"MEM_bram_access\":\"%01b\",\"MEM_S1_bram_access\":\"%01b\",\"MEM_bram_load\":\"%01b\",", MEM_cache_fill_en, MEM_cache_fill_addr, MEM_bram_access, MEM_S1_bram_access, MEM_bram_load);
            $fwrite(trace_fd, "\"l0_store_en\":\"%01b\",\"l0_store_addr\":\"%08h\",", l0_store_en_i, l0_store_addr_i);
            $fwrite(trace_fd, "\"EX_csr_idx\":\"%03h\",\"csr_write_en\":\"%01b\",\"csr_trap_enter\":\"%01b\",\"csr_trap_return\":\"%01b\",\"csr_next\":\"%08h\",", EX_csr_idx, csr_write_en_i, csr_trap_enter_i, csr_trap_return_i, csr_next_i);
            $fwrite(trace_fd, "\"csr_mstatus\":\"%08h\",\"csr_mtvec\":\"%08h\",\"csr_mscratch\":\"%08h\",\"csr_mepc\":\"%08h\",\"csr_mcause\":\"%08h\",", csr_mstatus_i, csr_mtvec_i, csr_mscratch_i, csr_mepc_i, csr_mcause_i);
            $fwrite(trace_fd, "\"hint_hit\":\"%01b\",\"hint_train\":\"%01b\",\"hint_current_index\":\"%08b\",\"hint_current_tag\":\"%06b\",\"hint_current_valid\":\"%01b\",\"hint_current_value\":\"%01b\",", hint_hit_i, hint_train_i, hint_current_index_i, hint_current_tag_i, hint_current_valid_i, hint_current_value_i);
            $fwrite(trace_fd, "\"bht_current_index\":\"%06b\",\"bht_current_counter\":\"%02b\",\"bht_current_valid\":\"%01b\"},", bht_current_index_i, bht_current_counter_i, bht_current_valid_i);

            $fwrite(trace_fd, "\"tags\":{");
            $fwrite(trace_fd, "\"ID\":["); write_tag(id_tag0, id_pc_tag0, id_instr_tag0, 0); $fwrite(trace_fd, ","); write_tag(id_tag1, id_pc_tag1, id_instr_tag1, 1); $fwrite(trace_fd, "],");
            $fwrite(trace_fd, "\"EX\":["); write_tag(ex_tag0, ex_pc_tag0, ex_instr_tag0, 0); $fwrite(trace_fd, ","); write_tag(ex_tag1, ex_pc_tag1, ex_instr_tag1, 1); $fwrite(trace_fd, "],");
            $fwrite(trace_fd, "\"MEM1\":["); write_tag(mem_tag0, mem_pc_tag0, mem_instr_tag0, 0); $fwrite(trace_fd, ","); write_tag(mem_tag1, mem_pc_tag1, mem_instr_tag1, 1); $fwrite(trace_fd, "],");
            $fwrite(trace_fd, "\"MEM2\":["); write_tag(mem2_tag0, mem2_pc_tag0, mem2_instr_tag0, 0); $fwrite(trace_fd, ","); write_tag(mem2_tag1, mem2_pc_tag1, mem2_instr_tag1, 1); $fwrite(trace_fd, "],");
            $fwrite(trace_fd, "\"WB\":["); write_tag(wb_tag0, wb_pc_tag0, wb_instr_tag0, 0); $fwrite(trace_fd, ","); write_tag(wb_tag1, wb_pc_tag1, wb_instr_tag1, 1); $fwrite(trace_fd, "]},");
            $fwrite(trace_fd, "\"edgeEvents\":{\"retire0\":%01b,\"retire1\":%01b,\"retireTag0\":%0d,\"retireTag1\":%0d,\"retireRegWrite0\":%01b,\"retireRegWrite1\":%01b,\"retireRd0\":%0d,\"retireRd1\":%0d,\"retireData0\":\"%08h\",\"retireData1\":\"%08h\",", retire0_q, retire1_q, retire_tag0_q, retire_tag1_q, retire_regwrite0_q, retire_regwrite1_q, retire_rd0_q, retire_rd1_q, retire_data0_q, retire_data1_q);
            $fwrite(trace_fd, "\"store\":%01b,\"storeTag\":%0d,\"storeAddr\":\"%08h\",\"storeMask\":\"%02b\",\"storeData\":\"%08h\",", store_q, store_tag_q, store_addr_q, store_mask_q, store_data_q);
            $fwrite(trace_fd, "\"l0Fill\":%01b,\"l0FillAddr\":\"%08h\",\"l0FillData\":\"%08h\",\"l0Invalidate\":%01b,\"l0InvalidateAddr\":\"%08h\",", l0_fill_q, l0_fill_addr_q, l0_fill_data_q, l0_invalidate_q, l0_invalidate_addr_q);
            $fwrite(trace_fd, "\"csrWrite\":%01b,\"trapEnter\":%01b,\"trapReturn\":%01b,\"csrTag\":%0d,\"csrIndex\":\"%03h\",\"csrValue\":\"%08h\",", csr_write_q, trap_enter_q, trap_return_q, csr_tag_q, csr_index_q, csr_value_q);
            $fwrite(trace_fd, "\"redirect\":%01b,\"redirectTag\":%0d,\"redirectTarget\":\"%08h\",\"redirectReason\":%0d}}\n", redirect_q, redirect_tag_q, redirect_target_event_q, redirect_reason_q);
            $fflush(trace_fd);
        end
    end
endmodule
